#!/usr/bin/env python3
"""Widget-facing reader. Prints one normalized JSON line (same shape as
fetch-usage.py) and NEVER touches the network.

The claude-usage-daemon is the only thing that polls the API; it writes
latest.json. The widget just reflects that file. Crucially we serve it
*however old it is* — a stale-but-real number beats hitting the rate-limited
endpoint ourselves (doing so used to make a second caller that kept the daemon
throttled, freezing the data). We only fall back to a one-off direct fetch if
latest.json is entirely absent (daemon never installed/ran)."""
import json, os, subprocess, sys, time

HOME = os.path.expanduser("~")
LATEST = os.path.join(HOME, ".cache", "claude-usage", "latest.json")
FETCH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fetch-usage.py")
# Past this the widget footer says "updated Xm ago" but the data is still shown.
# Daemon polls every ~110s (endpoint allows ~3 req/300s); 250s tolerates one
# delayed poll without flagging stale.
FRESH_SEC = 250


def recompute_resets(obj):
    now = time.time()
    for it in obj.get("items", []):
        if it.get("resets_epoch"):
            it["resets_in_sec"] = max(0, int(it["resets_epoch"] - now))
    return obj


def main():
    # Preferred path: reflect the daemon's file, always. No network.
    try:
        age = time.time() - os.path.getmtime(LATEST)
        with open(LATEST) as f:
            obj = json.load(f)
        obj = recompute_resets(obj)
        # Fresh: show as live. Stale: keep the numbers but flag age so the
        # footer reads "updated Xm ago"; don't invent an error.
        obj["stale"] = age > FRESH_SEC
        if age > FRESH_SEC and obj.get("state") == "ok":
            obj["state"] = "ok"  # still the last-known-good; footer shows age
        sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\n")
        return
    except Exception:
        pass

    # Fallback only if the daemon file doesn't exist at all.
    try:
        out = subprocess.run([sys.executable, FETCH], capture_output=True,
                             text=True, timeout=20).stdout.strip()
        if out:
            sys.stdout.write(out + "\n")
            return
    except Exception:
        pass

    sys.stdout.write(json.dumps({"ok": False, "state": "error",
                                 "error": "no data"}) + "\n")


if __name__ == "__main__":
    main()
