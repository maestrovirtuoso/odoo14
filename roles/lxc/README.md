# Domaine `lxc` — cycle de vie des conteneurs

Tout s'exécute **sur les hôtes** (`gluster_servers`), jamais dans les
conteneurs : ces rôles sont ce qui fait exister les conteneurs et les rend
joignables.

| Rôle | Responsabilité | Appelé par |
|---|---|---|
| `install` | Installe LXC, crée les conteneurs Debian 12 | `ansi2-snapchot.yaml` |
| `lxc_lan` | Expose les conteneurs sur le LAN, amorce leur accès SSH | `ansi_odoo.yaml`, `reseau-lxc.yaml` |
| `cleanup` | Désinstalle LXC et retire ce que les rôles ont posé | `nettoyage.yaml` |

`cleanup` (ici) nettoie les **hôtes** ; `odoo_cleanup`, dans
`roles/exploitation/`, remet un **conteneur** à plat sans le détruire. Les deux
noms se ressemblent, leur portée n'a rien de commun.

Fichiers internes, importés par `tasks/main.yaml` et non appelables de
l'extérieur : `install/tasks/reap_stale.yaml`,
`lxc_lan/tasks/undo_routed.yaml`.

Carte complète : [../README.md](../README.md).
