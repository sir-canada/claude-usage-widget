import QtQuick
import QtQuick.Layouts
import QtQuick.Window
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents3
import org.kde.plasma.extras as PlasmaExtras
import org.kde.plasma.plasmoid
import "utils.js" as Utils

PlasmaExtras.Representation {
    id: full

    readonly property bool showRows: root.items.length > 0
    readonly property bool showPlaceholder: root.ready && !root.ok && !showRows
    // Rate-limited responses still carry near-fresh cached data; the
    // "Updated X ago" footer covers it, no need to dim or warn.
    readonly property bool cachedView: root.ready && (root.stale || !root.ok) && showRows
                                       && root.state !== "ratelimited"

    // Keep the hover-opened popup alive while the pointer is inside it.
    HoverHandler {
        onHoveredChanged: {
            root.popupHovered = hovered;
            if (!hovered)
                root.scheduleCollapse();
        }
    }

    // Click anywhere in the popup body dismisses it. The refresh ToolButton
    // consumes its own taps, so it's unaffected. This also releases any pin
    // that left the popup stuck on screen.
    TapHandler {
        acceptedButtons: Qt.LeftButton
        onTapped: {
            root.pinned = false;
            root.popupHovered = false;
            root.compactHovered = false;
            root.expanded = false;
        }
    }

    // Re-trigger the staggered gauge reveal each time the popup opens.
    property bool revealed: false
    Connections {
        target: root
        function onExpandedChanged() {
            if (root.expanded) {
                full.revealed = false;
                revealTimer.restart();
            }
        }
    }
    Timer {
        id: revealTimer
        interval: 50
        onTriggered: full.revealed = true
    }
    Component.onCompleted: revealTimer.start()

    // Height must include the header bar, or the bottom of the content — the
    // "Updated Xs ago" footer — gets clipped past the popup edge.
    //
    // minimumHeight matters as much as preferredHeight: Plasma persists the
    // popup's dialog size per-applet (popupHeight in appletsrc) and that saved
    // value overrides preferredHeight. Without a floor, a stale/short saved
    // size silently crops the footer forever.
    // The header bar already provides visual separation, so the content needs
    // almost no top margin of its own — a full largeSpacing there just reads as
    // dead space under the title.
    readonly property real contentTopMargin: Math.round(Kirigami.Units.smallSpacing / 2)
    readonly property real contentBottomMargin: Kirigami.Units.largeSpacing

    readonly property real wantedHeight: (header ? header.implicitHeight : 0)
                                         + contentColumn.implicitHeight
                                         + contentTopMargin + contentBottomMargin

    // Pin the height to the content, hard: min == preferred == max.
    //
    // Plasma persists the popup's dialog size per-applet (popupHeight in
    // appletsrc) and replays it over preferredHeight on load. Any layout change
    // we make would otherwise be fought by a height saved from the *previous*
    // layout — cropping the footer if the saved value is short, padding dead
    // space at the bottom if it's tall. Clamping min and max to the same value
    // leaves the saved size nothing to override, so the popup is always exactly
    // as tall as what's in it.
    //
    // …up to the screen. The sessions list can make the natural height taller
    // than the display; past the cap the list scrolls instead of the popup
    // growing off-screen. (Screen here is the popup dialog's own screen.)
    readonly property real screenCap: Screen.desktopAvailableHeight > 0
                                      ? Screen.desktopAvailableHeight - Kirigami.Units.gridUnit * 3
                                      : Number.MAX_VALUE
    readonly property real lockedHeight: Math.min(Math.max(wantedHeight,
                                                           Kirigami.Units.gridUnit * 12),
                                                  screenCap)

    Layout.preferredWidth: Kirigami.Units.gridUnit * 20
    Layout.preferredHeight: lockedHeight
    Layout.minimumHeight: lockedHeight
    Layout.maximumHeight: lockedHeight
    Layout.minimumWidth: Kirigami.Units.gridUnit * 16
    Layout.maximumWidth: Kirigami.Units.gridUnit * 24

    collapseMarginsHint: true

    // No refresh button: the widget reads the daemon's cache every 5s and the
    // footer states the data's exact age and when the next poll lands. A manual
    // refresh would re-read the same file and change nothing — the API cadence
    // is the daemon's to own, and it's rate-limited besides. (Right-click still
    // offers "Refresh Now" for the rare case where it helps.)
    header: PlasmaExtras.PlasmoidHeading {
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Kirigami.Units.smallSpacing
            anchors.rightMargin: Kirigami.Units.smallSpacing
            spacing: Kirigami.Units.smallSpacing

            Kirigami.Heading {
                text: i18n("Claude Usage")
                level: 2
                elide: Text.ElideRight
                Layout.fillWidth: true
            }

            // Plan badge chip
            Rectangle {
                visible: root.plan !== ""
                radius: height / 2
                color: Qt.alpha(Kirigami.Theme.highlightColor, 0.15)
                implicitHeight: planLabel.implicitHeight + Kirigami.Units.smallSpacing
                implicitWidth: planLabel.implicitWidth + Kirigami.Units.largeSpacing

                PlasmaComponents3.Label {
                    id: planLabel
                    anchors.centerIn: parent
                    text: root.plan
                    color: Kirigami.Theme.highlightColor
                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                }
            }

            // Direct path to the settings dialog: the context-menu route was
            // unreliable while the widget refreshed, and the popup is already
            // under the pointer anyway.
            PlasmaComponents3.ToolButton {
                icon.name: "configure"
                text: i18n("Configure…")
                display: PlasmaComponents3.AbstractButton.IconOnly
                onClicked: {
                    root.pinned = false;
                    root.expanded = false;
                    Plasmoid.internalAction("configure").trigger();
                }
            }

            PlasmaComponents3.ToolButton {
                icon.name: "window-close"
                text: i18n("Close")
                display: PlasmaComponents3.AbstractButton.IconOnly
                onClicked: {
                    root.pinned = false;
                    root.popupHovered = false;
                    root.compactHovered = false;
                    root.expanded = false;
                }
            }
        }
    }

    // First load: keep the popup its final size, centered spinner.
    PlasmaComponents3.BusyIndicator {
        anchors.centerIn: parent
        visible: !root.ready
        running: visible
    }

    // Designed error states.
    PlasmaExtras.PlaceholderMessage {
        anchors.centerIn: parent
        width: parent.width - Kirigami.Units.gridUnit * 4
        visible: full.showPlaceholder
        iconName: root.stateIcon(root.state)
        text: root.stateHeading(root.state)
        explanation: root.stateDescription(root.state)
    }

    ColumnLayout {
        id: contentColumn
        visible: root.ready && full.showRows
        anchors.fill: parent
        anchors.margins: Kirigami.Units.largeSpacing
        anchors.topMargin: full.contentTopMargin
        anchors.bottomMargin: full.contentBottomMargin

        // Gap *between* metric blocks. Each block already ends in its own reset
        // line, which carries plenty of visual air — a largeSpacing on top of
        // that just stretched the popup with nothing in it.
        spacing: Kirigami.Units.smallSpacing

        // ---- Running Claude Code sessions ----
        // First thing under the heading: the sessions are what you act on, so
        // they sit on top; the usage bars keep a fixed place at the bottom.
        // Section hides entirely when no session windows exist.
        RowLayout {
            visible: root.sessions.length > 0
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing

            PlasmaComponents3.Label {
                text: i18n("Sessions")
                font.bold: true
                font.pointSize: Kirigami.Theme.smallFont.pointSize
                opacity: 0.85
            }

            PlasmaComponents3.Label {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignRight
                readonly property int attN: root.sessionsAttentionCount
                readonly property int workN: root.sessionsWorkingCount
                readonly property int idleN: root.sessions.length - attN - workN
                text: {
                    var parts = [];
                    if (attN > 0)
                        parts.push(i18n("%1 waiting", attN));
                    if (workN > 0)
                        parts.push(i18n("%1 working", workN));
                    if (idleN > 0)
                        parts.push(i18n("%1 idle", idleN));
                    return parts.join(" · ");
                }
                opacity: 0.6
                font.pointSize: Kirigami.Theme.smallFont.pointSize
            }
        }

        ListView {
            id: sessionsList
            visible: root.sessions.length > 0
            model: root.sessions
            clip: true
            spacing: Math.round(Kirigami.Units.smallSpacing / 2)

            // Session list font: configurable family + point size (empty / 0
            // = theme defaults). Row height follows the chosen font.
            FontMetrics {
                id: sessionsFm
                font.family: plasmoid.configuration.sessionsFontFamily !== ""
                             ? plasmoid.configuration.sessionsFontFamily
                             : Kirigami.Theme.defaultFont.family
                font.pointSize: plasmoid.configuration.sessionsFontSize > 0
                                ? plasmoid.configuration.sessionsFontSize
                                : Kirigami.Theme.defaultFont.pointSize
            }

            readonly property real rowHeight: Math.max(sessionsFm.height,
                                                       Kirigami.Units.gridUnit)
                                              + Kirigami.Units.smallSpacing * 2
            readonly property bool overflowing: contentHeight > height + 1

            // Natural size is the full list; the popup grows to fit it. Only
            // when lockedHeight hits the screen cap does the layout shrink
            // this view (fillHeight absorbs the shortfall, nothing else does)
            // and scrolling takes over. Floor of 3 rows so the section can't
            // collapse to nothing on very small screens.
            implicitHeight: contentHeight
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.preferredHeight: contentHeight
            Layout.maximumHeight: contentHeight
            Layout.minimumHeight: Math.min(contentHeight,
                                           rowHeight * 3 + spacing * 2)

            // Compact but always-visible scrollbar whenever the list scrolls;
            // wheel scrolling is native to the ListView.
            PlasmaComponents3.ScrollBar.vertical: PlasmaComponents3.ScrollBar {
                policy: sessionsList.overflowing ? PlasmaComponents3.ScrollBar.AlwaysOn
                                                 : PlasmaComponents3.ScrollBar.AlwaysOff
            }

            // MouseArea is the delegate root: it owns hover + row clicks, and
            // the per-row ✕ ToolButton sits on top of it, eating its own
            // clicks before they reach the row handler.
            delegate: MouseArea {
                id: sessionRow
                required property var modelData

                // attention: green + slow pulse (ready / waiting on you) ·
                // working: orange (busy, no action needed) · idle: dim.
                readonly property bool attention: modelData.state === "attention"
                readonly property color stateColor: attention
                    ? Kirigami.Theme.positiveTextColor
                    : modelData.state === "working"
                      ? Kirigami.Theme.neutralTextColor
                      : Kirigami.Theme.disabledTextColor

                width: sessionsList.width
                height: sessionsList.rowHeight
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor

                // Jump to that session's window; the popup has done its job,
                // so dismiss it (and drop any pin) on the way out.
                onClicked: {
                    root.activateSession(modelData.row);
                    root.pinned = false;
                    root.popupHovered = false;
                    root.compactHovered = false;
                    root.expanded = false;
                }

                Rectangle {
                    anchors.fill: parent
                    // Keep the row (and its hover pill) clear of the scrollbar.
                    anchors.rightMargin: sessionsList.overflowing
                                         ? Kirigami.Units.smallSpacing * 2 : 0
                    radius: 4
                    color: sessionRow.containsMouse
                           ? Qt.alpha(Kirigami.Theme.highlightColor, 0.15)
                           : "transparent"

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: Kirigami.Units.smallSpacing
                        anchors.rightMargin: Kirigami.Units.smallSpacing
                        spacing: Kirigami.Units.smallSpacing * 2

                        // Status dot + ring. The whole dot breathes gently
                        // while a session waits on you (faster) or is working
                        // (slower) — shallow fade, below "annoying" threshold.
                        Item {
                            id: dotWrap
                            implicitWidth: 8
                            implicitHeight: 8

                            Rectangle {
                                anchors.fill: parent
                                radius: 4
                                color: sessionRow.stateColor
                            }

                            Rectangle {
                                visible: sessionRow.modelData.state !== "idle"
                                anchors.centerIn: parent
                                width: 14
                                height: 14
                                radius: 7
                                color: "transparent"
                                border.width: 2
                                border.color: Qt.alpha(sessionRow.stateColor, 0.35)
                            }

                            SequentialAnimation {
                                running: sessionRow.modelData.state !== "idle"
                                loops: Animation.Infinite
                                onStopped: dotWrap.opacity = 1
                                NumberAnimation {
                                    target: dotWrap; property: "opacity"
                                    to: 0.45
                                    duration: sessionRow.attention ? 1400 : 2500
                                    easing.type: Easing.InOutQuad
                                }
                                NumberAnimation {
                                    target: dotWrap; property: "opacity"
                                    to: 1.0
                                    duration: sessionRow.attention ? 1400 : 2500
                                    easing.type: Easing.InOutQuad
                                }
                            }
                        }

                        // Title in a clipping wrapper so the label can
                        // free-run wider than the row and marquee-scroll on
                        // hover (pattern lifted from plasma-taskbar-patches).
                        Item {
                            id: titleClip
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            clip: true

                            PlasmaComponents3.Label {
                                id: titleLabel

                                readonly property real overflowPx:
                                    Math.max(0, implicitWidth - titleClip.width)
                                // Only marquee when it's worth it: if 80%+ of
                                // the text is already visible, scrolling a few
                                // px is more fidget than information — the
                                // ellipsis stays.
                                readonly property bool marqueeOn:
                                    sessionRow.containsMouse
                                    && titleClip.width < implicitWidth * 0.8

                                anchors.verticalCenter: parent.verticalCenter
                                // While scrolling the label takes its full text
                                // width and the wrapper clips; at rest it fits
                                // the wrapper and elides.
                                width: marqueeOn ? implicitWidth : titleClip.width
                                elide: marqueeOn ? Text.ElideNone : Text.ElideRight
                                text: sessionRow.modelData.title
                                opacity: sessionRow.modelData.state === "idle" ? 0.65 : 1.0
                                font.family: sessionsFm.font.family
                                font.pointSize: sessionsFm.font.pointSize

                                // Hover marquee, instant start: scroll left at
                                // 60px/s until the tail is flush, hold, snap
                                // back, loop while hovered. Animates only x —
                                // never a layout width — so it can't feed back
                                // into sizing. Snaps home on hover exit.
                                SequentialAnimation {
                                    running: titleLabel.marqueeOn
                                    loops: Animation.Infinite
                                    onRunningChanged: if (!running) titleLabel.x = 0

                                    PropertyAction { target: titleLabel; property: "x"; value: 0 }
                                    NumberAnimation {
                                        target: titleLabel
                                        property: "x"
                                        to: -titleLabel.overflowPx
                                        duration: Math.max(1, Math.round(titleLabel.overflowPx / 60 * 1000))
                                        easing.type: Easing.Linear
                                    }
                                    PauseAnimation { duration: 800 }
                                    PropertyAction { target: titleLabel; property: "x"; value: 0 }
                                    PauseAnimation { duration: 600 }
                                }
                            }
                        }

                        PlasmaComponents3.Label {
                            id: statusLabel
                            visible: sessionRow.modelData.state !== "idle"
                            text: sessionRow.attention ? i18n("ready")
                                                       : i18n("working")
                            color: sessionRow.stateColor
                            font.italic: true
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                            // "ready" pulses in step with the green dot
                            // (same 1400ms rate); "working" sits faded and
                            // static — its dot alone carries the "alive"
                            // signal.
                            opacity: sessionRow.attention ? 1.0 : 0.55

                            SequentialAnimation {
                                running: statusLabel.visible && sessionRow.attention
                                loops: Animation.Infinite
                                onStopped: statusLabel.opacity =
                                               sessionRow.attention ? 1.0 : 0.55
                                NumberAnimation {
                                    target: statusLabel; property: "opacity"
                                    to: 0.45; duration: 1400
                                    easing.type: Easing.InOutQuad
                                }
                                NumberAnimation {
                                    target: statusLabel; property: "opacity"
                                    to: 1.0; duration: 1400
                                    easing.type: Easing.InOutQuad
                                }
                            }
                        }

                        // Idle rows: how long the session has sat idle, in
                        // the gray slot where active rows show their status
                        // text. Hidden under a minute. tickSec drives the
                        // refresh, so it stays current while the popup is
                        // open.
                        PlasmaComponents3.Label {
                            visible: sessionRow.modelData.state === "idle"
                                     && sessionRow.modelData.idleSince > 0
                                     && root.tickSec - sessionRow.modelData.idleSince >= 60
                            text: Utils.fmtIdle(root.tickSec - sessionRow.modelData.idleSince)
                            color: Kirigami.Theme.disabledTextColor
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                        }

                        // ✕, far right, hover-only: closes that session's
                        // terminal window (KWin close request — the app can
                        // still prompt/refuse; nothing is killed).
                        PlasmaComponents3.ToolButton {
                            visible: sessionRow.containsMouse
                            icon.name: "window-close"
                            text: i18n("Close session window")
                            display: PlasmaComponents3.AbstractButton.IconOnly
                            Layout.preferredHeight: sessionsList.rowHeight - 2
                            Layout.preferredWidth: Layout.preferredHeight
                            onClicked: root.closeSession(sessionRow.modelData.row)
                        }
                    }
                }
            }
        }

        Kirigami.Separator {
            visible: root.sessions.length > 0
            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.smallSpacing
        }

        // Inline notice when showing cached values (token expired / offline).
        Kirigami.InlineMessage {
            Layout.fillWidth: true
            visible: full.cachedView && root.state !== "ok"
            type: Kirigami.MessageType.Warning
            text: root.stateHeading(root.state)
        }

        Repeater {
            model: root.popupGroups
            delegate: MetricGroup {
                required property var modelData
                required property int index

                Layout.fillWidth: true
                groupItems: modelData.items
                resetEpoch: modelData.resets
                dimmed: full.cachedView
                revealed: full.revealed
                showSeparator: index > 0

                // Staggered reveal: each bar starts a beat after the last,
                // counting across groups so the cascade doesn't restart.
                staggerBase: {
                    var n = 0;
                    for (var i = 0; i < index; i++)
                        n += root.popupGroups[i].items.length;
                    return n;
                }
            }
        }

        // No flexible spacer here: the popup is sized to its content, so a
        // fillHeight Item adds nothing but an extra ColumnLayout spacing gap
        // above the separator.

        // Footer: hairline + "updated" line + cached chip.
        Kirigami.Separator {
            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.smallSpacing
        }

        // Chip on the left, timing text right-aligned — so the footer's metadata
        // lines up with the reset lines above it, all flush to the right edge.
        RowLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing

            Rectangle {
                visible: full.cachedView
                radius: height / 2
                color: Qt.alpha(Kirigami.Theme.neutralTextColor, 0.15)
                implicitHeight: cachedLabel.implicitHeight + Kirigami.Units.smallSpacing
                implicitWidth: cachedLabel.implicitWidth + Kirigami.Units.largeSpacing

                PlasmaComponents3.Label {
                    id: cachedLabel
                    anchors.centerIn: parent
                    text: i18n("cached")
                    color: Kirigami.Theme.neutralTextColor
                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                }
            }

            PlasmaComponents3.Label {
                // fillWidth + AlignRight (not Layout.alignment) so this label
                // eats the slack in the row: it stays pinned right whether or
                // not the chip is there to push it.
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignRight

                // Exact age of the data in seconds, plus when the daemon polls
                // next (it publishes next_poll, so this follows its real
                // cadence and backoff). Both are snapshots taken when the popup
                // opens / new data lands — not a live per-second stopwatch.
                // When showing cached/stale data this line goes full-opacity so
                // the age — not just the dimmed gauges — explains itself.
                readonly property string nextText: root.nextPoll > 0
                      ? (root.nextPoll > root.nowSec
                         ? i18n("next in <i>%1</i>", Utils.fmtAge(root.nextPoll - root.nowSec))
                         : i18n("next due now"))
                      : ""
                textFormat: Text.StyledText
                text: root.updated > 0
                      ? i18n("Updated <i>%1</i> ago", Utils.fmtAge(root.nowSec - root.updated))
                        + (nextText ? " · " + nextText : "")
                      : i18n("Updated —")
                color: full.cachedView ? Kirigami.Theme.neutralTextColor
                                       : Kirigami.Theme.textColor
                opacity: full.cachedView ? 1.0 : 0.7
                font.pointSize: Kirigami.Theme.smallFont.pointSize
            }
        }
    }
}
