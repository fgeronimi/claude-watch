#!/bin/bash
# <swiftbar.title>Claude Watch</swiftbar.title>
# <swiftbar.desc>Agents Claude Code actifs, veille bloquée et quotas</swiftbar.desc>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
#
# Plugin SwiftBar, rafraîchi toutes les 5 secondes. Ce fichier ne fait que lancer
# lib/menu.sh : il n'a pas à changer quand l'affichage évolue.

src="${BASH_SOURCE[0]}"
while [ -L "$src" ]; do
  dir="$(cd -P "$(dirname "$src")" && pwd)"
  src="$(readlink "$src")"
  case "$src" in /*) ;; *) src="$dir/$src" ;; esac
done
exec /bin/bash "$(cd -P "$(dirname "$src")/.." && pwd)/lib/menu.sh"
