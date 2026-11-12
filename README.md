# claude-watch

Garde le Mac éveillé tant qu'un agent Claude Code travaille, et suit la consommation des quotas dans la barre de menus.

- **Veille** : `caffeinate` démarre quand tu envoies un prompt et s'arrête quand l'agent a fini.
- **Barre de menus** (SwiftBar) : nombre d'agents actifs, quotas 5 h et 7 jours, rythme de consommation.
- **Status line** Claude Code : le même résumé, session par session.
- **Historique** SQLite : coût par projet, par modèle et par jour.
- **Alertes** macOS : passage de 80 % puis 95 % d'un quota, fin d'un tour d'agent de plus de 5 minutes.

Aucun appel réseau : tout vient du JSON que Claude Code transmet à la status line.

## Installation

```bash
brew install jq
brew install --cask swiftbar   # à lancer une fois pour choisir le dossier de plugins
./install.sh
```

`install.sh` peut être relancé sans risque. Il :

1. crée le lien `~/.claude/claude-watch` vers ce repo ;
2. ajoute les hooks `UserPromptSubmit`, `Stop` et `SessionEnd` dans `~/.claude/settings.json`, après une sauvegarde horodatée et sans toucher aux autres réglages ;
3. configure la status line, sauf si une autre est déjà en place (`./install.sh --force` pour la remplacer) ;
4. lie le plugin dans le dossier SwiftBar et la CLI dans `~/.local/bin` ou `~/bin` s'ils existent.

Les sessions Claude Code déjà ouvertes doivent être relancées. `claude-watch doctor` vérifie l'installation.

Pour désinstaller : `./uninstall.sh` (`--purge` supprime aussi l'historique).

## Lecture de l'affichage

Barre de menus : `☕2 34%▲ · 61%`

| Élément | Sens |
| --- | --- |
| `☕2` | deux agents travaillent, la veille est bloquée (`💤` : aucun) |
| `34%` | quota de la fenêtre de 5 h |
| `61%` | quota de la fenêtre de 7 jours |
| `▲` | consommation plus rapide que le temps qui passe : le quota sera épuisé avant le reset |
| `▼` | de la marge |

Le texte passe en orange à 80 % et en rouge à 95 %. Le menu déroulant donne les heures de reset, la projection au reset, le coût du jour et les projets les plus consommateurs sur 7 jours.

Le rythme compare le pourcentage consommé au pourcentage de la fenêtre écoulé. Exemple : 60 % du quota hebdo après 30 % de la semaine donne ▲ et une projection à 200 %. La projection n'est affichée qu'après 10 % de la fenêtre, avant elle ne veut rien dire.

## CLI

```
claude-watch status            agents actifs, quotas et rythme
claude-watch history [jours]   une ligne par jour (14 par défaut)
claude-watch report [jours]    coût par projet et par modèle (7 par défaut)
claude-watch doctor            dépendances et installation
claude-watch paths             chemins utilisés
```

La base se requête aussi directement : `sqlite3 ~/.local/state/claude-watch/history.db`, table `samples` et vue `deltas` (coût de chaque intervalle).

## Configuration

Optionnelle : copier `config.example` dans `~/.config/claude-watch/config`. On peut y régler la durée maximale de `caffeinate`, ses options, les seuils d'alerte et la marge du rythme.

## Fonctionnement

```
UserPromptSubmit ─► hooks/awake.sh start ─► caffeinate -i (pid dans l'état)
Stop / SessionEnd ─► hooks/awake.sh stop|end ─► kill, notification
status line ─► statusline.sh ─► fichier quota + historique SQLite + alertes
SwiftBar (5 s) ─► swiftbar/claude-watch.5s.sh ─► lit l'état, n'écrit rien
```

L'état vit dans `~/.local/state/claude-watch/` : un pid `caffeinate` par session, la dernière mesure de quota, la base `history.db`.

## Limites

- **Quotas** : disponibles seulement avec un abonnement Pro ou Max, et après la première réponse d'une session. Le quota hebdomadaire par modèle affiché par `/usage` n'est pas transmis à la status line.
- **Fraîcheur** : la mesure ne bouge que lorsqu'une session Claude Code tourne. L'usage fait ailleurs (claude.ai, autre machine) n'apparaît qu'à la session suivante ; le menu indique l'âge de la mesure.
- **Coûts** : c'est le coût équivalent API calculé par Claude Code, pas une facture. Il sert à comparer projets et modèles entre eux.
- **Écran rabattu sur batterie** : macOS met en veille malgré `caffeinate`. Il faut le secteur et un écran externe.
- **Interruption avec Échap** : le hook `Stop` peut ne pas se déclencher. `caffeinate` s'arrête alors au prompt suivant, à la fin de la session ou après 4 h.
- **Tour de plus de 4 h** : `caffeinate` expire avant la fin, augmenter `CLAUDE_WATCH_MAX_SECONDS`.

## Tests

```bash
./tests/run.sh
```

Les tests simulent `caffeinate` et les notifications, ils tournent aussi sous Linux (il faut `jq` et `sqlite3`).
