pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Wayland

PanelWindow {
    id: surface
    required property bool open
    required property Item barItem
    property var controller: null
    property var anchorWindow: null
    property string anchorMode: "center"
    property Item anchorItem: null
    property real expandedWidth: 400
    property real contentPreferredHeight: 0
    property real fixedHeight: -1
    property real contentMargins: 28
    property color surfaceColor: Atelier.canvas
    property color borderColor: Atelier.rule
    property real restingRadius: 20
    property real edgeMargin: 24
    property real barGap: 0
    property real barTopMargin: 0
    property bool wantsKeyboard: true
    property string title: "Overview"
    property string chapter: "01"
    property string subtitle: "A little space for your day."
    property string motif: "orbit"
    property color tone: Atelier.sage
    property var destinations: [
        {name: "calendar", label: "Day"},
        {name: "weather", label: "Weather"},
        {name: "resources", label: "System"},
        {name: "media", label: "Listen"}
    ]
    default property alias content: contentSlot.data
    readonly property Item contentArea: contentSlot
    readonly property real expandedHeight: fixedHeight > 0 ? fixedHeight : Math.max(52, contentPreferredHeight + contentMargins * 2)
    readonly property real shellWidth: expandedWidth
    readonly property real contentOpacity: openProgress
    property real openProgress: open ? 1 : 0
    signal dismissRequested()

    anchors { left: true; right: true; top: true; bottom: true }
    exclusiveZone: 0
    color: "transparent"
    WlrLayershell.exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: visible && wantsKeyboard ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
    Behavior on openProgress { NumberAnimation { duration: surface.open ? 260 : 160; easing.type: Easing.OutCubic } }

    Rectangle { anchors.fill: parent; color: Atelier.scrim; opacity: surface.openProgress * 0.36 }
    MouseArea { anchors.fill: parent; onClicked: surface.dismissRequested() }
    Rectangle {
        id: folio

        // Escape closes every popup. The handler sits on the card itself, an
        // ancestor of the content, so an unhandled key from a focused field
        // inside travels up to here.
        focus: true
        Keys.onEscapePressed: event => { event.accepted = true; surface.dismissRequested(); }

        readonly property real spine: surface.width >= 900 ? 248 : 176
        width: Math.min(surface.expandedWidth + spine, surface.width - 136)
        height: Math.min(Math.max(surface.expandedHeight + 24, 500), surface.height - 56)
        x: Math.max(108, (surface.width - width) / 2 + 44)
        y: (surface.height - height) / 2 + 20 * (1 - surface.openProgress)
        radius: 20
        color: Atelier.canvas
        opacity: surface.openProgress
        clip: true
        MouseArea { anchors.fill: parent }
        Rectangle {
            width: folio.spine
            height: parent.height
            color: Qt.tint(Atelier.canvas, Qt.alpha(surface.tone, 0.2))
            AtelierText { x: 28; y: 30; text: "ATELIER  /  " + surface.chapter; font.family: Atelier.mono; font.pixelSize: 10; font.letterSpacing: 1.5 }
            AtelierText { x: 28; y: 88; width: parent.width - 48; text: surface.title; display: true; font.pixelSize: 36; wrapMode: Text.WordWrap }
            AtelierText { x: 28; y: 190; width: parent.width - 56; text: surface.subtitle; font.pixelSize: 12; color: Atelier.muted; wrapMode: Text.WordWrap }
            FolioArtwork { x: 12; y: 250; width: parent.width - 24; height: Math.max(80, parent.height - 392); tint: surface.tone; motif: surface.motif }
            Flow {
                x: 24; width: parent.width - 48
                anchors.bottom: parent.bottom; anchors.bottomMargin: 34
                spacing: 8
                Repeater {
                    model: surface.destinations
                    delegate: Rectangle {
                        required property var modelData
                        width: destination.implicitWidth + 20; height: 30; radius: 15
                        color: mouse.containsMouse ? Qt.alpha(surface.tone, 0.24) : Qt.alpha(Atelier.canvas, 0.6)
                        AtelierText { id: destination; anchors.centerIn: parent; text: parent.modelData.label; font.pixelSize: 11 }
                        MouseArea {
                            id: mouse; anchors.fill: parent; hoverEnabled: true
                            onClicked: if (surface.controller) surface.controller.navigatePanel(parent.modelData.name);
                        }
                    }
                }
            }
        }
        Flickable {
            x: folio.spine + surface.contentMargins
            y: surface.contentMargins + 16
            width: folio.width - folio.spine - surface.contentMargins * 2
            height: folio.height - surface.contentMargins * 2 - 16
            contentHeight: contentSlot.height
            contentWidth: width
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
            Item {
                id: contentSlot
                width: parent.width
                height: surface.expandedHeight - surface.contentMargins * 2
            }
        }
        Item {
            anchors.right: parent.right; anchors.top: parent.top
            width: 38; height: 38
            AtelierText { anchors.centerIn: parent; text: "×"; font.pixelSize: 22; color: Atelier.muted }
            MouseArea { anchors.fill: parent; onClicked: surface.dismissRequested() }
        }
    }
}
