pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.impl as QQCImpl
import Quickshell
import Quickshell.Services.SystemTray
import "components"

PanelWindow {
    id: rail
    required property var host
    required property var niri
    required property var monitor
    screen: monitor
    anchors { left: true; top: true; bottom: true }
    implicitWidth: 88
    exclusiveZone: 88
    color: Atelier.ink

    // The rail can now be light chrome on a light wallpaper, so it needs an
    // explicit edge instead of relying on a dark panel to separate itself.
    Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: Atelier.rule }

    Column {
        id: crown
        x: 12; y: 22; width: 64; spacing: 20
        Item {
            width: 64; height: 38
            Rectangle { anchors.centerIn: parent; width: 34; height: 34; radius: 17; color: Atelier.gold }
            Rectangle { x: 32; y: 0; width: 18; height: 38; color: Atelier.ink }
            Rectangle { x: 34; y: 3; width: 3; height: 32; color: Atelier.paper }
            MouseArea { anchors.fill: parent; onClicked: rail.host.toggleLauncherPopup(rail.monitor) }
        }
        Item {
            width: 64; height: 76
            Column {
            width: 64
            Text { anchors.horizontalCenter: parent.horizontalCenter; text: Qt.formatDateTime(rail.host.now, "HH"); color: Atelier.paper; font.family: Atelier.display; font.pixelSize: 28 }
            Text { anchors.horizontalCenter: parent.horizontalCenter; text: Qt.formatDateTime(rail.host.now, "mm"); color: Atelier.gold; font.family: Atelier.display; font.pixelSize: 28 }
            }
            MouseArea { anchors.fill: parent; onClicked: rail.host.toggleClockPopup(rail.monitor) }
        }
    }
    Flickable {
        x: 12; y: crown.y + crown.height + 24; width: 64
        height: Math.max(120, rail.height - y - foot.height - 36)
        contentHeight: navigation.height; clip: true
        Column {
            id: navigation; spacing: 8
            RailButton { icon: "view-app-grid-symbolic"; label: "DISCOVER"; active: rail.host.launcherPopupOpen; onClicked: rail.host.toggleLauncherPopup(rail.monitor) }
            RailButton { icon: "audio-x-generic-symbolic"; label: "LISTEN"; active: rail.host.mediaPopupOpen; onClicked: rail.host.toggleMediaPopup(rail.monitor) }
            RailButton { icon: "preferences-system-notifications-symbolic"; label: "ACTIVITY"; active: rail.host.notifPopupOpen; onClicked: rail.host.toggleNotifPopup(rail.monitor) }
            RailButton { icon: "edit-paste-symbolic"; label: "COLLECT"; active: rail.host.clipboardPopupOpen; onClicked: rail.host.toggleClipboardPopup(rail.monitor) }
            RailButton { icon: "network-wired-symbolic"; label: "CONNECT"; active: rail.host.networkPopupOpen || rail.host.bluetoothPopupOpen; onClicked: rail.host.toggleNetworkPopup(rail.monitor) }
            RailButton { icon: "applications-graphics-symbolic"; label: "STUDIO"; active: rail.host.themePickerPopupOpen || rail.host.stylePresetPopupOpen; onClicked: rail.host.toggleStylePresetPopup(rail.monitor) }
            Rectangle { width: 28; height: 1; x: 18; color: Atelier.rule }
            Repeater {
                model: rail.niri.tasksForOutput(String(rail.monitor.name || ""))
                delegate: Item {
                    id: task
                    required property var modelData
                    width: 64; height: 38
                    Rectangle { x: 8; y: 17; width: 4; height: 4; radius: 2; color: task.modelData.isUrgent ? "#ed8370" : Atelier.gold; visible: task.modelData.isFocused || task.modelData.isUrgent }
                    Image { anchors.centerIn: parent; width: 22; height: 22; source: Quickshell.iconPath(task.modelData.appId, true); fillMode: Image.PreserveAspectFit }
                    MouseArea { anchors.fill: parent; onClicked: rail.niri.focusWindow(task.modelData.id) }
                }
            }
        }
    }
    Column {
        id: foot
        x: 12; width: 64; anchors.bottom: parent.bottom; anchors.bottomMargin: 18; spacing: 10
        RailButton { icon: rail.host.weatherIcon; label: rail.host.weatherTemperature.replace(/C$/, "°"); onClicked: rail.host.toggleWeatherPopup(rail.monitor) }
        RailButton { icon: "utilities-system-monitor-symbolic"; label: "SYSTEM"; active: rail.host.resourcesPopupOpen; onClicked: rail.host.toggleResourcesPopup(rail.monitor) }
        Grid {
            width: 64; columns: 3; spacing: 4
            Repeater {
                model: SystemTray.items.values
                delegate: Item {
                    id: tray
                    required property var modelData
                    width: 18; height: 22
                    Image { anchors.centerIn: parent; width: 16; height: 16; source: rail.host.trayIconSource(tray.modelData.icon); fillMode: Image.PreserveAspectFit }
                    MouseArea {
                        anchors.fill: parent; acceptedButtons: Qt.LeftButton | Qt.RightButton
                        onClicked: event => {
                            if (tray.modelData.menu) rail.host.openTrayMenu(tray.modelData.menu, tray);
                            else if (event.button === Qt.RightButton) tray.modelData.secondaryActivate();
                            else tray.modelData.activate();
                        }
                    }
                }
            }
        }
        RailButton { icon: "system-shutdown-symbolic"; label: "SESSION"; accent: Atelier.danger; active: rail.host.powerPopupOpen; onClicked: rail.host.togglePowerPopup(rail.monitor) }
    }
}
