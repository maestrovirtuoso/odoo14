# scripting11 — Sauvegarde du volume Gluster "training"

Procédure complète, automatisée avec Ansible pour le cycle de vie du snapshot
(création / montage / démontage / suppression) et un script shell dédié pour
la copie des données.

## Fichiers du projet

- `inventory.ini` — inventaire Ansible (groupe `gluster_servers`, hôte `gluster9`)
- `playbooks/ansible-snapchot.yml` — création, activation, montage, démontage
  et suppression du snapshot Gluster
- `scripts/copy-file.sh` — copie par lots (`0-4`, `5-9`, `a-c`, `d-f`) du
  contenu du snapshot monté vers la destination de sauvegarde oVirt

## 1. Création, activation et montage du snapshot

```bash
ansible-playbook -i inventory.ini playbooks/ansible-snapchot.yml \
  --tags snapshot,mount,prepare
```

Ceci exécute, sur `gluster9` :
1. `gluster snapshot create training-snapshot training no-timestamp`
2. `gluster snapshot activate training-snapshot`
3. création de `/mnt/snapshots/training`
4. montage du snapshot (`mount -t glusterfs gluster9:/snaps/training-snapshot/training /mnt/snapshots/training`)
5. création de `/mnt/backup/ovirt/volumes/training/cb690d5d-6321-410a-ae87-1b1cf01ab3e8`
   (propriétaire `vdsm:kvm`)

## 2. Vérification du contenu à copier

```bash
ls -lh /mnt/snapshots/training/cb690d5d-6321-410a-ae87-1b1cf01ab3e8/images/
```

## 3. Copie des données

Sur l'hôte `gluster9`, lancer le script (idéalement via `at` ou `nohup` pour
un gros volume) :

```bash
./scripts/copy-file.sh \
  /mnt/snapshots/training/cb690d5d-6321-410a-ae87-1b1cf01ab3e8/images \
  /mnt/backup/ovirt/volumes/training/cb690d5d-6321-410a-ae87-1b1cf01ab3e8/images
```

Le script copie par lots alphabétiques (`0*1*2*3*4*`, `5*6*7*8*9*`, `a*b*c*`,
`d*e*f*` — couvrant tout l'espace hexadécimal des UUID Gluster), journalise
chaque étape dans `/copy-hp-training.log`, et s'arrête immédiatement (`set -euo
pipefail`) en cas d'échec d'un `cp`.

Suivi en parallèle :

```bash
ps -ef | grep "cp -r"
tail -f /copy-hp-training.log
```

## 4. Vérification du résultat

```bash
ls -l /mnt/backup/ovirt/volumes/training/cb690d5d-6321-410a-ae87-1b1cf01ab3e8/images/
df -h
```

## 5. Démontage et nettoyage du snapshot

```bash
ansible-playbook -i inventory.ini playbooks/ansible-snapchot.yml \
  --tags unmount,cleanup
```

Ceci exécute :
1. démontage de `/mnt/snapshots/training`
2. suppression du point de montage
3. `gluster snapshot deactivate training-snapshot`
4. `gluster snapshot delete training-snapshot`

## Correctif par rapport à la procédure initiale (README.md)

Le script de copie original omettait le préfixe `5*` (les fichiers commençant
par `5` n'étaient jamais copiés) et utilisait des chemins en dur. `copy-file.sh`
corrige les deux points et accepte désormais `source_dir`/`dest_dir` en
paramètres.
