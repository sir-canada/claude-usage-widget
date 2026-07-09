import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM

KCM.SimpleKCM {
    id: page

    property alias cfg_showPercentText: showPercentText.checked
    property alias cfg_showTimeLeft: showTimeLeft.checked
    property alias cfg_showWeekly: showWeekly.checked
    property alias cfg_showScoped: showScoped.checked
    property int cfg_refreshSeconds

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
    }
}
