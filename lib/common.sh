# shellcheck shell=bash
# Fonctions partagées par tous les scripts de claude-watch (à sourcer).
# Compatible avec le bash 3.2 livré par macOS.

# Les hooks et SwiftBar tournent avec un PATH minimal : on ajoute Homebrew.
PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

CLAUDE_WATCH_CONFIG="${CLAUDE_WATCH_CONFIG:-$HOME/.config/claude-watch/config}"
# shellcheck disable=SC1090
[ -f "$CLAUDE_WATCH_CONFIG" ] && . "$CLAUDE_WATCH_CONFIG"

STATE_DIR="${CLAUDE_WATCH_STATE_DIR:-$HOME/.local/state/claude-watch}"
DB="$STATE_DIR/history.db"

: "${CLAUDE_WATCH_MAX_SECONDS:=14400}"      # garde-fou caffeinate (4 h)
: "${CLAUDE_WATCH_CAFFEINATE_FLAGS:=-i}"    # ajouter -d pour garder l'écran allumé
: "${CLAUDE_WATCH_THRESHOLDS:=80 95}"       # seuils d'alerte, en ordre croissant
: "${CLAUDE_WATCH_NOTIFY_AFTER:=300}"       # notifier la fin d'un tour plus long que N s (0 = jamais)
: "${CLAUDE_WATCH_LOG_INTERVAL:=30}"        # intervalle mini entre deux mesures par session
: "${CLAUDE_WATCH_PACE_MARGIN:=10}"         # écart (en points) avant d'afficher ▲ ou ▼
: "${CLAUDE_WATCH_COLOR:=1}"                # couleurs dans la status line (0 = sans)
: "${CLAUDE_WATCH_BAR_STYLE:=battery}"      # barre de menus : battery (icône) ou text
: "${CLAUDE_WATCH_BAR_THEME:=auto}"         # auto, light ou dark (utilisé quand une batterie est rouge)
: "${CLAUDE_WATCH_LOW:=20}"                 # % restant sous lequel une batterie passe au rouge

FIVE_LEN=18000     # fenêtre de 5 h
SEVEN_LEN=604800   # fenêtre de 7 jours

now() { date +%s; }

# fmt_epoch <epoch> <format strftime> — date BSD (macOS) puis GNU en secours.
fmt_epoch() { date -r "$1" "+$2" 2>/dev/null || date -d "@$1" "+$2"; }

# human_duration <secondes> → "12 min", "2 h 05", "3 j 4 h"
human_duration() {
  local s=$1
  [ "$s" -lt 0 ] && s=0
  if [ "$s" -lt 60 ]; then echo "moins d'1 min"
  elif [ "$s" -lt 3600 ]; then echo "$((s / 60)) min"
  elif [ "$s" -lt 86400 ]; then printf '%d h %02d\n' $((s / 3600)) $((s % 3600 / 60))
  else echo "$((s / 86400)) j $((s % 86400 / 3600)) h"
  fi
}

# short_duration <secondes> → "12min", "1h39", "3j" (forme compacte pour la status line)
short_duration() {
  local s=$1
  [ "$s" -lt 0 ] && s=0
  if [ "$s" -lt 3600 ]; then echo "$((s / 60))min"
  elif [ "$s" -lt 86400 ]; then printf '%dh%02d\n' $((s / 3600)) $((s % 3600 / 60))
  else echo "$((s / 86400))j"
  fi
}

# gauge <pct> [largeur] → ▰▰▰▱▱▱▱▱▱▱
gauge() {
  local pct=$1 width=${2:-10} filled i out=""
  filled=$(( (pct * width + 50) / 100 ))
  [ "$filled" -gt "$width" ] && filled=$width
  [ "$filled" -lt 0 ] && filled=0
  # Un quota entamé n'affiche jamais une jauge vide.
  [ "$pct" -gt 0 ] && [ "$filled" -eq 0 ] && filled=1
  i=0
  while [ "$i" -lt "$width" ]; do
    if [ "$i" -lt "$filled" ]; then out="$out▰"; else out="$out▱"; fi
    i=$((i + 1))
  done
  echo "$out"
}

# Échappe une valeur pour un littéral SQL entre apostrophes.
sq() { printf %s "$1" | sed "s/'/''/g"; }

db() { sqlite3 -cmd ".timeout 3000" "$DB" "$@"; }

