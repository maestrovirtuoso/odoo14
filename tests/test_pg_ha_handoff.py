"""Protections du vrai transfert Debian -> Patroni, uniquement sous /tmp."""

import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("pg_ha_guard", ROOT / "roles/pg_ha/files/guard.py")
guard = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(guard)


class PatroniHandoffTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="odoo14-ha-handoff-test-")
        self.addCleanup(self.directory.cleanup)
        root = Path(self.directory.name)
        data, config = root / "data", root / "config"
        data.mkdir()
        config.mkdir()
        (data / "important-data").write_text("original cluster")
        (config / "postgresql.conf").write_text("original settings")
        self.args = SimpleNamespace(
            data_dir=data, config_dir=config,
            archive_dir=Path(str(data) + ".before-patroni"),
            config_archive_dir=Path(str(config) + ".before-patroni"),
            marker=root / "managed.json", scope="odoo14", name="odoodb1",
            version="15", port=5432, new_install="no", allow_adopt="no",
        )
        self.commands = []
        self.state = {"empty": False, "managed": False}

    def execute(self, result=0):
        def command(argv, **kwargs):
            self.commands.append(argv)
            return subprocess.CompletedProcess(argv, result, "", "")
        with patch.object(guard, "inspect", return_value=self.state.copy()), \
             patch.object(guard.subprocess, "run", side_effect=command), \
             contextlib.redirect_stdout(io.StringIO()):
            guard.prepare(self.args)

    def test_unproven_data_is_refused_without_stopping_or_moving_anything(self):
        with self.assertRaisesRegex(RuntimeError, "explicit adoption"):
            self.execute()
        self.assertFalse(self.commands)
        self.assertFalse(self.args.marker.exists())
        self.assertFalse(self.args.archive_dir.exists())
        self.assertEqual((self.args.data_dir / "important-data").read_text(), "original cluster")

    def test_fresh_cluster_and_debian_config_are_preserved_and_retry_is_noop(self):
        self.state["empty"] = True
        self.execute()
        self.assertFalse(self.args.data_dir.exists())
        self.assertEqual((self.args.archive_dir / "important-data").read_text(), "original cluster")
        self.assertEqual((self.args.config_archive_dir / "postgresql.conf").read_text(), "original settings")
        self.assertEqual(guard.load_marker(self.args)["phase"], "ready")
        self.assertEqual(len(self.commands), 1)
        self.execute()
        self.assertEqual(len(self.commands), 1)

    def test_explicit_adoption_keeps_nonempty_pgdata_in_place(self):
        self.args.allow_adopt = "yes"
        self.execute()
        self.assertEqual((self.args.data_dir / "important-data").read_text(), "original cluster")
        self.assertFalse(self.args.archive_dir.exists())
        self.assertEqual(guard.load_marker(self.args)["mode"], "adopt")
        self.assertEqual((self.args.config_archive_dir / "postgresql.conf").read_text(), "original settings")

    def test_failed_stop_keeps_data_and_resumes_using_prepared_marker(self):
        self.state["empty"] = True
        with self.assertRaisesRegex(RuntimeError, "could not be stopped"):
            self.execute(result=1)
        self.assertTrue((self.args.data_dir / "important-data").exists())
        self.assertFalse(self.args.archive_dir.exists())
        self.assertEqual(guard.load_marker(self.args)["phase"], "prepared")
        # L'etat SQL n'est plus necessaire au retry : le mode fresh a deja
        # ete prouve et enregistre avant le premier arret.
        self.state["empty"] = False
        self.execute()
        self.assertTrue((self.args.archive_dir / "important-data").exists())
        self.assertEqual(guard.load_marker(self.args)["phase"], "ready")

    def test_prior_archives_are_never_overwritten(self):
        self.state["empty"] = True
        self.args.archive_dir.mkdir()
        sentinel = self.args.archive_dir / "prior-backup"
        sentinel.write_text("preserve")
        with self.assertRaisesRegex(RuntimeError, "already exists"):
            self.execute()
        self.assertEqual(sentinel.read_text(), "preserve")
        self.assertFalse(self.commands)
        self.assertTrue((self.args.data_dir / "important-data").exists())

    def test_marker_for_other_cluster_cannot_authorize_handoff(self):
        guard.save_marker(self.args, "fresh", "prepared")
        marker = json.loads(self.args.marker.read_text())
        marker["scope"] = "another-cluster"
        self.args.marker.write_text(json.dumps(marker))
        with self.assertRaisesRegex(RuntimeError, "different"):
            self.execute()
        self.assertFalse(self.commands)
        self.assertTrue((self.args.data_dir / "important-data").exists())

    def test_world_readable_marker_cannot_authorize_handoff(self):
        guard.save_marker(self.args, "fresh", "prepared")
        self.args.marker.chmod(0o644)
        with self.assertRaisesRegex(RuntimeError, "unsafe"):
            self.execute()
        self.assertFalse(self.commands)


if __name__ == "__main__":
    unittest.main()
