# Guide de lecture des schémas Odoo 14

Ce README explique chaque vue des dossiers de schémas du projet : ce qu’elle représente, comment suivre ses flèches et ce qu’il faut en retenir.

La série de référence est celle du **3 novembre 2026**, dans [schemas-patroni-odoo14](schemas-patroni-odoo14/README.md). La variable `pg_ha_enabled: true` est déclarée dans [les variables communes](../group_vars/all/vars.yml). Les dessins décrivent la configuration du dépôt ; ils ne prouvent pas que les services sont déployés ou qu’une bascule a été testée sur les serveurs.

## Comprendre les composants

| Composant | Fonction dans les schémas |
| --- | --- |
| Hôte | Machine qui héberge les conteneurs LXC. |
| LXC | Conteneur Linux dans lequel s’exécute une application ou un service de données. |
| Odoo | Application utilisée dans le navigateur ; elle conserve ses données structurées dans PostgreSQL. |
| PostgreSQL | Base de données : un primaire accepte les écritures, les répliques suivent ses modifications. |
| WAL | Journaux PostgreSQL utilisés pour transmettre les modifications aux répliques. |
| Patroni | Agent présent sur chaque nœud PostgreSQL ; il pilote son serveur local et coordonne les changements de rôle. |
| etcd | Registre distribué utilisé pour la coordination et le verrou du leader ; deux membres sur trois forment la majorité. |
| HAProxy | Point d’accès SQL qui dirige une connexion vers le primaire identifié par Patroni. |
| GlusterFS | Stockage partagé du filestore Odoo, notamment les pièces jointes, et des sessions. |
| venv | Environnement Python propre à chaque conteneur Odoo, contenant ses dépendances. |
| Ansible | Outil qui applique la configuration décrite dans les playbooks et les rôles du dépôt. |

## Comment lire les dessins

Commencer par les contours : ils séparent les réseaux, les hôtes et les conteneurs. Suivre ensuite les flèches et leurs libellés : une connexion SQL, une réplication WAL et une sonde de supervision n’ont pas le même rôle.

Dans la série récente, les traits pleins représentent les échanges applicatifs, SQL, WAL ou stockage. Les pointillés représentent le pilotage, les sondes ou les étapes d’un scénario. Dans les anciennes vues LXC, les pointillés représentent aussi les réponses : consulter la légende du dossier concerné.

Les formats PNG servent à consulter les dessins, les SVG à les agrandir ou les imprimer, et les fichiers draw.io à les modifier. Un document à plusieurs onglets regroupe des vues également disponibles séparément : ce sont les mêmes schémas.

## Les 14 schémas de référence : Patroni et Odoo 14

[Catalogue des formats](schemas-patroni-odoo14/README.md) · [Document draw.io à 14 onglets](schemas-patroni-odoo14/dossier-patroni-odoo14.drawio)

### 01 — Architecture globale : Odoo et PostgreSQL HA

[Voir le schéma](schemas-patroni-odoo14/01-architecture-globale-ha.svg)

Cette vue rassemble les trois instances Odoo, les trois nœuds PostgreSQL et le stockage partagé. Les applications se trouvent sur le réseau `192.168.36.0/24`, les bases sur `192.168.33.0/24`.

Suivre le parcours utilisateur → Odoo → HAProxy → PostgreSQL primaire, puis le lien Odoo → GlusterFS pour les fichiers. Les trois Odoo utilisent une base commune ; les répliques PostgreSQL suivent le primaire. La disponibilité SQL dépend aussi du réseau, du stockage et des accès web, que Patroni ne rend pas automatiquement redondants.

### 02 — Déploiement : hôtes Debian et conteneurs LXC

[Voir le schéma](schemas-patroni-odoo14/02-deploiement-hotes-lxc.svg)

Cette vue explique où s’exécute chaque service. Les contours distinguent les hôtes des conteneurs Odoo et PostgreSQL qu’ils hébergent ; les adresses identifient les points d’accès sur les deux réseaux.

