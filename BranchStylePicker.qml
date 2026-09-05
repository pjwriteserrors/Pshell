pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io

Item {
    id: root
    signal closeRequested
    required property color foreground
    required property color background
    required property color secondaryBoxColor
    required property color secondaryBoxStrongColor
    required property color secondaryInsetColor
    required property color barColor
    property color danger: "#df817b"
    property var entries: []
    property string currentBranch: ""
    property bool dirty: false
    property string errorText: ""
    property string chosenBranch: ""
    property bool confirming: false
    property bool switching: false
    readonly property string script: Quickshell.shellDir + "/scripts/branch_styles.py"
    readonly property var selected: entries.find(item => item.branch === chosenBranch) || null
    function refresh() { if (!catalog.running) catalog.running = true; }
    function choose(branch) { chosenBranch = branch; confirming = false; }
    function apply() {
        if (!selected || dirty || !selected.compatible || selected.current || switching) return;
        if (!confirming) { confirming = true; return; }
        switching = true;
        Quickshell.execDetached(["python3", script, "switch", chosenBranch]);
    }
    Component.onCompleted: refresh()
    focus: true
    Keys.onEscapePressed: { if(confirming) confirming=false; else closeRequested(); }
    Keys.onReturnPressed: apply()
    Keys.onLeftPressed: {
        let index=entries.findIndex(item => item.branch===chosenBranch);
        if(entries.length) choose(entries[Math.max(0,index-1)].branch);
    }
    Keys.onRightPressed: {
        let index=entries.findIndex(item => item.branch===chosenBranch);
        if(entries.length) choose(entries[Math.min(entries.length-1,index+1)].branch);
    }
    Process {
        id: catalog
        command: ["python3", root.script, "catalog"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const data=JSON.parse(text);
                    root.entries=data.branches; root.currentBranch=data.current; root.dirty=data.dirty;
                    root.errorText=data.message || "";
                    if(!root.chosenBranch) root.chosenBranch=data.current;
                    if(root.errorText) root.switching=false;
                } catch(error) { root.errorText=String(error); }
            }
        }
        stderr: StdioCollector { onStreamFinished: if(text.trim()) root.errorText=text.trim(); }
    }
    Timer { interval: 1800; repeat: true; running: root.visible; onTriggered: root.refresh() }
    Column {
        anchors.fill: parent; anchors.margins: 24; spacing: 18
        Text { text: "Styles"; color: root.foreground; font.family: "C059"; font.pixelSize: 38 }
        Text { width: parent.width; text: "One branch. A complete desktop.   /   " + root.currentBranch; color: root.foreground; opacity: 0.65; font.pixelSize: 12; elide: Text.ElideMiddle }
        GridView {
            id: library
            width: parent.width; height: Math.max(120, parent.height - 220); clip: true
            model: root.entries; cellWidth: width / Math.max(1,Math.floor(width/310)); cellHeight: 194
            delegate: Item {
                id: entry
                required property var modelData
                width: library.cellWidth; height: library.cellHeight
                Rectangle {
                    width: parent.width-14; height: parent.height-14; radius: 22
                    color: root.chosenBranch === entry.modelData.branch ? root.secondaryBoxStrongColor : root.secondaryBoxColor
                    border.width: root.chosenBranch === entry.modelData.branch ? 1 : 0; border.color: root.barColor
                    Text { x: 24; y: 22; text: entry.modelData.current ? "● ACTIVE" : "○ LOCAL BRANCH"; color: root.foreground; opacity: 0.65; font.family: "Adwaita Mono"; font.pixelSize: 10 }
                    Text { x: 24; y: 53; width: parent.width-48; text: entry.modelData.name; color: root.foreground; font.family: "C059"; font.pixelSize: 36; elide: Text.ElideRight }
                    Text { x: 24; y: 108; width: parent.width-48; text: entry.modelData.branch; color: root.foreground; opacity: 0.65; font.pixelSize: 12; elide: Text.ElideMiddle }
                    Text { x: 24; y: 144; text: entry.modelData.compatible ? "GIT CHECKOUT  ↗" : "Missing style manifest"; color: root.foreground; font.pixelSize: 10 }
                    MouseArea { anchors.fill: parent; onClicked: { root.choose(entry.modelData.branch); root.forceActiveFocus(); } }
                }
            }
            ScrollBar.vertical: ScrollBar {}
        }
        Text {
            width: parent.width; wrapMode: Text.WordWrap; color: root.dirty || root.errorText ? root.danger : root.foreground
            text: root.dirty ? "Uncommitted changes: commit or move them before switching. Nothing will be discarded."
                : root.errorText || (root.confirming ? "Restart the shell and check out " + root.chosenBranch + "? Press again to confirm." : "Local branches only. No automatic stash, reset or downloads.")
            font.pixelSize: 12
        }
        Rectangle {
            width: parent.width; height: 44; radius: 22
            color: root.secondaryBoxStrongColor
            opacity: root.dirty || !root.selected || root.selected.current || !root.selected.compatible ? 0.5 : 1
            Text { anchors.centerIn: parent; text: root.switching ? "Switching…" : root.selected && root.selected.current ? "Current style" : root.confirming ? "Confirm checkout & restart" : "Use selected style"; color: root.foreground; font.pixelSize: 13 }
            MouseArea { anchors.fill: parent; onClicked: root.apply() }
        }
    }
}
