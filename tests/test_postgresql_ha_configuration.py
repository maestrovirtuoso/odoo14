"""Rendu des configurations Patroni/etcd avec des secrets synthetiques."""

import shlex
import unittest

import yaml

from test_postgresql_configuration import inventory_variables, render, template, yaml_file
from test_load_balancer_disabled import FALSE_VALUES, TRUE_VALUES, permitted, task_runs


def ha_variables(host):
    variables = {}
    # Aucun default du role pg_server : Patroni fonctionne dans son play.
    for relative in ("roles/pg_ha/defaults/main.yml", "group_vars/all/vars.yml", "group_vars/db_containers/vars.yml"):
        variables.update(yaml_file(relative))
    variables.update(inventory_variables())
    variables.update(variables["hostvars"][host])
    variables.update(
        inventory_hostname=host, ansible_managed="Ansible test",
        vault_pg_replication_password="synthetic:replication\\password\"",
        vault_pg_patroni_superuser_password="synthetic:postgres\\password\"",
        vault_pg_patroni_rest_password="synthetic:REST\\password\"",
    )
    return variables


def patroni_config(variables):
    return yaml.safe_load(template("roles/pg_ha/templates/patroni.yml.j2", variables))


class PatroniEtcdConfigurationTests(unittest.TestCase):
    def test_each_member_advertises_its_own_sql_rest_and_etcd_addresses(self):
        inventory = inventory_variables()
        nodes = inventory["groups"]["db_containers"]
        expected_hosts = [inventory["hostvars"][node]["ansible_host"] for node in nodes]
        self.assertEqual(len(set(expected_hosts)), 3)
        self.assertEqual(set(expected_hosts), {"192.168.33.156", "192.168.33.157", "192.168.33.158"})
        for node in nodes:
            variables = ha_variables(node)
            own_ip = variables["ansible_host"]
            sql_port = render("{{ pg_port }}", variables)
            rest_port = variables["pg_ha_rest_port"]
            config = patroni_config(variables)
            with self.subTest(node=node):
                self.assertEqual(config["name"], node)
                self.assertEqual(config["postgresql"]["connect_address"], "%s:%s" % (own_ip, sql_port))
                self.assertEqual(config["postgresql"]["listen"], "%s,127.0.0.1:%s" % (own_ip, sql_port))
                self.assertEqual(config["restapi"]["listen"], "%s:%s" % (own_ip, rest_port))
                self.assertEqual(config["restapi"]["connect_address"], "%s:%s" % (own_ip, rest_port))
                self.assertEqual(set(config["etcd3"]["hosts"]), {"%s:%s" % (address, variables["pg_ha_etcd_client_port"]) for address in expected_hosts})
                self.assertEqual(config["postgresql"]["data_dir"], render("{{ pg_data_dir }}", variables))
                self.assertNotEqual(config["postgresql"]["config_dir"], render("{{ pg_conf_dir }}", variables))

    def test_etcd_peer_mapping_and_cluster_identity_agree_on_all_members(self):
        canonical = None
        for node in inventory_variables()["groups"]["db_containers"]:
            variables = ha_variables(node)
            config = yaml.safe_load(template("roles/pg_ha/templates/etcd.yml.j2", variables))
            peers = dict(part.split("=", 1) for part in config["initial-cluster"].split(","))
            expected = {member: "http://%s:%s" % (variables["hostvars"][member]["ansible_host"], variables["pg_ha_etcd_peer_port"])
                        for member in variables["groups"]["db_containers"]}
            with self.subTest(node=node):
                self.assertEqual(peers, expected)
                self.assertEqual(config["name"], node)
                self.assertEqual(config["listen-peer-urls"], expected[node])
                self.assertEqual(config["initial-advertise-peer-urls"], expected[node])
                self.assertEqual(config["listen-client-urls"], "http://%s:%s" % (variables["ansible_host"], variables["pg_ha_etcd_client_port"]))
                self.assertEqual(config["advertise-client-urls"], config["listen-client-urls"])
                self.assertIs(config["enable-v2"], False)
                self.assertNotEqual(config["data-dir"], render("{{ pg_data_dir }}", variables))
                identity = (config["initial-cluster-token"], config["initial-cluster"])
                if canonical is None:
                    canonical = identity
                self.assertEqual(identity, canonical)

    def test_every_member_can_become_primary_and_serve_both_followers(self):
        variables = ha_variables("odoodb1")
        config = patroni_config(variables)
        bootstrap = config["bootstrap"]["dcs"]
        postgres = bootstrap["postgresql"]
        parameters = postgres["parameters"]
        self.assertTrue(postgres["use_slots"])
        self.assertTrue(postgres["use_pg_rewind"])
        self.assertEqual(parameters["wal_level"], "replica")
        self.assertGreaterEqual(parameters["max_wal_senders"], 4)
        self.assertGreaterEqual(parameters["max_replication_slots"], 3)
        self.assertNotEqual(str(parameters["max_slot_wal_keep_size"]), "-1")
        self.assertLessEqual(bootstrap["loop_wait"] + 2 * bootstrap["retry_timeout"], bootstrap["ttl"])
        self.assertIn("data-checksums", config["bootstrap"]["initdb"])
        self.assertEqual(parameters["wal_log_hints"], "on")
        for node in variables["groups"]["db_containers"]:
            member = patroni_config(ha_variables(node))
            with self.subTest(node=node):
                self.assertFalse(member["tags"]["nofailover"])
                self.assertFalse(member["tags"]["clonefrom"])
                self.assertNotIn("replicatefrom", member["tags"])
                self.assertNotIn("primary_conninfo", member["postgresql"].get("parameters", {}))
                self.assertIs(member["postgresql"]["remove_data_directory_on_rewind_failure"], False)
                self.assertIs(member["postgresql"]["remove_data_directory_on_diverged_timelines"], False)

    def test_replication_and_rewind_authentication_allow_all_possible_leaders(self):
        variables = ha_variables("odoodb1")
        inline_rows = patroni_config(variables)["postgresql"]["pg_hba"]
        file_rows = [line for line in template("roles/pg_ha/templates/pg_hba.conf.j2", variables).splitlines()
                     if line.strip() and not line.lstrip().startswith("#")]
        self.assertEqual([shlex.split(line) for line in inline_rows], [shlex.split(line) for line in file_rows])
        rows = [shlex.split(line) for line in inline_rows]
        network = [row for row in rows if row[0] == "host"]
        addresses = {variables["hostvars"][node]["ansible_host"] + "/32" for node in variables["groups"]["db_containers"]}
        self.assertEqual({row[3] for row in network if row[1:3] == ["replication", variables["pg_replication_user"]]}, addresses)
        self.assertEqual({row[3] for row in network if row[1:3] == ["postgres", "postgres"]}, addresses)
        self.assertTrue(all(row[3].endswith(("/32", "/128")) for row in network))
        self.assertTrue(all(row[4] == "scram-sha-256" for row in network))

    def test_yaml_escaping_preserves_all_three_credentials(self):
        variables = ha_variables("odoodb2")
        config = patroni_config(variables)
        self.assertEqual(config["restapi"]["authentication"]["password"], variables["vault_pg_patroni_rest_password"])
        self.assertEqual(config["postgresql"]["authentication"]["superuser"]["password"], variables["vault_pg_patroni_superuser_password"])
        self.assertEqual(config["postgresql"]["authentication"]["replication"]["password"], variables["vault_pg_replication_password"])

    def test_patroni_service_owns_postgresql_without_load_balancer_dependencies(self):
        variables = ha_variables("odoodb1")
        service = template("roles/pg_ha/templates/patroni.service.j2", variables)
        self.assertIn("Conflicts=postgresql@15-main.service", service)
        self.assertIn("User=postgres", service)
        self.assertIn("KillMode=process", service)
        self.assertIn("ExecStart=/usr/bin/patroni " + variables["pg_ha_config_file"], service)
        self.assertNotIn("haproxy", service)
        self.assertNotIn("keepalived", service)


