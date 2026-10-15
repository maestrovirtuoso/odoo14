# Lancer les playbooks depuis Ubuntu 22.04 ou Debian 12

Ce guide concerne le **poste de contrôle**, c’est-à-dire la machine depuis
laquelle on lance Ansible. Les serveurs cibles du dépôt restent les hôtes
Rocky 8 et leurs conteneurs Debian 12.

Le dépôt est prévu pour **Ansible 2.10.x** avec les collections épinglées dans
[`requirements.yml`](../requirements.yml) :

| Collection | Version |
| --- | --- |
| `community.general` | `1.3.6` |
| `community.postgresql` | `1.1.1` |
| `ansible.posix` | `1.1.1` |

L’environnement vérifié sur le poste Ubuntu 22.04 du projet utilise
**Ansible 2.10.8 et Python 3.10.12**. Les sorties transmises depuis le poste
Debian 12 confirment aussi l’installation d’**Ansible 2.10.8 avec Python
3.9.25** dans l’environnement uv. L’installation des collections et le
déploiement depuis ce second poste restent à valider.

## 1. Installer Ansible sur Ubuntu 22.04

Utiliser le paquet `ansible` des dépôts Ubuntu 22.04 :

```bash
sudo apt update
sudo apt install -y ansible git openssh-client sshpass
ansible --version
```