db_init() {
  mkdir -p "$STATE_DIR"
  db >/dev/null <<'SQL'
PRAGMA journal_mode=WAL;
CREATE TABLE IF NOT EXISTS samples (
  ts          INTEGER NOT NULL,
  session_id  TEXT    NOT NULL,
  project     TEXT,
  model       TEXT,
  five_pct    REAL,
  five_reset  INTEGER,
  seven_pct   REAL,
  seven_reset INTEGER,
  cost_usd    REAL
);
CREATE INDEX IF NOT EXISTS samples_ts ON samples (ts);
CREATE INDEX IF NOT EXISTS samples_session ON samples (session_id, ts);
-- cost_usd est cumulé par session : la vue en déduit le coût de chaque intervalle.
CREATE VIEW IF NOT EXISTS deltas AS
SELECT *,
       MAX(0, cost_usd - COALESCE(LAG(cost_usd) OVER (PARTITION BY session_id ORDER BY ts), 0)) AS cost_delta
FROM samples;
SQL
}

# Écrit en base les mesures laissées en attente par la status line.
flush_pending() {
  local f tmp
  [ -f "$DB" ] || db_init
  for f in "$STATE_DIR"/pending-*.sql; do
    [ -f "$f" ] || continue
    tmp="$f.flush.$$"
    mv "$f" "$tmp" 2>/dev/null || continue
    db < "$tmp" >/dev/null 2>&1
    rm -f "$tmp"
  done
}

# Vrai si le pid est bien un caffeinate vivant (l'état survit aux redémarrages,
# un pid peut donc avoir été réattribué à un autre process).
is_caffeinate() {
  [ -n "$1" ] && ps -p "$1" -o comm= 2>/dev/null | grep -q caffeinate
}

active_count() {
  local n=0 f
  for f in "$STATE_DIR"/awake-*.pid; do
    [ -f "$f" ] || continue
    if is_caffeinate "$(cat "$f" 2>/dev/null)"; then n=$((n + 1)); fi
  done
  echo "$n"
}

# pace <pct consommé> <resets_at> <durée fenêtre> [maintenant]
# → "<% de la fenêtre écoulé> <projection % au reset, -1 si trop tôt> <fast|ok|slow>"
pace() {
  awk -v p="$1" -v r="$2" -v l="$3" -v n="${4:-$(now)}" -v m="$CLAUDE_WATCH_PACE_MARGIN" 'BEGIN {
    rem = r - n; if (rem < 0) rem = 0; if (rem > l) rem = l
    e = (l - rem) / l * 100
    proj = (e >= 10) ? p / e * 100 : -1
    d = p - e
    s = (d > m) ? "fast" : ((d < -m) ? "slow" : "ok")
    printf "%d %d %s\n", int(e + 0.5), (proj < 0) ? -1 : int(proj + 0.5), s
  }'
}

pace_icon() {
  case "$1" in
    fast) echo "▲" ;;
    slow) echo "▼" ;;
    *) echo "" ;;
  esac
}

# notify <message> <titre>
notify() {
  if [ -n "${CLAUDE_WATCH_NOTIFY_CMD:-}" ]; then
    "$CLAUDE_WATCH_NOTIFY_CMD" "$1" "$2"
  elif command -v osascript >/dev/null 2>&1; then
    osascript -e 'on run argv' \
      -e 'display notification (item 1 of argv) with title (item 2 of argv)' \
      -e 'end run' "$1" "$2" >/dev/null 2>&1
  fi
}

# check_alert <clé> <libellé> <pct entier> <resets_at>
# Une seule notification par seuil et par fenêtre.
check_alert() {
  local key=$1 label=$2 pct=$3 resets=$4 level=0 t prev_reset="" prev_level=0
  local file="$STATE_DIR/alert-$key"
  [ -n "$pct" ] || return 0
  for t in $CLAUDE_WATCH_THRESHOLDS; do
    [ "$pct" -ge "$t" ] && level=$t
  done
  [ "$level" -gt 0 ] || return 0
  [ -f "$file" ] && read -r prev_reset prev_level < "$file"
  if [ "$prev_reset" != "$resets" ] || [ "${prev_level:-0}" -lt "$level" ]; then
    echo "$resets $level" > "$file"
    notify "$label : $pct % consommés (reset $(fmt_epoch "$resets" '%a %H:%M'))" "Claude Watch"
  fi
}
