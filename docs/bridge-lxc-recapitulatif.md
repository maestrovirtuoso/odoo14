# Configuration réseau bridge pour conteneurs LXC — 3 nœuds Rocky 8

Documentation des manipulations réalisées sur le cluster `gluster_servers`
(192.168.96.139 / .140 / .141) pour donner une adresse IP routable aux
conteneurs LXC `devodoo14`.

---

## 1. Pourquoi un bridge ?

### Le problème

Par défaut, LXC crée un bridge interne `lxcbr0` en 10.0.3.0/24 avec un
serveur DHCP local (dnsmasq) et du NAT. Ce mode fonctionne, mais impose
trois limites :

| Limite | Conséquence concrète |
|---|---|
| Réseau privé isolé | Les conteneurs sont en 10.0.3.x, invisibles depuis le LAN 192.168.96.0/24 |
| Isolation inter-hôtes | Le conteneur de .139 ne peut pas joindre celui de .141, alors qu'ils ont le même plan d'adressage |
| Accès entrant par NAT | Chaque service à publier (Odoo sur 8069, PostgreSQL sur 5432…) demande une règle de redirection sur l'hôte |

### La solution

Un bridge `br0` posé **sur l'interface physique** `ens160` place les
conteneurs directement sur le LAN. Ils obtiennent une adresse
192.168.96.x, au même titre qu'une machine physique.

```
AVANT (lxcbr0, NAT)                APRÈS (br0, bridge L2)

  [conteneur 10.0.3.x]               [conteneur 192.168.96.150]
          |                                    |
      [lxcbr0] -- NAT --> [ens160]          [br0] --- [ens160]
          |                    |               |          |
      (isolé)              192.168.96.139   (même L2)  LAN 192.168.96.0/24
```

Bénéfices :

- **Accès direct** : `http://192.168.96.150:8069` depuis n'importe quel poste du LAN
- **Communication inter-nœuds** : les trois conteneurs se voient (indispensable pour un cluster, une réplication, un partage GlusterFS)
- **Pas de règles NAT** à maintenir port par port
- **Adressage maîtrisé** : IP statiques, DNS interne possible

### Quand ne PAS le faire

Si les conteneurs n'ont besoin que de sortir vers internet et d'exposer
un ou deux ports, `lxcbr0` + redirection de port reste plus simple et
plus sûr (voir §7).

---

## 2. Prérequis

### 2.1 — Espace disque

Un rootfs Debian bullseye occupe ~400 Mo, un conteneur Odoo + PostgreSQL
4 à 6 Go. La racine des hôtes était initialement à 4 Go (90 % pleins),
ce qui faisait échouer `lxc-create` avec `No space left on device`.

Le disque virtuel faisait 20 Go dont seulement 9 Go partitionnés :
11 Go étaient récupérables sans toucher à l'hyperviseur.

```bash
# Vérifier l'espace non alloué : SIZE du disque vs somme des partitions
lsblk

# Installer l'outil de redimensionnement de partition si absent
dnf install -y cloud-utils-growpart

# Étendre la partition 2 sur tout l'espace libre qui la suit
growpart /dev/nvme0n1 2

# Informer LVM que le volume physique a grandi
pvresize /dev/nvme0n1p2

# Attribuer tout l'espace libre du groupe au volume logique racine
lvextend -l +100%FREE /dev/mapper/rl-root

# Étendre le système de fichiers XFS (à chaud, sans démontage)
xfs_growfs /

# Contrôle : la racine doit être passée de 4 Go à ~11 Go
df -h /
```

> `xfs_growfs` ne sait qu'agrandir, jamais réduire. Aucun risque pour les
> données. Si le système de fichiers est ext4, utiliser `resize2fs` à la
> place.

### 2.2 — Identifier l'interface physique et la passerelle

```bash
# Nom de l'interface et connexions NetworkManager actives
nmcli -t -f DEVICE,TYPE,STATE con show --active

# Passerelle réelle du réseau (ne PAS la supposer)
ip r | grep default
```

Résultat sur ce cluster : interface `ens160`, passerelle `192.168.96.2`,
hôtes en DHCP.

---

## 3. Création du bridge (par hôte)

