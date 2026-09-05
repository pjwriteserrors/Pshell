pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import "components"

Item {
    id: root
    signal closeRequested
    required property color foreground
    required property color background
    required property color secondaryBoxColor
    required property color secondaryBoxStrongColor
    required property color secondaryInsetColor
    required property color barColor
    property string selectedThemeId: ThemeEngine.currentThemeId
    property int selectedIndex: 0
    readonly property var themeOptions: ThemeEngine.availableThemes

    function syncSelection() {
        for (let i = 0; i < themeOptions.length; ++i)
            if (themeOptions[i].id === selectedThemeId) { selectedIndex = i; return; }
        selectedIndex = 0;
    }
    function selectIndex(index) {
        if (!themeOptions.length) return;
        selectedIndex = Math.max(0, Math.min(themeOptions.length - 1, index));
        selectedThemeId = themeOptions[selectedIndex].id;
        list.positionViewAtIndex(selectedIndex, ListView.Contain);
    }
    function applySelection() {
        if (ThemeEngine.selectTheme(selectedThemeId)) closeRequested();
    }
    focus: true
    Component.onCompleted: syncSelection()
    onThemeOptionsChanged: syncSelection()
    Keys.onEscapePressed: closeRequested()
    Keys.onUpPressed: selectIndex(selectedIndex - 1)
    Keys.onDownPressed: selectIndex(selectedIndex + 1)
    Keys.onLeftPressed: selectIndex(selectedIndex - 1)
    Keys.onRightPressed: selectIndex(selectedIndex + 1)
    Keys.onReturnPressed: applySelection()
    Keys.onEnterPressed: applySelection()


    Item {
        anchors.fill: parent; anchors.margins: 16
        Rectangle {
            id: sample
            width: parent.width * 0.43; height: parent.height - 46; radius: 90
            color: [Atelier.surface, "#d2d8bf", "#d9c6a3", "#c6cfd0", "#d6c6bd"][root.selectedIndex % 5]
            FolioArtwork { anchors.fill: parent; anchors.margins: 30; tint: Atelier.sage }
            Rectangle {
                anchors.centerIn: parent; width: parent.width * 0.7; height: width; radius: width / 2
                color: Atelier.ink
                AtelierText { anchors.centerIn: parent; text: "Aa"; display: true; font.pixelSize: Math.min(110, parent.width * 0.5); color: Atelier.paper }
            }
            AtelierText { x: 26; y: 28; text: "MATERIAL STUDY  /  0" + (root.selectedIndex + 1); font.family: Atelier.mono; font.pixelSize: 10 }
        }
        Column {
            x: sample.width + 32; width: parent.width - x; spacing: 14
            AtelierText { text: "Make it yours."; display: true; font.pixelSize: 32 }
            AtelierText { width: parent.width; text: "Shape, movement and surface. Select a study to explore its character."; wrapMode: Text.WordWrap; color: Atelier.muted; font.pixelSize: 12 }
            GridView {
                id: list
                width: parent.width; height: Math.max(150, root.height - 214)
                model: root.themeOptions; currentIndex: root.selectedIndex; clip: true
                cellWidth: width / 2; cellHeight: 116
                ScrollBar.vertical: ScrollBar {}
                delegate: Item {
                    id: choice
                    required property var modelData
                    required property int index
                    width: list.cellWidth; height: list.cellHeight
                    Rectangle {
                        width: parent.width - 10; height: parent.height - 10; radius: 16
                        color: choice.index === root.selectedIndex ? Atelier.ink : Atelier.surface
                        Row {
                            x: 16; y: 16; spacing: -6
                            Repeater {
                                model: [Atelier.sage, Atelier.gold, Atelier.accent]
                                delegate: Rectangle { required property color modelData; width: 24; height: 24; radius: 12; color: modelData; border.width: 2; border.color: choice.index === root.selectedIndex ? Atelier.ink : Atelier.surface }
                            }
                        }
                        AtelierText { x: 16; y: 58; width: parent.width - 32; text: choice.modelData.name; color: choice.index === root.selectedIndex ? Atelier.paper : Atelier.text; font.pixelSize: 15; elide: Text.ElideRight }
                        AtelierText { x: 16; y: 82; text: choice.index === root.selectedIndex ? "IN FOCUS" : "EXPLORE"; font.family: Atelier.mono; font.pixelSize: 8; color: choice.index === root.selectedIndex ? Atelier.gold : Atelier.muted }
                        MouseArea { anchors.fill: parent; onClicked: { root.selectIndex(choice.index); root.forceActiveFocus(); } }
                    }
                }
            }
            Rectangle {
                width: parent.width; height: 44; radius: 22; color: Atelier.accent
                AtelierText { anchors.centerIn: parent; text: root.selectedThemeId === ThemeEngine.currentThemeId ? "Current material" : "Apply material  ↗"; color: Atelier.paper; font.pixelSize: 13 }
                MouseArea { anchors.fill: parent; onClicked: root.applySelection() }
            }
        }
        AtelierText { anchors.bottom: parent.bottom; text: "← →  Explore    ↵  Apply    Esc  Close"; font.family: Atelier.mono; font.pixelSize: 10; color: Atelier.muted }
    }
}
