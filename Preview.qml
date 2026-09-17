import QtQuick
import QtQuick.Controls
import Quickshell
import "components"

// A normal application window: no layer shell, lock, wallpaper or bar takeover.
ApplicationWindow {
    id: window
    visible: true
    width: 1180
    height: 800
    title: "Atelier · Design review"
    color: Atelier.ink
    property int page: Number(Quickshell.env("ATELIER_PAGE") || "0")
    property string capturePath: Quickshell.env("ATELIER_CAPTURE")

    Rectangle {
        id: canvas
        anchors.fill: parent
        color: Atelier.ink

        Row {
            x: 32; y: 24; spacing: 24
            Repeater {
                model: ["01  Applications", "02  Interface", "03  Listening"]
                delegate: AtelierText {
                    required property string modelData
                    required property int index
                    text: modelData
                    font.pixelSize: 13
                    color: window.page === index ? Atelier.accent : Atelier.muted
                    MouseArea { anchors.fill: parent; onClicked: window.page = parent.index }
                }
            }
        }
        Rectangle { x: 32; y: 60; width: parent.width - 64; height: 1; color: Atelier.rule }
        AtelierText {
            x: 40; y: 85
            text: window.page === 0 ? "A place to begin." : window.page === 1 ? "Form & rhythm." : "On the record."
            display: true
    font.pixelSize: 44
        }
        AtelierText {
            x: 42; y: 150
            text: "ATELIER     /     DESKTOP STUDIES     /     2026"
            font.pixelSize: 11
            font.letterSpacing: 2
            color: Atelier.muted
        }
        Loader {
            id: review
            x: 32; y: 198
            width: parent.width - 64; height: parent.height - y - 48
            sourceComponent: window.page === 0 ? applications : media
        }
        AtelierText {
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 16
            x: 40
            text: "Separate preview · Existing desktop remains active"
            color: Atelier.muted
            font.pixelSize: 11
        }
    }

    Component {
        id: applications
        AppLauncherPopup {
            previewMode: true
            foreground: Atelier.paper
            background: Atelier.ink
            secondaryBoxColor: Qt.alpha(Atelier.paper, 0.025)
            secondaryBoxStrongColor: Qt.alpha(Atelier.accent, 0.13)
            secondaryInsetColor: Atelier.ink
            barColor: Atelier.accent
        }
    }
    Component {
        id: media
        Item {
            MediaPopupContent {
                width: Math.min(520, parent.width)
                anchors.horizontalCenter: parent.horizontalCenter
                foreground: Atelier.paper
                secondaryBoxColor: Qt.alpha(Atelier.paper, 0.025)
                secondaryInsetColor: Atelier.ink
                accent: Atelier.accent
                players: []
                activePlayer: null
            }
        }
    }
    Timer {
        interval: 2400
        running: window.capturePath !== ""
        onTriggered: canvas.grabToImage(result => {
            result.saveToFile(window.capturePath);
            Qt.quit();
        })
    }
}
