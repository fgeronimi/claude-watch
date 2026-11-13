#!/bin/bash
# Tests de bout en bout, sans macOS : caffeinate et les notifications sont simulés.
#   ./tests/run.sh

set -u
ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T=$(mktemp -d)
trap 'pkill -f "$T/bin/caffeinate" 2>/dev/null; rm -rf "$T"' EXIT

export HOME="$T/home"
export CLAUDE_WATCH_CONFIG=/dev/null
export CLAUDE_WATCH_STATE_DIR="$T/state"
export CLAUDE_WATCH_NOTIFY_CMD="$T/bin/notify"
export CLAUDE_WATCH_LOG_INTERVAL=0
export CLAUDE_WATCH_NOTIFY_AFTER=1
export CLAUDE_WATCH_COLOR=0
mkdir -p "$HOME/.claude" "$T/bin"

# Faux caffeinate : reste vivant sous le nom "caffeinate".
cat > "$T/bin/caffeinate" <<'EOF'
#!/bin/bash
trap 'kill $child 2>/dev/null; exit 0' TERM INT
sleep 600 &
child=$!
wait
EOF
cat > "$T/bin/notify" <<EOF
#!/bin/bash
echo "\$2 | \$1" >> "$T/notifications"
EOF
chmod +x "$T/bin/caffeinate" "$T/bin/notify"
export PATH="$T/bin:$PATH"

pass=0; fail=0
ok() { pass=$((pass + 1)); echo "  ok   $1"; }
ko() { fail=$((fail + 1)); echo "  KO   $1"; [ -n "${2:-}" ] && echo "       $2"; }
assert() { if eval "$2"; then ok "$1"; else ko "$1" "$2"; fi; }
contains() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
# Vivant et pas zombie (dans un conteneur, personne ne récolte les orphelins).
alive() { case "$(ps -p "$1" -o stat= 2>/dev/null)" in '' | Z*) return 1 ;; *) return 0 ;; esac; }

now=$(date +%s)
hook_json() { printf '{"session_id":"%s","cwd":"/Users/f/dev/%s"}' "$1" "$2"; }
status_json() { # <sid> <projet> <coût> <5h %> <7j %> [modèle]
  printf '{"session_id":"%s","cwd":"/Users/f/dev/%s","workspace":{"project_dir":"/Users/f/dev/%s"},
    "model":{"display_name":"%s"},"cost":{"total_cost_usd":%s},"context_window":{"used_percentage":42.6},
    "rate_limits":{"five_hour":{"used_percentage":%s,"resets_at":%s},
                   "seven_day":{"used_percentage":%s,"resets_at":%s}}}' \
    "$1" "$2" "$2" "${6:-Opus}" "$3" "$4" $((now + 9000)) "$5" $((now + 302400))
}
sql() { sqlite3 "$CLAUDE_WATCH_STATE_DIR/history.db" "$1"; }

echo "Hook awake"
out=$(hook_json s1 alpha | "$ROOT/hooks/awake.sh" start)
assert "start n'écrit rien sur stdout" '[ -z "$out" ]'
pid=$(cat "$T/state/awake-s1.pid")
assert "caffeinate lancé" 'alive "$pid"'
hook_json s2 beta | "$ROOT/hooks/awake.sh" start
assert "deux sessions actives" '[ "$("$ROOT/bin/claude-watch" status | head -1)" = "☕ 2 agent(s) en cours, veille bloquée" ]'
sleep 1.2
hook_json s1 alpha | "$ROOT/hooks/awake.sh" stop
sleep 0.3
assert "caffeinate arrêté au stop" '! alive "$pid"'
assert "fichier pid supprimé" '[ ! -f "$T/state/awake-s1.pid" ]'
assert "notification de fin de tour" 'grep -q "Agent terminé.*(alpha)" "$T/notifications"'
echo 999999 > "$T/state/awake-fantome.pid"
assert "pid périmé ignoré" '[ "$("$ROOT/bin/claude-watch" status | head -1)" = "☕ 1 agent(s) en cours, veille bloquée" ]'
rm -f "$T/state/awake-fantome.pid"

