# README1 — Déployer ProSys depuis un autre poste

Liste des commandes à exécuter, dans l'ordre, sur un **nouveau poste de
contrôle** (Debian/Ubuntu) pour déployer le cluster Odoo 14.

Cible du déploiement :

| Rôle | Hôte Rocky 8 | Conteneur LXC | IP conteneur |
|---|---|---|---|
| Odoo primaire (init base + crons) | 192.168.96.128 | devodoo14 | 192.168.96.151 |
| Odoo | 192.168.96.129 | devodoo14 | 192.168.96.152 |
| Odoo | 192.168.96.140 | devodoo14 | 192.168.96.153 |
| PostgreSQL 15 dédié | 192.168.96.141 | devpg15 | 192.168.96.150 |

---

## 1. Paquets du poste de contrôle

```bash
sudo apt update
sudo apt install -y ansible git openssh-client sshpass
```

Vérifier la version — **elle doit être 2.10.x** :

```bash
ansible --version
```

> `ansible.posix 1.1.1` déclare `requires_ansible: >=2.9,<2.11`. Avec
> ansible ≥ 2.11 la collection refuse de se charger et le playbook s'arrête
> dès la play `0/5`. Si le poste a une version plus récente :
> `sudo apt remove ansible && pip3 install 'ansible==2.10.8'`.

## 2. Récupérer le dépôt

```bash
git clone git@github.com:maestrovirtuoso/odoo14.git ProSys
cd ProSys
```

## 3. Collections Ansible (versions épinglées)

```bash
ansible-galaxy collection install -r requirements.yml
ansible-galaxy collection list | grep -E 'community.general|community.postgresql|ansible.posix'
```

Attendu : `community.general 1.3.6`, `community.postgresql 1.1.1`,
`ansible.posix 1.1.1`.

## 4. Clé SSH (RSA obligatoire)

Le rôle `lxc_lan` injecte `~/.ssh/id_rsa.pub` dans les conteneurs.

```bash
ls ~/.ssh/id_rsa.pub || ssh-keygen -t rsa -b 4096
for h in 128 129 140 141; do ssh-copy-id root@192.168.96.$h; done
```

Vérifier que les 4 hôtes répondent sans mot de passe :

```bash
ansible gluster_servers -m ping
```

## 5. Secrets (vault)

```bash
cp group_vars/all/vault.yml.example group_vars/all/vault.yml
$EDITOR group_vars/all/vault.yml          # vault_odoo_admin_password, vault_odoo_db_password
ansible-vault encrypt group_vars/all/vault.yml
```

Optionnel — éviter de retaper le mot de passe du vault à chaque commande :

```bash
printf '%s' 'mon-mot-de-passe-vault' > ~/.prosys-vault-pass
chmod 600 ~/.prosys-vault-pass
```

puis décommenter `ANSIBLE_VAULT_PASSWORD_FILE` dans `.env` (étape suivante).

## 6. Variables d'environnement

```bash
cp .env.example .env
$EDITOR .env
set -a && source .env && set +a
```

`.env` n'est **pas** lu automatiquement : il faut le sourcer dans chaque
nouveau terminal avant de lancer un playbook.

## 7. Vérifier la carte réseau dédiée avant de toucher aux hôtes

La play réseau retire la carte `ens224` de l'hôte pour la donner au conteneur.
Elle ne doit **jamais** porter la route par défaut ni votre session SSH :

```bash
ansible gluster_servers -m shell -a 'ip -br link show ens224; ip r | head -1'
```

Si un hôte nomme sa carte autrement, surcharger `nic` dans
`host_vars/<ip>.yml`.

## 8. Créer les conteneurs LXC

```bash
ansible-playbook playbooks/ansi2-snapchot.yaml
```

> Sur 192.168.96.141, ce play **détruit** l'ancien conteneur `devodoo14`
> (`stale_containers`) avant de créer `devpg15`. Sauvegarder d'abord la base
> et le filestore si cet hôte porte des données.

## 9. Déploiement complet

```bash
ansible-playbook playbooks/ansi_odoo.yaml --ask-vault-pass
```

(sans `--ask-vault-pass` si `ANSIBLE_VAULT_PASSWORD_FILE` est défini)

Les 6 plays, dans un ordre contraignant :

