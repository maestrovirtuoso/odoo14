# Haute disponibilité PostgreSQL : Patroni, etcd et HAProxy

Ce document explique le rôle [`roles/ansi_postgresql_ha/pg_ha`](../roles/ansi_postgresql_ha/pg_ha/) et le playbook
[`playbooks/ansi_postgresql_ha.yaml`](../playbooks/ansi_postgresql_ha.yaml).
Ensemble, ils rendent la base PostgreSQL d'Odoo **hautement disponible** :
si le serveur primaire tombe, une réserve prend sa place automatiquement,
et Odoo la retrouve sans qu'on touche à sa configuration.

> **État au 23/10/2026 : écrit, ni testé ni déployé.**
> Le code n'a pas été exécuté. Ni sur les conteneurs, ni sur un
> environnement de test. Le premier passage doit se faire à un moment calme,
> après une sauvegarde (§ 5.2).

Documents voisins :
[ARCHITECTURE-ACTUELLE.md](ARCHITECTURE-ACTUELLE.md),
[POSTE-CONTROLE-UBUNTU-DEBIAN.md](POSTE-CONTROLE-UBUNTU-DEBIAN.md),
[sauvegarde-restauration.md](sauvegarde-restauration.md).

---

## 1. Ce qui change

| | Aujourd'hui (`pg_server`) | Avec Patroni (`pg_ha`) |
|---|---|---|
| Primaire | `odoodb1`, fixé dans l'inventaire | celui que Patroni désigne, qui peut changer |
| Panne du primaire | Odoo arrêté jusqu'à une intervention manuelle | une réserve est promue en 30 à 45 s environ |
| Adresse visée par Odoo | `192.168.33.161:5432` | les trois HAProxy : `192.168.33.161,162,163:5000` |
| Ancien primaire qui revient | à reconstruire à la main | Patroni le remet en réserve (`pg_rewind`) |
| Données | inchangées | inchangées : Patroni **reprend** les répertoires existants |

```
                    Odoo 1, 2, 3   (réseau 192.168.36.0/24, à travers le NAT)
                          │
          host=192.168.33.161,192.168.33.162,192.168.33.163  port=5000
                          │      libpq essaie dans l'ordre
          ┌───────────────┼────────────────────────┐
          ▼               ▼                        ▼
 ┌─ odoodb1 .161 ─┐ ┌─ odoodb2 .162 ─┐   ┌─ odoodb3 .163 ─┐
 │ HAProxy  :5000 │ │ HAProxy  :5000 │   │ HAProxy  :5000 │   ─┐ chaque HAProxy
 │ Patroni  :8008 │ │ Patroni  :8008 │   │ Patroni  :8008 │    │ envoie au primaire
 │ PostgreSQL     │ │ PostgreSQL     │   │ PostgreSQL     │   ─┘ du moment
 │  PRIMAIRE :5432│ │  réserve :5432 │   │  réserve :5432 │
 │ etcd :2379/2380│ │ etcd :2379/2380│   │ etcd :2379/2380│
 └───────┬────────┘ └───────┬────────┘   └───────┬────────┘
         └── réplication streaming (WAL) ───────┘
         └──── etcd : quorum de 2 sur 3 ─────────┘
```

---

## 2. Les trois composants

**etcd** est le registre partagé. Il tient une clé « leader » qu'**un seul**
serveur peut détenir à la fois. Ses trois membres, un par conteneur, doivent
être au moins **deux** à se voir (quorum) pour accepter une écriture. Un
serveur isolé ne peut donc jamais se proclamer primaire seul.

**Patroni** tourne sur chaque serveur. C'est lui, et non plus Debian, qui
démarre et arrête PostgreSQL. Le primaire renouvelle la clé « leader » toutes
les 10 s. S'il ne la renouvelle plus pendant 30 s (`ttl`), la réserve la plus
à jour la prend et devient primaire. L'autre réserve et l'ancien primaire,
quand il revient, se mettent à la suivre.

**HAProxy** tourne sur chaque serveur, sur le port 5000. Toutes les 3 s, il
demande à l'API de Patroni de chacun des trois serveurs : « es-tu primaire ? »
(`GET /primary`). Seul le primaire répond `200`, et HAProxy ne lui envoie
que les connexions de ce serveur-là.

**Pourquoi trois HAProxy et pas un seul ?** Un HAProxy unique serait un point
de panne. Odoo reçoit les trois adresses (`odoo_db_host`), et libpq, la
bibliothèque qu'utilise Odoo, passe à l'adresse suivante si l'une ne répond
pas. `PGTARGETSESSIONATTRS=read-write` lui fait aussi écarter un serveur qui
serait en lecture seule.