echo "Status line"
line=$(status_json s2 beta 0.50 34.7 61.2 | "$ROOT/statusline.sh")
assert "session active : point plein" 'contains "$line" "●"'
assert "pourcentages affichés" 'contains "$line" "5h 34%" && contains "$line" "7j 61%"'
assert "projet, modèle et contexte affichés" 'contains "$line" "beta  Opus  ctx 42%"'
line=$(status_json s1 alpha 1.00 35 61 | "$ROOT/statusline.sh")
assert "session inactive : cercle vide" 'contains "$line" "○"'
mkdir -p "$T/repo" && git -C "$T/repo" init -q -b ma-branche 2>/dev/null
line=$(printf '{"session_id":"s5","cwd":"%s","model":{"display_name":"Opus"},"rate_limits":{"five_hour":{"used_percentage":85,"resets_at":%s},"seven_day":{"used_percentage":10,"resets_at":%s}}}' "$T/repo" $((now + 5940)) $((now + 302400)) | "$ROOT/statusline.sh")
assert "branche git affichée" 'contains "$line" "repo  ma-branche  Opus"'
assert "reset affiché à partir de 80 %" 'contains "$line" "5h 85%▲ ↻1h39" || contains "$line" "5h 85%▲ ↻1h38"'
assert "pas de reset sous 80 %" '! contains "$line" "7j 10% ↻"'
colored=$(status_json s6 delta 0.10 35 61 | CLAUDE_WATCH_COLOR=1 "$ROOT/statusline.sh")
assert "couleurs ANSI activées par défaut" 'contains "$colored" "$(printf "\\033[32m")35%"'
assert "fichier quota écrit" '[ "$(cut -d" " -f2,4 "$T/state/quota")" = "35 61" ]'
line=$(printf '{"session_id":"s3","cwd":"/tmp/x","cost":{"total_cost_usd":0.1}}' | "$ROOT/statusline.sh")
assert "sans rate_limits : message dédié" 'contains "$line" "quotas indisponibles"'
status_json s4 "l'appli" 0.20 35 61 | "$ROOT/statusline.sh" >/dev/null
assert "apostrophe dans le chemin" '[ "$(sql "SELECT COUNT(*) FROM samples WHERE project LIKE \"%l'"'"'appli\";")" = 1 ]'

echo "Historique"
status_json s1 alpha 1.75 40 62 | "$ROOT/statusline.sh" >/dev/null
status_json s1 alpha 2.50 45 63 Sonnet | "$ROOT/statusline.sh" >/dev/null
assert "mesures enregistrées" '[ "$(sql "SELECT COUNT(*) FROM samples WHERE session_id = \"s1\";")" = 3 ]'
assert "coût = dernier cumul de la session" '[ "$(sql "SELECT SUM(cost_delta) FROM deltas WHERE session_id = \"s1\";")" = 2.5 ]'
report=$("$ROOT/bin/claude-watch" report)
assert "rapport par projet" 'contains "$report" "alpha" && contains "$report" "2.50"'
assert "rapport par modèle" 'contains "$report" "Sonnet"'
assert "historique par jour" 'contains "$("$ROOT/bin/claude-watch" history)" "$(date +%Y-%m-%d)"'

echo "Mise en attente"
export CLAUDE_WATCH_LOG_INTERVAL=3600
status_json s2 beta 0.90 45 63 | "$ROOT/statusline.sh" >/dev/null
assert "mesure retenue par l'intervalle" '[ -f "$T/state/pending-s2.sql" ]'
hook_json s2 beta | "$ROOT/hooks/awake.sh" end
assert "écrite en base par le hook" '[ "$(sql "SELECT MAX(cost_usd) FROM samples WHERE session_id = \"s2\";")" = 0.9 ]'
assert "état de session nettoyé" '[ ! -f "$T/state/awake-s2.pid" ] && [ ! -f "$T/state/log-s2.stamp" ]'
export CLAUDE_WATCH_LOG_INTERVAL=0

echo "Alertes"
: > "$T/notifications"
status_json s1 alpha 3 81 63 | "$ROOT/statusline.sh" >/dev/null; sleep 0.3
status_json s1 alpha 3 82 63 | "$ROOT/statusline.sh" >/dev/null; sleep 0.3
assert "une seule alerte à 80 %" '[ "$(grep -c "Session 5 h" "$T/notifications")" = 1 ]'
status_json s1 alpha 3 96 63 | "$ROOT/statusline.sh" >/dev/null; sleep 0.3
assert "nouvelle alerte à 95 %" '[ "$(grep -c "Session 5 h" "$T/notifications")" = 2 ]'
assert "pas d'alerte hebdo sous le seuil" '! grep -q "Semaine" "$T/notifications"'

