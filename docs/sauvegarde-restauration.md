# Sauvegarde et restauration d'Odoo

Procédure opérationnelle. À suivre dans l'ordre, sans sauter d'étape.

Pour comprendre les playbooks qui produisent ces sauvegardes, voir
[EXPLICATION-DES-PLAYBOOKS.md](EXPLICATION-DES-PLAYBOOKS.md).

---

## Ce qu'une sauvegarde contient, et pourquoi c'est un couple

Depuis la bascule des pièces jointes sur disque, **une sauvegarde complète tient en deux fichiers indissociables** :

| Fichier | Contenu |
|---|---|
| `prod-<horodatage>.dump` | la base `prod` : données métier et **métadonnées** des pièces jointes |
| `filestore-<horodatage>.tgz` | les **octets** des pièces jointes |

Un troisième fichier, `manifeste-<horodatage>.txt`, porte les empreintes SHA-256 et les comptages.

> **Le piège à connaître.** Restaurer le `.dump` seul réussit sans la moindre erreur et donne une instance apparemment saine — jusqu'à ce qu'un utilisateur ouvre un document. La base cite alors des fichiers qui n'existent pas. Rien dans les journaux ne le signale au démarrage.
>
> Les deux fichiers du **même horodatage** vont toujours ensemble.

Ce n'était pas le cas avant le 24/09/2026 : les pièces jointes étaient stockées dans la base (`ir_attachment.location = db`), et un `pg_dump` suffisait. Les sauvegardes antérieures à cette date se restaurent donc seules.

---

## Où elles se trouvent

`/srv/sauvegardes/` sur **192.168.96.128**, rétention 30 jours, écrites chaque nuit à 02h15 par `odoo-sauvegarde.timer`.

```bash
ssh root@192.168.96.128 'ls -lt /srv/sauvegardes | head'
systemctl status odoo-sauvegarde.timer      # sur .128
journalctl -u odoo-sauvegarde.service -n 50 # dernière exécution
```

Une copie hors du cluster n'existe **que** si quelqu'un a lancé le rapatriement :

```bash
ansible-playbook playbooks/ansi_sauvegarde.yaml -k --ask-vault-pass -e sauvegarde_rapatrier=true
```

---

## Restauration complète

### 0. Arrêter les trois instances

Non négociable. Trois Odoo écrivant dans une base en cours de restauration la corrompent.

```bash
ansible odoo_containers -k -m service -a 'name=odoo state=stopped'
```

### 1. Choisir le couple de fichiers

```bash
ssh root@192.168.96.128
cd /srv/sauvegardes
ls -lt | head
cat manifeste-<horodatage>.txt     # vérifier les empreintes et les comptages
```

Note l'horodatage retenu. **Les deux fichiers doivent le partager.**

### 2. Restaurer la base

Depuis **.128**, qui possède le dump et le client PostgreSQL 15 :

```bash
export PGPASSFILE=/root/.pgpass
PG="-h 192.168.96.150 -p 5432 -U odoo"

dropdb   $PG --if-exists prod
createdb $PG -O odoo prod

# PostgreSQL 15 : sans ces deux lignes, pg_restore échoue en boucle sur
# "permission denied for schema public" et la base est inutilisable.
psql $PG -d prod -c 'ALTER DATABASE prod OWNER TO odoo' \
                 -c 'ALTER SCHEMA public OWNER TO pg_database_owner'

pg_restore $PG -d prod --no-owner --no-acl prod-<horodatage>.dump
```

### 3. Restaurer le filestore

Le filestore est **commun aux trois instances** : un volume GlusterFS replica 3 monté sur `/mnt/odoo14`. Une seule extraction suffit, et elle sert les trois nœuds.

**Depuis le point de montage, jamais dans `/bricks/odoo14/odoo`** — c'est la brique. Y écrire contourne la réplication et corrompt l'index `.glusterfs`.

```bash
# Mettre de côté l'existant plutôt que de l'écraser
mv /mnt/odoo14/prod /mnt/odoo14/prod.avant-restauration

tar xzf /srv/sauvegardes/filestore-<horodatage>.tgz -C /mnt/odoo14

# Les conteneurs sont privilégiés : les numéros traversent le bind tels quels.
chown -R 105:112 /mnt/odoo14/prod
```

