# ProSys — Odoo 14 sur cluster LXC

Déploiement Ansible d'**Odoo 14** dans un conteneur LXC sur chacun des trois
nœuds Rocky 8 du cluster. Trois instances **autonomes** : chaque nœud a sa
propre base PostgreSQL locale et son propre filestore.

```
                        LAN 192.168.96.0/24
   ┌──────────────┐      ┌──────────────┐      ┌──────────────┐
   │ Node1  .139  │      │ Node2  .140  │      │ Node3  .141  │
   │   lxcbr0     │      │   lxcbr0     │      │   lxcbr0     │
   │  10.0.1.1/24 │      │  10.0.2.1/24 │      │  10.0.3.1/24 │
   │  ┌────────┐  │      │  ┌────────┐  │      │  ┌────────┐  │
   │  │ odoo1  │  │      │  │ odoo2  │  │      │  │ odoo3  │  │
   │  │10.0.1.10  │      │  │10.0.2.10  │      │  │10.0.3.10 │
   │  │Odoo + PG│ │      │  │Odoo + PG│ │      │  │Odoo + PG│ │
   │  └────────┘  │      │  └────────┘  │      │  └────────┘  │
   └──────┬───────┘      └──────┬───────┘      └──────┬───────┘
     DNAT │ 8069           DNAT │ 8069           DNAT │ 8069
   .139:8069              .140:8069              .141:8069
```

