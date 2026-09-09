# ProSys — Odoo 14 répliqué sur un cluster LXC

Déploiement Ansible d'**Odoo 14** dans un conteneur LXC sur chacun des trois
nœuds Rocky 8 du cluster, avec **réplication PostgreSQL en streaming** entre les
trois instances.

```
                        LAN 192.168.96.0/24
   ┌──────────────┐      ┌──────────────┐      ┌──────────────┐
   │ Node1  .139  │      │ Node2  .140  │      │ Node3  .141  │
   │   lxcbr0     │      │   lxcbr0     │      │   lxcbr0     │
   │  10.0.1.1/24 │      │  10.0.2.1/24 │      │  10.0.3.1/24 │
   │      │       │      │      │       │      │      │       │
   │  ┌───┴────┐  │      │  ┌───┴────┐  │      │  ┌───┴────┐  │
   │  │odoo1   │  │◄─────┼──│odoo2   │  │      │  │odoo3   │  │
   │  │10.0.1.10  │      │  │10.0.2.10  │      │  │10.0.3.10 │
   │  │PRIMAIRE│  │◄─────┼──┼────────┼──┼──────┼──│STANDBY │  │
   │  └────────┘  │      │  │STANDBY │  │      │  └────────┘  │
   └──────────────┘      │  └────────┘  │      └──────────────┘
          ▲              └──────────────┘
          │  DNAT 8069
     http://192.168.96.139:8069
```

## Modèle de réplication

**PostgreSQL streaming, un primaire et deux standbys hot.** Les trois bases
portent les mêmes données ; `odoo1` est seul en écriture.

Odoo ne fonctionne pas sur une base en lecture seule — il écrit sessions,
séquences et crons à chaque requête. Sur les standbys, PostgreSQL réplique donc
en continu mais le service `odoo` reste **arrêté et désactivé**, prêt à démarrer
après promotion. C'est de la haute disponibilité actif/passif avec données
répliquées, pas de la répartition d'écriture. Un multi-maître réel demanderait
Bucardo ou BDR, non supportés par Odoo.

Le streaming ne réplique que la base. Le **filestore** (pièces jointes) est
synchronisé séparément par un timer systemd sur le primaire, toutes les 2 min.

## Réseau

Chaque nœud garde son bridge interne `lxcbr0` sur un sous-réseau distinct, et
les hôtes routent entre eux via le LAN. Les paquets quittent chaque machine avec
l'adresse MAC de l'hôte, ce que l'hyperviseur accepte sans configuration
particulière — contrairement à un bridge L2 sur l'interface physique, bloqué par
le filtrage MAC du vSwitch (voir [docs/bridge-lxc-recapitulatif.md](docs/bridge-lxc-recapitulatif.md)).

| Nœud | IP hôte | `lxcbr0` | Conteneur | Rôle |
|---|---|---|---|---|
| Node1 | 192.168.96.139 | 10.0.1.1/24 | 10.0.1.10 | primary |
| Node2 | 192.168.96.140 | 10.0.2.1/24 | 10.0.2.10 | standby |
| Node3 | 192.168.96.141 | 10.0.3.1/24 | 10.0.3.10 | standby |

Le trafic inter-conteneurs est masqueradé : un standby se présente au primaire
avec l'**IP LAN de son hôte**, pas son IP conteneur. C'est pourquoi
`pg_allowed_cidrs` liste aussi les `/32` des hôtes.

## Structure

```
playbooks/
  ansi_odoo.yaml         Déploiement complet (3 plays)
  nettoyage_odoo.yaml    Remise à plat des conteneurs
  ansi2-snapchot.yaml    Création des conteneurs LXC
  nettoyage.yaml         Destruction des conteneurs LXC
roles/
  install/               Paquets LXC + création des conteneurs Debian 11
  odoo_net/              Hôtes : sous-réseaux, routage, firewalld, bootstrap SSH
  odoo14/                Conteneurs : Odoo 14 + PostgreSQL + base initiale
  odoo_replication/      Conteneurs : streaming PG + synchro filestore
  odoo_cleanup/          Conteneurs : réparation APT, reset optionnel
  cleanup/               Hôtes : désinstallation LXC
group_vars/odoo_containers/   Versions, chemins, CIDR autorisés, secrets
host_vars/192.168.96.*.yml    Sous-réseau et IP conteneur par nœud
```

## Prérequis

```bash
ssh-keygen                                                    # si pas déjà de clé
for h in 139 140 141; do ssh-copy-id root@192.168.96.$h; done # obligatoire (plays 2-3)
ansible-galaxy collection install -r requirements.yml
cp group_vars/odoo_containers/vault.yml.example group_vars/odoo_containers/vault.yml
$EDITOR group_vars/odoo_containers/vault.yml                  # vrais mots de passe
ansible-vault encrypt group_vars/odoo_containers/vault.yml
```

L'authentification **par clé** vers les trois hôtes n'est pas optionnelle : les
plays 2 et 3 atteignent les conteneurs par `ProxyCommand`, qui ne peut pas
demander de mot de passe.

## Déploiement

```bash
ansible-playbook playbooks/ansi_odoo.yaml --ask-vault-pass
```

