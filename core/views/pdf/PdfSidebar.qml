pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.style.widgets
import qs.core.services

// The left of the window: the pages as small pictures (dragged into a new
// order, several chosen at once), the contents, the notes and marks, what a
// search found, the folder's other PDFs and what is attached. It slides in
// from the edge; the tab chosen is kept (Pdf.sidebar).
Rectangle {
	id: root

	property var reader: null
	property var menu: null
	property real fullWidth: 240

	color: Qt.alpha(Pdf.night ? "#121317" : Theme.bg, 0.97)

	Rectangle {
		anchors.right: parent.right
		anchors.top: parent.top
		anchors.bottom: parent.bottom
		width: 1
		color: Theme.outline
	}

	readonly property var tabs: [
		{ value: "pages", icon: "file_multiple_outline", tip: "Pages" },
		{ value: "outline", icon: "format_list_bulleted_square", tip: "Contents" },
		{ value: "notes", icon: "comment_text_multiple_outline", tip: "Notes and marks" },
		{ value: "search", icon: "magnify", tip: "Found" },
		{ value: "files", icon: "folder_outline", tip: "Folder and attachments" }
	]
	readonly property string tab: Pdf.sidebar === "" ? "pages" : Pdf.sidebar

	// the content keeps its width while the sidebar slides, so it is pushed in, not squeezed
	Item {
		id: body

		x: root.width - root.fullWidth
		width: root.fullWidth
		height: root.height

		Row {
			id: tabRow

			anchors.horizontalCenter: parent.horizontalCenter
			y: 8
			spacing: 2

			Repeater {
				model: root.tabs

				IconButton {
					required property var modelData

					width: 38
					height: 34
					icon: modelData.icon
					iconSize: 18
					checked: root.tab === modelData.value
					onClicked: Pdf.sidebar = modelData.value
				}
			}
		}

		StyledText {
			id: tabTitle

			anchors.left: parent.left
			anchors.leftMargin: 14
			anchors.top: tabRow.bottom
			anchors.topMargin: 10
			text: (root.tabs.find(t => t.value === root.tab)?.tip ?? "") + (root.tab === "pages" && Pdf.selectedPages.length > 1 ? `  ·  ${Pdf.selectedPages.length} chosen` : "")
			tone: Theme.textMuted
			font.pixelSize: Theme.size.small
			font.weight: Font.DemiBold
		}

		Loader {
			id: content

			anchors.left: parent.left
			anchors.right: parent.right
			anchors.top: tabTitle.bottom
			anchors.bottom: parent.bottom
			anchors.topMargin: 6
			clip: true
			sourceComponent: root.tab === "outline" ? outline : (root.tab === "notes" ? notes : (root.tab === "search" ? found : (root.tab === "files" ? files : pages)))
			opacity: 0
			onLoaded: fade.restart()

			NumberAnimation {
				id: fade

				target: content
				property: "opacity"
				from: 0
				to: 1
				duration: Motion.medium
			}
		}
	}

	Component {
		id: pages

		SidebarPages {
			reader: root.reader
			menu: root.menu
		}
	}

	Component {
		id: outline

		SidebarOutline {
			reader: root.reader
		}
	}

	Component {
		id: notes

		SidebarNotes {}
	}

	Component {
		id: found

		SidebarSearch {
			reader: root.reader
		}
	}

	Component {
		id: files

		SidebarFiles {}
	}
}
