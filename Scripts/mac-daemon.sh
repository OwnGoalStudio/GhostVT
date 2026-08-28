#!/bin/bash
# Loads or unloads ighostvtd as a per-user LaunchAgent for the Mac Catalyst
# harness (see AGENTS.md, "make mac-run").
#
#   mac-daemon.sh install <daemon-binary> <plist-template>
#   mac-daemon.sh uninstall
set -euo pipefail

label="wiki.qaq.ighostvtd"
domain="gui/$(id -u)"
install_path="$HOME/Library/LaunchAgents/$label.plist"

case "${1:-}" in
install)
    daemon="${2:?usage: $0 install <daemon-binary> <plist-template>}"
    template="${3:?usage: $0 install <daemon-binary> <plist-template>}"
    test -x "$daemon" || { echo "error: $daemon was not built" >&2; exit 66; }
    mkdir -p "$(dirname "$install_path")"
    launchctl bootout "$domain/$label" 2>/dev/null || true
    sed -e "s|@DAEMON@|$daemon|g" "$template" >"$install_path"
    plutil -lint "$install_path" >/dev/null
    launchctl bootstrap "$domain" "$install_path"
    echo "$label loaded in $domain; log: ~/Library/Logs/ighostvtd.log"
    ;;
uninstall)
    launchctl bootout "$domain/$label" 2>/dev/null || true
    rm -f "$install_path"
    echo "$label LaunchAgent removed"
    ;;
*)
    echo "usage: $0 install <daemon-binary> <plist-template> | uninstall" >&2
    exit 64
    ;;
esac
