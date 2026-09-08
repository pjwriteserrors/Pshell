pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

// One place to change how the desktop looks: wallpaper and colours, window
// motion, and the Git branch that carries the whole setup. Every style branch
// ships a Studio so that switching back out of it is always possible.
Item {
	id: root

	signal closeRequested

	required property color foreground
	required property color background
	required property color secondaryBoxColor
	required property color secondaryBoxStrongColor
	required property color secondaryInsetColor
	required property color barColor
	required property color danger

	property string page: "styles"

	readonly property var pages: [
		{ id: "wallpaper", label: "Wallpaper & Colours" },
		{ id: "motion", label: "Motion" },
		{ id: "styles", label: "Styles" }
	]

	Row {
		id: tabs

		anchors.top: parent.top
		anchors.left: parent.left
		anchors.right: parent.right
		height: 42
		spacing: 8

		Repeater {
			model: root.pages

			delegate: Rectangle {
				id: tab

				required property var modelData

				width: Math.min(220, (root.width - 16) / 3)
				height: 42
				radius: 21
				color: root.page === tab.modelData.id ? root.secondaryBoxStrongColor : "transparent"

				Text {
					anchors.centerIn: parent
					text: tab.modelData.label
					color: root.foreground
					opacity: root.page === tab.modelData.id ? 1 : 0.62
					font.pixelSize: 12
				}

				MouseArea {
					anchors.fill: parent
					cursorShape: Qt.PointingHandCursor
					onClicked: root.page = tab.modelData.id
				}
			}
		}
	}

	Item {
		id: stage

		anchors.top: tabs.bottom
		anchors.topMargin: 14
		anchors.left: parent.left
		anchors.right: parent.right
		anchors.bottom: parent.bottom

		// Only the visible page is instantiated: the wallpaper page starts
		// preview processes and must not run behind another tab.
		Loader {
			anchors.fill: parent
			active: root.page === "wallpaper"
			sourceComponent: ThemePickerPopup {
				foreground: root.foreground
				background: root.background
				secondaryBoxColor: root.secondaryBoxColor
				secondaryBoxStrongColor: root.secondaryBoxStrongColor
				secondaryInsetColor: root.secondaryInsetColor
				barColor: root.barColor
				danger: root.danger
				onCloseRequested: root.closeRequested()
			}
		}

		Loader {
			anchors.fill: parent
			active: root.page === "motion"
			sourceComponent: AnimationPickerPopup {
				foreground: root.foreground
				background: root.background
				secondaryBoxColor: root.secondaryBoxColor
				secondaryBoxStrongColor: root.secondaryBoxStrongColor
				secondaryInsetColor: root.secondaryInsetColor
				barColor: root.barColor
				onCloseRequested: root.closeRequested()
			}
		}

		Loader {
			anchors.fill: parent
			active: root.page === "styles"
			sourceComponent: BranchStylePicker {
				foreground: root.foreground
				background: root.background
				secondaryBoxColor: root.secondaryBoxColor
				secondaryBoxStrongColor: root.secondaryBoxStrongColor
				secondaryInsetColor: root.secondaryInsetColor
				barColor: root.barColor
				danger: root.danger
				onCloseRequested: root.closeRequested()
			}
		}
	}
}
