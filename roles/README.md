# Les rôles, par domaine

Les rôles ne sont plus à plat : ils sont rangés dans quatre domaines, lisibles
dans l'ordre où le déploiement les traverse.

```text
roles/
├── socle/          préparer le système, hôtes comme conteneurs
├── lxc/            créer, exposer et désinstaller les conteneurs
├── odoo/           la pile applicative : base, Odoo, filestore, sessions
└── exploitation/   répartiteur, sauvegarde, migration, remise à plat
```

Un rôle appartient au domaine qui décrit **ce qu'il produit**, pas la machine
sur laquelle il tourne : `odoo_filestore` s'exécute sur les hôtes, mais ce
qu'il produit est le stockage d'Odoo, donc il est dans `odoo/`.

## Le piège à connaître avant tout

**Ansible ne descend pas dans les sous-dossiers de `roles/` tout seul.** Seuls
les chemins listés dans `roles_path` d'[ansible.cfg](../ansible.cfg) sont
fouillés :

```ini
roles_path = ./roles/socle:./roles/lxc:./roles/odoo:./roles/exploitation
```

Conséquences pratiques :

- **Créer un domaine sans l'ajouter à cette ligne** rend ses rôles invisibles.
  L'erreur est `the role 'x' was not found`, et elle ne dit pas pourquoi.
- Les playbooks et les `meta/main.yml` continuent d'appeler les rôles **par
  leur nom seul** (`- role: odoo14`), jamais par leur chemin. Déplacer un rôle
  d'un domaine à l'autre ne casse donc aucun appel.
- Les noms doivent rester **uniques sur l'ensemble des domaines** : à nom
  égal, le premier chemin de la liste gagne, silencieusement.
- Les chemins sont relatifs au **répertoire courant**, pas à `ansible.cfg` :
  lancer `ansible-playbook` depuis la racine du dépôt.

## Carte des rôles

Cible = groupe d'inventaire sur lequel les playbooks le jouent.

### `socle/` — préparation du système

| Rôle | Cible | Responsabilité |
|---|---|---|
| `base_debian` | conteneurs | Sources APT bookworm cohérentes, réparation dpkg, réalignement des versions. Appelé en **dépendance** `meta`, pas depuis un playbook. |
| `python38` | conteneurs Odoo | Compile CPython 3.8.20 sous `/opt/python3.8` — Odoo 14 ne tourne pas sur le Python 3.11 de bookworm. Dépendance `meta` d'`odoo14`. |
| `chrony` | `gluster_servers` | Synchronise l'horloge des hôtes. **Avant tout le reste** : une horloge fausse fait échouer `apt` dans les conteneurs. |

### `lxc/` — cycle de vie des conteneurs

| Rôle | Cible | Responsabilité |
|---|---|---|
| `install` | `gluster_servers` | Installe LXC et crée les conteneurs Debian 12. |
| `lxc_lan` | `gluster_servers` | Expose les conteneurs sur le LAN et amorce leur accès SSH. |
| `cleanup` | `gluster_servers` | Désinstalle LXC et retire ce que les rôles ont posé sur les hôtes. |

### `odoo/` — la pile applicative

| Rôle | Cible | Responsabilité |
|---|---|---|
| `pg_server` | `db_containers` | PostgreSQL 15 partagé, `pg_hba`, rôle SQL, base. |
| `odoo14` | `odoo_containers` | Paquet, venv, `odoo.conf`, fragment systemd. Laisse le service **arrêté**. |
| `odoo_dbinit` | `odoo_primary` | Initialise le registre et pilote `ir_attachment.location`. Le **nœud primaire seul**. |
| `odoo_uid` | `odoo_containers` | Aligne l'UID/GID du compte `odoo` (105/112) entre les nœuds. |
| `odoo_filestore` | `gluster_bricks` | Branche le filestore du conteneur sur le volume de l'hôte (bind LXC). |
| `odoo_sessions` | `odoo_containers` | Sessions communes aux instances, prérequis du répartiteur. |

### `exploitation/` — service, données, reprise

| Rôle | Cible | Responsabilité |
|---|---|---|
| `odoo_lb` | `lb_hosts` | HAProxy + keepalived, VIP `.160`. |
| `odoo_backup` | `backup_host` | Service planifié, sauvegarde et rapatriement des archives. |
| `odoo_migration` | plusieurs | Les 12 étapes de la migration du filestore, **une par point d'entrée**. |
| `odoo_cleanup` | `odoo_containers` | Répare APT, ou remet le conteneur à plat avec `-e full_reset=true`. |

## Rôles à plusieurs points d'entrée

C'est ce qui se perd le plus vite : un fichier sous `tasks/` n'est pas
forcément un détail interne, c'est parfois **l'interface publique du rôle**.
Deux cas à ne pas confondre.

### Points d'entrée publics — appelés avec `tasks_from`

```yaml
- ansible.builtin.import_role:
    name: odoo_lb
    tasks_from: preflight
```

