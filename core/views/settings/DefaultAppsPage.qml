pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// Default apps (core/services/DefaultApps.qml): which program opens links,
// folders, pictures, videos, music, documents, archives and the rest – what
// xdg-open, the file chooser and every program go by – and the shell's own
// terminal. Each kind folds out every program that can open it.
SettingsPage {
	id: root

	title: "Default apps"
	description: "Which program opens what – for links, files from the file manager and everything that asks the desktop."

	readonly property var groups: [
		{ anchor: "apps-web", title: "Web and mail", subtitle: "Links, pages and mail addresses", icon: "web", kinds: ["browser", "mail"] },
		{ anchor: "apps-files", title: "Files", subtitle: "Folders and archives", icon: "folder_outline", kinds: ["files", "archives"] },
		{ anchor: "apps-media", title: "Pictures, videos, music", subtitle: "What a double click plays or shows", icon: "image_outline", kinds: ["images", "video", "music"] },
		{ anchor: "apps-documents", title: "Documents", subtitle: "Text, PDF, office files, e-books, calendar files", icon: "file_document_outline", kinds: ["text", "pdf", "documents", "ebooks", "calendar"] },
		{ anchor: "apps-more", title: "More", subtitle: "Torrents and 3D models", icon: "apps", kinds: ["torrents", "models"] }
	]

	onActiveChanged: if (root.active) DefaultApps.load()

	headerTrailing: [
		TextButton {
			text: "Read again"
			icon: "refresh"
			variant: "ghost"
			busy: DefaultApps.loading
			onActivated: DefaultApps.load()
		}
	]

	// what went wrong last
	Rectangle {
		Layout.fillWidth: true
		visible: DefaultApps.error !== ""
		implicitHeight: errorText.implicitHeight + 24
		radius: Theme.radius.large
		color: Theme.dangerContainer

		StyledText {
			id: errorText

			anchors.verticalCenter: parent.verticalCenter
			x: 14
			width: parent.width - 28
			text: DefaultApps.error
			tone: Theme.danger
			wrapMode: Text.Wrap
		}
	}

	Repeater {
		model: root.groups

		delegate: SettingCard {
			id: group

			required property var modelData

			anchor: group.modelData.anchor
			title: group.modelData.title
			subtitle: group.modelData.subtitle
			icon: group.modelData.icon

			ColumnLayout {
				Layout.fillWidth: true
				spacing: 2

				Repeater {
					model: group.modelData.kinds.map(id => DefaultApps.byId[id]).filter(kind => kind)

					delegate: AppKindRow {
						required property var modelData
						Layout.fillWidth: true
						kind: modelData
					}
				}

				// before the first read
				Repeater {
					model: DefaultApps.loaded ? 0 : group.modelData.kinds.length

					delegate: Rectangle {
						Layout.fillWidth: true
						Layout.preferredHeight: 58
						radius: Theme.radius.large
						color: Theme.layer2
						opacity: 0.5

						SequentialAnimation on opacity {
							loops: Animation.Infinite
							running: root.active && !DefaultApps.loaded
							NumberAnimation { to: 0.25; duration: 700; easing.type: Easing.InOutSine }
							NumberAnimation { to: 0.5; duration: 700; easing.type: Easing.InOutSine }
						}
					}
				}
			}

			StyledText {
				Layout.fillWidth: true
				visible: group.modelData.kinds.includes("torrents") && Plugins.on("torrents")
				text: "The torrent client keeps magnet links and .torrent files for itself while its plugin is on."
				wrapMode: Text.Wrap
				font.pixelSize: Theme.size.small
				tone: Theme.textSubtle
			}

			StyledText {
				Layout.fillWidth: true
				visible: group.modelData.kinds.includes("browser")
				text: "The browser picked here is also the one the shell opens pages and searches in."
				wrapMode: Text.Wrap
				font.pixelSize: Theme.size.small
				tone: Theme.textSubtle
			}
		}
	}

	// ── the shell's terminal ───────────────────────────────────────────────
	SettingCard {
		anchor: "apps-terminal"
		title: "Terminal"
		subtitle: "What the shell opens commands, SSH logins and scripts in"
		icon: "console"
		modified: DefaultApps.terminal !== ""
		onReset: DefaultApps.keep("terminal", "")

		Flow {
			Layout.fillWidth: true
			spacing: 8

			Repeater {
				model: DefaultApps.terminals

				delegate: AppChoice {
					required property var modelData
					app: modelData
					selected: Terminal.kind === modelData.executable
					note: Terminal.kind === modelData.executable && DefaultApps.terminal === "" ? "host profile" : ""
					onClicked: DefaultApps.keep("terminal", modelData.executable)
				}
			}
		}
	}

	StyledText {
		Layout.fillWidth: true
		visible: DefaultApps.file !== ""
		text: `Kept in ${DefaultApps.file.replace(Paths.home, "~")}${DefaultApps.backedUp ? " – as it was before the first change: mimeapps.list.bak-before-pshell" : ""}`
		wrapMode: Text.Wrap
		font.pixelSize: Theme.size.small
		tone: Theme.textFaint
	}
}
