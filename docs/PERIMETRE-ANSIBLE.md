# Périmètre de l'automatisation

État au **25 septembre 2026**.

Ce que le dépôt Ansible gère, ce qu'il vérifie sans le poser, et ce qui reste
entièrement manuel. À lire avant de supposer qu'un rejeu de playbook remettra
l'infrastructure en état.

Documents voisins :
[ARCHITECTURE.md](ARCHITECTURE.md),
[EXPLICATION-DES-PLAYBOOKS.md](EXPLICATION-DES-PLAYBOOKS.md),
[sauvegarde-restauration.md](sauvegarde-restauration.md).

---

## Les quatre étages du filestore

```
┌─ GÉRÉ ─────────────────────────────────────────────────────────────────┐
│  Conteneur devodoo14                          Hôte node1               │
│  /var/lib/odoo/filestore/prod/ab/ab12…   ◄─bind─►   /mnt/odoo14/prod/…   │
└────────────────────────────────────────────────────────────────────────┘
┌─ VÉRIFIÉ, MAIS PAS POSÉ ───────────────────────────────────────────────┐
│               client FUSE  « node1:/odoo14 »                           │
└────────────────────────────────────────────────────────────────────────┘
┌─ PAS GÉRÉ DU TOUT ─────────────────────────────────────────────────────┐
│   glusterfsd node1       glusterfsd node3       glusterfsd node4       │
│   /bricks/odoo14/odoo    /bricks/odoo14/odoo    /bricks/odoo14/odoo    │
│   volume · pairs · briques · replica 3 · self-heal                     │
└────────────────────────────────────────────────────────────────────────┘
```

Le dépôt couvre **l'étage du haut**, contrôle celui du milieu, et ignore celui
du bas.

---

## ✅ Ce qui est géré

### Le bind conteneur ↔ hôte

[roles/odoo/odoo_filestore/tasks/main.yaml:131](../roles/odoo/odoo_filestore/tasks/main.yaml)

```yaml
- name: Partager le filestore avec le conteneur
  ansible.builtin.lineinfile:
    path: "/var/lib/lxc/{{ lxc_container_name }}/config"
    regexp: '^lxc\.mount\.entry\s*=.*\s{{ odoo_ct_filestore | regex_escape }}\s'
    line: >-
      lxc.mount.entry = {{ filestore_host_src }} {{ odoo_ct_filestore }}
      none bind,create=dir 0 0
  notify: redemarrer le conteneur
```

Source : `filestore_host_src: /mnt/odoo14`
([defaults:28](../roles/odoo/odoo_filestore/defaults/main.yml)).
Destination : `var/lib/odoo/filestore`, **relative** — syntaxe de `fstab`,
résolue depuis la racine du rootfs.

Le `regexp` discrimine sur le point de montage **destination** :
`lxc.mount.entry` est une directive répétable, un `lineinfile` par clé ne s'y
transposerait pas.

### Le chemin du filestore côté Odoo

[roles/odoo/odoo14/templates/odoo.conf.j2:39](../roles/odoo/odoo14/templates/odoo.conf.j2)
→ `data_dir = {{ odoo_data_dir }}`
[group_vars/odoo_containers/vars.yml:23](../group_vars/odoo_containers/vars.yml)
→ `/var/lib/odoo`

Les niveaux `prod/` et `ab/` ne sont configurés **nulle part** : Odoo les
fabrique lui-même, à partir du nom de la base et des deux premiers caractères
de l'empreinte SHA-1 du contenu.

### Les UID, des deux côtés du bind

| Où | Fichier | Valeur |
|---|---|---|
| dans le conteneur | [roles/odoo/odoo_uid/defaults/main.yml:30](../roles/odoo/odoo_uid/defaults/main.yml) | `105 / 112` |
| sur le volume | [roles/odoo/odoo_filestore/defaults/main.yml:65](../roles/odoo/odoo_filestore/defaults/main.yml) | `105 / 112` |

Les deux **doivent** concorder. Les conteneurs sont privilégiés (aucun
`lxc.idmap` dans le dépôt), donc les numéros traversent le bind sans
translation — et un système de fichiers partagé retient des **numéros**, pas
des noms.

### La récupération d'un filestore local laissé derrière

[roles/odoo/odoo_filestore/tasks/main.yaml:95](../roles/odoo/odoo_filestore/tasks/main.yaml)

`cp -a -n` depuis `/bricks/odoo14/prod` vers le volume : n'écrase jamais un
fichier présent. Les noms étant des empreintes SHA-1, deux fichiers de même
nom sont identiques par construction.

### Le refus d'écrire dans une brique

[roles/odoo/odoo_filestore/tasks/main.yaml:77](../roles/odoo/odoo_filestore/tasks/main.yaml)

Si le chemin partagé contient `.glusterfs`, c'est une brique : le rôle
s'arrête. Y faire écrire Odoo court-circuiterait la réplication et
corromprait l'index interne.

---

## ⚠️ Ce qui est vérifié, mais jamais posé

### Le montage FUSE

[roles/odoo/odoo_filestore/tasks/main.yaml:49](../roles/odoo/odoo_filestore/tasks/main.yaml)

```yaml
- name: Le filestore est bien servi par le volume GlusterFS
  ansible.builtin.assert:
    that:
      - _fs.rc == 0
      - filestore_fstype_attendu in _fs.stdout     # fuse.glusterfs
```

