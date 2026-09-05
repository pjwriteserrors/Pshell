import QtQuick
import QtQuick.Layouts
import qs.components
import qs.services
import qs.config

ColumnLayout {
    id: root

    required property string title
    property string description: ""

    spacing: 0

    StyledText {
        Layout.topMargin: Appearance.spacing.large
        text: root.title
        font.pointSize: Appearance.font.size.larger
        font.family: "DejaVu Serif"
        font.weight: 400
    }

    StyledText {
        visible: root.description !== ""
        text: root.description
        color: Colours.palette.m3outline
    }
}
