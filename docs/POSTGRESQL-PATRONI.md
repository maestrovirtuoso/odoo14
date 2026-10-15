# PostgreSQL 15 avec Patroni et etcd

Le mode courant est `pg_ha_enabled: true`. Chaque conteneur PostgreSQL
héberge PostgreSQL 15, Patroni et un membre etcd. Patroni surveille les
instances et utilise le consensus etcd pour choisir un primaire.

| Alias | IP du conteneur | Hôte LXC | Rôle initial |
| --- | --- | --- | --- |
| `odoodb1` | `192.168.33.156` | `192.168.33.21` | Primaire prévu au démarrage |
| `odoodb2` | `192.168.33.157` | `192.168.33.22` | Réplique |
| `odoodb3` | `192.168.33.158` | `168.168.33.23` | Réplique |

Les trois conteneurs s’appellent `devpg15`, chacun sur son hôte.
L’adresse physique `168.168.33.23` est conservée ; son conteneur utilise
bien `192.168.33.158`.

## Réplication et élection

Les écritures sont acceptées par le primaire courant. Les répliques suivent
ses journaux WAL et restent en lecture seule. Après une panne du primaire,
Patroni peut promouvoir une réplique éligible et reconfigurer les autres
membres autour du nouveau primaire.

Les trois membres etcd nécessitent un **quorum de deux** pour coordonner
le cluster. La perte d’un serveur permet de conserver ce quorum ; la perte
de deux membres ne permet plus une nouvelle élection sûre. La possibilité
d’élire un primaire dépend aussi de l’état des répliques et des règles
Patroni, pas uniquement du nombre de serveurs joignables.

## Accès Odoo après une bascule

Les utilisateurs accèdent directement aux trois applications :

- `http://192.168.96.151:8069`
- `http://192.168.96.152:8069`
- `http://192.168.96.153:8069`

Au démarrage, `odoo_db_host` cible `192.168.33.156`. **L’élection d’un nouveau
primaire PostgreSQL ne change pas automatiquement cette adresse dans
Odoo.** Après une bascule, relever l’adresse du primaire courant puis
modifier `odoo_db_host` dans `group_vars/all/vars.yml` pour cette adresse.
Appliquer ensuite le changement aux trois Odoo :

```bash
ansible-playbook -i inventory.yaml playbooks/ansi_odoo_dbhost.yaml --ask-vault-pass
```

Ce playbook vérifie que la nouvelle cible SQL est un primaire, modifie
uniquement `db_host` dans la configuration Odoo et redémarre les instances
une par une, sans réinitialiser la base. Les sauvegardes SQL doivent aussi
cibler le primaire courant.
Une découverte automatique du primaire par les applications reste une
évolution distincte.

Les groupes `db_primary` et `db_replicas` décrivent le placement initial.
Ils ne suivent pas les promotions Patroni ; leur contenu ne constitue
donc pas un contrôle du primaire courant.

## Préparer le réseau et les secrets

Les conteneurs doivent être créés, disposer de leurs adresses LAN et être
joignables en SSH depuis le poste Ansible. Vérifier les valeurs `ct_ip`,
`ct_prefix`, `ct_gateway` et `ct_dns_servers` dans les variables des hôtes.

Les communications nécessaires sont :

| Port TCP | Communication |
| --- | --- |
| `5432` | Odoo vers le primaire ; réplication entre les PostgreSQL |
| `2379` | Patroni vers les membres etcd |
| `2380` | Membres etcd entre eux |
| `8008` | API REST Patroni, communication entre membres et administration |
| `22` | Poste Ansible vers les hôtes et conteneurs |

Le fichier [`vault.yml.example`](../group_vars/all/vault.yml.example)
décrit les secrets attendus. Renseigner leurs valeurs dans le fichier
Vault chiffré existant :

```bash
ansible-vault edit group_vars/all/vault.yml
```

Les secrets Odoo, de réplication et d’administration Patroni/PostgreSQL
ont des usages différents. Fournir des valeurs dédiées selon cet exemple.

```yaml
vault_pg_replication_password: "REMPLACER_PAR_UN_SECRET_DEDIE"
vault_pg_patroni_superuser_password: "REMPLACER_PAR_UN_AUTRE_SECRET"
vault_pg_patroni_rest_password: "REMPLACER_PAR_UN_AUTRE_SECRET_REST"
```

## Déployer

Pour déployer PostgreSQL, Patroni et etcd sans installer Odoo :

```bash
ansible-playbook -i inventory.yaml playbooks/ansi_postgresql_ha.yaml --ask-vault-pass
```

Le déploiement principal utilise le rôle `pg_ha` avant d’initialiser et
de démarrer les applications :

```bash
ansible-playbook -i inventory.yaml playbooks/ansi_odoo.yaml --ask-vault-pass
```

La configuration du dépôt ne signifie pas que les services sont déjà
déployés sur les serveurs.

## Données existantes

Le changement depuis l’ancien serveur `192.168.96.150` n’effectue aucune
migration de ses bases. Une reprise nécessite une sauvegarde et une
procédure de restauration cohérente avec le filestore Odoo.

Un ancien cluster utilisant le rôle `pg_replication` ne doit pas être
piloté simultanément par Patroni. Le guide
[`POSTGRESQL-REPLICATION.md`](POSTGRESQL-REPLICATION.md) décrit ce mode
alternatif, uniquement lorsque `pg_ha_enabled: false`.
Changer ce booléen ne convertit pas les données et ne constitue pas une
procédure de migration entre les deux modes.

Voir le [diagramme d’architecture](ARCHITECTURE-DIAGRAMME.md).
