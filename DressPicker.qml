pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import "components"

// Studio-Seite "Symbole & Zeiger": das Icon-Set, das der Desktop trägt, und
// der Mauszeiger.
//
// Beide Listen zeigen die echte Sache - Icons aus den Dateien des Themes und
// ein Zeiger, der aus dem left_ptr des Cursor-Themes dekodiert wurde -, weil
// eine Liste von Namen nichts darüber sagt, was man da auswählt.
//
// `scripts/appearance_themes.py` sucht und wendet an. Anwenden heißt
// GSettings, GTK 3 und 4, Qts eigene Config, der Xcursor-Default und niris
// cursor-Block auf einmal: ein Zeiger, der nur an einer Stelle gesetzt wird,
// lässt die halbe Sitzung auf dem alten - was sich anfühlt wie "geht nicht".
//
// Für neue Styles: diese Seite bleibt, und sie ruft weiter dieses Skript auf.
// Zeichne die Listen so, wie dein Style Listen zeichnet. Siehe STUDIO.md.
Item {
    id: root

    signal closeRequested

    required property color foreground
    required property color background
    required property color secondaryBoxColor
    required property color secondaryBoxStrongColor
    required property color secondaryInsetColor
    required property color barColor

    property var iconThemes: []
    property var cursorThemes: []
    property int iconIndex: 0
    property int cursorIndex: 0
    property string column: "icons"
    property string liveIcon: ""
    property string liveCursor: ""
    property int liveCursorSize: 24
    property bool loading: false

    readonly property string scriptPath: Quickshell.shellDir + "/scripts/appearance_themes.py"

    readonly property var currentIcon: root.iconThemes.length > 0
        ? root.iconThemes[Math.max(0, Math.min(root.iconThemes.length - 1, root.iconIndex))]
        : null
    readonly property var currentCursor: root.cursorThemes.length > 0
        ? root.cursorThemes[Math.max(0, Math.min(root.cursorThemes.length - 1, root.cursorIndex))]
        : null

    readonly property bool dressed: root.currentIcon
        && root.currentCursor
        && String(root.currentIcon.id) === root.liveIcon
        && String(root.currentCursor.id) === root.liveCursor

    focus: true

    function reset() {
        root.loading = true;
        listProcess.running = true;
        currentProcess.running = true;
        Qt.callLater(function () { root.forceActiveFocus(); });
    }

    function selectByIds(iconId, cursorId) {
        for (let i = 0; i < root.iconThemes.length; i += 1)
            if (String(root.iconThemes[i].id) === iconId) { root.iconIndex = i; break; }
        for (let i = 0; i < root.cursorThemes.length; i += 1)
            if (String(root.cursorThemes[i].id) === cursorId) { root.cursorIndex = i; break; }
    }

    function move(delta) {
        if (root.column === "icons") {
            if (root.iconThemes.length === 0) return;
            root.iconIndex = Math.max(0, Math.min(root.iconThemes.length - 1, root.iconIndex + delta));
            iconList.positionViewAtIndex(root.iconIndex, ListView.Contain);
        } else {
            if (root.cursorThemes.length === 0) return;
            root.cursorIndex = Math.max(0, Math.min(root.cursorThemes.length - 1, root.cursorIndex + delta));
            cursorList.positionViewAtIndex(root.cursorIndex, ListView.Contain);
        }
    }

    function apply() {
        if (!root.currentIcon && !root.currentCursor) return;
        const command = ["python3", root.scriptPath, "apply"];
        if (root.currentIcon) command.push("--icon", String(root.currentIcon.id));
        if (root.currentCursor) {
            command.push("--cursor", String(root.currentCursor.id));
            command.push("--cursor-size", String(root.liveCursorSize));
        }
        Quickshell.execDetached(command);
        root.liveIcon = root.currentIcon ? String(root.currentIcon.id) : root.liveIcon;
        root.liveCursor = root.currentCursor ? String(root.currentCursor.id) : root.liveCursor;
    }

    Component.onCompleted: root.reset()
    Keys.onEscapePressed: root.closeRequested()
    Keys.onReturnPressed: root.apply()
    Keys.onEnterPressed: root.apply()
    Keys.onUpPressed: root.move(-1)
    Keys.onDownPressed: root.move(1)
    Keys.onLeftPressed: root.column = "icons"
    Keys.onRightPressed: root.column = "cursors"
    Keys.onTabPressed: root.column = root.column === "icons" ? "cursors" : "icons"

    Process {
        id: listProcess
        command: ["python3", root.scriptPath, "list"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const parsed = JSON.parse(String(text || "{}"));
                    root.iconThemes = parsed.icons || [];
                    root.cursorThemes = parsed.cursors || [];
                    root.selectByIds(root.liveIcon, root.liveCursor);
                } catch (error) {
                    root.iconThemes = [];
                    root.cursorThemes = [];
                }
                root.loading = false;
            }
        }
    }

    Process {
        id: currentProcess
        command: ["python3", root.scriptPath, "current"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const parsed = JSON.parse(String(text || "{}"));
                    root.liveIcon = String(parsed.icon || "");
                    root.liveCursor = String(parsed.cursor || "");
                    root.liveCursorSize = Number(parsed.cursorSize || 24);
                    root.selectByIds(root.liveIcon, root.liveCursor);
                } catch (error) {
                    // was da war, bleibt
                }
            }
        }
    }

    Item {
        id: panel
        anchors.fill: parent
        anchors.margins: 14

        // ------------------------------------------------------- was getragen wird
        Rectangle {
            id: worn
            width: parent.width * 0.42; height: parent.height; radius: 28; color: Atelier.ink; clip: true

            AtelierText {
                x: 24; y: 24
                text: root.loading ? "WIRD GELESEN" : "GETRAGEN"
                color: Atelier.paper; font.family: Atelier.mono; font.pixelSize: 9
            }

            AtelierText {
                id: wornName
                x: 24; y: 46; width: parent.width - 48
                text: root.currentIcon ? String(root.currentIcon.name || root.currentIcon.id) : ""
                color: Atelier.paper; display: true; font.pixelSize: 28
                maximumLineCount: 1; elide: Text.ElideRight
            }

            AtelierText {
                id: wornComment
                x: 24; anchors.top: wornName.bottom; anchors.topMargin: 4; width: parent.width - 48
                text: root.currentIcon ? String(root.currentIcon.comment || "") : ""
                color: Atelier.paper; opacity: 0.6; font.pixelSize: 11
                wrapMode: Text.WordWrap; maximumLineCount: 2; elide: Text.ElideRight
            }

            // Sechs Marken in der Größe, in der man sie wirklich sieht.
            Grid {
                id: sampleGrid
                x: 24; anchors.top: wornComment.bottom; anchors.topMargin: 26
                columns: 3; columnSpacing: 24; rowSpacing: 20

                Repeater {
                    model: root.currentIcon ? (root.currentIcon.samples || []) : []

                    delegate: Image {
                        required property string modelData
                        width: 54; height: 54
                        source: "file://" + modelData
                        sourceSize: Qt.size(108, 108)
                        fillMode: Image.PreserveAspectFit
                        smooth: true; mipmap: true; asynchronous: true
                    }
                }
            }

            Rectangle {
                id: wornRule
                x: 24; anchors.top: sampleGrid.bottom; anchors.topMargin: 26
                width: parent.width - 48; height: 1; color: Qt.alpha(Atelier.paper, 0.2)
            }

            // Der Zeiger, in der Größe, in der er gezeichnet wird.
            Item {
                id: pointerBlock
                x: 24; anchors.top: wornRule.bottom; anchors.topMargin: 20
                width: parent.width - 48; height: 64

                Image {
                    id: pointerLarge
                    anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                    width: Math.max(32, root.liveCursorSize); height: width
                    source: root.currentCursor && String(root.currentCursor.preview || "") !== ""
                        ? "file://" + root.currentCursor.preview
                        : ""
                    sourceSize: Qt.size(128, 128)
                    fillMode: Image.PreserveAspectFit
                    smooth: true; asynchronous: true
                }

                Column {
                    anchors.left: pointerLarge.right; anchors.leftMargin: 18
                    anchors.verticalCenter: parent.verticalCenter; spacing: 1

                    AtelierText {
                        text: root.currentCursor ? String(root.currentCursor.name || root.currentCursor.id) : ""
                        color: Atelier.paper; font.pixelSize: 14
                    }

                    AtelierText {
                        text: root.liveCursorSize + " px"
                        color: Atelier.paper; opacity: 0.6; font.family: Atelier.mono; font.pixelSize: 9
                    }
                }
            }

            // Wie groß der Zeiger gezeichnet wird - die eine Zahl dieser Seite.
            Row {
                x: 24; anchors.bottom: parent.bottom; anchors.bottomMargin: 24; spacing: 8
                height: 30

                Repeater {
                    model: [16, 24, 32, 48, 64]

                    delegate: Rectangle {
                        required property int modelData
                        width: 46; height: 30; radius: 15
                        color: root.liveCursorSize === modelData ? Atelier.accent : Qt.alpha(Atelier.paper, 0.12)

                        Behavior on color { ColorAnimation { duration: 120 } }

                        AtelierText {
                            anchors.centerIn: parent
                            text: String(modelData)
                            color: root.liveCursorSize === modelData ? Atelier.onAccent : Atelier.paper
                            font.family: Atelier.mono; font.pixelSize: 10
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.liveCursorSize = modelData
                        }
                    }
                }
            }
        }

        // ------------------------------------------------------------ die Listen
        Item {
            id: lists
            x: worn.width + 24; width: parent.width - x; height: parent.height

            AtelierText {
                id: marksHeading
                text: "Zeichensätze"; display: true; font.pixelSize: 26
                color: root.column === "icons" ? Atelier.text : Atelier.muted
            }

            ListView {
                id: iconList
                y: 48; width: parent.width * 0.58; height: parent.height - 48
                clip: true; model: root.iconThemes; currentIndex: root.iconIndex
                spacing: 6; boundsBehavior: Flickable.StopAtBounds

                delegate: Rectangle {
                    id: iconRow
                    required property var modelData
                    required property int index

                    readonly property bool chosen: root.iconIndex === iconRow.index
                    readonly property bool live: String(iconRow.modelData.id) === root.liveIcon

                    width: iconList.width - 12; height: 46; radius: 23
                    color: iconRow.chosen ? Atelier.selectedSurface : iconHover.containsMouse ? Atelier.surface : "transparent"

                    Behavior on color { ColorAnimation { duration: 120 } }

                    Row {
                        x: 14; anchors.verticalCenter: parent.verticalCenter; spacing: 4

                        Repeater {
                            model: (iconRow.modelData.samples || []).slice(0, 3)

                            delegate: Image {
                                required property string modelData
                                width: 20; height: 20
                                source: "file://" + modelData
                                sourceSize: Qt.size(40, 40)
                                fillMode: Image.PreserveAspectFit
                                smooth: true; mipmap: true; asynchronous: true
                            }
                        }
                    }

                    AtelierText {
                        x: 90; anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - 116
                        text: String(iconRow.modelData.name || iconRow.modelData.id)
                        font.pixelSize: 12; elide: Text.ElideRight
                        color: iconRow.chosen ? Atelier.text : Atelier.muted
                    }

                    Rectangle {
                        visible: iconRow.live
                        anchors.right: parent.right; anchors.rightMargin: 16
                        anchors.verticalCenter: parent.verticalCenter
                        width: 7; height: 7; radius: 3.5; color: Atelier.accent
                    }

                    MouseArea {
                        id: iconHover
                        anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: { root.forceActiveFocus(); root.column = "icons"; root.iconIndex = iconRow.index; }
                        onDoubleClicked: root.apply()
                    }
                }

                ScrollBar.vertical: ScrollBar {}
            }

            AtelierText {
                x: iconList.width + 20
                text: "Zeiger"; display: true; font.pixelSize: 26
                color: root.column === "cursors" ? Atelier.text : Atelier.muted
            }

            ListView {
                id: cursorList
                x: iconList.width + 20; y: 48
                width: parent.width - x - 4; height: parent.height - 48 - 56
                clip: true; model: root.cursorThemes; currentIndex: root.cursorIndex
                spacing: 6; boundsBehavior: Flickable.StopAtBounds

                delegate: Rectangle {
                    id: cursorRow
                    required property var modelData
                    required property int index

                    readonly property bool chosen: root.cursorIndex === cursorRow.index
                    readonly property bool live: String(cursorRow.modelData.id) === root.liveCursor

                    width: cursorList.width - 12; height: 46; radius: 23
                    color: cursorRow.chosen ? Atelier.selectedSurface : cursorHover.containsMouse ? Atelier.surface : "transparent"

                    Behavior on color { ColorAnimation { duration: 120 } }

                    Image {
                        id: pointerMark
                        x: 16; anchors.verticalCenter: parent.verticalCenter
                        width: 20; height: 20
                        source: String(cursorRow.modelData.preview || "") === "" ? "" : "file://" + cursorRow.modelData.preview
                        sourceSize: Qt.size(48, 48)
                        fillMode: Image.PreserveAspectFit
                        smooth: true; asynchronous: true
                    }

                    AtelierText {
                        x: 48; anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - 76
                        text: String(cursorRow.modelData.name || cursorRow.modelData.id)
                        font.pixelSize: 12; elide: Text.ElideRight
                        color: cursorRow.chosen ? Atelier.text : Atelier.muted
                    }

                    Rectangle {
                        visible: cursorRow.live
                        anchors.right: parent.right; anchors.rightMargin: 16
                        anchors.verticalCenter: parent.verticalCenter
                        width: 7; height: 7; radius: 3.5; color: Atelier.accent
                    }

                    MouseArea {
                        id: cursorHover
                        anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: { root.forceActiveFocus(); root.column = "cursors"; root.cursorIndex = cursorRow.index; }
                        onDoubleClicked: root.apply()
                    }
                }

                ScrollBar.vertical: ScrollBar {}
            }

            Rectangle {
                id: wearButton
                x: iconList.width + 20; anchors.bottom: parent.bottom
                width: parent.width - x - 4; height: 44; radius: 22
                color: root.dressed ? Qt.alpha(Atelier.surface, 0.48) : Atelier.accent
                opacity: wearMouse.containsMouse ? 0.9 : 1

                AtelierText {
                    anchors.centerIn: parent
                    text: root.loading ? "Sucht..." : root.dressed ? "Wird schon getragen" : "Anlegen"
                    font.pixelSize: 12
                    color: root.dressed ? Atelier.muted : Atelier.onAccent
                }

                MouseArea {
                    id: wearMouse
                    anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                    onClicked: { root.forceActiveFocus(); root.apply(); }
                }
            }
        }
    }
}
