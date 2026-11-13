#!/usr/bin/env python3
"""
Simulation de charge : N utilisateurs connectés en même temps à Odoo 14.

Chaque utilisateur simulé se comporte comme un onglet de navigateur :
  - il se connecte (/web/session/authenticate), ouvre /web et charge les menus ;
  - il garde une attente ouverte sur le bus (/longpolling/poll), comme tout
    onglet Odoo ouvert ;
  - jusqu'à la fin du test, il enchaîne des actions courantes : ouvrir une
    liste, ouvrir une fiche, chercher, autocompléter un champ, regrouper. Entre
    deux actions, il fait une pause de réflexion (3 à 15 s par défaut).

Par défaut, le test ne fait QUE lire. --ecriture ajoute des créations et des
modifications de contacts (res.partner) nommés "[test charge] ...". Chaque
utilisateur supprime les siens à la fin du test.

Bibliothèque standard de Python 3.7 ou plus : rien à installer.

Où le lancer
------------
Depuis un poste qui n'est ni une instance Odoo ni le conteneur de
supervision, par exemple dev-sys-client1. Ce poste doit résoudre le nom du
site (voir /etc/hosts) et joindre le port visé.

Exemples
--------
Via nginx, 100 utilisateurs pendant 10 minutes, connectés en 100 s :

    export ODOO_MDP='mot de passe du compte'
    python3 simulation_charge_odoo.py --base prod --login test.charge \\
        --cible https://ha-odoo14.dev.guichetunique.cm --insecure

En direct sur les trois instances, sessions réparties à tour de rôle. Le
poste doit être autorisé par nftables sur odoo1..3 (PROXYS, § 4.5 de
docs/NGINX-REPARTITION-CHARGE.md) : la machine du proxy l'est déjà.

    python3 simulation_charge_odoo.py --base prod --login test.charge \\
        --cible http://192.168.36.161:8069 \\
        --cible http://192.168.36.162:8069 \\
        --cible http://192.168.36.163:8069

Répartition par nginx
---------------------
nginx choisit l'instance selon l'adresse du client (hash $remote_addr) : les
sessions lancées depuis UN poste arrivent toutes sur LE MÊME Odoo. Des
utilisateurs derrière une même adresse NAT vivent la même chose. Pour charger
les trois instances par nginx, lancer le script depuis plusieurs postes ; sinon
viser les instances en direct.

Comptes
-------
--login : un seul compte pour toutes les sessions (Odoo accepte plusieurs
sessions par compte). Le mot de passe est lu dans la variable ODOO_MDP, sinon
demandé au clavier. Utiliser un compte de test, pas admin.
--comptes FICHIER : une ligne "login;mot de passe" par compte. Les sessions se
répartissent sur ces comptes, à tour de rôle.

Résultats
---------
Un résumé toutes les 30 s, puis un tableau par action : nombre, erreurs, durée
moyenne, médiane, p95, maximum. La plage horaire du test est affichée pour la
retrouver dans Grafana. --csv enregistre chaque requête.
"""

import argparse
import collections
import csv
import getpass
import gzip
import http.client
import json
import math
import os
import random
import re
import ssl
import sys
import threading
import time
from datetime import datetime
from urllib.parse import urlsplit, urlunsplit

AGENT = "simulation-charge-odoo/1.0"
ACTION_BUS = "bus (longpolling)"
ERREURS_RESEAU = (OSError, http.client.HTTPException)
LETTRES = "abcdefghilmnoprstu"

# Types de champs affichés dans une vue liste.
TYPES_LISTE = ("char", "integer", "float", "monetary", "date", "datetime",
               "boolean", "selection", "many2one")
CHAMPS_TECHNIQUES = ("create_uid", "write_uid", "create_date", "write_date")
GROUPES_PREFERES = ("country_id", "state", "company_id", "user_id", "categ_id",
                    "type", "state_id")

Modele = collections.namedtuple(
    "Modele", "nom champs_liste champs_fiche champ_recherche champ_groupe")


