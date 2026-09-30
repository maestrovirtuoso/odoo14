# HAProxy dans ce projet

Comment HAProxy fonctionne ici, en clair : ce qu'il fait, ce qu'il ne fait pas,
et où lire sa configuration réelle.

---

## 1. Ce que HAProxy fait dans ce projet

Avant lui, chaque utilisateur visait une adresse fixe (`.151`, `.152` ou `.153`).
Si ce nœud tombait, il fallait changer d'URL à la main — trois instances, mais
aucune tolérance à la panne du point de vue de l'utilisateur.

HAProxy donne une **adresse unique**, la VIP `192.168.96.160`, et choisit pour
chaque requête **vers quelle instance Odoo la faire suivre**. Il ne fait que ça :
router. Ce qui décide **quel hôte porte la VIP** est un autre programme,
`keepalived`, expliqué en §7.

```
navigateur → VIP 192.168.96.160:80
                  │
             HAProxy      ← choisit le backend
                  │
        ┌─────────┼─────────┐
      odoo1     odoo2     odoo3
      .151      .152      .153
```

HAProxy tourne sur les **trois** hôtes Rocky (`.128`, `.129`, `.140`), pas sur un
seul : un répartiteur unique serait le point de panne qu'on cherchait à
supprimer. À un instant donné, un seul de ces trois HAProxy reçoit du trafic —
celui de l'hôte qui porte la VIP.

Fichiers du projet :

| Fichier | Rôle |
|---|---|
| [roles/odoo_lb/templates/haproxy.cfg.j2](../roles/odoo_lb/templates/haproxy.cfg.j2) | le modèle de configuration |
| [roles/odoo_lb/tasks/main.yaml](../roles/odoo_lb/tasks/main.yaml) | installation, réglages système, dépôt du fichier |
| [roles/odoo_lb/tasks/verif.yaml](../roles/odoo_lb/tasks/verif.yaml) | vérifie que ça marche réellement |
| [group_vars/lb_hosts/vars.yml](../group_vars/lb_hosts/vars.yml) | VIP, port, identifiants des statistiques |
| [playbooks/ansi_repartiteur.yaml](../playbooks/ansi_repartiteur.yaml) | orchestration complète |

---

## 2. La configuration réellement déployée

Ce que `haproxy -c -f /etc/haproxy/haproxy.cfg` valide et charge aujourd'hui sur
les trois hôtes — lu directement sur `.129` :

```haproxy
global
    log         /dev/log local0
    maxconn     2000
    daemon
    stats socket /var/lib/haproxy/stats mode 660 level admin

defaults
    mode        http
    log         global
    option      httplog
    option      forwardfor
    option      redispatch
    retries     3
    timeout connect 5s
    timeout client  120s
    timeout server  120s

frontend odoo_front
    bind 192.168.96.160:80

    acl est_stats       path_beg /haproxy-stats
    acl est_longpolling path_beg /longpolling

    use_backend stats_back       if est_stats
    use_backend odoo_longpolling if est_longpolling
    default_backend odoo_http

backend odoo_http
    balance roundrobin
    cookie SRV insert indirect nocache
    option httpchk GET /web/login
    http-check expect status 200
    server odoo1 192.168.96.151:8069 check cookie odoo1
    server odoo2 192.168.96.152:8069 check cookie odoo2
    server odoo3 192.168.96.153:8069 check cookie odoo3

backend odoo_longpolling
    balance roundrobin
    cookie SRV insert indirect nocache
    server odoo1 192.168.96.151:8072 check cookie odoo1
    server odoo2 192.168.96.152:8072 check cookie odoo2
    server odoo3 192.168.96.153:8072 check cookie odoo3

backend stats_back
    stats enable
    stats uri /haproxy-stats
    stats refresh 5s
    stats auth admin:prosys-lab
```

Ce fichier n'est **jamais écrit à la main** : le dépôt écrit son modèle
Jinja2, jamais sa sortie. Toucher `/etc/haproxy/haproxy.cfg` directement sur une
machine serait effacé au prochain déploiement.

Aucune IP n'y est écrite en dur par le dépôt : le modèle boucle sur
`groups['odoo_containers']` et lit `hostvars[h].ansible_host`. Une IP recopiée à
la main finit toujours par diverger, et un backend qui vise la mauvaise machine
**ne se voit pas** — il répond, juste pas à qui on croit.

---

## 3. Les quatre blocs, un par un

### `global` — réglages du processus HAProxy lui-même

