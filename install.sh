#!/usr/bin/env bash
# Install (or upgrade) the Claude Usage plasmoid and its polling daemon.
#
#   ./install.sh              install/upgrade widget + daemon
#   ./install.sh --no-daemon  install/upgrade the widget only (degraded mode)
#
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ID="org.sircanada.claudeusage"
WANT_DAEMON=1

for arg in "$@"; do
    case "$arg" in
        --no-daemon) WANT_DAEMON=0 ;;
        -h|--help)
            grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

# --- Preflight ---------------------------------------------------------------
need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found. $2" >&2; exit 1; }; }
need python3      "Install python3."
need kpackagetool6 "Install it (usually in the 'plasma-sdk' or 'plasma-workspace' package)."
need systemctl    "A systemd user session is required."

if [ ! -f "$HOME/.claude/.credentials.json" ]; then
    echo "WARNING: ~/.claude/.credentials.json not found."
    echo "         Install Claude Code and sign in (run 'claude') — until then the"
    echo "         widget will show 'Not signed in'."
fi

# --- Plasmoid ----------------------------------------------------------------
if [ -d "$HOME/.local/share/plasma/plasmoids/$PLUGIN_ID" ]; then
    echo "Upgrading plasmoid $PLUGIN_ID ..."
    kpackagetool6 --type Plasma/Applet --upgrade "$DIR/package"
else
    echo "Installing plasmoid $PLUGIN_ID ..."
    kpackagetool6 --type Plasma/Applet --install "$DIR/package"
fi

# --- Daemon ------------------------------------------------------------------
if [ "$WANT_DAEMON" -eq 1 ]; then
    echo "Installing daemon ..."
    # The two data dirs must exist before the unit starts: its ProtectSystem=strict
    # + ReadWritePaths sandbox fails to build the namespace if they are missing.
    mkdir -p "$HOME/.local/share/claude-usage-daemon" \
             "$HOME/.local/share/claude-usage" \
             "$HOME/.cache/claude-usage" \
             "$HOME/.config/systemd/user"
    install -m 0755 "$DIR/daemon/daemon.py" "$HOME/.local/share/claude-usage-daemon/daemon.py"
    install -m 0644 "$DIR/daemon/claude-usage-daemon.service" "$HOME/.config/systemd/user/claude-usage-daemon.service"
    systemctl --user daemon-reload
    systemctl --user enable --now claude-usage-daemon.service
    systemctl --user try-restart claude-usage-daemon.service
    echo "Daemon active: $(systemctl --user is-active claude-usage-daemon.service)"
else
    echo "Skipping daemon (--no-daemon). The widget will fetch usage directly on"
    echo "each refresh; this hits the rate-limited endpoint more often and keeps no history."
fi

# --- Next steps --------------------------------------------------------------
cat <<'EOF'

Done.

  • Add the widget: right-click a panel or the desktop → "Add Widgets…" → "Claude Usage".
  • If you just UPGRADED an already-placed widget, Plasma caches the old QML.
    Load the new version with:

        systemctl --user restart plasma-plasmashell.service

EOF
