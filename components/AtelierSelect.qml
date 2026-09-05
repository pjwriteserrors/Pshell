pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls

ComboBox {
    id: control
    implicitHeight: 38
    font.family: Atelier.sans
    font.pixelSize: 12
    leftPadding: 16
    rightPadding: 36
    background: Rectangle { radius: 19; color: control.down ? "#d2d8bf" : Atelier.surface }
    contentItem: AtelierText { text: control.displayText; verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight; font.pixelSize: 12 }
    indicator: AtelierText { x: control.width - 28; y: 8; text: "⌄"; font.pixelSize: 18 }
    delegate: ItemDelegate {
        id: option
        required property int index
        width: control.width
        text: control.textAt(index)
        highlighted: control.highlightedIndex === index
        contentItem: AtelierText { text: option.text; color: option.highlighted ? Atelier.paper : Atelier.text; font.pixelSize: 12; elide: Text.ElideRight }
        background: Rectangle { radius: 12; color: option.highlighted ? Atelier.ink : "transparent" }
    }
    popup: Popup {
        y: control.height + 6; width: control.width; padding: 8
        implicitHeight: Math.min(280, menu.contentHeight + 16)
        background: Rectangle { radius: 18; color: Atelier.canvas; border.width: 1; border.color: Atelier.rule }
        contentItem: ListView {
            id: menu
            clip: true; implicitHeight: contentHeight
            model: control.popup.visible ? control.delegateModel : null
            currentIndex: control.highlightedIndex
            ScrollBar.vertical: ScrollBar {}
        }
    }
}
