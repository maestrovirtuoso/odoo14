# Répartition de charge Odoo avec nginx

Ce document explique le fichier [`nginx/odoo-repartition.conf`](../nginx/odoo-repartition.conf)
et décrit sa mise en place sur la **machine proxy**. Ce nginx se place devant
les trois instances Odoo : les utilisateurs n'ont plus qu'**une seule
adresse** à retenir, et la panne d'une instance ne les oblige plus à changer
d'URL.

> **État au 22/10/2026 : proposition, rien n'est déployé.**
> Le proxy existe déjà, **hors conteneur**. Il sera ensuite remplacé par une
> **VM**. Le fichier nginx est le même dans les deux cas ; la section 5
> explique le passage à la VM.

Dans ce document, **`IP_DU_PROXY`** désigne l'adresse de la machine proxy
actuelle, et **`IP_DE_LA_VM`** celle de la future VM. Remplacez-les par les
vraies adresses avant de lancer les commandes.

Les adresses des trois instances sont celles du fichier nginx :
`192.168.96.151`, `.152` et `.153`, ports 8069 et 8072.

Documents voisins :
[ARCHITECTURE-ACTUELLE.md](ARCHITECTURE-ACTUELLE.md),
[ARCHITECTURE.md](ARCHITECTURE.md).

---

## 1. Ce qui change

```
AVANT                                    APRÈS

 utilisateurs                             utilisateurs
  │     │     │                                │
  │     │     │                        http://IP_DU_PROXY
  │     │     │                                │
  │     │     │                     ┌──────────┴──────────┐
  │     │     │                     │ nginx               │
  │     │     │                     │ machine proxy  :80  │
  │     │     │                     │ (puis la VM)        │
  │     │     │                     └──┬───────┬───────┬──┘
  │     │     │                        │       │       │   /            → 8069
  │     │     │                        │       │       │   /longpolling → 8072
  ▼     ▼     ▼                        ▼       ▼       ▼
 Odoo  Odoo  Odoo                    Odoo    Odoo    Odoo
 .151  .152  .153                    .151    .152    .153
                                       │       │       │
                                       └───────┼───────┘
                                    PostgreSQL + GlusterFS
```

| | Avant | Après |
|---|---|---|
| Adresse utilisateur | 3 adresses, une par instance | une seule, celle du proxy |
| Instance en panne | ses utilisateurs doivent changer d'URL | nginx les envoie sur une autre instance |
| Répartition | manuelle, selon l'URL donnée à chacun | automatique, par adresse IP du client |
| Accès direct à `:8069` | ouvert à tous | réservé au proxy (§ 4.5) |

---

## 2. Ce que la machine proxy doit permettre

Ces conditions valent pour le proxy actuel et pour la future VM.

1. **Joindre les trois instances sur 8069 et 8072.** Le test du § 4.1 le
   vérifie avant toute installation.
2. **Ne pas être un des hôtes LXC qui portent un conteneur Odoo.** Les
   conteneurs sont raccordés en ipvlan à la carte de leur hôte
   (`lxc_net_type=ipvlan` dans [inventory.yaml](../inventory.yaml)). Avec ce
   mode, un hôte ne peut pas joindre son propre conteneur. Un nginx installé
   sur un de ces hôtes perdrait l'instance qu'il héberge. Elle ne serait pas
   écartée une fois pour toutes : nginx la réessaierait toutes les 30 s, et
   un utilisateur attendrait 5 s à chaque nouvel essai.
3. **Avoir une IP fixe.** Les trois conteneurs Odoo n'accepteront plus que
   cette adresse sur 8069 et 8072 (§ 4.5).
4. **Avoir le port 80 libre, ou déjà tenu par nginx.** Si un autre logiciel
   (Apache, HAProxy…) occupe déjà le port 80, ce fichier ne peut pas s'y
   ajouter tel quel. Voir le § 4.1.

**Conseil : donnez un nom DNS au proxy** (par exemple `odoo.<votre-domaine>`)
et communiquez ce nom aux utilisateurs plutôt que l'IP. Au passage à la VM,
il suffira de faire pointer le nom vers la nouvelle machine : personne n'aura
à changer d'URL, et `web.base.url` (§ 4.4) restera valable.

---