Lire chaque bloc de l’extérieur vers l’intérieur : hôte, conteneur, puis services. Un redémarrage de service, un arrêt de conteneur et une panne d’hôte ont des conséquences différentes. Le placement représenté ne suffit pas à établir l’indépendance des machines physiques sous-jacentes.

### 03 — Patroni orchestre le rôle de chaque PostgreSQL

[Voir le schéma](schemas-patroni-odoo14/03-orchestration-patroni.svg)

Chaque agent Patroni pilote son PostgreSQL local et consulte etcd pour coordonner le rôle de primaire. HAProxy interroge les API Patroni afin de sélectionner sa destination SQL.

Séparer les flèches de pilotage des flèches de données : PostgreSQL réplique lui-même les WAL vers les répliques. Les données SQL ne transitent pas par Patroni ou etcd.

### 04 — Connexion Odoo : du venv au primaire courant

[Voir le schéma](schemas-patroni-odoo14/04-connexion-odoo-haproxy.svg)

Le processus Odoo utilise les bibliothèques PostgreSQL de son environnement Python pour joindre les endpoints `192.168.33.161,192.168.33.162,192.168.33.163` sur le port `5000`. Le HAProxy choisi dirige ensuite la connexion vers le primaire sur `5432`.

Suivre Odoo → libpq → HAProxy → primaire. Le paramètre `PGTARGETSESSIONATTRS=read-write` vise une session autorisant les écritures. Le TLS PostgreSQL traverse HAProxy jusqu’au serveur SQL. Après une bascule, une connexion interrompue doit être rouverte ; sa transaction en cours ne migre pas.

### 05 — Réplication : un primaire et deux répliques

[Voir le schéma](schemas-patroni-odoo14/05-replication-postgresql.svg)

Le primaire reçoit les écritures et produit des WAL. Les deux répliques reçoivent ces journaux et les rejouent pour maintenir une copie des données PostgreSQL.

Les flèches WAL partent du primaire vers les répliques. La réplication est asynchrone : une écriture confirmée peut ne pas encore être présente sur une réplique lors d’une panne. Le quorum etcd ne confirme pas la réception des WAL. Le filestore suit un autre chemin, via GlusterFS.

### 06 — Bascule automatique après panne du primaire

[Voir le schéma](schemas-patroni-odoo14/06-bascule-automatique.svg)

Le scénario enchaîne la perte du primaire, la coordination Patroni/etcd, la promotion d’une réplique éligible et la mise à jour du routage HAProxy. Les clients peuvent ensuite établir de nouvelles connexions vers le nouveau primaire.

Lire les étapes dans l’ordre. La promotion dépend notamment du quorum et de l’état des répliques. Le choix d’odoodb2 dans le dessin est un exemple ; il ne fixe pas le résultat réel de l’élection. Les temporisations configurées ne constituent pas un délai de rétablissement mesuré.

### 07 — Quorum etcd et partitions réseau

[Voir le schéma](schemas-patroni-odoo14/07-quorum-et-partitions.svg)

Cette vue montre ce qui arrive lorsque des membres ne peuvent plus communiquer. Avec trois membres etcd, la majorité nécessite deux membres capables de communiquer entre eux.

Comparer le groupe majoritaire au membre isolé : un serveur encore allumé n’a pas nécessairement l’autorité pour conserver ou acquérir le rôle de primaire. La perte de majorité empêche la coordination normale. Le watchdog étant désactivé dans les LXC, le dessin ne représente pas une garantie de coupure matérielle d’un ancien primaire.

### 08 — Bascule planifiée pour maintenance

[Voir le schéma](schemas-patroni-odoo14/08-bascule-planifiee.svg)

Cette vue décrit un changement volontaire de primaire avant une maintenance. On contrôle l’état du cluster et de la réplique cible, on demande la bascule, puis on vérifie les nouveaux rôles et le retour des connexions applicatives.

La différence avec la vue 06 est le déclenchement préparé par un administrateur. Une bascule planifiée peut tout de même interrompre des sessions : les applications doivent pouvoir se reconnecter.

### 09 — Réintégrer un ancien primaire sous Patroni

[Voir le schéma](schemas-patroni-odoo14/09-retour-ancien-primaire.svg)

