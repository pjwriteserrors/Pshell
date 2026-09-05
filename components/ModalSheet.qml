pragma ComponentBehavior: Bound
import QtQuick

Item {
    id: sheet
    required property bool open
    property real scrimOpacity: 0.34
    property string mode: "center"
    property real sheetWidth: 980
    property real sheetHeight: 620
    property real bottomMargin: 0
    property color shadowSurfaceColor: Atelier.canvas
    property string title: "Studio"
    property string caption: "Make room for what matters."
    property var controller: null
    property bool studio: false
    property real reveal: open ? 1 : 0
    default property alias content: container.data
    readonly property Item containerItem: container
    readonly property bool centered: true
    signal dismissRequested()
    anchors.fill: parent
    Behavior on reveal { NumberAnimation { duration: sheet.open ? 280 : 160; easing.type: Easing.OutCubic } }
    Rectangle { anchors.fill: parent; color: Atelier.ink; opacity: sheet.reveal * 0.42 }
    MouseArea { anchors.fill: parent; onClicked: sheet.dismissRequested() }
    Rectangle {
        id: frame
        width: Math.min(sheet.sheetWidth + 72, parent.width - 152)
        height: Math.min(sheet.sheetHeight + 124, parent.height - 56)
        x: Math.max(108, (parent.width - width) / 2 + 44)
        y: (parent.height - height) / 2 + 24 * (1 - sheet.reveal)
        opacity: sheet.reveal
        radius: 24; color: Atelier.canvas; clip: true
        MouseArea { anchors.fill: parent }
        Rectangle { x: 36; y: 36; width: 7; height: 38; radius: 3; color: Atelier.accent }
        AtelierText { x: 58; y: 26; text: sheet.title; display: true; font.pixelSize: 42 }
        AtelierText { x: 60; y: 78; text: sheet.caption; font.pixelSize: 12; color: Atelier.muted; visible: !sheet.studio }
        Row {
            x: 60; y: 78; spacing: 20; visible: sheet.studio
            Repeater {
                model: [{name:"presets",label:"Styles"}, {name:"wallpaper",label:"Wallpapers"}, {name:"animations",label:"Motion"}]
                delegate: AtelierText {
                    required property var modelData
                    text: modelData.label; font.pixelSize: 12
                    color: mouse.containsMouse ? Atelier.accent : Atelier.muted
                    MouseArea { id: mouse; anchors.fill: parent; hoverEnabled: true; onClicked: if(sheet.controller) sheet.controller.navigatePanel(parent.modelData.name) }
                }
            }
        }
        Item {
            anchors.right: parent.right; anchors.rightMargin: 22; y: 26
            width: 42; height: 42
            Rectangle { anchors.fill: parent; radius: 21; color: Atelier.surface }
            AtelierText { anchors.centerIn: parent; text: "×"; font.pixelSize: 24 }
            MouseArea { anchors.fill: parent; onClicked: sheet.dismissRequested() }
        }
        Item {
            id: container
            x: 36; y: 112
            width: frame.width - 72
            height: frame.height - 136
        }
    }
}
