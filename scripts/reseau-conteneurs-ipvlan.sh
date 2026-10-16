l#!/bin/bash
# ===========================================================================
# Reseau des 6 conteneurs LXC en IPVLAN, depuis le poste de controle.
#
# Pour chaque hote (SSH root, par cle) :
#   1. arrete le conteneur ;
#   2. reecrit lxc.net.0.* dans /var/lib/lxc/<ct>/config (ipvlan, mode l2,
#      IP et passerelle) et retire macvlan, hwaddr, hook ipvlan, lxc.net.1 ;
#   3. ecrit /etc/systemd/network/eth0.network dans le conteneur (IP statique) ;
#   4. redemarre le conteneur et verifie : MAC identique a celle de l'hote,
#      passerelle et 8.8.8.8 joignables ;
#   5. teste le conteneur depuis CE poste (ping + port 22).
#
# Equivalent du role roles/lxc_lan, sans Ansible. Rejouable.
# Reseau jetant les MAC inconnues -> ipvlan (MAC de l'hote). Voir
# docs/BOOTSTRAP-CONTENEUR-MANUEL.md, section 1a.
#
# Usage :
#   ./scripts/reseau-conteneurs-ipvlan.sh                 # les 6 hotes
#   ./scripts/reseau-conteneurs-ipvlan.sh 192.168.36.21   # un ou plusieurs hotes
#   DRY_RUN=1 ./scripts/reseau-conteneurs-ipvlan.sh       # affiche sans rien changer
#
# Prerequis : cle SSH du poste de controle autorisee pour root sur les hotes.
# ===========================================================================
set -u

# hote:conteneur:carte:ip_conteneur:prefixe:passerelle:dns1,dns2
# (valeurs de host_vars/<ip>.yml)
TARGETS=(
  "192.168.36.21:devodoo14:enp5s0:192.168.36.151:24:192.168.36.254:172.24.10.17,172.24.10.18"
  "192.168.36.22:devodoo14:enp5s0:192.168.36.152:24:192.168.36.254:172.24.10.17,172.24.10.18"
  "192.168.36.23:devodoo14:enp5s0:192.168.36.153:24:192.168.36.254:172.24.10.17,172.24.10.18"
  "192.168.33.21:devpg15:enp1s0:192.168.33.156:24:192.168.33.254:192.168.36.1,192.168.36.2"
  "192.168.33.22:devpg15:enp1s0:192.168.33.157:24:192.168.33.254:192.168.36.1,192.168.36.2"
  "192.168.33.23:devpg15:enp1s0:192.168.33.158:24:192.168.33.254:192.168.36.1,192.168.36.2"
)

DRY_RUN="${DRY_RUN:-0}"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)

