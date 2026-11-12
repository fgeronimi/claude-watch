#!/bin/bash
# Status line Claude Code : affiche l'état de veille et les quotas, et les
# enregistre pour la barre de menus (fichier quota) et l'historique (SQLite).

src="${BASH_SOURCE[0]}"
while [ -L "$src" ]; do
  dir="$(cd -P "$(dirname "$src")" && pwd)"
  src="$(readlink "$src")"
  case "$src" in /*) ;; *) src="$dir/$src" ;; esac
done
ROOT="$(cd -P "$(dirname "$src")" && pwd)"
# shellcheck source=lib/common.sh
. "$ROOT/lib/common.sh"

input=$(cat)

# Un seul appel jq ; séparateur non blanc pour conserver les champs vides.
IFS=$'\x1f' read -r sid project model cost five five_reset seven seven_reset <<EOF
$(jq -r '
  def pct: if . == null then "" else floor end;
  [ (.session_id // ""),
    (.workspace.project_dir // .cwd // ""),
    (.model.display_name // .model.id // ""),
    (.cost.total_cost_usd // 0),
    (.rate_limits.five_hour.used_percentage | pct),
    (.rate_limits.five_hour.resets_at | pct),
    (.rate_limits.seven_day.used_percentage | pct),
    (.rate_limits.seven_day.resets_at | pct)
  ] | map(tostring) | join("\u001f")' <<<"$input" 2>/dev/null)
EOF

sid=$(printf %s "$sid" | tr -cd 'A-Za-z0-9_-')
[ -n "$sid" ] || { echo "claude-watch : pas de session"; exit 0; }

mkdir -p "$STATE_DIR"
ts=$(now)

# --- Quotas pour la barre de menus ---
if [ -n "$five" ]; then
  tmp="$STATE_DIR/quota.tmp.$$"
  printf '%s %s %s %s %s\n' "$ts" "$five" "${five_reset:-0}" "${seven:-0}" "${seven_reset:-0}" > "$tmp" \
    && mv "$tmp" "$STATE_DIR/quota"
  (
    check_alert five "Session 5 h" "$five" "${five_reset:-0}"
    check_alert seven "Semaine" "$seven" "${seven_reset:-0}"
  ) >/dev/null 2>&1 &
fi

# --- Historique : la dernière mesure est toujours gardée en attente, puis
# écrite en base au plus une fois par intervalle (ou par le hook Stop). ---
pending="$STATE_DIR/pending-$sid.sql"
printf "INSERT INTO samples VALUES (%s, '%s', '%s', '%s', %s, %s, %s, %s, %s);\n" \
  "$ts" "$sid" "$(sq "$project")" "$(sq "$model")" \
  "${five:-NULL}" "${five_reset:-NULL}" "${seven:-NULL}" "${seven_reset:-NULL}" "${cost:-0}" \
  > "$pending.tmp.$$" && mv "$pending.tmp.$$" "$pending"

stamp="$STATE_DIR/log-$sid.stamp"
last=$(cat "$stamp" 2>/dev/null || echo 0)
if [ $((ts - last)) -ge "$CLAUDE_WATCH_LOG_INTERVAL" ]; then
  echo "$ts" > "$stamp"
  flush_pending
fi

# --- Affichage ---
if is_caffeinate "$(cat "$STATE_DIR/awake-$sid.pid" 2>/dev/null)"; then awake="☕"; else awake="💤"; fi

if [ -z "$five" ]; then
  echo "$awake quotas indisponibles"
  exit 0
fi

red=$'\033[31m'; yellow=$'\033[33m'; reset=$'\033[0m'
paint() { # <pct> <texte>
  if [ "$1" -ge 95 ]; then printf '%s%s%s' "$red" "$2" "$reset"
  elif [ "$1" -ge 80 ]; then printf '%s%s%s' "$yellow" "$2" "$reset"
  else printf '%s' "$2"
  fi
}

read -r _ _ five_state <<<"$(pace "$five" "${five_reset:-0}" "$FIVE_LEN" "$ts")"
line="$awake 5h $(paint "$five" "$five%")$(pace_icon "$five_state")"
[ "${five_reset:-0}" -gt "$ts" ] && line="$line ↻$(fmt_epoch "$five_reset" '%H:%M')"

if [ -n "$seven" ]; then
  read -r _ _ seven_state <<<"$(pace "$seven" "${seven_reset:-0}" "$SEVEN_LEN" "$ts")"
  line="$line │ 7j $(paint "$seven" "$seven%")$(pace_icon "$seven_state")"
fi

echo "$line"