Après une bascule, l’ancien primaire peut avoir des données divergentes. Il doit rejoindre le cluster sous le contrôle de Patroni et suivre le primaire courant.

Le parcours présente `pg_rewind` lorsque ses préconditions sont réunies. En cas d’échec ou de divergence non récupérable par ce mécanisme, une réinitialisation doit être décidée explicitement ; elle remplace les données locales de la réplique. Le retour de la machine ne lui rend pas automatiquement son ancien rôle.

### 10 — Transition du cluster initial vers Patroni

[Voir le schéma](schemas-patroni-odoo14/10-transition-vers-patroni.svg)

Cette vue explique le passage historique d’un primaire fixé dans la configuration à une gestion des rôles par Patroni, avec etcd pour la coordination et HAProxy pour l’accès SQL.

Comparer le chemin SQL avant et après la transition. Dans la configuration récente, `pg_ha_enabled` est déjà déclaré à `true` : la vue explique l’évolution du projet. Les groupes d’inventaire décrivant le placement initial ne constituent pas une mesure du primaire courant après une bascule.

### 11 — Flux réseau, certificats et surfaces de gestion

[Voir le schéma](schemas-patroni-odoo14/11-flux-reseau-et-tls.svg)

Cette vue détaille les communications nécessaires entre applications, proxies, bases et services de coordination. Lire chaque flèche en identifiant sa source, sa destination, son port et sa protection.

| Port | Usage représenté |
| --- | --- |
| 8069 / 8072 | Accès web Odoo et bus. |
| 5000 | Odoo vers les endpoints SQL HAProxy. |
| 5432 | HAProxy vers PostgreSQL et réplication PostgreSQL. |
| 8008 | API HTTP Patroni, notamment la sonde `/primary`. |
| 2379 / 2380 | Accès HTTPS à etcd / échanges HTTPS entre membres. |
| 22 | Administration SSH par Ansible. |

Le TLS SQL et le TLS etcd ont des configurations distinctes. Une sonde HTTP Patroni ne transporte pas les requêtes SQL. Les flux GlusterFS doivent aussi atteindre les serveurs de briques annoncés par le volume.

### 12 — Sauvegarder puis restaurer Odoo et ses données

[Voir le schéma](schemas-patroni-odoo14/12-sauvegarde-et-restauration.svg)

La sauvegarde associe un dump PostgreSQL et une archive du filestore, conservés dans `/srv/sauvegardes`. Les sessions sont exclues de l’archive. La restauration doit remettre ensemble une base et des fichiers cohérents, puis permettre de vérifier le fonctionnement d’Odoo et l’accès aux pièces jointes.

Le timer est déclaré à 02:15, avec un délai aléatoire allant jusqu’à dix minutes et une rétention de trente jours. Le chemin de sauvegarde SQL via HAProxy reste à compléter pour les certificats clients et les variables `PGSSL*`, puis à valider. Le schéma décrit un parcours ; le dépôt ne fournit pas une restauration HA automatisée et validée. La réplication ne remplace pas cette sauvegarde.

### 13 — Installer Odoo 14 sur Debian dans les LXC

[Voir le schéma](schemas-patroni-odoo14/13-installation-odoo14-debian-lxc.svg)

Cette vue suit la préparation des conteneurs Debian 12, l’installation de Python 3.8.20 et du venv, la mise à disposition du code Odoo, le montage du stockage, la configuration et l’initialisation conditionnelle de la base.

Les flèches donnent un ordre d’opérations. Odoo1 initialise la base lorsque nécessaire, pendant que les services Odoo sont arrêtés, avant leur démarrage commun. Le GlusterFS de cette série est monté directement dans chaque conteneur sur `/var/lib/odoo`.

### 14 — Pile d’exécution : LXC, venv et service Odoo

[Voir le schéma](schemas-patroni-odoo14/14-pile-execution-odoo14-venv.svg)

Cette coupe montre comment Odoo démarre à l’intérieur d’un conteneur. Python 3.8.20 est installé dans `/opt/python3.8` ; le venv local se trouve dans `/opt/odoo14-venv`. Le paquet Debian fournit le code dans `/usr/lib/python3/dist-packages/odoo`, accessible au venv par `odoo-deb.pth`.

