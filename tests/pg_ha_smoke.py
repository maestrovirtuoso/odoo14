#!/usr/bin/env python3
"""Patroni/etcd : trois noeuds ephemeres, bascule et retour de l'ancien leader.

PATRONI_BIN=/tmp/venv/bin/patroni ETCD_BIN=/tmp/etcd python3 tests/pg_ha_smoke.py
Dependencies deja disponibles uniquement ; aucune installation. Tous les
processus/configurations/donnees restent sous /tmp et sur la boucle locale.
PostgreSQL 15 est prefere ; 14 est utilise si 15 n'est pas installe.
"""

import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

import psycopg2
import yaml

from test_postgresql_configuration import template
from test_postgresql_ha_configuration import ha_variables


HTTP = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def request(url):
    try:
        with HTTP.open(url, timeout=2) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as error:
        return error.code, None


def wait_until(predicate, description, timeout=90):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            result = predicate()
            if result:
                return result
        except (OSError, ValueError, psycopg2.Error):
            pass
        time.sleep(0.25)
    raise AssertionError("Timeout: " + description)


def run(command, check=True):
    result = subprocess.run([str(part) for part in command], capture_output=True, text=True, timeout=30)
    if check and result.returncode:
        raise RuntimeError("{}: {}".format(command[0], result.stderr.strip()))
    return result


def ports_for(addresses, count):
    reservations, ports = [], []
    try:
        for unused in range(count):
            first = socket.socket()
            first.bind((addresses[0], 0))
            reservations.append(first)
            port = first.getsockname()[1]
            for address in addresses[1:]:
                peer = socket.socket()
                peer.bind((address, port))
                reservations.append(peer)
            ports.append(port)
        return ports
    finally:
        for reservation in reservations:
            reservation.close()


