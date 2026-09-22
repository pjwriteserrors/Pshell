pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import "components"

// Studio-Seite "Kompositionen": ein ganzer Look, unter einem Namen gespeichert.
//
// Jede andere Seite ändert eine Sache - das Wallpaper, die Bewegung, die
// Symbole, den Style-Branch. Diese hier behält das *Set*: was alle davon
// gleichzeitig waren. Stell einen Look über die anderen Seiten zusammen, komm
// hierher, behalte ihn - und er lässt sich in einem Zug wieder anlegen, egal
// wie weit du danach abgekommen bist.
//
// Die Arbeit macht `scripts/combinations.py`. Kompositionen liegen absichtlich
// außerhalb des Style-Branches: eine Komposition nennt einen Branch, im Branch
// gespeichert wäre beim ersten Wechsel alles weg.
//
// Für neue Styles: diese Seite bleibt, und sie ruft weiter dieses Skript auf,
// damit unter einem Style gespeicherte Kompositionen auch unter dem nächsten
// noch funktionieren. Siehe STUDIO.md.
Item {
    id: root

    signal closeRequested

    required property color foreground
    required property color background
    required property color secondaryBoxColor
    required property color secondaryBoxStrongColor
    required property color secondaryInsetColor
    required property color barColor
    required property color danger

    property var combinations: []
    property var currentState: ({})
    property int selectedIndex: 0
    property bool busy: false
    property string notice: ""

    readonly property string scriptPath: Quickshell.shellDir + "/scripts/combinations.py"
    readonly property var selected: root.combinations.length > 0
        ? root.combinations[Math.max(0, Math.min(root.combinations.length - 1, root.selectedIndex))]
        : null

    // Eine Komposition ist "angelegt", wenn jeder Teil, den sie nennt, auch an ist.
    function partsOf(entry) {
        if (!entry) return [];
        const state = root.currentState || ({});
        return [
            { label: "Wallpaper", value: String(entry.themeName || entry.theme || ""), live: String(state.theme || "") === String(entry.theme || "") },
            { label: "Farben", value: [entry.backend, entry.palette, entry.style].filter(v => String(v || "") !== "").join(" · "), live: String(state.palette || "") === String(entry.palette || "") && String(state.style || "") === String(entry.style || "") },
            { label: "Bewegung", value: String(entry.animation || ""), live: String(state.animation || "") === String(entry.animation || "") },
            { label: "Symbole", value: String(entry.icons || ""), live: String(state.icons || "") === String(entry.icons || "") },
            { label: "Zeiger", value: String(entry.cursor || "") + (entry.cursorSize ? " · " + entry.cursorSize + " px" : ""), live: String(state.cursor || "") === String(entry.cursor || "") },
            { label: "Style", value: String(entry.branch || ""), live: String(state.branch || "") === String(entry.branch || "") }
        ].filter(part => part.value !== "");
    }

    readonly property bool selectedWorn: {
        const parts = root.partsOf(root.selected);
        if (parts.length === 0) return false;
        for (const part of parts) if (!part.live) return false;
        return true;
    }

    focus: true

    function reset() {
        root.reload();
        Qt.callLater(function () { root.forceActiveFocus(); });
    }

    function reload() {
        root.busy = true;
        listProcess.running = true;
    }

    function move(delta) {
        if (root.combinations.length === 0) return;
        root.selectedIndex = Math.max(0, Math.min(root.combinations.length - 1, root.selectedIndex + delta));
        keptList.positionViewAtIndex(root.selectedIndex, ListView.Contain);
    }

    function wear() {
        if (!root.selected) return;
        root.notice = "Legt " + root.selected.name + " an…";
        Quickshell.execDetached(["python3", root.scriptPath, "apply", "--name", String(root.selected.name)]);
    }

    function keep(name) {
        const trimmed = String(name || "").trim();
        if (trimmed === "") return;
        root.busy = true;
        captureProcess.command = ["python3", root.scriptPath, "capture", "--name", trimmed];
        captureProcess.running = true;
        root.notice = trimmed + " behalten";
        nameField.text = "";
    }

    function discard() {
        if (!root.selected) return;
        root.busy = true;
        deleteProcess.command = ["python3", root.scriptPath, "delete", "--name", String(root.selected.name)];
        deleteProcess.running = true;
    }

    Component.onCompleted: root.reset()
    Keys.onEscapePressed: root.closeRequested()
    Keys.onUpPressed: root.move(-1)
    Keys.onDownPressed: root.move(1)
    Keys.onReturnPressed: root.wear()
    Keys.onEnterPressed: root.wear()

    Process {
        id: listProcess
        command: ["python3", root.scriptPath, "list"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const parsed = JSON.parse(String(text || "{}"));
                    root.combinations = parsed.combinations || [];
                    root.currentState = parsed.current || ({});
                } catch (error) {
                    root.combinations = [];
                }
                root.busy = false;
                if (root.selectedIndex >= root.combinations.length)
                    root.selectedIndex = Math.max(0, root.combinations.length - 1);
            }
        }
    }

    Process { id: captureProcess; onExited: root.reload() }
    Process { id: deleteProcess; onExited: root.reload() }

    Item {
        id: panel
        anchors.fill: parent
        anchors.margins: 14

        // ------------------------------------------------ woraus eine besteht
        Rectangle {
            id: sheet
            width: parent.width * 0.42; height: parent.height; radius: 28; color: Atelier.ink; clip: true
            opacity: root.selected ? 1 : 0.35

            Behavior on opacity { NumberAnimation { duration: 160 } }

            AtelierText {
                x: 24; y: 24
                text: root.busy ? "WIRD GELESEN" : root.selectedWorn ? "ANGELEGT" : "KOMPOSITION"
                color: Atelier.paper; font.family: Atelier.mono; font.pixelSize: 9
            }

            AtelierText {
                id: sheetName
                x: 24; y: 46; width: parent.width - 48
                text: root.selected ? String(root.selected.name || "") : "Noch nichts behalten"
                color: Atelier.paper; display: true; font.pixelSize: 30
                maximumLineCount: 2; wrapMode: Text.WordWrap; elide: Text.ElideRight
            }

            // Woraus die Komposition besteht, Teil für Teil, mit dem markiert,
            // was der Desktop schon trägt.
            Column {
                x: 24; anchors.top: sheetName.bottom; anchors.topMargin: 24
                width: parent.width - 48; spacing: 0

                Repeater {
                    model: root.partsOf(root.selected)

                    delegate: Item {
                        id: partRow
                        required property var modelData

                        width: sheet.width - 48; height: 30

                        AtelierText {
                            id: partLabel
                            anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                            width: 78
                            text: String(partRow.modelData.label)
                            color: Atelier.paper; opacity: 0.55
                            font.family: Atelier.mono; font.pixelSize: 9
                        }

                        AtelierText {
                            anchors.left: partLabel.right; anchors.leftMargin: 10
                            anchors.right: partMark.left; anchors.rightMargin: 10
                            anchors.verticalCenter: parent.verticalCenter
                            text: String(partRow.modelData.value)
                            color: Atelier.paper; opacity: partRow.modelData.live ? 1 : 0.6
                            font.pixelSize: 11; elide: Text.ElideRight
                        }

                        Rectangle {
                            id: partMark
                            anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                            width: 7; height: 7; radius: 3.5
                            color: partRow.modelData.live ? Atelier.accent : Qt.alpha(Atelier.paper, 0.22)
                        }

                        Rectangle {
                            anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
                            height: 1; color: Qt.alpha(Atelier.paper, 0.12)
                        }
                    }
                }
            }

            AtelierText {
                x: 24; anchors.bottom: sheetButtons.top; anchors.bottomMargin: 12
                width: parent.width - 48
                text: root.notice
                color: Atelier.paper; opacity: 0.6; font.pixelSize: 10; elide: Text.ElideRight
            }

            Row {
                id: sheetButtons
                x: 24; anchors.bottom: parent.bottom; anchors.bottomMargin: 24; spacing: 8

                Rectangle {
                    width: 120; height: 40; radius: 20
                    color: root.selectedWorn ? Qt.alpha(Atelier.paper, 0.12) : Atelier.accent
                    opacity: root.selected ? (wearMouse.containsMouse ? 0.9 : 1) : 0.4

                    AtelierText {
                        anchors.centerIn: parent
                        text: root.selectedWorn ? "Angelegt" : "Anlegen"
                        font.pixelSize: 12
                        color: root.selectedWorn ? Atelier.paper : Atelier.onAccent
                    }

                    MouseArea {
                        id: wearMouse
                        anchors.fill: parent; hoverEnabled: true; enabled: !!root.selected
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.wear()
                    }
                }

                Rectangle {
                    width: 104; height: 40; radius: 20
                    color: Qt.alpha(Atelier.paper, replaceMouse.containsMouse ? 0.2 : 0.12)
                    opacity: root.selected ? 1 : 0.4

                    Behavior on color { ColorAnimation { duration: 120 } }

                    AtelierText { anchors.centerIn: parent; text: "Ersetzen"; font.pixelSize: 12; color: Atelier.paper }

                    MouseArea {
                        id: replaceMouse
                        anchors.fill: parent; hoverEnabled: true; enabled: !!root.selected
                        cursorShape: Qt.PointingHandCursor
                        onClicked: { if (root.selected) root.keep(String(root.selected.name)); }
                    }
                }

                Rectangle {
                    width: 104; height: 40; radius: 20
                    color: discardMouse.containsMouse ? Qt.alpha(Atelier.danger, 0.3) : Qt.alpha(Atelier.paper, 0.12)
                    opacity: root.selected ? 1 : 0.4

                    Behavior on color { ColorAnimation { duration: 120 } }

                    AtelierText {
                        anchors.centerIn: parent; text: "Verwerfen"; font.pixelSize: 12
                        color: discardMouse.containsMouse ? Atelier.danger : Atelier.paper
                    }

                    MouseArea {
                        id: discardMouse
                        anchors.fill: parent; hoverEnabled: true; enabled: !!root.selected
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.discard()
                    }
                }
            }
        }

        // --------------------------------------------------- was behalten ist
        Item {
            id: kept
            x: sheet.width + 24; width: parent.width - x; height: parent.height

            AtelierText {
                id: keptHeading
                text: "Behalten"; display: true; font.pixelSize: 26
            }

            AtelierText {
                id: keptCount
                y: 34
                text: root.busy ? "wird gelesen…" : root.combinations.length + " Stück · eine Komposition legt nur die Teile an, die sie nennt"
                color: Atelier.muted; font.pixelSize: 11; width: parent.width; elide: Text.ElideRight
            }

            ListView {
                id: keptList
                y: 62; width: parent.width; height: parent.height - 62 - 56
                clip: true; model: root.combinations; currentIndex: root.selectedIndex
                spacing: 8; boundsBehavior: Flickable.StopAtBounds

                delegate: Rectangle {
                    id: keptRow
                    required property var modelData
                    required property int index

                    readonly property bool chosen: root.selectedIndex === keptRow.index

                    width: keptList.width - 12; height: 62; radius: 20
                    color: keptRow.chosen ? Atelier.selectedSurface : keptHover.containsMouse ? Atelier.surface : Qt.alpha(Atelier.surface, 0.5)

                    Behavior on color { ColorAnimation { duration: 120 } }

                    AtelierText {
                        x: 18; y: 12; width: parent.width - 36
                        text: String(keptRow.modelData.name || "")
                        font.pixelSize: 15; elide: Text.ElideRight
                        color: keptRow.chosen ? Atelier.text : Atelier.muted
                    }

                    AtelierText {
                        x: 18; y: 34; width: parent.width - 36
                        text: [
                            String(keptRow.modelData.themeName || ""),
                            String(keptRow.modelData.animation || "").split(":").pop(),
                            String(keptRow.modelData.branch || "").split("/").pop()
                        ].filter(v => v !== "").join(" · ")
                        font.family: Atelier.mono; font.pixelSize: 9; color: Atelier.muted; elide: Text.ElideRight
                    }

                    MouseArea {
                        id: keptHover
                        anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: { root.forceActiveFocus(); root.selectedIndex = keptRow.index; }
                        onDoubleClicked: root.wear()
                    }
                }

                AtelierText {
                    anchors.centerIn: parent
                    visible: keptList.count === 0 && !root.busy
                    width: parent.width - 40
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    text: "Stell den Desktop über die anderen Seiten ein,\nbenenne unten, was gerade an ist, und behalte es."
                    color: Atelier.muted; font.pixelSize: 13
                }

                ScrollBar.vertical: ScrollBar {}
            }

            // Behalten, was gerade an ist: die einzige Stelle, an der diese
            // Seite etwas schreibt.
            Row {
                anchors.bottom: parent.bottom; width: parent.width; spacing: 10

                TextField {
                    id: nameField
                    width: parent.width - 140; height: 44
                    placeholderText: "Name für das, was gerade an ist"
                    color: Atelier.text
                    placeholderTextColor: Atelier.muted
                    selectedTextColor: Atelier.onAccent
                    selectionColor: Atelier.accent
                    font.pixelSize: 12
                    background: Rectangle {
                        radius: 22
                        color: Atelier.surface
                        border.width: nameField.activeFocus ? 1 : 0
                        border.color: Atelier.accent
                    }
                    onAccepted: root.keep(text)
                }

                Rectangle {
                    width: 130; height: 44; radius: 22
                    color: nameField.text.trim() === "" ? Qt.alpha(Atelier.surface, 0.48) : Atelier.selectedSurface
                    opacity: keepMouse.containsMouse ? 0.9 : 1

                    AtelierText {
                        anchors.centerIn: parent
                        text: "Behalten"; font.pixelSize: 12
                        color: nameField.text.trim() === "" ? Atelier.muted : Atelier.text
                    }

                    MouseArea {
                        id: keepMouse
                        anchors.fill: parent; hoverEnabled: true
                        enabled: nameField.text.trim() !== ""
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.keep(nameField.text)
                    }
                }
            }
        }
    }
}
