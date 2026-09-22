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
//   Ctrl+1 .. Ctrl+5           jump to a page
//   arrows / Enter             handled by the page itself
FocusScope {
    id: root

    // Studio nimmt in jedem Style dieselben sieben Farben und reicht sie an
    // seine Seiten weiter, damit eine Seite aus einem Branch auch im nächsten
    // passt. Siehe STUDIO.md.
    required property color foreground
    required property color background
    required property color secondaryBoxColor
    required property color secondaryBoxStrongColor
    required property color secondaryInsetColor
    required property color barColor
    required property color danger

    // Die Seitenliste ist ein Vertrag, keine Style-Entscheidung: jeder
    // Style-Branch trägt alle fünf, weil jede Seite der einzige Weg zu dem ist,
    // was sie steuert. Validate.qml lässt den Build scheitern, wenn eine fehlt.
    // Siehe STUDIO.md.
    readonly property var pages: [
        {id: "wallpaper", label: "Wallpaper & Farben", hint: "^1"},
        {id: "motion", label: "Bewegung", hint: "^2"},
        {id: "dress", label: "Symbole & Zeiger", hint: "^3"},
        {id: "styles", label: "Styles", hint: "^4"},
        {id: "combinations", label: "Kompositionen", hint: "^5"}
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
        const item = root.page === "motion" ? motion
            : root.page === "wallpaper" ? landscape
            : root.page === "dress" ? dress
            : root.page === "combinations" ? combinations
            : null;
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
        } else if (event.key >= Qt.Key_1 && event.key <= Qt.Key_5) {
            root.showPage(root.pages[event.key - Qt.Key_1].id);
            event.accepted = true;
        }
    }
    property string page: "wallpaper"
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
    Component.onCompleted: Qt.callLater(root.focusPage)
    Row {
        id: tabs
        width: parent.width; spacing: 8
        Repeater {
            model: root.pages
            delegate: Rectangle {
                id: tab
                required property var modelData
                readonly property bool current: root.page === tab.modelData.id
                width: Math.min(190, (root.width-24)/5); height: 42; radius: 21
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
            foreground: root.foreground; background: root.background; secondaryBoxColor: root.secondaryBoxColor
            secondaryBoxStrongColor: root.secondaryBoxStrongColor; secondaryInsetColor: root.secondaryInsetColor; barColor: root.barColor; danger: root.danger
            onCloseRequested: root.closeRequested()
            onStudioApplyRequested: root.apply(false)
        }
        AnimationPickerPopup {
            id: motion
            anchors.fill: parent; visible: root.page === "motion"; embedded: true
            foreground: root.foreground; background: root.background; secondaryBoxColor: root.secondaryBoxColor
            secondaryBoxStrongColor: root.secondaryBoxStrongColor; secondaryInsetColor: root.secondaryInsetColor; barColor: root.barColor
            onCloseRequested: root.closeRequested()
            onStudioApplyRequested: root.apply(true)
        }
        BranchStylePicker {
            anchors.fill: parent; visible: root.page === "styles"
            foreground: root.foreground; background: root.background; secondaryBoxColor: root.secondaryBoxColor
            secondaryBoxStrongColor: root.secondaryBoxStrongColor; secondaryInsetColor: root.secondaryInsetColor; barColor: root.barColor; danger: root.danger
            onCloseRequested: root.closeRequested()
        }
        DressPicker {
            id: dress
            anchors.fill: parent; visible: root.page === "dress"
            foreground: root.foreground; background: root.background; secondaryBoxColor: root.secondaryBoxColor
            secondaryBoxStrongColor: root.secondaryBoxStrongColor; secondaryInsetColor: root.secondaryInsetColor; barColor: root.barColor
            onCloseRequested: root.closeRequested()
        }
        CombinationPicker {
            id: combinations
            anchors.fill: parent; visible: root.page === "combinations"
            foreground: root.foreground; background: root.background; secondaryBoxColor: root.secondaryBoxColor
            secondaryBoxStrongColor: root.secondaryBoxStrongColor; secondaryInsetColor: root.secondaryInsetColor; barColor: root.barColor; danger: root.danger
            onCloseRequested: root.closeRequested()
        }
    }
    Column {
        anchors.bottom: parent.bottom; width: parent.width; spacing: 10
        Rectangle { width: parent.width; height: 1; color: Atelier.rule }
        AtelierText { width: parent.width; text: root.message || "Auswählen → abstimmen → anwenden. Kompositionen behalten den ganzen Look."; color: Atelier.muted; font.pixelSize: 11; elide: Text.ElideRight }
        Row {
            width: parent.width; spacing: 10
            Rectangle {
                id: applyButton
                property bool ready: !root.applying && (root.page === "wallpaper" || root.page === "motion") && (root.page === "motion" ? motion.selectedAnimationId !== "" : !!landscape.currentTheme)
                width: parent.width; height: 42; radius: 21
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
