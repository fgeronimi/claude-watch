#!/bin/bash
# Contenu de la barre de menus : titre (agents et batteries) et menu déroulant.
# Lancé par swiftbar/claude-watch.5s.sh ; peut aussi s'exécuter seul pour voir la sortie.

src="${BASH_SOURCE[0]}"
while [ -L "$src" ]; do
  dir="$(cd -P "$(dirname "$src")" && pwd)"
  src="$(readlink "$src")"
  case "$src" in /*) ;; *) src="$dir/$src" ;; esac
done
ROOT="$(cd -P "$(dirname "$src")/.." && pwd)"
# --- DIAGNOSTIC TEMPORAIRE : sous SwiftBar, enregistre la sortie, les erreurs et
# l'environnement dans .debug/ pour comprendre pourquoi l'élément ne s'affiche pas. ---
if [ -n "${SWIFTBAR:-}" ] && [ -z "${CW_DEBUG_CHILD:-}" ]; then
  d="$ROOT/.debug"
  mkdir -p "$d"
  CW_DEBUG_CHILD=1 /bin/bash "$ROOT/lib/menu.sh" > "$d/out" 2> "$d/err"
  code=$?
  {
    echo "date=$(date '+%F %T') exit=$code"
    echo "bash=$BASH_VERSION"
    for v in PATH HOME LANG LC_ALL LC_CTYPE TMPDIR SHELL OS_APPEARANCE OS_VERSION_MAJOR SWIFTBAR SWIFTBAR_VERSION SWIFTBAR_BUILD SWIFTBAR_PLUGIN_PATH SWIFTBAR_PLUGIN_REFRESH_REASON; do
      eval "echo \"$v=\${$v-<absent>}\""
    done
    echo "python3=$(command -v python3)"
  } > "$d/env" 2>&1
  cat "$d/out"
  exit $code
fi

# shellcheck source=../lib/common.sh
. "$ROOT/lib/common.sh"

# SwiftBar grise les lignes sans action : on leur en donne une (un clic rafraîchit)
# pour qu'elles s'affichent dans la couleur normale du menu.
ON=" refresh=true"

ts=$(now)
active=$(active_count)

# bar_title <% restant 5 h|-> <% restant 7 j|->
# Titre de la barre de menus : nombre d'agents, puis deux batteries 5H et 7J avec le
# pourcentage de quota restant. L'image est mise en cache tant que rien ne change.
# Styles : compact (deux lignes, étroit), wide (une ligne), text (sans image).
# Un élément trop large est masqué sans prévenir par macOS quand la barre est pleine.
bar_title() {
  local five_left=$1 seven_left=$2 mode=template param=templateImage
  local cache="$STATE_DIR/bar.cache" key out="" w h b64 v layout=compact
  [ "$CLAUDE_WATCH_BAR_STYLE" = wide ] && layout=wide

  # Tant que rien n'est rouge, une image « template » prend d'elle-même la couleur
  # de la barre. Avec du rouge, il faut une image en couleurs, donc choisir un thème.
  for v in "$five_left" "$seven_left"; do
    if [ "$v" != "-" ] && [ "$v" -le "$CLAUDE_WATCH_LOW" ]; then
      param=image
      mode=$CLAUDE_WATCH_BAR_THEME
      [ "$mode" = auto ] && mode=${OS_APPEARANCE:-$(defaults read -g AppleInterfaceStyle 2>/dev/null || echo Light)}
      case "$mode" in [Dd]ark) mode=dark ;; *) mode=light ;; esac
    fi
  done

  if [ "$CLAUDE_WATCH_BAR_STYLE" != text ] && command -v python3 >/dev/null 2>&1; then
    key="v4 $active $five_left $seven_left $mode $CLAUDE_WATCH_LOW $layout"
    if [ -f "$cache" ] && [ "$(sed -n 1p "$cache")" = "$key" ]; then
      out=$(sed -n 2p "$cache")
    else
      out=$(python3 "$ROOT/lib/render_bar.py" "$active" "$five_left" "$seven_left" "$mode" "$CLAUDE_WATCH_LOW" "$layout" 2>/dev/null) || out=""
      if [ -n "$out" ]; then
        mkdir -p "$STATE_DIR"
        printf '%s\n%s\n' "$key" "$out" > "$cache.tmp.$$" && mv "$cache.tmp.$$" "$cache"
      fi
    fi
  fi

  if [ -n "$out" ]; then
    read -r w h b64 <<<"$out"
    # Titre invisible (espace sans chasse) : un titre vide ferait passer l'élément pour absent.
    printf '\342\200\213 | %s=%s width=%s height=%s\n' "$param" "$b64" "$w" "$h"
  else
    # Secours en texte : pas de python3, ou style « text » demandé.
    [ "$five_left" = "-" ] || five_left="$five_left%"
    [ "$seven_left" = "-" ] || seven_left="$seven_left%"
    echo "$active  ${five_left}·${seven_left}"
  fi
}

# quota_line <libellé> <pct> <resets_at> <durée fenêtre>
# Une ligne à jauge, en police à chasse fixe pour que les deux fenêtres s'alignent,
# et le détail en sous-menu.
quota_line() {
  local label=$1 pct=$2 resets=$3 len=$4 elapsed proj state color=""
  read -r elapsed proj state <<<"$(pace "$pct" "$resets" "$len" "$ts")"
  if [ "$pct" -ge 95 ]; then color=" color=red"
  elif [ "$pct" -ge 80 ]; then color=" color=orange"
  fi
  printf '%s  %s  %3s %% utilisés   reset dans %s | font=Menlo size=12%s\n' \
    "$label" "$(gauge "$pct")" "$pct" "$(human_duration $((resets - ts)))" "$color$ON"
  echo "-- Reset : $(fmt_epoch "$resets" '%A %H:%M') |$ON"
  case "$state" in
    fast) echo "-- Trop rapide : $pct % consommés pour $elapsed % de la fenêtre | color=orange$ON" ;;
    slow) echo "-- De la marge : $pct % consommés pour $elapsed % de la fenêtre |$ON" ;;
    *) echo "-- Dans le rythme : $pct % consommés pour $elapsed % de la fenêtre |$ON" ;;
  esac
  [ "$proj" -ge 0 ] && echo "-- Projection au reset : $proj % |$ON"
}

quota="$STATE_DIR/quota"
if [ -f "$quota" ]; then
  read -r q_ts five five_reset seven seven_reset < "$quota"

  # Fenêtre déjà réinitialisée depuis la dernière mesure : le compteur est reparti de zéro.
  five_stale=0; seven_stale=0
  [ "$five_reset" -le "$ts" ] && { five=0; five_stale=1; }
  [ "$seven_reset" -le "$ts" ] && { seven=0; seven_stale=1; }

  bar_title $((100 - five)) $((100 - seven))
  echo "---"
  if [ "$five_stale" = 1 ]; then
    echo "5 h  fenêtre réinitialisée, pas encore de nouvelle mesure | font=Menlo size=12$ON"
  else
    quota_line "5 h" "$five" "$five_reset" "$FIVE_LEN"
  fi
  if [ "$seven_stale" = 1 ]; then
    echo "7 j  fenêtre réinitialisée, pas encore de nouvelle mesure | font=Menlo size=12$ON"
  else
    quota_line "7 j" "$seven" "$seven_reset" "$SEVEN_LEN"
  fi
  echo "Mesure d'il y a $(human_duration $((ts - q_ts))) | color=gray"
else
  bar_title - -
  echo "---"
  echo "Pas encore de données de quota |$ON"
  echo "-- Elles arrivent après la première réponse d'une session Claude Code |$ON"
fi

echo "---"
if [ "$active" -gt 0 ]; then
  echo "$active agent(s) en cours, veille bloquée |$ON"
else
  echo "Aucun agent actif, veille normale |$ON"
fi

if [ -f "$DB" ]; then
  midnight="CAST(strftime('%s','now','localtime','start of day','utc') AS INTEGER)"
  today=$(db "SELECT printf('%.2f', COALESCE(SUM(cost_delta), 0)) FROM deltas WHERE ts >= $midnight;" 2>/dev/null)
  echo "---"
  echo "Aujourd'hui : ${today:-0.00} \$ (équivalent API) |$ON"
  echo "Top projets sur 7 jours |$ON"
  db -separator ' : ' "SELECT replace(COALESCE(NULLIF(replace(project, rtrim(project, replace(project, '/', '')), ''), ''), '?'), '|', '/'),
                               printf('%.2f \$', SUM(cost_delta))
                        FROM deltas WHERE ts >= $ts - 604800
                        GROUP BY project ORDER BY SUM(cost_delta) DESC LIMIT 5;" 2>/dev/null \
    | sed -e 's/^/-- /' -e "s/\$/ |$ON/"
fi

echo "---"
echo "Rapport détaillé | bash='$ROOT/bin/claude-watch' param1=report terminal=true"
echo "Historique par jour | bash='$ROOT/bin/claude-watch' param1=history terminal=true"
echo "Rafraîchir | refresh=true"
