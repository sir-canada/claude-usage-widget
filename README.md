# Claude Usage — KDE Plasma 6 widget

A system-tray widget for KDE Plasma 6 that shows your Claude subscription usage
at a glance: the **5-hour session window**, the **weekly** limit, and the
**weekly model-scoped** limit — each with a live countdown to when it resets.

The panel icon shows your 5-hour usage percentage (green → amber → red) and, when
you get close to the limit, a battery-style fill bar and an attention badge.
Hover it for a popup with every limit and its reset time.

![panel](screenshots/panel.png)
![popup](screenshots/popup.png)

> Screenshots not added yet — capture the tray icon and the hover popup with
> Spectacle and drop them in `screenshots/` as `panel.png` and `popup.png`.

## Requirements

- **KDE Plasma 6** (the widget uses KF6 APIs; it will not run on Plasma 5)
- **python3** (standard library only — no pip packages)
- A **systemd user session** (for the background daemon)
- A signed-in **[Claude Code](https://claude.com/claude-code)** install with a
  Pro or Max subscription — the widget reads usage for that account

## Install

```sh
git clone https://github.com/sir-canada/claude-usage-widget.git
cd claude-usage-widget
./install.sh
```

Then add it to a panel: right-click the panel → **Add Widgets…** → **Claude Usage**.

To **upgrade** later, `git pull` and run `./install.sh` again. If the widget was
already on your panel, Plasma caches the old code — reload it with
`systemctl --user restart plasma-plasmashell.service`.

**Widget-only mode:** `./install.sh --no-daemon` installs just the widget. It
works, but without the daemon the widget queries the usage endpoint directly on
every refresh (hitting rate limits more often) and keeps no history. The daemon
is recommended.

## Uninstall

```sh
./uninstall.sh          # remove widget + daemon, keep your logged data
./uninstall.sh --purge  # also delete the cache and usage history
```

## How it works

- A small **daemon** (`daemon/daemon.py`, run as a systemd user service) polls
  Claude's usage endpoint every 60 seconds (configurable via the
  `CLAUDE_USAGE_POLL` env var; it backs off to 600 s if the endpoint rate-limits
  it) and writes the result to `~/.cache/claude-usage/latest.json`.
- The **widget** never touches the network. Every few seconds it just reads that
  cache file, so a single poller feeds the display and you never double up on
  requests.
- The daemon also records each usage sample and per-message token counts (parsed
  from your local Claude Code transcripts in `~/.claude/projects/`) into a SQLite
  database at `~/.local/share/claude-usage/usage.db`, so you can analyze your
  own history offline.

## Configuration

Right-click the widget → **Configure…**:

- Append a **`%` sign** after the panel number
- Show the **time remaining** in the 5-hour window in the panel
- Show the **weekly** limit in the popup
- Show the **weekly model-scoped** limit in the popup
- **Refresh interval** in seconds (minimum 15)

## Privacy & security

- The only network destination is **`https://api.anthropic.com`** — Anthropic's
  own usage endpoint. Nothing is sent anywhere else.
- Authentication reuses the OAuth token **Claude Code already stores** in
  `~/.claude/.credentials.json`. It is read **read-only**, never printed, and
  never copied elsewhere.
- The token is **never refreshed or rotated** — doing so could invalidate your
  Claude Code login. If the token expires, the widget simply shows the last
  cached numbers until you next use Claude Code (which refreshes it).
- All logged data stays on your machine.

## Disclaimer

This is an unofficial project and is **not affiliated with Anthropic**. It reads
`api.anthropic.com/api/oauth/usage` (with the beta header
`anthropic-beta: oauth-2025-04-20`), which is **undocumented** and may change or
stop working at any time.

## License

[MIT](LICENSE)
