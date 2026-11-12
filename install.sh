#!/bin/bash
# Installe claude-watch : lien ~/.claude/claude-watch, hooks et status line dans
# ~/.claude/settings.json, plugin SwiftBar. Peut être relancé sans risque.
#
#   ./install.sh           installe (ne remplace pas une status line existante)
#   ./install.sh --force   remplace aussi une status line existante

set -euo pipefail

ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

force=0
[ "${1:-}" = "--force" ] && force=1

for c in jq sqlite3; do
  command -v "$c" >/dev/null 2>&1 || { echo "Il manque $c (brew install $c)." >&2; exit 1; }
done
command -v caffeinate >/dev/null 2>&1 || echo "Attention : caffeinate introuvable (macOS uniquement)."
command -v python3 >/dev/null 2>&1 || echo "Attention : python3 introuvable, la barre de menus sera en texte au lieu des batteries."

chmod +x "$ROOT/install.sh" "$ROOT/uninstall.sh" "$ROOT/statusline.sh" \
  "$ROOT/hooks/awake.sh" "$ROOT/swiftbar/claude-watch.5s.sh" "$ROOT/bin/claude-watch"

# --- Lien stable : settings.json ne dépend pas de l'emplacement du repo ---
CLAUDE_DIR="$HOME/.claude"
LINK="$CLAUDE_DIR/claude-watch"
mkdir -p "$CLAUDE_DIR"
ln -sfn "$ROOT" "$LINK"
echo "Lien        : $LINK → $ROOT"

# --- Base d'historique ---
# shellcheck source=lib/common.sh
. "$ROOT/lib/common.sh"
db_init
echo "Historique  : $DB"

# --- settings.json ---
settings="$CLAUDE_DIR/settings.json"
[ -f "$settings" ] || echo '{}' > "$settings"
jq empty "$settings" 2>/dev/null || { echo "$settings n'est pas un JSON valide, je n'y touche pas." >&2; exit 1; }
backup="$settings.bak.$(date +%Y%m%d-%H%M%S)"
cp "$settings" "$backup"

tmp=$(mktemp)
jq --arg base "$LINK" --arg force "$force" '
  # Retire nos anciennes entrées (et celles du script manuel ~/.claude/hooks/awake.sh).
  def ours: (.command // "") | (contains("/claude-watch/") or contains(".claude/hooks/awake.sh"));
  def strip: map(.hooks = ((.hooks // []) | map(select(ours | not)))) | map(select((.hooks | length) > 0));
  def add(ev; arg):
    .hooks[ev] = (((.hooks[ev] // []) | strip)
      + [{hooks: [{type: "command", command: ("\"" + $base + "/hooks/awake.sh\" " + arg)}]}]);

  .hooks = (.hooks // {})
  | add("UserPromptSubmit"; "start")
  | add("Stop"; "stop")
  | add("SessionEnd"; "end")
  | if $force == "1" or .statusLine == null or ((.statusLine.command // "") | contains("/claude-watch/"))
    then .statusLine = {type: "command", command: ("\"" + $base + "/statusline.sh\"")}
    else . end
' "$settings" > "$tmp"
mv "$tmp" "$settings"
echo "Réglages    : $settings (sauvegarde : $backup)"

if ! jq -e '(.statusLine.command // "") | contains("/claude-watch/")' "$settings" >/dev/null; then
  echo
  echo "Une autre status line est déjà configurée, je ne l'ai pas remplacée :"
  echo "  $(jq -r '.statusLine.command' "$settings")"
  echo "Sans la status line de claude-watch, pas de quotas ni d'historique."
  echo "Relance avec --force pour la remplacer."
  echo
fi

# --- Plugin SwiftBar ---
plugin_dir=$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || true)
plugin_dir="${plugin_dir/#\~/$HOME}"
if [ -n "$plugin_dir" ] && [ -d "$plugin_dir" ]; then
  ln -sfn "$ROOT/swiftbar/claude-watch.5s.sh" "$plugin_dir/claude-watch.5s.sh"
  echo "SwiftBar    : $plugin_dir/claude-watch.5s.sh"
  [ -e "$plugin_dir/claude-awake.5s.sh" ] \
    && echo "              (l'ancien claude-awake.5s.sh est encore là, tu peux le supprimer)"
else
  echo "SwiftBar    : dossier de plugins introuvable."
  echo "              brew install --cask swiftbar, lance-le une fois, puis relance ./install.sh"
fi

# --- CLI ---
for bindir in "$HOME/.local/bin" "$HOME/bin"; do
  if [ -d "$bindir" ]; then
    ln -sfn "$ROOT/bin/claude-watch" "$bindir/claude-watch"
    echo "CLI         : $bindir/claude-watch"
    break
  fi
done

echo
echo "Terminé. Les sessions Claude Code déjà ouvertes doivent être relancées."
