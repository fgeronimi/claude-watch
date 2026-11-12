#!/bin/bash
# <swiftbar.title>Claude Watch</swiftbar.title>
# <swiftbar.desc>Agents Claude Code actifs, veille bloquée et quotas</swiftbar.desc>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>

src="${BASH_SOURCE[0]}"
while [ -L "$src" ]; do
  dir="$(cd -P "$(dirname "$src")" && pwd)"
  src="$(readlink "$src")"
  case "$src" in /*) ;; *) src="$dir/$src" ;; esac
done
ROOT="$(cd -P "$(dirname "$src")/.." && pwd)"
# shellcheck source=../lib/common.sh
. "$ROOT/lib/common.sh"

ts=$(now)
active=$(active_count)
if [ "$active" -gt 0 ]; then icon="☕$active"; else icon="💤"; fi

# describe <libellé> <pct> <resets_at> <durée fenêtre> : lignes du menu déroulant
describe() {
  local label=$1 pct=$2 resets=$3 len=$4 elapsed proj state
  read -r elapsed proj state <<<"$(pace "$pct" "$resets" "$len" "$ts")"
  echo "$label : $pct % — reset $(fmt_epoch "$resets" '%a %H:%M') (dans $(human_duration $((resets - ts))))"
  case "$state" in
    fast) echo "-- Trop rapide : $pct % consommés pour $elapsed % de la fenêtre | color=orange" ;;
    slow) echo "-- De la marge : $pct % consommés pour $elapsed % de la fenêtre" ;;
    *) echo "-- Dans le rythme : $pct % consommés pour $elapsed % de la fenêtre" ;;
  esac
  [ "$proj" -ge 0 ] && echo "-- Projection au reset : $proj %"
}

quota="$STATE_DIR/quota"
if [ -f "$quota" ]; then
  read -r q_ts five five_reset seven seven_reset < "$quota"

  # Fenêtre déjà réinitialisée depuis la dernière mesure : le compteur est reparti de zéro.
  five_stale=0; seven_stale=0
  [ "$five_reset" -le "$ts" ] && { five=0; five_stale=1; }
  [ "$seven_reset" -le "$ts" ] && { seven=0; seven_stale=1; }

  read -r _ _ five_state <<<"$(pace "$five" "$five_reset" "$FIVE_LEN" "$ts")"
  read -r _ _ seven_state <<<"$(pace "$seven" "$seven_reset" "$SEVEN_LEN" "$ts")"
  [ "$five_stale" = 1 ] && five_state=ok
  [ "$seven_stale" = 1 ] && seven_state=ok

  color=""
  if [ "$five" -ge 95 ] || [ "$seven" -ge 95 ]; then color=" | color=red"
  elif [ "$five" -ge 80 ] || [ "$seven" -ge 80 ]; then color=" | color=orange"
  fi

  echo "$icon $five%$(pace_icon "$five_state") · $seven%$(pace_icon "$seven_state")$color"
  echo "---"
  if [ "$five_stale" = 1 ]; then
    echo "Session 5 h : fenêtre réinitialisée, pas encore de nouvelle mesure"
  else
    describe "Session 5 h" "$five" "$five_reset" "$FIVE_LEN"
  fi
  if [ "$seven_stale" = 1 ]; then
    echo "Semaine : fenêtre réinitialisée, pas encore de nouvelle mesure"
  else
    describe "Semaine" "$seven" "$seven_reset" "$SEVEN_LEN"
  fi
  echo "Mesure d'il y a $(human_duration $((ts - q_ts))) | color=gray"
else
  echo "$icon"
  echo "---"
  echo "Pas encore de données de quota"
  echo "-- Elles arrivent après la première réponse d'une session Claude Code"
fi

echo "---"
if [ "$active" -gt 0 ]; then
  echo "$active agent(s) en cours, veille bloquée"
else
  echo "Aucun agent actif, veille normale"
fi

if [ -f "$DB" ]; then
  midnight="CAST(strftime('%s','now','localtime','start of day','utc') AS INTEGER)"
  today=$(db "SELECT printf('%.2f', COALESCE(SUM(cost_delta), 0)) FROM deltas WHERE ts >= $midnight;" 2>/dev/null)
  echo "---"
  echo "Aujourd'hui : ${today:-0.00} \$ (équivalent API)"
  echo "Top projets sur 7 jours"
  db -separator ' : ' "SELECT replace(COALESCE(NULLIF(replace(project, rtrim(project, replace(project, '/', '')), ''), ''), '?'), '|', '/'),
                               printf('%.2f \$', SUM(cost_delta))
                        FROM deltas WHERE ts >= $ts - 604800
                        GROUP BY project ORDER BY SUM(cost_delta) DESC LIMIT 5;" 2>/dev/null \
    | sed 's/^/-- /'
fi

echo "---"
echo "Rapport détaillé | bash='$ROOT/bin/claude-watch' param1=report terminal=true"
echo "Historique par jour | bash='$ROOT/bin/claude-watch' param1=history terminal=true"
echo "Rafraîchir | refresh=true"
