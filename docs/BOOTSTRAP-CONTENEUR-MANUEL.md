# Amorçage manuel d'un conteneur (Debian 12)

Équivalent de la tâche « Installer openssh-server + clé du contrôleur » de
`roles/lxc_lan/tasks/main.yaml`, à faire commande par commande quand on veut
voir où ça bloque.

Entrer dans le conteneur depuis l'hôte LXC :

```bash
lxc-attach -n devodoo14
```

Les commandes suivantes se tapent dans le conteneur.

## 1. Vérifier le réseau

```bash
ip -4 addr show eth0
ip -4 r
cat /etc/resolv.conf
getent hosts deb.debian.org
ping -c 2 8.8.8.8
```

Si `getent` ne répond rien : problème de DNS. Si `ping 8.8.8.8` échoue :
problème de route ou de passerelle. Inutile d'aller plus loin tant que ça ne
marche pas.

## 1b. Si le conteneur n'a pas Internet : sortie NAT par l'hôte

Symptôme : `ping` de la passerelle (`ip neigh` affiche `INCOMPLETE`) ou de
`8.8.8.8` échoue depuis le conteneur, alors que l'hôte y arrive. Le réseau
filtre la MAC/IP du macvlan. On donne alors au conteneur une 2e interface
(`eth1`) sur `lxcbr0`, masquerade derrière l'IP de l'hôte. `eth0` garde son IP
LAN. Équivalent manuel de `lxc_egress_nat` (roles/lxc_lan).

**Sur l'hôte LXC** (Debian 12, hors du conteneur) :

```bash
sysctl -w net.ipv4.ip_forward=1
echo 'net.ipv4.ip_forward = 1' > /etc/sysctl.d/99-lxc-forward.conf

systemctl enable --now lxc-net
ip -4 addr show lxcbr0          # doit porter 10.0.3.1/24

# lxc-net pose lui-meme le masquerade de lxcbr0 ; verifier :
iptables -t nat -S POSTROUTING | grep 10.0.3.0
# Si la politique FORWARD est DROP (pare-feu actif), autoriser lxcbr0 :
iptables -S FORWARD | head -1
```

Arrêter le conteneur et modifier sa config :

```bash
lxc-stop -n devodoo14

# eth0 ne porte plus la passerelle LAN
sed -i '/^lxc\.net\.0\.ipv4\.gateway/d' /var/lib/lxc/devodoo14/config

cat >> /var/lib/lxc/devodoo14/config <<'EOF'
lxc.net.1.type = veth
lxc.net.1.link = lxcbr0
lxc.net.1.name = eth1
lxc.net.1.flags = up
lxc.net.1.ipv4.address = 10.0.3.10/24
lxc.net.1.ipv4.gateway = 10.0.3.1
EOF
```

Dans le conteneur, la passerelle doit aussi disparaître d'`eth0` et être posée
sur `eth1` côté systemd-networkd (fichiers du rootfs, vus depuis l'hôte) :

```bash
R=/var/lib/lxc/devodoo14/rootfs/etc/systemd/network
sed -i '/^Gateway=/d' $R/eth0.network

cat > $R/eth1.network <<'EOF'
[Match]
Name=eth1

[Network]
Address=10.0.3.10/24
Gateway=10.0.3.1
DNS=172.24.10.17
DNS=172.24.10.18
EOF

lxc-start -n devodoo14 -d
```

Remplacer `172.24.10.17/18` par les DNS de `ct_dns_servers` de l'hôte (voir
`host_vars/<ip>.yml`). Vérifier dans le conteneur :

```bash
lxc-attach -n devodoo14
ip -4 r                         # default via 10.0.3.1 dev eth1
ping -c 2 8.8.8.8
getent hosts deb.debian.org
```

Pour revenir en arrière : supprimer les lignes `lxc.net.1.*`, retirer
`eth1.network`, remettre `Gateway=` dans `eth0.network` et
`lxc.net.0.ipv4.gateway`, puis `lxc-stop` / `lxc-start`.

## 2. Dépôts apt

```bash
export DEBIAN_FRONTEND=noninteractive
rm -f /etc/apt/apt.conf.d/99-ignore-valid-until

cat > /etc/apt/sources.list <<'EOF'
deb http://deb.debian.org/debian bookworm main
deb http://deb.debian.org/debian bookworm-updates main
deb http://security.debian.org/debian-security bookworm-security main
EOF

cat > /etc/apt/apt.conf.d/99-no-languages <<'EOF'
Acquire::Languages "none";
Acquire::ForceIPv4 "true";
Acquire::http::Timeout "20";
Acquire::Retries "0";
DPkg::Lock::Timeout "60";
EOF
```

Cache apt (optionnel, remplacer l'adresse) :

```bash
echo 'Acquire::http::Proxy "http://192.168.33.1:3142";' > /etc/apt/apt.conf.d/01proxy
```

## 3. Installer les paquets

```bash
apt-get update
apt-get install -y openssh-server python3 python3-apt
```

En cas d'échec de l'installation :

```bash
apt-get -y --fix-broken install
dpkg --configure -a
apt-get update && apt-get install -y openssh-server python3 python3-apt
```

Vérifier :

```bash
dpkg -s openssh-server python3 python3-apt | grep -E '^(Package|Status)'
```

## 4. Clé SSH du poste de contrôle

Remplacer par la clé publique du poste de contrôle (`cat ~/.ssh/id_rsa.pub`) :

```bash
install -d -m 700 /root/.ssh
touch /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
echo "ssh-ed25519 AAAA... utilisateur@controleur" >> /root/.ssh/authorized_keys
```

## 5. Démarrer SSH

```bash
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
ssh-keygen -A
systemctl enable ssh
systemctl restart ssh
systemctl status ssh --no-pager -l
ss -ltn | grep ':22'
/usr/bin/python3 --version
```

`systemctl status` doit afficher `active (running)` et `ss` une ligne sur
`:22`.

## 6. Tester depuis le poste de contrôle

```bash
ssh root@<ip_du_conteneur> true && echo SSH_OK
```

Quand tout répond, relancer le playbook : la tâche d'amorçage verra les
paquets déjà installés et passera sans rien télécharger.