## 3. Les choix du fichier, un par un

### 3.1 `hash $remote_addr consistent` — chaque utilisateur reste sur le même nœud

Un utilisateur est toujours envoyé sur la **même instance**, choisie à partir
de son adresse IP.

- **Pourquoi pas `ip_hash`**, la solution habituelle ? `ip_hash` ne tient
  compte que des **trois premiers octets** de l'adresse. Tous les postes d'un
  même réseau `/24` arriveraient **tous sur la même instance** : aucune
  répartition.
- **`consistent`** : quand une instance tombe, seuls **ses** utilisateurs
  sont déplacés. Les autres ne bougent pas.
- **Pourquoi garder chaque utilisateur sur le même nœud ?** Odoo 14 stocke
  chaque session dans un fichier sous `/var/lib/odoo/sessions`. Ce répertoire
  est sur le volume GlusterFS, donc **partagé** entre les trois instances,
  *à condition que le montage soit en place* (§ 4.3). Si c'est le cas, rester
  sur le même nœud sert seulement à éviter des allers-retours réseau. Sinon,
  c'est ce qui empêche l'utilisateur d'être déconnecté à chaque requête.

Limite : si plusieurs utilisateurs passent par un même NAT, ils arrivent
avec la même IP et tombent tous sur la même instance.

### 3.2 Deux `upstream` : 8069 et 8072

| Chemin | Port | Rôle |
|---|---|---|
| `/` | 8069 | interface web, RPC |
| `/longpolling` | 8072 | bus de notifications : messagerie, compteurs, alertes |

Si tout est envoyé sur 8069, l'interface fonctionne mais **plus aucune
notification n'arrive**, sans message d'erreur. Odoo n'ouvre 8072 que lorsque
`workers > 0`, ce qui est le cas ici (`odoo_workers: 2`).

### 3.3 Les délais

| Directive | Valeur | Raison |
|---|---|---|
| `proxy_connect_timeout` | **5 s** | Quand un hôte est tombé, rien ne répond. C'est ce délai qui fixe combien de temps l'utilisateur attend avant que nginx passe au nœud suivant. L'exemple officiel d'Odoo met 720 s, soit 12 minutes d'attente. |
| `proxy_read_timeout` | 720 s | Le longpolling garde une requête ouverte près d'une minute ; un rapport PDF ou un import peut durer plusieurs minutes. |
| `proxy_send_timeout` | 720 s | Même raison, dans l'autre sens. |

### 3.4 La bascule : `proxy_next_upstream error timeout`

Quand la connexion à une instance échoue ou expire, nginx envoie la requête
à l'instance suivante.

Nginx ne renvoie **jamais** ailleurs un `POST` déjà transmis à une instance.
Odoo n'a donc aucun risque de traiter deux fois la même création
d'enregistrement. En revanche, un `POST` dont la connexion a été **refusée**
(instance arrêtée) est bien renvoyé ailleurs, puisque rien n'a été traité.

`max_fails=3 fail_timeout=30s` : après 3 échecs en 30 s, l'instance est
écartée pendant 30 s, puis nginx la réessaie.

Ce contrôle de santé est **passif** : nginx ne détecte une instance en panne
qu'au moment où une vraie requête échoue. Un Odoo qui répond `500` (registre
cassé) reste donc dans le pool, car il répond. Le contrôle actif
(`GET /web/login` toutes les quelques secondes) est réservé à NGINX Plus,
la version payante.

### 3.5 Les en-têtes et `proxy_mode`

Derrière nginx, Odoo voit toutes les requêtes arriver du proxy. Pour qu'il
connaisse la vraie IP du client et la vraie URL, nginx ajoute des en-têtes
`X-Forwarded-*`, et Odoo doit être réglé pour les lire (`proxy_mode = True`,
§ 4.4).

- **`X-Forwarded-Host` est obligatoire.** Odoo 14 n'utilise les en-têtes de
  proxy que si celui-ci est présent. Sans lui, `proxy_mode = True` n'a aucun
  effet, et rien ne le signale.
- **`X-Forwarded-For $remote_addr`** remplace toute valeur envoyée par le
  navigateur. Un client ne peut donc pas se faire passer pour une autre IP.

### 3.6 `client_max_body_size 128m`

