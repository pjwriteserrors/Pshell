pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import "components"

ThemedRectangle {
	id: root

	signal choiceSelected(int index)

	property string title: ""
	property var model: []
	property int selectedIndex: 0
	property color foreground: "white"
	property color accent: "white"
	property color surface: "#222222"
	property color strongSurface: "#333333"
	property bool showImages: false
	property string labelRole: "name"
	property string detailRole: "mediaType"

	radius: ThemeEngine.radiusMedium
	color: Qt.alpha(root.surface, 0.76)
	border.width: 1
	border.color: Qt.alpha(root.foreground, 0.11)
	clip: true

	AtelierText {
		id: heading
		anchors.top: parent.top
		anchors.left: parent.left
		anchors.margins: 12
		color: root.foreground
		font.pixelSize: 13
		font.weight: Font.DemiBold
		text: root.title
	}

	ListView {
		id: choiceList
		anchors.top: heading.bottom
		anchors.topMargin: 10
		anchors.left: parent.left
		anchors.right: parent.right
		anchors.bottom: parent.bottom
		anchors.margins: 8
		model: root.model
		spacing: 7
		clip: true
		boundsBehavior: Flickable.StopAtBounds
		currentIndex: root.selectedIndex
		onCurrentIndexChanged: if (currentIndex >= 0 && currentIndex !== root.selectedIndex) root.choiceSelected(currentIndex)

		delegate: ThemedRectangle {
			id: choice
			required property int index
			required property var modelData
			readonly property bool selected: index === root.selectedIndex
			width: choiceList.width
			height: root.showImages ? 72 : 58
			radius: ThemeEngine.radiusMedium
			color: selected ? Qt.alpha(root.accent, 0.24) : Qt.alpha(root.strongSurface, choiceMouse.containsMouse ? 0.72 : 0.48)
			border.width: selected ? 2 : 1
			border.color: selected ? Qt.alpha(root.accent, 0.78) : Qt.alpha(root.foreground, 0.08)
			clip: true

			Image {
				id: thumbnail
				visible: root.showImages
				anchors.left: parent.left
				anchors.top: parent.top
				anchors.bottom: parent.bottom
				width: 104
				fillMode: Image.PreserveAspectCrop
				source: String(choice.modelData.previewPath || "")
			}

			Column {
				anchors.left: root.showImages ? thumbnail.right : parent.left
				anchors.leftMargin: root.showImages ? 11 : 12
				anchors.right: parent.right
				anchors.rightMargin: 10
				anchors.verticalCenter: parent.verticalCenter
				spacing: 4
				AtelierText {
					width: parent.width
					color: root.foreground
					font.pixelSize: 12
					font.weight: choice.selected ? Font.DemiBold : Font.Medium
					elide: Text.ElideRight
					text: String(choice.modelData[root.labelRole] || choice.modelData.name || "")
				}
				AtelierText {
					width: parent.width
					color: Qt.alpha(root.foreground, 0.52)
					font.pixelSize: 10
					elide: Text.ElideRight
					text: String(choice.modelData[root.detailRole] || "")
				}
			}

			MouseArea {
				id: choiceMouse
				anchors.fill: parent
				hoverEnabled: true
				cursorShape: Qt.PointingHandCursor
				onClicked: {
					choiceList.currentIndex = choice.index;
					root.choiceSelected(choice.index);
				}
			}
		}
	}
}
