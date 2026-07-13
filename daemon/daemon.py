#!/usr/bin/env python3
"""claude-usage-daemon — the single source of truth for Claude usage on this box.

Every POLL seconds it:
  1. Polls the Anthropic OAuth allowance endpoint (the percentages the widget
     shows) and appends one row to the `samples` table.
  2. Incrementally scans ~/.claude/projects/**/*.jsonl for new assistant
     messages and appends per-message token rows to the `messages` table
     (deduped by record uuid; files read from a persisted byte offset).
  3. Writes ~/.cache/claude-usage/latest.json in the shape the plasmoid reads,
     so the widget never touches the network (only this daemon does — 1 call /
     POLL seconds, well under the endpoint's rate limit).

Everything is stored RAW. No aggregation happens here; analyze.py does that
later. Stdlib only (urllib, sqlite3, json). Never prints the token.

Design constraints inherited from the widget's fetch script:
  - Reads ~/.claude/.credentials.json, uses the OAuth access token as-is.
  - NEVER performs an OAuth refresh (that would rotate the refresh token and
    disrupt the Claude Code login). Expired token -> skip the poll, keep going.
"""
import json, os, sqlite3, sys, time, urllib.request, urllib.error
from datetime import datetime, timezone

HOME = os.path.expanduser("~")
CREDS = os.path.join(HOME, ".claude", ".credentials.json")
PROJECTS = os.path.join(HOME, ".claude", "projects")
DB = os.path.join(HOME, ".local", "share", "claude-usage", "usage.db")
CACHE_DIR = os.path.join(HOME, ".cache", "claude-usage")
LATEST = os.path.join(CACHE_DIR, "latest.json")
URL = "https://api.anthropic.com/api/oauth/usage"
POLL = int(os.environ.get("CLAUDE_USAGE_POLL", "110"))


# ----------------------------------------------------------------------------
# database
# ----------------------------------------------------------------------------
def db_connect():
    os.makedirs(os.path.dirname(DB), exist_ok=True)
    con = sqlite3.connect(DB, timeout=30)
    con.execute("PRAGMA journal_mode=WAL")
    con.executescript("""
    CREATE TABLE IF NOT EXISTS samples (
        ts              REAL PRIMARY KEY,   -- when we polled (epoch)
        five_pct        REAL,
        five_reset      REAL,               -- epoch of the 5h window reset
        five_active     INTEGER,
        weekly_pct      REAL,
        weekly_reset    REAL,
        scoped_pct      REAL,
        scoped_reset    REAL,
        scoped_model    TEXT,               -- e.g. "Fable"
        sev_five        TEXT,
        sev_weekly      TEXT,
        sev_scoped      TEXT,
        raw             TEXT                -- full API JSON, future-proofing
    );
    CREATE TABLE IF NOT EXISTS messages (
        uuid            TEXT PRIMARY KEY,   -- transcript record uuid (dedupe)
        ts              REAL,               -- message timestamp (epoch)
        session         TEXT,               -- session id (transcript basename)
        model           TEXT,               -- raw model string
        family          TEXT,               -- fable|opus|sonnet|haiku|other
        input           INTEGER,
        output          INTEGER,
        cache_read      INTEGER,
        cache_create_1h INTEGER,
        cache_create_5m INTEGER,
        service_tier    TEXT
    );
    CREATE TABLE IF NOT EXISTS files (
        path    TEXT PRIMARY KEY,
        offset  INTEGER,                    -- bytes consumed so far
        mtime   REAL
    );
    CREATE INDEX IF NOT EXISTS idx_messages_ts ON messages(ts);
    """)
    con.commit()
    return con


# ----------------------------------------------------------------------------
# allowance poll  (percentages)
# ----------------------------------------------------------------------------
def parse_iso(s):
    if not s:
        return None
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except Exception:
        return None


def plan_label(sub, tier):
    sub = (sub or "").strip()
    name = {"max": "Max", "pro": "Pro", "team": "Team",
            "enterprise": "Enterprise"}.get(sub.lower(), sub.title() or "Claude")
    t = (tier or "").lower()
    mult = " 20×" if "20x" in t else (" 5×" if "5x" in t else "")
    return name + mult