Par défaut, nginx refuse toute requête de plus de **1 Mo** avec une erreur
`413 Request Entity Too Large`. Sans cette ligne, la plupart des pièces
jointes échoueraient.

### 3.7 `add_header X-Odoo-Noeud`

Cet en-tête indique quelle instance a répondu (dans le navigateur : F12,
onglet Réseau). Il sert à **observer** la répartition et la bascule pendant
les tests. Il révèle les IP internes : à retirer en production.

---

## 4. Mise en place sur le proxy actuel

L'ordre compte. Chaque étape est vérifiée avant de passer à la suivante, et
l'accès direct à 8069 n'est fermé qu'**en dernier**, une fois nginx validé.

### 4.1 Vérifier le proxy avant d'installer

Sur la machine proxy :

```bash
# 1. Les trois instances repondent-elles DEPUIS le proxy ?
for ip in 151 152 153; do
  for port in 8069 8072; do
    curl -s -m 5 -o /dev/null -w "192.168.96.$ip:$port : %{http_code}\n" \
      http://192.168.96.$ip:$port/web/login
  done
done

# 2. Qui tient deja le port 80 ?
ss -ltnp | grep ':80 '

# 3. Si c'est nginx : un site revendique-t-il deja default_server ?
nginx -T 2>/dev/null | grep -nE 'listen|server_name'
```

| Résultat | Que faire |
|---|---|
| `200` pour les six lignes | continuer |
| `000` pour une seule instance | le proxy est sans doute l'hôte LXC de cette instance (§ 2, point 2) : passer directement à la VM (§ 5) |
| `000` partout | routage ou pare-feu entre le proxy et le réseau des conteneurs |
| port 80 tenu par autre chose que nginx | choisir un autre port dans le fichier (`listen 8080`, et `$http_host` au lieu de `$host`), ou libérer le 80 |

### 4.2 Installer le fichier

Depuis le poste de contrôle :

```bash
scp nginx/odoo-repartition.conf root@IP_DU_PROXY:/etc/nginx/sites-available/odoo
```