### Ce qui se passe quand le primaire tombe

| Temps | Événement |
|---|---|
| 0 s | le primaire s'arrête |
| ≤ 9 s | les HAProxy l'écartent (3 contrôles ratés à 3 s d'intervalle) ; Odoo n'a plus de base |
| ≤ 30 s | la clé « leader » expire dans etcd |
| ~30–40 s | Patroni promeut la réserve la plus à jour, si son retard est inférieur à 1 Mo |
| + ≤ 6 s | les HAProxy la voient primaire (2 contrôles réussis) ; Odoo écrit de nouveau |

Pendant ce délai, les requêtes Odoo échouent. Odoo remplace lui-même ses
connexions coupées : les utilisateurs voient une erreur, rechargent la page,
et reprennent.

---

## 3. Ports et flux

| Port | Entre | Rôle |
|---|---|---|
| 5000 | Odoo, sauvegarde → les 3 conteneurs PostgreSQL | HAProxy, vers le primaire |
| 5432 | entre les 3 conteneurs PostgreSQL | réplication, `pg_rewind`, HAProxy → PostgreSQL |
| 8008 | entre les 3 conteneurs PostgreSQL | API REST de Patroni (contrôles HAProxy, bascules) |
| 2379 | entre les 3 conteneurs PostgreSQL | etcd, clients (Patroni) |
| 2380 | entre les 3 conteneurs PostgreSQL | etcd, entre membres |
| 7000 | boucle locale seulement | page d'état de HAProxy |

Tout est chiffré, sauf l'API de Patroni :

- **PostgreSQL** : TLS vérifié (`verify-full`) et certificat client exigé
  pour Odoo. Chaque serveur reçoit un **nouveau** certificat (`pki/pgha-*.crt`)
  qui porte les **trois** adresses. Une connexion entrée par le HAProxy de
  `odoodb1` peut en effet aboutir sur le primaire `odoodb2`, qui doit alors
  prouver qu'il est bien l'adresse que le client a visée.
- **etcd** : TLS avec certificat client, émis par une autorité **séparée**
  (`pki/etcd/`). Pouvoir écrire dans etcd revient à pouvoir changer les
  paramètres de PostgreSQL. Avec l'autorité commune, le certificat client
  d'un conteneur Odoo suffirait.
- **API de Patroni** : HTTP. Les lectures sont libres, car HAProxy en a
  besoin. Les actions (bascule, configuration) exigent le compte `patroni`.

---

## 4. Ce que fait le playbook

Le rôle se déroule dans cet ordre, sur les trois serveurs ensemble :

1. **Contrôles**. Le rôle vérifie les trois serveurs, les secrets, et la
   présence de l'autorité de certification **existante**. Si elle manquait,
   une nouvelle serait créée et Odoo rejetterait tous les serveurs.
2. **Paquets** : `patroni`, `etcd-server`, `haproxy`. Ils sont installés
   **sans démarrer** leurs services.
3. **Constat et décision**. Le rôle constate l'état de chaque serveur sans
   rien arrêter : il lit le fichier de contrôle sur disque (`pg_controldata`)
   et compte les bases présentes. Il décide ensuite :

   | Décision | Quand | Ce qui est fait |
   |---|---|---|
   | `demarrer` | serveur déjà repris par Patroni | Patroni est démarré s'il ne tourne pas |
   | `primaire` | premier passage, `odoodb1`, qui n'est pas en réserve | Debian arrête PostgreSQL, Patroni le redémarre et **adopte** ses données |
   | `reserve` | même cluster que le primaire (même identifiant système), en réserve | idem, sans recopie : il reprend en réserve |
   | `recopie` | cluster étranger **sans aucune base** (cluster vide du paquet) | vidé puis recopié depuis le primaire |
   | `refus` | tout le reste | **arrêt du playbook** |

   Un refus arrête tout à cette étape. Aucun service n'a encore été
   configuré ni arrêté, et `pg_server` reste utilisable.
4. **Certificats**, puis **etcd**, démarré sur les trois serveurs en même
   temps. Le rôle vérifie qu'il est sain avec ses trois membres. Vient
   ensuite la configuration de Patroni, encore sans le démarrer.
