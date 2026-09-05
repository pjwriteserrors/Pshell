import QtQuick
import QtQuick.Layouts
import qs.components
import qs.services
import qs.config

StyledRect {
    id: root

    default property alias content: contentColumn.data
    property real contentSpacing: Appearance.spacing.larger
    property bool alignTop: false

    Layout.fillWidth: true
    implicitHeight: contentColumn.implicitHeight + Appearance.padding.large * 2

    radius: Appearance.rounding.normal
    color: "transparent"
    Rectangle { width: parent.width; height: 1; color: Colours.palette.m3outlineVariant }

    ColumnLayout {
        id: contentColumn

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: root.alignTop ? parent.top : undefined
        anchors.verticalCenter: root.alignTop ? undefined : parent.verticalCenter
        anchors.margins: Appearance.padding.large

        spacing: root.contentSpacing
    }
}