> **Avertissement** — cette opération coupe brièvement le réseau de
> l'hôte. Garder une console de l'hyperviseur ouverte et procéder
> **un nœud à la fois**. Trois hôtes cassés simultanément par une
> commande Ansible, c'est une soirée perdue.

### 3.1 — Script exécuté en arrière-plan

Les commandes doivent s'enchaîner sans dépendre de la session SSH, qui
tombe entre le `con down` et le `con up`. `setsid` détache le processus
du terminal pour qu'il survive à la déconnexion.

```bash
cat > /root/mkbr0.sh <<'EOF'
#!/bin/bash

# Créer la connexion bridge nommée br0
nmcli con add type bridge ifname br0 con-name br0

# Mode DHCP : le bridge hérite de la MAC de ens160 et récupère
# le même bail que l'hôte avait auparavant.
# IPv6 désactivé pour éviter les auto-configurations parasites.
nmcli con mod br0 ipv4.method auto ipv6.method disabled

# STP inutile ici (pas de boucle possible) et ajoute 30 s au démarrage
nmcli con mod br0 bridge.stp no

# Rattacher l'interface physique au bridge en tant qu'esclave
nmcli con add type bridge-slave ifname ens160 master br0 con-name br0-slave

# Bascule : couper l'interface physique puis monter le bridge
nmcli con down ens160
nmcli con up br0
EOF

chmod +x /root/mkbr0.sh

# Exécution détachée : survit à la coupure de la session SSH
setsid /root/mkbr0.sh > /root/mkbr0.log 2>&1 < /dev/null &
```

Attendre ~15 secondes, puis se reconnecter.

### 3.2 — Vérifications

```bash
# br0 doit porter l'adresse IP de l'hôte
ip -br a show br0

# ens160 doit apparaître avec "master br0"
bridge link show

# La route par défaut doit passer par br0
ip r | grep default

# Confirmer le rattachement côté NetworkManager
nmcli con show br0-slave | grep connection.master
```

Sortie attendue :

```
br0              UP    192.168.96.139/24
2: ens160: <...> master br0 state forwarding
```

### 3.3 — Retour arrière en cas de problème

Depuis la console de l'hyperviseur :

```bash
nmcli con delete br0 br0-slave
nmcli con up ens160
```

---

## 4. Configuration du conteneur

### 4.1 — Pointer le conteneur vers br0

```bash
# Remplacer lxcbr0 par br0 dans la config du conteneur
sed -i 's/^lxc\.net\.0\.link.*/lxc.net.0.link = br0/' \
  /var/lib/lxc/devodoo14/config

# Toujours vérifier : un sed silencieux qui n'a rien matché est courant
grep lxc.net.0.link /var/lib/lxc/devodoo14/config
```

### 4.2 — Adresse IP statique dans le conteneur

**Point important** : l'image bullseye de linuxcontainers n'embarque pas
`ifupdown`. Il n'y a donc ni `/etc/network/interfaces` ni
`networking.service` — elle utilise **systemd-networkd**. Écrire dans
`/etc/network/interfaces` n'a aucun effet.

```bash
cat > /var/lib/lxc/devodoo14/rootfs/etc/systemd/network/eth0.network <<'EOF'
[Match]
Name=eth0

[Network]
Address=192.168.96.150/24
Gateway=192.168.96.2
DNS=192.168.96.2
EOF
```

### 4.3 — Redémarrage du conteneur

```bash
# stop + start séparés : "lxc-stop -r" fait un reboot interne
# qui ne recrée pas le veth avec la nouvelle configuration réseau
lxc-stop -n devodoo14
lxc-start -n devodoo14
sleep 8

# La colonne IPV4 doit être remplie
lxc-ls -f

# Le veth doit maintenant apparaître avec "master br0"
bridge link show | grep br0
```

---

## 5. Plan d'adressage

| Hôte | IP hôte | Conteneur | IP conteneur |
|---|---|---|---|
| Node1 | 192.168.96.139 | devodoo14 | 192.168.96.150 |
| Node2 | 192.168.96.140 | devodoo14 | 192.168.96.151 |
| Node3 | 192.168.96.141 | devodoo14 | 192.168.96.152 |

Passerelle : 192.168.96.2 — DNS : 192.168.96.2