Systemd lance `/opt/odoo14-venv/bin/python /usr/bin/odoo` avec la configuration `/etc/odoo/odoo.conf`. Le Python système 3.11 continue de servir au système et à Ansible. Le venv appartient à chaque conteneur, tandis que les fichiers Odoo sont partagés sur GlusterFS. Le cron porté par odoo1 reste indépendant du rôle de primaire PostgreSQL.

## Les anciens schémas réseau LXC — 18 octobre 2026

[Catalogue et légende](schemas-lxc/README.md)

### Raccordement IPVLAN L2

[Voir le schéma](schemas-lxc/01-raccordement-ipvlan.svg). Il relie la carte réseau de l’hôte à l’interface du conteneur en IPVLAN L2. Le conteneur dispose de son IP et partage la MAC de l’interface parente. Le chemin dessiné ne passe pas par un NAT sur l’hôte. La communication directe entre l’hôte et son propre conteneur via cette interface parente n’est pas fournie par ce montage.

### Accès utilisateur à Odoo

[Voir le schéma](schemas-lxc/02-acces-utilisateur-odoo.svg). Suivre le navigateur jusqu’à l’IP du conteneur sur `8069`, puis le trajet retour en pointillés. Cette vue explique l’accès web direct ; elle ne représente pas un répartiteur HTTP commun aux trois applications.

### Flux Odoo vers PostgreSQL

[Voir le schéma](schemas-lxc/03-flux-odoo-postgresql.svg). La requête part du réseau applicatif, traverse le routage externe et atteint PostgreSQL sur `5432`. Le trajet retour est aussi nécessaire à la connexion. Cette ancienne vue montre l’accès direct au serveur SQL ; la série récente ajoute les endpoints HAProxy sur `5000`.

## Les anciens schémas GlusterFS — 18 octobre 2026

[Catalogue et légende](schemas-glusterfs/README.md). Ces dessins utilisent le montage sur les hôtes suivi d’un bind LXC ; le playbook récent monte directement le volume dans les conteneurs Odoo.

### Volume partagé entre les trois Odoo

[Voir le schéma](schemas-glusterfs/01-volume-partage-trois-odoo.svg). Les trois applications accèdent au volume externe `sre`, annoncé par `192.168.36.8`. Elles retrouvent ainsi les mêmes fichiers et sessions. Le serveur qui décrit le volume n’est pas nécessairement l’unique serveur transportant ses données : les clients contactent les serveurs de briques annoncés.

### Montage sur l’hôte et bind LXC

[Voir le schéma](schemas-glusterfs/02-montage-hote-et-bind-lxc.svg). Lire les couches dans l’ordre : volume externe → montage hôte `/mnt/odoo` → bind dans le conteneur `/var/lib/odoo` → accès Odoo. Le bind expose le montage existant dans le conteneur ; il ne crée pas une copie des fichiers. Ce mécanisme appartient à l’ancienne configuration.

### GlusterFS et sauvegarde

[Voir le schéma](schemas-glusterfs/03-glusterfs-et-sauvegarde.svg). L’hôte `192.168.36.21` lit le montage et conserve l’archive avec le dump SQL dans `/srv/sauvegardes`. Les sessions sont exclues. Les flèches de sauvegarde montrent la production d’archives distinctes des données en service : un stockage partagé ne suffit pas à protéger contre une suppression ou une corruption.

## Les anciens schémas d’architecture et de HA — 25 octobre 2026

[Catalogue et légende](schemas-architecture-ha/README.md). À la date de cette série, `pg_ha_enabled=false` : les vues Patroni représentent alors une option. Cette valeur historique diffère de la configuration récente.

### Architecture technique actuelle de cette édition

[Voir le schéma](schemas-architecture-ha/01-architecture-actuelle.svg). Cette vue réunit les hôtes, les conteneurs, les réseaux, les flux numérotés et les dépendances de stockage et de sauvegarde. Odoo contacte directement odoodb1 sur `5432`. La lire pour comprendre l’état antérieur et les échanges entre couches ; les mentions Rocky et montage hôte/bind sont celles de cette édition.