Sur le proxy (si nginx n'y est pas encore : `apt-get install -y nginx`) :

```bash
ln -sf /etc/nginx/sites-available/odoo /etc/nginx/sites-enabled/odoo
nginx -t
systemctl reload nginx
```

Si `nginx -t` répond **`a duplicate default server for 0.0.0.0:80`**, un
autre site revendique déjà `default_server` :

- s'il s'agit du site `default` de Debian (page « Welcome to nginx! ») :
  `rm /etc/nginx/sites-enabled/default` ;
- s'il s'agit d'un vrai site déjà servi par le proxy : **ne pas le
  toucher**. Retirer `default_server` dans le fichier Odoo et remplacer
  `server_name _;` par le nom DNS ou l'IP que tapent les utilisateurs.

### 4.3 Vérifier que les sessions sont partagées

Dans **chacun** des trois conteneurs Odoo :

```bash
findmnt /var/lib/odoo
```

| Résultat | Conséquence |
|---|---|
| `fuse.glusterfs` | sessions partagées : en cas de panne, l'utilisateur change d'instance **sans être déconnecté** |
| rien | sessions locales : la répartition fonctionne, mais en cas de panne, l'utilisateur déplacé doit **se reconnecter** |

### 4.4 Passer Odoo en `proxy_mode = True`

À faire **uniquement maintenant**, une fois nginx en place. Le commentaire
de [`roles/ansi_odoo/odoo14/templates/odoo.conf.j2`](../roles/ansi_odoo/odoo14/templates/odoo.conf.j2)
explique pourquoi : avec `True`, Odoo fait confiance aux en-têtes
`X-Forwarded-*` de **n'importe quel client**. Il ne faut donc l'activer
qu'avec un proxy devant, et avec l'accès direct fermé (§ 4.5).

**Méthode durable** (recommandée) : dans le modèle, remplacer
`proxy_mode = False` par `proxy_mode = True`, adapter le commentaire, puis
rejouer le déploiement :

```bash
ansible-playbook playbooks/ansi_odoo.yaml
```

**Méthode rapide**, pour tester : dans chaque conteneur Odoo, lancer la
commande ci-dessous. Elle sera **écrasée** au prochain passage du playbook
si le modèle n'est pas modifié.

```bash
sed -i 's/^proxy_mode.*/proxy_mode = True/' /etc/odoo/odoo.conf && systemctl restart odoo
```

Ensuite, se connecter en administrateur **par le proxy** et vérifier, dans
*Paramètres → Technique → Paramètres système*, que `web.base.url` vaut
l'adresse du proxy (`http://<nom DNS>` ou `http://IP_DU_PROXY`). Odoo utilise
cette adresse dans les liens de ses e-mails et pour générer les rapports PDF.

### 4.5 Fermer l'accès direct à 8069 / 8072

Sans ce filtrage, un utilisateur peut contourner nginx et, puisque
`proxy_mode = True`, envoyer de faux en-têtes `X-Forwarded-*`. Les journaux
d'Odoo afficheraient alors une IP inventée.

Dans **chacun** des trois conteneurs Odoo, vérifier d'abord qu'aucune règle
n'existe déjà (`nft list ruleset` doit être vide), puis :

```bash
apt-get install -y nftables
cat > /etc/nftables.conf <<'EOF'
#!/usr/sbin/nft -f
flush ruleset

# Machines autorisees a joindre Odoo. Au passage a la VM, ajouter son IP
# ICI, puis retirer l'ancienne une fois la bascule terminee (section 5).
define PROXYS = { IP_DU_PROXY }

table inet odoo_filtre {
    chain input {
        type filter hook input priority 0; policy accept;
        # Le conteneur vers lui-meme : le "wait_for :8069" de ansi_odoo.yaml
        # s'execute DANS le conteneur, vers sa propre IP.
        iif "lo" accept
        tcp dport { 8069, 8072 } ip saddr $PROXYS accept
        tcp dport { 8069, 8072 } drop
    }
}
EOF
nft -c -f /etc/nftables.conf && systemctl enable --now nftables
```

`nft -c` vérifie le fichier sans l'appliquer : si `IP_DU_PROXY` n'a pas été
remplacé, il échoue ici et rien n'est chargé.

SSH (22) n'est pas concerné : Ansible continue de fonctionner normalement.

### 4.6 Tester

Depuis un poste utilisateur :

```bash
# 1. nginx repond et indique le noeud qui a servi la requete
curl -sI http://IP_DU_PROXY/web/login | grep -Ei '^HTTP|X-Odoo-Noeud'

# 2. L'acces direct est ferme (apres 4.5) : doit expirer
curl -m 5 -sI http://192.168.96.151:8069/web/login || echo "ferme : OK"
```

**Test de bascule :**

1. Se connecter par le proxy, ouvrir F12 → Réseau, et noter la valeur de
   `X-Odoo-Noeud`, par exemple `192.168.96.152:8069`.
2. Arrêter cette instance-là. Sur l'hôte LXC qui la porte :
   `lxc-attach -n devodoo14 -- systemctl stop odoo`.
3. Recharger la page. `X-Odoo-Noeud` doit désigner une autre instance, et
   l'utilisateur doit rester connecté si les sessions sont partagées (§ 4.3).
4. Envoyer un message dans *Discussion* depuis un autre compte : il doit
   arriver sans recharger la page, ce qui prouve que `/longpolling` passe.
5. Redémarrer l'instance :
   `lxc-attach -n devodoo14 -- systemctl start odoo`.

---

## 5. Passage du proxy à la VM

Le fichier nginx **ne change pas** : il ne contient aucune adresse propre au
proxy. Seules changent l'IP autorisée dans les conteneurs Odoo et l'adresse
que tapent les utilisateurs.

1. **Créer la VM depuis la plateforme de virtualisation**, et non à
   l'intérieur d'un des hôtes LXC. Le réseau du lab rejette les adresses MAC
   qu'il ne connaît pas (voir l'ipvlan dans [inventory.yaml](../inventory.yaml)) :
   une VM imbriquée dans un hôte n'obtiendrait aucune réponse.
2. Sur la VM : `apt-get install -y nginx`, puis § 4.1 et § 4.2 à
   l'identique. Le test du § 4.1 doit donner `200` partout.
