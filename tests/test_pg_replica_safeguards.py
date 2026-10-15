"""Exerce le vrai controle et la permutation du role, avec fichiers ephemeres.

Les connexions SQL et outils systeme sont remplaces par des doubles : aucune
commande pg_ctlcluster, aucun chown et aucun acces a une base reelle ici.
"""

import contextlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("pg_replica", ROOT / "roles/pg_replication/files/pg_replica.py")
replica = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(replica)


def arguments(directory):
    data = Path(directory) / "main"
    data.mkdir()
    (data / "original-data").write_text("preserve me")
    return SimpleNamespace(
        data_dir=data,
        config_dir=Path(directory) / "config",
        stage_dir=Path(str(data) + ".replication-staging"),
        archive_dir=Path(str(data) + ".before-replication"),
        primary_host="192.168.96.156",
        primary_user="replicator",
        primary_system_id="123456789",
        version="15",
        port=5432,
        slot="prosys_odoodb2",
        conninfo="host=192.168.96.156 port=5432 user=replicator passfile=/tmp/synthetic-passfile",
        allow_reseed="no",
    )


class FakeCursor:
    def __init__(self, state, database):
        self.state, self.database, self.rows = state, database, []

    def __enter__(self):
        return self

    def __exit__(self, *unused):
        pass

    def execute(self, query):
        if "pg_is_in_recovery" in query:
            self.rows = [(self.state.get("recovery", False), self.state.get("system_id", "old-system"), self.state.get("conninfo", ""), self.state["data_directory"])]
        elif "SELECT datname" in query:
            self.rows = [(name,) for name in self.state.get("databases", [])]
        elif "SELECT rolname" in query:
            self.rows = [(name,) for name in self.state.get("roles", [])]
        elif "SELECT count(*) FROM pg_tablespace" in query:
            self.rows = [(self.state.get("tablespaces", 0),)]
        elif "SELECT count(*) FROM pg_replication_slots" in query:
            self.rows = [(self.state.get("slots", 0),)]
        elif "pg_class" in query:
            self.rows = [(self.state.get("objects", {}).get(self.database, 0),)]
        else:
            raise AssertionError("Unexpected SQL query")

    def fetchone(self):
        return self.rows[0]

    def fetchall(self):
        return self.rows


class FakeConnection:
    def __init__(self, state, database):
        self.state, self.database = state, database

    def __enter__(self):
        return self

    def __exit__(self, *unused):
        pass

    def cursor(self):
        return FakeCursor(self.state, self.database)