`maxconn 2000` plafonne les connexions simultanées. `stats socket
/var/lib/haproxy/stats` ouvre un canal d'administration local : c'est par lui
que `tasks/verif.yaml` interroge l'état réel des serveurs (`echo "show stat" |
socat stdio /var/lib/haproxy/stats`), et par lui aussi qu'on peut sortir un
nœud de rotation sans toucher au fichier de configuration :

```bash
echo "set server odoo_http/odoo1 state maint" | socat stdio /var/lib/haproxy/stats
```

### `defaults` — réglages hérités par tous les `frontend`/`backend`

- **`option forwardfor`** pose l'en-tête `X-Forwarded-For`. Indispensable ici :
  `odoo.conf` a `proxy_mode = True`, donc Odoo **fait confiance** à cet en-tête
  pour connaître l'IP réelle du visiteur. Sans lui, tout le trafic semblerait
  venir de HAProxy.
- **`option redispatch`** : si le serveur désigné par le cookie de session est
  tombé, renvoyer la requête ailleurs plutôt que d'échouer. C'est ce qui rend
  une panne de nœud invisible pour l'utilisateur — à condition que les sessions
  soient partagées (§6), sinon il serait simplement déconnecté sur l'autre nœud.
- **`timeout client` / `timeout server` à 120 s**, et non les 50 s par défaut de
  HAProxy : le longpolling d'Odoo maintient une connexion ouverte près d'une
  minute en attendant un évènement. Un délai plus court la couperait en boucle,
  et les notifications ne fonctionneraient jamais.

### `frontend odoo_front` — ce qui écoute sur la VIP

`bind 192.168.96.160:80` : HAProxy écoute sur une adresse que l'hôte ne porte
**pas toujours** — voir §7 pour pourquoi ça marche quand même. Trois routes,
décidées par le **chemin** de l'URL :

| Chemin | Backend |
|---|---|
| `/haproxy-stats*` | `stats_back` |
| `/longpolling*` | `odoo_longpolling` |
| tout le reste | `odoo_http` |

### `backend odoo_http` / `backend odoo_longpolling` — vers quelle instance

Deux backends distincts, **pas un seul avec deux ports par serveur** : Odoo
n'ouvre le port 8072 (longpolling) que si `workers > 0`. Router `/longpolling`
vers 8069 par erreur donnerait une interface parfaitement fonctionnelle **sans
aucune notification** — une panne muette, difficile à imputer parce que rien
n'échoue visiblement à l'écran.

`balance roundrobin` : les requêtes sans cookie tournent entre les trois
serveurs dans l'ordre. Observé en direct (six requêtes, sans cookie) :

```
requete 1 -> odoo3     requete 4 -> odoo3
requete 2 -> odoo1     requete 5 -> odoo1
requete 3 -> odoo2     requete 6 -> odoo2
```

---

## 4. Le contrôle de santé : `option httpchk`

```haproxy
option httpchk GET /web/login
http-check expect status 200
```

HAProxy envoie une vraie requête HTTP `GET /web/login` à chaque serveur,
régulièrement, et attend un `200`. Un serveur qui ne répond pas ce code exact
est marqué `DOWN` et sort de la rotation **sans intervention humaine**.

Le choix de la page compte : `/web/login` traverse la pile complète — Odoo,
son connecteur PostgreSQL, le rendu des templates QWeb. Un simple `TCP connect`
aurait dit « le port écoute », pas « Odoo répond correctement ». C'est
exactement cette différence qui a servi de diagnostic le 30/09/2026 : le
backend `odoo_longpolling` (contrôlé par un TCP simple) restait UP pendant que
`odoo_http` (contrôlé par `/web/login`) passait DOWN sur les trois nœuds — HAProxy
avait raison, Odoo renvoyait une erreur 500 sur cette page précise pendant
qu'un module mal désinstallé restait en base (voir
[ARCHITECTURE.md §13ter](ARCHITECTURE.md)).

**Lire l'état réel**, à tout moment, sans rien couper :

```bash
ansible-playbook playbooks/ansi_repartiteur.yaml --tags verif
```

ou directement dans un navigateur : `http://192.168.96.160/haproxy-stats`.

---

## 5. Rester sur le même nœud : le cookie `SRV`

```haproxy
cookie SRV insert indirect nocache
...
server odoo1 192.168.96.151:8069 check cookie odoo1
```

À la première requête sans cookie, HAProxy choisit un serveur (par
`roundrobin`) et **pose** un cookie nommé `SRV` valant le nom de ce serveur
(`odoo1`, `odoo2` ou `odoo3`). Tant que ce cookie revient, HAProxy renvoie
systématiquement vers le même nœud.

- **`insert`** : c'est HAProxy qui crée le cookie, Odoo n'en sait rien.
- **`indirect`** : le cookie n'est **jamais transmis** à Odoo — HAProxy le
  retire avant de faire suivre la requête, et l'ajoute à la réponse. Odoo ne
  voit jamais passer `SRV`.
- **`nocache`** : ajoute `Cache-Control: private` pour qu'un intermédiaire
  (proxy, CDN) ne mette pas en cache une réponse qui contient ce cookie.

Observé en gardant le cookie sur quatre requêtes :

```
requete 1 -> odoo3     requete 3 -> odoo3
requete 2 -> odoo3     requete 4 -> odoo3
```