class ErreurSimulation(Exception):
    """Requête en échec. Elle est déjà comptée dans les statistiques."""


# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------

class Client:
    """Une connexion HTTP persistante (keep-alive) vers une cible, comme un
    navigateur. Un objet par fil : http.client n'est pas partageable."""

    def __init__(self, url, contexte_ssl, delai):
        u = urlsplit(url)
        self.https = u.scheme == "https"
        self.hote = u.hostname
        self.port = u.port or (443 if self.https else 80)
        self.prefixe = u.path.rstrip("/")
        self.nom = u.netloc
        self.contexte_ssl = contexte_ssl
        self.delai = delai
        self.conn = None

    def fermer(self):
        if self.conn is not None:
            self.conn.close()
            self.conn = None

    def _ouvrir(self):
        if self.https:
            return http.client.HTTPSConnection(
                self.hote, self.port, timeout=self.delai,
                context=self.contexte_ssl)
        return http.client.HTTPConnection(self.hote, self.port,
                                          timeout=self.delai)

    def requete(self, methode, chemin, corps, entetes, rejouable):
        for essai in (1, 2):
            reutilisee = self.conn is not None and self.conn.sock is not None
            if self.conn is None:
                self.conn = self._ouvrir()
            try:
                self.conn.request(methode, self.prefixe + chemin, body=corps,
                                  headers=entetes)
                reponse = self.conn.getresponse()
                donnees = reponse.read()
            except (http.client.RemoteDisconnected, BrokenPipeError,
                    ConnectionResetError):
                # Connexion keep-alive fermée par le serveur pendant la
                # pause : une lecture est renvoyée une fois, pas une écriture.
                self.fermer()
                if essai == 1 and reutilisee and rejouable:
                    continue
                raise
            except Exception:
                self.fermer()
                raise
            if reponse.getheader("Content-Encoding") == "gzip":
                donnees = gzip.decompress(donnees)
            return reponse, donnees
        raise http.client.HTTPException("connexion perdue")


def url_bus(cible):
    """En direct, le bus est sur 8072 et non 8069 (workers > 0). Via nginx,
    /longpolling est routé par nginx : même adresse."""
    u = urlsplit(cible)
    if u.port == 8069:
        return urlunsplit((u.scheme, "%s:8072" % u.hostname, u.path, "", ""))
    return cible


# ---------------------------------------------------------------------------
# Statistiques
# ---------------------------------------------------------------------------

class Statistiques:
    def __init__(self):
        self.verrou = threading.Lock()
        # (horodatage, utilisateur, action, durée, erreur ou None, noeud)
        self.mesures = []
        self.connectes = 0

    def noter(self, utilisateur, action, duree, erreur=None, noeud=None):
        with self.verrou:
            self.mesures.append((time.time(), utilisateur, action, duree,
                                 erreur, noeud))

    def variation_connectes(self, delta):
        with self.verrou:
            self.connectes += delta

    def depuis(self, indice):
        with self.verrou:
            return self.mesures[indice:], len(self.mesures), self.connectes


def centile(valeurs_triees, p):
    if not valeurs_triees:
        return 0.0
    rang = max(0, math.ceil(p / 100.0 * len(valeurs_triees)) - 1)
    return valeurs_triees[rang]


def repartition(compteur):
    total = sum(compteur.values())
    if not total:
        return ""
    return ", ".join("%s %d %%" % (noeud, round(100.0 * n / total))
                     for noeud, n in compteur.most_common())


# ---------------------------------------------------------------------------
# Utilisateur simulé
# ---------------------------------------------------------------------------

