# Domaine `socle` — préparation du système

Ce que toute machine doit avoir avant qu'Odoo ou PostgreSQL n'y soit installé.
Rien ici ne connaît Odoo.

| Rôle | Cible | Appelé par |
|---|---|---|
| `chrony` | hôtes (`gluster_servers`) | `ansi_odoo.yaml`, en **premier play** |
| `base_debian` | conteneurs | dépendance `meta` d'`odoo14` et de `pg_server` |
| `python38` | conteneurs Odoo | dépendance `meta` d'`odoo14` |

`base_debian` et `python38` ne sont appelés par aucun playbook : ils arrivent
par les `meta/main.yml` des rôles qui en dépendent. Chercher leur nom dans
`playbooks/` ne donne donc rien — voir `roles/odoo/odoo14/meta/main.yml`.

`chrony` passe avant le réseau et non après : une horloge fausse fait échouer
`apt-get update` dans les conteneurs (« Release file is not valid yet ») et
fait arbitrer GlusterFS sur des horodatages incohérents.

Carte complète : [../README.md](../README.md).