def poll_allowance(creds):
    """Returns (sample_row_dict, latest_json_dict) or (None, None) on failure."""
    token = creds.get("accessToken")
    if not token:
        return None, None
    if creds.get("expiresAt") and creds["expiresAt"] / 1000 < time.time():
        return None, None  # expired; do not refresh (would rotate token)

    req = urllib.request.Request(URL, headers={
        "Authorization": "Bearer " + token,
        "anthropic-beta": "oauth-2025-04-20",
        "anthropic-version": "2023-06-01",
        "User-Agent": "claude-usage-daemon/1.0",
        "Accept": "application/json",
    })
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            data = json.loads(r.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        info = {"state": "ratelimited" if e.code == 429 else "error"}
        ra = e.headers.get("Retry-After") if e.headers else None
        if ra:
            info["retry_after"] = ra
        return None, info
    except Exception:
        return None, {"state": "offline"}

    now = time.time()
    limits = {l.get("kind"): l for l in (data.get("limits") or [])
              if isinstance(l, dict)}
    s = limits.get("session") or {}
    w = limits.get("weekly_all") or {}
    sc = limits.get("weekly_scoped") or {}
    scoped_model = ""
    try:
        scoped_model = (sc.get("scope") or {}).get("model", {}).get("display_name") or ""
    except Exception:
        pass

    sample = {
        "ts": now,
        "five_pct": s.get("percent"),
        "five_reset": parse_iso(s.get("resets_at")),
        "five_active": 1 if s.get("is_active") else 0,
        "weekly_pct": w.get("percent"),
        "weekly_reset": parse_iso(w.get("resets_at")),
        "scoped_pct": sc.get("percent"),
        "scoped_reset": parse_iso(sc.get("resets_at")),
        "scoped_model": scoped_model,
        "sev_five": s.get("severity"),
        "sev_weekly": w.get("severity"),
        "sev_scoped": sc.get("severity"),
        "raw": json.dumps(data, separators=(",", ":")),
    }

    # latest.json in the shape the plasmoid already understands
    def mk(key, label, lim):
        ep = parse_iso(lim.get("resets_at"))
        return {"key": key, "label": label,
                "pct": int(round(lim.get("percent") or 0)),
                "resets_epoch": ep,
                "resets_in_sec": (max(0, int(ep - now)) if ep else None),
                "severity": lim.get("severity") or "normal"}
    items = []
    if s:
        items.append(mk("5h", "5-hour", s))
    if w:
        items.append(mk("wk", "Weekly", w))
    if sc:
        items.append(mk("scoped", scoped_model or "Model", sc))
    latest = {"ok": True, "stale": False, "state": "ok", "updated": int(now),
              "plan": plan_label(creds.get("subscriptionType"),
                                 creds.get("rateLimitTier")),
              "items": items}
    return sample, latest


def write_latest(obj):
    try:
        os.makedirs(CACHE_DIR, exist_ok=True)
        tmp = LATEST + ".tmp"
        with open(tmp, "w") as f:
            json.dump(obj, f, separators=(",", ":"))
        os.replace(tmp, LATEST)
    except Exception:
        pass


def insert_sample(con, sample):
    con.execute("""INSERT OR REPLACE INTO samples
        (ts,five_pct,five_reset,five_active,weekly_pct,weekly_reset,
         scoped_pct,scoped_reset,scoped_model,sev_five,sev_weekly,sev_scoped,raw)
        VALUES (:ts,:five_pct,:five_reset,:five_active,:weekly_pct,:weekly_reset,
         :scoped_pct,:scoped_reset,:scoped_model,:sev_five,:sev_weekly,:sev_scoped,:raw)""",
        sample)


# ----------------------------------------------------------------------------
# transcript scan  (raw token counts)
# ----------------------------------------------------------------------------
def family_of(model):
    m = (model or "").lower()
    if "fable" in m:
        return "fable"
    if "opus" in m:
        return "opus"
    if "sonnet" in m:
        return "sonnet"
    if "haiku" in m:
        return "haiku"
    if "synthetic" in m:
        return "synthetic"
    return "other"


def scan_transcripts(con):
    if not os.path.isdir(PROJECTS):
        return 0
    known = dict(con.execute("SELECT path, offset FROM files").fetchall())
    rows = []
    files_seen = []
    for root, _dirs, names in os.walk(PROJECTS):
        for name in names:
            if not name.endswith(".jsonl"):
                continue
            path = os.path.join(root, name)
            try:
                size = os.path.getsize(path)
            except OSError:
                continue
            start = known.get(path, 0)
            if start > size:          # file shrank/rotated; re-read from 0
                start = 0
            if start == size:
                continue
            session = name[:-6]       # strip .jsonl
            try:
                with open(path, "rb") as f:
                    f.seek(start)
                    chunk = f.read(size - start)
            except OSError:
                continue
            # only consume up to the last complete line
            nl = chunk.rfind(b"\n")
            if nl == -1:
                continue              # no complete line yet
            consumed = start + nl + 1
            for line in chunk[:nl].split(b"\n"):
                if not line.strip():
                    continue
                try:
                    rec = json.loads(line)
                except Exception:
                    continue
                if rec.get("type") != "assistant":
                    continue
                msg = rec.get("message") or {}
                usage = msg.get("usage") or {}
                if not usage:
                    continue
                model = msg.get("model") or ""
                fam = family_of(model)
                if fam == "synthetic":
                    continue
                cc = usage.get("cache_creation") or {}
                rows.append((
                    rec.get("uuid") or (session + ":" + str(rec.get("requestId"))),
                    parse_iso(rec.get("timestamp")),
                    session, model, fam,
                    usage.get("input_tokens") or 0,
                    usage.get("output_tokens") or 0,
                    usage.get("cache_read_input_tokens") or 0,
                    cc.get("ephemeral_1h_input_tokens") or 0,
                    cc.get("ephemeral_5m_input_tokens") or 0,
                    usage.get("service_tier") or "",
                ))
            files_seen.append((path, consumed, os.path.getmtime(path)))

    if rows:
        con.executemany("""INSERT OR IGNORE INTO messages
            (uuid,ts,session,model,family,input,output,cache_read,
             cache_create_1h,cache_create_5m,service_tier)
            VALUES (?,?,?,?,?,?,?,?,?,?,?)""", rows)
    if files_seen:
        con.executemany(
            "INSERT OR REPLACE INTO files (path,offset,mtime) VALUES (?,?,?)",
            files_seen)
    return len(rows)


# ----------------------------------------------------------------------------
# main loop
# ----------------------------------------------------------------------------
def load_creds():
    try:
        with open(CREDS) as f:
            return json.load(f)["claudeAiOauth"]
    except Exception:
        return None


# API poll gating: the transcript scan runs every tick (cheap, local), but the
# allowance poll backs off exponentially on 429 so we don't hammer — and don't
# keep the rate-limit window open — when the endpoint is throttling us.
_next_poll = 0.0
_backoff = POLL
MAX_BACKOFF = 600


def tick(con):
    global _next_poll, _backoff
    creds = load_creds()
    new_msgs = scan_transcripts(con)
    status = "scan"
    now = time.time()
    if creds and now >= _next_poll:
        sample, latest = poll_allowance(creds)
        if sample:
            insert_sample(con, sample)
            _backoff = POLL
            _next_poll = now + POLL
            # Publish when we'll poll again so the widget can show "next in Xs"
            # instead of hardcoding (and drifting from) our cadence.
            latest["next_poll"] = int(_next_poll)
            write_latest(latest)
            status = "ok"
        else:
            st = (latest or {}).get("state")
            if st == "ratelimited":
                _backoff = min(_backoff * 2, MAX_BACKOFF)
                ra = (latest or {}).get("retry_after")
                status = f"429 backoff→{_backoff}s" + (f" retry-after={ra}" if ra else "")
            else:
                _backoff = POLL
                status = st or "skip"
            _next_poll = now + _backoff
    elif creds:
        status = f"wait {int(_next_poll - now)}s"
    con.commit()
    return status, new_msgs


def main():
    con = db_connect()
    once = "--once" in sys.argv
    while True:
        try:
            status, n = tick(con)
            ts = datetime.now().strftime("%H:%M:%S")
            print(f"[{ts}] poll={status} new_messages={n}", flush=True)
        except Exception as e:
            print(f"tick error: {e}", file=sys.stderr, flush=True)
        if once:
            break
        time.sleep(POLL)


if __name__ == "__main__":
    main()