class HALeaderSelectionTests(unittest.TestCase):
    def test_sql_target_tracks_each_elected_leader_and_rejects_zero_or_two(self):
        tasks = yaml_file("playbooks/tasks/pg_ha_leader.yaml")
        fact = next(task["ansible.builtin.set_fact"]["_pg_ha_leaders"] for task in tasks if "_pg_ha_leaders" in task.get("ansible.builtin.set_fact", {}))
        guard = next(task["ansible.builtin.assert"]["that"] for task in tasks if task.get("ansible.builtin.assert", {}).get("that") == "_pg_ha_leaders | length == 1")
        group = next(task["ansible.builtin.add_host"] for task in tasks if "ansible.builtin.add_host" in task)
        inventory = inventory_variables()
        nodes = inventory["groups"]["db_containers"]
        for statuses in ((200, 503, 503), (503, 200, 503), (503, 503, 200), (503, 503, 503), (200, 200, 503)):
            variables = dict(inventory)
            variables["hostvars"] = {name: dict(values) for name, values in inventory["hostvars"].items()}
            for node, status in zip(nodes, statuses):
                variables["hostvars"][node].update(inventory_hostname=node, _pg_ha_primary_api={"status": status})
            leaders = render(fact, variables)
            variables["_pg_ha_leaders"] = leaders
            with self.subTest(statuses=statuses):
                self.assertEqual(permitted(guard, variables), statuses.count(200) == 1)
                if statuses.count(200) == 1:
                    self.assertEqual(render(group["name"], variables), nodes[statuses.index(200)])
                    self.assertEqual(group["groups"], "pg_ha_current_primary")

    def test_discovery_requires_all_members_and_uses_primary_rest_endpoint(self):
        tasks = yaml_file("playbooks/tasks/pg_ha_leader.yaml")
        inventory = inventory_variables()
        nodes = inventory["groups"]["db_containers"]
        guard = tasks[0]["ansible.builtin.assert"]["that"]
        self.assertTrue(permitted(guard, dict(inventory, ansible_play_hosts_all=nodes)))
        self.assertFalse(permitted(guard, dict(inventory, ansible_play_hosts_all=nodes[:2])))
        uri = next(task["ansible.builtin.uri"] for task in tasks if "ansible.builtin.uri" in task)
        self.assertEqual(render(uri["url"], {"ansible_host": "192.168.33.157"}), "http://192.168.33.157:8008/primary")
        self.assertIs(uri["use_proxy"], False)

    def test_ha_and_manual_dispatch_are_mutually_exclusive(self):
        dispatch = yaml_file("playbooks/ansi_replication.yaml")
        self.assertIs(yaml_file("group_vars/all/vars.yml")["pg_ha_enabled"], True)
        for value in FALSE_VALUES + TRUE_VALUES:
            selected = [task["ansible.builtin.import_playbook"] for task in dispatch if task_runs(task, {"pg_ha_enabled": value})]
            with self.subTest(flag=value):
                self.assertEqual(selected, ["ansi_postgresql_ha.yaml"] if value in TRUE_VALUES else ["ansi_replication_manuelle.yaml"])

    def test_old_roles_refuse_to_manage_a_patroni_cluster(self):
        for role in ("pg_server", "pg_replication"):
            guard = yaml_file("roles/" + role + "/tasks/main.yaml")[0]["ansible.builtin.assert"]["that"]
            for value in FALSE_VALUES + TRUE_VALUES:
                with self.subTest(role=role, flag=value):
                    self.assertEqual(permitted(guard, {"pg_ha_enabled": value}), value in FALSE_VALUES)

    def test_sql_provisioning_uses_elected_group_and_checks_recovery_before_writes(self):
        plays = yaml_file("playbooks/ansi_postgresql_ha.yaml")
        play = next(play for play in plays if play.get("hosts") == "pg_ha_current_primary")
        tasks = play["tasks"]
        sql_guard = next(task["ansible.builtin.assert"]["that"] for task in tasks if "ansible.builtin.assert" in task)
        self.assertTrue(permitted(sql_guard, {"_pg_ha_sql_mode": {"query_result": [{"in_recovery": False}]}}))
        self.assertFalse(permitted(sql_guard, {"_pg_ha_sql_mode": {"query_result": [{"in_recovery": True}]}}))
        guard_index = next(index for index, task in enumerate(tasks) if "ansible.builtin.assert" in task)
        for index, task in enumerate(tasks):
            if "community.postgresql.postgresql_user" in task or "community.postgresql.postgresql_db" in task:
                self.assertGreater(index, guard_index)
        self.assertFalse(any("pg_server" in item.get("roles", []) for item in plays))

    def test_manual_odoo_refresh_only_changes_db_host_after_primary_check(self):
        plays = yaml_file("playbooks/ansi_odoo_dbhost.yaml")
        self.assertEqual(len(plays), 1)
        play = plays[0]
        self.assertEqual(play["serial"], 1)
        self.assertFalse(play.get("roles"))
        tasks = play["tasks"]
        guard = next(task["ansible.builtin.assert"]["that"] for task in tasks if "ansible.builtin.assert" in task)
        for recovery in (True, False):
            self.assertEqual(permitted(guard, {"_odoo_new_pg": {"query_result": [{"in_recovery": recovery}]}}), not recovery)
        changes = [task for task in tasks if "ansible.builtin.lineinfile" in task]
        self.assertEqual(len(changes), 1)
        line = render(changes[0]["ansible.builtin.lineinfile"]["line"], {"odoo_db_host": "192.168.33.158"})
        self.assertEqual(line, "db_host = 192.168.33.158")
        self.assertIs(changes[0]["ansible.builtin.lineinfile"]["create"], False)
        self.assertTrue(changes[0].get("notify"))
        forbidden = {"community.postgresql.postgresql_db", "community.postgresql.postgresql_user", "ansible.builtin.command", "ansible.builtin.shell", "ansible.builtin.apt"}
        self.assertTrue(all(not (set(task) & forbidden) for task in tasks))

    def test_migration_snapshot_and_endpoint_check_use_the_current_primary(self):
        plays = yaml_file("playbooks/ansi_syncro.yaml")
        discovery = next(play for play in plays if any(task.get("ansible.builtin.import_tasks") == "tasks/pg_ha_leader.yaml" for task in play.get("tasks", [])))
        self.assertEqual(discovery["hosts"], "db_containers")
        guard = next(task["ansible.builtin.assert"]["that"] for task in discovery["tasks"] if "ansible.builtin.assert" in task)
        inventory = inventory_variables()
        variables = dict(inventory, groups=dict(inventory["groups"], pg_ha_current_primary=["odoodb2"]))
        variables["odoo_db_host"] = inventory["hostvars"]["odoodb1"]["ansible_host"]
        self.assertFalse(permitted(guard, variables))
        variables["odoo_db_host"] = inventory["hostvars"]["odoodb2"]["ansible_host"]
        self.assertTrue(permitted(guard, variables))
        snapshot = next(play for play in plays if any(task.get("ansible.builtin.import_role", {}).get("tasks_from") == "sauvegarde_base" for task in play.get("tasks", [])))
        self.assertEqual(snapshot["hosts"], "pg_ha_current_primary")
        recovery_guard = next(task["ansible.builtin.assert"]["that"] for task in snapshot["tasks"] if "ansible.builtin.assert" in task)
        self.assertFalse(permitted(recovery_guard, {"_migration_pg_mode": {"query_result": [{"in_recovery": True}]}}))
        self.assertTrue(permitted(recovery_guard, {"_migration_pg_mode": {"query_result": [{"in_recovery": False}]}}))


if __name__ == "__main__":
    unittest.main()
