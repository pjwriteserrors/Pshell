import QtQuick

Text {
    property bool display: false
    font.family: display ? Atelier.display : Atelier.sans
    font.letterSpacing: display ? -0.6 : 0.2
    font.weight: Font.Normal
    color: Atelier.paper
    textFormat: Text.PlainText
    renderType: Text.NativeRendering
}