**Pourquoi coller un utilisateur à un nœud alors que le but est la
répartition ?** Parce qu'Odoo garde en mémoire, côté serveur, des objets liés à
la session (le cache ORM notamment) — changer de nœud à chaque requête serait
plus lent, pas plus robuste. Le collage n'est qu'une préférence : `option
redispatch` (§3) l'annule dès que le nœud collé ne répond plus.

---

## 6. Pourquoi HAProxy seul ne suffisait pas : les sessions

Odoo 14 stocke ses sessions HTTP dans des **fichiers**, un par session,
`data_dir/sessions`. Tant qu'elles restent locales à chaque conteneur, un
utilisateur renvoyé par HAProxy vers un autre nœud (parce que le premier est
tombé, ou par simple répartition) y est **déconnecté** : sa session n'existe pas
là-bas, malgré le cookie `SRV`.

Le rôle [odoo_sessions](../roles/odoo_sessions) résout ça **avant** que HAProxy
ne soit posé — l'ordre est contraignant dans
[ansi_repartiteur.yaml](../playbooks/ansi_repartiteur.yaml). Le volume GlusterFS
étant monté sur le `data_dir` entier des conteneurs, `data_dir/sessions` s'y
trouve déjà par construction : les trois instances partagent le même
répertoire de sessions, sans bind ni montage additionnel.

C'est ce qui a été vérifié en pratique : sortir `odoo1` de la rotation pendant
qu'un utilisateur y était connecté, et constater qu'il reste connecté, servi
par un autre nœud.

---

## 7. HAProxy et keepalived : qui fait quoi

HAProxy **route** les requêtes. Il ne décide pas quelle machine reçoit le
trafic des utilisateurs — c'est `keepalived`, un programme distinct, qui fait
**voyager la VIP** vers l'hôte vivant de plus haute priorité (protocole VRRP).
Détail complet dans
[ARCHITECTURE.md §13bis](ARCHITECTURE.md#13bis-le-répartiteur-de-charge) et le
modèle [keepalived.conf.j2](../roles/odoo_lb/templates/keepalived.conf.j2).

Les deux tournent **ensemble**, sur les mêmes trois hôtes : keepalived décide
qui reçoit le trafic, HAProxy décide vers quel Odoo le faire suivre une fois
qu'il est arrivé.

### Le réglage sans lequel HAProxy ne démarre pas sur deux hôtes sur trois

```haproxy
bind 192.168.96.160:80
```

Par défaut, Linux refuse qu'un processus écoute sur une adresse que la machine
ne porte pas. Or seul le maître keepalived porte `192.168.96.160` à un instant
donné — les deux hôtes de secours ne la portent pas.

```bash
sysctl net.ipv4.ip_nonlocal_bind=1
```

Posé par [tasks/main.yaml](../roles/odoo_lb/tasks/main.yaml), ce réglage
autorise HAProxy à se lier à une adresse absente. **Sans lui, HAProxy ne
démarre tout simplement pas** sur les hôtes de secours — et ça ne se voit qu'au
moment où ils devraient prendre le relais, c'est-à-dire pendant une panne.

### Le réglage sans lequel les backends restent DOWN sans raison visible

SELinux confine HAProxy à une liste fixe de ports « http » — 8069 et 8072 n'en
font pas partie par défaut. Sans le booléen suivant, **tous** les backends
apparaissent DOWN alors qu'Odoo répond parfaitement en direct, et le journal de
HAProxy ne dit rien d'utile — la trace est dans l'audit SELinux.

```bash
setsebool -P haproxy_connect_any 1
```

Posé automatiquement, seulement si SELinux est actif (`getenforce`).

---

## 8. Commandes utiles

```bash
# Tout vérifier d'un coup, sans rien couper
ansible-playbook playbooks/ansi_repartiteur.yaml --tags verif

# L'état des backends, lu depuis la socket d'administration
ansible lb_hosts -m shell -a \
  'echo "show stat" | socat stdio /var/lib/haproxy/stats | cut -d, -f1,2,18'

# Qui porte la VIP en ce moment
ansible lb_hosts -m shell -a 'ip -o addr show to 192.168.96.160'

# Sortir un nœud de rotation sans y toucher (test, maintenance)
ansible lb_hosts -m shell -a \
  'echo "set server odoo_http/odoo1 state maint" | socat stdio /var/lib/haproxy/stats'
# ... et le remettre :
ansible lb_hosts -m shell -a \
  'echo "set server odoo_http/odoo1 state ready" | socat stdio /var/lib/haproxy/stats'

# Éprouver la bascule pour de vrai (coupe brièvement le service)
ansible-playbook playbooks/ansi_repartiteur.yaml --tags bascule
```

Dans un navigateur : `http://192.168.96.160/haproxy-stats` (identifiants dans
`group_vars/lb_hosts/vars.yml` — `admin` / `vault_lb_stats_password`, ou
`prosys-lab` par défaut en l'absence de vault).
