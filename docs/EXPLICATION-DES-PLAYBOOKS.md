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
| déployer / mettre à jour | `ansible-playbook playbooks/ansi_odoo.yaml -k --ask-vault-pass` |
| corriger l'horloge seule | `… ansi_odoo.yaml -k --ask-vault-pass --tags horloge` |
| ne rejouer que la base | `… ansi_odoo.yaml -k --ask-vault-pass --limit odoodb` |
| état des lieux avant migration | `… ansi_syncro.yaml -k --ask-vault-pass --tags preflight` |
| rebrancher le filestore | `… ansi_syncro.yaml -k --ask-vault-pass --tags filestore` |
| vérifier base ↔ filestore | `… ansi_syncro.yaml -k --ask-vault-pass --tags verif` |
| sauvegarder maintenant | `ansible-playbook playbooks/ansi_sauvegarde.yaml -k --ask-vault-pass` |
| copie hors cluster | `… ansi_sauvegarde.yaml … -e sauvegarde_rapatrier=true` |

---

## Trois familles

```
CONSTRUIRE     ansi2-snapchot.yaml          crée les conteneurs LXC
               ansi_odoo.yaml               déploie tout

EXPLOITER      ansi_syncro.yaml             déplace les pièces jointes
               ansi_sauvegarde.yaml         sauvegarde

DÉFAIRE        nettoyage_odoo.yaml          remet les conteneurs Odoo à plat
               nettoyage.yaml               désinstalle LXC des hôtes

FRAGMENT       reseau-lxc.yaml              le réseau seul, sans le reste
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

Six plays. **L'ordre est contraignant**, et chaque étape est là pour une
raison précise.

| # | Hôtes | Rôles | Pourquoi ici |
|---|---|---|---|
| 0 | `localhost` | — | versions d'Ansible et des collections |
| 1 | `gluster_servers` | `chrony`, `lxc_lan` | l'horloge d'abord, puis le réseau |
| 2 | `db_containers` | `pg_server` | la base avant tout client |
| 3 | `odoo_containers` | `odoo14` | Odoo installé, **laissé arrêté** |
| 4 | `odoo_primary` | `odoo_dbinit` | le registre, par **un seul** nœud |
| 5 | `odoo_containers` | — | démarrage |

### Play 0 — tagué `never`

Il vérifie qu'Ansible est dans la fourchette validée. `ansible.posix 1.1.1`
déclare `requires_ansible: >=2.9,<2.11` : monter Ansible impose de monter
aussi les collections, et inversement.

Il **ne tourne plus par défaut**. Le tag `never` est l'idiome Ansible pour
« seulement sur demande » — le poste de contrôle bouge rarement, et le
vérifier à chaque déploiement n'apprend rien.

```bash
--tags all,preflight    # avec tout le reste
--tags preflight        # seul, sans toucher aux hôtes
```

### Play 1 — pourquoi `chrony` avant `lxc_lan`

Une horloge fausse fait échouer `apt-get update` dans les conteneurs avec
*« Release file is **not valid yet** »* — c'est le contrôle du champ `Date:`,
l'inverse du cas expiré, donc `Acquire::Check-Valid-Until` n'y peut rien.

Corriger l'heure est un **prérequis**, pas une finition.

Les conteneurs LXC n'ont pas d'horloge propre : ils lisent celle du noyau de
l'hôte. Corriger l'hôte les corrige instantanément, rien à faire dedans.

Tag `horloge` pour ne jouer que ça, sans redémarrer les conteneurs :

```bash
ansible-playbook playbooks/ansi_odoo.yaml -k --ask-vault-pass --tags horloge
```

### Plays 3 et 4 — le garde-fou triple

Trois `odoo -i base` concurrents sur une base partagée **corrompent le
registre**. Trois protections indépendantes l'empêchent :

1. le groupe `odoo_primary` ne contient qu'un hôte ;
2. le play 4 est distinct du play 3, et s'exécute alors qu'Odoo est **arrêté
   partout** ;
3. une sonde `to_regclass('public.ir_module_module')` rend l'initialisation
   conditionnelle — `to_regclass` renvoie `NULL` sur une base vierge au lieu
   de lever une erreur.

C'est pour cela que le play 3 laisse le service **arrêté** : démarrer les
trois instances avant l'étape 4 leur ferait ouvrir un registre à moitié
construit.

### Options utiles

```bash
--limit odoodb          # ne rejouer que la play 2 (la base)
--tags horloge          # ne rejouer que l'horloge
--tags all,preflight    # avec le contrôle d'environnement
```

**Quand le lancer :** à chaque changement de configuration.

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

Le contournement, dans `roles/odoo_dbinit` — ne pas le « simplifier » :

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

Le seul rôle `lxc_lan`, sans le reste. Utile pour refaire le réseau d'un
conteneur sans rejouer un déploiement complet.

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
   `ansible-playbook ansi_odoo.yaml`. À convertir en `notify:` / handler.
2. **`roles/odoo_net/`** — code mort, remplacé par `lxc_lan`.
3. **`gluster_servers`** — nom trompeur : il désigne les 4 hôtes physiques,
   pas les nœuds Gluster. Ceux-ci sont dans `gluster_bricks`.
4. **Purges one-shot rejouées à chaque passage** (~30 items sans effet) :
   `undo_routed`, `purge_replication`. Le flag `lxc_undo_routed` existe déjà
   pour les neutraliser.