echo "Rythme"
. "$ROOT/lib/common.sh"
assert "trop rapide" '[ "$(pace 65 $((now + 9000)) 18000 $now)" = "50 130 fast" ]'
assert "dans le rythme" '[ "$(pace 52 $((now + 9000)) 18000 $now)" = "50 104 ok" ]'
assert "de la marge" '[ "$(pace 20 $((now + 9000)) 18000 $now)" = "50 40 slow" ]'
assert "pas de projection en début de fenêtre" '[ "$(pace 4 $((now + 17500)) 18000 $now)" = "3 -1 ok" ]'

echo "Plugin SwiftBar"
# À ce stade : 96 % du quota 5 h consommés (reste 4 %, rouge), 63 % du quota 7 j.
menu=$("$ROOT/swiftbar/claude-watch.5s.sh")
title=$(echo "$menu" | head -1)
assert "titre : image en couleurs quand une batterie est rouge" 'contains "$title" " | image=iVBORw0KGgo"'
assert "titre : taille en points" 'contains "$title" " width=" && contains "$title" " height=20"'
assert "image mise en cache" '[ "$(sed -n 1p "$T/state/bar.cache")" = "v4 0 4 37 light 20 compact" ]'
assert "thème sombre suivi" 'contains "$(OS_APPEARANCE=Dark "$ROOT/swiftbar/claude-watch.5s.sh" | head -1)" "image=" && [ "$(sed -n 1p "$T/state/bar.cache")" = "v4 0 4 37 dark 20 compact" ]'
assert "jauges alignées" 'contains "$menu" "5 h  ▰▰▰▰▰▰▰▰▰▰   96 % utilisés" && contains "$menu" "7 j  ▰▰▰▰▰▰▱▱▱▱   63 % utilisés"'
assert "jauge : arrondi et bornes" '[ "$(gauge 0)" = "▱▱▱▱▱▱▱▱▱▱" ] && [ "$(gauge 3)" = "▰▱▱▱▱▱▱▱▱▱" ] && [ "$(gauge 34)" = "▰▰▰▱▱▱▱▱▱▱" ] && [ "$(gauge 100)" = "▰▰▰▰▰▰▰▰▰▰" ]'
assert "top projets" 'contains "$menu" "-- alpha : "'
assert "lignes d'information cliquables (non grisées)" 'contains "$menu" "veille normale | refresh=true"'
printf '%s 50 %s 70 %s\n' $((now - 20000)) $((now - 100)) $((now + 300000)) > "$T/state/quota"
menu=$("$ROOT/swiftbar/claude-watch.5s.sh")
assert "fenêtre 5 h expirée : batterie pleine" '[ "$(sed -n 1p "$T/state/bar.cache")" = "v4 0 100 30 template 20 compact" ] && contains "$menu" "fenêtre réinitialisée"'
assert "titre : image template sans rouge" 'contains "$(echo "$menu" | head -1)" " | templateImage=iVBORw0KGgo"'
assert "titre en texte sur demande" '[ "$(CLAUDE_WATCH_BAR_STYLE=text "$ROOT/swiftbar/claude-watch.5s.sh" | head -1)" = "0  100%·30%" ]'
rm -f "$T/state/quota"
assert "sans mesure : batteries vides" '[ "$(CLAUDE_WATCH_BAR_STYLE=text "$ROOT/swiftbar/claude-watch.5s.sh" | head -1)" = "0  -·-" ]'

echo "Compatibilité bash 3.2 (macOS)"
# En locale UTF-8, bash 3.2 lit "$var▰" comme une variable au nom prolongé par le début
# du caractère : la sortie devient de l'UTF-8 invalide et SwiftBar masque le plugin.
assert "aucune variable collée à un caractère non ASCII" '! grep -nP "\\\$[A-Za-z_][A-Za-z0-9_]*[^\\x00-\\x7F]" "$ROOT"/lib/*.sh "$ROOT"/hooks/*.sh "$ROOT"/statusline.sh "$ROOT"/swiftbar/*.sh "$ROOT"/bin/claude-watch "$ROOT"/install.sh "$ROOT"/uninstall.sh'
status_json s1 alpha 3 34 61 | "$ROOT/statusline.sh" >/dev/null
assert "sortie du menu en UTF-8 valide" '"$ROOT/swiftbar/claude-watch.5s.sh" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1'
assert "sortie de la status line en UTF-8 valide" 'status_json s1 alpha 3 34 61 | CLAUDE_WATCH_COLOR=1 "$ROOT/statusline.sh" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1'
assert "sortie de la CLI en UTF-8 valide" '"$ROOT/bin/claude-watch" status | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1'

