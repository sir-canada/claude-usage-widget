import QtQuick
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasma5support as P5Support
import org.kde.kirigami as Kirigami
import org.kde.taskmanager as TaskManager
import "utils.js" as Utils

PlasmoidItem {
    id: root

    // ---- usage data (same normalized shape read-usage.py emits) ----
    property bool ready: false        // a fetch has completed at least once
    property bool ok: false           // last fetch produced usable data
    property bool stale: false        // data came from cache (network/token issue)
    property string state: "loading"  // loading | ok | offline | expired | noauth | error
    property string plan: ""
    property double updated: 0
    property double nextPoll: 0       // epoch of the daemon's next API poll
    property var items: []
    property bool fetching: false

    // Two clocks on purpose:
    //   nowSec  - snapshot, re-anchored when the popup opens / new data lands.
    //             Drives the footer's "Updated Xs ago" (a stopwatch there would
    //             be noise).
    //   tickSec - the countdown clock. Ticks 1s while a reset is imminent so
    //             the last 90s counts down for real, 30s otherwise.
    property double nowSec: Date.now() / 1000
    property double tickSec: Date.now() / 1000

    readonly property bool resetImminent: {
        for (var i = 0; i < items.length; i++) {
            var e = items[i].resets_epoch;
            if (!e)
                continue;
            var left = e - tickSec;
            // Lower bound: once a reset is well past due the daemon just hasn't
            // repolled yet — don't spin at 1Hz forever waiting for it.
            if (left < Utils.IMMINENT_SEC && left > -30)
                return true;
        }
        return false;
    }

    // Hover-to-open popup (replaces the plain-text panel tooltip).
    // Clicking pins the popup open so the refresh button can be reached.
    property bool pinned: false
    property bool compactHovered: false
    property bool popupHovered: false

    function scheduleCollapse() {
        collapseTimer.restart();
    }

    Timer {
        id: collapseTimer
        interval: 450
        onTriggered: {
            if (!root.pinned && !root.popupHovered && !root.compactHovered)
                root.expanded = false;
        }
    }

    // ---- running Claude Code sessions (from window titles) ----
    //
    // Claude Code writes its state into the terminal window title:
    //   "✳ <session title>"            while idle / waiting for input
    //   "<braille spinner> <title>"    while working (⠐⠋⠙… U+2800-U+28FF)
    // So the window list alone yields: which sessions exist, what each is
    // called, and whether it's currently doing something. No polling, no
    // scripts — TasksModel is live and requestActivate() works on Wayland.
    //
    // Limitation (accepted): a session whose terminal doesn't forward the
    // title (tmux/ssh without passthrough) won't appear.
    // Session states:
    //   "attention" - window demands attention (Claude rang the bell: finished
    //                 or waiting on a permission prompt). Clears when focused.
    //   "working"   - title carries the braille spinner.
    //   "idle"      - plain ✳ title.
    property var sessions: []          // [{ row, title, state }] attention > working > idle
    property string _sessionsSig: ""   // change detector; see rebuildSessions()
    // Titles of sessions that currently run a background shell task. The
    // window title only reflects foreground activity (spinner), so an idle
    // title with a live bg task would read "idle" — read-sessions.py walks
    // /proc and reports those; they render as "working".
    property var bgTitles: []

    // "Ready" latch, no bell required (same trick as the yellow-flash in
    // ~/Documents/projects/plasma-taskbar-patches): when a title drops its
    // braille spinner while its window is NOT focused, that session finished
    // without you watching — latch it "ready" until you activate the window
    // (or it starts working again). Plain JS maps, internal bookkeeping only.
    property var _wasWorking: ({})   // title -> last observed spinner state
    property var _readyLatch: ({})   // title -> true while latched
    // title -> epoch sec the session went idle. Stamped live on the
    // (working/attention -> idle) transition; sessions already idle when the
    // widget starts fall back to the window's LastActivated as best guess
    // (upper bound — it went idle sometime after you last touched it).
    property var _idleSince: ({})
    readonly property int sessionsAttentionCount: countState("attention")
    readonly property int sessionsWorkingCount: countState("working")

    function countState(s) {
        var n = 0;
        for (var i = 0; i < sessions.length; i++)
            if (sessions[i].state === s)
                n++;
        return n;
    }

    TaskManager.TasksModel {
        id: tasksModel
        // All windows everywhere: a session on another desktop/screen is still
        // a session you may want to jump to.
        filterByVirtualDesktop: false
        filterByScreen: false
        filterByActivity: false
        filterMinimized: false
        groupMode: TaskManager.TasksModel.GroupDisabled
        sortMode: TaskManager.TasksModel.SortLastActivated
    }

    // The braille spinner animates in the title, so TasksModel fires
    // dataChanged several times a second per busy session. Coalesce through
    // a timer — start-if-stopped, NOT restart(): with several busy sessions
    // the events can arrive faster than the debounce interval forever, and
    // restart() would starve the rebuild indefinitely. This runs at most 4x/s
    // regardless of storm rate.
    //
    // Always on (not gated on the popup being open): the ready-latch needs
    // to see the spinner-drop transition the moment it happens, popup or no.
    Connections {
        target: tasksModel
        function onDataChanged() { if (!sessionsRebuild.running) sessionsRebuild.start(); }
        function onRowsInserted() { if (!sessionsRebuild.running) sessionsRebuild.start(); }
        function onRowsRemoved() { if (!sessionsRebuild.running) sessionsRebuild.start(); }
        function onModelReset() { if (!sessionsRebuild.running) sessionsRebuild.start(); }
    }

    Timer {
        id: sessionsRebuild
        interval: 250
        onTriggered: root.rebuildSessions()
    }

    // Background-task state can change without any window-title event (a bg
    // shell finishing changes nothing on screen), so poll the cheap /proc
    // walk while the popup is open. Popup closed: zero work.
    Timer {
        interval: 5000
        running: root.expanded
        repeat: true
        onTriggered: root.refreshBgTasks()
    }

    function rebuildSessions() {
        var out = [];
        // Ghostty prepends "🔔 " to the title when the bell rings while the
        // window is unfocused ("🔔 ✳ title") — the prefix must be optional or
        // a session disappears from this list at the exact moment it wants
        // you. It doubles as an attention signal alongside the window flag.
        var re = /^(🔔\s*)?([✳⠀-⣿])\s+(.+)$/;
        var nextWas = {};
        var seen = {};
        for (var i = 0; i < tasksModel.count; i++) {
            var idx = tasksModel.makeModelIndex(i);
            var title = tasksModel.data(idx, Qt.DisplayRole);
            var m = re.exec(String(title || ""));
            if (!m)
                continue;
            var t = m[3];
            var spinning = m[2] !== "✳";
            var isActive = tasksModel.data(idx,
                TaskManager.AbstractTasksModel.IsActive) === true;

            // Ready latch: spinner just vanished while the window wasn't
            // focused -> finished unwatched. Focusing the window (or a new
            // turn starting) acknowledges it.
            if (_wasWorking[t] === true && !spinning && !isActive)
                _readyLatch[t] = true;
            if (isActive || spinning)
                delete _readyLatch[t];
            nextWas[t] = spinning;
            seen[t] = true;

            var attention = !!m[1]
                || _readyLatch[t] === true
                || tasksModel.data(idx,
                    TaskManager.AbstractTasksModel.IsDemandingAttention) === true;
            var working = spinning || bgTitles.indexOf(t) !== -1;
            var state = attention ? "attention"
                                  : (working ? "working" : "idle");
            // LastActivated arrives as a QDateTime (a JS Date here); windows
            // never activated this login report an invalid/zero value and
            // sink to the bottom.
            var la = tasksModel.data(idx, TaskManager.AbstractTasksModel.LastActivated);
            var last = (la instanceof Date) ? la.getTime() : (Number(la) || 0);

            // Idle-since bookkeeping: stamp on entering idle, clear the
            // moment the session is anything else.
            if (state === "idle") {
                if (_idleSince[t] === undefined)
                    _idleSince[t] = last > 0 ? Math.floor(last / 1000)
                                             : Math.floor(Date.now() / 1000);
            } else if (_idleSince[t] !== undefined) {
                delete _idleSince[t];
            }

            out.push({ row: i, title: t, state: state, last: last,
                       idleSince: _idleSince[t] || 0 });
        }
        // Prune bookkeeping for windows that no longer exist.
        _wasWorking = nextWas;
        for (var k in _readyLatch)
            if (!seen[k])
                delete _readyLatch[k];
        for (var k2 in _idleSince)
            if (!seen[k2])
                delete _idleSince[k2];
        // "ready" (needs you) pinned on top; everything else strictly by
        // when you last activated the window, newest first.
        out.sort(function (a, b) {
            var ra = a.state === "attention" ? 0 : 1;
            var rb = b.state === "attention" ? 0 : 1;
            if (ra !== rb)
                return ra - rb;
            return b.last - a.last;
        });

        // The spinner ticks change the raw titles constantly, but the
        // extracted {title, busy} set is stable while nothing real changed.
        // Replacing the array unconditionally would rebuild every delegate on
        // each spinner frame — same flicker bug parseOutput() guards against.
        var sig = JSON.stringify(out);
        if (sig === _sessionsSig)
            return;
        _sessionsSig = sig;
        sessions = out;
    }

    function activateSession(row) {
        tasksModel.requestActivate(tasksModel.makeModelIndex(row));
    }

    function closeSession(row) {
        tasksModel.requestClose(tasksModel.makeModelIndex(row));
    }

    readonly property var fiveHour: {
        for (var i = 0; i < items.length; i++)
            if (items[i].key === "5h")
                return items[i];
        return null;
    }

    readonly property var popupItems: {
        var out = [];
        for (var i = 0; i < items.length; i++) {
            var it = items[i];
            if (it.key === "wk" && !plasmoid.configuration.showWeekly)
                continue;
            if (it.key === "scoped" && !plasmoid.configuration.showScoped)
                continue;
            out.push(it);
        }
        return out;
    }

    // Metrics that reset at the same instant are drawn as one block with a
    // single "Resets in ..." line, instead of repeating the same countdown
    // under every bar. Today the two weekly rows always share an epoch (to the
    // same second) — but this checks rather than assumes: if Anthropic ever
    // staggers them, they fall back to separate rows with their own countdowns.
    readonly property var popupGroups: {
        var src = popupItems;
        var groups = [];
        var i = 0;
        while (i < src.length) {
            var head = src[i];
            var g = { items: [head], resets: head.resets_epoch || 0 };
            var j = i + 1;
            while (j < src.length && head.resets_epoch && src[j].resets_epoch
                   && Math.abs(src[j].resets_epoch - head.resets_epoch) <= 60) {
                g.items.push(src[j]);
                j++;
            }
            groups.push(g);
            i = j;
        }
        return groups;
    }

    function metricLabel(item) {
        if (!item)
            return "";
        if (item.key === "5h")
            return i18n("Current session");
        if (item.key === "wk")
            return i18n("All models · week");
        if (item.key === "scoped")
            return item.label ? i18n("%1 · week", item.label) : i18n("Model · week");
        return item.label || item.key;
    }

    // Usage color: theme-semantic green -> amber -> red so it matches every
    // Plasma color scheme (same red as battery-critical).
    function usageColor(pct) {
        var v = Math.max(0, Math.min(100, pct || 0));
        var good = Kirigami.Theme.positiveTextColor;
        var warn = Kirigami.Theme.neutralTextColor;
        var bad = Kirigami.Theme.negativeTextColor;
        if (v <= 60)
            return good;
        if (v <= 85)
            return Qt.tint(good, Qt.alpha(warn, (v - 60) / 25));
        return Qt.tint(warn, Qt.alpha(bad, (v - 85) / 15));
    }

    // Reads the claude-usage-daemon's cached data (no network); falls back to
    // a direct fetch only if the daemon isn't running.
    readonly property string scriptPath: {
        var p = Qt.resolvedUrl("../code/read-usage.py").toString();
        return p.replace(/^file:\/\//, "");
    }

    readonly property string sessionsScriptPath: {
        var p = Qt.resolvedUrl("../code/read-sessions.py").toString();
        return p.replace(/^file:\/\//, "");
    }

    P5Support.DataSource {
        id: executable
        engine: "executable"
        connectedSources: []
        onNewData: (source, data) => {
            disconnectSource(source);
            if (source.indexOf("read-sessions") !== -1) {
                root.parseBgTasks(data.stdout);
                return;
            }
            root.fetching = false;
            root.parseOutput(data.stdout);
        }
    }

    function refresh() {
        if (fetching)
            return;
        fetching = true;
        executable.connectSource("python3 '" + scriptPath + "'");
    }

    function refreshBgTasks() {
        executable.connectSource("python3 '" + sessionsScriptPath + "'");
    }

    function parseBgTasks(text) {
        var titles = [];
        try {
            titles = JSON.parse(String(text || "").trim()).bg || [];
        } catch (e) {
            titles = [];
        }
        // Only rebuild when the set actually changed — same churn guard as
        // everywhere else in this file.
        if (JSON.stringify(titles) === JSON.stringify(bgTitles))
            return;
        bgTitles = titles;
        rebuildSessions();
    }

    // Reading the daemon's local cache is free (no network), so always reflect
    // the latest on open.
    // root.expanded, not a bare `expanded`: the latter binds to the signal's
    // injected parameter, which Qt6 deprecates (and warns about on every load).
    onExpandedChanged: {
        if (root.expanded) {
            root.nowSec = Date.now() / 1000;
            // tickSec freezes while the popup is closed (its timer gates on
            // expanded); re-anchor so countdowns and idle-for badges are
            // correct immediately on open, not after the first 30s tick.
            root.tickSec = Date.now() / 1000;
            root.refresh();
            root.rebuildSessions();
            root.refreshBgTasks();
        } else {
            root.pinned = false;
        }
    }

    function parseOutput(text) {
        var raw = String(text || "").trim();
        if (raw === "") {
            ok = false;
            state = "error";
            ready = true;
            return;
        }
        try {
            var d = JSON.parse(raw);
            var newUpdated = d.updated || 0;
            var newItems = d.items || [];
            // Scalars are no-ops in QML when unchanged, but replacing the items
            // array ALWAYS re-binds (and rebuilds delegates) — which is the 5s
            // flicker. Only replace it when the sample truly changed; live
            // countdowns come from resets_epoch + the tick timer, not re-reads.
            var sampleChanged = (newUpdated !== updated) || (newItems.length !== items.length);
            ok = !!d.ok;
            stale = !!d.stale;
            state = d.state || (d.ok ? "ok" : "error");
            plan = d.plan || "";
            updated = newUpdated;
            nextPoll = d.next_poll || 0;
            if (sampleChanged) {
                items = newItems;
                // Re-anchor the footer's "updated X ago" to the moment fresh
                // poll data actually landed, so the age it shows is real.
                nowSec = Date.now() / 1000;
            }
        } catch (e) {
            ok = false;
            state = "error";
            items = [];
        }
        ready = true;
    }

    // The widget only mirrors the daemon's local cache file (no network), so it
    // can read often — new numbers appear within a few seconds of the daemon
    // writing them. The daemon owns the actual API-poll cadence + backoff.
    Timer {
        interval: 5000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }

    // Keeps countdowns fresh between fetches; only runs while something that
    // shows a countdown is on screen. Goes to 1Hz for the final 90s before a
    // reset (and back to 30s after), so the panel/popup tick down to the second
    // exactly when that's the number you care about — and idle the rest of the
    // time.
    Timer {
        interval: root.resetImminent ? 1000 : 30000
        running: root.expanded || plasmoid.configuration.showTimeLeft
        repeat: true
        onTriggered: root.tickSec = Date.now() / 1000
    }

    // The footer's age clock: coarse, and re-anchored on open / on fresh data.
    Timer {
        interval: 30000
        running: root.expanded
        repeat: true
        onTriggered: root.nowSec = Date.now() / 1000
    }

    Plasmoid.status: {
        if (root.ready && (root.state === "expired" || root.state === "noauth"))
            return PlasmaCore.Types.NeedsAttentionStatus;
        if (root.fiveHour && (root.fiveHour.pct || 0) >= 90)
            return PlasmaCore.Types.NeedsAttentionStatus;
        return PlasmaCore.Types.ActiveStatus;
    }

    Plasmoid.icon: Qt.resolvedUrl("../icons/claude-usage.svg").toString()

    // No panel tooltip: hovering opens the rich popup instead.
    toolTipMainText: ""
    toolTipSubText: ""
    // Never hide-on-deactivate. With it on, the hover popup holds the Wayland
    // popup grab; a right-click context menu then opens as the popup's *child*
    // in the grab chain, the popup deactivates and hides — and takes the menu
    // down with it (popup and menu both vanish the instant they appear, which
    // made Configure unreachable). Dismissal is owned by the hover-out
    // collapse timer (and the popup's own click/✕ handlers), so nothing is
    // lost by leaving this off.
    hideOnWindowDeactivate: false

    function stateHeading(s) {
        switch (s) {
        case "noauth": return i18n("Not signed in to Claude Code");
        case "expired": return i18n("Session token expired");
        case "offline": return i18n("Can't reach Anthropic");
        case "ratelimited": return i18n("Waiting for Anthropic (rate limited)");
        case "loading": return i18n("Loading…");
        default: return i18n("Couldn't read usage");
        }
    }

    function stateDescription(s) {
        switch (s) {
        case "noauth": return i18n("Sign in by running “claude” in a terminal.");
        case "expired": return i18n("Usage will update after you next use Claude Code.");
        case "offline": return i18n("Check your network connection. Cached values are shown if available.");
        case "ratelimited": return i18n("Anthropic is rate limiting usage checks. It will retry on the next poll.");
        default: return i18n("The usage script returned an unexpected result.");
        }
    }

    function stateIcon(s) {
        switch (s) {
        case "noauth": return "dialog-password";
        case "expired": return "clock";
        case "offline": return "network-disconnect";
        default: return "data-warning";
        }
    }

    preferredRepresentation: compactRepresentation
    compactRepresentation: CompactRepresentation {}
    fullRepresentation: FullRepresentation {}

    Plasmoid.contextualActions: [
        PlasmaCore.Action {
            text: i18n("Refresh Now")
            icon.name: "view-refresh"
            // No `enabled: !root.fetching` here: that binding flipped twice on
            // every 5s cache read, and a context-menu action changing state
            // under an open menu makes the menu unusable ("updates too fast").
            // refresh() already no-ops while a fetch is in flight.
            onTriggered: root.refresh()
        }
    ]
}