> **Aucune donnée n'est partagée entre les nœuds.** Chaque instance est
> indépendante : un contact créé sur `odoo1` n'existe pas sur `odoo2`. La haute
> disponibilité reste à construire — voir [Vers la haute disponibilité](#vers-la-haute-disponibilité).

## Réseau

Chaque nœud garde son bridge interne `lxcbr0` sur un sous-réseau distinct, et
les hôtes routent entre eux via le LAN. Les paquets quittent chaque machine avec
l'adresse MAC de l'hôte, ce que l'hyperviseur accepte sans configuration
particulière — contrairement à un bridge L2 sur l'interface physique, bloqué par
le filtrage MAC du vSwitch (voir [docs/bridge-lxc-recapitulatif.md](docs/bridge-lxc-recapitulatif.md)).

| Nœud | IP hôte | `lxcbr0` | Conteneur | Accès web |
|---|---|---|---|---|
| Node1 | 192.168.96.139 | 10.0.1.1/24 | 10.0.1.10 | http://192.168.96.139:8069 |
| Node2 | 192.168.96.140 | 10.0.2.1/24 | 10.0.2.10 | http://192.168.96.140:8069 |
| Node3 | 192.168.96.141 | 10.0.3.1/24 | 10.0.3.10 | http://192.168.96.141:8069 |

Le routage inter-nœuds n'est pas indispensable aux instances autonomes ; il est
conservé car toute évolution vers la HA en aura besoin.

## Structure

```
playbooks/
  ansi_odoo.yaml         Déploiement complet (2 plays)
  nettoyage_odoo.yaml    Remise à plat des conteneurs
  ansi2-snapchot.yaml    Création des conteneurs LXC
  nettoyage.yaml         Destruction des conteneurs LXC
roles/
  install/               Paquets LXC + création des conteneurs Debian 11
  odoo_net/              Hôtes : sous-réseaux, routage, firewalld, bootstrap SSH
  odoo14/                Conteneurs : PostgreSQL + Odoo 14 + base locale
  odoo_cleanup/          Conteneurs : réparation APT, reset optionnel
  cleanup/               Hôtes : désinstallation LXC
group_vars/odoo_containers/   Versions, chemins, secrets
host_vars/192.168.96.*.yml    Sous-réseau et IP conteneur par nœud
```

## Prérequis

```bash
ssh-keygen                                                    # si pas déjà de clé
for h in 139 140 141; do ssh-copy-id root@192.168.96.$h; done # obligatoire (play 2)
ansible-galaxy collection install -r requirements.yml
cp group_vars/odoo_containers/vault.yml.example group_vars/odoo_containers/vault.yml
$EDITOR group_vars/odoo_containers/vault.yml                  # vrais mots de passe
ansible-vault encrypt group_vars/odoo_containers/vault.yml
```

L'authentification **par clé** vers les trois hôtes n'est pas optionnelle : la
play 2 atteint les conteneurs par `ProxyCommand`, qui ne peut pas demander de
mot de passe.

## Déploiement

```bash
ansible-playbook playbooks/ansi_odoo.yaml --ask-vault-pass
```

| Play | Cible | Effet |
|---|---|---|
| 1 | `gluster_servers` | Sous-réseaux `lxcbr0`, routage inter-nœuds, firewalld, DNAT 8069, bootstrap SSH + Python dans les conteneurs |
| 2 | `odoo_containers` | Sources APT assainies, PostgreSQL, Odoo 14 (dépôt nightly), `odoo.conf`, base `prod` locale |

Le rôle `odoo14` détecte un nœud resté en mode standby d'une ancienne
configuration répliquée et le **promeut** automatiquement en instance autonome
en lecture/écriture.

Comme `list_db = false` désactive le gestionnaire de bases web — bon réglage, il
évite de l'exposer sur le réseau — la base est créée en ligne de commande par le
playbook.

## Vérification

```bash
# chaque nœud doit répondre, en lecture/écriture
ansible odoo_containers -m shell -a "cd /tmp && sudo -u postgres psql -tAc \
  \"select case when pg_is_in_recovery() then 'LECTURE SEULE (anormal)' \
    else 'lecture/ecriture' end\""

# services actifs sur les trois
ansible odoo_containers -m shell -a "systemctl is-active postgresql odoo"

# interface web de chaque nœud
for h in 139 140 141; do curl -sI -o /dev/null -w "$h -> %{http_code}\n" \
  http://192.168.96.$h:8069/web/login; done
```

Connexion : `admin` / valeur de `vault_odoo_admin_password`.

## Nettoyage

```bash
# réparation APT, non destructif
ansible-playbook playbooks/nettoyage_odoo.yaml --ask-vault-pass

# DESTRUCTIF : supprime bases PostgreSQL et filestore
ansible-playbook playbooks/nettoyage_odoo.yaml --ask-vault-pass -e full_reset=true
```

## Vers la haute disponibilité

Trois instances autonomes ne constituent pas de la HA : perdre un nœud perd ses
données. Trois chemins possibles, par ordre de coût croissant :

| Approche | Principe | Bascule |
|---|---|---|
| **Streaming PostgreSQL** | 1 primaire en écriture, 2 standbys hot ; le filestore se synchronise par rsync | Manuelle (`pg_ctlcluster promote`) |
| **Streaming + Patroni/repmgr** | Idem, plus un quorum, une IP virtuelle `keepalived` et un HAProxy | Automatique |
| **Actif/passif sur GlusterFS** | Datadir PostgreSQL et filestore sur un volume Gluster répliqué ; un seul Odoo actif | Automatique via `keepalived` |

Dans tous les cas, **un seul Odoo peut écrire à la fois** : Odoo ne fonctionne
pas sur une base en lecture seule, il y écrit sessions, séquences et crons à
chaque requête. La HA possible ici est de type actif/passif, pas de la
répartition d'écriture.

Une implémentation complète du streaming PostgreSQL (rôle `odoo_replication`,
`pg_basebackup` automatisé, synchro du filestore par timer systemd) a existé
dans ce dépôt et reste récupérable :

```bash
git show 3873a30 --stat            # voir ce que contenait le rôle
git checkout 3873a30 -- roles/odoo_replication
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
| **`postgresql_user` sans `role_attr_flags` réinitialise les attributs** | Le rôle `odoo` perd `CREATEDB` : `permission denied to create database` | `role_attr_flags: "LOGIN,CREATEDB"` déclaré explicitement |

## Limites connues

- **Debian 11 et Odoo 14 sont tous deux en fin de vie.** Les conteneurs ne
  reçoivent plus de correctifs de sécurité. Acceptable pour de la formation ou
  une reprise d'existant, pas pour de la production exposée. Le passage à Debian
  12 ne demande qu'un `-r bookworm` dans le rôle `install` et rendrait caduc tout
  le contournement APT.
- La clé injectée dans les conteneurs est **RSA**. OpenSSH ≥ 8.8 refuse les
  signatures `ssh-rsa` par défaut ; Debian 11 embarque 8.4, donc cela passe. Une
  bascule vers Debian 12 imposerait une clé Ed25519.
- Aucune sauvegarde n'est configurée. Chaque base ne vit que sur son nœud.
