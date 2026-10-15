#!/usr/bin/python3
"""Check ownership/data before handing PostgreSQL to Patroni.

This tool never deletes PostgreSQL data. A proven empty Debian cluster is
archived; explicit adoption keeps an existing cluster in its current place.
"""
import argparse
import contextlib
import json
import os
import pathlib
import pwd
import re
import shutil
import subprocess
import sys

import psycopg2


@contextlib.contextmanager
def postgres_identity():
    if os.geteuid() != 0:
        yield
        return
    account = pwd.getpwnam("postgres")
    uid, gid = os.geteuid(), os.getegid()
    os.setegid(account.pw_gid)
    os.seteuid(account.pw_uid)
    try:
        yield
    finally:
        os.seteuid(uid)
        os.setegid(gid)


def load_marker(args):
    marker = args.marker
    if not marker.exists():
        return None
    owner = 0 if os.geteuid() == 0 else os.geteuid()
    if marker.is_symlink() or marker.stat().st_uid != owner or marker.stat().st_mode & 0o077:
        raise RuntimeError("The Patroni ownership marker has unsafe ownership or permissions.")
    value = json.loads(marker.read_text())
    for field, expected in (("scope", args.scope), ("name", args.name),
                            ("data_dir", str(args.data_dir)), ("config_dir", str(args.config_dir))):
        if value.get(field) != expected:
            raise RuntimeError("The ownership marker belongs to a different cluster/node/path.")
    return value