| Rôle | Points d'entrée | `main` ? |
|---|---|---|
| `exploitation/odoo_lb` | `preflight`, `verif`, `bascule` | oui — pose HAProxy/keepalived |
| `exploitation/odoo_backup` | `sauvegarder`, `rapatrier` | oui — installe le service planifié |
| `exploitation/odoo_migration` | `preflight_hotes`, `preflight_uid`, `preflight_base`, `sauvegarde_base`, `sauvegarde_filestore`, `arreter`, `attendre_conteneurs`, `droits`, `fusion`, `bilan`, `demarrer`, `verif` | **non** — échoue exprès |

`odoo_migration` n'a volontairement aucun comportement par défaut : le mettre
dans une section `roles:` lève une erreur explicite plutôt que de ne rien
faire. La section `roles:` n'accepte pas `tasks_from` ; ces rôles s'appellent
donc par `import_role`.

### Fichiers internes — importés par `main`, jamais appelés de l'extérieur

| Fichier | Importé par |
|---|---|
| `lxc/install/tasks/reap_stale.yaml` | `install` |
| `lxc/lxc_lan/tasks/undo_routed.yaml` | `lxc_lan` (sous le drapeau `lxc_undo_routed`) |
| `odoo/odoo14/tasks/purge_replication.yaml` | `odoo14` |
| `odoo/pg_server/tasks/purge_replication.yaml` | `pg_server` |

## Quel playbook appelle quel rôle

Index inverse : partir du playbook pour trouver le rôle.

| Playbook | Rôles, dans l'ordre |
|---|---|
| `ansi2-snapchot.yaml` | `install` |
| `ansi_odoo.yaml` | `chrony` → `lxc_lan` → `pg_server` → `odoo14` → `odoo_dbinit` |
| `ansi_syncro.yaml` | `odoo_migration` (12 entrées) avec `odoo_uid`, `odoo_filestore`, `odoo_dbinit` |
| `ansi_sauvegarde.yaml` | `odoo_backup` (`main`, `sauvegarder`, `rapatrier`) |
| `ansi_repartiteur.yaml` | `odoo_lb:preflight` → `odoo_sessions` → `odoo_lb` → `odoo_lb:verif` → `odoo_lb:bascule` |
| `reseau-lxc.yaml` | `lxc_lan` |
| `nettoyage_odoo.yaml` | `odoo_cleanup` |
| `nettoyage.yaml` | `cleanup` |

Les dépendances `meta` n'apparaissent pas ci-dessus : `odoo14` tire
`base_debian` et `python38`, `pg_server` tire `base_debian`.

## Où écrire une valeur

Dans l'ordre de priorité croissante — la dernière gagne :

| Emplacement | Pour quoi |
|---|---|
| `roles/<domaine>/<rôle>/defaults/main.yml` | La valeur par défaut du rôle, celle qui marche sans rien surcharger |
| `group_vars/<groupe>/vars.yml` | Ce qui dépend du rôle de la machine dans l'architecture |
| `host_vars/<ip>.yml` | Ce qui est propre à une machine |
| `group_vars/all/vault.yml` | Les secrets, chiffrés — jamais dans `defaults/` |
| `-e` en ligne de commande | Les drapeaux ponctuels (`full_reset`, `lxc_undo_routed`) |

Un rôle ne doit pas lire une variable qu'aucun de ces emplacements ne définit
sans `| default(...)` : l'erreur arrive alors en cours de play, sur une
machine à moitié configurée.

## Ajouter ou déplacer un rôle

1. Le poser dans le domaine qui décrit ce qu'il produit.
2. Si c'est un **nouveau domaine**, ajouter son chemin à `roles_path` dans
   `ansible.cfg` — sinon il est introuvable.
3. Convention Ansible : `tasks/main.yaml` comme entrée, `defaults/main.yml`
   pour les valeurs surchargeables, `handlers/`, `templates/`, `files/`,
   `meta/main.yml` pour les dépendances.
4. Un parcours spécialisé va dans `tasks/<nom>.yaml` et s'appelle par
   `import_role` + `tasks_from` — ne pas recopier ses tâches dans un playbook.
5. Le déclarer dans les tableaux ci-dessus et dans
   [docs/STRUCTURE-PROJET.md](../docs/STRUCTURE-PROJET.md).
6. Avant de **renommer** un rôle, chercher son nom dans `playbooks/`, dans les
   `meta/main.yml` et dans `docs/` : les appels se font par nom, aucun outil ne
   signale un appel resté en arrière.

## Réserve sur cette arborescence

Un `roles/` imbriqué n'est pas la convention Ansible : `ansible-galaxy`,
`ansible-lint` et `molecule` supposent des rôles directement sous `roles/`.
Ici c'est sans effet — [requirements.yml](../requirements.yml) ne déclare que
des collections, et aucun rôle n'est installé depuis Galaxy. Si un rôle
externe devait l'être un jour, lui réserver un domaine (`roles/externes/`) et
l'ajouter à `roles_path`, pour qu'il ne se mélange pas aux rôles du dépôt.