class InspectionTests(unittest.TestCase):
    def inspect(self, args, state):
        state = dict({"data_directory": str(args.data_dir)}, **state)
        def connect(**kwargs):
            return FakeConnection(state, kwargs["dbname"])
        with patch.object(replica, "postgres_identity", contextlib.nullcontext), \
             patch.object(replica, "control_system_id", return_value="old-system"), \
             patch.object(replica.psycopg2, "connect", side_effect=connect):
            return replica.inspect_cluster(args)

    def test_only_proven_empty_online_cluster_can_be_replaced_automatically(self):
        with tempfile.TemporaryDirectory(prefix="odoo14-replica-test-") as directory:
            args = arguments(directory)
            self.assertTrue(self.inspect(args, {})["fresh_cluster"])
            cases = (
                {"databases": ["prod"]},
                {"roles": ["odoo"]},
                {"objects": {"postgres": 1}},
                {"objects": {"template1": 1}},
                {"tablespaces": 1},
                {"slots": 1},
                {"recovery": True},
            )
            for state in cases:
                with self.subTest(state=state):
                    self.assertFalse(self.inspect(args, state)["fresh_cluster"])

    def test_socket_for_different_data_directory_is_refused(self):
        with tempfile.TemporaryDirectory(prefix="odoo14-replica-test-") as directory:
            args = arguments(directory)
            with self.assertRaisesRegex(RuntimeError, "different PGDATA"):
                self.inspect(args, {"data_directory": "/tmp/another-cluster"})

    def test_unreadable_cluster_is_never_assumed_empty(self):
        with tempfile.TemporaryDirectory(prefix="odoo14-replica-test-") as directory:
            args = arguments(directory)
            with patch.object(replica, "postgres_identity", contextlib.nullcontext), \
                 patch.object(replica, "control_system_id", return_value="old-system"), \
                 patch.object(replica.psycopg2, "connect", side_effect=replica.psycopg2.OperationalError("offline")), \
                 patch.object(replica, "run", return_value=subprocess.CompletedProcess([], 1, "", "")):
                result = replica.inspect_cluster(args)
            self.assertFalse(result["fresh_cluster"])
            self.assertFalse(result["matches_primary"])

    def test_existing_standby_must_match_cluster_and_upstream(self):
        with tempfile.TemporaryDirectory(prefix="odoo14-replica-test-") as directory:
            args = arguments(directory)
            (args.data_dir / "standby.signal").touch()
            good = {"recovery": True, "system_id": args.primary_system_id,
                    "conninfo": "host=192.168.96.156 port=5432 user=replicator"}
            self.assertTrue(self.inspect(args, good)["matches_primary"])
            for changes in ({"recovery": False}, {"system_id": "other"}, {"conninfo": "host=192.168.96.150 port=5432 user=replicator"}, {"conninfo": "host=192.168.96.156 port=5433 user=replicator"}):
                with self.subTest(changes=changes):
                    self.assertFalse(self.inspect(args, dict(good, **changes))["matches_primary"])


class BootstrapTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="odoo14-bootstrap-test-")
        self.addCleanup(self.directory.cleanup)
        self.args = arguments(self.directory.name)
        self.commands = []
        self.state = {"matches_primary": False, "fresh_cluster": True}
        for name, value in (
            ("postgres_identity", contextlib.nullcontext),
            ("inspect_cluster", lambda args: self.state.copy()),
            ("control_system_id", lambda path, version: self.args.primary_system_id),
        ):
            mock = patch.object(replica, name, value)
            mock.start()
            self.addCleanup(mock.stop)
        # Keep all file operations owned by this test process.
        mock = patch.object(replica.os, "chown")
        mock.start()
        self.addCleanup(mock.stop)

    def command(self, command, check=True):
        self.commands.append(command)
        if command[0].endswith("pg_basebackup"):
            (self.args.stage_dir / "standby.signal").touch()
            (self.args.stage_dir / "replicated-data").write_text("new copy")
        return subprocess.CompletedProcess(command, 0, "", "")

    def execute(self, command=None):
        with patch.object(replica, "run", side_effect=command or self.command), \
             contextlib.redirect_stdout(__import__("io").StringIO()):
            replica.bootstrap(self.args)

    def test_unproven_cluster_is_refused_before_any_external_command(self):
        self.state["fresh_cluster"] = False
        with self.assertRaisesRegex(RuntimeError, "not proven empty"):
            self.execute()
        self.assertEqual(self.commands, [])
        self.assertEqual((self.args.data_dir / "original-data").read_text(), "preserve me")

    def test_failed_transfer_keeps_original_cluster_and_removes_only_own_stage(self):
        def fail_transfer(command, check=True):
            self.commands.append(command)
            (self.args.stage_dir / "partial-transfer").write_text("partial")
            raise RuntimeError("network unavailable")
        with self.assertRaisesRegex(RuntimeError, "network unavailable"):
            self.execute(fail_transfer)
        self.assertEqual((self.args.data_dir / "original-data").read_text(), "preserve me")
        self.assertFalse(self.args.archive_dir.exists())
        self.assertFalse(self.args.stage_dir.exists())
        self.assertFalse(replica.marker_path(self.args).exists())
        self.assertTrue(all("pg_ctlcluster" not in command[0] for command in self.commands))

    def test_success_preserves_old_data_and_second_run_does_not_clone(self):
        self.execute()
        self.assertEqual((self.args.archive_dir / "original-data").read_text(), "preserve me")
        self.assertEqual((self.args.data_dir / "replicated-data").read_text(), "new copy")
        self.assertFalse(replica.marker_path(self.args).exists())
        self.assertEqual(len(self.commands), 2)
        self.state["matches_primary"] = True
        self.execute()
        self.assertEqual(len(self.commands), 2)

    def test_explicit_reseed_preserves_the_nonempty_cluster(self):
        self.state["fresh_cluster"] = False
        self.args.allow_reseed = "yes"
        self.execute()
        self.assertEqual((self.args.archive_dir / "original-data").read_text(), "preserve me")
        self.assertTrue((self.args.data_dir / "standby.signal").exists())

    def test_stop_failure_retains_old_cluster_and_completed_copy_for_retry(self):
        def stop_fails(command, check=True):
            if command[0] == "pg_ctlcluster":
                self.commands.append(command)
                return subprocess.CompletedProcess(command, 1, "", "cannot stop")
            return self.command(command, check)
        with self.assertRaisesRegex(RuntimeError, "Could not stop"):
            self.execute(stop_fails)
        self.assertTrue((self.args.data_dir / "original-data").exists())
        self.assertFalse(self.args.archive_dir.exists())
        self.assertTrue((self.args.stage_dir / "standby.signal").exists())
        self.execute()
        self.assertTrue((self.args.archive_dir / "original-data").exists())
        self.assertEqual(sum(command[0].endswith("pg_basebackup") for command in self.commands), 1)

    def test_failed_directory_swap_restores_original_before_retry(self):
        original_rename = replica.os.rename
        def fail_swap(source, destination):
            if Path(source) == self.args.stage_dir:
                raise OSError("simulated rename failure")
            return original_rename(source, destination)
        with patch.object(replica.os, "rename", side_effect=fail_swap):
            with self.assertRaisesRegex(OSError, "simulated rename"):
                self.execute()
        self.assertTrue((self.args.data_dir / "original-data").exists())
        self.assertFalse(self.args.archive_dir.exists())
        self.assertTrue(self.args.stage_dir.exists())
        self.execute()
        self.assertTrue((self.args.archive_dir / "original-data").exists())
        self.assertTrue((self.args.data_dir / "replicated-data").exists())
        self.assertEqual(sum(command[0].endswith("pg_basebackup") for command in self.commands), 1)

    def test_existing_archive_and_unmanaged_stage_are_never_overwritten(self):
        for target in (self.args.archive_dir, self.args.stage_dir):
            target.mkdir()
            sentinel = target / "important"
            sentinel.write_text("keep")
            with self.assertRaises(RuntimeError):
                self.execute()
            self.assertEqual(sentinel.read_text(), "keep")
            sentinel.unlink()
            target.rmdir()
        self.assertEqual(self.commands, [])

    def test_resume_after_old_data_archived_reuses_completed_transfer(self):
        self.args.stage_dir.mkdir()
        (self.args.stage_dir / "standby.signal").touch()
        (self.args.stage_dir / "replicated-data").write_text("completed copy")
        self.args.data_dir.rename(self.args.archive_dir)
        replica.write_marker(self.args, "switching")
        self.execute()
        self.assertEqual((self.args.data_dir / "replicated-data").read_text(), "completed copy")
        self.assertTrue((self.args.archive_dir / "original-data").exists())
        self.assertTrue(all(not command[0].endswith("pg_basebackup") for command in self.commands))

    def test_wrong_primary_marker_cannot_authorize_cleanup(self):
        self.args.stage_dir.mkdir()
        sentinel = self.args.stage_dir / "must-survive"
        sentinel.write_text("keep")
        replica.write_marker(self.args, "copying")
        marker = replica.marker_path(self.args)
        state = json.loads(marker.read_text())
        state["primary_system_id"] = "different-primary"
        marker.write_text(json.dumps(state))
        with self.assertRaisesRegex(RuntimeError, "different"):
            self.execute()
        self.assertEqual(sentinel.read_text(), "keep")


if __name__ == "__main__":
    unittest.main()
