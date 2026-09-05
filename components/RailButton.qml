pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.impl as QQCImpl
import Quickshell

Item {
    id: root
    required property string icon
    required property string label
    property bool active: false
    property color accent: Atelier.gold
    signal clicked
    width: 64
    height: 55
    Rectangle {
        anchors.horizontalCenter: parent.horizontalCenter
        width: 42; height: 34; radius: 17
        color: root.active ? root.accent : mouse.containsMouse ? "#384140" : "transparent"
        Behavior on color { ColorAnimation { duration: 140 } }
    }
    QQCImpl.IconImage {
        anchors.horizontalCenter: parent.horizontalCenter; y: 8
        width: 18; height: 18; source: Atelier.icon(root.icon)
        color: root.active ? Atelier.ink : Atelier.paper
    }
    Text {
        anchors.horizontalCenter: parent.horizontalCenter; y: 38
        text: root.label; color: root.active ? Atelier.gold : "#a9b1a4"
        font.family: Atelier.sans; font.pixelSize: 9; font.letterSpacing: 0.6
    }
    MouseArea { id: mouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.clicked() }
}
