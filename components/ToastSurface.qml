pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Wayland

PanelWindow {
    id: toast
    required property var host
    required property var modelData
    required property int index
    readonly property var notification: modelData.notification
    screen: host.popupScreenFallback(null)
    anchors { top: true; right: true }
    margins { top: 28 + index * (implicitHeight + 12); right: 28 }
    implicitWidth: 380
    implicitHeight: contents.height + 40
    exclusiveZone: 0
    color: "transparent"
    visible: true
    WlrLayershell.exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: notification.hasInlineReply ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
    Rectangle {
        anchors.fill: parent; radius: 22; color: Atelier.canvas
        Rectangle { y: 24; width: 4; height: parent.height - 48; radius: 2; color: Atelier.accent }
    }
    Column {
        id: contents
        x: 24; y: 20; width: toast.width - 48; spacing: 12
        Row {
            width: parent.width
            AtelierText { width: parent.width - 24; text: toast.notification.appName || "A new arrival"; font.family: Atelier.mono; font.pixelSize: 10; color: Atelier.muted; elide: Text.ElideRight }
            AtelierText { text: "×"; font.pixelSize: 18; MouseArea { anchors.fill: parent; anchors.margins: -8; onClicked: toast.notification.dismiss() } }
        }
        AtelierText { width: parent.width; text: toast.notification.summary; display: true; font.pixelSize: 25; wrapMode: Text.WordWrap; maximumLineCount: 3; elide: Text.ElideRight }
        AtelierText { width: parent.width; text: toast.notification.body; font.pixelSize: 12; wrapMode: Text.WordWrap; maximumLineCount: 5; elide: Text.ElideRight; visible: text !== "" }
        Image { width: parent.width; height: visible ? 100 : 0; visible: source.toString() !== ""; source: toast.notification.image; fillMode: Image.PreserveAspectFit; asynchronous: true }
        Rectangle {
            width: parent.width; height: 3; color: Atelier.rule; visible: toast.notification.hints.value !== undefined
            Rectangle { width: parent.width * Math.min(100,Math.max(0,Number(toast.notification.hints.value || 0)))/100; height: 3; color: Atelier.accent }
        }
        Flow {
            width: parent.width; spacing: 8
            Repeater {
                model: toast.notification.actions
                delegate: Rectangle {
                    required property var modelData
                    width: label.implicitWidth + 24; height: 32; radius: 16; color: Atelier.surface
                    AtelierText { id: label; anchors.centerIn: parent; text: parent.modelData.text; font.pixelSize: 11 }
                    MouseArea { anchors.fill: parent; onClicked: parent.modelData.invoke() }
                }
            }
        }
        TextField {
            id: reply; width: parent.width
            visible: toast.notification.hasInlineReply
            placeholderText: toast.notification.inlineReplyPlaceholder || "Reply and press Enter"
            onAccepted: toast.host.submitInlineReply(toast.notification, reply)
        }
    }
    Timer {
        interval: toast.modelData.duration; running: true
        onTriggered: toast.host.removeToast(toast.modelData.toastId)
    }
}
