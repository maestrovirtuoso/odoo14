# Sortir etcd des conteneurs PostgreSQL

Ce document décrit comment déplacer etcd, le registre de Patroni, des
**conteneurs** PostgreSQL vers les **hôtes** qui les portent. Une fois ce
changement fait, si deux conteneurs PostgreSQL tombent, **le troisième reste
primaire** et Odoo continue de fonctionner.

> **État au 26/10/2026 : automatisé par `ansi_postgresql_ha.yaml`, non testé.**
> Il suffit du groupe `etcd_cluster` dans [inventory.yaml](../inventory.yaml),
> déjà présent, puis de relancer le playbook (§ 6). Les étapes manuelles des
> § 4 et 5 décrivent ce que fait le playbook : elles servent à comprendre ou à
> dépanner. Ce document complète [POSTGRESQL-PATRONI.md](POSTGRESQL-PATRONI.md).

---

## 1. Pourquoi

Patroni ne peut désigner un primaire que si **etcd a son quorum** : au moins
2 membres sur 3 qui se voient. Aujourd'hui, chaque membre etcd tourne dans un
conteneur PostgreSQL :

| Conteneurs PostgreSQL arrêtés | Membres etcd restants | Quorum | Résultat |
|---|---|---|---|
| 1 | 2 sur 3 | oui | un autre devient primaire |
| 2 | **1 sur 3** | **non** | le dernier passe en lecture seule, Odoo s'arrête |

Arrêter deux conteneurs PostgreSQL, c'est aussi arrêter deux etcd. Le dernier
serveur ne peut pas savoir si les autres sont morts ou s'il est seulement
isolé du réseau. Il refuse donc d'être primaire, pour ne jamais risquer deux
primaires.

**La solution est de séparer les deux.** etcd tourne sur les trois hôtes LXC
(`192.168.33.21`, `.22`, `.23`). Arrêter des conteneurs ne touche plus au
quorum.

---

## 2. L'architecture visée

```
   hôte 192.168.33.21        hôte 192.168.33.22        hôte 192.168.33.23
   ┌──────────────────┐      ┌──────────────────┐      ┌──────────────────┐
   │ etcd  :2379/2380 │──────│ etcd  :2379/2380 │──────│ etcd  :2379/2380 │
   │                  │      │                  │      │                  │
   │ ┌──────────────┐ │      │ ┌──────────────┐ │      │ ┌──────────────┐ │
   │ │ odoodb1 .161 │ │      │ │ odoodb2 .162 │ │      │ │ odoodb3 .163 │ │
   │ │ PostgreSQL   │ │      │ │ PostgreSQL   │ │      │ │ PostgreSQL   │ │
   │ │ Patroni      │ │      │ │ Patroni      │ │      │ │ Patroni      │ │
   │ │ HAProxy      │ │      │ │ HAProxy      │ │      │ │ HAProxy      │ │
   │ └──────────────┘ │      │ └──────────────┘ │      │ └──────────────┘ │
   └──────────────────┘      └──────────────────┘      └──────────────────┘
```

| Panne | etcd | Résultat |
|---|---|---|
| 1 conteneur PostgreSQL | 3 sur 3 | un autre devient primaire |
| **2 conteneurs PostgreSQL** | **3 sur 3** | **le dernier devient ou reste primaire** |
| 1 hôte (son conteneur tombe avec lui) | 2 sur 3 | un autre devient primaire |
| 2 hôtes | 1 sur 3 | lecture seule (inévitable avec 3 membres) |

**Particularité du réseau ipvlan :** un conteneur ne peut pas joindre son
propre hôte. `odoodb1` n'atteint donc pas l'etcd de `192.168.33.21`, mais il
atteint ceux de `.22` et `.23`. Cela suffit : Patroni reçoit les trois
adresses et utilise celles qui répondent. Les messages « No route to host »
vers l'etcd de son propre hôte sont donc normaux.

---

## 3. Avant de commencer

- **Remettre les trois conteneurs PostgreSQL en route.** `patronictl list`
  doit montrer un `Leader` et deux réserves, avec une timeline (`TL`)
  renseignée.
- **Ouvrir les ports.** Les hôtes `.21`, `.22` et `.23` doivent accepter 2379
  et 2380 entre eux, et 2379 depuis les conteneurs PostgreSQL.
- **Travailler depuis le poste de contrôle** qui détient `pki/etcd/`. C'est
  l'autorité qui a signé les certificats clients de Patroni. Une autre
  autorité serait refusée.
- **Prévoir une coupure d'environ une minute** à l'étape 5 : PostgreSQL est
  arrêté puis redémarré sur les trois serveurs.

---

## 4. Installer etcd sur les trois hôtes

### 4.1 Certificats, sur le poste de contrôle

Un certificat par hôte, signé par l'autorité d'etcd, valable pour son IP et
pour la boucle locale :

