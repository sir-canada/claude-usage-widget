import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM
import org.kde.taskmanager as TaskManager

KCM.SimpleKCM {
    id: page

    property alias cfg_showPercentText: showPercentText.checked
    property alias cfg_showTimeLeft: showTimeLeft.checked
    property alias cfg_showWeekly: showWeekly.checked
    property alias cfg_showScoped: showScoped.checked
    property int cfg_refreshSeconds
    property string cfg_sessionsFontFamily
    property int cfg_sessionsFontSize

    // The KCM host passes cfg_<key>Default initial properties for every key;
    // declare them so "Setting initial properties failed" stops landing in
    // the journal. Values unused.
    property bool cfg_showPercentTextDefault
    property bool cfg_showTimeLeftDefault
    property bool cfg_showWeeklyDefault
    property bool cfg_showScopedDefault
    property int cfg_refreshSecondsDefault
    property string cfg_sessionsFontFamilyDefault
    property int cfg_sessionsFontSizeDefault

    // ---- live session titles for the font preview ----
    // Same title parse as main.qml: Claude Code sessions are terminal windows
    // titled "✳ title" (idle) or "<braille spinner> title" (working), with an
    // optional "🔔 " bell prefix. Real titles make the preview honest; when
    // fewer than three exist, invented ones fill the remaining rows.
    property var liveTitles: []

    function harvestTitles() {
        var re = /^(🔔\s*)?([✳⠀-⣿])\s+(.+)$/;
        var out = [];
        for (var i = 0; i < tasksModel.count && out.length < 3; i++) {
            var idx = tasksModel.makeModelIndex(i);
            var m = re.exec(String(tasksModel.data(idx, Qt.DisplayRole) || ""));
            if (m)
                out.push(m[3]);
        }
        // Replace only on real change; the array feeds a Repeater.
        if (JSON.stringify(out) !== JSON.stringify(liveTitles))
            liveTitles = out;
    }

    TaskManager.TasksModel {
        id: tasksModel
        filterByVirtualDesktop: false
        filterByScreen: false
        filterByActivity: false
        filterMinimized: false
        groupMode: TaskManager.TasksModel.GroupDisabled
        onCountChanged: harvestQuiesce.restart()
    }

    // The model populates asynchronously after the dialog opens; a short
    // quiesce collapses the initial burst of count changes into one harvest.
    Timer {
        id: harvestQuiesce
        interval: 250
        onTriggered: page.harvestTitles()
    }
    Component.onCompleted: harvestQuiesce.start()

    // One row per state so the preview always demos all three: waiting on
    // you, working, idle. Live titles slot in positionally; examples cover
    // the rest.
    readonly property var previewRows: {
        var ex = [i18n("fix daemon polling backoff"),
                  i18n("add font preview to config"),
                  i18n("update README screenshots")];
        var t = liveTitles;
        return [
            { state: "attention", title: t.length > 0 ? t[0] : ex[0] },
            { state: "working",   title: t.length > 1 ? t[1] : ex[1] },
            { state: "idle",      title: t.length > 2 ? t[2] : ex[2] }
        ];
    }

    Kirigami.FormLayout {
        QQC2.CheckBox {
            id: showPercentText
            Kirigami.FormData.label: i18n("Panel:")
            text: i18n("Show % sign after the number")
        }
        QQC2.CheckBox {
            id: showTimeLeft
            text: i18n("Show time left in the 5-hour window")
        }

        Item { Kirigami.FormData.isSection: true }

        QQC2.CheckBox {
            id: showWeekly
            Kirigami.FormData.label: i18n("Popup:")
            text: i18n("Show weekly limit")
        }
        QQC2.CheckBox {
            id: showScoped
            text: i18n("Show model-scoped weekly limit")
        }

        Item { Kirigami.FormData.isSection: true }

        QQC2.ComboBox {
            Kirigami.FormData.label: i18n("Refresh interval:")
            textRole: "text"
            valueRole: "value"
            model: [
                { text: i18n("30 seconds"), value: 30 },
                { text: i18n("1 minute"), value: 60 },
                { text: i18n("2 minutes"), value: 120 },
                { text: i18n("5 minutes"), value: 300 }
            ]
            Component.onCompleted: currentIndex = Math.max(0, indexOfValue(page.cfg_refreshSeconds))
            onActivated: page.cfg_refreshSeconds = currentValue
        }

        Item { Kirigami.FormData.isSection: true }

        QQC2.ComboBox {
            id: sessionsFontCombo
            Kirigami.FormData.label: i18n("Sessions list font:")
            editable: false

            // Every row renders in the UI font — the panel below is the
            // preview — so the list is built once, up front. Never swap the
            // model while the popup is opening: the popup sizes itself and
            // builds delegates from the old model first, and the stale rows
            // paint over the new ones.
            model: [i18n("Theme default")].concat(Qt.fontFamilies())

            Component.onCompleted: {
                var i = page.cfg_sessionsFontFamily === ""
                        ? 0 : model.indexOf(page.cfg_sessionsFontFamily);
                currentIndex = i > 0 ? i : 0;
            }
            onActivated: page.cfg_sessionsFontFamily =
                             currentIndex === 0 ? "" : currentText
        }

        QQC2.SpinBox {
            Kirigami.FormData.label: i18n("Sessions list size:")
            from: 0
            to: 32
            value: page.cfg_sessionsFontSize
            textFromValue: (v, locale) => v === 0 ? i18n("Theme default") : (v + " pt")
            valueFromText: (t, locale) => parseInt(t) || 0
            onValueModified: page.cfg_sessionsFontSize = value
        }

        // ---- live preview of the sessions list ----
        // Mirrors the popup's row styling (dot + ring, title, status label,
        // font-driven row height) using the family/size currently selected
        // above — updates the moment either changes, before Apply.
        Rectangle {
            id: previewPanel
            Kirigami.FormData.label: i18n("Preview:")
            Kirigami.FormData.labelAlignment: Qt.AlignTop

            Kirigami.Theme.inherit: false
            Kirigami.Theme.colorSet: Kirigami.Theme.View

            radius: 6
            color: Kirigami.Theme.backgroundColor
            border.width: 1
            border.color: Qt.alpha(Kirigami.Theme.textColor, 0.15)

            implicitWidth: Kirigami.Units.gridUnit * 18
            implicitHeight: previewCol.implicitHeight
                            + Kirigami.Units.largeSpacing * 2

            FontMetrics {
                id: previewFm
                font.family: page.cfg_sessionsFontFamily !== ""
                             ? page.cfg_sessionsFontFamily
                             : Kirigami.Theme.defaultFont.family
                font.pointSize: page.cfg_sessionsFontSize > 0
                                ? page.cfg_sessionsFontSize
                                : Kirigami.Theme.defaultFont.pointSize
            }

            // Same row-height rule as the popup's sessions list.
            readonly property real rowHeight:
                Math.max(previewFm.height, Kirigami.Units.gridUnit)
                + Kirigami.Units.smallSpacing * 2

            ColumnLayout {
                id: previewCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.margins: Kirigami.Units.largeSpacing
                spacing: Math.round(Kirigami.Units.smallSpacing / 2)

                Repeater {
                    model: page.previewRows
                    delegate: RowLayout {
                        id: previewRow
                        required property var modelData

                        readonly property bool attention: modelData.state === "attention"
                        readonly property bool working: modelData.state === "working"
                        readonly property color stateColor: attention
                            ? Kirigami.Theme.positiveTextColor
                            : working ? Kirigami.Theme.neutralTextColor
                                      : Kirigami.Theme.disabledTextColor

                        Layout.fillWidth: true
                        Layout.preferredHeight: previewPanel.rowHeight
                        spacing: Kirigami.Units.smallSpacing * 2

                        // Status dot + ring, pulsing like the real popup:
                        // attention breathes at 1400ms, working at 2500ms,
                        // idle static.
                        Item {
                            id: previewDot
                            implicitWidth: 8
                            implicitHeight: 8

                            Rectangle {
                                anchors.fill: parent
                                radius: 4
                                color: previewRow.stateColor
                            }
                            Rectangle {
                                visible: previewRow.modelData.state !== "idle"
                                anchors.centerIn: parent
                                width: 14
                                height: 14
                                radius: 7
                                color: "transparent"
                                border.width: 2
                                border.color: Qt.alpha(previewRow.stateColor, 0.35)
                            }
                            SequentialAnimation {
                                running: previewRow.attention || previewRow.working
                                loops: Animation.Infinite
                                onStopped: previewDot.opacity = 1
                                NumberAnimation {
                                    target: previewDot; property: "opacity"
                                    to: 0.45
                                    duration: previewRow.attention ? 1400 : 2500
                                    easing.type: Easing.InOutQuad
                                }
                                NumberAnimation {
                                    target: previewDot; property: "opacity"
                                    to: 1.0
                                    duration: previewRow.attention ? 1400 : 2500
                                    easing.type: Easing.InOutQuad
                                }
                            }
                        }

                        QQC2.Label {
                            Layout.fillWidth: true
                            text: previewRow.modelData.title
                            elide: Text.ElideRight
                            opacity: previewRow.modelData.state === "idle" ? 0.65 : 1.0
                            font.family: previewFm.font.family
                            font.pointSize: previewFm.font.pointSize
                        }

                        QQC2.Label {
                            id: previewStatus
                            visible: previewRow.modelData.state !== "idle"
                            text: previewRow.attention ? i18n("ready")
                                                       : i18n("working")
                            color: previewRow.stateColor
                            font.italic: true
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                            opacity: previewRow.attention ? 1.0 : 0.55

                            // "ready" pulses with the green dot; "working"
                            // stays static — mirrors the popup.
                            SequentialAnimation {
                                running: previewStatus.visible && previewRow.attention
                                loops: Animation.Infinite
                                NumberAnimation {
                                    target: previewStatus; property: "opacity"
                                    to: 0.45; duration: 1400
                                    easing.type: Easing.InOutQuad
                                }
                                NumberAnimation {
                                    target: previewStatus; property: "opacity"
                                    to: 1.0; duration: 1400
                                    easing.type: Easing.InOutQuad
                                }
                            }
                        }

                        // Idle rows carry an idle-for badge in the popup;
                        // static sample here.
                        QQC2.Label {
                            visible: previewRow.modelData.state === "idle"
                            text: "2h14m"
                            color: Kirigami.Theme.disabledTextColor
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                        }
                    }
                }
            }
        }
    }
}