5. **Reprise** de PostgreSQL. Le primaire passe en premier ; le rôle attend
   qu'etcd le confirme comme primaire, puis reprend les réserves. **Odoo
   perd la base quelques secondes**, le temps que Patroni redémarre
   `odoodb1`. Il le vise toujours en direct sur 5432, et `odoodb1` reste
   primaire.

   À chaque serveur repris, juste avant le premier démarrage de Patroni, le
   rôle retire PostgreSQL à Debian :

   - l'unité `postgresql@15-main` est masquée, et `start.conf` passe à
     `disabled`. C'est aussi la marque « serveur repris » que lit l'étape 3 ;
   - les fichiers `conf.d/10-prosys.conf` et `20-replication.conf` de
     `pg_server` sont renommés en `.avant-patroni` ;
   - l'ancien `.pgpass` est supprimé.

6. **Comptes et configuration**. Sur le primaire, le rôle pose le mot de
   passe de `postgres` (nécessaire à `pg_rewind`) et vérifie les rôles
   `replicator` et `odoo` ainsi que la base `prod`. Il remet aussi la
   configuration dynamique d'etcd en conformité avec `pg_ha_dcs`.
7. **HAProxy**, puis **vérification**. Le rôle attend un primaire et deux
   réserves avec moins de 16 Mo de retard. Il ouvre ensuite une vraie
   connexion TLS à travers chaque HAProxy et vérifie qu'elle aboutit au
   primaire.

Rejoué ensuite, le playbook ne fait que vérifier et remettre en conformité,
**sans coupure**.

---

## 5. Mise en place, pas à pas

### 5.1 Prérequis

- Lancer le playbook **depuis le poste de contrôle qui a déployé la base**,
  celui qui détient `pki/` et le vault. Le rôle refuse de démarrer sans
  `pki/ca.key`.
- Ouvrir les ports du § 3. Entre les trois conteneurs PostgreSQL, le trafic
  reste sur le même réseau, sans NAT. Le port 5000 doit être joignable depuis
  le réseau Odoo, comme 5432 l'est aujourd'hui.
- Ajouter deux secrets au vault, d'au moins 12 caractères et différents des
  autres mots de passe :

  ```bash
  ansible-vault edit group_vars/all/vault.yml
  ```

  ```yaml
  vault_pg_patroni_superuser_password: "…"
  vault_pg_patroni_rest_password: "…"
  ```

### 5.2 Sauvegarder d'abord

La reprise ne recopie ni n'efface aucune base. Une sauvegarde reste le seul
retour arrière sûr. Sur l'hôte de sauvegarde :

```bash
systemctl start odoo-sauvegarde.service   # ou la procédure de sauvegarde-restauration.md
```

### 5.3 Lancer la reprise

```bash
ansible-playbook playbooks/ansi_postgresql_ha.yaml --ask-vault-pass
```

Le message « Bilan de la reprise » doit annoncer `primaire` pour `odoodb1`
et `reserve` pour `odoodb2` et `odoodb3`. Un `refus` arrête le playbook
avant que le moindre service ne soit touché (§ 8).

**Si Patroni ne démarre pas sur `odoodb1`**, la tâche « Le cluster a un
primaire » échoue au bout de 3 minutes. À ce moment, Debian a déjà arrêté
PostgreSQL : **Odoo n'a plus de base**. Lire d'abord la cause
(`journalctl -u patroni -n 50` sur `odoodb1`). Pour rendre la base à Debian
immédiatement, lancer sur `odoodb1` :

```bash
systemctl stop patroni && systemctl disable patroni
systemctl unmask postgresql@15-main
echo auto > /etc/postgresql/15/main/start.conf
for f in 10-prosys 20-replication; do
  mv /etc/postgresql/15/main/conf.d/$f.conf.avant-patroni /etc/postgresql/15/main/conf.d/$f.conf
done
rm -f /etc/patroni/config.yml      # sinon pg_server refuse de reprendre la main
systemctl start postgresql@15-main
```

Les réserves n'ont pas encore été touchées à ce stade : elles suivent
toujours `odoodb1`. Une fois la cause corrigée, relancer le playbook.

### 5.4 Vérifier

Sur n'importe lequel des trois conteneurs :

```bash
patronictl -c /etc/patroni/config.yml list
```

```
+ Cluster: odoo-pg ---------+---------+-----------+----+-----------+
| Member  | Host            | Role    | State     | TL | Lag in MB |
+---------+-----------------+---------+-----------+----+-----------+
| odoodb1 | 192.168.33.161  | Leader  | running   |  1 |           |
| odoodb2 | 192.168.33.162  | Replica | streaming |  1 |         0 |
| odoodb3 | 192.168.33.163  | Replica | streaming |  1 |         0 |
+---------+-----------------+---------+-----------+----+-----------+
```

