pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.style.widgets
import qs.core.services

// Searching the file: a field that drops down below the bar, the count of
// what was found and the arrows to walk it (Enter, Shift+Enter). The hits
// themselves are drawn on the pages and along the scroll bar by the reader;
// the sidebar lists them with the words around.
Rectangle {
	id: root

	property bool open: false
	signal closed()

	function focusField() {
		field.input.forceActiveFocus();
		field.input.selectAll();
	}

	width: Math.min(420, Math.max(300, (parent?.width ?? 600) * 0.4))
	height: 48
	radius: 24
	color: Qt.alpha(Theme.bg, 0.96)
	border.color: Theme.outline
	opacity: root.open ? 1 : 0
	visible: opacity > 0.01
	scale: root.open ? 1 : 0.94
	transformOrigin: Item.TopRight

	Behavior on opacity {
		Anim {
			duration: Motion.medium
		}
	}
	Behavior on scale {
		SpatialAnim {
			duration: Motion.medium
		}
	}

	Row {
		anchors.fill: parent
		anchors.leftMargin: 8
		anchors.rightMargin: 6
		spacing: 4

		Field {
			id: field

			anchors.verticalCenter: parent.verticalCenter
			width: parent.width - countText.width - 3 * 30 - 16
			height: 34
			icon: "magnify"
			placeholder: "Search the file"
			color: "transparent"
			text: Pdf.searchText
			onEdited: text => typing.restart()
			onAccepted: Pdf.searchStep(1)
			onEscapePressed: {
				Pdf.searchText = "";
				root.closed();
			}
			onUpPressed: Pdf.searchStep(-1)
			onDownPressed: Pdf.searchStep(1)

			Keys.onReturnPressed: event => Pdf.searchStep(event.modifiers & Qt.ShiftModifier ? -1 : 1)
			Keys.onEnterPressed: event => Pdf.searchStep(event.modifiers & Qt.ShiftModifier ? -1 : 1)
		}

		// a word typed is looked for once the typing rests
		Timer {
			id: typing

			interval: 260
			onTriggered: {
				Pdf.searchCurrent = -1;
				Pdf.searchText = field.text.trim();
			}
		}

		StyledText {
			id: countText

			anchors.verticalCenter: parent.verticalCenter
			width: 64
			horizontalAlignment: Text.AlignRight
			text: Pdf.searchText === "" ? "" : (Pdf.searchCount === 0 ? "None" : `${Pdf.searchCurrent + 1} / ${Pdf.searchCount}`)
			tone: Pdf.searchText !== "" && Pdf.searchCount === 0 ? Theme.danger : Theme.textMuted
			tabular: true
		}

		IconButton {
			anchors.verticalCenter: parent.verticalCenter
			width: 30
			height: 30
			icon: "chevron_up"
			enabled: Pdf.searchCount > 0
			onClicked: Pdf.searchStep(-1)
		}
		IconButton {
			anchors.verticalCenter: parent.verticalCenter
			width: 30
			height: 30
			icon: "chevron_down"
			enabled: Pdf.searchCount > 0
			onClicked: Pdf.searchStep(1)
		}
		IconButton {
			anchors.verticalCenter: parent.verticalCenter
			width: 30
			height: 30
			icon: "format_list_bulleted"
			checked: Pdf.sidebar === "search"
			onClicked: Pdf.sidebar = Pdf.sidebar === "search" ? "" : "search"
		}
	}
}