class Utilisateur(threading.Thread):
    def __init__(self, numero, cible, compte, config, modeles, stats, arret):
        super().__init__(name="utilisateur-%d" % numero, daemon=True)
        self.numero = numero
        self.cible = cible
        self.login, self.mdp = compte
        self.config = config
        self.modeles = modeles
        self.stats = stats
        self.arret = arret
        self.client = Client(cible, config.contexte_ssl, config.delai)
        self.session_id = None
        self.contexte = {}
        self.connecte = False
        self.verrou = threading.Lock()
        self.vues_chargees = set()
        self.derniers_ids = {}
        self.crees = []
        self.compteur = 0
        self.fil_bus = None
        actions = [(self.ouvrir_liste, 35), (self.ouvrir_fiche, 30),
                   (self.rechercher, 15), (self.autocompleter, 10),
                   (self.regrouper, 10)]
        if config.ecriture:
            actions.append((self.creer_ou_modifier, 10))
        self.actions, self.poids = zip(*actions)

    # --- état -------------------------------------------------------------

    def _changer_etat(self, connecte):
        with self.verrou:
            if connecte == self.connecte:
                return
            self.connecte = connecte
        self.stats.variation_connectes(1 if connecte else -1)

    # --- requêtes ---------------------------------------------------------

    def _envoyer(self, action, methode, chemin, corps=None, client=None,
                 rejouable=True):
        client = client or self.client
        entetes = {"User-Agent": AGENT, "Accept-Encoding": "gzip"}
        if corps is not None:
            entetes["Content-Type"] = "application/json"
        if self.session_id:
            entetes["Cookie"] = "session_id=" + self.session_id
        debut = time.monotonic()
        try:
            reponse, donnees = client.requete(methode, chemin, corps, entetes,
                                              rejouable)
        except ERREURS_RESEAU as exc:
            self.stats.noter(self.numero, action, time.monotonic() - debut,
                             "%s: %s" % (type(exc).__name__, str(exc)[:100]),
                             client.nom)
            raise ErreurSimulation()
        duree = time.monotonic() - debut
        for cookie in reponse.msg.get_all("Set-Cookie") or []:
            trouve = re.match(r"\s*session_id=([^;]*)", cookie)
            if trouve:
                self.session_id = trouve.group(1)
        # En-tête ajouté par nginx (docs/NGINX-REPARTITION-CHARGE.md) ; à
        # défaut, l'adresse visée.
        noeud = reponse.getheader("X-Odoo-Noeud") or client.nom
        return reponse, donnees, duree, noeud

    def page(self, action, chemin):
        # Suit les redirections comme un navigateur (/web -> /web/, par
        # exemple). Seul un renvoi vers /web/login est une erreur : la
        # session n'est pas reconnue.
        duree_totale = 0.0
        for _ in range(5):
            reponse, donnees, duree, noeud = self._envoyer(action, "GET",
                                                           chemin)
            duree_totale += duree
            if reponse.status not in (301, 302, 303, 307, 308):
                break
            destination = urlsplit(reponse.getheader("Location") or "")
            if "/web/login" in destination.path or not destination.path:
                break
            chemin = destination.path + (
                "?" + destination.query if destination.query else "")
            if self.client.prefixe and chemin.startswith(self.client.prefixe):
                chemin = chemin[len(self.client.prefixe):]
        erreur = None
        if reponse.status in (301, 302, 303, 307, 308):
            erreur = "redirigé vers %s" % (reponse.getheader("Location") or "?")
            if "/web/login" in erreur:
                self._changer_etat(False)
        elif reponse.status >= 400:
            erreur = "HTTP %d" % reponse.status
        duree = duree_totale
        self.stats.noter(self.numero, action, duree, erreur, noeud)
        if erreur:
            raise ErreurSimulation()
        return donnees

    def rpc(self, action, chemin, params, client=None, rejouable=True):
        corps = json.dumps({"jsonrpc": "2.0", "method": "call",
                            "id": random.randint(1, 10 ** 9),
                            "params": params}).encode("utf-8")
        reponse, donnees, duree, noeud = self._envoyer(
            action, "POST", chemin, corps, client, rejouable)
        erreur, resultat = None, None
        if reponse.status != 200:
            erreur = "HTTP %d" % reponse.status
        else:
            try:
                message = json.loads(donnees.decode("utf-8"))
            except ValueError:
                erreur = "réponse illisible (pas du JSON)"
            else:
                if message.get("error"):
                    detail = message["error"].get("data") or {}
                    nom = (detail.get("name") or message["error"].get("message")
                           or "erreur")
                    erreur = "%s: %s" % (nom.rsplit(".", 1)[-1],
                                         str(detail.get("message", ""))[:100])
                    if "SessionExpired" in nom:
                        self._changer_etat(False)
                else:
                    resultat = message.get("result")
        self.stats.noter(self.numero, action, duree, erreur, noeud)
        if erreur:
            raise ErreurSimulation()
        return resultat

    def appeler(self, action, modele, methode, args=None, kwargs=None,
                rejouable=True):
        kw = dict(kwargs or {})
        kw["context"] = self.contexte
        return self.rpc(action,
                        "/web/dataset/call_kw/%s/%s" % (modele, methode),
                        {"model": modele, "method": methode,
                         "args": args or [], "kwargs": kw},
                        rejouable=rejouable)

    def lire_liste(self, action, modele, domaine, decalage):
        res = self.rpc(action, "/web/dataset/search_read", {
            "model": modele.nom, "fields": modele.champs_liste,
            "domain": domaine, "context": self.contexte,
            "offset": decalage, "limit": 80, "sort": ""})
        ids = [r["id"] for r in (res or {}).get("records", [])]
        if ids:
            self.derniers_ids[modele.nom] = ids

    # --- connexion --------------------------------------------------------

    def se_connecter(self):
        self.session_id = None
        self.vues_chargees.clear()
        res = self.rpc("connexion", "/web/session/authenticate", {
            "db": self.config.base, "login": self.login,
            "password": self.mdp})
        if not res or not res.get("uid"):
            self.stats.noter(self.numero, "connexion", 0.0,
                             "identifiants refusés", self.client.nom)
            raise ErreurSimulation()
        self.contexte = res.get("user_context") or {}
        self._changer_etat(True)
        # Ce que fait le navigateur juste après : la page, puis les menus.
        self.page("ouverture de /web", "/web")
        self.page("menus", "/web/webclient/load_menus/%d" % int(time.time()))
        if self.config.messagerie:
            self.rpc("messagerie (démarrage)", "/mail/init_messaging", {})

    # --- actions ----------------------------------------------------------

    def ouvrir_liste(self, modele=None):
        m = modele or random.choice(self.modeles)
        if m.nom not in self.vues_chargees:
            self.appeler("chargement des vues", m.nom, "load_views", kwargs={
                "views": [[False, "list"], [False, "form"], [False, "search"]],
                "options": {"toolbar": True, "load_filters": True}})
            self.vues_chargees.add(m.nom)
        self.lire_liste("liste", m, [], random.choice((0, 0, 0, 80)))

    def ouvrir_fiche(self):
        m = random.choice(self.modeles)
        if not self.derniers_ids.get(m.nom):
            self.ouvrir_liste(m)
        ids = self.derniers_ids.get(m.nom)
        if ids:
            self.appeler("fiche", m.nom, "read",
                         [[random.choice(ids)], m.champs_fiche])

    def rechercher(self):
        m = random.choice(self.modeles)
        domaine = []
        if m.champ_recherche:
            domaine = [[m.champ_recherche, "ilike",
                        "".join(random.choices(LETTRES, k=2))]]
        self.lire_liste("recherche", m, domaine, 0)

    def autocompleter(self):
        m = random.choice(self.modeles)
        self.appeler("autocomplétion", m.nom, "name_search", kwargs={
            "name": random.choice(LETTRES), "args": [],
            "operator": "ilike", "limit": 8})

    def regrouper(self):
        candidats = [m for m in self.modeles if m.champ_groupe]
        if not candidats:
            self.ouvrir_liste()
            return
        m = random.choice(candidats)
        self.appeler("regroupement", m.nom, "web_read_group", kwargs={
            "domain": [], "fields": [m.champ_groupe],
            "groupby": [m.champ_groupe], "lazy": True})

    def creer_ou_modifier(self):
        if self.crees and random.random() < 0.5:
            self.appeler("modification", "res.partner", "write",
                         [[random.choice(self.crees)],
                          {"phone": "+237 6%08d" % random.randint(0, 99999999)}],
                         rejouable=False)
            return
        self.compteur += 1
        nouvel_id = self.appeler(
            "création", "res.partner", "create",
            [{"name": "[test charge] utilisateur %d n°%d"
                      % (self.numero, self.compteur)}],
            rejouable=False)
        if isinstance(nouvel_id, int):
            self.crees.append(nouvel_id)

    def nettoyer(self):
        if not self.crees or not self.connecte:
            return
        try:
            self.appeler("suppression (nettoyage)", "res.partner", "unlink",
                         [self.crees], rejouable=False)
            self.crees = []
        except ErreurSimulation:
            pass

    # --- fils -------------------------------------------------------------

    def boucle_bus(self):
        client = Client(url_bus(self.cible), self.config.contexte_ssl,
                        self.config.delai_bus)
        dernier = 0
        while not self.arret.is_set():
            if not self.connecte:
                self.arret.wait(2)
                continue
            try:
                notifications = self.rpc(
                    ACTION_BUS, "/longpolling/poll",
                    {"channels": [], "last": dernier, "options": {}},
                    client=client)
            except ErreurSimulation:
                self.arret.wait(5)
                continue
            for notification in notifications or []:
                if isinstance(notification, dict):
                    dernier = max(dernier, notification.get("id", 0))
        client.fermer()

    def run(self):
        try:
            while not self.arret.is_set():
                if not self.connecte:
                    try:
                        self.se_connecter()
                    except ErreurSimulation:
                        if not self.connecte:
                            self.arret.wait(random.uniform(10, 20))
                            continue
                if self.config.bus and self.fil_bus is None:
                    self.fil_bus = threading.Thread(
                        target=self.boucle_bus, name=self.name + "-bus",
                        daemon=True)
                    self.fil_bus.start()
                action = random.choices(self.actions, weights=self.poids)[0]
                try:
                    action()
                except ErreurSimulation:
                    pass
                self.arret.wait(random.uniform(self.config.pause_min,
                                               self.config.pause_max))
        finally:
            self.nettoyer()
            self._changer_etat(False)
            self.client.fermer()