# Script execute SUR l'hote : $1=ct $2=nic $3=ip $4=prefixe $5=passerelle $6=dns $7=dry
REMOTE=$(cat <<'EOS'
CT=$1; NIC=$2; IP=$3; PFX=$4; GW=$5; DNS=$6; DRY=$7
CFG=/var/lib/lxc/$CT/config
NETD=/var/lib/lxc/$CT/rootfs/etc/systemd/network

[ -f "$CFG" ] || { echo "ECHEC: $CFG absent (conteneur non cree ? voir ansi2-snapchot.yaml)"; exit 20; }
ip link show "$NIC" >/dev/null 2>&1 || { echo "ECHEC: carte $NIC absente sur l'hote"; exit 21; }

if [ "$DRY" = "1" ]; then
  echo "[dry-run] lxc.net.0 -> ipvlan l2 sur $NIC, $IP/$PFX via $GW, dns $DNS"
  grep -E '^lxc\.net' "$CFG"
  exit 0
fi

cp -a "$CFG" "$CFG.avant-ipvlan.$(date +%Y%m%d%H%M%S)"
lxc-stop -n "$CT" -t 30 2>/dev/null || lxc-stop -n "$CT" -k 2>/dev/null

sed -i -E '/^lxc\.net\.0\./d; /^lxc\.net\.1\./d; /^lxc\.hook\.pre-start.*ipvlan/d' "$CFG"
cat >> "$CFG" <<EOF
lxc.net.0.type = ipvlan
lxc.net.0.link = $NIC
lxc.net.0.name = eth0
lxc.net.0.flags = up
lxc.net.0.ipvlan.mode = l2
lxc.net.0.ipv4.address = $IP/$PFX
lxc.net.0.ipv4.gateway = $GW
EOF

mkdir -p "$NETD"
rm -f "$NETD/eth1.network"
{
  printf '[Match]\nName=eth0\n\n[Network]\nAddress=%s/%s\nGateway=%s\n' "$IP" "$PFX" "$GW"
  for d in ${DNS//,/ }; do printf 'DNS=%s\n' "$d"; done
} > "$NETD/eth0.network"

if ! lxc-start -n "$CT" -d; then
  echo "ECHEC: lxc-start. Config lue :"; grep -E '^lxc\.net' "$CFG"
  lxc-start -n "$CT" -F -l ERROR -o /dev/stdout 2>&1 | head -20
  exit 22
fi

# attendre l'etat RUNNING puis l'IP
for i in $(seq 1 30); do
  [ "$(lxc-info -n "$CT" -sH 2>/dev/null)" = "RUNNING" ] && break; sleep 1
done
for i in $(seq 1 30); do
  lxc-attach -n "$CT" -- ip -4 addr show eth0 2>/dev/null | grep -q "$IP" && break; sleep 1
done

HMAC=$(cat /sys/class/net/$NIC/address)
CMAC=$(lxc-attach -n "$CT" -- cat /sys/class/net/eth0/address 2>/dev/null)
echo "MAC hote $NIC=$HMAC  conteneur eth0=$CMAC"
[ "$HMAC" = "$CMAC" ] && echo "OK  ipvlan actif (MAC de l'hote)" || echo "KO  MAC differente : le conteneur n'est pas en ipvlan"
lxc-attach -n "$CT" -- ip -4 addr show eth0 | grep -q "$IP" && echo "OK  IP $IP presente" || echo "KO  IP $IP absente"
lxc-attach -n "$CT" -- ping -c 2 -W 3 "$GW" >/dev/null 2>&1 && echo "OK  passerelle $GW" || echo "KO  passerelle $GW injoignable"
lxc-attach -n "$CT" -- ping -c 2 -W 3 8.8.8.8 >/dev/null 2>&1 && echo "OK  Internet (8.8.8.8)" || echo "KO  Internet injoignable"
EOS
)

wanted=("$@")
selected() {
  [ ${#wanted[@]} -eq 0 ] && return 0
  local w; for w in "${wanted[@]}"; do [ "$w" = "$1" ] && return 0; done
  return 1
}

ok=(); ko=()
for t in "${TARGETS[@]}"; do
  IFS=: read -r H CT NIC IP PFX GW DNS <<< "$t"
  selected "$H" || continue
  echo
  echo "=== $H : $CT ($IP/$PFX, carte $NIC) ==="

  if ! ssh "${SSH_OPTS[@]}" "root@$H" bash -s -- "$CT" "$NIC" "$IP" "$PFX" "$GW" "$DNS" "$DRY_RUN" <<< "$REMOTE"; then
    echo "ECHEC sur $H"; ko+=("$H"); continue
  fi

  if [ "$DRY_RUN" != "1" ]; then
    # Vu du poste de controle : c'est de la que Ansible atteindra le conteneur.
    if ping -c 2 -W 3 "$IP" >/dev/null 2>&1; then echo "OK  ping $IP depuis le poste"; else echo "KO  ping $IP depuis le poste"; ko+=("$H"); continue; fi
    if timeout 5 bash -c "exec 3<>/dev/tcp/$IP/22" 2>/dev/null; then echo "OK  port 22 de $IP ouvert"; else echo "--  port 22 de $IP ferme (normal tant que openssh-server n'est pas installe)"; fi
  fi
  ok+=("$H")
done

echo
echo "=== Resume ==="
echo "Traites sans erreur : ${ok[*]:-aucun}"
echo "En echec            : ${ko[*]:-aucun}"
[ ${#ko[@]} -eq 0 ]
