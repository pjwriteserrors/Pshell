pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import "components"

// The attachment picker: the same directory thread as the file browser,
// laid over the chat while a file is chosen. Enter attaches the selected
// entry (or steps into a folder), Escape goes back to the chat.
Item {
	id: picker

	required property LauncherEngine engine
	readonly property string home: String(Quickshell.env("HOME") || "")

	Rectangle {
		anchors.fill: parent
		anchors.margins: -8
		radius: Filament.radius
		color: Filament.planeSolid

		// Nothing under the picker should react to the pointer.
		MouseArea { anchors.fill: parent; hoverEnabled: true }
	}

	Item {
		id: header
		width: parent.width
		height: 34

		FText {
			anchors.left: parent.left
			anchors.verticalCenter: parent.verticalCenter
			text: "Attach a file"
			font.pixelSize: Filament.textLg
			font.weight: Font.DemiBold
		}

		FText {
			anchors.left: parent.left
			anchors.leftMargin: 110
			anchors.right: done.left
			anchors.rightMargin: 12
			anchors.verticalCenter: parent.verticalCenter
			text: picker.engine.selectedAiSupportsVision
				? "Text, documents, PDF and images · Enter attaches · Escape returns"
				: "Text, documents and PDF · images need a vision model · Enter attaches"
			tone: "faint"
			font.pixelSize: Filament.textXs
		}

		FButton {
			id: done
			anchors.right: parent.right
			anchors.verticalCenter: parent.verticalCenter
			text: `Done${picker.engine.aiPendingAttachments.length > 0 ? ` · ${picker.engine.aiPendingAttachments.length}` : ""}`
			kind: "charge"
			compact: true
			onClicked: picker.engine.closeAttachmentPicker()
		}
	}

	LauncherFileThread {
		x: 0
		y: 44
		width: parent.width
		height: parent.height - 44
		engine: picker.engine
		picker: true
		directory: picker.engine.aiAttachmentDirectory
		entries: picker.engine.aiAttachmentEntries
		loading: picker.engine.aiAttachmentDirectoryLoading
		error: picker.engine.aiAttachmentDirectoryError
		selectedIndex: picker.engine.attachmentIndex
		shortcuts: [
			{ label: "Home", path: picker.home, icon: "go-home-symbolic" },
			{ label: "Downloads", path: `${picker.home}/Downloads`, icon: "folder-download-symbolic" },
			{ label: "Pictures", path: `${picker.home}/Pictures`, icon: "folder-pictures-symbolic" }
		]
		onSelected: index => picker.engine.attachmentIndex = index
		onActivated: entry => picker.engine.openAttachmentEntry(entry)
		onDirectoryRequested: path => picker.engine.aiAttachmentDirectory = path
	}
}