Le rôle **refuse de continuer** si `/mnt/odoo14` n'est pas un montage
`fuse.glusterfs`, et son message d'échec donne la commande de montage — mais
il ne la joue pas.

C'est une décision explicite, inscrite en tête du fichier :

```
roles/odoo/odoo_filestore/tasks/main.yaml:9
#         |  mount -t glusterfs                <- FAIT A LA MAIN, pas ici
```

> ### Pourquoi ce contrôle porte sur le TYPE et non sur l'existence
>
> Le 25/09/2026, les conteneurs se sont retrouvés bindés sur du stockage
> **local** au lieu du volume. Un contrôle « ce répertoire existe » serait
> passé sans broncher. Les trois filestores ont divergé — 37, 38 puis 39
> fichiers — et la base étant commune, deux nœuds sur trois citaient des
> fichiers qu'ils n'avaient pas. L'interface web est tombée en page blanche
> sur `.152` et `.153`, sans une seule erreur dans les journaux.

### La vérification depuis l'intérieur du conteneur

[roles/odoo/odoo_filestore/tasks/main.yaml:151](../roles/odoo/odoo_filestore/tasks/main.yaml)

Validée sur un **marqueur stdout** (`FILESTORE_PARTAGE_OK`) et non sur le code
retour : LXC 3.0.4 fait rendre 0 à `lxc-attach` même quand la commande interne
échoue.

### L'état du stockage, au préflight

[roles/exploitation/odoo_migration/tasks/preflight_hotes.yaml:44](../roles/exploitation/odoo_migration/tasks/preflight_hotes.yaml)

`findmnt --output FSTYPE,SOURCE,SIZE,AVAIL` — lecture seule, avant toute
modification.

---

## ❌ Ce qui n'est pas géré du tout

| Élément | Qui s'en occupe |
|---|---|
| création du volume `odoo14` | à la main |
| appairage des nœuds (`gluster peer probe`) | à la main |
| déclaration des briques, `replica 3` | à la main |
| démarrage / arrêt du volume | à la main |
| processus `glusterfsd`, ports, PID | GlusterFS lui-même |
| réparation (`self-heal`) | GlusterFS lui-même |
| **la ligne `/etc/fstab`** | **à la main — voir la lacune ci-dessous** |

Aucune tâche du dépôt ne contient `gluster volume create`, `gluster peer
probe` ni `mount -t glusterfs` en exécution. Les seules occurrences sont des
messages d'aide et des commentaires.

---

## Tableau de couverture

| Si… | Le playbook |
|---|---|
| le bind est perdu ou pointe ailleurs | **le repose** |
| `/mnt/odoo14` n'est pas monté | **s'arrête** et dit quoi faire |
| le montage pointe sur du disque local | **s'arrête** — garde-fou du 25/09 |
| le bind vise une brique | **s'arrête** |
| l'UID `odoo` a changé dans un conteneur | **le réaligne** |
| un ancien filestore local traîne | **le verse dans le volume** |
| une brique tombe | ne voit rien, ne fait rien |
| le volume est arrêté | s'arrête au premier `assert` |
| un `heal` est en attente | ne le voit pas |
| **un hôte redémarre sans ligne `fstab`** | **ne s'en aperçoit qu'au prochain passage** |

---

## La lacune connue

**Rien ne garantit que le montage revient après un redémarrage d'hôte.**

La ligne `/etc/fstab` a été posée à la main. Si elle disparaît, ou s'il lui
manque `_netdev` et `x-systemd.requires=glusterd.service`, le montage sera
tenté avant le réseau ou avant `glusterd` — il échouera, et Odoo repartira sur
un répertoire vide. Silencieusement, comme le 25/09.

La ligne attendue :

```
localhost:/odoo14 /mnt/odoo14 glusterfs defaults,_netdev,x-systemd.requires=glusterd.service,backup-volfile-servers=node1:node3:node4 0 0
```

| Option | Sans elle |
|---|---|
| `_netdev` | le montage est tenté avant le réseau |
| `x-systemd.requires=glusterd.service` | et avant le démon Gluster local |
| `backup-volfile-servers` | un `glusterd` local lent fait monter dans le vide |

### Deux façons de combler ça sans gérer le montage

**Un contrôle de la ligne `fstab`** — le rôle vérifie qu'elle existe et porte
les trois options, et refuse sinon. Il ne monte toujours rien : il constate.

**Un préflight Gluster en lecture seule** — état du volume, des pairs et de
`heal info`, avec `run_once` pour éviter le verrou de cluster que prennent les
commandes `gluster volume`.

Aucune des deux n'est implémentée à ce jour.

---

## Vérifier le périmètre soi-même

```bash
# Ce que le dépôt pose réellement
grep -rn "lxc.mount.entry" roles/odoo/odoo_filestore/tasks/main.yaml

# Ce qu'il refuse de poser
grep -rn "mount -t glusterfs\|gluster volume create\|gluster peer probe" roles/ playbooks/

# Ce qui est en place sur les hôtes, ici et maintenant
ansible gluster_bricks -k -m shell -a 'findmnt -n /mnt/odoo14 || echo "PAS MONTE"; grep odoo14 /etc/fstab || echo "PAS DANS FSTAB"'
ansible gluster_bricks -k -m shell -a 'grep lxc.mount.entry /var/lib/lxc/devodoo14/config'
```

La deuxième commande ne doit renvoyer que des commentaires et des messages
d'aide. Si elle renvoie une tâche, le périmètre décrit ici n'est plus à jour.
