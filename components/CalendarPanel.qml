pragma ComponentBehavior: Bound
import QtQuick

Item {
    id: root
    required property date selectedDate
    required property date today
    signal shiftMonth(int delta)
    implicitHeight: 376
    readonly property int firstDay: (new Date(selectedDate.getFullYear(), selectedDate.getMonth(), 1).getDay() + 6) % 7
    readonly property int days: new Date(selectedDate.getFullYear(), selectedDate.getMonth() + 1, 0).getDate()

    AtelierText { text: Qt.formatDate(root.selectedDate, "yyyy"); font.family: Atelier.mono; font.pixelSize: 12; color: Atelier.muted }
    AtelierText { y: 22; text: Qt.formatDate(root.selectedDate, "MMMM"); display: true; font.pixelSize: 32 }
    Row {
        anchors.right: parent.right; y: 20; spacing: 4
        Repeater {
            model: [-1, 1]
            delegate: Item {
                required property int modelData
                width: 36; height: 40
                AtelierText { anchors.centerIn: parent; text: parent.modelData < 0 ? "←" : "→"; font.pixelSize: 18 }
                HoverLayer { tint: Atelier.accent; onClicked: root.shiftMonth(parent.modelData) }
            }
        }
    }
    Rectangle { y: 78; width: parent.width; height: 1; color: Atelier.rule }
    Grid {
        y: 96; width: parent.width; columns: 7
        Repeater {
            model: ["M", "T", "W", "T", "F", "S", "S"]
            delegate: AtelierText {
                required property string modelData
                width: root.width / 7; height: 26
                text: modelData; color: Atelier.muted; font.pixelSize: 11
                horizontalAlignment: Text.AlignHCenter
            }
        }
        Repeater {
            model: 42
            delegate: Item {
                id: cell
                required property int index
                readonly property int day: index - root.firstDay + 1
                readonly property bool valid: day > 0 && day <= root.days
                readonly property bool current: valid && day === root.today.getDate()
                    && root.selectedDate.getMonth() === root.today.getMonth()
                    && root.selectedDate.getFullYear() === root.today.getFullYear()
                width: root.width / 7; height: 38
                Rectangle {
                    anchors.centerIn: parent; width: 32; height: 32; radius: 16
                    color: Atelier.accent; visible: cell.current
                }
                AtelierText {
                    anchors.centerIn: parent; text: cell.valid ? cell.day : ""
                    font.pixelSize: 14; color: cell.current ? Atelier.paper : Atelier.text
                }
            }
        }
    }
    AtelierText {
        anchors.bottom: parent.bottom
        text: Qt.formatDate(root.today, "dddd, d MMMM")
        font.pixelSize: 12; color: Atelier.muted
    }
}
