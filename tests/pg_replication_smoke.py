#!/usr/bin/env python3
"""Trois PostgreSQL ephemeres : SCRAM, slots, ecriture, lecture seule, reprise.

Lancer : python3 tests/pg_replication_smoke.py
Selectionne PostgreSQL 15 si disponible, sinon 14. Uniquement /tmp, ports
loopback ephemeres et pg_ctl sur ses propres PGDATA ; aucun service systeme.
Ce test valide les templates du projet avec le moteur local disponible,
pas le deploiement Debian/LXC ni les commandes pg_ctlcluster du role.
"""

import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time

import psycopg2
from psycopg2.extensions import make_dsn

from test_postgresql_configuration import template, variables_for


def run(command):
    result = subprocess.run([str(part) for part in command], capture_output=True, text=True, timeout=60)
    if result.returncode:
        raise RuntimeError("{} failed: {}".format(command[0], result.stderr.strip()))
    return result.stdout


def reserve_ports(count):
    reservations = []
    try:
        for unused in range(count):
            sock = socket.socket()
            sock.bind(("127.0.0.1", 0))
            reservations.append(sock)
        return [sock.getsockname()[1] for sock in reservations]
    finally:
        for sock in reservations:
            sock.close()


def query(socket_dir, port, sql, parameters=None):
    with psycopg2.connect(host=str(socket_dir), port=port, user="postgres", dbname="postgres") as connection:
        connection.autocommit = True
        with connection.cursor() as cursor:
            cursor.execute(sql, parameters)
            return cursor.fetchall() if cursor.description else []


def wait_until(predicate, description):
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        try:
            if predicate():
                return
        except psycopg2.Error:
            pass
        time.sleep(0.1)
    raise AssertionError("Timeout: " + description)


