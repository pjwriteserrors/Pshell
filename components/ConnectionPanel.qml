pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Controls.impl as QQCImpl

Column {
    id: root
    required property var backend
    property bool wireless: false
    signal disconnectRequested
    spacing: 18
    Rectangle {
        width: parent.width; height: 184; radius: 92
        color: Atelier.ink
        FolioArtwork { anchors.fill: parent; anchors.margins: 10; tint: Atelier.sage }
        Column {
            anchors.centerIn: parent; spacing: 10
            QQCImpl.IconImage { anchors.horizontalCenter: parent.horizontalCenter; width: 32; height: 32; color: Atelier.gold; source: root.wireless ? "/usr/share/icons/Adwaita/symbolic/status/bluetooth-active-symbolic.svg" : Atelier.icon("network-wired-symbolic") }
            AtelierText {
                anchors.horizontalCenter: parent.horizontalCenter; display: true; font.pixelSize: 28; color: Atelier.paper
                text: root.wireless ? (root.backend.powered ? "Discover nearby" : "Radio is resting") : (root.backend.currentType === "offline" ? "Off the grid" : "You're connected")
            }
        }
    }
    Row {
        visible: root.wireless; width: parent.width; spacing: 10
        Repeater {
            model: [root.backend.powered ? "Turn off" : "Turn on", root.backend.scanning ? "Searching…" : "Find devices"]
            delegate: Rectangle {
                required property string modelData
                required property int index
                width: (root.width - 10) / 2; height: 40; radius: 20; color: index === 1 ? Atelier.accent : Atelier.surface
                AtelierText { anchors.centerIn: parent; text: parent.modelData; color: parent.index === 1 ? Atelier.onAccent : Atelier.text; font.pixelSize: 12 }
                MouseArea { anchors.fill: parent; enabled: parent.index === 0 || !!root.backend.powered; onClicked: parent.index === 0 ? root.backend.togglePower() : root.backend.startScan() }
            }
        }
    }
    Column {
        width: parent.width; spacing: 14; visible: !root.wireless
        AtelierText { width: parent.width; text: root.wireless ? "" : root.backend.currentInterface + "  /  " + root.backend.currentIp; font.family: Atelier.mono; font.pixelSize: 11; elide: Text.ElideMiddle }
        Repeater {
            model: root.wireless ? [] : [{label:"RECEIVING",value:root.backend.currentDownloadSpeed,history:root.backend.downloadHistory},{label:"SENDING",value:root.backend.currentUploadSpeed,history:root.backend.uploadHistory}]
            delegate: Item {
                id: metric
                required property var modelData
                width: root.width; height: 100
                AtelierText { text: metric.modelData.label; font.family: Atelier.mono; font.pixelSize: 9; color: Atelier.muted }
                AtelierText { y: 18; text: root.backend.formatSpeed(metric.modelData.value); display: true; font.pixelSize: 34 }
                Canvas {
                    id: trace
                    y: 66; width: parent.width; height: 32
                    property var values: metric.modelData.history || []
                    onValuesChanged: requestPaint()
                    onWidthChanged: requestPaint()
                    onPaint: {
                        const c=getContext("2d"); c.reset();
                        const max=Math.max(1,...values);
                        c.strokeStyle=Atelier.sage; c.lineWidth=2; c.beginPath();
                        for(let i=0;i<values.length;i++) {
                            const x=i*width/Math.max(1,values.length-1), y=height-2-values[i]/max*(height-4);
                            if(i===0)c.moveTo(x,y);else c.lineTo(x,y);
                        }
                        c.stroke();
                    }
                }
            }
        }
        Rectangle {
            width: parent.width; height: 40; radius: 20; color: Atelier.surface; visible: !root.wireless && root.backend.currentType !== "offline"
            AtelierText { anchors.centerIn: parent; text: "Disconnect"; font.pixelSize: 12 }
            MouseArea { anchors.fill: parent; onClicked: root.disconnectRequested() }
        }
    }
    GridView {
        id: devices
        visible: root.wireless && root.backend.powered
        width: parent.width; height: visible ? 256 : 0; clip: true
        model: root.wireless ? root.backend.devices : []
        cellWidth: width / 2; cellHeight: 126
        delegate: Item {
            id: device
            required property var modelData
            width: devices.cellWidth; height: devices.cellHeight
            Rectangle {
                width: parent.width - 8; height: parent.height - 8; radius: 18
                color: device.modelData.connected ? Atelier.selectedSurface : Atelier.surface
                AtelierText { x: 14; y: 14; text: device.modelData.connected ? "● LINKED" : "○ NEARBY"; font.family: Atelier.mono; font.pixelSize: 9 }
                AtelierText { x: 14; y: 38; width: parent.width - 28; text: device.modelData.name; wrapMode: Text.WordWrap; maximumLineCount: 2; elide: Text.ElideRight; font.pixelSize: 14 }
                AtelierText { x: 14; y: 88; width: parent.width - 28; elide: Text.ElideRight; text: root.backend.deviceStatuses[device.modelData.address] || device.modelData.battery || (device.modelData.paired ? "Paired" : "Tap to connect"); color: Atelier.muted; font.pixelSize: 10 }
                MouseArea { anchors.fill: parent; onClicked: root.backend.connectDevice(device.modelData.address) }
            }
        }
        AtelierText { anchors.centerIn: parent; visible: devices.count === 0; text: "Your nearby devices will appear here."; width: parent.width - 30; wrapMode: Text.WordWrap; horizontalAlignment: Text.AlignHCenter; color: Atelier.muted }
    }
}
