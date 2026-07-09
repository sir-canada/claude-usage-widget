#!/usr/bin/env bash
# Install (or upgrade) the Claude Usage plasmoid and its polling daemon.
#
# One-line install (downloads the repo, then runs this):
#   curl -fsSL https://raw.githubusercontent.com/sir-canada/claude-usage-widget/main/install.sh | bash
#   curl -fsSL .../install.sh | bash -s -- --no-daemon   # widget only
#
# From a checkout:
#   ./install.sh              install/upgrade widget + daemon
#   ./install.sh --no-daemon  install/upgrade the widget only (degraded mode)
#
set -euo pipefail

REPO_TARBALL="https://github.com/sir-canada/claude-usage-widget/archive/refs/heads/main.tar.gz"
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

# --- Locate the payload ------------------------------------------------------
# When run from a checkout, the package/ and daemon/ dirs sit next to this
# script. When piped from curl (curl ... | bash) there are no local files, so
# download the repo tarball into a temp dir and continue from there.
SELF="${BASH_SOURCE[0]:-}"
if [ -n "$SELF" ] && [ -f "$SELF" ]; then
    DIR="$(cd "$(dirname "$SELF")" && pwd)"
else
    DIR=""
fi

if [ -z "$DIR" ] || [ ! -d "$DIR/package" ]; then
    echo "Downloading claude-usage-widget ..."
    command -v tar >/dev/null 2>&1 || { echo "ERROR: 'tar' is required." >&2; exit 1; }
    fetch() {
        if command -v curl >/dev/null 2>&1; then curl -fsSL "$1"
        elif command -v wget >/dev/null 2>&1; then wget -qO- "$1"
        else echo "ERROR: need 'curl' or 'wget' to download." >&2; exit 1; fi
    }
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    fetch "$REPO_TARBALL" | tar -xz -C "$TMP"
    DIR="$(echo "$TMP"/claude-usage-widget-*)"
    [ -d "$DIR/package" ] || { echo "ERROR: download looks incomplete (no package/)." >&2; exit 1; }
fi

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
