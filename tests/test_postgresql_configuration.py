"""Verification locale de la topologie et des configurations Ansible.

Lancer : python3 -m unittest discover -s tests -v
Les fichiers vault et les variables d'environnement de production ne sont
jamais charges. Aucune connexion aux machines de l'inventaire n'est ouverte.
"""

import atexit
import copy
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest

# Ansible initialise son repertoire temporaire pendant son import.
_ANSIBLE_TEMP = tempfile.mkdtemp(prefix="odoo14-ansible-tests-")
os.environ["ANSIBLE_LOCAL_TEMP"] = _ANSIBLE_TEMP
atexit.register(shutil.rmtree, _ANSIBLE_TEMP, ignore_errors=True)

from ansible.inventory.manager import InventoryManager
from ansible.parsing.dataloader import DataLoader
from ansible.template import Templar


ROOT = Path(__file__).resolve().parents[1]


def yaml_file(relative):
    return DataLoader().load_from_file(str(ROOT / relative))


def inventory_variables():
    loader = DataLoader()
    inventory = InventoryManager(loader=loader, sources=[str(ROOT / "inventory.yaml")])
    return {
        "groups": {
            name: [host.name for host in group.get_hosts()]
            for name, group in inventory.groups.items()
        },
        "hostvars": {name: host.get_vars() for name, host in inventory.hosts.items()},
    }


def variables_for(host="odoodb1"):
    variables = {}
    for relative in (
        "roles/pg_server/defaults/main.yml",
        "roles/pg_replication/defaults/main.yml",
        "group_vars/all/vars.yml",
        "group_vars/db_containers/vars.yml",
    ):
        variables.update(yaml_file(relative))
    variables.update(inventory_variables())
    variables.update(variables["hostvars"][host])
    variables.update(inventory_hostname=host, ansible_managed="Ansible test")
    # Secret synthetique uniquement, aucune ouverture du vault.
    variables["vault_pg_replication_password"] = "test:password\\with:separators"
    return variables


def render(value, variables):
    return Templar(loader=DataLoader(), variables=variables).template(value)


def template(relative, variables):
    # Comme l'action ansible.builtin.template 2.10, qui ne pretraite pas les
    # backslashes des fichiers Jinja (contrairement aux variables YAML).
    return Templar(loader=DataLoader(), variables=variables).do_template(
        (ROOT / relative).read_text(), escape_backslashes=False
    )


def config_parameters(content):
    parameters = {}
    for line in content.splitlines():
        if line.strip() and not line.lstrip().startswith("#") and "=" in line:
            name, value = line.split("=", 1)
            parameters[name.strip()] = value.strip().strip("'")
    return parameters


def pgpass_fields(line):
    """Lire le format documente de .pgpass, y compris ':' et '\\' echappes."""
    fields, field, escaped = [], [], False
    for char in line.rstrip("\n"):
        if escaped:
            field.append(char)
            escaped = False
        elif char == "\\":
            escaped = True
        elif char == ":":
            fields.append("".join(field))
            field = []
        else:
            field.append(char)
    if escaped:
        raise ValueError("Echappement incomplet")
    return fields + ["".join(field)]


