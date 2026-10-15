# PostgreSQL 15 : réplication avec primaire fixe (mode alternatif)

> Ce guide décrit uniquement le mode `pg_ha_enabled: false`, avec le rôle
> `pg_replication`. La configuration courante utilise Patroni et etcd : voir
> [POSTGRESQL-PATRONI.md](POSTGRESQL-PATRONI.md). Les deux modes ne doivent
> jamais piloter les mêmes instances PostgreSQL simultanément. Désactiver
> la variable ne constitue pas une migration depuis un cluster Patroni.

Les trois conteneurs s’appellent `devpg15`, chacun sur son propre hôte LXC.
L’inventaire distingue leurs adresses SSH des adresses de leurs hôtes :

```ini
[db_containers]
odoodb1 ansible_host=192.168.33.156 lxc_host=192.168.33.21
odoodb2 ansible_host=192.168.33.157 lxc_host=192.168.33.22
odoodb3 ansible_host=192.168.33.158 lxc_host=168.168.33.23

[db_primary]
odoodb1

[db_replicas]
odoodb2
odoodb3
```

`odoodb1` remplace l’ancien serveur PostgreSQL `192.168.96.150`, hébergé
sur `192.168.96.141`. La configuration Odoo et les sauvegardes utilisent
désormais `odoo_db_host: 192.168.33.156`.
L’hôte physique `168.168.33.23` est conservé ; son conteneur utilise
`192.168.33.158`.

## Fonctionnement

Les trois instances Odoo lisent et écrivent sur **odoodb1 uniquement**.
Le rôle `pg_replication` configure une réplication physique en streaming
**asynchrone** vers `odoodb2` et `odoodb3`. Les répliques restent en lecture
seule ; elles ne constituent pas des cibles supplémentaires pour les
écritures Odoo.

Chaque réplique reçoit une copie initiale avec `pg_basebackup`, puis suit
les journaux du primaire. Un slot physique par réplique retient les journaux
encore nécessaires. Une réplique longtemps déconnectée peut donc faire
croître l’occupation disque du primaire : surveiller les slots, le retard
et l’espace disponible dans `pg_wal`.

Une transaction peut être validée sur le primaire avant d’avoir atteint les
répliques. **Aucune promotion ni bascule automatique PostgreSQL n’est
configurée.** Les utilisateurs accèdent directement aux Odoo sur
`http://192.168.96.151:8069`, `http://192.168.96.152:8069` ou
`http://192.168.96.153:8069`.

## Préparer les conteneurs et le secret

Les conteneurs doivent exister, avoir leurs IP LAN et être accessibles en
SSH depuis le poste Ansible. Les deux répliques doivent joindre
`192.168.33.156:5432`. Le primaire autorise leurs adresses exactes dans
`pg_hba.conf` ; les trois Odoo doivent également joindre le primaire
sur TCP 5432.

Les `host_vars` des hôtes PostgreSQL définissent `ct_ip`. Renseigner aussi
le masque (`ct_prefix`), les DNS (`ct_dns_servers`) et la passerelle
(`ct_gateway`) selon le réseau réel si les valeurs par défaut ne conviennent
pas. La passerelle doit appartenir au réseau du conteneur ; le rôle réseau
refuse une passerelle hors de ce réseau avant de l’appliquer.

Dans le fichier Vault existant, ajouter un mot de passe dédié :

```bash
ansible-vault edit group_vars/all/vault.yml
```

```yaml
vault_pg_replication_password: "REMPLACER_PAR_UN_SECRET_DEDIE"
```

La variable `pg_replication_password` reprend ce secret. Le compte PostgreSQL
de réplication est `replicator` par défaut (`pg_replication_user`). Il est
distinct du compte utilisé par Odoo. Les connexions utilisent le port
PostgreSQL 5432.

## Déployer

Pour configurer ce mode alternatif sur des instances qui ne sont pas
pilotées par Patroni :

```bash
ansible-playbook -i inventory.yaml playbooks/ansi_replication.yaml \
  --extra-vars pg_ha_enabled=false --ask-vault-pass
```

Le déploiement courant est décrit dans [POSTGRESQL-PATRONI.md](POSTGRESQL-PATRONI.md).

Les rôles et playbooks ont été préparés dans le dépôt. Leur présence ne
signifie pas qu’ils ont déjà été exécutés sur les serveurs.

## Données existantes et réinitialisation d’une réplique

Le changement d’adresse ne transfère pas les données de l’ancien serveur.
Si la base existe encore sur `192.168.96.150`, organiser sa sauvegarde et
sa restauration sur le nouveau primaire avant de redémarrer les écritures
Odoo. Il faut aussi conserver un filestore cohérent avec cette base.

La copie initiale d’une réplique utilise les données du primaire. Par défaut,
`pg_replica_allow_reseed: false` protège un cluster possédant des bases,
comptes ou objets applicatifs. Un cluster Debian nouvellement créé et vide
peut être initialisé sans lever cette protection. Une réplique déjà
configurée pour ce primaire est réutilisée.

Si une future réplique contient déjà une base `prod`, par exemple après
un ancien déploiement sans réplication, le rôle s’arrête. Après avoir
vérifié et sauvegardé ses données, on peut autoriser sa réinitialisation
en définissant `pg_replica_allow_reseed: true` dans les variables de ce
conteneur uniquement, par exemple `host_vars/odoodb2.yml`.

Le rôle prépare la nouvelle copie avant de remplacer le répertoire actif.
L’ancien répertoire de données est conservé à côté, avec le suffixe
`.before-replication`. Une nouvelle réinitialisation est refusée si cette
archive existe déjà ; la conserver ailleurs avant une autre tentative.
Prévoir l’espace pour la copie initiale et les anciennes données.
Retirer ensuite l’autorisation `pg_replica_allow_reseed` afin de retrouver
la protection par défaut.

## Vérifier après exécution

Le primaire doit voir deux connexions en état `streaming`, avec
`sync_state = async` :

```bash
ansible -i inventory.yaml db_primary --become --become-user postgres \
  -m command \
  -a 'psql -X -d postgres -c "SELECT client_addr, application_name, state, sync_state FROM pg_stat_replication;"' \
  --ask-vault-pass
```

Sur chaque réplique, `pg_is_in_recovery()` doit renvoyer `t` :

```bash
ansible -i inventory.yaml db_replicas --become --become-user postgres \
  -m command \
  -a 'psql -X -d postgres -c "SELECT pg_is_in_recovery();"' \
  --ask-vault-pass
```

Le récepteur de journaux doit annoncer `status = streaming` et
`sender_host = 192.168.33.156` :

```bash
ansible -i inventory.yaml db_replicas --become --become-user postgres \
  -m command \
  -a 'psql -X -d postgres -c "SELECT status, sender_host, sender_port FROM pg_stat_wal_receiver;"' \
  --ask-vault-pass
```

Ces contrôles vérifient le streaming ; ils ne simulent pas une panne ni
une promotion. La réplication ne remplace pas les sauvegardes de la base
et des pièces jointes.

Voir aussi [`ARCHITECTURE-DIAGRAMME.md`](ARCHITECTURE-DIAGRAMME.md).