### 5.5 Faire passer Odoo par HAProxy — à enchaîner sans attendre

Tant que cette étape n'est pas faite, Odoo vise `odoodb1` en direct. Après
une bascule, il resterait alors sur un serveur en lecture seule.

1. Dans [`group_vars/all/vars.yml`](../group_vars/all/vars.yml), passer
   `pg_ha_enabled: true`.
2. Rejouer les déploiements :

   ```bash
   ansible-playbook playbooks/ansi_odoo.yaml --ask-vault-pass
   ansible-playbook playbooks/ansi_sauvegarde.yaml --ask-vault-pass
   ```

`odoo.conf` reçoit alors `db_host = 192.168.33.161,192.168.33.162,192.168.33.163`
et `db_port = 5000`. Dans `ansi_odoo.yaml`, la play `2ter/5` (Patroni)
remplace les plays `2/5` et `2bis/5` (`pg_server`).

### 5.6 Tester une bascule

À faire une fois, à un moment calme, pour voir le mécanisme fonctionner.

**Bascule planifiée** (propre, sans perte) :

```bash
patronictl -c /etc/patroni/config.yml switchover odoo-pg --candidate odoodb2
patronictl -c /etc/patroni/config.yml list     # odoodb2 est Leader
```

**Panne simulée** : arrêter Patroni sur le primaire du moment, qui arrête
alors PostgreSQL proprement.

```bash
systemctl stop patroni           # sur le primaire
patronictl -c /etc/patroni/config.yml list     # depuis un autre serveur : un nouveau Leader
systemctl start patroni          # l'ancien primaire revient en Replica
```

Pendant ces deux tests, Odoo doit continuer de fonctionner après quelques
secondes d'erreurs.

---

## 6. Exploitation courante

| Besoin | Commande (sur un conteneur PostgreSQL) |
|---|---|
| État du cluster | `patronictl -c /etc/patroni/config.yml list` |
| Bascule planifiée | `patronictl -c /etc/patroni/config.yml switchover odoo-pg` |
| Recopier entièrement une réserve | `patronictl -c /etc/patroni/config.yml reinit odoo-pg odoodb3` |
| Journal de Patroni | `journalctl -u patroni -f` |
| État d'etcd | `ETCDCTL_CACERT=/etc/etcd/ssl/ca.crt ETCDCTL_CERT=/etc/etcd/ssl/server.crt ETCDCTL_KEY=/etc/etcd/ssl/server.key etcdctl --endpoints=https://127.0.0.1:2379 endpoint health --cluster` |
| Page d'état HAProxy | `ssh -L 7000:127.0.0.1:7000 root@192.168.33.161`, puis <http://127.0.0.1:7000/> |

**Changer un paramètre PostgreSQL commun** (par exemple `max_connections`) :

1. Le modifier dans `pg_ha_dcs`, dans
   [`roles/ansi_postgresql_ha/pg_ha/defaults/main.yml`](../roles/ansi_postgresql_ha/pg_ha/defaults/main.yml).
2. Rejouer le playbook. La valeur est écrite dans etcd, et Patroni l'applique
   aux trois serveurs.
3. Si le paramètre exige un redémarrage, le playbook affiche « attend un
   redémarrage ». Le faire à un moment choisi, réserves d'abord :

   ```bash
   patronictl -c /etc/patroni/config.yml restart odoo-pg
   ```

**Ne pas** utiliser `patronictl edit-config` pour un changement durable : le
playbook remet la configuration d'etcd à l'identique de `pg_ha_dcs` à chaque
passage.

**Ne plus** utiliser `systemctl restart postgresql`, `pg_ctlcluster` ou
`pg_ctl` : c'est Patroni qui démarre et arrête PostgreSQL. L'unité Debian est
masquée pour cette raison. Pour redémarrer un serveur, utiliser `patronictl
restart`.

---

## 7. Limites, à connaître

1. **Pas de chien de garde matériel.** Dans un conteneur LXC, il n'y a pas de
   `/dev/watchdog`. Si Patroni plantait, systemd le relancerait en 5 s, et il
   constaterait qu'il a perdu le verrou. Mais s'il restait bloqué sans
   planter, l'ancien primaire continuerait d'accepter des écritures pendant
   qu'une réserve est promue. Le risque est faible mais réel.
