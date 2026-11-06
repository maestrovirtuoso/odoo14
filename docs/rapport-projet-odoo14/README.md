# Rapport ProSys — Odoo 14

[Rapport Word DOCX](Rapport-ProSys-Odoo14-Architecture-Fonctionnement.docx) · [Version PDF](Rapport-ProSys-Odoo14-Architecture-Fonctionnement.pdf)

Édition du **3 novembre 2026**. Le rapport rassemble **27 figures graphiques** et **12 schémas textuels**, avec explications du fonctionnement applicatif et technique.

Il couvre les familles ERP demandées, le parcours d’une action utilisateur et d’une pièce jointe, Debian/LXC/venv, PostgreSQL/Patroni/etcd/HAProxy, GlusterFS, la maintenance et les sauvegardes. Il distingue les fonctions demandées, les faits vérifiés dans le dépôt et les éléments restant à constater en exploitation.

Les images sont intégrées dans le DOCX. Les chapitres utilisent le format A4 ; les planches graphiques utilisent le format A3 pour préserver la lisibilité. Les vues historiques sont conservées et contextualisées.

## Sources et génération

- `rapport-contenu.json` : texte, catalogue des figures et sources.
- `generer-rapport.ps1` et `word-outils.ps1` : construction Word, sommaire, pagination et export PDF.
- `exporter-reseau-historique.ps1` : rendu du seul draw.io initialement sans PNG.
- `rendre-apercus.ps1` : rendu des pages PDF et planches de contrôle visuel.
- `verification-rapport.json` : bilan de pagination et correspondance figures/pages.

Génération depuis la racine du projet sous Windows avec Microsoft Word installé :

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\docs\rapport-projet-odoo14\generer-rapport.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\docs\rapport-projet-odoo14\rendre-apercus.ps1
```

Les éditions Community/Enterprise et les modules installés doivent être confirmés dans Odoo. Aucun secret ni aucune clé privée n’est reproduit.
