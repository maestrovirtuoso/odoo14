"""Verifie les chemins Ansible actif/inactif sans executer de module distant."""

import unittest

# Initialise ANSIBLE_LOCAL_TEMP sous /tmp avant tout import Ansible.
from test_postgresql_configuration import (
    config_parameters, inventory_variables, render, template, yaml_file,
)
from ansible.parsing.dataloader import DataLoader
from ansible.playbook.conditional import Conditional
from ansible.template import Templar


FALSE_VALUES = (False, "false", "False", "no", "0", 0)
TRUE_VALUES = (True, "true", "True", "yes", "1", 1)


def permitted(conditions, variables):
    loader = DataLoader()
    conditional = Conditional(loader=loader)
    conditional.when = conditions if isinstance(conditions, list) else [conditions]
    return conditional.evaluate_conditional(Templar(loader=loader, variables=variables), variables)


def task_runs(task, variables):
    return permitted(task.get("when", []), variables)


def selected_lb_tasks(variables):
    """Developpe les vraies branches include_tasks selon leurs conditions."""
    selected = []
    for task in yaml_file("roles/odoo_lb/tasks/main.yaml"):
        if task_runs(task, variables):
            include = task.get("ansible.builtin.include_tasks")
            selected.extend(yaml_file("roles/odoo_lb/tasks/" + include) if include else [task])
    return selected


def service_calls(variables):
    calls = []
    for task in selected_lb_tasks(variables):
        if "ansible.builtin.systemd" in task:
            for item in render(task.get("loop", [None]), variables):
                local = dict(variables, item=item)
                if task_runs(task, local):
                    calls.append(render(task["ansible.builtin.systemd"], local))
    return calls


