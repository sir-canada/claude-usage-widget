import QtQuick
import org.kde.kirigami as Kirigami

// Slim rounded progress bar. `value` is 0..1; `revealed` gates the
// popup-open reveal animation.
Item {
    id: gauge

    property real value: 0
    property color fillColor: Kirigami.Theme.highlightColor
    property bool revealed: true
    property bool dimmed: false

    implicitHeight: 6

    Rectangle {
        anchors.fill: parent
        radius: height / 2
        color: Qt.alpha(Kirigami.Theme.textColor, 0.12)
    }

    Rectangle {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        height: parent.height
        radius: height / 2
        color: gauge.fillColor
        opacity: gauge.dimmed ? 0.4 : 1.0
        width: gauge.revealed ? Math.max(height, parent.width * Math.max(0, Math.min(1, gauge.value))) : 0
        visible: gauge.value > 0

        Behavior on width {
            NumberAnimation { duration: Kirigami.Units.longDuration * 3; easing.type: Easing.OutCubic }
        }
        Behavior on color {
            ColorAnimation { duration: Kirigami.Units.longDuration }
        }
    }
}