```bash
cd pki/etcd
for ip in 192.168.33.21 192.168.33.22 192.168.33.23; do
  n=etcd-hote-$ip
  openssl req -new -nodes -newkey rsa:2048 -sha256 -subj "/CN=$n" \
    -keyout $n.key -out $n.csr
  openssl x509 -req -sha256 -days 3650 -in $n.csr -CA ca.crt -CAkey ca.key \
    -set_serial "0x$(openssl rand -hex 16)" \
    -extfile <(printf 'subjectAltName=IP:%s,IP:127.0.0.1\nextendedKeyUsage=serverAuth,clientAuth\n' $ip) \
    -out $n.crt
  rm $n.csr
done
```

Puis copier chaque certificat sur son hôte :

```bash
for ip in 192.168.33.21 192.168.33.22 192.168.33.23; do
  ssh root@$ip mkdir -p /etc/etcd/ssl
  scp ca.crt root@$ip:/etc/etcd/ssl/ca.crt
  scp etcd-hote-$ip.crt root@$ip:/etc/etcd/ssl/server.crt
  scp etcd-hote-$ip.key root@$ip:/etc/etcd/ssl/server.key
done
```

### 4.2 Paquets et configuration, sur chaque hôte

À faire sur `.21`, `.22` et `.23`, en adaptant `IP` à chaque fois :

```bash
IP=192.168.33.21          # .22 puis .23 sur les autres hôtes

apt-get update
apt-get install -y etcd-server etcd-client
# Le paquet démarre un etcd à un membre : on l'arrête avant de le configurer.
systemctl stop etcd

chown -R etcd:etcd /etc/etcd/ssl
chmod 600 /etc/etcd/ssl/server.key

cat > /etc/default/etcd <<EOF
ETCD_NAME="etcd-${IP//./-}"
ETCD_DATA_DIR="/var/lib/etcd/odoo-pg"
ETCD_LISTEN_PEER_URLS="https://$IP:2380"
ETCD_INITIAL_ADVERTISE_PEER_URLS="https://$IP:2380"
ETCD_LISTEN_CLIENT_URLS="https://$IP:2379,https://127.0.0.1:2379"
ETCD_ADVERTISE_CLIENT_URLS="https://$IP:2379"
ETCD_INITIAL_CLUSTER="etcd-192-168-33-21=https://192.168.33.21:2380,etcd-192-168-33-22=https://192.168.33.22:2380,etcd-192-168-33-23=https://192.168.33.23:2380"
ETCD_INITIAL_CLUSTER_STATE="new"
ETCD_INITIAL_CLUSTER_TOKEN="odoo-pg-hotes"
ETCD_CERT_FILE="/etc/etcd/ssl/server.crt"
ETCD_KEY_FILE="/etc/etcd/ssl/server.key"
ETCD_TRUSTED_CA_FILE="/etc/etcd/ssl/ca.crt"
ETCD_CLIENT_CERT_AUTH="true"
ETCD_PEER_CERT_FILE="/etc/etcd/ssl/server.crt"
ETCD_PEER_KEY_FILE="/etc/etcd/ssl/server.key"
ETCD_PEER_TRUSTED_CA_FILE="/etc/etcd/ssl/ca.crt"
ETCD_PEER_CLIENT_CERT_AUTH="true"
EOF
```

Le jeton `odoo-pg-hotes` est différent de celui des etcd des conteneurs
(`odoo-pg`). Les deux clusters ne peuvent donc pas se mélanger pendant la
migration.

### 4.3 Démarrer les trois en même temps

Un membre neuf attend les deux autres pour former le cluster. Lancer la
commande sur les trois hôtes à quelques secondes d'intervalle, ou d'un coup
depuis le poste de contrôle :

```bash
for ip in 192.168.33.21 192.168.33.22 192.168.33.23; do
  ssh root@$ip 'systemctl enable etcd && systemctl start etcd' &
done; wait
```

Vérifier, sur un hôte :

```bash
export ETCDCTL_API=3 ETCDCTL_ENDPOINTS=https://127.0.0.1:2379 \
  ETCDCTL_CACERT=/etc/etcd/ssl/ca.crt ETCDCTL_CERT=/etc/etcd/ssl/server.crt \
  ETCDCTL_KEY=/etc/etcd/ssl/server.key
etcdctl member list              # trois membres etcd-192-168-33-2x
etcdctl endpoint health --cluster   # trois lignes "is healthy"
```

---

## 5. Brancher Patroni sur les nouveaux etcd

Le nouvel etcd est **vide** : il ne sait pas encore qui est primaire. Le
**premier** Patroni qui démarre crée le cluster et devient primaire. Il faut
donc que ce soit le vrai primaire, sinon une réserve en retard prendrait la
place et des écritures seraient perdues. D'où l'ordre strict ci-dessous.

### 5.1 Repérer le primaire

Sur n'importe quel conteneur PostgreSQL :

```bash
patronictl -c /etc/patroni/config.yml list
```

Noter le `Leader`. Dans la suite, ce sera `odoodb2` en exemple.

### 5.2 Arrêter Patroni : les réserves d'abord, le primaire en dernier

Arrêter Patroni arrête aussi PostgreSQL proprement. **La coupure commence
ici.**