# ---------------------------------------------------------------------------
# Préparation : une session de test décrit les modèles avant la charge
# ---------------------------------------------------------------------------

def decrire_modele(nom, champs):
    stockes = sorted(
        n for n, d in champs.items()
        if d.get("store") and d.get("type") in TYPES_LISTE
        and n not in CHAMPS_TECHNIQUES
        and not n.startswith(("message_", "activity_", "__")))
    if "name" in stockes:
        stockes.remove("name")
        stockes.insert(0, "name")
    champs_liste = ["display_name"] + stockes[:7]
    champs_fiche = sorted(
        n for n, d in champs.items()
        if d.get("store") and d.get("type") != "binary"
        and not n.startswith("__"))[:60]
    textes = [n for n in stockes if champs[n].get("type") == "char"]
    champ_recherche = textes[0] if textes else None
    groupables = [n for n in stockes
                  if champs[n].get("type") in ("many2one", "selection")]
    preferes = [n for n in GROUPES_PREFERES if n in groupables]
    champ_groupe = (preferes or groupables or [None])[0]
    return Modele(nom, champs_liste, champs_fiche, champ_recherche,
                  champ_groupe)


def derniere_erreur(stats):
    return stats.mesures[-1][4] if stats.mesures else "?"


def preparer(config, compte, cible, noms):
    stats = Statistiques()
    sonde = Utilisateur(0, cible, compte, config, [], stats, threading.Event())
    try:
        sonde.se_connecter()
    except ErreurSimulation:
        sys.exit("Connexion impossible avec le compte %s sur %s : %s"
                 % (compte[0], cible, derniere_erreur(stats)))
    modeles = []
    for nom in noms:
        try:
            champs = sonde.appeler("préparation", nom, "fields_get",
                                   kwargs={"attributes": ["type", "store"]})
        except ErreurSimulation:
            print("  modèle %s ignoré : %s" % (nom, derniere_erreur(stats)))
            continue
        modele = decrire_modele(nom, champs or {})
        modeles.append(modele)
        print("  %s : liste %d champs, fiche %d champs, recherche sur %s, "
              "regroupement par %s" % (nom, len(modele.champs_liste),
                                       len(modele.champs_fiche),
                                       modele.champ_recherche or "-",
                                       modele.champ_groupe or "-"))
    try:
        sonde.rpc("préparation", "/mail/init_messaging", {})
        config.messagerie = True
    except ErreurSimulation:
        config.messagerie = False
    try:
        sonde.rpc("préparation", "/web/session/destroy", {})
    except ErreurSimulation:
        pass
    sonde.client.fermer()
    return modeles


