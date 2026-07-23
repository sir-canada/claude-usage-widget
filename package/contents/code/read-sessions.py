#!/usr/bin/env python3
"""Which Claude Code sessions have a live background shell task?

A session that is idle at the prompt still counts as "working" if it has a
background Bash task running. The widget can't see that from window titles
(Claude's title spinner only reflects foreground activity), so this script
walks /proc:

  - A Claude Bash tool shell is a zsh/bash process whose cmdline sources
    ~/.claude/shell-snapshots/… (distinctive marker), parented by a live
    claude process (parent check keeps orphans from a crashed claude from
    pinning a session "working" forever).
  - Task shells have stdout redirected to
    /tmp/claude-<uid>/<encoded-project>/<session-id>/tasks/<task>.output.
    NOTE: this does NOT distinguish background from foreground — foreground
    tool shells use the same task files (verified empirically; an earlier
    assumption that foreground goes to a pipe was wrong). It doesn't matter:
    a foreground shell only lives while the turn is active, and then the
    window title shows the spinner, so the widget already renders "working".
    This list only ever decides the idle-titled case — and an idle title
    with a live task shell can only be a background task.
  - The session id in that path names the transcript
    ~/.claude/projects/<encoded-project>/<session-id>.jsonl, whose last
    "ai-title" record is the same title Claude puts in the terminal window.

Output: {"bg": ["<session title>", ...]} — titles with >=1 running task
shell. Local /proc + file reads only; no network. Mirrors read-usage.py's
contract: always prints JSON, never blocks.
"""
import glob
import json
import os
import re

OUT_RE = re.compile(
    r"^/tmp/claude-\d+/(?P<proj>[^/]+)/(?P<sid>[0-9a-fA-F-]{36})/tasks/[^/]+\.output$"
)
PROJECTS = os.path.expanduser("~/.claude/projects")


def session_title(proj, sid):
    """Last aiTitle in the session transcript (later records win)."""
    fp = os.path.join(PROJECTS, proj, sid + ".jsonl")
    title = None
    try:
        with open(fp, errors="replace") as fh:
            for line in fh:
                # Cheap pre-filter; ai-title lines are rare and short.
                if '"ai-title"' not in line:
                    continue
                try:
                    o = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if o.get("type") == "ai-title":
                    title = o.get("aiTitle") or title
    except OSError:
        return None
    return title


def parent_is_claude(pid_dir):
    """True if the process's parent is a live claude process."""
    try:
        with open(os.path.join(pid_dir, "stat")) as fh:
            # field 4 (after the parenthesised comm, which may contain
            # spaces — split from the right of the closing paren)
            ppid = fh.read().rsplit(")", 1)[1].split()[1]
        with open("/proc/%s/cmdline" % ppid, "rb") as fh:
            pcmd = fh.read().decode(errors="replace")
    except (OSError, IndexError):
        return False
    return "claude" in pcmd.split("\0", 1)[0]


def main():
    titles = set()
    for fd1 in glob.glob("/proc/[0-9]*/fd/1"):
        pid_dir = os.path.dirname(os.path.dirname(fd1))
        try:
            with open(os.path.join(pid_dir, "cmdline"), "rb") as fh:
                cmd = fh.read().decode(errors="replace")
        except OSError:
            continue  # process gone / not ours
        if "shell-snapshots" not in cmd:
            continue
        if not parent_is_claude(pid_dir):
            continue  # orphan; its claude is gone
        try:
            target = os.readlink(fd1)
        except OSError:
            continue
        m = OUT_RE.match(target)
        if not m:
            continue
        t = session_title(m.group("proj"), m.group("sid"))
        if t:
            titles.add(t)
    print(json.dumps({"bg": sorted(titles)}))


if __name__ == "__main__":
    main()
