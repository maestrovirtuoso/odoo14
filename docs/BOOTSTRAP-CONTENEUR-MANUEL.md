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