# ---------------------------------------------------------------------------
# Rapports
# ---------------------------------------------------------------------------

def rapporteur(stats, arret, periode, debut, total):
    indice = 0
    precedent = time.monotonic()
    while not arret.wait(periode):
        nouvelles, indice, connectes = stats.depuis(indice)
        maintenant = time.monotonic()
        ecoule = max(0.001, maintenant - precedent)
        precedent = maintenant
        hors_bus = [m for m in nouvelles if m[2] != ACTION_BUS]
        durees = sorted(m[3] for m in hors_bus if m[4] is None)
        erreurs = sum(1 for m in nouvelles if m[4])
        noeuds = collections.Counter(m[5] for m in hors_bus)
        print("[%5d s] connectés %3d/%d | %6.1f req/s | p95 %6.2f s | "
              "erreurs %d | %s" % (maintenant - debut, connectes, total,
                                   len(hors_bus) / ecoule,
                                   centile(durees, 95), erreurs,
                                   repartition(noeuds)), flush=True)


def ligne_action(nom, mesures):
    reussies = sorted(m[3] for m in mesures if m[4] is None)
    moyenne = sum(reussies) / len(reussies) if reussies else 0.0
    print("%-28s %7d %8d %8.2f s %7.2f s %7.2f s %7.2f s" % (
        nom, len(mesures), len(mesures) - len(reussies), moyenne,
        centile(reussies, 50), centile(reussies, 95),
        reussies[-1] if reussies else 0.0))


