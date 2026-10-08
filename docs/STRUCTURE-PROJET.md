# Structure du projet

Ce guide relie chaque playbook aux rôles qui portent sa logique. Les playbooks
restent des points d'entrée d'orchestration ; les rôles sont les modules
réutilisables qui appliquent une responsabilité sur leurs hôtes cibles.

Pour l'architecture effectivement déployée, consulter
[ARCHITECTURE.md](ARCHITECTURE.md). Pour l'ordre, les tags et les commandes,
consulter [EXPLICATION-DES-PLAYBOOKS.md](EXPLICATION-DES-PLAYBOOKS.md).

## Arborescence

```text
.
├── ansible.cfg                 Configuration Ansible et chemin des rôles
├── inventory.yaml              Groupes et connexions aux hôtes/containers
├── requirements.yml            Collections Ansible requises
├── common/group_vars/          Variables partagées pour les conteneurs LXC
├── group_vars/                 Variables par groupe, dont les secrets Vault
├── host_vars/                  Paramètres propres à chaque hôte
├── playbooks/                  Points d'entrée, ordre et sélection des cibles
├── roles/                      Modules Ansible, rangés par domaine
│   ├── README.md               Carte des rôles : cibles, entrées, index inverse
│   ├── socle/                  Préparer le système, hôtes comme conteneurs
│   ├── lxc/                    Créer, exposer et désinstaller les conteneurs
│   ├── odoo/                   Base, application, filestore, sessions
│   └── exploitation/           Répartiteur, sauvegarde, migration, remise à plat
└── docs/                       Architecture, procédures et guides
```

Les rôles sont rangés en quatre domaines, lisibles dans l'ordre où le
déploiement les traverse. **Ansible ne descend pas dans ces sous-dossiers de
lui-même** : chacun est déclaré dans `roles_path` d'`ansible.cfg`, et un
domaine ajouté sans cette ligne rend ses rôles introuvables. Les appels, eux,
se font toujours par le nom seul du rôle (`- role: odoo14`), jamais par son
chemin : déplacer un rôle d'un domaine à l'autre ne casse aucun appel.

Un rôle appartient au domaine qui décrit **ce qu'il produit**, pas la machine
sur laquelle il tourne : `odoo_filestore` s'exécute sur les hôtes, mais produit
le stockage d'Odoo, donc il est dans `odoo/`.

Le détail par rôle — cible, points d'entrée, index inverse playbook → rôle —
est dans [../roles/README.md](../roles/README.md), et chaque domaine porte son
propre `README.md`.

Chaque rôle suit la convention Ansible : `tasks/main.yaml` comme entrée
principale, `defaults/` pour les valeurs surchargeables, `handlers/` pour les
actions déclenchées par changement, `templates/` et `files/` pour ses artefacts.
Les rôles à plusieurs parcours exposent des fichiers sous `tasks/` et sont
appelés par `import_role` avec `tasks_from`.

## Playbooks et modules

| Playbook | Usage | Modules (rôles) |
|---|---|---|
| `ansi2-snapchot.yaml` | Créer les conteneurs LXC | `install` |
| `ansi_odoo.yaml` | Déploiement nominal, de l'horloge au démarrage Odoo | `chrony`, `lxc_lan`, `pg_server`, `odoo14`, `odoo_dbinit` |
| `ansi_syncro.yaml` | Préparer, migrer et vérifier le stockage des pièces jointes | `odoo_migration`, `odoo_uid`, `odoo_filestore`, `odoo_dbinit` |
| `ansi_sauvegarde.yaml` | Installer, lancer et rapatrier une sauvegarde | `odoo_backup` |
| `ansi_repartiteur.yaml` | Partager les sessions, déployer et vérifier la VIP | `odoo_sessions`, `odoo_lb` |
| `reseau-lxc.yaml` | Appliquer le réseau LXC seul | `lxc_lan` |
| `nettoyage_odoo.yaml` | Réparer APT ou réinitialiser les conteneurs Odoo | `odoo_cleanup` |
| `nettoyage.yaml` | Désinstaller LXC et nettoyer les hôtes | `cleanup` |

`ansi_odoo.yaml`, `ansi_syncro.yaml`, `ansi_sauvegarde.yaml` et
`ansi_repartiteur.yaml` sont des workflows composés : leur ordre est
significatif. Leurs playbooks définissent les frontières de phase et les cibles ;
les tâches concrètes restent dans les rôles.

## Responsabilités des rôles

| Domaine | Rôle | Responsabilité |
|---|---|---|
| `socle` | `chrony` | Synchroniser l'horloge des hôtes, avant tout le reste |
| `socle` | `base_debian`, `python38` | Sources APT cohérentes et CPython 3.8 ; appelés en dépendance `meta`, pas depuis un playbook |
| `lxc` | `install` | Installer LXC et créer les conteneurs Debian 12 |
| `lxc` | `lxc_lan` | Présenter les conteneurs sur le LAN et amorcer leur accès SSH |
| `lxc` | `cleanup` | Désinstaller LXC et nettoyer les hôtes |
| `odoo` | `pg_server` | Configurer PostgreSQL partagé et ses accès |
| `odoo` | `odoo14` | Installer et configurer Odoo dans les conteneurs, service laissé arrêté |
| `odoo` | `odoo_dbinit` | Initialiser la base et piloter le stockage des pièces jointes |
| `odoo` | `odoo_uid`, `odoo_filestore` | Aligner l'UID Odoo et brancher le filestore |
| `odoo` | `odoo_sessions` | Partager les sessions entre instances, prérequis du répartiteur |
| `exploitation` | `odoo_lb` | Configurer HAProxy/Keepalived et vérifier la VIP |
| `exploitation` | `odoo_backup` | Installer le service planifié, sauvegarder et rapatrier les archives |
| `exploitation` | `odoo_migration` | Préflight, sauvegarde temporaire, arrêt, migration, bilan et vérification |
| `exploitation` | `odoo_cleanup` | Réparer APT ou remettre un conteneur à plat |

`cleanup` nettoie les **hôtes**, `odoo_cleanup` remet un **conteneur** à plat :
les noms se ressemblent, les portées n'ont rien de commun.

## Règles de découpage

- Un playbook choisit les groupes, l'ordre des phases, les tags et les variables
  propres au workflow ; il ne contient pas de logique système détaillée.
- Un rôle possède un domaine et s'exécute sur un type de cible cohérent. Les
  tâches réutilisées par plusieurs workflows restent dans ce rôle.
- Un rôle va dans le domaine qui décrit ce qu'il **produit**, pas la machine sur
  laquelle il tourne.
- Un point d'entrée spécialisé reste dans `tasks/<nom>.yaml` et se lance avec
  `import_role` et `tasks_from`, plutôt que de dupliquer les tâches dans un
  playbook.
- Les valeurs par défaut vont dans
  `roles/<domaine>/<role>/defaults/main.yml`, les valeurs propres aux groupes
  dans `group_vars/`, et les différences par hôte dans `host_vars/`. Les
  secrets restent dans Vault.
- Un **nouveau domaine** sous `roles/` doit être ajouté à `roles_path` dans
  `ansible.cfg`, sinon ses rôles sont introuvables (`the role 'x' was not
  found`, sans explication).
- Les noms de rôles restent uniques sur l'ensemble des domaines : à nom égal,
  le premier chemin de `roles_path` gagne, silencieusement.
- Avant de déplacer ou renommer un rôle, rechercher ses références dans les
  playbooks, dans les `meta/main.yml` et dans `docs/` : les appels se font par
  nom, aucun outil ne signale un appel resté en arrière.
