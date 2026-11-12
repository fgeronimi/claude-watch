#!/bin/bash
# Hook Claude Code : empêche la mise en veille pendant que l'agent travaille.
#   awake.sh start   (UserPromptSubmit) lance caffeinate
#   awake.sh stop    (Stop)             l'arrête, notifie si le tour a été long
#   awake.sh end     (SessionEnd)       l'arrête et nettoie l'état de la session
#
# Ne rien écrire sur stdout : la sortie d'un hook UserPromptSubmit est injectée
# dans le contexte de Claude.

src="${BASH_SOURCE[0]}"
while [ -L "$src" ]; do
  dir="$(cd -P "$(dirname "$src")" && pwd)"
  src="$(readlink "$src")"
  case "$src" in /*) ;; *) src="$dir/$src" ;; esac
done
ROOT="$(cd -P "$(dirname "$src")/.." && pwd)"
# shellcheck source=../lib/common.sh
. "$ROOT/lib/common.sh"

action="${1:-}"
[ -t 0 ] && { echo "usage : awake.sh start|stop|end (JSON du hook sur stdin)" >&2; exit 1; }
input=$(cat)

sid=$(jq -r '.session_id // empty' <<<"$input" 2>/dev/null | tr -cd 'A-Za-z0-9_-')
[ -n "$sid" ] || exit 0
project=$(basename "$(jq -r '.cwd // empty' <<<"$input" 2>/dev/null)" 2>/dev/null)

mkdir -p "$STATE_DIR"
pidf="$STATE_DIR/awake-$sid.pid"
startf="$STATE_DIR/awake-$sid.start"

stop_caffeinate() {
  local pid
  if [ -f "$pidf" ]; then
    pid=$(cat "$pidf" 2>/dev/null)
    if is_caffeinate "$pid"; then kill "$pid" 2>/dev/null; fi
    rm -f "$pidf"
  fi
}

case "$action" in
  start)
    stop_caffeinate
    # shellcheck disable=SC2086
    nohup caffeinate $CLAUDE_WATCH_CAFFEINATE_FLAGS -t "$CLAUDE_WATCH_MAX_SECONDS" >/dev/null 2>&1 &
    echo $! > "$pidf"
    now > "$startf"
    flush_pending
    ;;
  stop)
    if [ -f "$startf" ] && [ "$CLAUDE_WATCH_NOTIFY_AFTER" -gt 0 ]; then
      dur=$(( $(now) - $(cat "$startf") ))
      if [ "$dur" -ge "$CLAUDE_WATCH_NOTIFY_AFTER" ]; then
        notify "Agent terminé après $(human_duration "$dur")${project:+ ($project)}" "Claude Watch" &
      fi
    fi
    rm -f "$startf"
    stop_caffeinate
    flush_pending
    ;;
  end)
    rm -f "$startf"
    stop_caffeinate
    flush_pending
    rm -f "$STATE_DIR/log-$sid.stamp"
    ;;
  *)
    echo "usage : awake.sh start|stop|end" >&2
    exit 1
    ;;
esac >/dev/null

exit 0
