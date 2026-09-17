pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "components"

// The one place where the desktop's looks are changed: a wallpaper and its
// palette, window motion, the style branch, and the compositions you saved.
//
// Everything is reachable with the mouse and with the keyboard:
//   Escape                     close
//   Ctrl+Tab / Ctrl+Shift+Tab  next / previous page
//   Ctrl+1 .. Ctrl+4           jump to a page
//   arrows / Enter             handled by the page itself
FocusScope {
    id: root
    readonly property var pages: [
        {id: "wallpaper", label: "Wallpaper & Farben", hint: "^1"},
        {id: "motion", label: "Bewegung", hint: "^2"},
        {id: "styles", label: "Styles", hint: "^3"},
        {id: "collection", label: "Sammlung", hint: "^4"}
    ]
    readonly property int pageIndex: {
        for (let i = 0; i < root.pages.length; i += 1)
            if (root.pages[i].id === root.page) return i;
        return 0;
    }
    function showPage(id) { if (id && id !== root.page) root.page = id; }
    function cyclePage(delta) {
        root.showPage(root.pages[(root.pageIndex + delta + root.pages.length) % root.pages.length].id);
    }
    // The page owns the arrow keys, so it has to hold the focus.
    function focusPage() {
        const item = root.page === "motion" ? motion : root.page === "wallpaper" ? landscape : null;
        if (item) item.forceActiveFocus();
        else root.forceActiveFocus();
    }
    focus: true
    onPageChanged: Qt.callLater(root.focusPage)
    // Ctrl-modified on purpose: the pages use plain arrows, Enter and typing.
    Keys.onPressed: event => {
        if (!(event.modifiers & Qt.ControlModifier)) return;
        if (event.key === Qt.Key_Tab) {
            root.cyclePage(event.modifiers & Qt.ShiftModifier ? -1 : 1);
            event.accepted = true;
        } else if (event.key === Qt.Key_Backtab) {
            root.cyclePage(-1);
            event.accepted = true;
        } else if (event.key >= Qt.Key_1 && event.key <= Qt.Key_4) {
            root.showPage(root.pages[event.key - Qt.Key_1].id);
            event.accepted = true;
        }
    }
    property string page: "wallpaper"
    property var collection: []
    property string message: ""
    signal closeRequested
    property bool applying: applyProcess.running
    function apply(motionOnly) {
        if (applying) return;
        if (!motionOnly && !landscape.currentTheme) { message = "Choose a wallpaper first."; return; }
        const command = motionOnly
            ? ["bash", motion.applyScriptPath, "--animation", motion.selectedAnimationId]
            : ["bash", landscape.applyScriptPath, landscape.currentTheme.path, "--backend", landscape.selectedBackend, "--palette", landscape.selectedColorSpace, "--style", landscape.selectedPalette];
        if (!motionOnly && motion.selectedAnimationId) command.push("--animation", motion.selectedAnimationId);
        applyProcess.command = command;
        message = "Applying…";
        applyProcess.running = true;
    }
    Process {
        id: applyProcess
        property string errorOutput: ""
        onStarted: errorOutput = ""
        stderr: StdioCollector { onStreamFinished: applyProcess.errorOutput = text.trim() }
        onExited: code => root.message = code === 0 ? "Applied. Your desktop is up to date." : "Could not apply: " + applyProcess.errorOutput.slice(-350)
    }
    function snapshot() {
        return {name: nameField.text.trim(), themePath: landscape.currentTheme ? landscape.currentTheme.path : "",
            themeName: landscape.currentTheme ? landscape.currentTheme.name : "", preview: landscape.currentTheme ? landscape.currentTheme.previewPath : "",
            backend: landscape.selectedBackend, palette: landscape.selectedColorSpace, style: landscape.selectedPalette,
            animation: motion.selectedAnimationId};
    }
    function restore(entry) {
        landscape.searchText = "";
        const index = landscape.filteredThemes.findIndex(theme => theme.path === entry.themePath);
        if(index < 0) { message = "Wallpaper unavailable. Your saved composition is kept."; return; }
        landscape.currentThemeIndex = index;
        landscape.selectedBackend = entry.backend;
        landscape.selectedColorSpace = entry.palette;
        landscape.selectedPalette = entry.style;
        if (motion.animationOptions.some(option => option.id === entry.animation)) motion.selectedAnimationId = entry.animation;
        else if(entry.animation) { message = "Saved animation unavailable. Choose another before applying."; page = "motion"; return; }
        motion.syncSelectedIndex();
        nameField.text = entry.name;
        message = "Loaded for editing. Apply when you are ready.";
        page = "wallpaper";
    }
    function save() {
        if(library.running) return;
        library.command = ["python3", Quickshell.shellDir + "/scripts/studio_library.py", "save", JSON.stringify(snapshot())];
        library.running = true;
    }
    Component.onCompleted: {
        library.command = ["python3", Quickshell.shellDir + "/scripts/studio_library.py", "list"];
        library.running = true;
        Qt.callLater(root.focusPage);
    }
    Process {
        id: library
        stdout: StdioCollector { onStreamFinished: { try { root.collection = JSON.parse(text); root.message = "Collection ready · " + root.collection.length + " saved"; } catch(error) { root.message = String(error); } } }
        stderr: StdioCollector { onStreamFinished: if(text.trim()) root.message = text.trim().split("\n").pop() }
    }
    Row {
        id: tabs
        width: parent.width; spacing: 8
        Repeater {
            model: root.pages
            delegate: Rectangle {
                id: tab
                required property var modelData
                readonly property bool current: root.page === tab.modelData.id
                width: Math.min(190, (root.width-24)/4); height: 42; radius: 21
                color: tab.current ? Atelier.selectedSurface : tabHover.containsMouse ? Atelier.surface : "transparent"
                Behavior on color { ColorAnimation { duration: 120 } }
                Row {
                    anchors.centerIn: parent; spacing: 6
                    AtelierText { anchors.verticalCenter: parent.verticalCenter; text: tab.modelData.label; font.pixelSize: 12; color: tab.current ? Atelier.text : Atelier.muted }
                    AtelierText { anchors.verticalCenter: parent.verticalCenter; text: tab.modelData.hint; font.family: Atelier.mono; font.pixelSize: 9; color: Atelier.muted; opacity: tab.current ? 0.8 : 0.45 }
                }
                MouseArea { id: tabHover; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.showPage(tab.modelData.id) }
            }
        }
    }
    Item {
        x: 0; y: 56; width: parent.width; height: parent.height - 144
        ThemePickerPopup {
            id: landscape
            anchors.fill: parent; visible: root.page === "wallpaper"; embedded: true
            foreground: Atelier.text; background: Atelier.canvas; secondaryBoxColor: Atelier.surface
            secondaryBoxStrongColor: Atelier.selectedSurface; secondaryInsetColor: Atelier.surface; barColor: Atelier.accent; danger: Atelier.danger
            onCloseRequested: root.closeRequested()
            onStudioApplyRequested: root.apply(false)
        }
        AnimationPickerPopup {
            id: motion
            anchors.fill: parent; visible: root.page === "motion"; embedded: true
            foreground: Atelier.text; background: Atelier.canvas; secondaryBoxColor: Atelier.surface
            secondaryBoxStrongColor: Atelier.selectedSurface; secondaryInsetColor: Atelier.surface; barColor: Atelier.accent
            onCloseRequested: root.closeRequested()
            onStudioApplyRequested: root.apply(true)
        }
        BranchStylePicker {
            anchors.fill: parent; visible: root.page === "styles"
            foreground: Atelier.text; background: Atelier.canvas; secondaryBoxColor: Atelier.surface
            secondaryBoxStrongColor: Atelier.selectedSurface; secondaryInsetColor: Atelier.surface; barColor: Atelier.accent; danger: Atelier.danger
            onCloseRequested: root.closeRequested()
        }
        GridView {
            id: saved
            anchors.fill: parent; visible: root.page === "collection"; clip: true
            cellWidth: width / Math.max(1, Math.floor(width/290)); cellHeight: 228; model: root.collection
            delegate: Rectangle {
                id: recipe
                required property var modelData
                width: saved.cellWidth-14; height: 214; radius: 18; color: Atelier.surface
                Image { x: 8; y: 8; width: parent.width-16; height: 120; source: recipe.modelData.preview; fillMode: Image.PreserveAspectCrop; clip: true }
                AtelierText { x: 16; y: 139; width: parent.width-32; text: recipe.modelData.name; display: true; font.pixelSize: 24; elide: Text.ElideRight }
                AtelierText { x: 16; y: 176; width: parent.width-32; text: recipe.modelData.palette + " / " + recipe.modelData.style + "  ·  Laden ↗"; font.pixelSize: 11; elide: Text.ElideRight; color: Atelier.muted }
                MouseArea { anchors.fill: parent; onClicked: root.restore(recipe.modelData) }
            }
            AtelierText { anchors.centerIn: parent; visible: saved.count === 0; text: "Deine erste Komposition beginnt mit einem Wallpaper.\nWähle Farben und Bewegung, gib ihr unten einen Namen."; horizontalAlignment: Text.AlignHCenter; color: Atelier.muted; font.pixelSize: 14 }
            ScrollBar.vertical: ScrollBar {}
        }
    }
    Column {
        anchors.bottom: parent.bottom; width: parent.width; spacing: 10
        Rectangle { width: parent.width; height: 1; color: Atelier.rule }
        AtelierText { width: parent.width; text: root.message || "Auswählen → abstimmen → anwenden oder als Komposition speichern."; color: Atelier.muted; font.pixelSize: 11; elide: Text.ElideRight }
        Row {
            width: parent.width; spacing: 10
            TextField {
                id: nameField
                width: Math.max(160,parent.width-440); height: 42
                placeholderText: "Name deiner Komposition"
                color: Atelier.text
                placeholderTextColor: Atelier.muted
                selectedTextColor: Atelier.onAccent
                selectionColor: Atelier.accent
                background: Rectangle {
                    radius: 21
                    color: Atelier.surface
                    border.width: nameField.activeFocus ? 1 : 0
                    border.color: Atelier.accent
                }
                onAccepted: root.save()
            }
            Rectangle {
                id: saveButton
                property bool ready: !library.running && nameField.text.trim() !== "" && !!landscape.currentTheme
                width: 120; height: 42; radius: 21
                color: ready ? Atelier.selectedSurface : Qt.alpha(Atelier.surface, 0.48)
                border.width: ready ? 1 : 0
                border.color: Atelier.rule
                opacity: saveMouse.containsMouse ? 0.88 : 1
                AtelierText {
                    anchors.centerIn: parent
                    text: library.running ? "Speichert..." : "Speichern"
                    font.pixelSize: 12
                    color: saveButton.ready ? Atelier.text : Atelier.muted
                }
                MouseArea {
                    id: saveMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: saveButton.ready ? Qt.PointingHandCursor : Qt.ArrowCursor
                    enabled: saveButton.ready
                    onClicked: root.save()
                }
            }
            Rectangle {
                id: applyButton
                property bool ready: !root.applying && root.page !== "styles" && root.page !== "collection" && (root.page === "motion" ? motion.selectedAnimationId !== "" : !!landscape.currentTheme)
                width: 290; height: 42; radius: 21
                color: ready ? Atelier.accent : Qt.alpha(Atelier.surface, 0.48)
                opacity: applyMouse.containsMouse ? 0.90 : 1
                AtelierText {
                    anchors.centerIn: parent
                    text: root.applying ? "Wird angewendet..." : root.page === "motion" ? "Bewegung anwenden" : "Komposition anwenden"
                    font.pixelSize: 12
                    color: applyButton.ready ? Atelier.onAccent : Atelier.muted
                }
                MouseArea {
                    id: applyMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: applyButton.ready ? Qt.PointingHandCursor : Qt.ArrowCursor
                    enabled: applyButton.ready
                    onClicked: root.apply(root.page === "motion")
                }
            }
        }
    }
}
