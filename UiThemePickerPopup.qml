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

    Rectangle { anchors.fill: parent; color: root.background }
    Column {
        anchors.fill: parent
        anchors.margins: 24
        spacing: 18
        Item {
            width: parent.width
            height: 64
            AtelierText { text: "Interface"; display: true; font.pixelSize: 32 }
            AtelierText {
                y: 44; text: "Choose the character of your desktop."
                color: Atelier.muted; font.pixelSize: 12
            }
            Rectangle {
                anchors.right: parent.right
                width: 100; height: 36; radius: 2
                color: root.barColor
                AtelierText {
                    anchors.centerIn: parent; color: root.background
                    text: root.selectedThemeId === ThemeEngine.currentThemeId ? "Selected" : "Apply"
                    font.pixelSize: 12
                }
                HoverLayer { tint: root.background; onClicked: root.applySelection() }
            }
        }
        ListView {
            id: list
            width: parent.width
            height: parent.height - 112
            clip: true
            model: root.themeOptions
            currentIndex: root.selectedIndex
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar {}
            delegate: Item {
                id: choice
                required property var modelData
                required property int index
                width: list.width
                height: 76
                Rectangle { width: parent.width; height: 1; color: Atelier.rule }
                Rectangle {
                    y: 20; width: 2; height: 36
                    color: root.barColor; visible: choice.index === root.selectedIndex
                }
                AtelierText {
                    x: 16; y: 26; text: ("0" + (choice.index + 1)).slice(-2)
                    font.family: Atelier.mono; font.pixelSize: 11
                    color: choice.index === root.selectedIndex ? root.barColor : Atelier.muted
                }
                AtelierText {
                    x: 64; y: 12; text: choice.modelData.name
                    font.pixelSize: 18; color: root.foreground
                }
                AtelierText {
                    x: 64; y: 40; width: parent.width - 112
                    text: choice.modelData.description
                    elide: Text.ElideRight; font.pixelSize: 12; color: Atelier.muted
                }
                AtelierText {
                    anchors.right: parent.right; y: 26
                    text: choice.index === root.selectedIndex ? "●" : "○"
                    color: choice.index === root.selectedIndex ? root.barColor : Atelier.muted
                }
                HoverLayer {
                    tint: root.foreground; rippleEnabled: false
                    onClicked: { root.selectIndex(choice.index); root.forceActiveFocus(); }
                }
            }
        }
        AtelierText {
            text: "↑ ↓  Browse     ↵  Apply     Esc  Close"
            font.family: Atelier.mono; font.pixelSize: 11; color: Atelier.muted
        }
    }
}
