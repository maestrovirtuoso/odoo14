# Domaine `odoo` — la pile applicative

La base, l'application, son stockage et ses sessions. L'ordre du tableau est
celui dans lequel ces rôles doivent s'appliquer.

| Rôle | Cible | Responsabilité |
|---|---|---|
| `pg_server` | `db_containers` | PostgreSQL 15 partagé, `pg_hba`, rôle SQL, base |
| `odoo14` | `odoo_containers` | Paquet, venv, `odoo.conf`, unité systemd — service laissé **arrêté** |
| `odoo_dbinit` | `odoo_primary` | Initialise le registre, pilote `ir_attachment.location` |
| `odoo_uid` | `odoo_containers` | Aligne l'UID/GID du compte `odoo` (105/112) |
| `odoo_filestore` | `gluster_bricks` | Bind du filestore de l'hôte dans le conteneur |
| `odoo_sessions` | `odoo_containers` | Sessions communes, prérequis du répartiteur |

Deux points qui surprennent :

- `odoo_filestore` tourne sur les **hôtes**, pas dans les conteneurs : un bind
  LXC se déclare côté hôte. Il est rangé ici parce que ce qu'il produit est le
  stockage d'Odoo.
- `odoo_dbinit` ne vise que `odoo_primary`. La base est partagée : la jouer sur
  les trois nœuds, c'est trois initialisations concurrentes du même registre.

`odoo14` tire `base_debian` et `python38` par son `meta/main.yml` ;
`pg_server` tire `base_debian`. Voir `roles/socle/`.

Carte complète : [../README.md](../README.md).
