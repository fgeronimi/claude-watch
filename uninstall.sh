#!/bin/bash
# Désinstalle claude-watch. L'historique est conservé, sauf avec --purge.

set -euo pipefail

ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
# shellcheck source=lib/common.sh
. "$ROOT/lib/common.sh"

purge=0
[ "${1:-}" = "--purge" ] && purge=1

# --- Arrêt des caffeinate lancés par claude-watch ---
for f in "$STATE_DIR"/awake-*.pid; do
  [ -f "$f" ] || continue
  pid=$(cat "$f" 2>/dev/null || true)
  if is_caffeinate "$pid"; then kill "$pid" 2>/dev/null || true; fi
  rm -f "$f"
done

# --- settings.json ---
settings="$HOME/.claude/settings.json"
if [ -f "$settings" ] && jq empty "$settings" 2>/dev/null; then
  cp "$settings" "$settings.bak.$(date +%Y%m%d-%H%M%S)"
  tmp=$(mktemp)
  jq '
    def ours: (.command // "") | contains("/claude-watch/");
    def strip: map(.hooks = ((.hooks // []) | map(select(ours | not)))) | map(select((.hooks | length) > 0));
    if .hooks then .hooks |= (with_entries(.value |= strip) | with_entries(select((.value | length) > 0))) else . end
    | if .hooks == {} then del(.hooks) else . end
    | if ((.statusLine.command // "") | contains("/claude-watch/")) then del(.statusLine) else . end
  ' "$settings" > "$tmp"
  mv "$tmp" "$settings"
  echo "Réglages nettoyés : $settings"
fi

# --- Liens ---
rm -f "$HOME/.claude/claude-watch"
plugin_dir=$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || true)
plugin_dir="${plugin_dir/#\~/$HOME}"
[ -n "$plugin_dir" ] && rm -f "$plugin_dir/claude-watch.5s.sh"
for bindir in "$HOME/.local/bin" "$HOME/bin"; do
  [ -L "$bindir/claude-watch" ] && rm -f "$bindir/claude-watch"
done
echo "Liens supprimés."

if [ "$purge" = 1 ]; then
  rm -rf "$STATE_DIR"
  echo "Historique supprimé : $STATE_DIR"
else
  echo "Historique conservé : $STATE_DIR (--purge pour le supprimer)"
fi