def main():
    patroni = os.environ.get("PATRONI_BIN") or shutil.which("patroni")
    etcd = os.environ.get("ETCD_BIN") or shutil.which("etcd")
    if not patroni or not etcd:
        raise SystemExit("Renseigner PATRONI_BIN et ETCD_BIN vers les executables du test.")
    binaries = next((Path("/usr/lib/postgresql") / version / "bin" for version in ("15", "14")
                     if (Path("/usr/lib/postgresql") / version / "bin/postgres").is_file()), None)
    if binaries is None:
        raise SystemExit("PostgreSQL 15 ou 14 est requis ; aucune installation n'est effectuee.")
    version = binaries.parent.name
    print("Moteur local : " + run([binaries / "postgres", "--version"]).stdout.strip(), flush=True)
    addresses = ["127.0.0.11", "127.0.0.12", "127.0.0.13"]
    sql_port, rest_port, client_port, peer_port = ports_for(addresses, 4)
    nodes = ["odoodb1", "odoodb2", "odoodb3"]
    processes, logs = {}, []
    with tempfile.TemporaryDirectory(prefix="odoo14-pg-ha-smoke-") as directory:
        temporary = Path(directory)
        env = dict(os.environ, NO_PROXY=",".join(addresses + ["127.0.0.1", "localhost"]),
                   no_proxy=",".join(addresses + ["127.0.0.1", "localhost"]))
        data_dirs, patroni_files, etcd_files, credentials = {}, {}, {}, {}

        def start(kind, node):
            executable, configuration = (patroni, patroni_files[node]) if kind == "patroni" else (etcd, etcd_files[node])
            log = (temporary / (kind + "-" + node + ".log")).open("a")
            logs.append(log)
            command = [executable, str(configuration)] if kind == "patroni" else [executable, "--config-file=" + str(configuration)]
            processes[(kind, node)] = subprocess.Popen(command, cwd=temporary, env=env, stdout=log, stderr=subprocess.STDOUT)

        def stop(kind, node, abrupt=False):
            process = processes.pop((kind, node), None)
            if process and process.poll() is None:
                process.kill() if abrupt else process.terminate()
                try:
                    process.wait(timeout=20)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)

        def sql(node, statement, parameters=None):
            index = nodes.index(node)
            with psycopg2.connect(host=addresses[index], port=sql_port, dbname="postgres", user="postgres", password=credentials[node], connect_timeout=3) as connection:
                connection.autocommit = True
                with connection.cursor() as cursor:
                    cursor.execute(statement, parameters)
                    return cursor.fetchall() if cursor.description else []

        def primary(candidates):
            leaders = []
            for node in candidates:
                try:
                    status, unused = request("http://%s:%s/primary" % (addresses[nodes.index(node)], rest_port))
                    if status == 200:
                        leaders.append(node)
                except OSError:
                    pass
            return leaders[0] if len(leaders) == 1 else None

        def replicas_ready(leader, candidates):
            for node in candidates:
                if node != leader:
                    status, unused = request("http://%s:%s/replica" % (addresses[nodes.index(node)], rest_port))
                    if status != 200:
                        return False
            return True

        try:
            for index, node in enumerate(nodes):
                node_dir = temporary / node
                node_dir.mkdir()
                for name in ("config", "socket", "etcd"):
                    (node_dir / name).mkdir()
                variables = ha_variables(node)
                variables["hostvars"] = {name: dict(values) for name, values in variables["hostvars"].items()}
                for member, address in zip(nodes, addresses):
                    variables["hostvars"][member]["ansible_host"] = address
                variables.update(ansible_host=addresses[index], pg_version=version, pg_port=sql_port,
                                 pg_data_dir=str(node_dir / "data"), pg_ha_pg_config_dir=str(node_dir / "config"),
                                 pg_ha_rest_port=rest_port, pg_ha_etcd_client_port=client_port,
                                 pg_ha_etcd_peer_port=peer_port, pg_ha_etcd_data_dir=str(node_dir / "etcd"),
                                 pg_ha_scope=temporary.name, pg_ha_etcd_token=temporary.name,
                                 pg_ha_ttl=10, pg_ha_loop_wait=1, pg_ha_retry_timeout=3,
                                 odoo_client_ips=[], pg_backup_client_ips=[])
                config = yaml.safe_load(template("roles/pg_ha/templates/patroni.yml.j2", variables))
                config["postgresql"]["pgpass"] = str(node_dir / "pgpass")
                config["postgresql"]["parameters"]["unix_socket_directories"] = str(node_dir / "socket")
                config["bootstrap"]["dcs"]["postgresql"]["parameters"]["shared_buffers"] = "16MB"
                # Le processus de test est un utilisateur ordinaire : trust
                # seulement sur la socket /tmp privee ; reseau toujours SCRAM.
                config["postgresql"]["pg_hba"] = [line.replace(" peer", " trust") if line.startswith("local ") else line for line in config["postgresql"]["pg_hba"]]
                # Meme repertoire externe et fichiers initiaux que le role.
                (node_dir / "config/postgresql.conf").write_text("# Configuration geree par Patroni.\n")
                (node_dir / "config/pg_hba.conf").write_text("\n".join(config["postgresql"]["pg_hba"]) + "\n")
                patroni_files[node] = node_dir / "patroni.yml"
                patroni_files[node].write_text(yaml.safe_dump(config))
                patroni_files[node].chmod(0o600)
                credentials[node] = config["postgresql"]["authentication"]["superuser"]["password"]
                etcd_files[node] = node_dir / "etcd.yml"
                etcd_files[node].write_text(template("roles/pg_ha/templates/etcd.yml.j2", variables))
                data_dirs[node] = node_dir / "data"

            for node in nodes:
                start("etcd", node)
            wait_until(lambda: all(request("http://%s:%s/health" % (address, client_port))[0] == 200 for address in addresses), "quorum etcd")
            start("patroni", nodes[0])
            first = wait_until(lambda: primary([nodes[0]]), "bootstrap du primaire initial")
            for node in nodes[1:]:
                start("patroni", node)
            wait_until(lambda: replicas_ready(first, nodes), "deux replicas Patroni")
            sql(first, "CREATE TABLE ha_probe(id int PRIMARY KEY, value text)")
            sql(first, "INSERT INTO ha_probe VALUES (1, 'before-failover')")
            for node in nodes:
                wait_until(lambda node=node: sql(node, "SELECT value FROM ha_probe WHERE id=1") == [("before-failover",)], "premiere ecriture sur " + node)
                if node != first:
                    try:
                        sql(node, "INSERT INTO ha_probe VALUES (99, 'forbidden')")
                    except psycopg2.errors.ReadOnlySqlTransaction:
                        pass
                    else:
                        raise AssertionError("Un replica accepte des ecritures")

            print("OK : quorum etcd, primaire unique, deux replicas et premiere ecriture repliquee.", flush=True)
            # Simuler la perte d'un serveur : Patroni, PostgreSQL et son etcd.
            stop("patroni", first, abrupt=True)
            run([binaries / "pg_ctl", "-D", data_dirs[first], "-m", "immediate", "-w", "stop"], check=False)
            stop("etcd", first, abrupt=True)
            survivors = [node for node in nodes if node != first]
            elected = wait_until(lambda: primary(survivors), "election apres perte du primaire")
            if elected == first:
                raise AssertionError("Aucune nouvelle election")
            wait_until(lambda: replicas_ready(elected, survivors), "suivi du nouveau primaire")
            sql(elected, "INSERT INTO ha_probe VALUES (2, 'after-failover')")
            for node in survivors:
                wait_until(lambda node=node: sql(node, "SELECT count(*) FROM ha_probe")[0][0] == 2, "nouvelle ecriture sur " + node)
            print("OK : bascule automatique %s -> %s et nouvelle ecriture repliquee." % (first, elected), flush=True)

            start("etcd", first)
            start("patroni", first)
            wait_until(lambda: replicas_ready(elected, nodes), "retour de l'ancien primaire comme replica")
            wait_until(lambda: sql(first, "SELECT value FROM ha_probe WHERE id=2") == [("after-failover",)], "rattrapage de l'ancien primaire")
            if primary(nodes) != elected:
                raise AssertionError("Le primaire a change pendant la reintegration")
            print("OK : ancien primaire reintegre en lecture seule, deux replicas suivent le leader elu.", flush=True)
        except Exception:
            for node in nodes:
                path = temporary / ("patroni-" + node + ".log")
                if path.exists():
                    print("Journal " + node + ":\n" + path.read_text()[-5000:], flush=True)
            raise
        finally:
            for kind, node in list(processes):
                if kind == "patroni":
                    stop(kind, node)
            for node, data_dir in data_dirs.items():
                if (data_dir / "postmaster.pid").exists():
                    run([binaries / "pg_ctl", "-D", data_dir, "-m", "immediate", "-w", "stop"], check=False)
            for kind, node in list(processes):
                stop(kind, node)
            for log in logs:
                log.close()


if __name__ == "__main__":
    main()
