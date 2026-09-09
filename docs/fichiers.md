# Guide des fichiers

Rôle de chaque fichier du dépôt, et pourquoi il existe.

```
ProSys/
├── ansible.cfg                       configuration Ansible
├── inventory.yaml                    hôtes et conteneurs
├── requirements.yml                  collections Ansible requises
├── .gitignore                        exclusions Git (dont les secrets)
├── README.md                         vue d'ensemble du projet
├── group_vars/odoo_containers/       variables des conteneurs
├── host_vars/                        variables par hôte
├── common/group_vars/                variables des conteneurs LXC
├── playbooks/                        points d'entrée
├── roles/                            logique de déploiement
└── docs/                             documentation
```

---

## Racine

### `ansible.cfg`
Configuration Ansible du projet. Définit l'inventaire par défaut
(`inventory.yaml`) et le chemin des rôles (`./roles`), ce qui permet de lancer
les playbooks sans passer `-i` ni configurer de variables d'environnement.

### `inventory.yaml`
Déclare deux groupes.

`[gluster_servers]` — les trois hôtes physiques Rocky 8, joignables directement
en SSH sur le LAN.

`[odoo_containers]` — les trois conteneurs LXC. Ils n'ont **pas** d'adresse
routable depuis ton poste : Ansible les atteint en rebondissant sur leur hôte
via `ProxyCommand`. La variable `proxy_host` porte l'IP de l'hôte à traverser,
et `ansible_ssh_common_args` construit le tunnel. C'est pourquoi
l'authentification **par clé** vers les hôtes est obligatoire — un
`ProxyCommand` ne peut pas demander de mot de passe.

### `requirements.yml`
Collections Ansible à installer avant tout déploiement :
`community.general` (module `lxc_container`), `community.postgresql` (gestion
des rôles et bases), `ansible.posix` (`firewalld`, `sysctl`, `authorized_key`).