| Play | Cible | Effet |
|---|---|---|
| 1 | `gluster_servers` | Sous-réseaux `lxcbr0`, routage inter-nœuds, firewalld, DNAT 8069, bootstrap SSH + Python dans les conteneurs |
| 2 | `odoo_containers` | Sources APT assainies, PostgreSQL, Odoo 14 (dépôt nightly), `odoo.conf`, base `prod` |
| 3 | `odoo_containers` | `pg_basebackup` des standbys depuis le primaire, `pg_hba`, timer de synchro filestore |

La play 3 tourne en `serial: 1` avec `order: sorted` : le primaire est configuré
avant que les standbys ne se raccordent.

## Vérification

```bash
# 2 lignes "streaming" attendues
ansible odoo1 -m shell -a "cd /tmp && sudo -u postgres psql -xc \
  'select client_addr, state, sync_state from pg_stat_replication'"

# doit répondre "t"
ansible standby -m shell -a "cd /tmp && sudo -u postgres psql -tAc 'select pg_is_in_recovery()'"

# interface web du primaire
curl -sI http://192.168.96.139:8069/web/login
```

Test de bout en bout : créer un contact dans l'interface, puis vérifier qu'il a
traversé vers les standbys.

```bash
ansible standby -m shell -a "cd /tmp && sudo -u postgres psql -d prod -tAc \
  \"select id||' '||name from res_partner order by id desc limit 3\""
```

## Bascule après panne du primaire

Manuelle et assumée — l'automatiser demanderait Patroni ou repmgr avec quorum.

```bash
# 1. promouvoir un standby
ansible odoo2 -m shell -a "sudo -u postgres pg_ctlcluster 13 main promote"

# 2. publier son interface web (publish_odoo_web: true dans son host_vars)
ansible-playbook playbooks/ansi_odoo.yaml --tags odoo_net --ask-vault-pass

# 3. démarrer Odoo dessus
ansible odoo2 -m shell -a "systemctl enable --now odoo"
```

## Nettoyage

```bash
# réparation APT, non destructif
ansible-playbook playbooks/nettoyage_odoo.yaml --ask-vault-pass

# DESTRUCTIF : supprime bases PostgreSQL et filestore
ansible-playbook playbooks/nettoyage_odoo.yaml --ask-vault-pass -e full_reset=true
```

## Pièges rencontrés

Ces contraintes sont encodées dans les rôles. Les « simplifier » casse le
déploiement.

| Piège | Conséquence | Traitement |
|---|---|---|
| **`lxc-attach` (LXC 3.0.4) ne propage pas le code retour** — il renvoie toujours 0 | Toute vérification dans le conteneur réussit à tort ; un `apt` en échec passe inaperçu | Validation par **marqueur dans stdout** (`NET_OK`, `IP_OK`, `BOOTSTRAP_SSH_OK`), jamais par `.rc` |
| **NetworkManager s'approprie `lxcbr0`** et le détruit faute de profil | `lxc-net` dit « success », le bridge n'existe pas, `lxc-start` échoue sur `Failed to attach veth` | `/etc/NetworkManager/conf.d/99-lxc-unmanaged.conf` + vérification explicite du bridge |
| **`firewall-cmd --reload` purge les règles iptables de `lxc-net`** | Le conteneur perd son accès sortant, `apt` échoue | NAT redéclaré en règle **directe permanente** firewalld, réappliquée à chaque reload |
| **Debian 11 est en fin de vie** (août 2026) | `Release` expiré, pool `bullseye-security` purgé, aucune archive sécurité | `Acquire::Check-Valid-Until "false"` + sources limitées à `main` + `updates` |
| **Paquets résiduels en versions « security »** | `held broken packages` sur `perl`/`perl-base`, `gnupg`/`gpgv` | `roles/odoo14/files/apt-realign` rétrograde tout paquet dépassant la version téléchargeable, **en une seule transaction** |
| **`pkg.candidate` est trompeur** pour un paquet absent de tout dépôt | python-apt renvoie la version installée : la comparaison montre une égalité et le paquet est manqué | Comparaison sur `v.downloadable` |
| **Le `.deb` Odoo ne dépend que de `postgresql-client`** | `service postgresql` n'existe pas | Serveur installé explicitement, **avant** Odoo |
| **`postgresql_user` sans `role_attr_flags` réinitialise les attributs** | Le rôle `odoo` perd `CREATEDB` : `permission denied to create database` | `role_attr_flags: "LOGIN,CREATEDB"` déclaré partout |

## Limites connues

- **Debian 11 et Odoo 14 sont tous deux en fin de vie.** Les conteneurs ne
  reçoivent plus de correctifs de sécurité. Acceptable pour de la formation ou
  une reprise d'existant, pas pour de la production exposée. Le passage à Debian
  12 ne demande qu'un `-r bookworm` dans le rôle `install` et rendrait caduc tout
  le contournement APT.
- La clé injectée dans les conteneurs est **RSA**. OpenSSH ≥ 8.8 refuse les
  signatures `ssh-rsa` par défaut ; Debian 11 embarque 8.4, donc cela passe. Une
  bascule vers Debian 12 imposerait une clé Ed25519.
- La bascule après panne est manuelle.