La commande doit afficher une version **2.10.x**. Le paquet Ubuntu 22.04
regroupe Ansible 2.10.7 et son moteur 2.10.8.
[Source : paquet Ubuntu](https://packages.ubuntu.com/fr/jammy/ansible).

## 2. Préparer un environnement séparé sur Debian 12

Le paquet Debian 12 fournit `ansible-core` **2.14**, alors que le précontrôle
du dépôt exige une version comprise entre 2.10 inclus et 2.11 exclu.
[Source : paquet Debian](https://packages.debian.org/bookworm/ansible-core).

Pour conserver les versions prévues par le projet, utiliser un environnement
Python **3.9** séparé. Un environnement virtuel créé avec le Python 3.11 de
Debian 12 ne suffit pas à reproduire la plage Python prise en charge par
Ansible 2.10.
[Source : matrice de compatibilité Ansible](https://docs.ansible.com/projects/ansible-core/2.15/reference_appendices/release_and_maintenance.html).

Installer les outils nécessaires :

```bash
sudo apt update
sudo apt install -y git openssh-client sshpass curl ca-certificates

# Installer uv, qui permet de gérer un Python séparé.
curl -LsSf https://astral.sh/uv/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"

uv python install 3.9
uv venv --python 3.9 "$HOME/.venvs/odoo14-ansible"
source "$HOME/.venvs/odoo14-ansible/bin/activate"
uv pip install "ansible-base==2.10.8" "Jinja2==3.0.3"

ansible --version
```

`ansible-base` fournit le moteur et les commandes Ansible ; les collections
du projet seront installées à l’étape suivante. Jinja2 est fixé à 3.0.3 car
Ansible 2.10.8 utilise des fonctions supprimées dans Jinja2 3.1.
[Source : changements Jinja2](https://jinja.palletsprojects.com/en/stable/changes/#version-3-1-0).

La méthode d’installation et la gestion des versions Python sont décrites dans
la documentation officielle de
[uv](https://docs.astral.sh/uv/getting-started/installation/) et dans son guide
[d’installation de Python](https://docs.astral.sh/uv/guides/install-python/).

Dans chaque nouveau terminal Debian 12, réactiver l’environnement :

```bash
source "$HOME/.venvs/odoo14-ansible/bin/activate"
```

## 3. Récupérer le dépôt et installer les collections

Pour la suite, se placer à la racine du dépôt, où se trouvent `ansible.cfg`,
`inventory.yaml` et `requirements.yml`. Si le dépôt n’est pas encore présent,
le récupérer depuis la branche `dev1` :

```bash
git clone --branch dev1 https://github.com/maestrovirtuoso/odoo14.git "$HOME/odoo14"
cd "$HOME/odoo14"
```

Si le dépôt existe déjà, aller dans son dossier. Par exemple, sur le poste
`dev-sys-client1` des sorties transmises :

```bash
cd /home/akam/Documents/odoo14
```

Vérifier le dossier et installer les collections :

```bash
ls ansible.cfg inventory.yaml requirements.yml
ansible --version
ansible-galaxy collection install -r requirements.yml --no-deps
ansible-galaxy collection list
```

`ansible --version` doit maintenant indiquer le fichier `ansible.cfg` du
projet, au lieu de `config file = None`.

L’erreur `The requirements file '/root/requirements.yml' does not exist`
signifie que la commande a été lancée depuis `/root`, hors du dépôt : revenir
dans le dossier du projet avant de la relancer.

`--no-deps` installe les trois collections épinglées, suffisantes pour les
modules utilisés ici. Cela évite de télécharger les collections réseau,
Kubernetes et Google Cloud déclarées par `community.general`, dont ces
playbooks n’ont pas besoin. Cette sélection concerne ce dépôt ; d’autres
usages de `community.general` peuvent nécessiter ces dépendances.

Comparer les versions affichées avec le tableau en début de document : le
précontrôle du playbook vérifie la présence des collections, mais ne compare
pas leurs versions.

### Si le téléchargement échoue avec un délai TLS dépassé

L’erreur `_ssl.c:1130: The handshake operation timed out` peut survenir après
que les métadonnées Galaxy ont été récupérées : le téléchargement de l’archive
échoue pendant la connexion HTTPS, éventuellement après une redirection.
Les sorties transmises ne permettent pas de déterminer si le problème vient
du réseau, du proxy ou du serveur de téléchargement.

Dans Ansible 2.10.8, ce téléchargement utilise le délai par défaut de
`open_url`, soit **10 secondes**. Cette version n’accepte pas `--timeout` pour
`collection install`, et `ANSIBLE_GALAXY_SERVER_TIMEOUT` ne modifie pas ce
chemin de téléchargement. Ne pas réinstaller Python pour cette erreur.

Depuis la racine du dépôt, télécharger les archives avec `curl`, qui permet
de fixer un délai plus long et de réessayer, puis les installer localement :

```bash
(
  set -e
  mkdir -p collections/archives

  for artifact in community-general-1.3.6 community-postgresql-1.1.1 ansible-posix-1.1.1; do
    curl --fail --location --retry 5 --retry-all-errors --retry-delay 5 \
      --connect-timeout 60 --max-time 600 \
      --output "collections/archives/${artifact}.tar.gz.part" \
      "https://galaxy.ansible.com/api/v3/plugin/ansible/content/published/collections/artifacts/${artifact}.tar.gz"
    mv "collections/archives/${artifact}.tar.gz.part" "collections/archives/${artifact}.tar.gz"
  done

  ansible-galaxy collection install --no-deps \
    ./collections/archives/community-general-1.3.6.tar.gz \
    ./collections/archives/community-postgresql-1.1.1.tar.gz \
    ./collections/archives/ansible-posix-1.1.1.tar.gz

  ansible-galaxy collection list
)
```

Le bloc s’arrête si un téléchargement échoue, avant l’installation. Les
archives terminées sont conservées dans `collections/archives`, ignoré par
Git. `curl` conserve la validation des certificats HTTPS.
[Source : installation depuis une archive locale](https://docs.ansible.com/ansible/4/user_guide/collections_using.html).

Si `curl` échoue également, conserver son erreur exacte : une expiration, une
erreur de résolution DNS et une erreur de certificat ont des causes
différentes. Le poste doit pouvoir joindre le serveur final après les
redirections. Si l’accès IPv6 est en cause, réessayer le téléchargement avec
l’option `-4` de `curl` ; si un proxy est obligatoire, configurer le proxy
autorisé pour ce poste. Les archives peuvent aussi être téléchargées sur un
autre poste ayant accès à Galaxy, puis copiées dans `collections/archives`
pour exécuter uniquement la commande d’installation locale ci-dessus.

Copier uniquement les commandes des blocs de ce guide. Les lignes
`Starting...`, `Downloading...` et les invites comme
`(odoo14-ansible) root@dev-sys-client1:...#` sont des sorties du terminal ; les
coller comme commandes provoque les erreurs `command not found` vues dans
les sorties transmises.

## 4. Préparer l’inventaire et l’accès SSH

Vérifier les adresses dans [`inventory.yaml`](../inventory.yaml) et les fichiers
de [`host_vars`](../host_vars). Le poste de contrôle doit pouvoir joindre les
hôtes et les IP des conteneurs sur le réseau.

Le rôle réseau lit par défaut la clé publique `~/.ssh/id_rsa.pub`. Si cette
clé n’existe pas encore, la créer :

```bash
ssh-keygen -t rsa -b 4096
```

Copier la clé sur les trois hôtes d’applications et les trois hôtes PostgreSQL
actuellement actifs dans l’inventaire :

```bash
for h in 192.168.36.21 192.168.36.22 192.168.36.23 192.168.33.21 192.168.33.22 168.168.33.23; do
  ssh-copy-id -i "$HOME/.ssh/id_rsa.pub" "root@$h"
done
```

Le primaire PostgreSQL est `odoodb1` (`192.168.96.156`), porté par
`192.168.33.21`. Les deux autres conteneurs PostgreSQL seront ses répliques.

Une autre clé publique peut être fournie avec
`PROSYS_CONTROLLER_SSH_PUBKEY` dans `.env`. La clé privée correspondante doit
être accessible au client SSH, par exemple via `ANSIBLE_PRIVATE_KEY_FILE`.

## 5. Préparer les secrets et les variables d’environnement

Lors de la première configuration, créer les fichiers locaux s’ils n’existent
pas déjà. Les options `-n` évitent d’écraser une configuration existante :

```bash
cp -n group_vars/all/vault.yml.example group_vars/all/vault.yml
cp -n .env.example .env
```

Modifier `group_vars/all/vault.yml` pour renseigner les mots de passe, puis
chiffrer le fichier s’il est encore en clair :

```bash
ansible-vault encrypt group_vars/all/vault.yml
```

Le vault doit aussi définir `vault_pg_replication_password`,
`vault_pg_patroni_superuser_password` et `vault_pg_patroni_rest_password`.
Voir le [guide Patroni et etcd](POSTGRESQL-PATRONI.md).

Pour modifier un vault déjà chiffré :

```bash
ansible-vault edit group_vars/all/vault.yml
```

Adapter `.env`, puis exporter son contenu avant les commandes Ansible :

```bash
set -a
source .env
set +a
```

Ansible ne charge pas `.env` automatiquement : refaire cet export dans chaque
nouveau terminal. Si `ANSIBLE_VAULT_PASSWORD_FILE` est configuré, l’option
`--ask-vault-pass` devient inutile. Sinon, fournir cette option aux commandes
Ansible qui chargent l’inventaire dès que le vault est chiffré.

## 6. Vérifier puis déployer

### Vérifier la branche et les hôtes sélectionnés

Si `Gathering Facts` tente encore de joindre `192.168.96.128`,
`192.168.96.129` et `192.168.96.140`, l’inventaire chargé contient les anciens
hôtes. L’inventaire courant contient les hôtes Odoo `192.168.36.21`,
`192.168.36.22`, `192.168.36.23` et les hôtes PostgreSQL `192.168.33.21`,
`192.168.33.22`, `168.168.33.23`.

Depuis le dossier du dépôt sur le poste de contrôle, récupérer cette branche :

```bash
(
  set -e
  git status --short --branch
  git fetch origin
  git switch dev1
  git merge --ff-only origin/dev1
)
```

Si Git refuse le changement de branche ou la mise à jour, conserver les
modifications locales et examiner son message avant de continuer. Ce bloc
s’arrête sur une erreur ; il n’écrase pas les fichiers pour forcer la mise à
jour.

Vérifier ensuite explicitement l’inventaire et les cibles des deux playbooks,
sans modifier les serveurs :

```bash
ansible-inventory -i ./inventory.yaml --graph gluster_servers --ask-vault-pass
ansible-playbook -i ./inventory.yaml playbooks/ansi2-snapchot.yaml --list-hosts --ask-vault-pass
ansible-playbook -i ./inventory.yaml playbooks/reseau-lxc.yaml --list-hosts --ask-vault-pass
```

Avec l’inventaire actuel, les trois commandes doivent sélectionner les six
hôtes ci-dessus. L’ancien hôte PostgreSQL `192.168.96.141` n’est plus ciblé.

Tester ensuite l’accès SSH, par exemple sur le premier hôte :

```bash
ssh -o ConnectTimeout=10 root@192.168.36.21 'hostname'
```

Un message `connect to host ... port 22: Connection timed out` indique que
la connexion au port SSH n’a pas abouti : vérifier l’adresse, l’état du
serveur, le routage entre le poste et le serveur et le filtrage du port 22.
Ce blocage arrive avant l’authentification et avant les tâches de création
LXC. L’avertissement sur la découverte Python est une conséquence de
l’impossibilité de se connecter ; il ne prouve pas que Python manque.

Les options de mot de passe ont des usages distincts :

- `-k` ou `--ask-pass` : demander le mot de passe SSH si l’accès par clé n’est
  pas encore configuré.
- `-K` ou `--ask-become-pass` : demander le mot de passe d’élévation de
  privilèges ; cette option seule n’active pas `become`. L’inventaire actuel
  se connecte directement en `root`.
- `--ask-vault-pass` : déchiffrer le vault du projet.

Changer ces options ne résout pas un délai de connexion au port 22.

### Lancer les vérifications et la création

Vérifier l’environnement du poste de contrôle et la connexion aux hôtes sans
modifier les serveurs :

```bash
ansible-playbook playbooks/ansi_odoo.yaml --tags preflight --ask-vault-pass
ansible -i ./inventory.yaml gluster_servers -m ping --ask-vault-pass
```

La configuration PostgreSQL utilise Patroni et trois membres etcd pour
gérer un primaire et deux répliques. Un
cluster contenant des données applicatives est protégé contre une
réinitialisation implicite ; les détails de préparation et de vérification
figurent dans [POSTGRESQL-PATRONI.md](POSTGRESQL-PATRONI.md).

Si les conteneurs n’existent pas encore, les créer :

```bash
ansible-playbook -i ./inventory.yaml playbooks/ansi2-snapchot.yaml --ask-vault-pass
```

Avant le déploiement, vérifier également que la carte dédiée aux conteneurs
(`nic=ens224` par défaut dans l’inventaire) ne porte pas la connexion SSH ni
la route par défaut de l’hôte : le rôle réseau la donne au conteneur.

Lancer le déploiement :

```bash
ansible-playbook playbooks/ansi_odoo.yaml --ask-vault-pass
```

## 7. Vérifier les services

```bash
ansible odoo_containers --ask-vault-pass -m shell -a 'systemctl is-active odoo'
ansible db_containers --ask-vault-pass -m shell -a 'systemctl is-active odoo14-patroni odoo14-etcd'
```

Avec les IP actuelles, les interfaces Odoo sont accessibles sur :

- <http://192.168.96.151:8069/web/login>
- <http://192.168.96.152:8069/web/login>
- <http://192.168.96.153:8069/web/login>

## 8. Voir d’abord les conteneurs existants sur les nouveaux serveurs

Les nouveaux hôtes PostgreSQL figurent dans `gluster_servers` :

- `192.168.33.21` : serveur prévu pour la base de données.
- `192.168.33.22`.
- `168.168.33.23` : adresse conservée exactement comme fournie.

La commande suivante lit la liste des conteneurs LXC déjà présents, avec leurs
noms, états et adresses. Il n’installe aucun paquet et ne modifie pas les
conteneurs ni leur réseau. Il se connecte en `root` et utilise `raw`, sans
Python distant ni collection supplémentaire.

Afficher les conteneurs des trois hôtes PostgreSQL :

```bash
ansible -i ./inventory.yaml gluster_servers \
  --limit '192.168.33.21,192.168.33.22,168.168.33.23' \
  -m raw -a 'lxc-ls --fancy' --ask-vault-pass
```

Ajouter `-k` si la connexion SSH se fait encore par mot de passe. Si aucun
vault chiffré n’est utilisé, omettre `--ask-vault-pass`.

Les erreurs SSH et l’absence de la commande `lxc-ls` sont signalées comme des
erreurs ; elles ne sont pas interprétées comme une absence de conteneurs.
