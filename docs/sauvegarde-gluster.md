# scripting11

Voici la séquence propre, sans les tâtonnements :

## 1. Création et activation du snapshot Gluster
```bash
gluster snapshot create training-snapshot training no-timestamp
gluster snapshot activate training-snapshot
```

## 2. Préparation du point de montage
```bash
mkdir /mnt/snapshots/training
```

## 3. Montage du snapshot
```bash
mount -t glusterfs gluster9:/snaps/training-snapshot/training /mnt/snapshots/training
```

## 4. Préparation de la destination de sauvegarde
```bash
mkdir -p /mnt/backup/ovirt/volumes/training/cb690d5d-6321-410a-ae87-1b1cf01ab3e8/images
chown -R vdsm:kvm /mnt/backup/ovirt
```

## 5. Vérification du contenu à copier
```bash
cd /mnt/snapshots/training/cb690d5d-6321-410a-ae87-1b1cf01ab3e8/images/
ls -lh
```

## 6. Lancement et suivi de la copie (via `at`)
```bash
touch /root/copy-hp-training.log
at 9:41 am
echo "starting copy for HP volume training 0-4" >> /root/copy-hp-training.log
atq
ps -ef | grep "cp -r"
tail /root/copy-hp-training.log
```

## 7. Vérification du résultat
```bash
ls -l /mnt/backup/ovirt/volumes/training/cb690d5d-6321-410a-ae87-1b1cf01ab3e8/
df -h
```

## 8. Destruction / nettoyage
Aucune commande de démontage (`umount`) ni de suppression du snapshot (`gluster snapshot delete`) n'apparaît dans cet historique.

Souhaites-tu que je te propose les commandes pour compléter cette étape finale ?



Voici l'étape 6 complétée avec les commandes de copie, et la correction du chemin du log (uniformisé en chemin absolu `/copy-hp-training.log` à la racine, au lieu du mélange relatif/absolu dans l'original) :

## 6. Lancement et suivi de la copie (par lots alphabétiques)

```bash
touch /copy-hp-training.log

echo "starting copy for HP volume training 0-4" >> /copy-hp-training.log
date >> /copy-hp-training.log
cp -r --sparse=always 0* 1* 2* 3* 4* /mnt/backup/ovirt/volumes/training/cb690d5d-6321-410a-ae87-1b1cf01ab3e8/
echo "End of copy for HP volume training 0-4 ($?)" >> /copy-hp-training.log
date >> /copy-hp-training.log

echo "starting copy for HP volume training 6-9" >> /copy-hp-training.log
date >> /copy-hp-training.log
cp -r --sparse=always 6* 7* 8* 9* /mnt/backup/ovirt/volumes/training/cb690d5d-6321-410a-ae87-1b1cf01ab3e8/
echo "End of copy for HP volume training 6-9 ($?)" >> /copy-hp-training.log
date >> /copy-hp-training.log

echo "starting copy for HP volume training a-c" >> /copy-hp-training.log
date >> /copy-hp-training.log
cp -r --sparse=always a* b* c* /mnt/backup/ovirt/volumes/training/cb690d5d-6321-410a-ae87-1b1cf01ab3e8/
echo "End of copy for HP volume training a-c ($?)" >> /copy-hp-training.log
date >> /copy-hp-training.log

echo "starting copy for HP volume training d-f" >> /copy-hp-training.log
date >> /copy-hp-training.log
cp -r --sparse=always d* e* f* /mnt/backup/ovirt/volumes/training/cb690d5d-6321-410a-ae87-1b1cf01ab3e8/
echo "End of copy for HP volume training d-f ($?)" >> /copy-hp-training.log
date >> /copy-hp-training.log
```

**Vérification logique :**
- Le fichier `0*` couvre les noms commençant par 0, 1, 2, 3, 4 → correct, aucun chevauchement avec le lot suivant.
- Lot `6-9` : manque le préfixe `5*` — à vérifier si volontaire (pas de fichier commençant par 5 dans le volume, ou oubli).
- Les 3 blocs suivants (`6-9`, `a-c`, `d-f`) couvrent bien les caractères hexadécimaux restants (UUID Gluster en hex : 0-9, a-f).
- `$?` capture correctement le code retour du `cp` précédent, car il est référencé immédiatement après (avant tout autre `echo`/`date`).
- `--sparse=always` est cohérent pour préserver les fichiers creux (images disques QCOW2/RAW).

⚠️ **Point à vérifier** : le préfixe `5*` semble absent des 4 lots. Si des fichiers commencent par `5`, ils ne seront pas copiés.


umount /mnt/backup 2>/dev/null
sed -i 's|node5:/backup|node5:/mnt/backup|' /etc/fstab
grep backup /etc/fstab
systemctl daemon-reload
mount -a
df -h /mnt/backup    # doit montrer ~50G



for b in 1 2 3 4; do echo "brick$b: $(ls /data/glusterfs/backup/brick$b/brick/ | wc -l) éléments"; done


---
# --- Étapes 1-2 : création et activation du snapshot ---
- name: Créer le snapshot Gluster
  command: gluster snapshot create training-snapshot training no-timestamp
  tags: [snapshot]

- name: Activer le snapshot Gluster
  command: gluster snapshot activate training-snapshot
  tags: [snapshot]

# --- Étape 3 : préparation et montage ---
- name: Créer le point de montage du snapshot
  file:
    path: /mnt/snapshots/training
    state: directory
    mode: "0755"
  tags: [mount]

- name: Monter le snapshot
  mount:
    path: /mnt/snapshots/training
    src: "192.168.100.10:/snaps/training-snapshot/training"
    fstype: glusterfs
    state: mounted
  tags: [mount]

# --- Étape 4 : préparation de la destination de sauvegarde ---
- name: Créer le répertoire de destination de sauvegarde
  file:
    path: /mnt/backup/ovirt/volumes/training/cb690d5d-6321-410a-ae87-1b1cf01ab3e8/images
    state: directory
    owner: root
    group: root
  tags: [prepare]

# --- Étape 5 : copie des données (longue, plusieurs heures) ---
- name: Copier les données depuis le snapshot vers la destination de backup
  script: "../files/copy-files.sh"
  args:
    executable: /bin/bash
  tags: [copy]

# --- Étape 8 : démontage et nettoyage ---
- name: Démonter le snapshot
  mount:
    path: /mnt/snapshots/training
    state: unmounted
  tags: [unmount]

- name: Désactiver le snapshot
  command: gluster snapshot deactivate training-snapshot
  tags: [cleanup]

- name: Supprimer le snapshot
  command: gluster snapshot delete training-snapshot
  tags: [cleanup]

mount -t glusterfs node5:/snaps/training-snapshot/training /mnt/snapshots/training

sudo apt update && sudo apt install -y glusterfs-client
sudo mkdir -p /mnt/backup
sudo mount -t glusterfs node5:/backup /mnt/backup