def rapport_final(stats, debut_horloge, fin_horloge, duree, config):
    mesures = list(stats.mesures)
    hors_bus = [m for m in mesures if m[2] != ACTION_BUS]
    bus = [m for m in mesures if m[2] == ACTION_BUS]
    par_action = {}
    for m in hors_bus:
        par_action.setdefault(m[2], []).append(m)

    print()
    print("=" * 92)
    print("Résultats : %d utilisateurs, du %s au %s (%d s)" % (
        config.utilisateurs, debut_horloge.strftime("%Y-%m-%d %H:%M:%S"),
        fin_horloge.strftime("%H:%M:%S"), duree))
    print("Dans Grafana, choisir cette plage horaire pour lire le tableau "
          "de bord pendant le test.")
    print("=" * 92)
    print("%-28s %7s %8s %10s %9s %9s %9s" % (
        "Action", "Nombre", "Erreurs", "Moyenne", "Médiane", "p95", "Max"))
    for action, liste in par_action.items():
        ligne_action(action, liste)
    print("-" * 92)
    ligne_action("Total (hors bus)", hors_bus)
    print()
    print("Débit moyen : %.1f requêtes/s (hors bus)"
          % (len(hors_bus) / max(1.0, duree)))
    if config.bus:
        print("Bus (longpolling) : %d attentes, %d en erreur"
              % (len(bus), sum(1 for m in bus if m[4])))
    noeuds = collections.Counter(m[5] for m in hors_bus)
    if noeuds:
        print()
        print("Répartition (en-tête X-Odoo-Noeud, sinon adresse visée) :")
        total = sum(noeuds.values())
        for noeud, n in noeuds.most_common():
            print("  %-40s %7d  %5.1f %%" % (noeud, n, 100.0 * n / total))
    erreurs = collections.Counter(m[4] for m in mesures if m[4])
    if erreurs:
        print()
        print("Erreurs les plus fréquentes :")
        for message, n in erreurs.most_common(8):
            print("  %6d x %s" % (n, message))
    if config.csv:
        with open(config.csv, "w", newline="", encoding="utf-8") as f:
            ecrivain = csv.writer(f, delimiter=";")
            ecrivain.writerow(["horodatage", "utilisateur", "action",
                               "duree_s", "erreur", "noeud"])
            for t, utilisateur, action, d, erreur, noeud in mesures:
                ecrivain.writerow([
                    datetime.fromtimestamp(t).isoformat(timespec="milliseconds"),
                    utilisateur, action, "%.3f" % d, erreur or "", noeud or ""])
        print()
        print("Détail de chaque requête : %s" % config.csv)