3. Dans les trois conteneurs Odoo, **autoriser les deux machines** le temps
   de la bascule, puis recharger :
   ```bash
   sed -i 's/^define PROXYS = .*/define PROXYS = { IP_DU_PROXY, IP_DE_LA_VM }/' /etc/nftables.conf
   nft -c -f /etc/nftables.conf && systemctl reload nftables
   ```
4. Tester la VM directement : `curl -sI http://IP_DE_LA_VM/web/login`.
5. **Basculer les utilisateurs** : faire pointer le nom DNS vers
   `IP_DE_LA_VM`. Sans nom DNS, communiquer la nouvelle adresse aux
   utilisateurs et mettre à jour `web.base.url` (§ 4.4).
6. Une fois plus aucune requête dans `/var/log/nginx/odoo.access.log` sur
   l'ancien proxy, **retirer son IP** des conteneurs :
   ```bash
   sed -i 's/^define PROXYS = .*/define PROXYS = { IP_DE_LA_VM }/' /etc/nftables.conf
   nft -c -f /etc/nftables.conf && systemctl reload nftables
   ```
7. Retirer le site Odoo de l'ancien proxy :
   `rm /etc/nginx/sites-enabled/odoo && systemctl reload nginx`.

---

## 6. Dépannage

| Symptôme | Cause probable | Correction |
|---|---|---|
| `nginx -t` : `duplicate default server` | un autre site porte déjà `default_server` | § 4.2 |
| Page « Welcome to nginx! » | site `default` de Debian prioritaire | `rm /etc/nginx/sites-enabled/default`, recharger |
| `413 Request Entity Too Large` | pièce jointe > `client_max_body_size` | augmenter la valeur, recharger |
| `502 Bad Gateway` partout | aucune instance joignable depuis le proxy | relancer le test du § 4.1 ; vérifier que l'IP du proxy figure dans `PROXYS` (§ 4.5) |
| Lenteur de 5 s par moments, toujours sur la même instance | le proxy ne joint pas cette instance | § 2, point 2 ; test du § 4.1 |
| Interface OK, aucune notification | `/longpolling` n'atteint pas 8072 | vérifier `workers > 0` et la ligne `:8072` du test du § 4.1 |
| Déconnecté à chaque changement d'instance | sessions non partagées | § 4.3 |
| Journaux Odoo : toutes les IP sont celles du proxy | `proxy_mode` encore à `False`, ou `X-Forwarded-Host` absent | § 4.4 ; vérifier les `proxy_set_header` |
| Liens des e-mails en `:8069` | `web.base.url` pas à jour | § 4.4, dernier paragraphe |

---

## 7. Limites, à connaître

1. **Le proxy est un point unique de panne.** S'il tombe, plus personne
   n'accède à Odoo, d'autant que l'accès direct est fermé (§ 4.5). Pour le
   rouvrir en urgence : `nft flush ruleset` dans les conteneurs Odoo. La
   solution durable : deux proxys et une IP virtuelle portée par
   **keepalived**. C'est ce que faisait le couple HAProxy + keepalived posé
   le 30/09/2026 et retiré le 15/10/2026. Son code reste lisible dans
   l'historique Git :
   `git show dd487f7^:roles/odoo_lb/templates/haproxy.cfg.j2`.
2. **Les tâches planifiées restent sur `odoo1` seul**
   (`max_cron_threads` = 1 sur le primaire, 0 ailleurs). Si `odoo1` tombe,
   nginx continue de servir l'interface, mais **les crons s'arrêtent**.
3. **HTTP en clair.** Les mots de passe circulent en clair sur le réseau,
   comme aujourd'hui sur 8069. Pour passer en HTTPS, il faut un certificat,
   un bloc `listen 443 ssl` et une redirection 80 → 443.
4. **Les IP des instances sont recopiées à la main** dans le fichier nginx.
   Si elles changent, il faut le modifier. Une fois le principe validé, il
   gagnerait à devenir un modèle Jinja2 dans un rôle Ansible, généré depuis
   `groups['odoo_containers']`, comme le faisait l'ancien `haproxy.cfg.j2`.
5. **Contrôle de santé passif seulement** (§ 3.4).
6. Le message de fin de `roles/ansi_syncro/odoo_migration` demande de tester sur
   `http://<odoo1>:8069`. Une fois le § 4.5 appliqué, ces vérifications se
   font par le proxy.
