#!/usr/bin/python3
"""Relance Patroni sur ce serveur SANS redemarrer PostgreSQL, et le prouve.

Appele par tasks/relance.yaml, cluster EN PAUSE : en pause, un Patroni qui
s'arrete laisse PostgreSQL tourner, et KillMode=process empeche systemd de
l'arreter a sa place. Seul Patroni redemarre, et relit sa configuration
etcd, qu'un reload ne change pas.

Usage : relancer_patroni.py <URL de l'API REST de ce serveur> <delai en s>

Sort en 0 si, apres la relance, Patroni repond, se voit toujours en pause, a
joint etcd depuis sa relance, et si PostgreSQL a garde son heure de
demarrage. Sinon, sort en erreur avec la raison, avant tout autre serveur.
"""
import json
import subprocess
import sys
import time
import urllib.request

API = sys.argv[1].rstrip('/')
DELAI = int(sys.argv[2])


def arreter(raison):
    sys.exit('{} Le cluster reste en pause (bascule automatique desactivee).'.format(raison))


def statut():
    with urllib.request.urlopen(API + '/patroni', timeout=3) as reponse:
        return json.load(reponse)


kill_mode = subprocess.run(
    ['systemctl', 'show', '-p', 'KillMode', '--value', 'patroni'],
    capture_output=True, text=True, check=True).stdout.strip()
if kill_mode != 'process':
    arreter('KillMode={} : systemd arreterait PostgreSQL avec Patroni.'.format(kill_mode))

try:
    avant = statut()
except (OSError, ValueError) as erreur:
    arreter('API de Patroni injoignable avant la relance ({}).'.format(erreur))
if not avant.get('pause'):
    arreter('Patroni ne se voit pas en pause : le relancer arreterait PostgreSQL.')
if avant.get('state') != 'running' or not avant.get('postmaster_start_time'):
    arreter('PostgreSQL ne tourne pas (etat : {}).'.format(avant.get('state')))

debut = int(time.time())
try:
    subprocess.run(['systemctl', 'restart', 'patroni'], check=True)
except subprocess.CalledProcessError:
    arreter('systemctl restart patroni a echoue (journalctl -u patroni).')

# "pause" vrai apres la relance prouve deja que le nouveau Patroni a lu etcd :
# la pause n'existe que la. dcs_last_seen (Patroni >= 2.1) le date.
apres = {}
limite = time.time() + DELAI
while True:
    time.sleep(2)
    try:
        apres = statut()
    except (OSError, ValueError):
        apres = {}  # API pas encore revenue
    vu = apres.get('dcs_last_seen')
    if apres.get('state') == 'running' and apres.get('pause') and (vu is None or vu >= debut):
        break
    if time.time() > limite:
        manque = []
        if apres.get('state') != 'running':
            manque.append('etat {}'.format(apres.get('state', 'inconnu : API muette')))
        if not apres.get('pause'):
            manque.append("pause non vue (etcd pas lu)")
        if vu is not None and vu < debut:
            manque.append('etcd pas joint depuis la relance')
        arreter('Relance non confirmee {} s apres : {}.'.format(DELAI, ', '.join(manque)))

if apres.get('postmaster_start_time') != avant.get('postmaster_start_time'):
    arreter('PostgreSQL a redemarre ({} puis {}).'.format(
        avant.get('postmaster_start_time'), apres.get('postmaster_start_time')))

print('Patroni relance et relie a etcd ; PostgreSQL intact (demarre le {}).'.format(
    apres.get('postmaster_start_time')))
