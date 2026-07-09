import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PlasmaComponents3
import "utils.js" as Utils

MouseArea {
    id: compact

    readonly property bool vertical: Plasmoid.formFactor === PlasmaCore.Types.Vertical
    readonly property var fh: root.fiveHour
    readonly property real pct: fh ? (fh.pct || 0) : 0
    readonly property bool hasData: root.ready && !!fh
    readonly property bool errored: root.ready && !root.ok && !fh

    Layout.minimumWidth: vertical ? 0 : column.implicitWidth + Kirigami.Units.smallSpacing
    Layout.minimumHeight: vertical ? column.implicitHeight + Kirigami.Units.smallSpacing : 0

    hoverEnabled: true

    // Hover opens the popup (Noctalia-style); moving away closes it after a
    // short grace period unless the pointer moved into the popup itself.
    onContainsMouseChanged: {
        root.compactHovered = containsMouse;
        if (containsMouse)
            root.expanded = true;
        else
            root.scheduleCollapse();
    }

    // Click pins the popup open (click again or click elsewhere to release).
    onClicked: {
        root.pinned = !root.pinned;
        if (root.pinned)
            root.expanded = true;
    }

    // As compact as possible: the countdown stacks *under* the number so
    // the widget is only as wide as its widest line (clock-style).
    ColumnLayout {
        id: column
        anchors.centerIn: parent
        spacing: -2

        // Icon only as a stand-in while loading / on error, so there is
        // still something to hover.
        IconWithBadge {
            visible: !compact.hasData
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredWidth: Kirigami.Units.iconSizes.small
            Layout.preferredHeight: Kirigami.Units.iconSizes.small
        }

        PercentLabel {
            Layout.alignment: Qt.AlignHCenter
        }

        PlasmaComponents3.Label {
            visible: compact.hasData && plasmoid.configuration.showTimeLeft && !!(compact.fh && compact.fh.resets_epoch) && !compact.vertical
            Layout.alignment: Qt.AlignHCenter
            text: compact.fh && compact.fh.resets_epoch ? Utils.fmtDuration(compact.fh.resets_epoch - root.nowSec) : ""
            opacity: 0.7
            font.pointSize: Kirigami.Theme.smallFont.pointSize * 0.85
            font.features: ({ "tnum": 1 })
        }
    }

    // Ambient fill indicator, battery-style: only once it matters.
    Rectangle {
        visible: compact.hasData && compact.pct >= 60 && !compact.vertical
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        height: 2
        width: parent.width * Math.min(1, compact.pct / 100)
        radius: 1
        color: Qt.alpha(root.usageColor(compact.pct), 0.6)

        Behavior on width {
            NumberAnimation { duration: Kirigami.Units.longDuration * 3; easing.type: Easing.OutCubic }
        }
    }

    component PercentLabel: PlasmaComponents3.Label {
        visible: compact.hasData
        text: compact.pct + (plasmoid.configuration.showPercentText ? "%" : "")
        color: root.usageColor(compact.pct)
        font.weight: Font.DemiBold
        font.features: ({ "tnum": 1 })
    }

    component IconWithBadge: Item {
        Kirigami.Icon {
            id: icon
            anchors.fill: parent
            source: Qt.resolvedUrl("../icons/claude-usage.svg")
            opacity: root.ready ? 1.0 : 0.5

            // Slow pulse while first load is in flight.
            SequentialAnimation on opacity {
                running: !root.ready
                loops: Animation.Infinite
                NumberAnimation { to: 0.25; duration: 900; easing.type: Easing.InOutQuad }
                NumberAnimation { to: 0.6; duration: 900; easing.type: Easing.InOutQuad }
            }
        }

        // Small warning dot instead of scary text in the panel.
        Rectangle {
            visible: compact.errored || (root.ready && (root.state === "expired" || root.state === "noauth"))
            anchors.top: parent.top
            anchors.right: parent.right
            width: Math.round(parent.width * 0.38)
            height: width
            radius: width / 2
            color: Kirigami.Theme.negativeTextColor
            border.width: 1
            border.color: Kirigami.Theme.backgroundColor
        }
    }
}