### `.gitignore`
Exclut `group_vars/odoo_containers/vault.yml` tant qu'il est en clair, ainsi que
`.claude/` (configuration locale de l'éditeur) et les artefacts Ansible.

---

## Variables

### `group_vars/odoo_containers/vars.yml`
Variables communes aux trois conteneurs : version d'Odoo et URL du dépôt
nightly, utilisateurs système et SQL, chemins de configuration, de log et du
filestore, version de PostgreSQL et ses répertoires, nom de la base à créer.
Les mots de passe n'y figurent pas directement — ils sont référencés depuis le
vault.

### `group_vars/odoo_containers/vault.yml` *(non versionné)*
Les secrets réels : mot de passe maître d'Odoo et mot de passe du rôle
PostgreSQL. **À chiffrer** avec `ansible-vault encrypt`. Exclu du dépôt tant
qu'il est en clair.

### `group_vars/odoo_containers/vault.yml.example`
Modèle versionné du précédent, avec des valeurs de remplacement. À copier en
`vault.yml` puis à renseigner.

### `host_vars/192.168.96.139.yml` *(et `.140`, `.141`)*
Ce qui distingue chaque nœud : l'adresse et le sous-réseau de son bridge
`lxcbr0`, la plage DHCP, l'IP de son conteneur et sa passerelle, les routes vers
les sous-réseaux des deux autres nœuds, et `publish_odoo_web` qui commande la
redirection DNAT du port 8069.

C'est ici qu'on change le plan d'adressage, nulle part ailleurs.

### `common/group_vars/local_dev.yml`
Liste des conteneurs LXC à créer (`containers`), utilisée par le rôle `install`.
Séparé du reste car il concerne la création des conteneurs, étape antérieure au
déploiement d'Odoo.

---

## Playbooks

### `playbooks/ansi_odoo.yaml` — le playbook principal
Deux plays : `odoo_net` sur les hôtes, puis `odoo14` dans les conteneurs.
C'est le seul playbook à lancer pour déployer ou mettre à jour Odoo.

### `playbooks/ansi2-snapchot.yaml`
Crée les conteneurs LXC Debian 11 via le rôle `install`. À lancer **avant**
`ansi_odoo.yaml`, une seule fois.

### `playbooks/nettoyage_odoo.yaml`
Remet les conteneurs à plat via le rôle `odoo_cleanup`, sans les détruire.
Par défaut il ne fait que réparer APT ; avec `-e full_reset=true` il purge Odoo,
PostgreSQL et leurs données.

### `playbooks/nettoyage.yaml`
Détruit les conteneurs LXC et désinstalle LXC des hôtes, via le rôle `cleanup`.
C'est le retour à l'état initial des machines.

---

## Rôle `install` — création des conteneurs

### `roles/install/tasks/main.yaml`
Installe les paquets LXC selon la famille de l'OS (Debian ou RedHat), passe
SELinux en permissif sur Rocky, démarre `lxc-net`, puis crée et démarre les
conteneurs Debian 11 listés dans `containers`. En cas d'échec de `lxc-create`,
un bloc `rescue` affiche le log LXC plutôt qu'une erreur opaque.

---

## Rôle `odoo_net` — réseau des hôtes

S'exécute **sur les hôtes**. Prépare le terrain pour que les conteneurs soient
joignables et disposent d'un accès sortant.

### `roles/odoo_net/tasks/main.yaml`
Le cœur du rôle, dans cet ordre précis :

1. **Sous-réseau `lxcbr0`** — écrit `/etc/sysconfig/lxc-net` avec l'adressage du
   nœud, et force l'IP statique du conteneur via `systemd-networkd` dans son
   rootfs (l'image bullseye n'embarque pas `ifupdown`).
2. **Soustraction à NetworkManager** — sans ce fichier, NM s'approprie `lxcbr0`,
   ne trouve aucun profil et le détruit ; `lxc-net` dit « success » mais le
   bridge n'existe pas et `lxc-start` échoue.
3. **Routage inter-nœuds** — `ip_forward`, routes vers les sous-réseaux des
   pairs, et un hook NetworkManager pour les rejouer au redémarrage.
4. **firewalld** — `lxcbr0` en zone `trusted`, règles directes de forwarding,
   **NAT sortant en règle directe permanente** (un `firewall-cmd --reload` purge
   les règles iptables de `lxc-net`, la règle directe est réappliquée
   automatiquement), et DNAT du port 8069.
5. **Bootstrap du conteneur** — installe `openssh-server`, `python3` et
   `python3-apt`, injecte la clé publique du poste de contrôle, génère les clés
   d'hôte SSH. Sans cette étape, Ansible ne peut pas atteindre le conteneur.

Toutes les vérifications faites dans le conteneur reposent sur un **marqueur
imprimé sur stdout** (`NET_OK`, `IP_OK`, `BOOTSTRAP_SSH_OK`), jamais sur le code
retour : `lxc-attach` en LXC 3.0.4 renvoie toujours 0, quoi qu'il arrive.

### `roles/odoo_net/tasks/ensure_lxcbr0.yaml`
Garantit que le bridge existe réellement et porte la bonne adresse. Inclus deux
fois : après la configuration initiale, et après le redémarrage de `lxc-net`
consécutif au reload de firewalld. Si le bridge manque, relance `lxc-net`
directement après avoir purgé `/run/lxc/network_up` (sans quoi `lxc-net` refuse
de démarrer), et échoue avec un message exploitable plutôt que de laisser
`lxc-start` planter plus loin.

### `roles/odoo_net/defaults/main.yml`
Nom du conteneur, nom du bridge, port web, et la clé publique du poste de
contrôle (lue depuis `~/.ssh/id_rsa.pub`, surchargeable par `-e`).

### `roles/odoo_net/handlers/main.yaml`
Vide volontairement : les opérations sensibles sont appliquées en ligne dans
`tasks/main.yaml` pour maîtriser leur ordre, un handler différé arriverait trop
tard.

---

## Rôle `odoo14` — installation d'Odoo

S'exécute **dans les conteneurs**.

### `roles/odoo14/tasks/main.yaml`
Installe les dépendances, **PostgreSQL serveur** (le paquet Debian d'Odoo ne
dépend que de `postgresql-client`), le dépôt nightly et Odoo, dépose la
configuration, puis :

- **promeut** l'instance si elle est restée en mode recovery d'une ancienne
  configuration répliquée, et retire les reliquats (`replication.conf`,
  `primary_conninfo`) ;
- crée le rôle SQL `odoo` avec `CREATEDB` — `role_attr_flags` est obligatoire,
  sans lui le module réinitialise les attributs et Odoo ne peut plus créer de
  base ;
- classe la base en `ABSENTE`, `VIDE` ou `VALIDE`, reconstruit les deux premiers
  cas et **vérifie le résultat** (au moins un module installé). Tester la simple
  existence de la base ne suffit pas : une base créée dont l'initialisation a
  échoué reste présente et vide, et Odoo répond 500 indéfiniment.

### `roles/odoo14/tasks/apt_sources.yaml`
Assainit APT sur une Debian 11 en fin de vie : tolère les fichiers `Release`
expirés, limite les sources à `main` + `updates` (aucun dépôt sécurité n'est plus
exploitable), répare les paquets laissés en état incohérent, réaligne les
versions, puis **simule** l'installation de tout ce que le rôle va demander. Un
blocage se révèle ainsi avant toute modification.

### `roles/odoo14/files/apt-realign`
Script Python qui rétrograde tout paquet dont la version installée dépasse la
plus récente **téléchargeable**, en une seule transaction apt. Deux pièges qu'il
encode : `pkg.candidate` est inexploitable ici (pour un paquet absent de tout
dépôt, python-apt renvoie la version installée, la comparaison montre une égalité
et le paquet est manqué), et les paquets liés par une dépendance stricte comme
`perl`/`perl-base` doivent bouger ensemble.

### `roles/odoo14/templates/odoo.conf.j2`
Configuration d'Odoo. Connexion par socket Unix local, instance mono-base.
`db_name` est indispensable avec `list_db = False` : sans lui Odoo ne peut ni
lister ni déduire la base à servir, et répond 500.

### `roles/odoo14/defaults/main.yml`
Valeurs par défaut du rôle, surchargées par `group_vars`. Contient aussi
`debian_mirror`, qui permet de basculer sur `archive.debian.org`.

### `roles/odoo14/handlers/main.yaml`
Redémarrage d'Odoo et de PostgreSQL après modification de leur configuration.

---

## Rôle `odoo_cleanup` — remise à plat

### `roles/odoo_cleanup/tasks/main.yaml`
Arrête Odoo, libère les verrous `dpkg`/`apt` d'un lancement interrompu, termine
la transaction en cours, répare ou supprime les paquets en état incohérent,
réaligne les versions, vide le cache, et affiche un état de fin.

Avec `-e full_reset=true`, purge en plus Odoo, PostgreSQL, leurs données, le
dépôt nightly et les reliquats de l'ancienne architecture répliquée.
**Destructif** : supprime les bases et le filestore.

---

## Rôle `cleanup` — désinstallation LXC

### `roles/cleanup/tasks/main.yaml`
Détruit les conteneurs, arrête et désactive les services LXC, désinstalle les
paquets, supprime les répertoires créés, et rétablit SELinux en `enforcing`.
Annule ce que le rôle `install` a fait.

---

## Documentation

### `docs/bridge-lxc-recapitulatif.md`
Compte rendu détaillé des essais réseau : pourquoi un bridge L2 sur l'interface
physique a été abandonné (filtrage MAC du vSwitch de l'hyperviseur), comment le
diagnostiquer, et le repli retenu. Utile pour comprendre **pourquoi** le réseau
est construit ainsi.

### `docs/sauvegarde-gluster.md` et `docs/sauvegarde-gluster-notes.md`
Procédure de sauvegarde d'un volume GlusterFS par snapshot. Sans rapport avec
Odoo, conservée car elle documente une autre opération réelle sur ce cluster.

### `docs/fichiers.md`
Ce document.