# ---------------------------------------------------------------------------
# Programme principal
# ---------------------------------------------------------------------------

def lire_arguments():
    p = argparse.ArgumentParser(
        description="Simule N utilisateurs connectés à Odoo 14 "
                    "(lecture seule par défaut).")
    p.add_argument("--cible", action="append",
                   help="adresse d'Odoo ; répétable, les sessions se "
                        "répartissent à tour de rôle (défaut : "
                        "https://ha-odoo14.dev.guichetunique.cm)")
    p.add_argument("--base", default="prod",
                   help="base de données Odoo, odoo_shared_db (défaut : prod)")
    p.add_argument("--login", help="compte utilisé par toutes les sessions")
    p.add_argument("--comptes",
                   help="fichier « login;mot de passe », un compte par ligne")
    p.add_argument("--utilisateurs", type=int, default=100,
                   help="utilisateurs simultanés (défaut : 100)")
    p.add_argument("--duree", type=int, default=600,
                   help="durée du test en secondes, montée comprise "
                        "(défaut : 600)")
    p.add_argument("--montee", type=int, default=100,
                   help="secondes pour connecter tous les utilisateurs "
                        "(défaut : 100)")
    p.add_argument("--pause-min", type=float, default=3.0,
                   help="pause minimale entre deux actions, en s (défaut : 3)")
    p.add_argument("--pause-max", type=float, default=15.0,
                   help="pause maximale entre deux actions, en s (défaut : 15)")
    p.add_argument("--modeles", default="res.partner",
                   help="modèles consultés, séparés par des virgules "
                        "(défaut : res.partner)")
    p.add_argument("--ecriture", action="store_true",
                   help="ajoute créations et modifications de contacts de "
                        "test, supprimés à la fin")
    p.add_argument("--sans-bus", action="store_true",
                   help="ne pas garder d'attente ouverte sur /longpolling")
    p.add_argument("--insecure", action="store_true",
                   help="ne pas vérifier le certificat HTTPS")
    p.add_argument("--delai", type=float, default=120.0,
                   help="durée maximale d'une requête, en s (défaut : 120)")
    p.add_argument("--rapport", type=int, default=30,
                   help="période du résumé intermédiaire, en s (défaut : 30)")
    p.add_argument("--csv", help="enregistre chaque requête dans ce fichier")
    a = p.parse_args()
    if not a.login and not a.comptes:
        p.error("--login ou --comptes est obligatoire")
    if a.pause_min > a.pause_max:
        p.error("--pause-min doit être inférieure à --pause-max")
    if a.utilisateurs < 1:
        p.error("--utilisateurs doit valoir au moins 1")
    a.cible = a.cible or ["https://ha-odoo14.dev.guichetunique.cm"]
    return a