class TopologyTests(unittest.TestCase):
    def test_inventory_and_lxc_addresses_agree(self):
        variables = variables_for()
        self.assertEqual(variables["groups"]["db_primary"], ["odoodb1"])
        self.assertEqual(variables["groups"]["db_replicas"], ["odoodb2", "odoodb3"])
        expected = {
            "odoodb1": ("192.168.33.156", "192.168.33.21"),
            "odoodb2": ("192.168.33.157", "192.168.33.22"),
            "odoodb3": ("192.168.33.158", "168.168.33.23"),
        }
        for host, (container_ip, physical_ip) in expected.items():
            with self.subTest(host=host):
                hostvars = variables["hostvars"][host]
                self.assertEqual(hostvars["ansible_host"], container_ip)
                self.assertEqual(hostvars["lxc_host"], physical_ip)
                physical_vars = yaml_file("host_vars/" + physical_ip + ".yml")
                self.assertEqual(physical_vars["ct_ip"], container_ip)
                self.assertEqual(physical_vars["lxc_container_name"], "devpg15")
        self.assertEqual(render("{{ odoo_db_host }}", variables), expected["odoodb1"][0])

    def topology_is_valid(self, variables):
        variables = dict(variables, pg_ha_enabled=False)
        preflight = yaml_file("playbooks/ansi_replication_manuelle.yaml")[0]["tasks"]
        for task in preflight:
            conditions = task.get("ansible.builtin.assert", {}).get("that", [])
            if isinstance(conditions, str):
                conditions = [conditions]
            if any("vault_" in condition for condition in conditions):
                continue
            for condition in conditions:
                if not render("{{ (" + condition + ") | bool }}", variables):
                    return False
        return True

    def test_topology_preflight_rejects_miswired_clusters(self):
        good = variables_for()
        self.assertTrue(self.topology_is_valid(good))
        for case in ("no_primary", "two_primaries", "overlap", "unclassified", "duplicate_ip", "wrong_endpoint"):
            variables = copy.deepcopy(good)
            groups = variables["groups"]
            if case == "no_primary":
                groups["db_primary"] = []
            elif case == "two_primaries":
                groups["db_primary"].append("odoodb2")
            elif case == "overlap":
                groups["db_replicas"].append("odoodb1")
            elif case == "unclassified":
                groups["db_replicas"].pop()
            elif case == "duplicate_ip":
                variables["hostvars"]["odoodb3"]["ansible_host"] = variables["hostvars"]["odoodb2"]["ansible_host"]
            else:
                variables["odoo_db_host"] = "192.168.96.150"
            with self.subTest(case=case):
                self.assertFalse(self.topology_is_valid(variables))


