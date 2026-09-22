pragma ComponentBehavior: Bound

import QtQuick
import "components"

// A directory hung from a thread. The path runs along a wire at the top as
// small beads (each one is a place you can go back to), the shortcuts sit
// under it, and the entries hang below with the light on the selected one.
// Used twice: as the file browser and as the chat's attachment picker.
Item {
	id: thread

	required property LauncherEngine engine
	property string directory: ""
	property var entries: []
	property bool loading: false
	property string error: ""
	property int selectedIndex: -1
	property string query: ""
	property var shortcuts: []
	// picker: rows say whether they can be attached instead of offering "open"
	property bool picker: false
	property string emptyText: "This folder is empty"
	property string noMatchText: "No matching files"

	signal selected(int index)
	signal activated(var entry)
	signal directoryRequested(string path)
	signal openFolderRequested(string path)

	readonly property var crumbs: {
		const parts = String(directory || "").split("/").filter(part => part !== "");
		const list = [{ label: "/", path: "/" }];
		let path = "";
		for (const part of parts) {
			path += `/${part}`;
			list.push({ label: part, path });
		}
		return list;
	}
	readonly property int headerHeight: 62

	function iconFor(entry) {
		if (entry?.isDir) return "folder-symbolic";
		const kind = thread.engine.attachmentKind(entry);
		if (kind === "image") return "image-x-generic-symbolic";
		if (kind === "pdf" || kind === "document") return "x-office-document-symbolic";
		if (kind === "text") return "text-x-generic-symbolic";
		return "text-x-generic-symbolic";
	}

	function subtitleFor(entry) {
		if (!entry) return "";
		if (entry.isDir) return "Folder";
		const size = thread.engine.formatAttachmentSize(entry.size);
		if (!thread.picker) return `${entry.suffix || "file"} · ${size}`;
		const kind = thread.engine.attachmentKind(entry);
		if (kind === "image" && !thread.engine.selectedAiSupportsVision) return `${size} · needs a vision model`;
		if (kind === "") return `${size} · unsupported`;
		return `${kind} · ${size}`;
	}

	// ------------------------------------------------------------- the path
	Item {
		id: header
		width: parent.width
		height: thread.headerHeight

		Wire {
			x: 0
			y: 11
			width: parent.width
			height: 2
			cold: Filament.wireDim
			lit: 1
			litFrom: 0
			animateLit: false
			glow: false
			hot: Filament.wire
			opacity: 0.6
		}

		Row {
			id: crumbRow
			x: 0
			y: 0
			spacing: 6
			Repeater {
				model: thread.crumbs
				Bead {
					id: crumb
					required property var modelData
					required property int index
					readonly property bool last: index === thread.crumbs.length - 1
					beadHeight: 22
					padding: 9
					lit: last
					onClicked: thread.directoryRequested(crumb.modelData.path)
					FText {
						text: crumb.modelData.label
						mono: true
						font.pixelSize: Filament.textXs
						color: crumb.last ? Filament.charge : Filament.inkSoft
					}
				}
			}
		}

		FText {
			anchors.right: parent.right
			y: 3
			text: thread.loading
				? "reading"
				: (thread.query !== "" ? `${thread.entries.length} matches` : `${thread.entries.length} items`)
			mono: true
			tone: "faint"
			font.pixelSize: Filament.textXs
		}

		Row {
			x: 0
			y: 32
			spacing: 4
			Repeater {
				model: thread.shortcuts
				FButton {
					required property var modelData
					text: modelData.label
					icon: modelData.icon || ""
					kind: "ghost"
					compact: true
					iconSize: 12
					onClicked: thread.directoryRequested(modelData.path)
				}
			}
			FButton {
				text: "Open folder"
				icon: "document-open-symbolic"
				kind: "ghost"
				compact: true
				iconSize: 12
				visible: !thread.picker
				onClicked: thread.openFolderRequested(thread.directory)
			}
		}
	}

	// ------------------------------------------------------------ the rows
	ListView {
		id: list
		x: 4
		y: thread.headerHeight
		width: parent.width - 4
		height: parent.height - thread.headerHeight
		clip: true
		model: thread.entries
		currentIndex: thread.selectedIndex
		boundsBehavior: Flickable.StopAtBounds
		highlightFollowsCurrentItem: false
		cacheBuffer: 200
		onCurrentIndexChanged: if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain)

		ThreadLine {
			parent: list.contentItem
			x: 0
			y: 0
			height: Math.max(list.height, list.contentHeight)
			litY: list.currentItem ? list.currentItem.y + list.currentItem.height / 2 : -1
			litLength: 30
			z: -1
		}

		delegate: ThreadRow {
			id: row
			required property var modelData
			required property int index
			readonly property bool supported: !thread.picker || row.modelData?.isDir || thread.engine.attachmentSupported(row.modelData)
			readonly property bool already: thread.picker && !row.modelData?.isDir && thread.engine.isAttachmentSelected(row.modelData?.path)
			width: list.width
			height: 40
			inset: 16
			selected: index === thread.selectedIndex
			dim: !supported
			onEntered: thread.selected(index)
			onClicked: thread.activated(row.modelData)

			// A thumbnail for pictures, an icon for the rest.
			Rectangle {
				id: thumb
				anchors.left: parent.left
				anchors.verticalCenter: parent.verticalCenter
				width: 24
				height: 24
				radius: 5
				color: row.modelData?.isImage ? Filament.well : "transparent"
				clip: true

				Image {
					anchors.fill: parent
					visible: row.modelData?.isImage ?? false
					source: row.modelData?.isImage ? `file://${row.modelData.path}` : ""
					sourceSize: Qt.size(48, 48)
					fillMode: Image.PreserveAspectCrop
					asynchronous: true
					cache: true
					smooth: true
				}

				FIcon {
					anchors.centerIn: parent
					visible: !(row.modelData?.isImage ?? false)
					name: thread.iconFor(row.modelData)
					fallbacks: ["text-x-generic-symbolic"]
					size: 17
					color: row.modelData?.isDir ? (row.selected ? Filament.charge : Filament.inkSoft) : Filament.inkMute
				}
			}

			Column {
				anchors.left: parent.left
				anchors.leftMargin: 34
				anchors.right: trailing.left
				anchors.rightMargin: 8
				anchors.verticalCenter: parent.verticalCenter
				spacing: 1
				FText {
					width: parent.width
					text: String(row.modelData?.name || "")
					font.pixelSize: Filament.textMd
					font.weight: row.selected ? Font.DemiBold : Font.Medium
					color: row.selected ? Filament.ink : Filament.inkSoft
				}
				FText {
					width: parent.width
					text: thread.subtitleFor(row.modelData)
					tone: "mute"
					font.pixelSize: Filament.textXs
				}
			}

			Item {
				id: trailing
				anchors.right: parent.right
				anchors.rightMargin: 6
				anchors.verticalCenter: parent.verticalCenter
				width: thread.picker ? 18 : (row.modelData?.isDir ? openFolder.implicitWidth : 0)
				height: parent.height

				// picker: what would happen
				FText {
					visible: thread.picker
					anchors.centerIn: parent
					text: row.modelData?.isDir ? "›" : (row.already ? "✓" : (row.supported ? "+" : "·"))
					mono: true
					font.pixelSize: Filament.textMd
					color: row.already ? Filament.charge : (row.selected ? Filament.ink : Filament.inkMute)
				}

				// browser: a folder can also be opened in the file manager
				FButton {
					id: openFolder
					visible: !thread.picker && (row.modelData?.isDir ?? false)
					anchors.right: parent.right
					anchors.verticalCenter: parent.verticalCenter
					text: "open"
					kind: "ghost"
					compact: true
					opacity: row.selected || row.hovered ? 1 : 0
					Behavior on opacity { NumberAnimation { duration: Filament.quick } }
					onClicked: thread.openFolderRequested(String(row.modelData?.path || ""))
				}
			}
		}
	}

	// ------------------------------------------------------ empty / loading
	Item {
		x: 4
		y: thread.headerHeight
		width: parent.width - 4
		height: 48
		visible: thread.entries.length === 0

		Spark {
			x: -2
			y: 17
			size: 6
			breathing: thread.loading
			color: thread.error !== "" ? Filament.alert : (thread.loading ? Filament.charge : Filament.wireDim)
			intensity: thread.loading || thread.error !== "" ? 1 : 0.5
		}

		FText {
			x: 20
			y: 12
			width: parent.width - 20
			text: thread.loading
				? "Reading the folder"
				: (thread.error !== "" ? thread.error : (thread.query !== "" ? thread.noMatchText : thread.emptyText))
			tone: thread.error !== "" ? "alert" : "soft"
			font.pixelSize: Filament.textMd
		}
	}
}