def lire_comptes(a):
    if a.comptes:
        comptes = []
        with open(a.comptes, encoding="utf-8") as f:
            for ligne in f:
                ligne = ligne.rstrip("\r\n")
                if not ligne.strip() or ligne.lstrip().startswith("#"):
                    continue
                login, separateur, mdp = ligne.partition(";")
                if not separateur:
                    sys.exit("Ligne sans « ; » dans %s : %s" % (a.comptes, ligne))
                comptes.append((login.strip(), mdp))
        if not comptes:
            sys.exit("Aucun compte dans %s" % a.comptes)
        return comptes
    mdp = os.environ.get("ODOO_MDP")
    if mdp:
        print("Mot de passe de %s lu dans la variable ODOO_MDP." % a.login)
    else:
        mdp = getpass.getpass("Mot de passe de %s : " % a.login)
    return [(a.login, mdp)]


def attendre_jusqu_a(echeance):
    while True:
        reste = echeance - time.monotonic()
        if reste <= 0:
            return
        time.sleep(min(1.0, reste))


def main():
    config = lire_arguments()
    comptes = lire_comptes(config)
    contexte = ssl.create_default_context()
    if config.insecure:
        contexte.check_hostname = False
        contexte.verify_mode = ssl.CERT_NONE
    config.contexte_ssl = contexte
    config.bus = not config.sans_bus
    config.delai_bus = 75.0   # Odoo garde l'attente du bus 50 s au plus
    config.messagerie = False

    print("Préparation sur %s, base %s :" % (config.cible[0], config.base),
          flush=True)
    noms = [n.strip() for n in config.modeles.split(",") if n.strip()]
    modeles = preparer(config, comptes[0], config.cible[0], noms)
    if not modeles:
        sys.exit("Aucun modèle utilisable : vérifier --modeles.")

    print()
    print("%d utilisateurs, connectés en %d s, test de %d s, pause %.0f à %.0f s"
          % (config.utilisateurs, config.montee, config.duree,
             config.pause_min, config.pause_max))
    print("Cibles : %s" % ", ".join(config.cible))
    print("Écritures : %s | bus : %s | messagerie : %s" % (
        "oui" if config.ecriture else "non (lecture seule)",
        "oui" if config.bus else "non",
        "oui" if config.messagerie else "module absent"))
    if len(config.cible) == 1 and urlsplit(config.cible[0]).port != 8069:
        print("Attention : nginx répartit selon l'adresse du client "
              "(hash $remote_addr). Toutes les sessions de ce poste "
              "arriveront sur le même Odoo.")
    print(flush=True)

    stats = Statistiques()
    arret = threading.Event()
    debut = time.monotonic()
    fin = debut + config.duree
    debut_horloge = datetime.now()
    threading.Thread(target=rapporteur, daemon=True, args=(
        stats, arret, config.rapport, debut, config.utilisateurs)).start()

    utilisateurs = []
    ecart = config.montee / float(config.utilisateurs)
    try:
        for i in range(config.utilisateurs):
            if time.monotonic() >= fin:
                break
            u = Utilisateur(i + 1, config.cible[i % len(config.cible)],
                            comptes[i % len(comptes)], config, modeles,
                            stats, arret)
            u.start()
            utilisateurs.append(u)
            attendre_jusqu_a(min(fin, time.monotonic() + ecart))
        attendre_jusqu_a(fin)
    except KeyboardInterrupt:
        print("\nInterrompu.", flush=True)

    arret.set()
    print("Fin du test : les utilisateurs terminent leur requête en cours%s..."
          % (" et suppriment leurs contacts de test" if config.ecriture else ""),
          flush=True)
    limite = time.monotonic() + config.delai + 30
    try:
        for u in utilisateurs:
            u.join(max(0.1, limite - time.monotonic()))
    except KeyboardInterrupt:
        pass
    duree = time.monotonic() - debut
    rapport_final(stats, debut_horloge, datetime.now(), duree, config)

    restants = [i for u in utilisateurs for i in u.crees]
    if restants:
        print()
        print("Contacts de test non supprimés (nom « [test charge] ... ») : "
              "ids %s" % restants)


if __name__ == "__main__":
    main()
