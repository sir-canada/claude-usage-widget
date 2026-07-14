import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents3

// One usage metric: label + %, gauge. The reset countdown lives on MetricGroup,
// which owns it for the whole block — metrics that reset together shouldn't each
// print the same countdown.
ColumnLayout {
    id: row

    property var metric: null
    property bool primary: false     // 5-hour row gets the bigger treatment
    property bool revealed: true     // staggered popup-open animation
    property bool dimmed: false      // cached/stale display

    readonly property real pct: metric ? (metric.pct || 0) : 0
    readonly property color pctColor: root.usageColor(pct)

    spacing: Math.round(Kirigami.Units.smallSpacing / 2)
    opacity: dimmed ? 0.55 : 1.0

    RowLayout {
        Layout.fillWidth: true
        spacing: Kirigami.Units.smallSpacing

        PlasmaComponents3.Label {
            Layout.fillWidth: true
            text: root.metricLabel(row.metric)
            elide: Text.ElideRight
        }

        PlasmaComponents3.Label {
            text: row.pct + "%"
            color: row.pctColor
            font.pointSize: Kirigami.Theme.defaultFont.pointSize * (row.primary ? 1.35 : 1.0)
            font.weight: row.primary ? Font.DemiBold : Font.Normal
            font.features: ({ "tnum": 1 })
        }
    }

    UsageGauge {
        Layout.fillWidth: true
        value: row.pct / 100
        fillColor: row.pctColor
        revealed: row.revealed
        dimmed: row.dimmed
    }
}
