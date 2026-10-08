# Guide des fichiers

Rôle de chaque fichier du dépôt, et pourquoi il existe.

```
ProSys/
├── ansible.cfg                       configuration Ansible
├── inventory.yaml                    hôtes et conteneurs
├── requirements.yml                  collections Ansible requises
├── .env.example                      modèle des variables d'environnement
├── .env                              copie locale (non versionnée)
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

### `.env.example` et `.env`
`.env.example` est le **modèle versionné**, sans aucun secret ; `.env` en est la
copie locale, ignorée par git. Deux familles de variables y cohabitent.

Les `ANSIBLE_*` sont lues nativement par Ansible et priment sur `ansible.cfg` :
config et inventaire, `ANSIBLE_HOST_KEY_CHECKING=False` (les conteneurs sont
recréés et changent de clé d'hôte), `ANSIBLE_PIPELINING` et `ANSIBLE_FORKS` pour
la vitesse, et `ANSIBLE_VAULT_PASSWORD_FILE` qui évite de retaper le mot de
passe du vault à chaque lancement.

Les `PROSYS_*` sont propres au projet et relues côté playbooks avec
`lookup('env', ...)` : `PROSYS_ODOO_VERSION` et `PROSYS_ODOO_INITIAL_DB` dans
`group_vars/odoo_containers/vars.yml`, `PROSYS_ODOO_WEB_PORT` et
`PROSYS_CONTROLLER_SSH_PUBKEY` dans `roles/lxc/lxc_lan/defaults/main.yml`. Chacune
est filtrée par `| default(<valeur>, true)` : vide ou absente, c'est la valeur
du fichier de variables qui s'applique — le `.env` ne peut donc rien casser s'il
est incomplet.

Ansible ne lit pas `.env` tout seul : il faut l'exporter avant de lancer un
playbook, avec `set -a && source .env && set +a`.

Les mots de passe restent dans `vault.yml`, chiffré : le `.env` ne contient
qu'un *chemin* vers le mot de passe du vault, jamais le mot de passe lui-même.

### `.gitignore`
Exclut `group_vars/odoo_containers/vault.yml` tant qu'il est en clair et `.env`
(réglages propres au poste), ainsi que `.claude/` (configuration locale de
l'éditeur) et les artefacts Ansible.

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
Cinq plays enchaînés : horloge et réseau sur les hôtes (`chrony`, `lxc_lan`),
la base (`pg_server`), Odoo installé mais laissé arrêté (`odoo14`),
l'initialisation du registre par le seul nœud primaire (`odoo_dbinit`), puis le
démarrage des instances.
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

### `roles/lxc/install/tasks/main.yaml`
Installe les paquets LXC selon la famille de l'OS (Debian ou RedHat), passe
SELinux en permissif sur Rocky, démarre `lxc-net`, puis crée et démarre les
conteneurs Debian 11 listés dans `containers`. En cas d'échec de `lxc-create`,
un bloc `rescue` affiche le log LXC plutôt qu'une erreur opaque.

---

## Rôle `odoo14` — installation d'Odoo

S'exécute **dans les conteneurs**.

### `roles/odoo/odoo14/tasks/main.yaml`
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

### `roles/odoo/odoo14/tasks/purge_replication.yaml`
Démantèle l'ancienne architecture répliquée. Le projet a d'abord déployé une
réplication PostgreSQL streaming ; ce fichier efface tout ce qu'elle avait laissé
sur les conteneurs :

- **promeut** une instance restée en mode recovery — sa base serait en lecture
  seule et Odoo ne pourrait pas y écrire ;
- supprime le timer, le service et le script de synchronisation du filestore ;
- supprime `replication.conf`, `standby.signal`, `primary_conninfo` et surtout
  **`/var/lib/postgresql/.pgpass`**, qui contenait le mot de passe de réplication
  en clair alors que plus rien ne l'utilisait ;
- retire les lignes `host replication` de `pg_hba.conf` et supprime le rôle SQL
  `replicator` ;
- supprime la paire de clés SSH que le primaire générait pour pousser le
  filestore, et la révoque des `authorized_keys` des autres nœuds — son
  commentaire `root@devodoo14` la distingue de celle du poste de contrôle, qui
  doit être conservée.

Idempotent : une fois le parc propre il ne signale plus aucun changement, et il
rattrape un conteneur restauré depuis une sauvegarde antérieure.

### `roles/socle/base_debian/tasks/main.yaml`
Assainit APT sur une Debian 11 en fin de vie : tolère les fichiers `Release`
expirés, limite les sources à `main` + `updates` (aucun dépôt sécurité n'est plus
exploitable), répare les paquets laissés en état incohérent, réaligne les
versions, puis **simule** l'installation de tout ce que le rôle va demander. Un
blocage se révèle ainsi avant toute modification.

### `roles/socle/base_debian/files/apt-realign`
Script Python qui rétrograde tout paquet dont la version installée dépasse la
plus récente **téléchargeable**, en une seule transaction apt. Deux pièges qu'il
encode : `pkg.candidate` est inexploitable ici (pour un paquet absent de tout
dépôt, python-apt renvoie la version installée, la comparaison montre une égalité
et le paquet est manqué), et les paquets liés par une dépendance stricte comme
`perl`/`perl-base` doivent bouger ensemble.

### `roles/odoo/odoo14/templates/odoo.conf.j2`
Configuration d'Odoo. Connexion par socket Unix local, instance mono-base.
`db_name` est indispensable avec `list_db = False` : sans lui Odoo ne peut ni
lister ni déduire la base à servir, et répond 500.

### `roles/odoo/odoo14/defaults/main.yml`
Valeurs par défaut du rôle, surchargées par `group_vars`. Contient aussi
`debian_mirror`, qui permet de basculer sur `archive.debian.org`.

### `roles/odoo/odoo14/handlers/main.yaml`
Redémarrage d'Odoo et de PostgreSQL après modification de leur configuration.

---

## Rôle `odoo_cleanup` — remise à plat

### `roles/exploitation/odoo_cleanup/tasks/main.yaml`
Arrête Odoo, libère les verrous `dpkg`/`apt` d'un lancement interrompu, termine
la transaction en cours, répare ou supprime les paquets en état incohérent,
réaligne les versions, vide le cache, et affiche un état de fin.

Avec `-e full_reset=true`, purge en plus Odoo, PostgreSQL, leurs données, le
dépôt nightly et les reliquats de l'ancienne architecture répliquée.
**Destructif** : supprime les bases et le filestore.

---

## Rôle `cleanup` — désinstallation LXC

### `roles/lxc/cleanup/tasks/main.yaml`
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

### `docs/EXPLICATION-DES-FICHIERS.md`
Ce document.
