#!/usr/bin/env bash
# Remove the Claude Usage plasmoid and daemon.
#
#   ./uninstall.sh           remove widget + daemon, keep logged usage data
#   ./uninstall.sh --purge    also delete the cache and SQLite usage history
#
set -euo pipefail

PLUGIN_ID="org.sircanada.claudeusage"
PURGE=0

for arg in "$@"; do
    case "$arg" in
        --purge) PURGE=1 ;;
        -h|--help)
            grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

echo "Stopping daemon ..."
systemctl --user disable --now claude-usage-daemon.service 2>/dev/null || true
rm -f "$HOME/.config/systemd/user/claude-usage-daemon.service"
systemctl --user daemon-reload 2>/dev/null || true

# Remove only the file we installed — the directory may hold other tools.
rm -f "$HOME/.local/share/claude-usage-daemon/daemon.py"
rmdir "$HOME/.local/share/claude-usage-daemon" 2>/dev/null || true

echo "Removing plasmoid ..."
kpackagetool6 --type Plasma/Applet --remove "$PLUGIN_ID" 2>/dev/null || true

if [ "$PURGE" -eq 1 ]; then
    echo "Purging usage data ..."
    rm -rf "$HOME/.cache/claude-usage" "$HOME/.local/share/claude-usage"
else
    echo "Kept your usage data:"
    echo "  ~/.cache/claude-usage/"
    echo "  ~/.local/share/claude-usage/   (usage.db)"
    echo "Delete it with:  ./uninstall.sh --purge"
fi

echo "Note: your Claude Code login (~/.claude/) was not touched."
echo "Done. Remove the widget from your panel if it is still shown."
