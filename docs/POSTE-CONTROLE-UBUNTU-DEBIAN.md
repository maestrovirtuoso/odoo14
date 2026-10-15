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
**Ansible 2.10.8 et Python 3.10.12**. La procédure d’installation du poste de
contrôle sous Debian 12 ci-dessous reste à valider sur ce système.

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

## 3. Installer les collections du projet

Pour la suite, se placer à la racine du dépôt, où se trouvent `ansible.cfg`,
`inventory.yaml` et `requirements.yml` :

```bash
ansible-galaxy collection install -r requirements.yml
ansible-galaxy collection list
```

Comparer les versions affichées avec le tableau en début de document : le
précontrôle du playbook vérifie la présence des collections, mais ne compare
pas leurs versions.

## 4. Préparer l’inventaire et l’accès SSH

Vérifier les adresses dans [`inventory.yaml`](../inventory.yaml) et les fichiers
de [`host_vars`](../host_vars). Le poste de contrôle doit pouvoir joindre les
hôtes et les IP des conteneurs sur le réseau.

Le rôle réseau lit par défaut la clé publique `~/.ssh/id_rsa.pub`. Si cette
clé n’existe pas encore, la créer :

```bash
ssh-keygen -t rsa -b 4096
```

Copier la clé sur les trois hôtes d’applications et l’hôte PostgreSQL
actuellement déclarés dans l’inventaire (adapter les adresses si nécessaire) :

```bash
for h in 192.168.36.21 192.168.36.22 192.168.36.23 192.168.96.141; do
  ssh-copy-id -i "$HOME/.ssh/id_rsa.pub" "root@$h"
done
```

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

Vérifier l’environnement du poste de contrôle et la connexion aux hôtes sans
modifier les serveurs :

```bash
ansible-playbook playbooks/ansi_odoo.yaml --tags preflight --ask-vault-pass
ansible gluster_servers -m ping --ask-vault-pass
```

**Attention :** dans la configuration actuelle,
[`host_vars/192.168.96.141.yml`](../host_vars/192.168.96.141.yml) déclare
`devodoo14` dans `stale_containers`. Le playbook de création supprime cet ancien
conteneur avant de créer `devpg15`. Sauvegarder ses données si elles doivent
être conservées.

Si les conteneurs n’existent pas encore, les créer :

```bash
ansible-playbook playbooks/ansi2-snapchot.yaml --ask-vault-pass
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
ansible db_containers --ask-vault-pass -m shell -a 'systemctl is-active postgresql'
```

Avec les IP actuelles, les interfaces Odoo sont accessibles sur :

- <http://192.168.96.151:8069/web/login>
- <http://192.168.96.152:8069/web/login>
- <http://192.168.96.153:8069/web/login>