echo "Rendu de l'icône"
png="$T/icone.png"
"$ROOT/lib/render_bar.py" 2 66 39 dark | cut -d" " -f3 | base64 -d > "$png" 2>/dev/null
assert "PNG valide" '[ "$(head -c 8 "$png" | od -An -c | tr -d " ")" = "211PNG\\r\\n032\\n" ]'
assert "compact par défaut : deux lignes, étroit" '[ "$("$ROOT/lib/render_bar.py" 2 66 39 dark | cut -d" " -f1,2)" = "51 20" ]'
assert "disposition large sur une ligne" '[ "$("$ROOT/lib/render_bar.py" 2 66 39 dark 20 wide | cut -d" " -f1,2)" = "121 16" ]'
assert "compact : au plus 60 points même au plus large" '[ "$("$ROOT/lib/render_bar.py" 12 100 100 template | cut -d" " -f1)" -le 60 ]'
assert "style wide transmis par le plugin" 'contains "$(CLAUDE_WATCH_BAR_STYLE=wide "$ROOT/swiftbar/claude-watch.5s.sh" | head -1)" " height=16"'
assert "base64 sans = final, quel que soit le contenu" '! { for l in compact wide; do for a in 0 1 2 12; do for p in 0 7 33 66 100; do "$ROOT/lib/render_bar.py" $a $p $((100 - p)) dark 20 $l; done; done; done; } | grep -q "="'
assert "titre non vide devant l'image" '[ "$("$ROOT/swiftbar/claude-watch.5s.sh" | head -1 | cut -d"|" -f1 | od -An -tx1 | tr -d " \\n")" = "e2808b200a" ]'
assert "arguments invalides refusés" '! "$ROOT/lib/render_bar.py" 2 66 39 rose >/dev/null 2>&1'

echo "Installation"
cat > "$HOME/.claude/settings.json" <<'EOF'
{"model":"opus",
 "hooks":{"Stop":[{"hooks":[{"type":"command","command":"say fini"}]},
                  {"hooks":[{"type":"command","command":"~/.claude/hooks/awake.sh stop"}]}]},
 "statusLine":{"type":"command","command":"~/autre.sh"}}
EOF
"$ROOT/install.sh" > "$T/install.log" 2>&1
s="$HOME/.claude/settings.json"
assert "réglages existants conservés" '[ "$(jq -r .model "$s")" = opus ]'
assert "hook tiers conservé" 'jq -e ".hooks.Stop | map(.hooks[].command) | index(\"say fini\")" "$s" >/dev/null'
assert "ancien hook manuel retiré" '! grep -q "~/.claude/hooks/awake.sh" "$s"'
assert "trois hooks ajoutés" '[ "$(grep -c "claude-watch/hooks/awake.sh" "$s")" = 3 ]'
assert "status line tierce non remplacée" '[ "$(jq -r .statusLine.command "$s")" = "~/autre.sh" ]'
assert "avertissement affiché" 'grep -q -- "--force" "$T/install.log"'
"$ROOT/install.sh" --force >/dev/null 2>&1
"$ROOT/install.sh" >/dev/null 2>&1
assert "status line remplacée avec --force" 'jq -e ".statusLine.command | contains(\"claude-watch/statusline.sh\")" "$s" >/dev/null'
assert "réinstallation sans doublon" '[ "$(grep -c "claude-watch/hooks/awake.sh" "$s")" = 3 ]'
line=$(status_json s9 gamma 0.1 12 30 | "$HOME/.claude/claude-watch/statusline.sh")
assert "status line utilisable via le lien" 'contains "$line" "5h 12%"'
out=$(hook_json s9 gamma | bash -c "$(jq -r ".hooks.UserPromptSubmit[0].hooks[0].command" "$s")")
assert "commande du hook exécutable telle quelle" '[ -f "$T/state/awake-s9.pid" ]'
"$ROOT/uninstall.sh" >/dev/null 2>&1
assert "désinstallation : hooks retirés" '! grep -q "claude-watch" "$s"'
assert "désinstallation : hook tiers conservé" 'jq -e ".hooks.Stop[0].hooks[0].command == \"say fini\"" "$s" >/dev/null'
assert "désinstallation : caffeinate arrêté" '[ ! -f "$T/state/awake-s9.pid" ]'
assert "désinstallation : historique conservé" '[ -f "$T/state/history.db" ]'

echo
echo "$pass réussis, $fail en échec"
[ "$fail" -eq 0 ]