| Play | Cible | Effet |
|---|---|---|
| 0/5 | localhost | Contrôle des versions ansible + collections |
| 1/5 | `gluster_servers` | Carte physique donnée au conteneur, amorçage SSH |
| 2/5 | `db_containers` | PostgreSQL 15, rôle `odoo`, `pg_hba.conf` |
| 3/5 | `odoo_containers` | Python 3.8, Odoo 14, `odoo.conf` — service **arrêté** |
| 4/5 | `odoo_primary` | `odoo -i base` sur la base partagée, **odoo1 seul** |
| 5/5 | `odoo_containers` | Démarrage des 3 instances, attente du port 8069 |

## 10. Vérification

```bash
# services actifs
ansible odoo_containers -m shell -a 'systemctl is-active odoo'
ansible db_containers   -m shell -a 'systemctl is-active postgresql'

# base accessible en lecture/écriture depuis le conteneur PostgreSQL
ansible db_containers -m shell -a "sudo -u postgres psql -tAc \
  \"select case when pg_is_in_recovery() then 'LECTURE SEULE (anormal)' \
    else 'lecture/ecriture' end\""

# interface web des trois instances
for i in 151 152 153; do curl -sI -o /dev/null -w "$i -> %{http_code}\n" \
  http://192.168.96.$i:8069/web/login; done
```

Connexion : `admin` / `admin` (mot de passe par défaut créé par `-i base`,
à changer à la première connexion). Le `admin_passwd` du vault est le mot de
passe **maître** de gestion des bases, pas celui de l'utilisateur.

---

## Rejouer une étape seule

```bash
# réseau uniquement (carte physique, redémarrage des conteneurs)
ansible-playbook playbooks/reseau-lxc.yaml -k

# voir ce qui changerait sans rien toucher
ansible-playbook playbooks/reseau-lxc.yaml -k --check --diff

# un seul hôte
ansible-playbook playbooks/ansi_odoo.yaml --ask-vault-pass --limit 192.168.96.128
```

## Nettoyage

```bash
# réparation APT dans les conteneurs Odoo — non destructif
ansible-playbook playbooks/nettoyage_odoo.yaml --ask-vault-pass

# DESTRUCTIF : supprime bases PostgreSQL et filestore
ansible-playbook playbooks/nettoyage_odoo.yaml --ask-vault-pass -e full_reset=true

# DESTRUCTIF : désinstalle LXC et détruit les conteneurs sur les hôtes
ansible-playbook playbooks/nettoyage.yaml
```

Repartir de zéro : `nettoyage.yaml` → `ansi2-snapchot.yaml` → `ansi_odoo.yaml`.

## Checklist express

```bash
sudo apt install -y ansible git openssh-client sshpass
git clone git@github.com:maestrovirtuoso/odoo14.git ProSys && cd ProSys
ansible-galaxy collection install -r requirements.yml
ssh-keygen -t rsa -b 4096
for h in 128 129 140 141; do ssh-copy-id root@192.168.96.$h; done
cp group_vars/all/vault.yml.example group_vars/all/vault.yml
$EDITOR group_vars/all/vault.yml && ansible-vault encrypt group_vars/all/vault.yml
cp .env.example .env && set -a && source .env && set +a
ansible-playbook playbooks/ansi2-snapchot.yaml
ansible-playbook playbooks/ansi_odoo.yaml --ask-vault-pass



PLAY [0/5 - Verifier l'environnement du poste de controle] ***************************************************************************************************************************

TASK [La version d'ansible est dans la fourchette validee] ***************************************************************************************************************************
ok: [localhost] => {
    "changed": false,
    "msg": "ansible 2.10.8"
}

TASK [Les collections requises sont presentes aux versions attendues] ****************************************************************************************************************
ok: [localhost]

TASK [Aucune collection requise ne manque] *******************************************************************************************************************************************
ok: [localhost] => (item=community.general 1.3.6) => {
    "ansible_loop_var": "item",
    "changed": false,
    "item": {
        "name": "community.general",
        "version": "1.3.6"
    },
    "msg": "All assertions passed"
}
ok: [localhost] => (item=community.postgresql 1.1.1) => {
    "ansible_loop_var": "item",
    "changed": false,
    "item": {
        "name": "community.postgresql",
        "version": "1.1.1"
    },
    "msg": "All assertions passed"
}
ok: [localhost] => (item=ansible.posix 1.1.1) => {
    "ansible_loop_var": "item",
    "changed": false,
    "item": {
        "name": "ansible.posix",
        "version": "1.1.1"
    },
    "msg": "All assertions passed"
}

```