2. **Quorum etcd : 2 sur 3.** La perte d'un serveur est tolérée. Avec deux
   serveurs perdus, le dernier se met en **lecture seule**, car il ne peut pas
   savoir s'il est seul ou isolé. Odoo est alors arrêté : c'est voulu.
3. **Réplication asynchrone.** À une bascule non planifiée, les dernières
   écritures du primaire, jusqu'à 1 Mo (`maximum_lag_on_failover`), peuvent
   être perdues. Le mode synchrone (`synchronous_mode: true` dans
   `pg_ha_dcs`) l'éviterait, au prix d'écritures plus lentes et d'un arrêt
   des écritures si aucune réserve ne répond.
4. **Sauvegardes par HAProxy.** Les connexions relayées par HAProxy exigent
   un certificat client (`clientcert=verify-full`). Les Odoo en ont un.
   L'hôte de sauvegarde n'en a pas dans ce dépôt
   ([`roles/ansi_sauvegarde/odoo_backup`](../roles/ansi_sauvegarde/odoo_backup/)) : une fois
   `pg_ha_enabled: true`, `pg_dump` sera refusé tant qu'on ne lui en donne pas
   un, émis de la même façon que pour les Odoo.
5. **Groupes de l'inventaire.** `db_containers` (`odoodb1`) et `db_replicas`
   ne décrivent plus que le placement d'origine. Après une bascule,
   [`ansi_syncro.yaml`](../playbooks/ansi_syncro.yaml) et
   [`roles/nettoyage_odoo/odoo_cleanup`](../roles/nettoyage_odoo/odoo_cleanup/), qui traitent
   `db_containers` comme « la » base, viseraient une réserve. Les vérifier
   avant de les utiliser.
6. **Les tâches planifiées d'Odoo** restent sur `odoo1` seul : la haute
   disponibilité de la base ne les rend pas disponibles si `odoo1` tombe.

---

## 8. Dépannage

| Symptôme | Cause probable | Que faire |
|---|---|---|
| `Refuser tout cas qui risquerait de perdre…` | voir ci-dessous | voir « Reprise refusée » |
| `pki/ca.key est absent` | playbook lancé depuis un autre poste | le lancer depuis le poste de contrôle de la base |
| etcd ne démarre pas, `Le cluster etcd est sain` échoue | 2379/2380 fermés entre conteneurs, ou un membre absent | `journalctl -u etcd` sur chaque serveur ; vérifier les ports |
| Patroni s'arrête : `system ID mismatch` | le serveur porte un autre cluster | cas « Reprise refusée » ; ou `patronictl reinit` si c'est une réserve |
| `patronictl list` : une réserve en `start failed` | elle a divergé et `pg_rewind` a échoué | `patronictl -c /etc/patroni/config.yml reinit odoo-pg <serveur>` |
| Odoo : `no pg_hba.conf entry for host "192.168.33.16x"` | connexion relayée sans certificat client | vérifier `/etc/odoo/pg-ssl/` sur le conteneur Odoo (§ 7, point 4 pour la sauvegarde) |
| Odoo : `server certificate … does not match host name` | serveur encore sur l'ancien certificat à une seule adresse | rejouer le playbook ; vérifier `ssl_cert_file` = `/etc/patroni/ssl/server.crt` |
| HAProxy : les trois serveurs `DOWN` | aucun primaire, ou 8008 injoignable | `patronictl list`, puis `curl -i http://192.168.33.161:8008/primary` |
| `attend un redémarrage` | paramètre changé qui exige un redémarrage | § 6, « Changer un paramètre » |

### Reprise refusée

Le rôle s'arrête **avant toute modification** dans trois situations :

- **`odoodb1` est en réserve** : quelqu'un a promu une autre réserve à la
  main. Identifier le vrai primaire (`SELECT pg_is_in_recovery();` sur
  chaque serveur), puis l'indiquer dans l'inventaire comme membre de
  `db_containers`.
- **Une réserve n'est pas en récupération** alors qu'elle a le même
  identifiant que le primaire : elle a été promue et a **divergé**. Ses
  écritures propres seraient perdues. Les sauvegarder (`pg_dump`) si elles
  comptent, puis la vider pour qu'elle soit recopiée :
  `pg_dropcluster 15 main && pg_createcluster 15 main`.
- **Un serveur porte les bases d'un autre cluster.** Il n'est jamais vidé
  automatiquement. Le faire à la main, après sauvegarde, comme ci-dessus.

Relancer ensuite le playbook.
