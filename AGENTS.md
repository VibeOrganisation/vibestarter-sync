# VibeStarter Sync

> Méthode de travail commune : `../AGENTS.md`. Ce dépôt ne tourne sur aucun serveur.
> **Branche par défaut : `vibestarter-sync`**, pas `main`.

Fork de [Rojo](https://github.com/rojo-rbx/rojo), l'outil de synchronisation
fichiers ↔ Roblox Studio. Consommé par `../vibestarter` comme sous-arbre `vendor/sync` :
le build de l'image VM **ne clone plus l'upstream**, il compile ce sous-arbre.

## Ce dépôt n'est pas un projet propre

C'est du code tiers modifié. Deux conséquences qui priment sur toute considération de
style.

**La licence est MPL-2.0.** Les fichiers couverts **et modifiés** doivent rester
disponibles sous MPL pour les destinataires du binaire distribué. N'introduis pas de code
sous une licence incompatible dans les fichiers hérités, et ne retire aucun en-tête de
licence.

**La provenance vit dans `UPSTREAM.json`**, qui remplace le champ `rojoCommit` de
`vibestarter/scripts/vm-image/guest-build.lock.json`. Base actuelle :

| | |
|---|---|
| Upstream | `https://github.com/rojo-rbx/rojo.git` |
| Tag de base | `v7.7.0-rc.1` |
| Commit de base | `0113f7b07419b0127ed86cc42a2df56fe57bfaa0` |

Tiens ce fichier à jour : c'est lui qui permet d'auditer la divergence et de préparer une
montée de version de Rojo.

## Mesurer la divergence avant de modifier

Avant tout changement non trivial, regarde ce qui a déjà été modifié par rapport à
l'upstream — un correctif local peut déjà exister, ou avoir été corrigé en amont :

```bash
git remote add upstream https://github.com/rojo-rbx/rojo.git   # une seule fois
git fetch upstream --tags
git diff upstream/v7.7.0-rc.1 -- .
```

**Préfère toujours un correctif accepté en amont à une divergence de plus.** Chaque écart
local est une dette à repayer à la prochaine montée de version.

## Rapport à VibeStarter

Les notes d'intégration côté consommateur vivent dans `../vibestarter` — voir son
`AGENTS.md`, `THIRD-PARTY-NOTICES.md` et les documents `docs/studio-mcp-*`. Un changement
de comportement ici peut casser le plugin Studio ou le watchdog côté application : vérifie
là-bas avant de considérer un changement comme terminé.