def main():
    binaries = next((Path("/usr/lib/postgresql") / version / "bin" for version in ("15", "14")
                     if (Path("/usr/lib/postgresql") / version / "bin/postgres").is_file()), None)
    if binaries is None:
        raise SystemExit("PostgreSQL 15 ou 14 est requis ; aucune installation n'est effectuee.")
    version = run([binaries / "postgres", "--version"]).strip()
    print("Moteur local : " + version, flush=True)
    active = []
    with tempfile.TemporaryDirectory(prefix="odoo14-pg-smoke-") as directory:
        temporary = Path(directory)
        ports = reserve_ports(3)
        clusters = [temporary / ("node" + str(index)) for index in range(3)]
        sockets = [temporary / ("socket" + str(index)) for index in range(3)]
        for socket_dir in sockets:
            socket_dir.mkdir()

        def start(index):
            active.append(index)
            try:
                run([binaries / "pg_ctl", "-D", clusters[index], "-l", temporary / ("node%d.log" % index), "-w", "start"])
            except Exception:
                log = temporary / ("node%d.log" % index)
                if log.exists():
                    print(log.read_text(), flush=True)
                raise

        try:
            run([binaries / "initdb", "-D", clusters[0], "-U", "postgres", "--auth-local=trust", "--auth-host=scram-sha-256", "--no-locale"])
            primary = variables_for()
            primary.update(ansible_host="127.0.0.1", pg_listen_addresses="127.0.0.1,localhost", pg_port=ports[0],
                           pg_max_wal_senders=14, pg_max_replication_slots=4, pg_shared_buffers="16MB",
                           odoo_client_ips=[], pg_backup_client_ips=[], pg_replication_client_ips=["127.0.0.1"])
            conf = template("roles/pg_server/templates/10-prosys.conf.j2", primary)
            conf += "\nmax_worker_processes=12\nmax_prepared_transactions=2\nmax_locks_per_transaction=96\n"
            conf += "unix_socket_directories='{}'\n".format(sockets[0])
            (clusters[0] / "conf.d").mkdir()
            (clusters[0] / "conf.d/10-prosys.conf").write_text(conf)
            with (clusters[0] / "postgresql.conf").open("a") as output:
                output.write("\ninclude_dir='conf.d'\n")
            hba = template("roles/pg_server/templates/pg_hba.conf.j2", primary)
            # Peer dans le deploiement ; trust uniquement sur notre socket
            # /tmp prive pour le compte du processus de test non-root.
            hba = hba.replace("peer", "trust")
            (clusters[0] / "pg_hba.conf").write_text(hba)
            start(0)
            password = primary["vault_pg_replication_password"]
            query(sockets[0], ports[0], "CREATE ROLE replicator LOGIN REPLICATION PASSWORD %s", (password,))
            capacities = {name: int(query(sockets[0], ports[0], "SHOW " + name)[0][0])
                          for name in ("max_connections", "max_worker_processes", "max_wal_senders", "max_prepared_transactions", "max_locks_per_transaction")}

            for index in (1, 2):
                slot = "prosys_odoodb" + str(index + 1)
                query(sockets[0], ports[0], "SELECT pg_create_physical_replication_slot(%s, true)", (slot,))
                variables = variables_for("odoodb" + str(index + 1))
                variables.update(ansible_host="127.0.0.1", pg_port=ports[0], _pg_replication_host="127.0.0.1",
                                 _pg_replication_primary="odoodb1", odoo_client_ips=[])
                passfile = temporary / ("replica%d.pgpass" % index)
                passfile.write_text(template("roles/pg_replication/templates/pgpass.j2", variables))
                passfile.chmod(0o600)
                conninfo = make_dsn(host="127.0.0.1", port=ports[0], user="replicator", passfile=str(passfile), application_name="odoodb" + str(index + 1))
                run([binaries / "pg_basebackup", "--dbname", conninfo, "--pgdata", clusters[index], "--write-recovery-conf", "--wal-method=stream", "--checkpoint=fast", "--slot", slot, "--no-password"])
                variables["pg_port"] = ports[index]
                variables["hostvars"]["odoodb1"]["pg_replication_primary_settings"] = capacities
                replica_config = template("roles/pg_replication/templates/replica.conf.j2", variables)
                replica_config += "\nunix_socket_directories='{}'\n".format(sockets[index])
                (clusters[index] / "conf.d/99-prosys-replica.conf").write_text(replica_config)
                (clusters[index] / "pg_hba.conf").write_text(template("roles/pg_replication/templates/pg_hba.conf.j2", variables).replace("peer", "trust"))
                start(index)

            wait_until(lambda: query(sockets[0], ports[0], "SELECT count(*) FROM pg_stat_replication WHERE state='streaming'")[0][0] == 2, "deux replicas en streaming")
            query(sockets[0], ports[0], "CREATE TABLE replication_probe(id int PRIMARY KEY, value text)")
            query(sockets[0], ports[0], "INSERT INTO replication_probe VALUES (1, 'replicated')")
            for index in (1, 2):
                wait_until(lambda: query(sockets[index], ports[index], "SELECT value FROM replication_probe WHERE id=1") == [("replicated",)], "ecriture visible sur replica " + str(index))
                assert query(sockets[index], ports[index], "SELECT pg_is_in_recovery()")[0][0]
                try:
                    query(sockets[index], ports[index], "INSERT INTO replication_probe VALUES (2, 'forbidden')")
                except psycopg2.errors.ReadOnlySqlTransaction:
                    pass
                else:
                    raise AssertionError("Une replique accepte les ecritures")
                for name, value in capacities.items():
                    assert int(query(sockets[index], ports[index], "SHOW " + name)[0][0]) >= value

            # Un simple redemarrage conserve l'identite et reprend le slot.
            run([binaries / "pg_ctl", "-D", clusters[2], "-m", "fast", "-w", "stop"])
            active.remove(2)
            query(sockets[0], ports[0], "INSERT INTO replication_probe VALUES (2, 'after-restart')")
            start(2)
            wait_until(lambda: query(sockets[2], ports[2], "SELECT value FROM replication_probe WHERE id=2") == [("after-restart",)], "rattrapage apres redemarrage")
            print("OK : 2 replicas streaming, mot de passe SCRAM avec ':'/'\\', slots actifs, ecritures repliquees, lecture seule et reprise apres redemarrage.", flush=True)
        finally:
            for index in reversed(active):
                subprocess.run([str(binaries / "pg_ctl"), "-D", str(clusters[index]), "-m", "immediate", "-w", "stop"], capture_output=True, text=True, timeout=30)


if __name__ == "__main__":
    main()