class PostgreSQLConfigurationTests(unittest.TestCase):
    def test_replication_play_is_independent_of_previous_role_defaults(self):
        # Chaque play recharge ses variables : pg_server/defaults n'est pas
        # accessible au play suivant qui configure tous les replicas.
        variables = {}
        for relative in ("roles/pg_replication/defaults/main.yml", "group_vars/all/vars.yml", "group_vars/db_containers/vars.yml"):
            variables.update(yaml_file(relative))
        variables.update(inventory_variables())
        variables.update(variables["hostvars"]["odoodb2"])
        variables.update(
            inventory_hostname="odoodb2", ansible_managed="Ansible test",
            vault_pg_replication_password="synthetic-password",
            _pg_replication_host="192.168.33.156",
            _pg_replication_primary="odoodb1",
        )
        variables["hostvars"]["odoodb1"]["pg_replication_primary_settings"] = {
            "max_connections": 200, "max_worker_processes": 8,
            "max_wal_senders": 10, "max_prepared_transactions": 0,
            "max_locks_per_transaction": 64,
        }
        self.assertEqual(int(render("{{ pg_port }}", variables)), 5432)
        self.assertEqual(render("{{ pg_conf_dir }}", variables), "/etc/postgresql/15/main")
        self.assertEqual(render("{{ pg_data_dir }}", variables), "/var/lib/postgresql/15/main")
        self.assertEqual(pgpass_fields(template("roles/pg_replication/templates/pgpass.j2", variables))[1], "5432")
        parameters = config_parameters(template("roles/pg_replication/templates/replica.conf.j2", variables))
        self.assertEqual(parameters["port"], "5432")
        self.assertEqual(parameters["listen_addresses"], "192.168.33.157,localhost")

    def test_primary_hba_grants_replication_only_to_declared_standbys(self):
        variables = variables_for()
        rendered = template("roles/pg_server/templates/pg_hba.conf.j2", variables)
        rows = [shlex.split(line) for line in rendered.splitlines() if line.strip() and not line.startswith("#")]
        network_rows = [row for row in rows if row[0].startswith("host")]
        self.assertTrue(all(row[3].endswith(("/32", "/128")) for row in network_rows))
        replication = [row for row in network_rows if row[1] == "replication"]
        self.assertEqual(
            {(row[2], row[3], row[4]) for row in replication},
            {
                ("replicator", "192.168.33.157/32", "scram-sha-256"),
                ("replicator", "192.168.33.158/32", "scram-sha-256"),
            },
        )
        self.assertFalse(any(row[1] == "all" and row[2] == "replicator" for row in network_rows))

    def test_primary_has_capacity_and_bounded_wal_retention(self):
        variables = variables_for()
        parameters = config_parameters(template("roles/pg_server/templates/10-prosys.conf.j2", variables))
        self.assertEqual(parameters["wal_level"], "replica")
        self.assertGreaterEqual(int(parameters["max_wal_senders"]), len(variables["groups"]["db_replicas"]) + 2)
        self.assertGreaterEqual(int(parameters["max_replication_slots"]), len(variables["groups"]["db_replicas"]))
        self.assertNotEqual(parameters["max_slot_wal_keep_size"], "-1")
        self.assertEqual(parameters["synchronous_standby_names"], "")

    def test_each_server_listens_on_its_own_address(self):
        for host in variables_for()["groups"]["db_containers"]:
            variables = variables_for(host)
            variables["_pg_replication_primary"] = "odoodb1"
            variables["hostvars"]["odoodb1"]["pg_replication_primary_settings"] = {
                "max_connections": 200, "max_worker_processes": 12,
                "max_wal_senders": 14, "max_prepared_transactions": 2,
                "max_locks_per_transaction": 96,
            }
            path = "roles/pg_server/templates/10-prosys.conf.j2" if host == "odoodb1" else "roles/pg_replication/templates/replica.conf.j2"
            parameters = config_parameters(template(path, variables))
            addresses = {address.strip() for address in parameters["listen_addresses"].split(",")}
            with self.subTest(host=host):
                self.assertEqual(addresses, {variables["ansible_host"], "localhost"})
                self.assertEqual(parameters["hot_standby"], "on")

    def test_replica_recovery_capacity_matches_nondefault_primary(self):
        variables = variables_for("odoodb2")
        variables["_pg_replication_primary"] = "odoodb1"
        capacities = {"max_connections": 257, "max_worker_processes": 12,
                      "max_wal_senders": 14, "max_prepared_transactions": 2,
                      "max_locks_per_transaction": 96}
        variables["hostvars"]["odoodb1"]["pg_replication_primary_settings"] = capacities
        parameters = config_parameters(template("roles/pg_replication/templates/replica.conf.j2", variables))
        for name, value in capacities.items():
            with self.subTest(parameter=name):
                self.assertGreaterEqual(int(parameters[name]), value)

    def test_pgpass_preserves_colons_and_backslashes_in_password(self):
        variables = variables_for("odoodb2")
        variables["_pg_replication_host"] = render("{{ odoo_db_host }}", variables)
        result = template("roles/pg_replication/templates/pgpass.j2", variables)
        self.assertEqual(len(result.splitlines()), 1)
        self.assertEqual(pgpass_fields(result), ["192.168.33.156", "5432", "replication", "replicator", variables["vault_pg_replication_password"]])


class NetworkGuardTests(unittest.TestCase):
    def test_real_gateway_guard_accepts_only_matching_subnet(self):
        tasks = yaml_file("roles/lxc_lan/tasks/main.yaml")
        guard = next(task for task in tasks if "ansible.builtin.command" in task and "sous-reseau" in task["name"])
        script = guard["ansible.builtin.command"]["argv"][2]
        cases = (
            ("192.168.96.156/24", "192.168.96.1", True),
            ("192.168.96.156/24", "192.168.33.1", False),
            ("192.168.96.156/16", "192.168.33.1", True),
            ("192.168.33.157/24", "192.168.33.1", True),
            ("168.168.33.158/24", "168.168.33.1", True),
            ("192.168.33.157/999", "192.168.33.1", False),
        )
        for address, gateway, accepted in cases:
            with self.subTest(address=address, gateway=gateway):
                result = subprocess.run([sys.executable, "-c", script, address, gateway], capture_output=True, text=True, check=False)
                self.assertEqual(result.returncode == 0, accepted)


if __name__ == "__main__":
    unittest.main()
