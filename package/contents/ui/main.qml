import QtQuick
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasma5support as P5Support
import org.kde.kirigami as Kirigami
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
    property var items: []
    property bool fetching: false

    property double nowSec: Date.now() / 1000

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

    P5Support.DataSource {
        id: executable
        engine: "executable"
        connectedSources: []
        onNewData: (source, data) => {
            disconnectSource(source);
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

    // Reading the daemon's local cache is free (no network), so always reflect
    // the latest on open.
    onExpandedChanged: {
        if (expanded) {
            nowSec = Date.now() / 1000;
            refresh();
        } else {
            pinned = false;
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
            if (sampleChanged)
                items = newItems;
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

    // Keeps countdowns fresh between fetches; only ticks while something
    // that shows a countdown is on screen.
    Timer {
        interval: 30000
        running: root.expanded || plasmoid.configuration.showTimeLeft
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
    hideOnWindowDeactivate: !pinned

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
            enabled: !root.fetching
            onTriggered: root.refresh()
        }
    ]
}
