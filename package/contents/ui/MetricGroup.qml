import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents3
import "utils.js" as Utils

// A set of metrics that share one reset instant, drawn as a single block: bars
// stacked tight, one "Resets in ..." line underneath them all. The weekly pair
// (all-models + the scoped model) always resets together, so printing the same
// countdown twice was just noise.
//
// A group of one — the 5h session — renders exactly like an ordinary row, so
// this is a superset of the old layout, not a special case.
ColumnLayout {
    id: group

    property var groupItems: []
    property double resetEpoch: 0
    property bool revealed: true     // staggered popup-open animation
    property bool dimmed: false      // cached/stale display
    property int staggerBase: 0      // reveal delay offset, in row units
    property bool showSeparator: false   // set for every group but the first

    // Tighter than the largeSpacing between groups: the bars in a block read as
    // one unit, and the gap is what says so.
    spacing: Kirigami.Units.smallSpacing

    // A rule between groups — session / week / meta. Lives at the *top* of the
    // group (rather than the bottom) so it's naturally suppressed on the first
    // one, and can never dangle under the header or double up with the footer's
    // own separator.
    Kirigami.Separator {
        visible: group.showSeparator
        Layout.fillWidth: true
        Layout.topMargin: Math.round(Kirigami.Units.smallSpacing / 2)
        Layout.bottomMargin: Math.round(Kirigami.Units.smallSpacing / 2)
    }

    Repeater {
        model: group.groupItems
        delegate: MetricDelegate {
            required property var modelData
            required property int index

            Layout.fillWidth: true
            metric: modelData
            primary: modelData.key === "5h"
            dimmed: group.dimmed
            revealed: group.revealed

            Behavior on revealed {
                SequentialAnimation {
                    PauseAnimation { duration: (group.staggerBase + index) * 60 }
                    PropertyAction {}
                }
            }
        }
    }

    // Right-aligned so it settles under the end of the gauge — the metadata sits
    // in its own column instead of competing with the labels down the left edge.
    PlasmaComponents3.Label {
        visible: group.resetEpoch > 0
        Layout.fillWidth: true
        horizontalAlignment: Text.AlignRight

        // Countdown + the wall-clock instant it lands. tickSec (not nowSec) so
        // the final 90s actually counts down second by second.
        readonly property double remain: group.resetEpoch - root.tickSec
        text: group.resetEpoch > 0
              ? i18n("Resets in %1 · %2", Utils.fmtDuration(remain),
                     Utils.fmtResetWhen(group.resetEpoch, remain))
              : ""
        opacity: 0.7
        font.pointSize: Kirigami.Theme.smallFont.pointSize
        font.features: ({ "tnum": 1 })
    }
}