`105:112` sont l'UID et le GID du compte `odoo` dans les conteneurs. Vérifier avec `ansible odoo_containers -m command -a 'id odoo'` s'ils ont changé.

### 4. Redémarrer et vérifier

```bash
ansible odoo_containers -k -m service -a 'name=odoo state=started'
```

Puis, obligatoirement :

1. Ouvrir un contact **qui a une photo** via `http://192.168.96.151:8069`. Si l'image s'affiche, le couple base/filestore est cohérent.
2. Rouvrir le même contact via `.152` et `.153`.

### 5. Effacer la copie de sécurité

Seulement après quelques jours de fonctionnement normal :

```bash
rm -rf /mnt/odoo14/prod.avant-restauration
```

---

## Cas particuliers

**Seul le filestore est perdu** (suppression accidentelle de fichiers) — ne touche pas à la base. Étapes 0, 3 et 4 uniquement. La base connaît déjà ces pièces jointes.

**Seule la base est perdue** — étapes 0, 2 et 4. Mais restaure un dump dont le filestore *actuel* contient encore tous les fichiers cités : si des pièces jointes ont été créées après le dump, leurs fichiers deviennent des orphelins inoffensifs. L'inverse serait grave.

**La sauvegarde est douteuse** — la tester avant de détruire l'existant. Le playbook qui le faisait a été supprimé le 30/09/2026 : la vérification est désormais manuelle. Restaurer le dump sur une base jetable, puis confronter ses `store_fname` au contenu de l'archive :

```bash
# Sur odoodb : une base jetable, que le dbfilter "^prod$" ne sert pas
sudo -u postgres createdb -O odoo prod_verif

# Sur .128 : la remplir, puis comparer
export PGPASSFILE=/root/.pgpass
pg_restore -h 192.168.96.150 -U odoo -d prod_verif --no-owner --no-acl <le .dump>
mkdir /tmp/verif && tar xzf <le .tgz> -C /tmp/verif
psql -h 192.168.96.150 -U odoo -d prod_verif -Atc \
  "SELECT store_fname FROM ir_attachment WHERE store_fname IS NOT NULL" \
  | while read f; do [ -f "/tmp/verif/prod/$f" ] || echo "MANQUANT $f"; done

# Puis nettoyer
sudo -u postgres dropdb prod_verif   # sur odoodb
rm -rf /tmp/verif                    # sur .128
```

Aucune ligne `MANQUANT` = les deux moitiés se correspondent.

---

## À ne pas faire

- **Écrire dans `/bricks/odoo14/odoo`.** C'est la brique, pas un répertoire ordinaire. Un fichier déposé là n'obtient ni GFID ni lien dans `.glusterfs` : il n'est pas répliqué, et le démon de réparation peut le supprimer. Le filestore se restaure par `/mnt/odoo14`.
- **Restaurer le filestore depuis plusieurs hôtes à la fois.** Le volume est partagé : une seule extraction suffit, trois extractions concurrentes se marchent dessus.
- **Restaurer un `.dump` sans son `.tgz`** du même horodatage — voir le premier encadré.
- **Faire confiance à une sauvegarde jamais restaurée.** Depuis la suppression du playbook de test, plus rien ne le vérifie automatiquement : la procédure manuelle ci-dessus est le seul recours.

---

## Ce que la sauvegarde ne protège pas

Depuis le retrait du montage GlusterFS le 25/09/2026, **plus rien ne couvre la panne d'un nœud** côté filestore : chaque instance a le sien, sur son propre volume logique, sans réplication. La perte de l'hôte `.129` emporte le filestore d'odoo2, et cette sauvegarde ne le contient pas — elle ne couvre que celui d'odoo1.

Ce qu'elle couvre en revanche : l'erreur humaine et la corruption logique sur la **base**, qui reste partagée et intégralement sauvegardée.

Symétriquement, une sauvegarde rangée sur `.128` ne protège pas de la **perte du cluster entier** — les quatre hôtes vivent vraisemblablement sur le même hyperviseur. Seul le rapatriement hors cluster couvre ce cas, et il n'a lieu que lorsqu'on le demande explicitement.