```bash
# dans odoodb1 puis odoodb3 (les réserves)
systemctl stop patroni
# puis dans odoodb2 (le primaire)
systemctl stop patroni
```

Confirmer sur le primaire qu'il s'est bien arrêté en primaire :

```bash
sudo -u postgres /usr/lib/postgresql/15/bin/pg_controldata /var/lib/postgresql/15/main \
  | grep 'cluster state'
# primaire : "shut down"        réserves : "shut down in recovery"
```

### 5.3 Changer l'adresse d'etcd dans les trois conteneurs

Dans `/etc/patroni/config.yml`, remplacer le bloc `hosts` de `etcd3` par les
trois hôtes. Le reste du bloc ne change pas, car les certificats de Patroni
sont signés par la même autorité.

```yaml
etcd3:
  hosts:
    - "192.168.33.21:2379"
    - "192.168.33.22:2379"
    - "192.168.33.23:2379"
```

```bash
nano /etc/patroni/config.yml
```

### 5.4 Redémarrer : le primaire d'abord

```bash
# dans odoodb2 (le primaire)
systemctl start patroni
patronictl -c /etc/patroni/config.yml list    # attendre : odoodb2 Leader, running
```

Puis seulement les réserves :

```bash
# dans odoodb1 et odoodb3
systemctl start patroni
patronictl -c /etc/patroni/config.yml list    # trois membres, deux en streaming
```

**La coupure s'arrête** dès que le primaire est `Leader`.

### 5.5 Arrêter l'ancien etcd des conteneurs

Il ne sert plus. Dans chaque conteneur PostgreSQL :

```bash
systemctl disable --now etcd
```

---

## 6. Avec le playbook

```bash
ansible-playbook playbooks/ansi_postgresql_ha.yaml --ask-vault-pass
```

Le playbook enchaîne deux plays :

1. **`etcd_hotes`, sur les hôtes du groupe `etcd_cluster`** : certificats,
   paquets, configuration, puis démarrage des trois etcd ensemble (§ 4).
2. **`pg_ha`, sur les trois conteneurs.** Patroni vise désormais les etcd des
   hôtes, et aucun etcd n'est plus installé dans les conteneurs. Si Patroni
   utilisait encore les etcd des conteneurs, le playbook fait la bascule du
   § 5 tout seul :
   - il désigne le primaire **avant** tout arrêt, en interrogeant Patroni ;
   - il arrête les réserves, puis le primaire ;
   - il écrit la nouvelle configuration ;
   - il redémarre le primaire d'abord, puis les réserves ;
   - il désactive l'ancien etcd des conteneurs.

   **Coupure pour Odoo : environ une minute.**

**Si aucun primaire n'est en service**, par exemple après une perte de
quorum, le playbook s'arrête **avant de rien arrêter** et demande lequel
redémarrer en premier. Il faut choisir celui qui a les données les plus
récentes, c'est-à-dire la plus grande « Latest checkpoint location ». Sur
chaque conteneur :

```bash
sudo -u postgres /usr/lib/postgresql/15/bin/pg_controldata /var/lib/postgresql/15/main \
  | grep -E 'state|TimeLineID|checkpoint location'
```

Puis relancer en le désignant :

```bash
ansible-playbook playbooks/ansi_postgresql_ha.yaml --ask-vault-pass \
  -e pg_ha_primaire_migration=odoodb2
```

Pour revenir à etcd dans les conteneurs, retirer le groupe `etcd_cluster` de
l'inventaire et relancer le playbook : la même bascule se fait dans l'autre
sens.

---

## 7. Tester

Faire **un arrêt à la fois**, en vérifiant `patronictl list` entre chaque :

1. Arrêter le conteneur du primaire : une réserve devient `Leader`.
2. Sans redémarrer le premier, arrêter le conteneur du nouveau primaire :
   **le dernier conteneur devient `Leader`**. C'est ce qui était impossible
   avant ce changement.
3. Redémarrer les deux conteneurs (`lxc-start -n devpg15` sur leur hôte).
   Patroni les remet en réserve.

Pendant ce test, Odoo ne suit le primaire tout seul que s'il passe par
HAProxy (`pg_ha_enabled: true`, § 5.5 de
[POSTGRESQL-PATRONI.md](POSTGRESQL-PATRONI.md)).

---

## 8. Limites

- **Deux hôtes perdus** : plus que 1 etcd sur 3, le cluster se fige en
  lecture seule. Pour tolérer cela aussi, il faudrait 5 membres etcd, avec un
  quorum de 3.
- **Promotion du dernier serveur** : il n'est promu que si son retard est
  inférieur à 1 Mo (`maximum_lag_on_failover`). Une réserve très en retard
  reste en lecture seule plutôt que de perdre des écritures.
- **Retour arrière** : remettre les adresses des conteneurs (`.161`, `.162`,
  `.163`) dans `config.yml`, puis `systemctl enable --now etcd` dans les
  conteneurs. Reprendre ensuite l'ordre du § 5 : arrêts réserves d'abord,
  démarrage primaire d'abord.
