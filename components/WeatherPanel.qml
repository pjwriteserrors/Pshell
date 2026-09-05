pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.impl as QQCImpl

Item {
    id: root
    required property string temperature
    required property string description
    required property string location
    required property string iconSource
    required property var readings
    required property string sunrise
    required property string sunset
    implicitHeight: 368

    AtelierText {
        text: "OUTSIDE"; font.family: Atelier.mono; font.pixelSize: 11
        font.letterSpacing: 2; color: Atelier.muted
    }
    AtelierText { y: 24; text: root.temperature.replace(/C$/, "°"); font.pixelSize: 64; display: true }
    QQCImpl.IconImage {
        anchors.right: parent.right; y: 44; width: 40; height: 40
        source: root.iconSource; color: Atelier.accent
    }
    AtelierText { y: 110; text: root.description; font.pixelSize: 16 }
    AtelierText { y: 134; width: parent.width; elide: Text.ElideRight; text: root.location; color: Atelier.muted; font.pixelSize: 12 }
    Grid {
        y: 174; width: parent.width; columns: 2; columnSpacing: 24; rowSpacing: 12
        Repeater {
            model: root.readings
            delegate: Item {
                required property var modelData
                width: (root.width - 24) / 2; height: 44
                Rectangle { width: parent.width; height: 1; color: Atelier.rule }
                AtelierText { y: 7; text: parent.modelData.label; font.pixelSize: 10; color: Atelier.muted }
                AtelierText { y: 23; text: parent.modelData.value; font.pixelSize: 15 }
            }
        }
    }
    AtelierText {
        anchors.bottom: parent.bottom; font.family: Atelier.mono; font.pixelSize: 12
        color: Atelier.accent; text: "↑  " + root.sunrise + "     ↓  " + root.sunset
    }
}
