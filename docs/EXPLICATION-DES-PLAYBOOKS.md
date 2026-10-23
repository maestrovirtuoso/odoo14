# Les playbooks, en détail

État au **25 septembre 2026**.

Comment lancer ce dépôt sans en connaître l'histoire : ce que fait chaque
playbook, dans quel ordre, et pourquoi cet ordre.

Documents voisins :
[ARCHITECTURE.md](ARCHITECTURE.md) (le *quoi* et le *pourquoi*),
[PERIMETRE-ANSIBLE.md](PERIMETRE-ANSIBLE.md) (ce qui est automatisé, et ce qui ne l'est pas),
[EXPLICATION-DES-FICHIERS.md](EXPLICATION-DES-FICHIERS.md) (fichier par fichier),
[sauvegarde-restauration.md](sauvegarde-restauration.md) (procédure opérationnelle).

---

## Aide-mémoire

| Je veux… | Commande |
|---|---|
| créer les conteneurs | `ansible-playbook playbooks/ansi2-snapchot.yaml -k` |
| déployer / mettre à jour | les trois commandes de [l'ordre de lancement](#ordre-de-lancement) |
| corriger l'horloge seule | `… ansi_odoo.yaml -k --ask-vault-pass --tags horloge` |
| refaire le réseau des conteneurs | `ansible-playbook -i inventory.yaml playbooks/reseau-lxc.yaml` |
| ne rejouer que la base | `… ansi_odoo.yaml -k --ask-vault-pass --limit odoodb1` |
| monter le volume sre seul | `… ansi_odoo.yaml -k --ask-vault-pass --tags filestore` |
| état des lieux avant migration | `… ansi_syncro.yaml -k --ask-vault-pass --tags preflight` |
| rebrancher le filestore | `… ansi_syncro.yaml -k --ask-vault-pass --tags filestore` |
| vérifier base ↔ filestore | `… ansi_syncro.yaml -k --ask-vault-pass --tags verif` |
| sauvegarder maintenant | `ansible-playbook playbooks/ansi_sauvegarde.yaml -k --ask-vault-pass` |
| copie hors cluster | `… ansi_sauvegarde.yaml … -e sauvegarde_rapatrier=true` |
| passer la base en haute disponibilité | `ansible-playbook playbooks/ansi_postgresql_ha.yaml --ask-vault-pass`, puis la suite du [§ 5.5](POSTGRESQL-PATRONI.md) |

### Ordre de lancement

Le réseau des conteneurs n'est plus fait par `ansi_odoo.yaml` : il est fait
par `reseau-lxc.yaml`, seul playbook qui joue le rôle `lxc_lan`. Un
déploiement se lance donc en trois commandes, dans cet ordre :

```bash
ansible-playbook playbooks/ansi_odoo.yaml -k --ask-vault-pass --tags horloge
ansible-playbook -i inventory.yaml playbooks/reseau-lxc.yaml
ansible-playbook playbooks/ansi_odoo.yaml --ask-vault-pass
```

1. **L'horloge d'abord.** `reseau-lxc.yaml` installe `openssh-server` par apt
   dans les conteneurs. Une horloge fausse le fait échouer sur *« Release file
   is not valid yet »*. Le tag `horloge` ne joue que le rôle `chrony`.
2. **Le réseau ensuite.** Il expose les conteneurs sur le LAN et amorce leur
   accès SSH. Sans lui, Ansible ne joint aucun conteneur.
3. **Le déploiement enfin.** Il rejoue `chrony`, sans effet sur une horloge
   déjà juste, puis tout le reste.

---

## Trois familles

```
CONSTRUIRE     ansi2-snapchot.yaml          crée les conteneurs LXC
               reseau-lxc.yaml              réseau des conteneurs et accès SSH
               ansi_odoo.yaml               déploie le reste

EXPLOITER      ansi_syncro.yaml             déplace les pièces jointes
               ansi_sauvegarde.yaml         sauvegarde

DÉFAIRE        nettoyage_odoo.yaml          remet les conteneurs Odoo à plat
               nettoyage.yaml               désinstalle LXC des hôtes
```

Tous partagent un principe : **ils n'orchestrent que**. La logique vit dans les
rôles. Un playbook dit *quoi*, *où*, *dans quel ordre* — jamais *comment*.

---

## 1. `ansi2-snapchot.yaml` — naissance des conteneurs

Un seul play, un seul rôle.

```yaml
hosts: gluster_servers        # les 4 hôtes Rocky 8
roles: [install]
```

Il installe LXC (via EPEL sur Rocky), passe SELinux en permissif, pose
`/etc/lxc/default.conf` — absent du paquet EPEL, et sans lui `lxc-create`
échoue immédiatement — puis crée un conteneur Debian 12 bookworm par hôte.

> ### ⚠ Le piège d'espace disque
>
> Le partitionnement Rocky par défaut donne à `/var` un volume de **1 Go**
> quand `/` en a 15. Un rootfs Debian 12 (~500 Mo) plus le cache de
> téléchargement (~150 Mo) n'y tiennent pas.
>
> `lxc-create` échoue à l'extraction, **détruit le rootfs partiel**, et ne
> laisse que *« Failed to create container from template »* — aucun indice de
> place, parce que `community.general.lxc_container` passe toujours `--quiet`,
> ce qui bâillonne le template `download`.
>
> Le rôle le gère : sous `lxc_min_free_mb` (3000), il bind-monte
> `/var/lib/lxc` et `/var/cache/lxc` vers `/srv`, qui est sur `/`. Pour
> diagnostiquer à la main, rejoue `lxc-create` **sans `--quiet`**.

**Quand le lancer :** une fois, ou après un `nettoyage.yaml`.

---

## 2. `ansi_odoo.yaml` — le déploiement nominal

Huit plays. **L'ordre est contraignant** : Ansible termine un play sur tous
ses hôtes avant de passer au suivant, et c'est ce qui garantit l'enchaînement
« horloge → stockage → base → Odoo → initialisation → démarrage ».

Le réseau des conteneurs n'en fait plus partie : `reseau-lxc.yaml` doit être
passé avant, voir [l'ordre de lancement](#ordre-de-lancement).

| # | Hôtes | Rôles | Pourquoi ici |
|---|---|---|---|
| 0 | `localhost` | — | versions d'Ansible et des collections (tag `never`) |
| 1 | `gluster_servers` (6 hôtes) | `chrony` | l'horloge d'abord ; le réseau est fait avant, par `reseau-lxc.yaml` |
| 1bis | `gluster_bricks` (3 hôtes Odoo) | `odoo_filestore` | le volume `sre` monté **avant** l'installation d'Odoo |
| 2 | `db_containers` (odoodb1) | `pg_server` | la base primaire avant tout client |
| 2bis | `db_replicas` (odoodb2, odoodb3) | `pg_server` | les réserves **après** le primaire, qui crée leurs slots |
| 3 | `odoo_containers` (odoo1-3) | `odoo14`, `odoo_uid` | Odoo installé, **laissé arrêté** |
| 4 | `odoo_primary` (odoo1) | `odoo_dbinit` | le registre, par **un seul** nœud |
| 5 | `odoo_containers` | — | démarrage et attente de `:8069` |

```bash
ansible-playbook playbooks/ansi_odoo.yaml -k --ask-vault-pass --tags horloge
ansible-playbook -i inventory.yaml playbooks/reseau-lxc.yaml
ansible-playbook playbooks/ansi_odoo.yaml --ask-vault-pass
```

Le playbook est **idempotent** : un second passage ne recrée ni la base, ni
les réserves, ni le registre. Il **redémarre** en revanche certains services,
voir [Ce qui coupe le service](#ce-qui-coupe-le-service).

### Play 0 — contrôle du poste, tagué `never`

`hosts: localhost`, `connection: local`. Deux vérifications :

- la version d'Ansible est dans `[2.10, 2.11[` — `ansible.posix 1.1.1` déclare
  `requires_ansible: >=2.9,<2.11` : monter Ansible impose de monter aussi les
  collections, et inversement ;
- chaque collection de `requirements.yml` apparaît dans
  `ansible-galaxy collection list`.

Le but est d'échouer **avant** de toucher une machine, plutôt qu'en plein
déploiement sur un paramètre inconnu. Il ne tourne que sur demande : le tag
`never` est l'idiome Ansible pour « seulement si on le nomme ».

```bash
--tags all,preflight    # avec tout le reste
--tags preflight        # seul, sans toucher aux hôtes
```

### Play 1 — horloge, sur les six hôtes

`gather_facts: true` : `chrony` choisit son chemin de configuration et son
service selon `ansible_os_family`. `vars_files: common/group_vars/local_dev.yml`
fournit la variable `containers`.

**`chrony`.** Une horloge fausse fait échouer `apt-get update` dans les
conteneurs avec *« Release file is **not valid yet** »* — c'est le contrôle du
champ `Date:`, l'inverse du cas expiré, donc `Acquire::Check-Valid-Until` n'y
peut rien. Le rôle :

- pose `makestep 1.0 -1` dans `/etc/chrony/chrony.conf` (Debian 12 ; le chemin
  et le nom du service, `chrony`, sont choisis selon `ansible_os_family`). Le
  réglage habituel des distributions, `makestep 1.0 3`, n'autorise le saut que
  pendant les trois premières mises à jour : une dérive apparue ensuite n'est
  jamais rattrapée ;
- compare `date -u +%s` de l'hôte et du poste de contrôle ; au-delà de 60 s il
  force `chronyc makestep`, remesure, et échoue si l'écart persiste.

Les conteneurs LXC n'ont pas d'horloge propre : ils lisent celle du noyau de
l'hôte. Corriger l'hôte les corrige instantanément.

Tag `horloge` pour ne jouer que `chrony`. C'est la première commande de
[l'ordre de lancement](#ordre-de-lancement) :

```bash
ansible-playbook playbooks/ansi_odoo.yaml -k --ask-vault-pass --tags horloge
```

### Play 1bis — le filestore commun, tagué `filestore`

```
192.168.36.8:/sre  ──mount glusterfs (fstab, _netdev)──►  /mnt/odoo      hôtes .36.21-23
                                                              │ lxc.mount.entry (bind)
                                                              ▼
                                                        /var/lib/odoo    odoo1-3
```

`odoo_filestore`, joué sur les **hôtes** Odoo :

1. installation du client GlusterFS par `ansible.builtin.package` :
   `glusterfs-client` sur les hôtes Debian 12 (client 10.x), `glusterfs-fuse`
   sur un hôte Rocky / RHEL. Si `gluster_hosts` est renseigné, les noms
   des serveurs de brique (`dev-glustervm1..3`) sont écrits dans `/etc/hosts`
   pour forcer une résolution IPv4.
2. `wait_for 192.168.36.8:24007`, puis `ansible.posix.mount` du volume sur
   `/mnt/odoo`, type `glusterfs`, options `defaults,_netdev` — inscrit dans
   `/etc/fstab` **et** monté immédiatement. `_netdev` fait attendre le réseau
   au démarrage de l'hôte.
3. **Garde-fou central** : `findmnt` doit rendre `fuse.glusterfs`. Un
   répertoire vide au même endroit ne prouve rien — Odoo y écrirait sans
   erreur, et les trois filestores divergeraient en silence. Un chemin qui
   contient `.glusterfs` (une brique) est refusé.
4. Un éventuel reliquat local est versé dans le volume (`cp -a -n`, qui
   n'écrase rien : les noms sont des empreintes SHA-1 du contenu). Puis
   `/mnt/odoo`, `filestore/` et `filestore/prod` passent à `105:112` — en
   **numérique**, l'hôte n'ayant pas de compte `odoo`. `run_once` : c'est le
   même volume vu des trois hôtes.
5. `lxc.mount.entry = /mnt/odoo var/lib/odoo none bind,create=dir 0 0` dans la
   config LXC. Cette directive n'est lue qu'au démarrage : un handler redémarre
   le conteneur.
6. Vérification **dans** le conteneur : `/var/lib/odoo` est en
   `fuse.glusterfs` (marqueur `FILESTORE_PARTAGE_OK`).

Le bind porte sur le `data_dir` **entier** : pièces jointes (`filestore/`) et
sessions (`sessions/`) sont communes aux trois instances.

### Plays 2 et 2bis — PostgreSQL primaire et réserves

Même rôle `pg_server` pour les deux. La variable `pg_is_replica` — vraie pour
les membres de `db_replicas` — choisit la branche. Le rôle dépend de
`base_debian` (sources APT cohérentes, réparation dpkg).

**Tronc commun**, sur les trois serveurs :

- paquets `postgresql-15` et `python3-psycopg2` ;
- `conf.d/10-prosys.conf` : `listen_addresses` sur l'IP du conteneur et
  `localhost` (jamais `*`), `max_connections = 200`, `shared_buffers = 256MB`,
  `password_encryption = scram-sha-256` ;
- `conf.d/20-replication.conf` : `wal_level = replica`, `max_wal_senders = 10`,
  `max_replication_slots = 10`, `max_slot_wal_keep_size = 2GB`,
  `hot_standby = on` ;
- `pg_hba.conf`, **dérivé de l'inventaire** : une ligne `/32` par conteneur
  Odoo (bases `prod` et `postgres`, rôle `odoo`), l'hôte de sauvegarde (base
  `prod` seule), une ligne `replication` par serveur PostgreSQL ;
- `flush_handlers` **avant** de créer le moindre rôle SQL : sans redémarrage
  préalable, `scram-sha-256` ne serait pas encore actif, le mot de passe serait
  stocké en md5 et refusé ensuite par `pg_hba` — une erreur qu'on prendrait
  pour une faute de `pg_hba`.

**Play 2, le primaire** (`tasks/primary.yaml`) :

- purge des fichiers de l'ancienne réplication ;
- rôle `odoo` : `LOGIN, NOSUPERUSER, NOCREATEDB, NOCREATEROLE` ;
- base `prod`, `owner odoo`, `template0`. Le propriétaire est déterminant en
  PostgreSQL 15 : un rôle ordinaire ne peut plus créer d'objet dans `public`
  s'il ne possède pas la base, et `odoo -i base` échouerait ;
- rôle `replicator` (`REPLICATION`) et un slot physique par réserve
  (`pg_create_physical_replication_slot`). Le slot garde les WAL qu'une réserve
  n'a pas lus ; `max_slot_wal_keep_size` l'empêche de remplir le disque du
  primaire si une réserve meurt.

**Play 2bis, les réserves** (`tasks/replica.yaml`) :

- `/var/lib/postgresql/.pgpass` en `0600` :
  `<primaire>:5432:replication:replicator:<mdp>` — le mot de passe n'apparaît
  ni dans `ps`, ni dans le journal d'Ansible ;
- s'il n'y a pas encore de `standby.signal` : refus si le cluster local
  contient une base autre que `postgres`, `template0`, `template1` ; arrêt,
  répertoire de données vidé et recréé en `0700` ;
  `pg_basebackup -X stream -S <slot> -c fast -w` ; création de `standby.signal` ;
- `primary_conninfo` (avec `passfile` et `application_name`) et
  `primary_slot_name` dans `20-replication.conf` ;
- vérification **des deux côtés** : sur la réserve, `pg_is_in_recovery()` et
  `pg_stat_wal_receiver.status = streaming` ; sur le primaire (`delegate_to`),
  la réserve figure dans `pg_stat_replication`.

**Commun aux deux** : `pg_hba_file_rules WHERE error IS NOT NULL` doit être
vide. Un simple *reload* ignore en silence une ligne invalide et laisse
l'ancienne règle en vigueur.

> La bascule vers une réserve est **manuelle** : rien ne surveille le
> primaire. Procédure en tête de `roles/ansi_odoo/pg_server/tasks/replica.yaml`.

### Play 3 — Odoo installé, laissé arrêté

`odoo14`, qui dépend de `base_debian` et de `python38` :

- **`python38`** compile CPython 3.8.20 sous `/opt/python3.8`, après contrôle du
  SHA-256 de l'archive, puis vérifie les modules `ssl`, `sqlite3`, `ctypes`,
  `zlib`… Odoo 14 ne tourne pas sur le Python 3.11 de bookworm : `safe_eval`
  rejette ses opcodes.
- Paquet `odoo` du dépôt nightly 14.0, puis venv `/opt/odoo14-venv` sur
  Python 3.8 (versions figées si un fichier de verrouillage existe sur le
  contrôleur, sinon le `requirements.txt` amont).
- `odoo-deb.pth` rend le code du paquet Debian visible depuis le venv ; le
  fragment `odoo.service.d/venv.conf` remplace `ExecStart` pour lancer
  `/usr/bin/odoo` avec l'interpréteur du venv.
- **Garde-fou filestore** : `findmnt /var/lib/odoo` doit être GlusterFS, sinon
  le rôle s'arrête en nommant le chemin et la cause ; et
  `odoo.service.d/filestore.conf` pose `AssertPathIsMountPoint=/var/lib/odoo`.
  *Assert* et non *Condition* : une Condition non remplie fait passer l'unité
  pour démarrée, une Assert échoue bruyamment.
- `/etc/odoo/odoo.conf` : `db_host` = le primaire, `db_name = prod`,
  `dbfilter = ^prod$`, `list_db = False`, `data_dir = /var/lib/odoo`,
  `workers = 2` (ce qui ouvre le port 8072 du longpolling),
  `max_cron_threads` à 1 sur le primaire et 0 ailleurs, `proxy_mode = False`
  (aucun proxy devant Odoo).
- Accès à la base : `wait_for :5432`, puis `SELECT 1` avec les identifiants
  d'Odoo — un seul test pour le réseau inter-LAN, `pg_hba` et le mot de passe.
- `service odoo` : `stopped`, `enabled`.

`odoo_uid` ensuite : il aligne le compte `odoo` sur `105:112`, après avoir
vérifié que l'UID cible est libre, et ne fait le `chown -R` que si quelque
chose a changé. Le paquet Debian attribue le premier UID système libre, qui
peut différer d'un conteneur à l'autre ; sur un volume partagé ce sont les
**numéros** qui comptent. Il exige Odoo arrêté — d'où sa place juste après
`odoo14`.

### Play 4 — le registre, par un seul nœud

`odoo_dbinit` sur `odoo_primary`, `throttle: 1` :

- sonde `SELECT to_regclass('public.ir_module_module')` — `NULL` sur une base
  vierge au lieu d'une erreur ;
- base vierge seulement : en tant que `odoo`,
  `python3.8 /usr/bin/odoo -c odoo.conf -d prod -i base --without-demo=all --stop-after-init` ;
- `ir_attachment.location = file` dans `ir_config_parameter`
  (`INSERT … ON CONFLICT … WHERE … IS DISTINCT FROM`, donc *changed* seulement
  si la valeur bouge) : les pièces jointes vont sur le volume partagé, pas en
  base ;
- avec `-e odoo_force_storage=true` seulement : migration des pièces jointes
  existantes vers ce support.

Trois `odoo -i base` concurrents sur une base partagée **corrompent le
registre**. Trois protections indépendantes l'empêchent :

1. le groupe `odoo_primary` ne contient qu'un hôte ;
2. le play 4 est distinct du play 3, et s'exécute alors qu'Odoo est **arrêté
   partout** ;
3. la sonde `to_regclass` rend l'initialisation conditionnelle.

### Play 5 — démarrage

`service odoo` : `started`, `enabled`, puis `wait_for :8069` sur l'IP de
chaque conteneur (120 s au plus). Les trois instances ouvrent un registre
complet.

### Ce qui coupe le service

| Play | Coupure |
|---|---|
| — | `reseau-lxc.yaml`, joué avant : `lxc_lan` redémarre **toujours** les conteneurs, son `lxc-stop` n'est pas conditionné à un changement |
| 1bis | redémarre les conteneurs Odoo au premier passage, ou si la ligne de bind change |
| 2 / 2bis | redémarre PostgreSQL si sa configuration change ; les Odoo perdent leurs connexions quelques secondes |

### Options utiles

```bash
--tags horloge          # chrony seul, à passer avant reseau-lxc.yaml
--tags filestore        # montage du volume sre et bind seuls
--limit odoodb1         # ne rejouer que la base primaire
--tags all,preflight    # avec le contrôle d'environnement
```

**Quand le lancer :** à chaque changement de configuration.

**Prérequis :** conteneurs créés (`ansi2-snapchot.yaml`), réseau des conteneurs
fait (`reseau-lxc.yaml`, après `--tags horloge`), clé SSH copiée sur
les six hôtes, collections installées, `group_vars/all/vault.yml` renseigné —
y compris `vault_pg_replication_password` — puis chiffré.

---

## 3. `ansi_syncro.yaml` — déplacer les pièces jointes

Le plus élaboré : **15 plays**, dont 12 étapes portées par le rôle
`odoo_migration` et ses points d'entrée `tasks_from`.

### Ce qu'il fait

Il déplace les pièces jointes entre les deux supports possibles. Le **sens**
est piloté par une variable :

```bash
# base → disque (défaut)
ansible-playbook playbooks/ansi_syncro.yaml -k --ask-vault-pass

# disque → base (retour arrière)
ansible-playbook playbooks/ansi_syncro.yaml -k --ask-vault-pass \
  -e odoo_attachment_location=db -e odoo_force_storage=true
```

### L'ordre, et ce que chaque contrainte évite

```
0   préflight      horloges, montage, UID, volume à migrer
1   sauvegardes    pg_dump + tar par nœud        ← tant que rien n'a bougé
2   ARRÊT          les trois Odoo                ← aucune écriture pendant
3   UID            105/112 partout               ← un FS retient des NUMÉROS
4   bind           /mnt/odoo14 → conteneur         ← redémarre les conteneurs
5   droits         chown du filestore
5b  récupération   verse les anciens filestores  ← SINON perte silencieuse
6   migration      un seul nœud, le primaire
7   bilan          VACUUM FULL + vérification
8   redémarrage
```

**Play 1 avant play 2** : sauvegarder pendant que tout est encore intact.

**Play 2 avant play 3** : renuméroter un compte dont des processus tournent
leur ferait perdre l'accès à leurs propres fichiers au `chown`.

**Play 3 avant play 4** : un système de fichiers partagé retient des
**numéros**, pas des noms. Si `odoo` vaut 105 ici et 106 là, les fichiers
deviennent illisibles d'un nœud à l'autre.

> ### ⚠ Play 5bis, l'étape qu'on oublie
>
> `ir_attachment.location = db` ne vaut que pour les pièces jointes **à
> venir**. Celles créées avant sont restées sur le filestore **local** de
> chaque conteneur, et le bind vient se poser par-dessus : il ne les supprime
> pas, il les **masque**.
>
> Odoo cite alors des `store_fname` devenus introuvables, l'interface affiche
> des images cassées, et **aucune tâche n'a échoué**. Mesuré le 24/09/2026 :
> 14 fichiers distincts, cités par 27 pièces jointes.
>
> La récupération est sans risque : les noms sont des empreintes SHA-1 du
> contenu, donc deux fichiers de même nom sont identiques par construction —
> d'où `tar --skip-old-files` plutôt qu'un écrasement.

### Les quatre tags

| Tag | Effet | Coupure |
|---|---|---|
| `preflight` | horloges, montage, UID, volume à migrer | non |
| `filestore` | vérifie le montage, récupère un reliquat, binde | brève |
| `fusion` | verse les anciens filestores locaux | non |
| `verif` | confronte chaque `store_fname` au disque | non |

### Le play 6 n'appelle pas `force_storage()`

Délibérément. Cette méthode d'Odoo refait son **propre** `search()`, et
`ir.attachment._search` injecte silencieusement `('res_field', '=', False)`
dans tout domaine qui ne mentionne pas ce champ.

Les avatars, photos d'employés et icônes de menu — qui sont des *valeurs de
champs binaires* — lui sont donc **invisibles**. Il les laisse en place et
rend `True`.

Mesuré : 36 pièces jointes en base, **14 migrées, 22 ignorées en silence**.

Le contournement, dans `roles/ansi_odoo/odoo_dbinit` — ne pas le « simplifier » :

```python
tous = ['|', ('res_field', '=', False), ('res_field', '!=', False)]
champ = {'db': 'store_fname', 'file': 'db_datas'}[Att._storage()]
for att in Att.search(tous + [(champ, '!=', False)]):
    with env.cr.savepoint():
        att.write({'datas': att.datas})
```

### Le play 7 dépend du sens

Vers le disque, il exige « plus rien en base » et lance un `VACUUM FULL` —
sans lui, PostgreSQL ne rend aucun espace et la migration paraît inutile.
Vers la base, il exige « plus rien sur disque » et saute le `VACUUM FULL`,
qui réécrirait pour rien une table qui vient de grossir.

---

## 4. `ansi_sauvegarde.yaml` — la copie

Trois plays, trois tags, **zéro logique** : chaque étape est un point d'entrée
du rôle `odoo_backup`.

```yaml
tasks:
  - ansible.builtin.import_role:
      name: odoo_backup
      tasks_from: sauvegarder      # ou : main / rapatrier
```

`import_role` et non la section `roles:` — celle-ci n'accepte pas
`tasks_from`, qui est précisément ce qui permet à un rôle d'avoir plusieurs
portes.

| Tag | Ce qu'il fait |
|---|---|
| `installer` | client PG15, `.pgpass`, script, timer quotidien |
| `sauvegarder` | lance une sauvegarde et rend compte |
| `rapatrier` | sort une copie **hors** du cluster |

### Une sauvegarde = deux fichiers du même horodatage

| Fichier | Contenu |
|---|---|
| `prod-<horodatage>.dump` | la base : données métier et **métadonnées** |
| `filestore-<horodatage>.tgz` | les **octets** des pièces jointes |
| `manifeste-<horodatage>.txt` | empreintes SHA-256 et comptages |

> Restaurer le `.dump` seul **réussit sans erreur** et donne une instance
> apparemment saine — jusqu'à ce qu'un utilisateur ouvre un document.

### Trois détails du script qui comptent

**Base d'abord, filestore ensuite.** L'inverse produirait des références
mortes ; dans ce sens, au pire des fichiers orphelins que personne ne
réclame.

**Suffixe `.part` puis `mv`.** Un fichier n'obtient son nom définitif qu'une
fois écrit en entier : une sauvegarde interrompue reste reconnaissable.

**Rotation seulement après un succès.** Vérifié : quand `pg_dump` échoue, le
script sort en 1, aucun `.dump` complet n'est créé, et les anciennes
sauvegardes sont intactes.

Automatique : timer systemd sur `.128`, 02h15, rétention 30 jours,
`/srv/sauvegardes`.

---

## 4bis. `ansi_postgresql_ha.yaml` — haute disponibilité de la base

Installe etcd, Patroni et HAProxy dans les trois conteneurs PostgreSQL
(groupe `db_cluster`), et confie PostgreSQL à Patroni. Au premier passage,
il **reprend** le cluster de `pg_server` sans recopie : `odoodb1` reste
primaire, `odoodb2` et `odoodb3` restent ses réserves. Toute situation
douteuse arrête le playbook avant qu'un service ne soit touché.

Il se joue sur les trois serveurs ensemble, jamais avec `--limit`. Il doit
être suivi sans attendre de `pg_ha_enabled: true`, puis de `ansi_odoo.yaml`
et `ansi_sauvegarde.yaml` : c'est ce qui fait passer Odoo par HAProxy. Une
fois Patroni en place, `ansi_odoo.yaml` joue `pg_ha` (play `2ter/5`) à la
place de `pg_server`, et `pg_server` refuse de toucher à un serveur repris.

Explication complète, exploitation et limites :
[POSTGRESQL-PATRONI.md](POSTGRESQL-PATRONI.md).

---

## 5. Les trois autres

### `nettoyage_odoo.yaml`

Réparation APT dans les conteneurs, **non destructif** :

```bash
ansible-playbook playbooks/nettoyage_odoo.yaml --ask-vault-pass
```

Avec `-e full_reset=true`, il supprime en plus les bases PostgreSQL et le
filestore : **destructif**.

### `nettoyage.yaml`

Désinstalle LXC des hôtes. Pour repartir de zéro au niveau des conteneurs
eux-mêmes, c'est lui **puis** `ansi2-snapchot.yaml`.

### `reseau-lxc.yaml`

Le seul playbook qui joue le rôle `lxc_lan`. `ansi_odoo.yaml` ne le joue
plus et suppose ce playbook déjà passé : il se lance avant lui, après la
correction d'horloge, voir [l'ordre de lancement](#ordre-de-lancement). Il
sert aussi seul, pour refaire le réseau d'un conteneur sans rejouer un
déploiement complet.

```bash
ansible-playbook -i inventory.yaml playbooks/reseau-lxc.yaml
ansible-playbook -i inventory.yaml playbooks/reseau-lxc.yaml --check --diff   # voir sans toucher
ansible-playbook -i inventory.yaml playbooks/reseau-lxc.yaml --limit 192.168.36.21
```

`hosts: gluster_servers`, `gather_facts: true` : `lxc_lan` lit
`ansible_default_ipv4` (passerelle et carte de l'hôte).
`vars_files: common/group_vars/local_dev.yml` fournit la variable `containers`.

**Ce que fait `lxc_lan`.** Il agit sur l'hôte : `/var/lib/lxc/<ct>/config` et le
rootfs du conteneur.

1. **Garde-fous**, avant toute modification :
   - `lxc_net_type` vaut `phys`, `macvlan` ou `ipvlan` (l'inventaire pose
     `ipvlan`), et `ct_ip` / `ct_prefix` sont définis ;
   - la passerelle est dans le sous-réseau du conteneur — calcul Python
     `ipaddress` sur le poste de contrôle (`delegate_to: localhost`), le Python
     de l'hôte n'étant pas garanti ;
   - en mode `phys` seulement : la carte cédée n'est pas celle qui porte la
     route par défaut de l'hôte, ce qui le couperait sans retour.
2. **Configuration LXC**, une clé `lxc.net.0.*` par `lineinfile` : `type`,
   `link` (`enp5s0` ou `enp1s0`, depuis `host_vars`), `name = eth0`,
   `flags = up`, `ipv4.address`, `ipv4.gateway`, et le mode (`ipvlan.mode = l2`).
   Les directives des autres modes et une `hwaddr` figée sont retirées. La
   configuration d'origine est copiée une seule fois en `config.orig`.
3. **Dans le rootfs** : `/etc/systemd/network/eth0.network` (`Address`,
   `Gateway`, une ligne `DNS=` par serveur). L'IP est posée deux fois, par LXC
   au démarrage et par systemd-networkd dans le conteneur : elle tient après
   un redémarrage, quel que soit celui qui passe en premier.
4. **Options** : `lxc_egress_nat` ajouterait une interface `eth1` sur
   `lxcbr0`, en masquerade derrière l'hôte (désactivé) ; `lxc_undo_routed=false`
   laisse les routes `10.0.x.0/24` en place.
5. **Redémarrage** : `lxc-stop`, `lxc-start -d`, puis attente de `RUNNING`
   par `lxc-info -sH` (100 × 2 s). En cas d'échec, un `rescue` affiche le
   journal LXC et la configuration lue.
6. **Attente de l'IP** : `lxc-attach` boucle 30 s sur `ip -4 addr show eth0`.
7. **Amorçage SSH** par `lxc-attach` : sources APT bookworm, réalignement des
   paquets (`realign_apt`), installation de `openssh-server`, `python3`,
   `python3-apt` (trois tentatives), clé du contrôleur dans
   `authorized_keys`, `PermitRootLogin prohibit-password`, `ssh-keygen -A`,
   puis contrôle que `:22` écoute et que `/usr/bin/python3` répond.
8. **Test final** : `wait_for :22` **depuis le poste de contrôle**. En ipvlan
   comme en macvlan, l'hôte ne joint pas son propre conteneur : le test fait
   depuis lui échouerait sur un conteneur sain.

> **LXC 3.0.4 : `lxc-attach` rend toujours 0.** Toute vérification faite dans
> le conteneur est validée sur un **marqueur** imprimé sur stdout (`IP_OK`,
> `BOOTSTRAP_SSH_OK`), jamais sur le code retour.

À la fin de ce playbook, Ansible joint chaque conteneur directement en SSH : c'est
ce qui rend possible `ansi_odoo.yaml`.

---

## Le fil conducteur

Quatre défaillances de ce projet partagent une cause : **un indicateur qui ne
mesurait pas ce qu'on croyait.**

| Indicateur | Ce qu'on croyait | Ce qu'il mesurait |
|---|---|---|
| `lxc-attach` rend 0 | la commande a réussi | rien — il rend **toujours** 0 |
| `odoo shell` rend 0 | la migration est complète | rien non plus |
| `RESTANT=0` | les octets sont arrivés | que `db_datas` est vide — la **source** |
| un répertoire existe | le volume partagé est monté | qu'un répertoire existe |

D'où les deux principes encodés partout dans ces playbooks :

**Valider sur des marqueurs de sortie**, jamais sur un code retour dont on
n'a pas vérifié la signification — `IP_OK`, `BOOTSTRAP_SSH_OK`,
`FILESTORE_PARTAGE_OK`, `RESTANT=0`, `SANS_FICHIER=0`.

**Vérifier la destination, pas la source.** Un déplacement de données doit
demander si les octets sont arrivés, pas seulement s'ils sont partis.

C'est pour cela que le rôle `odoo_filestore` ne teste pas « un montage
existe » mais « c'est bien du `fuse.glusterfs` » — la nuance qui a coûté une
journée de diagnostic le 25/09/2026.

---

## Dettes connues

1. **`lxc_lan` arrête et redémarre les conteneurs à chaque exécution**, même
   quand la configuration n'a pas changé : `changed_when: _lxc_stop.rc == 0`
   est inconditionnel. C'est une coupure de service gratuite à chaque
   `ansible-playbook reseau-lxc.yaml`. À convertir en `notify:` / handler.
2. **`roles/inutilises/odoo_net/`** — code mort, remplacé par `lxc_lan`.
3. **`gluster_servers`** — nom trompeur : il désigne les 4 hôtes physiques,
   pas les nœuds Gluster. Ceux-ci sont dans `gluster_bricks`.
4. **Purges one-shot rejouées à chaque passage** (~30 items sans effet) :
   `undo_routed`, `purge_replication`. Le flag `lxc_undo_routed` existe déjà
   pour les neutraliser.
