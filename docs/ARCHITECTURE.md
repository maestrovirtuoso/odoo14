# Architecture ProSys — Odoo 14 en grappe

État au **25 septembre 2026**.

Document de référence pour reprendre le dépôt sans en connaître l'histoire. Il
décrit ce qui *est*, pourquoi c'est ainsi, et ce qui reste à faire.

Documents voisins :
[EXPLICATION-DES-PLAYBOOKS.md](EXPLICATION-DES-PLAYBOOKS.md) (playbook par playbook),
[PERIMETRE-ANSIBLE.md](PERIMETRE-ANSIBLE.md) (ce qui est automatise, et ce qui ne l'est pas),
[EXPLICATION-DES-FICHIERS.md](EXPLICATION-DES-FICHIERS.md) (fichier par fichier),
[sauvegarde-restauration.md](sauvegarde-restauration.md) (procédure opérationnelle),
[bridge-lxc-recapitulatif.md](bridge-lxc-recapitulatif.md) (historique réseau).

---

## 1. Vue d'ensemble

Trois instances Odoo 14 servent la **même base PostgreSQL** et le **même
filestore**. Aucune n'est maître ; chaque utilisateur vise l'IP d'une
instance. Le répartiteur HAProxy + keepalived posé le 30/09/2026 a été retiré
du dépôt le 15/10/2026.

```
                    ┌──────────────────────────────────────────────┐
                    │      LAN 192.168.96.0/24  —  carte ens224    │
                    └──────────────────────────────────────────────┘
                        │             │             │             │
   ┌────────────────────┴───┐  ┌──────┴──────┐  ┌───┴─────────┐  ┌┴──────────────────┐
   │  HÔTE .128  Rocky 8    │  │ HÔTE .129   │  │ HÔTE .140   │  │ HÔTE .141         │
   │                        │  │             │  │             │  │                   │
   │  ┌──────────────────┐  │  │ ┌─────────┐ │  │ ┌─────────┐ │  │ ┌───────────────┐ │
   │  │ CT devodoo14     │  │  │ │devodoo14│ │  │ │devodoo14│ │  │ │ CT devpg15    │ │
   │  │ odoo1    .151    │  │  │ │ odoo2   │ │  │ │ odoo3   │ │  │ │ odoodb  .150  │ │
   │  │ ★ PRIMAIRE       │  │  │ │  .152   │ │  │ │  .153   │ │  │ │ PostgreSQL 15 │ │
   │  └──────────────────┘  │  │ └─────────┘ │  │ └─────────┘ │  │ └───────────────┘ │
   │                        │  │             │  │             │  │                   │
   │  brique odoo14         │  │ brique      │  │ brique      │  │  PAS de brique    │
   │  volume monté par le CT│  │ idem        │  │ idem        │  │  PAS de volume    │
   │  /srv/sauvegardes  ◄── sauvegardes       │  │             │  │                   │
   └────────────────────────┘  └─────────────┘  └─────────────┘  └───────────────────┘
        └──────── GlusterFS « odoo14 » replica 3 ────────┘
```

### Correspondance hôte ↔ conteneur

| Hôte Rocky 8 | Conteneur LXC | IP conteneur | Nom d'inventaire | Rôle |
|---|---|---|---|---|
| 192.168.96.128 | `devodoo14` | 192.168.96.151 | `odoo1` | Odoo — **primaire** (init + cron) |
| 192.168.96.129 | `devodoo14` | 192.168.96.152 | `odoo2` | Odoo |
| 192.168.96.140 | `devodoo14` | 192.168.96.153 | `odoo3` | Odoo |
| 192.168.96.141 | `devpg15` | 192.168.96.150 | `odoodb` | PostgreSQL 15 seul |

Les trois conteneurs Odoo portent **le même nom LXC local**, `devodoo14` : il n'est
unique que par hôte, c'est l'IP qui les distingue.

> ### ⚠ La confusion qui coûte le plus cher ici
>
> **Un hôte et son conteneur sont deux machines différentes, avec deux IP
> différentes.** L'hôte `.128` porte le conteneur `odoo1` qui est en `.151`.
>
> Autoriser `odoo1` dans `pg_hba.conf` n'autorise **en rien** `.128`. Monter un
> volume sur l'hôte ne le rend **pas** visible dans le conteneur. `ls /var/lib/odoo`
> sur l'hôte ne renvoie rien : Odoo n'y est pas.
>
> Toute procédure trouvée en ligne suppose que les deux sont la même machine.

---

## 2. Réseau : carte physique dédiée

Chaque conteneur reçoit **sa propre carte réseau physique** (`ens224`), cédée par
l'hôte :

```
lxc.net.0.type = phys
lxc.net.0.link = ens224
lxc.net.0.name = eth0
lxc.net.0.ipv4.address = <ct_ip>/24
```

Le conteneur **possède** la carte. Ses paquets ne traversent donc jamais le
netfilter de l'hôte : **aucune règle firewalld n'est dans le chemin**.

Deux conséquences majeures :

1. **`pg_hba.conf` est la seule barrière d'accès à la base.** D'où l'absence
   délibérée de toute ligne fourre-tout en `0.0.0.0/0`, et des `/32` uniquement.
2. Ansible joint les conteneurs **directement en SSH**, sans rebond ni
   `ProxyCommand`.

> **Danger** : `nic` ne doit **jamais** désigner la carte qui porte la route par
> défaut de l'hôte. La céder au conteneur couperait l'hôte sans retour possible.
> `lxc_lan` refuse de le faire, par un `assert` sur
> `ansible_default_ipv4.interface`.

Ce modèle remplace une architecture routée (`lxcbr0`, sous-réseaux `10.0.x.0/24`,
routage inter-hôtes, redirection de port). Un pont L2 sur la carte physique n'était
pas possible : l'hyperviseur filtre les adresses MAC. Les reliquats de l'ancien
modèle sont activement démontés par `lxc_lan/tasks/undo_routed.yaml`.

---

## 3. Les deux ressources partagées

```
        DONNÉES ODOO
             │
   ┌─────────┴──────────┐
   ▼                    ▼
PostgreSQL          Filestore
prod @ .150         GlusterFS replica 3, monte sur /var/lib/odoo (conteneurs)
metadonnees         les octets des pieces jointes
```

### 3.1 La base

Une base unique `prod`, servie par le conteneur `odoodb`. Chaque instance ouvre
`db_maxconn = 16` connexions ; à trois nœuds, tenir `max_connections` cohérent.

`list_db = False` et `dbfilter = ^prod$` : le gestionnaire de bases web est
désactivé, la base est créée en ligne de commande par le playbook.

**Le rôle SQL `odoo` est `NOCREATEDB`**, délibérément : aucune instance ne doit
pouvoir créer ou détruire une base sur un serveur qui les héberge toutes. Tout ce
qui exige `CREATE DATABASE` doit tourner **sur `odoodb`** en authentification peer
sous le compte `postgres`.

`pg_hba.conf` généré :

```
local   all             postgres                                peer
local   all             all                                     peer
host    all             all             127.0.0.1/32            scram-sha-256
host    all             all             ::1/128                 scram-sha-256
host    prod,postgres   odoo            192.168.96.151/32       scram-sha-256
host    prod,postgres   odoo            192.168.96.152/32       scram-sha-256
host    prod,postgres   odoo            192.168.96.153/32       scram-sha-256
host    prod,prod_test  odoo            192.168.96.128/32       scram-sha-256
```

- `postgres` pour les conteneurs Odoo n'est **pas un oubli** : à chaque démarrage,
  Odoo 14 appelle `_create_empty_database()`, qui interroge `pg_database` avant de
  rattraper l'exception `DatabaseExists`. Sans cet accès, Odoo s'arrête.
- La dernière ligne est l'**hôte** de sauvegarde `.128`, pour `pg_dump` et le test
  de restauration. Il n'a pas accès à `postgres` : il n'a aucune raison de lire le
  catalogue.

### 3.2 Le filestore — commun et répliqué

```
volume gluster « odoo14 »   replica 3, briques /bricks/odoo14/odoo sur .128 .129 .140
      │
      │  /etc/fstab DU CONTENEUR — node<n>:/odoo14 glusterfs
      │  defaults,_netdev,backup-volfile-servers=…
      ▼
/var/lib/odoo               ← le data_dir ENTIER, dans le conteneur
      ├── filestore/prod    ← là où Odoo écrit ses pièces jointes
      ├── sessions          ← partagé par construction (§3.3)
      └── addons
```

**Le conteneur monte le volume lui-même**, par son propre `/etc/fstab`. Il n'y a
plus ni montage sur l'hôte ni `lxc.mount.entry` : `/dev/fuse` est exposé au
conteneur, et le bind du filestore est commenté dans sa configuration LXC.

C'est un changement par rapport à l'architecture à deux étages décrite jusqu'au
29/09/2026 (hôte en FUSE, conteneur en bind). Le montage n'est **pas** géré par
Ansible, à la demande : le rôle `odoo_filestore` se contente de vérifier, et de
refuser si le compte n'est pas bon.

> ### ⚠ Pourquoi ce garde-fou existe
>
> Le 25/09/2026, les conteneurs se sont retrouvés bindés sur du stockage
> **local** au lieu du volume. Rien ne l'a signalé : Odoo a continué d'écrire,
> et les trois filestores ont divergé — 37, 38 puis 39 fichiers. La base étant
> commune, deux nœuds sur trois citaient des fichiers qu'ils n'avaient pas, et
> l'interface web est tombée en page blanche sur `.152` et `.153`.
>
> `_file_read` d'Odoo **ne lève pas d'erreur** quand un fichier manque : il
> journalise en `INFO` et renvoie une chaîne vide. Rien, nulle part, ne dit
> que quelque chose ne va pas.

**Ne jamais écrire dans `/bricks/odoo14/odoo`.** C'est la brique. Un fichier
déposé là n'obtient ni attribut `trusted.gfid` ni lien dans `.glusterfs` : il
n'est pas répliqué, et le démon de réparation peut le supprimer.

> **`/bricks/odoo14/prod` n'est PAS la brique.** `gluster volume info odoo14`
> est la seule source : les briques sont `/bricks/odoo14/odoo`. `prod` et
> `brick`, à côté, sont des répertoires **locaux** en XFS, reliquats d'essais
> antérieurs, hors du volume et non répliqués (38 fichiers sur `.128`, contenu
> différent d'un hôte à l'autre).
>
> Le 30/09/2026 une comparaison « le local est-il déjà dans le volume ? » a été
> menée contre `/bricks/odoo14/prod` et a conclu « rien à fusionner ». La
> conclusion était fausse : elle mesurait un répertoire mort. **Toute question
> sur le contenu du volume se pose depuis un point de montage**, jamais depuis
> `/bricks`.

#### L'écriture est simultanée, pas synchronisée

Mesuré le 25/09/2026 : un fichier écrit depuis le conteneur d'odoo1 est apparu
dans les **trois briques avec le même horodatage à la seconde**. Le client
GlusterFS écrit dans les trois répliques dans la **même opération** et ne rend
la main qu'au quorum. Il n'y a ni délai, ni démon de copie, ni tâche
planifiée.

Le `Self-heal Daemon` visible dans `gluster volume status` ne sert **pas** au
fonctionnement normal : il ne rattrape que ce qui a manqué pendant qu'une
brique était absente.

#### Détails qui comptent

- Options indispensables dans le `/etc/fstab` du conteneur : `_netdev` et
  `backup-volfile-servers`. Sans elles, le montage est tenté avant le réseau,
  ou reste dépendant d'un seul serveur volfile, et Odoo repart sur un
  répertoire vide.
- Chaque conteneur vise **son** hôte comme serveur volfile primaire
  (`node4:` pour odoo1, `node1:` pour odoo2, `node3:` pour odoo3), les deux
  autres en secours. Le trafic reste local au cas nominal.
- Les conteneurs sont **privilégiés** : les UID traversent sans translation —
  d'où le rôle `odoo_uid` (105/112).
- `/mnt/odoo14` est monté **en plus** dans les conteneurs, sur le même volume.
  Doublon sans effet, hérité des essais ; à nettoyer.
- Côté **hôtes**, `/mnt/odoo` figure au `fstab` de `.129` et `.140`, est
  **commenté** sur `.128`, et n'est monté nulle part. Le `fstab` de `.128`
  contient en plus deux lignes destinées au conteneur
  (`/var/lib/odoo/filestore`, `/mnt/odoo14`) : elles n'ont aucun sens sur un
  hôte qui n'héberge pas Odoo. C'est ce qui empêche la sauvegarde du filestore
  (§10).


### 3.3 Les sessions, partagées depuis le 30/09/2026

`data_dir/sessions` était **local** à chaque nœud tant qu'il n'y avait pas de
répartiteur : chaque utilisateur visait une IP fixe, des sessions locales étaient
donc cohérentes.

Le répartiteur (retiré depuis, le 15/10/2026) avait rendu cela faux : un
utilisateur renvoyé sur un autre nœud y aurait été **déconnecté**, sa session
n'existant pas là. Sans lui, le partage n'est plus nécessaire, mais il reste
en place : il ne gêne pas et resservira si un répartiteur revient.

**Le partage est ici gratuit**, et c'est une conséquence du choix de point de
montage : le volume est monté sur `/var/lib/odoo`, c'est-à-dire sur le `data_dir`
**entier**. `data_dir/sessions` est donc dans le volume par construction — aucun
bind, aucune ligne de fstab, aucun ordre de montage à respecter.

Le rôle `odoo_sessions` ne suppose pas ce cas, il le **mesure** : il compare le
répertoire des sessions au point de montage, et ne pose un bind que si les
sessions sont réellement en dehors du volume (cas d'un montage sur
`data_dir/filestore` seulement). Il retire au passage un bind devenu inutile.

**Le coût est réel, et assumé.** GlusterFS est mauvais sur les très nombreux
petits fichiers à forte rotation — ce que sont exactement les sessions. Chaque
requête authentifiée lit et réécrit un fichier qui part vers trois répliques au
lieu de rester sur un disque local.

L'alternative était les sessions **collantes** seules : aucun coût réseau, mais
l'utilisateur est déconnecté quand son nœud tombe. Le choix avait été la bascule
transparente.

Les sessions sont **exclues des sauvegardes** (`--exclude=./sessions` et
`--exclude=./_sessions`) : ce sont
des jetons d'authentification à durée de vie courte, et une archive conservée un
mois n'a pas à en contenir.

### 3.4 Les deux chemins qu'il ne faut pas confondre

| Variable | Valeur | Ce que c'est |
|---|---|---|
| `odoo_filestore` | `/var/lib/odoo` | le **point de montage** du volume |
| `odoo_filestore_reel` | `/var/lib/odoo/filestore` | le répertoire où **Odoo écrit**, qu'il construit en dur (`{data_dir}/filestore/{base}`) |

Une seule variable servait aux deux jusqu'au 30/09/2026. Conséquence : un fragment
systemd posé à la main assertait `/var/lib/odoo/filestore` comme point de montage
alors que le volume est sur `/var/lib/odoo`. L'assertion ne pouvait plus être
satisfaite, et **les trois instances sont restées arrêtées du 29/09 16h18 au
30/09**.

Le garde-fou n'a pas été retiré — il a fait exactement son travail, il a refusé de
servir plutôt que d'écrire sur le disque local. Il vit désormais dans
`roles/odoo14`, dérivé de `odoo_filestore`, donc incapable de diverger du montage.

---

## 4. L'UID, et pourquoi il est figé

GlusterFS stocke des **numéros**, pas des noms. Le compte `odoo` n'est créé par
aucune tâche de ce dépôt : il vient du `postinst` du paquet Debian, via
`adduser --system`, qui prend le premier UID libre.

Relevé le 24/09/2026 : les trois conteneurs portaient déjà `uid=105 gid=112` —
coïncidence heureuse, les images ayant été bâties identiquement. Le rôle `odoo_uid`
transforme cette chance en invariant vérifié à chaque passage.

L'UID et le GID **diffèrent** l'un de l'autre : `adduser` les alloue dans deux
plages distinctes. Ne pas « corriger » cela.

---

## 5. Python 3.8

Odoo 14 **ne tourne pas** sur le Python 3.11 de Debian 12 : son `safe_eval` valide
le bytecode contre une liste blanche d'opcodes qui s'arrête à 3.10, et rejette
l'opcode `RESUME` que 3.11 place en tête de toute expression. Aucune version de
bibliothèque ne corrige cela.

Le rôle `python38` compile CPython 3.8.20 sous `/opt/python3.8`, et `odoo14` bâtit
dessus un venv `/opt/odoo14-venv`. Le paquet `.deb` reste installé : il fournit
l'utilisateur système, `/etc/odoo`, `/var/lib/odoo`, l'unité systemd et le code
d'Odoo — du Python pur, qui s'importe parfaitement depuis le venv.

Un fragment systemd pointe le service sur l'interpréteur du venv. Toute commande
Odoo doit utiliser `{{ odoo_python }}` en **chemin absolu**, jamais le `odoo` du
`PATH`.

---

## 6. Inventaire

`inventory.yaml` est au format **INI** malgré son extension.

| Groupe | Membres | Usage |
|---|---|---|
| `gluster_servers` | .128 .129 .140 **.141** | les 4 hôtes physiques — **nom historique**, aucun rapport avec Gluster |
| `gluster_bricks` | .128 .129 .140 | les 3 hôtes portant réellement une brick |
| `backup_host` | .128 | porte les sauvegardes |
| `odoo_containers` | odoo1 odoo2 odoo3 | les instances |
| `odoo_primary` | odoo1 | init de la base + tâches planifiées |
| `db_containers` | odoodb | le serveur PostgreSQL |
| `lxc_containers` | ↳ odoo_containers, db_containers | `ansible_user`, interpréteur Python |

### Trois pièges de précédence et d'ordre, vérifiés empiriquement

1. **`vars_files` l'emporte sur `host_vars/`.** `containers` vit dans
   `common/group_vars/local_dev.yml`, injecté par `vars_files:`. Une surcharge
   par hôte perdrait **sans erreur**. D'où la valeur paresseuse :
   `containers: "{{ [ {'name': lxc_container_name} ] }}"`.

2. **Un groupe plus profond bat un groupe racine.** `odoo_containers` est enfant
   de `lxc_containers`, donc il l'emporte sur `odoo_primary` qui est racine. Poser
   `odoo_max_cron_threads` dans `group_vars/odoo_containers` désactiverait le cron
   **partout**, silencieusement. La valeur par défaut vit donc dans
   `roles/odoo14/defaults` — précédence la plus basse — et `odoo_primary` gagne
   proprement.

3. **Les defaults d'un rôle ne sont en portée que pendant ce rôle.** Un playbook
   qui lit une variable depuis une play `tasks:` distincte échoue sur
   `undefined`. D'où `group_vars/backup_host/vars.yml` et `odoo_python` dans
   `group_vars/odoo_containers`.

---

## 7. Playbooks

### `ansi2-snapchot.yaml` — création des conteneurs

Rôle `install` : paquets LXC (EPEL sur Rocky), SELinux permissif,
`/etc/lxc/default.conf` (absent du paquet EPEL, sans quoi `lxc-create` échoue),
puis création via le template `download` en Debian 12 bookworm.

> **Piège d'espace disque.** Le partitionnement Rocky par défaut donne à `/var` un
> volume de **1 Go** alors que `/` en a 15. Un rootfs Debian 12 (~500 Mo) plus le
> cache (~150 Mo) ne tiennent pas. `lxc-create` échoue à l'extraction, détruit le
> rootfs partiel, et ne laisse que « Failed to create container from template » —
> aucun indice de place, parce que le module passe toujours `--quiet`.
>
> `install` le gère : sous `lxc_min_free_mb` (3000), il bind-monte `/var/lib/lxc`
> et `/var/cache/lxc` vers `/srv`. Pour diagnostiquer à la main, rejouer
> `lxc-create` **sans `--quiet`**.

### `ansi_odoo.yaml` — déploiement nominal

**L'ordre des plays est contraignant.**

| # | Hôtes | Rôles | Pourquoi ici |
|---|---|---|---|
| 0 | localhost | — | contrôle des versions ; tag `never`, ne tourne plus par défaut |
| 1 | `gluster_servers` | `chrony`, `lxc_lan` | l'horloge d'abord : fausse, elle fait échouer apt dans les conteneurs |
| 2 | `db_containers` | `base_debian`, `pg_server` | la base avant tout client |
| 3 | `odoo_containers` | `base_debian`, `python38`, `odoo14` | Odoo installé mais **laissé arrêté** |
| 4 | `odoo_primary` | `odoo_dbinit` | init du registre, par **un seul** nœud |
| 5 | `odoo_containers` | — | démarrage |

Démarrer les trois instances avant l'étape 4 leur ferait ouvrir un registre à
moitié initialisé. Trois `odoo -i base` concurrents sur une base partagée la
corrompent — trois garde-fous indépendants l'en empêchent : le groupe
`odoo_primary` à un seul hôte, la séparation en plays, et une sonde
`to_regclass('public.ir_module_module')` qui rend l'init conditionnelle.

```bash
ansible-playbook playbooks/ansi_odoo.yaml -k --ask-vault-pass
ansible-playbook playbooks/ansi_odoo.yaml -k --ask-vault-pass --tags all,preflight   # avec le contrôle d'env.
ansible-playbook playbooks/ansi_odoo.yaml -k --ask-vault-pass --limit odoodb         # que la base
```

### `ansi_syncro.yaml` — bascule du filestore

Migration jouée une fois, mais dont quatre tags restent rejouables.

| Tag | Plays | Coupure | Usage |
|---|---|---|---|
| `preflight` | 0/8 ×3 | non | horloges, bricks, place, UID, volume à migrer |
| `fusion` | 5bis/8 | non | verse les anciens filestores locaux dans le volume |
| `verif` | final | non | confronte chaque `store_fname` au disque |
| *(aucun)* | 1 → 8 | **oui** | migration complète |

L'ordre complet : sauvegardes → arrêt → UID → montage+bind → droits → **fusion** →
migration → `VACUUM FULL` → démarrage.

### `ansi_sauvegarde.yaml`

Voir [sauvegarde-restauration.md](sauvegarde-restauration.md).

---

## 8. Rôles

| Rôle | Cible | Fonction |
|---|---|---|
| `install` | hôtes | paquets LXC, création des conteneurs Debian 12 |
| `chrony` | hôtes | horloge : `makestep 1.0 -1`, saut immédiat, vérification |
| `lxc_lan` | hôtes | carte physique, IP statique, amorçage SSH, démontage de l'ancien routage |
| `odoo_filestore` | `gluster_bricks` | vérifie le montage du volume ; ne le pose pas |
| `odoo_backup` | `backup_host` | client PG15, `.pgpass`, script, timer quotidien |
| `base_debian` | conteneurs | sources APT cohérentes, réalignement des paquets |
| `python38` | conteneurs Odoo | CPython 3.8.20 sous `/opt/python3.8` |
| `odoo14` | conteneurs Odoo | paquet, venv, `odoo.conf`, fragment systemd |
| `odoo_uid` | conteneurs Odoo | UID/GID communs (105/112) |
| `odoo_sessions` | conteneurs Odoo | sessions communes ; mesure si un bind est nécessaire |
| `pg_server` | `odoodb` | PostgreSQL 15, `pg_hba`, rôle SQL, base |
| `odoo_dbinit` | `odoo_primary` | init du registre, stockage des pièces jointes |
| `cleanup`, `odoo_cleanup` | — | démontage |
| ~~`odoo_net`~~ | — | **code mort**, remplacé par `lxc_lan` |

---

## 9. Pièges avérés

Chacun a réellement coûté du temps sur ce projet. Ils sont tous **silencieux** :
aucun ne provoque d'erreur franche.

### `lxc-attach` rend toujours 0

LXC 3.0.4 renvoie `0` même quand la commande interne échoue. **Toute** vérification
passant par `lxc-attach` doit être validée sur un **marqueur stdout**
(`IP_OK`, `BOOTSTRAP_SSH_OK`, `FILESTORE_OK`), jamais sur le code retour.

### `odoo shell` rend toujours 0

Même principe. Une migration peut laisser des pièces jointes derrière elle et
sortir en `0`. D'où les marqueurs `AMIGRER=`, `ECHECS=`, `RESTANT=`,
`SANS_FICHIER=`.

### Les commandes `gluster volume` prennent un verrou de cluster

Ansible exécute les tâches sur les hôtes **en parallèle** : trois
`gluster volume status` simultanés se bloquent mutuellement et rendent tous
`Locking failed on <pair>`. **Cela ressemble exactement à un volume en panne et
n'en est pas un.** Ces commandes rapportent l'état de tout le cluster : un seul
appel suffit → **`run_once: true`**.

### chronyd peut être sain et l'horloge fausse

Observé : **12 h 38 d'écart** sur trois hôtes, alors que `chronyc tracking`
affichait `active`, stratum 2 et une référence correcte. La politique Rocky par
défaut, `makestep 1.0 3`, n'autorise le saut que lors des **3 premières** mises à
jour après démarrage ; au-delà, chrony ne peut plus que glisser. `RMS offset` en
centaines de secondes est le signe.

Correction : `chronyc makestep`, puis `makestep 1.0 -1` dans `/etc/chrony.conf`.
**C'est ce que pose le rôle `chrony`**, sur les quatre hôtes, à chaque
exécution de `ansi_odoo.yaml`. La dérive s'est reproduite trois fois avant
qu'il existe : 12 h 38 le 24/09, 14 h 09 le 25/09.

Les conteneurs LXC **n'ont pas d'horloge propre** : corriger l'hôte les corrige
instantanément.

Symptôme trompeur : `apt-get update` échoue sur *« Release file is **not valid
yet** »* — c'est le contrôle du champ `Date:`, l'inverse du cas expiré, donc
`Acquire::Check-Valid-Until` n'y peut rien.

### `force_storage()` ignore les pièces jointes à `res_field`

`ir.attachment._search` injecte `('res_field', '=', False)` dans tout domaine qui
ne mentionne ni `id` ni `res_field`. Les valeurs de champs binaires — avatars,
photos d'employés, icônes de menu — sont donc **invisibles** pour `force_storage()`,
qui les laisse en place et rend `True`.

Mesuré : 36 pièces jointes en base, **14 migrées, 22 ignorées en silence**.

Contournement, dans `odoo_dbinit` — ne pas le « simplifier » :

```python
tous = ['|', ('res_field', '=', False), ('res_field', '!=', False)]
champ = {'db': 'store_fname', 'file': 'db_datas'}[Att._storage()]
for att in Att.search(tous + [(champ, '!=', False)]):
    with env.cr.savepoint():
        att.write({'datas': att.datas})
```

### Un montage masque le filestore préexistant

**`ir_attachment.location = db` ne vaut que pour les pièces jointes à venir.**
Les plus anciennes gardent leur `store_fname` et restent sur le filestore **local**
de chaque nœud. Le bind Gluster ne les supprime pas : il les **masque**.

Mesuré : 63 pièces jointes → 37 fichiers distincts → 23 présents + **14
introuvables**, tous antérieurs. L'interface affichait des images cassées, et
**aucune tâche n'avait échoué**.

La réparation est une **fusion**, pas une restauration : chaque nœud avait son
propre filestore, il faut l'**union des trois**. Sans danger, les noms étant des
empreintes SHA-1 : même nom ⇒ mêmes octets.

> **La leçon générale.** La migration contrôlait `RESTANT=0`, c'est-à-dire
> `db_datas IS NULL` : elle interrogeait la **source**. Elle n'a jamais demandé si
> les octets étaient arrivés. **Un déplacement de données doit vérifier la
> destination.**

### PostgreSQL 15 et le schéma `public`

Un rôle ordinaire ne peut plus y créer d'objet. La base doit appartenir à `odoo`
(`public` appartient alors à `pg_database_owner`, qui se résout à elle), sinon
`odoo -i base` meurt sur « permission denied for schema public ». Après tout
`pg_restore`, rejouer :

```sql
ALTER DATABASE prod OWNER TO odoo;
ALTER SCHEMA public OWNER TO pg_database_owner;
```

`password_encryption = scram-sha-256` doit être **en vigueur** (`meta:
flush_handlers`, et un **restart**, pas un reload) **avant** la création du rôle,
sinon le mot de passe est stocké en MD5 et rejeté par un `pg_hba` en scram — erreur
qui se lit comme un défaut de `pg_hba`.

### `postgresql_user` réinitialise les attributs

Sans `role_attr_flags` explicite, le module les remet à leurs valeurs par défaut à
chaque passage. Valeur courante : `LOGIN,NOSUPERUSER,NOCREATEDB,NOCREATEROLE`.

### `.pgpass` est indexé par nom de base

Une entrée limitée à `prod` ne s'applique pas à `prod_test`. Le champ base vaut
donc `*`. Le joker n'élargit aucun accès réel : `pg_hba` décide, côté serveur.
Et `libpq` **ignore silencieusement** un `.pgpass` plus permissif que `0600`.

### `failed_when: false` réécrit le champ `failed`

Ajouté le 30/09/2026. Sur une boucle, il met `failed: False` sur **chaque**
élément, y compris ceux qui ont échoué. Un bilan qui filtre sur ce champ ne
trouve donc jamais personne.

Le préflight du répartiteur a affiché `injoignables: []` alors que les trois Odoo
étaient **arrêtés** et que rien n'écoutait sur 8069 ni 8072. `ignore_errors: true`
laisse `failed` dire la vérité tout en poursuivant la play.

### Ansible évalue `success_msg` même quand l'assertion échoue

Tous les arguments d'une tâche sont templatés avant de la jouer. Un
`{{ liste | first }}` dans `success_msg` lève donc
`No first item, sequence was empty` sur une liste vide, et **la tâche plante au
lieu d'afficher le `fail_msg`** patiemment rédigé pour ce cas précis. Utiliser
`join`, qui accepte le vide.

### `/bricks/odoo14/prod` n'est pas une brique

`gluster volume info odoo14` est la **seule** source : les briques sont
`/bricks/odoo14/odoo`. À côté, `prod` et `brick` sont des répertoires locaux en
XFS, hors du volume, au contenu différent d'un hôte à l'autre.

Le 30/09/2026, une comparaison « ce fichier local est-il déjà dans le volume ? »
menée contre `/bricks/odoo14/prod` a conclu « rien à fusionner » — conclusion
fausse, tirée d'un répertoire mort. **Toute question sur le contenu du volume se
pose depuis un point de montage.**

### Deux chemins, un seul nom de variable

`odoo_filestore` désignait à la fois le point de montage du volume et le
répertoire où Odoo écrit. Ils ne coïncident que si le volume est monté sur
`data_dir/filestore`. Ici il l'est sur `data_dir`, un niveau plus haut — et un
fragment systemd posé à la main assertait l'autre chemin comme point de montage.
L'assertion est devenue insatisfiable et **les trois instances sont restées
arrêtées du 29/09 16h18 au 30/09**. Voir §3.4.

---

## 10. Sauvegarde

Deux fichiers **indissociables**, du même horodatage :

| Fichier | Contenu |
|---|---|
| `prod-<horodatage>.dump` | la base : données métier et **métadonnées** des pièces jointes |
| `filestore-<horodatage>.tgz` | les **octets** des pièces jointes |
| `manifeste-<horodatage>.txt` | empreintes SHA-256 et comptages |

> Restaurer le `.dump` seul **réussit sans erreur** et donne une instance
> apparemment saine, jusqu'à ce qu'un utilisateur ouvre un document.

**La base est unique** et **le filestore est commun**, répliqué ×3 avec un
contenu identique sur les trois bricks : un seul dump et une seule archive
suffisent, et ils sont complets. Sauvegarder depuis les trois nœuds archiverait
trois fois la même chose.

### Le prérequis qui a manqué cinq jours

L'hôte de sauvegarde doit avoir le volume **monté**, sur
`sauvegarde_filestore_src` (`/mnt/odoo`) :

```bash
# sur 192.168.96.128, une fois
mount -t glusterfs localhost:/odoo14 /mnt/odoo
```

Le montage n'est pas géré par Ansible, à la demande. Jamais `/bricks` : une
brick contient l'index interne `.glusterfs`, et la lire court-circuite la couche
qui garantit une vue cohérente.

> **Incident du 30/09/2026.** Le volume a été déplacé des hôtes vers les
> conteneurs. `sauvegarde_filestore_src` n'existait plus sur `.128`, `tar`
> échouait sur « open impossible: No such file or directory », **après** le
> `pg_dump`. Les dumps de base étaient donc à jour chaque matin et la dernière
> archive de filestore datait du **25/09** : cinq jours pendant lesquels la
> sauvegarde paraissait fonctionner. Le script contrôle désormais le **type de
> système de fichiers** de la source avant de commencer, et s'arrête avec
> `rc=3` en nommant la commande de montage — plutôt que de laisser un dump
> orphelin donner l'illusion d'une sauvegarde.
>
> Le contrôle porte sur le type, et non sur l'existence du répertoire : un
> répertoire vide existe aussi, et aurait produit une archive vide sans le
> moindre avertissement.

**Ce que ça protège** : l'erreur humaine et la corruption logique — contre
lesquelles la réplication ne peut rien, une suppression se répliquant sur les trois
bricks instantanément. Pas la panne d'un nœud : GlusterFS s'en charge.

Automatique : timer systemd sur `.128`, 02h15, rétention 30 jours, `/srv/sauvegardes`.
Le script écrit la base **d'abord**, le filestore **ensuite** — l'inverse produirait
des références mortes plutôt que des orphelins inoffensifs. Chaque fichier obtient
son nom définitif par un `mv` final : une sauvegarde interrompue reste reconnaissable
en `.part`, et la rotation n'a lieu **qu'après** un succès.


> **Plus aucun test de restauration.** `ansi_restauration-test.yaml` a été
> supprimé le 30/09/2026 a la demande. Rien ne verifie donc plus qu'une
> sauvegarde est reellement restaurable, ni que le dump et l'archive du
> filestore se correspondent. La verification est a faire a la main, selon
> [sauvegarde-restauration.md](sauvegarde-restauration.md).

---

## 11. Variables principales

| Variable | Valeur | Où |
|---|---|---|
| `odoo_shared_db` | `prod` (env `PROSYS_ODOO_DB`) | `group_vars/all` |
| `odoo_db_host` / `_port` / `_user` | `192.168.96.150` / `5432` / `odoo` | `group_vars/all` |
| `odoo_client_ips` | dérivé de `groups['odoo_containers']` | `group_vars/all` |
| `pg_backup_client_ips` | dérivé de `groups['backup_host']` | `group_vars/all` |
| `pg_version` | `15` | `group_vars/all` |
| `odoo_version` | `14.0` (env `PROSYS_ODOO_VERSION`) | `group_vars/odoo_containers` |
| `odoo_data_dir` | `/var/lib/odoo` | `group_vars/odoo_containers` |
| `odoo_filestore` | `/var/lib/odoo` — **point de montage** du volume | `group_vars/odoo_containers` |
| `odoo_filestore_reel` | `/var/lib/odoo/filestore` — où **Odoo écrit** (§3.4) | `group_vars/odoo_containers` |
| `odoo_venv_path` / `odoo_python` | `/opt/odoo14-venv` | `group_vars/odoo_containers` |
| `odoo_workers` / `odoo_db_maxconn` | `2` / `16` | `group_vars/odoo_containers` |
| `odoo_max_cron_threads` | `1` sur odoo1, `0` ailleurs | `group_vars/odoo_primary` |
| `sauvegarde_dir` | `/srv/sauvegardes` | `group_vars/backup_host` |
| `odoo_uid` / `odoo_gid` | `105` / `112` | `roles/odoo_uid/defaults` |
| `gluster_volume` | `odoo14` | `roles/odoo_filestore/defaults` |
| `filestore_host_src` / `sauvegarde_filestore_src` | `/mnt/odoo` — montage **hôte**, pour la sauvegarde | `group_vars/gluster_bricks`, `group_vars/backup_host` |
| `odoo_http_port` / `odoo_longpolling_port` | `8069` / `8072` | `group_vars/all` |

Les secrets vivent dans `group_vars/all/vault.yml`, **chiffré**, gitignoré tant
qu'il est en clair ; `vault.yml.example` est le modèle versionné. Il est dans
`all/` et non `odoo_containers/` parce que le conteneur PostgreSQL et les
conteneurs Odoo doivent lire le **même** `vault_odoo_db_password`, et que deux
copies divergent.

---

## 12. Vérifications

```bash
# Volume sain (UN SEUL nœud à la fois — verrou de cluster)
ansible 192.168.96.129 -k -m command -a 'gluster volume status odoo14'
ansible 192.168.96.129 -k -m command -a 'gluster volume heal odoo14 info'

# Réplication réellement identique — DEPUIS LES CONTENEURS, qui montent le
# volume. Interroger /bricks/odoo14/prod ne mesure PAS le volume : c'est un
# répertoire local périmé, au contenu différent d'un hôte à l'autre (§3.2).
ansible odoo_containers -m shell -a 'find /var/lib/odoo/filestore/prod -type f | wc -l'

# Les pièces jointes citées en base ont-elles leur fichier ?
ansible odoodb -m shell -a "su - postgres -c \"psql -d prod -At -c 'SELECT count(DISTINCT store_fname) FROM ir_attachment WHERE store_fname IS NOT NULL'\""

# Base et filestore concordent
ansible-playbook playbooks/ansi_syncro.yaml -k --ask-vault-pass --tags verif

# Connexions applicatives
ansible odoodb -k -m shell -a 'chdir=/tmp sudo -u postgres psql -d prod -c "SELECT client_addr, state, count(*) FROM pg_stat_activity WHERE backend_type = '"'"'client backend'"'"' GROUP BY 1,2"'

# Horloges
ansible gluster_servers -k -m command -a 'date -u'
```

Le test croisé qui compte, et qu'aucun playbook ne peut faire : joindre un fichier
à un contact via `.151`, l'ouvrir via `.152` puis `.153`.

---

## 13. État connu et dettes

Mesuré le **30/09/2026**, machines interrogées.

### Opérationnel

| Point | État |
|---|---|
| Volume `odoo14` | `Started`, replica 1×3, briques `/bricks/odoo14/odoo` sur `.128 .129 .140` |
| Montage | par les **conteneurs** eux-mêmes sur `/var/lib/odoo` ; rien de monté côté hôtes |
| Odoo | actif sur les trois, `/web/login` → **200** |
| Modules | **63 installés**, dont `website` réinstallé le 30/09 (§13ter) |
| Sessions | dans le volume par construction, aucun bind (§3.3) |
| Horloges | dérive de **14 h 09** le 25/09 — le rôle `chrony` la corrige et l'empêche |
| Sauvegarde base | quotidienne, dernier dump `prod-20260930-110338.dump` vérifié au `pg_restore --list` (9553 entrées) |
| Sauvegarde filestore | **en échec depuis le 25/09** — le volume n'est monté sur aucun hôte (§10) |
| Copie hors cluster | **aucune** — jamais rapatriée |

### ⚠ Le filestore est scindé en deux, et Odoo ne voit qu'une moitié

C'est **le point bloquant du moment**, et il ne se signale pas de lui-même.

Le volume contient deux arborescences de pièces jointes :

| Chemin dans le volume | Fichiers | Vu par Odoo ? |
|---|---|---|
| `prod/` (à la racine) | **137** | **non** |
| `filestore/prod/` | **14** | oui |

Odoo 14 construit le chemin en dur : `{data_dir}/filestore/{base}`. Il ne regarde
donc que le second. Le premier est l'héritage de l'époque où le volume était monté
un niveau plus bas.

Confrontation base ↔ fichiers :

| Mesure | Valeur |
|---|---|
| `store_fname` distincts référencés en base | **86** |
| présents dans `filestore/prod/` | 7 |
| **manquants là où Odoo les cherche** | **79** |
| récupérables depuis `prod/` à la racine | **79** |
| définitivement introuvables | **0** |

**Rien n'est perdu.** La remise en état est une fusion, et non un renommage —
`filestore/prod/` existe déjà avec ses 14 fichiers :

```bash
# sur odoo1 (192.168.96.151), une fois : le volume est commun aux trois
tar czf /root/volume-avant-fusion-$(date +%F).tgz -C /var/lib/odoo prod
rsync -a --ignore-existing /var/lib/odoo/prod/ /var/lib/odoo/filestore/prod/
find /var/lib/odoo/filestore/prod -type f | wc -l     # attendu : ~151
```

`--ignore-existing` et non `--delete` : les 14 fichiers déjà en place ont été
écrits par Odoo depuis, ils font autorité. `prod/` à la racine n'est **pas**
supprimé — il le sera après vérification, pas avant.

Pourquoi ça ne se voit pas : `_file_read` d'Odoo journalise en `INFO` et renvoie
une chaîne vide quand un fichier manque. Une pièce jointe absente s'affiche comme
un document vide, sans aucune erreur.

### Dettes techniques

1. **`lxc_lan` arrête et redémarre les conteneurs à chaque exécution**, même quand
   la configuration n'a pas changé : `changed_when: _lxc_stop.rc == 0` est
   inconditionnel. C'est une coupure de service gratuite à chaque
   `ansible-playbook`. À convertir en `notify:` / handler.
2. **`roles/odoo_net/`** — code mort à supprimer.
3. **`gluster_servers`** — nom trompeur, désigne les 4 hôtes physiques.
4. **Purges one-shot rejouées à chaque passage** (~30 items sans effet) :
   `undo_routed`, `purge_replication`, suppression des unités de synchro filestore.
   `lxc_undo_routed` existe déjà pour les neutraliser.
5. **`EXPLICATION-DES-FICHIERS.md`** ignore la quinzaine de fichiers créés du
   24 au 30/09/2026 : les rôles `chrony`, `odoo_uid`, `odoo_backup`,
   `odoo_migration`, `odoo_sessions`, et les playbooks
   `ansi_sauvegarde`, `ansi_syncro`.
6. **`/etc/fstab` des conteneurs : doublon `/mnt/odoo14`** — le volume y est monté
   deux fois, sur `/var/lib/odoo` et sur `/mnt/odoo14`. Sans effet, hérité des
   essais. Sur odoo1 et odoo3 s'ajoute une ligne `/mnt/odoo14` commentée.
7. **`/etc/fstab` de l'hôte `.128` pollué** — il contient deux lignes destinées au
   **conteneur** (`/var/lib/odoo/filestore`, `/mnt/odoo14`), et sa ligne `/mnt/odoo`
   est commentée. C'est ce qui empêche la sauvegarde du filestore (§10).
8. **Aucun test de restauration** — `ansi_restauration-test.yaml` supprimé le
   30/09/2026 à la demande. Rien ne vérifie plus qu'une sauvegarde est restaurable.
9. ~~`makestep 1.0 -1` à poser, chronyd à installer sur `.141`~~ — **résolu le
   25/09/2026** par le rôle `chrony`, appliqué aux quatre hôtes par
   `ansi_odoo.yaml` play 1.
10. **Pas de répartiteur de charge** — HAProxy + keepalived, posés le
    30/09/2026, ont été retirés du dépôt le 15/10/2026. Chaque utilisateur
    vise l'IP d'une instance ; si elle tombe, il doit changer d'URL. Le rôle
    `odoo_sessions` n'est plus appelé par aucun playbook.

### À faire dans l'ordre

```bash
# 1. RECOUVRER LES 79 PIECES JOINTES -- sur odoo1, cf. ci-dessus
tar czf /root/volume-avant-fusion-$(date +%F).tgz -C /var/lib/odoo prod
rsync -a --ignore-existing /var/lib/odoo/prod/ /var/lib/odoo/filestore/prod/

# 2. remettre l'archive du filestore en route -- a la main, sur .128
#    (decommenter la ligne /mnt/odoo du fstab, puis)
mount -t glusterfs localhost:/odoo14 /mnt/odoo
ansible-playbook playbooks/ansi_sauvegarde.yaml --tags sauvegarder

# 3. confronter la base au filestore
ansible-playbook playbooks/ansi_syncro.yaml --ask-vault-pass --tags verif
```

---

## 13ter. La désinstallation inachevée du module `website`

Diagnostiquée le 30/09/2026, en cherchant pourquoi le backend `odoo_http` du
répartiteur restait DOWN alors que `odoo_longpolling` était UP sur les **mêmes**
machines — ce qui écartait d'emblée SELinux et le pare-feu, la connexion TCP
passant.

`/web/login` renvoyait **500** sur les trois instances :

```
Template: web.frontend_layout
Node: <t t-set="x_icon" t-value="website.image_url(website, 'favicon')"/>
AttributeError: 'NoneType' object has no attribute 'image_url'
```

Le module `website` était `uninstalled`, et sa donnée toujours présente :

| Reliquat | Compte |
|---|---|
| Vues `website.*` | 268, dont **27 actives dans le chemin de rendu du login** |
| Lignes `ir_model_data` module `website` | 937 |
| Modèles `website*` | 14 |

`website.layout` héritait de `web.frontend_layout`, donc toute page frontend
appelait `website.image_url(...)` sans que le code Python soit chargé. Aucun
module n'était en état transitoire : la désinstallation ne tournait pas, elle
s'était arrêtée en laissant la base incohérente avec elle-même.

**Résolu par une réinstallation** (`-i website`, instances arrêtées, une seule
écrivant le registre), après `pg_dump` vérifié au `pg_restore --list`. Les 268
vues ont retrouvé leur code, et `/web/login` répond 200 sur les trois nœuds.

Désactiver la seule vue fautive aurait été un contournement : 26 autres vues
`website` actives siègent dans le même chemin de rendu, et la base serait restée
incohérente. Pour se débarrasser vraiment de `website`, il faut désormais le
désinstaller **depuis l'interface**, qui sait retirer ses 937 lignes.

---

## 14. Limites de cette architecture

- **Aucune adresse d'entrée unique.** Sans répartiteur, la perte d'un hôte Odoo
  coupe les utilisateurs qui le visaient, jusqu'à ce qu'ils changent d'URL.
- **PostgreSQL est un point unique de défaillance.** Si `.150` tombe, les trois
  Odoo s'arrêtent. GlusterFS ne protège que le filestore.
- **Odoo 14 est en fin de vie.** Le dépôt nightly est figé à `14.0.20231205`, et son
  `.deb` déclare des dépendances `python3-*` **non versionnées**, que bookworm
  résout vers des versions de l'ère 3.11 qu'Odoo 14 n'a jamais visées. Le venv 3.8
  contourne cela, mais c'est le premier endroit à regarder en cas d'échec au
  démarrage.
- **Les quatre hôtes vivent vraisemblablement sur le même hyperviseur.** Ni la
  réplication ni les sauvegardes locales ne protègent de sa perte.
- **La sauvegarde n'est pas éprouvée.** Le filestore n'est plus archivé depuis le
  25/09 (§10) et aucun test de restauration n'existe. Une sauvegarde dont on n'a
  jamais vérifié la restauration est une hypothèse, pas une protection.
- **Les sessions partagées coûtent à chaque requête authentifiée.** GlusterFS est
  mauvais sur les petits fichiers à forte rotation (§3.3).