class DisabledLoadBalancerTests(unittest.TestCase):
    def test_common_default_disables_lb_and_odoo_proxy_mode(self):
        common = yaml_file("group_vars/all/vars.yml")
        self.assertIs(common["lb_enabled"], False)
        self.assertFalse(render("{{ odoo_proxy_mode }}", common))
        self.assertIs(yaml_file("roles/odoo_lb/defaults/main.yml")["lb_enabled"], False)

    def test_disabled_path_never_reaches_install_or_configuration_tasks(self):
        for value in FALSE_VALUES:
            variables = {"lb_enabled": value, "ansible_facts": {"services": {}}}
            with self.subTest(flag=value):
                tasks = selected_lb_tasks(variables)
                self.assertTrue(any("ansible.builtin.service_facts" in task for task in tasks))
                for task in tasks:
                    modules = [key for key in task if key.startswith("ansible.")]
                    self.assertTrue(modules)
                    self.assertTrue(set(modules) <= {"ansible.builtin.service_facts", "ansible.builtin.systemd"})
                self.assertEqual(service_calls(variables), [])
        for value in TRUE_VALUES:
            with self.subTest(flag=value):
                tasks = selected_lb_tasks({"lb_enabled": value})
                self.assertTrue(any("ansible.builtin.dnf" in task for task in tasks))
                self.assertFalse(any("ansible.builtin.service_facts" in task for task in tasks))

    def test_only_existing_services_are_stopped_and_keepalived_goes_first(self):
        cases = (
            ({}, []),
            ({"nginx.service": {"state": "running"}}, []),
            ({"haproxy.service": {"state": "running"}}, ["haproxy"]),
            ({"keepalived.service": {"state": "stopped"}}, ["keepalived"]),
            ({"haproxy.service": {}, "keepalived.service": {}}, ["keepalived", "haproxy"]),
            ({"haproxy": {}, "keepalived": {}}, ["keepalived", "haproxy"]),
        )
        for services, expected in cases:
            for flag in FALSE_VALUES:
                with self.subTest(services=list(services), flag=flag):
                    calls = service_calls({"lb_enabled": flag, "ansible_facts": {"services": services}})
                    self.assertEqual([call["name"] for call in calls], expected)
                    self.assertTrue(all(call["state"] == "stopped" and call["enabled"] is False for call in calls))

    def test_handlers_cannot_restart_services_while_disabled(self):
        handlers = yaml_file("roles/odoo_lb/handlers/main.yaml")
        self.assertEqual(len(handlers), 2)
        for handler in handlers:
            for value in FALSE_VALUES + TRUE_VALUES:
                with self.subTest(handler=handler["name"], flag=value):
                    self.assertEqual(task_runs(handler, {"lb_enabled": value}), value in TRUE_VALUES)

    def test_diagnostics_and_failover_have_guards_at_both_entry_points(self):
        plays = yaml_file("playbooks/ansi_repartiteur.yaml")
        imports = {
            task["ansible.builtin.import_role"]["tasks_from"]: task
            for play in plays for task in play.get("tasks", [])
            if task.get("ansible.builtin.import_role", {}).get("name") == "odoo_lb"
        }
        self.assertTrue({"preflight", "verif", "bascule"} <= set(imports))
        for entry in ("preflight", "verif", "bascule"):
            tasks = yaml_file("roles/odoo_lb/tasks/" + entry + ".yaml")
            assertion = tasks[0]["ansible.builtin.assert"]["that"]
            for value in FALSE_VALUES + TRUE_VALUES:
                variables = {"lb_enabled": value}
                with self.subTest(entry=entry, flag=value):
                    self.assertEqual(task_runs(imports[entry], variables), value in TRUE_VALUES)
                    # Une invocation directe tasks_from est aussi arretee
                    # avant tout ping, lecture VIP ou arret de service.
                    self.assertEqual(permitted(assertion, variables), value in TRUE_VALUES)

    def test_sessions_are_skipped_without_lb(self):
        sessions = [role for play in yaml_file("playbooks/ansi_repartiteur.yaml")
                    for role in play.get("roles", [])
                    if isinstance(role, dict) and role.get("role") == "odoo_sessions"]
        self.assertEqual(len(sessions), 1)
        for value in FALSE_VALUES + TRUE_VALUES:
            with self.subTest(flag=value):
                self.assertEqual(task_runs(sessions[0], {"lb_enabled": value}), value in TRUE_VALUES)

    def test_main_disables_existing_services_before_lxc_network_changes(self):
        plays = yaml_file("playbooks/ansi_odoo.yaml")
        stops = [(index, play, task) for index, play in enumerate(plays) for task in play.get("tasks", [])
                 if task.get("ansible.builtin.import_role", {}).get("name") == "odoo_lb"
                 and task["ansible.builtin.import_role"].get("tasks_from") == "disable"]
        network = [index for index, play in enumerate(plays) if "lxc_lan" in play.get("roles", [])]
        self.assertEqual(len(stops), 1)
        self.assertTrue(network)
        index, play, task = stops[0]
        self.assertEqual(play["hosts"], "lb_hosts")
        self.assertLess(index, min(network))
        for value in FALSE_VALUES + TRUE_VALUES:
            with self.subTest(flag=value):
                self.assertEqual(task_runs(task, {"lb_enabled": value}), value in FALSE_VALUES)

    def test_rendered_odoo_proxy_mode_follows_boolean_and_cli_string_flags(self):
        variables = {}
        for relative in ("roles/odoo14/defaults/main.yml", "group_vars/all/vars.yml", "group_vars/odoo_containers/vars.yml"):
            variables.update(yaml_file(relative))
        variables.update(inventory_variables())
        variables.update(vault_odoo_admin_password="synthetic-admin", vault_odoo_db_password="synthetic-db", ansible_managed="Ansible test")
        for value in FALSE_VALUES + TRUE_VALUES:
            with self.subTest(flag=value):
                local = dict(variables, lb_enabled=value)
                parameters = config_parameters(template("roles/odoo14/templates/odoo.conf.j2", local))
                self.assertEqual(parameters["proxy_mode"], "True" if value in TRUE_VALUES else "False")


if __name__ == "__main__":
    unittest.main()
