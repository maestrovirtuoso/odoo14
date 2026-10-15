#!/usr/bin/python3
"""Inspect or seed a Debian PostgreSQL standby without discarding old data.

The password stays in a postgres-owned passfile. Only the staging directory
created under our marker may be removed; the old PGDATA is always retained.
"""
import argparse
import contextlib
import fcntl
import json
import os
import pathlib
import pwd
import re
import shutil
import subprocess
import sys

import psycopg2
from psycopg2.extensions import parse_dsn


@contextlib.contextmanager
def postgres_identity():
    """Peer authentication and PostgreSQL tools must run as postgres."""
    if os.geteuid() != 0:
        yield
        return
    account = pwd.getpwnam("postgres")
    old_uid, old_gid = os.geteuid(), os.getegid()
    os.setegid(account.pw_gid)
    os.seteuid(account.pw_uid)
    try:
        yield
    finally:
        os.seteuid(old_uid)
        os.setegid(old_gid)


def run(command, check=True):
    result = subprocess.run(command, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, env=dict(os.environ, LC_ALL="C"))
    if check and result.returncode:
        # Do not return libpq's connection settings or any existing password.
        categories = ("password authentication failed", "no pg_hba.conf entry",
                      "Connection refused", "timeout expired", "could not connect",
                      "No space left on device", "replication slot", "permission denied")
        reason = next((value for value in categories if value.lower() in result.stderr.lower()),
                      "check PostgreSQL logs and connectivity")
        raise RuntimeError("Command failed: {} (exit {}; {}).".format(
            command[0], result.returncode, reason))
    return result


def control_system_id(data_dir, version):
    result = run(["/usr/lib/postgresql/{}/bin/pg_controldata".format(version), str(data_dir)], False)
    match = re.search(r"^Database system identifier:\s*(\d+)$", result.stdout, re.MULTILINE)
    return match.group(1) if result.returncode == 0 and match else None


def marker_path(args):
    return pathlib.Path(str(args.data_dir) + ".replication-bootstrap.json")


def read_marker(args):
    path = marker_path(args)
    if not path.exists():
        return None
    expected_owner = 0 if os.geteuid() == 0 else os.geteuid()
    if path.is_symlink() or (path.stat().st_mode & 0o077) or path.stat().st_uid != expected_owner:
        raise RuntimeError("Unsafe bootstrap marker permissions.")
    value = json.loads(path.read_text())
    if value.get("data_dir") != str(args.data_dir) or value.get("primary_system_id") != args.primary_system_id:
        raise RuntimeError("Bootstrap marker belongs to a different data directory or primary.")
    return value


