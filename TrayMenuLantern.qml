pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import "components"

// A tray icon's menu, hung from its bead. Entries are rows on a thread;
// a submenu slides in from the right along the same thread, with the
// parent's name at the top as the way back.
Item {
	id: menu

	property real reveal: 1
	property var handle: null
	property var stack: []
	readonly property var current: stack.length > 0 ? stack[stack.length - 1] : null

	signal closeRequested()

	implicitWidth: Math.max(200, list.contentWidth + 40)
	implicitHeight: Math.min(560, header.height + list.contentHeight + 4)

	onHandleChanged: menu.stack = handle ? [{ handle: handle, title: "" }] : []

	QsMenuOpener {
		id: opener
		menu: menu.current ? menu.current.handle : null
	}

	function push(entry) {
		menu.stack = menu.stack.concat([{ handle: entry, title: entry.text || "" }]);
	}

	function pop() {
		if (menu.stack.length > 1) menu.stack = menu.stack.slice(0, -1);
	}

	Item {
		id: header
		width: parent.width
		height: menu.stack.length > 1 ? 30 : 0
		visible: menu.stack.length > 1
		FButton {
			anchors.left: parent.left
			anchors.verticalCenter: parent.verticalCenter
			icon: "go-previous-symbolic"
			text: menu.current ? menu.current.title : ""
			kind: "ghost"
			compact: true
			onClicked: menu.pop()
		}
	}

	ThreadLine {
		x: 8
		y: header.height + 4
		height: list.contentHeight
		litY: list.currentItem ? list.currentItem.y + list.currentItem.height / 2 : -1
	}

	ListView {
		id: list
		x: 8
		y: header.height + 4
		width: parent.width - 8
		height: parent.height - y
		clip: true
		spacing: 0
		model: opener.children
		currentIndex: -1
		boundsBehavior: Flickable.StopAtBounds
		property real contentWidth: 0

		delegate: Item {
			id: row
			required property var modelData
			required property int index
			width: list.width
			height: modelData.isSeparator ? 9 : 30
			onWidthChanged: {}

			Component.onCompleted: list.contentWidth = Math.max(list.contentWidth, label.implicitWidth + 60)

			Wire {
				visible: row.modelData.isSeparator
				x: 14; anchors.verticalCenter: parent.verticalCenter
				width: parent.width - 24; height: 2
				cold: Filament.wireDim
			}

			ThreadRow {
				visible: !row.modelData.isSeparator
				anchors.fill: parent
				selected: list.currentIndex === row.index
				dim: !(row.modelData.enabled ?? true)
				onEntered: list.currentIndex = row.index
				onClicked: {
					if (!(row.modelData.enabled ?? true)) return;
					if (row.modelData.hasChildren) { menu.push(row.modelData); return; }
					row.modelData.triggered();
					menu.closeRequested();
				}

				Image {
					id: entryIcon
					anchors.left: parent.left
					anchors.verticalCenter: parent.verticalCenter
					width: 14; height: 14
					source: row.modelData.icon || ""
					visible: (row.modelData.icon || "") !== ""
					sourceSize: Qt.size(14, 14)
				}

				FText {
					id: label
					anchors.left: parent.left
					anchors.leftMargin: entryIcon.visible ? 22 : 0
					anchors.right: chevron.left
					anchors.verticalCenter: parent.verticalCenter
					text: row.modelData.text || ""
					font.pixelSize: Filament.textSm
				}

				FText {
					id: chevron
					anchors.right: parent.right
					anchors.rightMargin: 10
					anchors.verticalCenter: parent.verticalCenter
					text: row.modelData.hasChildren ? "›" : ""
					tone: "mute"
					width: row.modelData.hasChildren ? 10 : 0
				}
			}
		}
	}
}