def save_marker(args, mode, phase):
    value = {"scope": args.scope, "name": args.name,
             "data_dir": str(args.data_dir), "config_dir": str(args.config_dir),
             "mode": mode, "phase": phase}
    temporary = pathlib.Path(str(args.marker) + ".tmp")
    fd = os.open(str(temporary), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as output:
        json.dump(value, output)
        output.flush()
        os.fsync(output.fileno())
    os.replace(str(temporary), str(args.marker))


def inspect(args):
    marker = load_marker(args)
    result = {"managed": marker is not None, "empty": False, "online": False,
              "physical_slots": [],
              "system_identifier": None, "in_recovery": None,
              "phase": marker.get("phase") if marker else None}
    if not args.data_dir.exists() or not any(args.data_dir.iterdir()):
        result["empty"] = True
        return result
    if args.data_dir.is_symlink():
        raise RuntimeError("Refusing a symbolic link as PGDATA.")
    version_file = args.data_dir / "PG_VERSION"
    if not version_file.is_file() or version_file.read_text().strip() != args.version:
        raise RuntimeError("PGDATA is not a valid cluster of the requested PostgreSQL version.")
    with postgres_identity():
        control = subprocess.run(["/usr/lib/postgresql/{}/bin/pg_controldata".format(args.version),
                                  str(args.data_dir)], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 text=True, env=dict(os.environ, LC_ALL="C"))
        found = re.search(r"^Database system identifier:\s*(\d+)$", control.stdout, re.MULTILINE)
        if control.returncode == 0 and found:
            result["system_identifier"] = found.group(1)
        try:
            connection = psycopg2.connect(dbname="postgres", user="postgres", port=args.port,
                                          host="/var/run/postgresql", connect_timeout=5)
            try:
                with connection.cursor() as cursor:
                    cursor.execute("SELECT current_setting('data_directory'), pg_is_in_recovery(), "
                                   "system_identifier::text FROM pg_control_system()")
                    directory, recovery, identifier = cursor.fetchone()
                    if pathlib.Path(directory).resolve() != args.data_dir.resolve():
                        raise RuntimeError("The local PostgreSQL port belongs to a different PGDATA.")
                    result.update(online=True, in_recovery=recovery, system_identifier=identifier)
                    cursor.execute("SELECT count(*) FROM pg_database WHERE datname NOT IN "
                                   "('postgres', 'template0', 'template1')")
                    databases = cursor.fetchone()[0]
                    cursor.execute("SELECT count(*) FROM pg_roles WHERE rolname <> 'postgres' AND rolname !~ '^pg_'")
                    roles = cursor.fetchone()[0]
                    cursor.execute("SELECT count(*) FROM pg_tablespace WHERE spcname NOT IN ('pg_default', 'pg_global')")
                    tablespaces = cursor.fetchone()[0]
                    cursor.execute("SELECT count(*) FROM pg_replication_slots")
                    slots = cursor.fetchone()[0]
                    cursor.execute("SELECT slot_name FROM pg_replication_slots WHERE slot_type='physical'")
                    result["physical_slots"] = [row[0] for row in cursor.fetchall()]
            finally:
                connection.close()
            objects = 0
            for database in ("postgres", "template1"):
                connection = psycopg2.connect(dbname=database, user="postgres", port=args.port,
                                              host="/var/run/postgresql", connect_timeout=5)
                try:
                    with connection.cursor() as cursor:
                        cursor.execute("""
                            SELECT
                              (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
                               WHERE n.nspname !~ '^pg_' AND n.nspname <> 'information_schema') +
                              (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                               WHERE n.nspname !~ '^pg_' AND n.nspname <> 'information_schema') +
                              (SELECT count(*) FROM pg_namespace WHERE nspname !~ '^pg_'
                               AND nspname NOT IN ('public', 'information_schema')) +
                              (SELECT count(*) FROM pg_extension WHERE extname <> 'plpgsql') +
                              (SELECT count(*) FROM pg_type t JOIN pg_namespace n ON n.oid=t.typnamespace
                               WHERE n.nspname !~ '^pg_' AND n.nspname <> 'information_schema') +
                              (SELECT count(*) FROM pg_largeobject_metadata) +
                              (SELECT count(*) FROM pg_event_trigger) +
                              (SELECT count(*) FROM pg_subscription)
                        """)
                        objects += cursor.fetchone()[0]
                finally:
                    connection.close()
            result["empty"] = not (recovery or databases or roles or tablespaces or slots or objects)
        except psycopg2.Error:
            # A cluster installed in this invocation, with policy_rc_d=101,
            # has not been started by the package manager. An older offline
            # cluster is never assumed empty from its file names.
            result["empty"] = args.new_install == "yes" and not marker
    return result


def prepare(args):
    marker = load_marker(args)
    state = inspect(args)
    if marker and marker.get("phase") in ("ready", "active"):
        print("HANDOFF_UNCHANGED")
        return
    if not marker:
        if not state["empty"] and args.allow_adopt != "yes":
            raise RuntimeError("Existing PostgreSQL data requires explicit adoption; nothing was moved.")
        mode = "fresh" if state["empty"] else "adopt"
        if args.archive_dir.exists() or args.config_archive_dir.exists():
            raise RuntimeError("An old before-patroni archive already exists; preserve/move it first.")
        save_marker(args, mode, "prepared")
    else:
        mode = marker["mode"]
    # The operator can restore the complete old Debian configuration too.
    if args.config_dir.exists() and not args.config_archive_dir.exists():
        shutil.copytree(str(args.config_dir), str(args.config_archive_dir))
    # Inspect first while peer SQL is available, then stop the old manager.
    # A retry uses our prepared marker and never touches a running Patroni.
    stopped = subprocess.run(["pg_ctlcluster", "--mode", "fast", args.version, "main", "stop"],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if stopped.returncode not in (0, 2):
        raise RuntimeError("The old PostgreSQL cluster could not be stopped; no data directory was moved.")
    if mode == "fresh" and args.data_dir.exists():
        if args.archive_dir.exists():
            raise RuntimeError("Both PGDATA and its archive exist; neither will be overwritten.")
        os.rename(str(args.data_dir), str(args.archive_dir))
    save_marker(args, mode, "ready")
    print("HANDOFF_CHANGED")


def activate(args):
    marker = load_marker(args)
    if not marker or marker.get("phase") not in ("ready", "active"):
        raise RuntimeError("The handoff must be complete before marking Patroni active.")
    if marker.get("phase") == "active":
        print("ACTIVATION_UNCHANGED")
        return
    save_marker(args, marker["mode"], "active")
    print("ACTIVATION_CHANGED")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("inspect", "prepare", "activate"))
    parser.add_argument("--data-dir", type=pathlib.Path, required=True)
    parser.add_argument("--config-dir", type=pathlib.Path, required=True)
    parser.add_argument("--marker", type=pathlib.Path, required=True)
    parser.add_argument("--archive-dir", type=pathlib.Path, required=True)
    parser.add_argument("--config-archive-dir", type=pathlib.Path, required=True)
    parser.add_argument("--scope", required=True)
    parser.add_argument("--name", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--new-install", choices=("yes", "no"), default="no")
    parser.add_argument("--allow-adopt", choices=("yes", "no"), default="no")
    args = parser.parse_args()
    for path in (args.data_dir, args.config_dir, args.archive_dir, args.config_archive_dir):
        if not path.is_absolute() or path == pathlib.Path("/") or path.is_symlink():
            raise RuntimeError("Data/configuration paths must be absolute and must not be symlinks.")
    if args.archive_dir != pathlib.Path(str(args.data_dir) + ".before-patroni"):
        raise RuntimeError("The data archive must be PGDATA.before-patroni.")
    if args.config_archive_dir != pathlib.Path(str(args.config_dir) + ".before-patroni"):
        raise RuntimeError("The configuration archive must be CONFIGDIR.before-patroni.")
    if args.action == "inspect":
        print(json.dumps(inspect(args)))
    elif args.action == "prepare":
        prepare(args)
    else:
        activate(args)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print("Patroni handoff refused: {}".format(error), file=sys.stderr)
        sys.exit(1)