def inspect_cluster(args):
    result = {"online": False, "in_recovery": None, "fresh_cluster": False,
              "matches_primary": False, "system_identifier": None,
              "resume_pending": read_marker(args) is not None}
    conninfo = {}
    with postgres_identity():
        result["system_identifier"] = control_system_id(args.data_dir, args.version)
        try:
            with psycopg2.connect(dbname="postgres", user="postgres", port=args.port,
                                  host="/var/run/postgresql", connect_timeout=5) as connection:
                with connection.cursor() as cursor:
                    cursor.execute("SELECT pg_is_in_recovery(), system_identifier::text, "
                                   "current_setting('primary_conninfo'), "
                                   "current_setting('data_directory') FROM pg_control_system()")
                    recovery, system_id, dsn, connected_data_dir = cursor.fetchone()
                    if pathlib.Path(connected_data_dir).resolve() != args.data_dir.resolve():
                        raise RuntimeError("The local PostgreSQL port belongs to a different PGDATA; refusing replacement.")
                    conninfo = parse_dsn(dsn) if dsn else {}
                    result.update(online=True, in_recovery=recovery, system_identifier=system_id)
                    cursor.execute("SELECT datname FROM pg_database WHERE datname NOT IN "
                                   "('postgres', 'template0', 'template1')")
                    result["application_databases"] = [row[0] for row in cursor.fetchall()]
                    cursor.execute("SELECT rolname FROM pg_roles WHERE rolname <> 'postgres' "
                                   "AND rolname !~ '^pg_'")
                    result["custom_roles"] = [row[0] for row in cursor.fetchall()]
                    cursor.execute("SELECT count(*) FROM pg_tablespace WHERE spcname NOT IN "
                                   "('pg_default', 'pg_global')")
                    tablespaces = cursor.fetchone()[0]
                    cursor.execute("SELECT count(*) FROM pg_replication_slots")
                    existing_slots = cursor.fetchone()[0]
            # Even an installation using only the postgres database may hold
            # application data. Check both writable default databases.
            objects = 0
            for database in ("postgres", "template1"):
                with psycopg2.connect(dbname=database, user="postgres", port=args.port,
                                      host="/var/run/postgresql", connect_timeout=5) as connection:
                    with connection.cursor() as cursor:
                        cursor.execute("""
                            SELECT
                              (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
                               WHERE n.nspname !~ '^pg_' AND n.nspname <> 'information_schema') +
                              (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                               WHERE n.nspname !~ '^pg_' AND n.nspname <> 'information_schema') +
                              (SELECT count(*) FROM pg_namespace WHERE nspname !~ '^pg_'
                               AND nspname NOT IN ('public', 'information_schema')) +
                              (SELECT count(*) FROM pg_extension WHERE extname <> 'plpgsql')
                              + (SELECT count(*) FROM pg_type t JOIN pg_namespace n ON n.oid=t.typnamespace
                                 WHERE n.nspname !~ '^pg_' AND n.nspname <> 'information_schema')
                              + (SELECT count(*) FROM pg_largeobject_metadata)
                              + (SELECT count(*) FROM pg_event_trigger)
                              + (SELECT count(*) FROM pg_subscription)
                        """)
                        objects += cursor.fetchone()[0]
            result["user_objects"] = objects
            result["fresh_cluster"] = (not result["in_recovery"]
                                       and not result["application_databases"]
                                       and not result["custom_roles"] and not objects
                                       and not tablespaces and not existing_slots)
        except (psycopg2.Error, ValueError):
            # Offline or unreadable never means empty. An already configured
            # standby can still be identified from its control/config files.
            result["fresh_cluster"] = False
            command = ["/usr/lib/postgresql/{}/bin/postgres".format(args.version),
                       "-D", str(args.data_dir), "-C", "primary_conninfo", "-c",
                       "config_file={}/postgresql.conf".format(args.config_dir)]
            config = run(command, False)
            if config.returncode == 0:
                try:
                    conninfo = parse_dsn(config.stdout.strip())
                except psycopg2.Error:
                    conninfo = {}
    result["matches_primary"] = (
        result["system_identifier"] == args.primary_system_id
        and (args.data_dir / "standby.signal").is_file()
        and (not result["online"] or result["in_recovery"])
        and conninfo.get("host") == args.primary_host
        and conninfo.get("user") == args.primary_user
        and int(conninfo.get("port", 5432)) == args.port)
    return result


