#!/usr/bin/env python3
"""Fetch Claude subscription usage for the Noctalia claude-usage plugin.
Prints a single normalized JSON line to stdout. Never prints the token.
Deliberately does NOT perform OAuth refresh (to avoid rotating the refresh
token and disrupting the user's Claude Code login); when the access token is
expired it reports state 'expired' and the widget shows the last cached value."""
import json, os, sys, time, urllib.request, urllib.error
from datetime import datetime, timezone

HOME = os.path.expanduser("~")
CREDS = os.path.join(HOME, ".claude", ".credentials.json")
CACHE_DIR = os.path.join(HOME, ".cache", "claude-usage")
CACHE = os.path.join(CACHE_DIR, "usage.json")
URL = "https://api.anthropic.com/api/oauth/usage"

def emit(obj):
    try:
        os.makedirs(CACHE_DIR, exist_ok=True)
        if obj.get("ok"):
            tmp = CACHE + ".tmp"
            with open(tmp, "w") as f:
                json.dump(obj, f)
            os.replace(tmp, CACHE)
    except Exception:
        pass
    sys.stdout.write(json.dumps(obj, separators=(",", ":")))
    sys.stdout.write("\n")

def cached(state):
    try:
        with open(CACHE) as f:
            c = json.load(f)
        c["ok"] = True
        c["stale"] = True
        c["state"] = state
        # recompute countdowns from stored absolute reset timestamps
        now = time.time()
        for it in c.get("items", []):
            if it.get("resets_epoch"):
                it["resets_in_sec"] = max(0, int(it["resets_epoch"] - now))
        return c
    except Exception:
        return None

def parse_reset(s):
    if not s:
        return None
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except Exception:
        return None

def plan_label(sub, tier):
    sub = (sub or "").strip()
    name = {"max": "Max", "pro": "Pro", "team": "Team", "enterprise": "Enterprise"}.get(sub.lower(), sub.title() or "Claude")
    mult = ""
    t = (tier or "").lower()
    if "20x" in t: mult = " 20×"
    elif "5x" in t: mult = " 5×"
    return name + mult

def main():
    try:
        with open(CREDS) as f:
            creds = json.load(f)["claudeAiOauth"]
    except Exception:
        return emit({"ok": False, "state": "noauth", "error": "no credentials"})
    token = creds.get("accessToken")
    if not token:
        return emit({"ok": False, "state": "noauth", "error": "no token"})
    if creds.get("expiresAt") and creds["expiresAt"] / 1000 < time.time():
        c = cached("expired")
        return emit(c if c else {"ok": False, "state": "expired", "error": "token expired"})

    req = urllib.request.Request(URL, headers={
        "Authorization": "Bearer " + token,
        "anthropic-beta": "oauth-2025-04-20",
        "anthropic-version": "2023-06-01",
        "User-Agent": "noctalia-claude-usage/1.0",
        "Accept": "application/json",
    })
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            data = json.loads(r.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        if e.code in (401, 403):
            c = cached("expired")
            return emit(c if c else {"ok": False, "state": "expired", "error": "unauthorized"})
        if e.code == 429:
            # The usage endpoint rate-limits readily; this is routine, not an
            # error. Serve the cache and let the next poll pick it up.
            c = cached("ratelimited")
            return emit(c if c else {"ok": False, "state": "ratelimited", "error": "rate limited"})
        c = cached("error")
        return emit(c if c else {"ok": False, "state": "error", "error": "http %d" % e.code})
    except Exception as e:
        c = cached("offline")
        return emit(c if c else {"ok": False, "state": "offline", "error": str(e)})

    now = time.time()
    limits = {l.get("kind"): l for l in (data.get("limits") or []) if isinstance(l, dict)}

    def mk(key, label, pct, resets_at, severity):
        ep = parse_reset(resets_at)
        return {
            "key": key, "label": label,
            "pct": int(round(pct)) if pct is not None else 0,
            "resets_epoch": ep,
            "resets_in_sec": (max(0, int(ep - now)) if ep else None),
            "severity": severity or "normal",
        }

    items = []
    # 5-hour window
    s = limits.get("session")
    if s: items.append(mk("5h", "5-hour", s.get("percent"), s.get("resets_at"), s.get("severity")))
    elif data.get("five_hour"): 
        fh = data["five_hour"]; items.append(mk("5h", "5-hour", fh.get("utilization"), fh.get("resets_at"), None))
    # Weekly (all models)
    w = limits.get("weekly_all")
    if w: items.append(mk("wk", "Weekly", w.get("percent"), w.get("resets_at"), w.get("severity")))
    elif data.get("seven_day"):
        sd = data["seven_day"]; items.append(mk("wk", "Weekly", sd.get("utilization"), sd.get("resets_at"), None))
    # Weekly model-scoped (e.g. Fable / Opus)
    sc = limits.get("weekly_scoped")
    if sc:
        label = "Fable"
        try:
            label = sc.get("scope", {}).get("model", {}).get("display_name") or label
        except Exception:
            pass
        items.append(mk("scoped", label, sc.get("percent"), sc.get("resets_at"), sc.get("severity")))

    emit({
        "ok": True, "stale": False, "state": "ok",
        "updated": int(now),
        "plan": plan_label(creds.get("subscriptionType"), creds.get("rateLimitTier")),
        "items": items,
    })

if __name__ == "__main__":
    main()