> Vérifier que .150–.152 sont **hors de la plage DHCP** du réseau, sinon
> conflit d'adresses. Sous VMware Workstation : Virtual Network Editor →
> DHCP Settings.

---

## 6. Déploiement sur les 3 nœuds via Ansible

À n'appliquer qu'**après validation complète du premier nœud**.

### 6.1 — Variables (`host_vars/`)

```yaml
# host_vars/192.168.96.139.yml
lxc_container_ip: 192.168.96.150

# host_vars/192.168.96.140.yml
lxc_container_ip: 192.168.96.151

# host_vars/192.168.96.141.yml
lxc_container_ip: 192.168.96.152
```

```yaml
# group_vars/gluster_servers.yml
lxc_container_name: devodoo14
lxc_bridge: br0
network_gateway: 192.168.96.2
network_dns: 192.168.96.2
physical_iface: ens160
```

### 6.2 — Rôle de configuration du conteneur

Le bridge lui-même se crée manuellement (§3) : le risque de perdre
l'accès SSH est trop élevé pour l'automatiser sans console de secours.
En revanche la configuration des conteneurs s'automatise sans danger.

```yaml
- name: Pointer le conteneur vers le bridge physique
  ansible.builtin.lineinfile:
    path: "/var/lib/lxc/{{ lxc_container_name }}/config"
    regexp: '^lxc\.net\.0\.link'
    line: "lxc.net.0.link = {{ lxc_bridge }}"
  notify: redemarrer conteneur

- name: Configurer systemd-networkd dans le conteneur
  ansible.builtin.copy:
    dest: "/var/lib/lxc/{{ lxc_container_name }}/rootfs/etc/systemd/network/eth0.network"
    mode: '0644'
    content: |
      [Match]
      Name=eth0

      [Network]
      Address={{ lxc_container_ip }}/24
      Gateway={{ network_gateway }}
      DNS={{ network_dns }}
  notify: redemarrer conteneur

- name: Verifier que le conteneur a bien une IPv4
  ansible.builtin.command: "lxc-info -n {{ lxc_container_name }} -iH"
  register: lxc_ip
  changed_when: false
  failed_when: lxc_container_ip not in lxc_ip.stdout
```

```yaml
# handlers/main.yml
# stop + start séparés, pas "lxc-stop -r" (voir §4.3)
- name: redemarrer conteneur
  ansible.builtin.shell: |
    lxc-stop -n {{ lxc_container_name }}
    lxc-start -n {{ lxc_container_name }}
    sleep 8
```

### 6.3 — Contrôle préalable d'espace disque

Évite de dérouler dix tâches pour découvrir le problème à la onzième.

```yaml
- name: Verifier l'espace disque disponible
  ansible.builtin.assert:
    that:
      - (ansible_mounts | selectattr('mount','equalto','/') | first).size_available > 2000000000
    fail_msg: "Moins de 2 Go libres sur / : creation de conteneur impossible"
```

---

## 7. Limite bloquante : filtrage MAC de l'hyperviseur

### Symptôme

Configuration Linux entièrement correcte, mais :

```bash
lxc-attach -n devodoo14 -- ping -c2 192.168.96.139   # OK, 0.14 ms
lxc-attach -n devodoo14 -- ping -c2 192.168.96.2     # Destination Host Unreachable
```

### Diagnostic

```bash
dnf install -y tcpdump

# Session 1 : écouter l'ARP sur l'interface physique
tcpdump -i ens160 -n arp

# Session 2 : provoquer du trafic
lxc-attach -n devodoo14 -- ping -c3 192.168.96.2
```

Résultat observé :

```
ARP, Request who-has 192.168.96.2 tell 192.168.96.150, length 28
ARP, Request who-has 192.168.96.2 tell 192.168.96.150, length 28
```

Les requêtes **sortent** avec la bonne adresse source, aucune réponse ne
revient. Le vSwitch VMware rejette les trames dont l'adresse MAC source
diffère de celle déclarée pour la carte virtuelle — comportement par
défaut, et le conteneur a sa propre MAC (`00:16:3e:...`).

À noter : `br_netfilter` n'était pas chargé, donc ce n'est pas le
pare-feu du bridge.

### Correctif — VMware Workstation

VM éteinte, ajouter dans le fichier `.vmx` :