def write_marker(args, phase):
    value = {"data_dir": str(args.data_dir), "stage_dir": str(args.stage_dir),
             "archive_dir": str(args.archive_dir), "primary_system_id": args.primary_system_id,
             "phase": phase}
    destination = marker_path(args)
    temporary = pathlib.Path(str(destination) + ".tmp")
    fd = os.open(str(temporary), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as output:
        json.dump(value, output)
        output.flush()
        os.fsync(output.fileno())
    os.replace(str(temporary), str(destination))


def validate_paths(args):
    data = args.data_dir
    if not data.is_absolute() or data == pathlib.Path("/") or data.name in ("", ".", ".."):
        raise RuntimeError("PGDATA must be an absolute cluster directory.")
    if str(data) != os.path.normpath(str(data)):
        raise RuntimeError("PGDATA must not contain relative path components.")
    for target in (data, args.stage_dir, args.archive_dir):
        if target.is_symlink():
            raise RuntimeError("Refusing a symlink as data, staging or archive directory.")
    if args.stage_dir != pathlib.Path(str(data) + ".replication-staging"):
        raise RuntimeError("The staging path must be PGDATA.replication-staging.")
    if args.archive_dir != pathlib.Path(str(data) + ".before-replication"):
        raise RuntimeError("The archive path must be PGDATA.before-replication.")


def bootstrap(args):
    validate_paths(args)
    with open(str(args.data_dir) + ".replication-bootstrap.lock", "a") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        bootstrap_locked(args)


def bootstrap_locked(args):
    marker = read_marker(args)
    if marker and (marker.get("stage_dir") != str(args.stage_dir)
                   or marker.get("archive_dir") != str(args.archive_dir)):
        raise RuntimeError("Bootstrap marker paths do not match the requested transaction.")

    if marker and marker.get("phase") == "copying":
        # A failed/interrupted transfer has not moved the original PGDATA.
        if args.stage_dir.exists():
            shutil.rmtree(str(args.stage_dir))
        marker_path(args).unlink()
        marker = None

    state = inspect_cluster(args)
    if state["matches_primary"]:
        # Covers an interruption just after the atomic directory permutation.
        if marker and not args.stage_dir.exists():
            marker_path(args).unlink()
        print("BOOTSTRAP_UNCHANGED")
        return

    if not marker:
        if not (state["fresh_cluster"] or args.allow_reseed == "yes"):
            raise RuntimeError("Existing data was not proven empty; explicit reseed authorization is required.")
        if args.archive_dir.exists():
            raise RuntimeError("PGDATA.before-replication already exists; preserve or move that archive first.")
        if args.stage_dir.exists():
            raise RuntimeError("Unmanaged staging directory exists; refusing to remove it.")
        account = pwd.getpwnam("postgres")
        args.stage_dir.mkdir(mode=0o700)
        os.chown(str(args.stage_dir), account.pw_uid, account.pw_gid)
        write_marker(args, "copying")
        try:
            with postgres_identity():
                run(["/usr/lib/postgresql/{}/bin/pg_basebackup".format(args.version),
                     "--dbname", args.conninfo, "--pgdata", str(args.stage_dir),
                     "--write-recovery-conf", "--wal-method=stream", "--checkpoint=fast",
                     "--slot", args.slot, "--no-password"])
        except Exception:
            # Only this role's staged copy is disposable. Never delete or
            # rename the old cluster after a failed network transfer.
            if args.stage_dir.exists():
                shutil.rmtree(str(args.stage_dir))
            marker_path(args).unlink()
            raise
        write_marker(args, "ready")

    with postgres_identity():
        staged_id = control_system_id(args.stage_dir, args.version)
    if staged_id != args.primary_system_id or not (args.stage_dir / "standby.signal").is_file():
        raise RuntimeError("The staged copy is not a standby of the expected primary.")
    # Do not overwrite an earlier preserved cluster, including on retries.
    if args.data_dir.exists() and args.archive_dir.exists():
        raise RuntimeError("Both PGDATA and its archive exist; refusing to overwrite either.")
    write_marker(args, "switching")
    stopped = run(["pg_ctlcluster", "--mode", "fast", args.version, "main", "stop"], False)
    if stopped.returncode not in (0, 2):
        raise RuntimeError("Could not stop the old PostgreSQL cluster; no data directory was moved.")
    if args.data_dir.exists():
        os.rename(str(args.data_dir), str(args.archive_dir))
    try:
        os.rename(str(args.stage_dir), str(args.data_dir))
    except Exception:
        if not args.data_dir.exists() and args.archive_dir.exists():
            os.rename(str(args.archive_dir), str(args.data_dir))
        raise
    marker_path(args).unlink()
    print("BOOTSTRAP_CHANGED")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("inspect", "bootstrap"))
    parser.add_argument("--data-dir", type=pathlib.Path, required=True)
    parser.add_argument("--config-dir", type=pathlib.Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--primary-host", required=True)
    parser.add_argument("--primary-user", required=True)
    parser.add_argument("--primary-system-id", required=True)
    parser.add_argument("--stage-dir", type=pathlib.Path)
    parser.add_argument("--archive-dir", type=pathlib.Path)
    parser.add_argument("--conninfo")
    parser.add_argument("--slot")
    parser.add_argument("--allow-reseed", choices=("yes", "no"), default="no")
    args = parser.parse_args()
    if args.action == "inspect":
        print(json.dumps(inspect_cluster(args)))
    else:
        if not all((args.stage_dir, args.archive_dir, args.conninfo, args.slot)):
            parser.error("bootstrap requires staging/archive paths, conninfo and a slot")
        bootstrap(args)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print("Replica operation refused: {}".format(error), file=sys.stderr)
        sys.exit(1)