### Réplication et bascule manuelle

[Voir le schéma](schemas-architecture-ha/02-replication-et-bascule-manuelle.svg). Le primaire envoie les WAL aux deux répliques. En cas de panne, un administrateur doit choisir et promouvoir une réplique, puis adapter les accès. La réplication prépare des copies utilisables, mais n’automatise pas à elle seule la reprise du service.

### Option HA Patroni / etcd / HAProxy

[Voir le schéma](schemas-architecture-ha/03-option-ha-patroni-etcd-haproxy.svg). Cette vue ajoute les agents Patroni, le quorum etcd et les proxies SQL à l’architecture précédente. Elle explique comment dissocier le point d’accès applicatif du rôle courant des bases. Elle représente une option à sa date de création, désormais déclarée active dans les variables récentes.

### Bascule HA et quorum

[Voir le schéma](schemas-architecture-ha/04-bascule-ha-et-quorum.svg). Le scénario illustre une panne du primaire et la promotion d’une réplique avec une majorité etcd. Le choix du nouveau primaire est illustratif ; les conditions d’éligibilité et le retard de réplication restent déterminants. Comparer cette vue aux vues récentes 06 et 07 pour approfondir les étapes et les partitions réseau.

## Vue historique dédiée à l’orchestration Patroni — 25 octobre 2026

[Voir le schéma](schemas-patroni/orchestration-patroni-haproxy-postgresql.svg) · [Explications du dossier](schemas-patroni/README.md)

Cette vue rassemble sur une seule page les responsabilités PostgreSQL, Patroni, etcd et HAProxy. Les traits SQL vont d’Odoo au proxy, puis au primaire. Les WAL passent directement entre serveurs PostgreSQL. Les sondes HAProxy interrogent Patroni, tandis que Patroni utilise etcd pour le verrou et la coordination.

Le regroupement des agents est logique : il existe un agent par nœud et plusieurs proxies. Ce dessin présente la même famille de mécanismes que la vue récente 03, avec le statut historique « HA désactivée » de son édition.

## Schémas d’origine et documents regroupés

| Fichier ou document | Explication |
| --- | --- |
| [Architecture initiale](architecture-actuelle.svg), également disponible en [Mermaid](architecture-actuelle.mmd) et [PNG](architecture-actuelle.png) | Vue d’ensemble antérieure : trois Odoo, primaire PostgreSQL fixe, deux répliques, GlusterFS et sauvegarde. La mention de bascule manuelle correspond à cette version. |
| [Réseau LXC d’origine, draw.io](architecture-reseau-lxc.drawio) et [aperçu conservé dans le rapport](rapport-projet-odoo14/architecture-reseau-lxc-historique.png) | Document réseau historique à lire avec les hypothèses de son édition ; utiliser les vues LXC détaillées pour distinguer raccordement, accès web et accès SQL. |
| [Installation Odoo, draw.io à deux onglets](schemas-patroni-odoo14/installation-odoo14-debian-lxc.drawio) | Regroupe les vues récentes 13 et 14 : étapes d’installation puis pile d’exécution. |
| [Architecture expert, draw.io](schemas-architecture-ha/architecture-actuelle-expert.drawio) | Version autonome de la première vue du dossier historique architecture/HA. |
| [Rapport du projet](rapport-projet-odoo14/README.md) | Présentation du rapport et de ses figures. Les images du dossier `apercus` sont des rendus de pages du rapport. |

## Ordre de lecture conseillé

Pour découvrir le projet : **01 → 02 → 04 → 13 → 14**. Pour comprendre la haute disponibilité : **03 → 05 → 06 → 07 → 08 → 09**. Pour préparer l’exploitation : **11 → 12**, puis **10** pour comprendre la transition historique.

Les sources et commandes de régénération figurent dans les README de chaque dossier. Pour vérifier une affirmation, partir de ces sources Ansible ; l’état réel du cluster doit être contrôlé séparément sur les serveurs.