```
ethernet0.noPromisc = "FALSE"
```

Sous Linux, également dans `/etc/vmware/config` :

```
vmnet.promiscuous = "TRUE"
```

Puis :

```bash
sudo vmware-networks --stop && sudo vmware-networks --start
```

### Correctif — ESXi / vCenter

Port group du vSwitch → **Edit** → **Security** → passer sur *Accept* :

- Promiscuous mode
- MAC address changes
- Forged transmits

### Repli si l'hyperviseur n'est pas modifiable

Retour sur `lxcbr0` avec publication de port depuis l'hôte :

```bash
# Revenir au bridge interne LXC
sed -i 's/^lxc\.net\.0\.link.*/lxc.net.0.link = lxcbr0/' \
  /var/lib/lxc/devodoo14/config

# Adresse statique dans le réseau interne 10.0.3.0/24
cat > /var/lib/lxc/devodoo14/rootfs/etc/systemd/network/eth0.network <<'EOF'
[Match]
Name=eth0

[Network]
Address=10.0.3.150/24
Gateway=10.0.3.1
DNS=192.168.96.2
EOF

lxc-stop -n devodoo14 && lxc-start -n devodoo14

# Activer le NAT sortant pour le réseau des conteneurs
firewall-cmd --permanent --add-masquerade

# Publier Odoo : 192.168.96.139:8069 -> 10.0.3.150:8069
firewall-cmd --permanent \
  --add-forward-port=port=8069:proto=tcp:toport=8069:toaddr=10.0.3.150

firewall-cmd --reload
```

**Compromis assumé** : les conteneurs des trois nœuds restent isolés les
uns des autres. Acceptable pour des instances Odoo indépendantes,
rédhibitoire pour un cluster.

---

## 8. Aide-mémoire des vérifications

```bash
# --- Côté hôte ---
lsblk                              # partitionnement et espace non alloué
df -h /                            # espace libre sur la racine
vgs ; lvs                          # état LVM
nmcli con show --active            # connexions réseau actives
bridge link show                   # quelles interfaces sur quel bridge
ip -br a show br0                  # adresse portée par le bridge
ip r | grep default                # route par défaut
systemctl status lxc-net           # dnsmasq du bridge interne

# --- Côté conteneur ---
lxc-ls -f                          # état + IP de tous les conteneurs
lxc-info -n devodoo14 -iH          # IP seule, exploitable en script
lxc-attach -n devodoo14 -- ip -br a
lxc-attach -n devodoo14 -- networkctl status eth0
lxc-attach -n devodoo14 -- ip neigh          # table ARP (FAILED = pas de réponse)
lxc-attach -n devodoo14 -- systemctl is-system-running
lxc-attach -n devodoo14 -- systemctl --failed

# --- Sur les 3 nœuds ---
ansible gluster_servers -k -m command -a "lxc-ls -f"
ansible gluster_servers -k -m command -a "lxc-attach -n devodoo14 -- ip -br a"
```

---

## 9. Pièges rencontrés

| Symptôme | Cause réelle |
|---|---|
| `lxc-create` : `No space left on device` | Racine à 4 Go saturée, disque de 20 Go partiellement partitionné |
| `cat /var/log/lxc/lxc-test1.log` : fichier absent | Le log s'appelle `test1.log`, pas `lxc-test1.log` |
| `/etc/network/interfaces` inexistant dans le conteneur | Image bullseye sans `ifupdown`, utilise systemd-networkd |
| `eth0` UP mais sans IPv4 | Aucun fichier `.network` ne correspond à l'interface |
| Config modifiée mais veth toujours sur l'ancien bridge | `lxc-stop -r` reboote l'invité sans recréer le veth |
| ARP émis sans réponse | Filtrage MAC du vSwitch de l'hyperviseur |

---

## 10. Suite

1. Débloquer le filtrage MAC côté VMware (§7) ou acter le repli NAT
2. Valider `.139` de bout en bout : `ping 192.168.96.150` depuis un poste du LAN
3. Répliquer sur `.140` et `.141`
4. Installer Odoo 14 + PostgreSQL dans les conteneurs
5. Prévoir la persistance des données : `/var/lib/postgresql` sur volume GlusterFS
