import QtQuick
import QtQuick.Layouts
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
    readonly property real wantedHeight: (header ? header.implicitHeight : 0)
                                         + contentColumn.implicitHeight
                                         + Kirigami.Units.largeSpacing * 2

    Layout.preferredWidth: Kirigami.Units.gridUnit * 20
    Layout.preferredHeight: Math.max(wantedHeight, Kirigami.Units.gridUnit * 12)
    Layout.minimumHeight: Math.max(wantedHeight, Kirigami.Units.gridUnit * 12)
    Layout.minimumWidth: Kirigami.Units.gridUnit * 16
    Layout.maximumWidth: Kirigami.Units.gridUnit * 24

    collapseMarginsHint: true

    header: PlasmaExtras.PlasmoidHeading {
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Kirigami.Units.smallSpacing
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

            PlasmaComponents3.ToolButton {
                id: refreshButton
                icon.name: "view-refresh"
                enabled: !root.fetching
                display: PlasmaComponents3.AbstractButton.IconOnly
                text: i18n("Refresh")
                onClicked: root.refresh()

                PlasmaComponents3.ToolTip.text: text
                PlasmaComponents3.ToolTip.visible: hovered

                RotationAnimation on rotation {
                    running: root.fetching
                    loops: Animation.Infinite
                    from: 0
                    to: 360
                    duration: 900
                }
                // Settle back upright when the fetch finishes.
                RotationAnimation on rotation {
                    running: !root.fetching && refreshButton.rotation !== 0
                    to: 360
                    duration: 300
                    easing.type: Easing.OutCubic
                    onFinished: refreshButton.rotation = 0
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
        spacing: Kirigami.Units.largeSpacing

        // Inline notice when showing cached values (token expired / offline).
        Kirigami.InlineMessage {
            Layout.fillWidth: true
            visible: full.cachedView && root.state !== "ok"
            type: Kirigami.MessageType.Warning
            text: root.stateHeading(root.state)
        }

        Repeater {
            model: root.popupItems
            delegate: MetricDelegate {
                required property var modelData
                required property int index
                Layout.fillWidth: true
                metric: modelData
                primary: modelData.key === "5h"
                dimmed: full.cachedView
                revealed: full.revealed

                // Staggered reveal: each row starts a beat after the last.
                Behavior on revealed {
                    SequentialAnimation {
                        PauseAnimation { duration: index * 60 }
                        PropertyAction {}
                    }
                }
            }
        }

        // No flexible spacer here: the popup is sized to its content, so a
        // fillHeight Item adds nothing but an extra ColumnLayout spacing gap
        // above the separator.

        // Footer: hairline + "updated" line + cached chip.
        Kirigami.Separator { Layout.fillWidth: true }

        RowLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing

            PlasmaComponents3.Label {
                Layout.fillWidth: true
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
        }
    }
}
