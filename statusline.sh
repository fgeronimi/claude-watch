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
IFS=$'\x1f' read -r sid project dir model ctx cost five five_reset seven seven_reset <<EOF
$(jq -r '
  def pct: if . == null then "" else floor end;
  [ (.session_id // ""),
    (.workspace.project_dir // .cwd // ""),
    (.workspace.current_dir // .cwd // ""),
    (.model.display_name // .model.id // ""),
    (.context_window.used_percentage | pct),
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
# ● projet  branche  modèle  ctx 42%   5h 34%   7j 61%
if [ "${CLAUDE_WATCH_COLOR:-1}" = 1 ]; then
  c_off=$'\033[0m'; c_dim=$'\033[2m'; c_bold=$'\033[1m'
  c_red=$'\033[31m'; c_green=$'\033[32m'; c_yellow=$'\033[33m'
  c_blue=$'\033[34m'; c_magenta=$'\033[35m'; c_cyan=$'\033[36m'
else
  c_off=""; c_dim=""; c_bold=""; c_red=""; c_green=""; c_yellow=""; c_blue=""; c_magenta=""; c_cyan=""
fi

level_color() { # <pct> : vert, puis jaune à 80 %, rouge à 95 %
  if [ "$1" -ge 95 ]; then printf %s "$c_red"
  elif [ "$1" -ge 80 ]; then printf %s "$c_yellow"
  else printf %s "$c_green"
  fi
}

# Point vert : veille bloquée pour cette session. Cercle gris : veille normale.
if is_caffeinate "$(cat "$STATE_DIR/awake-$sid.pid" 2>/dev/null)"; then
  line="${c_green}●${c_off}"
else
  line="${c_dim}○${c_off}"
fi

[ -n "$project" ] && line="$line ${c_bold}${c_cyan}$(basename "$project")${c_off}"

branch=""
if [ -n "$dir" ] && [ -d "$dir" ]; then
  branch=$(git --no-optional-locks -C "$dir" symbolic-ref --quiet --short HEAD 2>/dev/null \
    || git --no-optional-locks -C "$dir" rev-parse --short HEAD 2>/dev/null)
fi
[ -n "$branch" ] && line="$line  ${c_magenta}${branch}${c_off}"
[ -n "$model" ] && line="$line  ${c_blue}${model}${c_off}"
[ -n "$ctx" ] && line="$line  ${c_dim}ctx${c_off} $(level_color "$ctx")${ctx}%${c_off}"

if [ -z "$five" ]; then
  echo "$line   ${c_dim}quotas indisponibles${c_off}"
  exit 0
fi

quota() { # <libellé> <pct> <resets_at> <durée fenêtre> <afficher le reset : 0|1>
  local state out
  read -r _ _ state <<<"$(pace "$2" "$3" "$4" "$ts")"
  out="${c_dim}$1${c_off} $(level_color "$2")$2%${c_off}"
  # ▲ : consommation plus rapide que le temps qui passe.
  [ "$state" = fast ] && out="$out${c_yellow}▲${c_off}"
  # Le temps avant le reset n'apparaît que lorsqu'il devient utile.
  if [ "$5" = 1 ] && [ "$2" -ge 80 ] && [ "$3" -gt "$ts" ]; then
    out="$out ${c_dim}↻$(short_duration $(($3 - ts)))${c_off}"
  fi
  printf %s "$out"
}

line="$line   $(quota 5h "$five" "${five_reset:-0}" "$FIVE_LEN" 1)"
[ -n "$seven" ] && line="$line   $(quota 7j "$seven" "${seven_reset:-0}" "$SEVEN_LEN" 1)"

echo "$line"
