pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// What comes up when a magnet link or a .torrent file arrives: its name and
// size, where it should go (the default, the last places, any folder), the
// room left there, which files are wanted, and whether it starts now.
// A magnet link's files come in while it is open; it can be added before.
Item {
	id: root

	// the waiting torrent shown: Torrents.pending[0]
	readonly property var entry: Torrents.pending.length > 0 ? Torrents.pending[0] : null
	readonly property bool shown: root.entry !== null
	property string pid: ""
	property string destination: ""
	// indices of the files left out
	property var skip: []
	property bool startNow: true
	property bool inOrder: false
	property bool remember: false
	// { free, total, exists, writable } of the destination
	property var space: null

	readonly property real wantedSize: {
		if (!root.entry || !root.entry.hasMetadata) return -1;
		return root.entry.files.reduce((sum, file) => root.skip.includes(file.index) ? sum : sum + file.size, 0);
	}
	readonly property bool tight: root.space !== null && root.space.free >= 0 && root.wantedSize > 0 && root.wantedSize > root.space.free

	visible: scrim.opacity > 0.01

	// a new one: the defaults again
	onEntryChanged: {
		if (!root.entry || root.entry.pid === root.pid || root.entry.uri === root.pidUri) {
			if (root.entry) root.pid = root.entry.pid;
			return;
		}
		root.pid = root.entry.pid;
		root.pidUri = root.entry.uri ?? "";
		root.destination = Torrents.settings.destination;
		root.skip = [];
		root.startNow = !Torrents.settings.startPaused;
		root.inOrder = false;
		root.remember = false;
		root.measure();
		Sounds.play("open");
	}
	property string pidUri: ""

	onDestinationChanged: measureLater.restart()

	Timer {
		id: measureLater

		interval: 250
		onTriggered: root.measure()
	}

	function measure() {
		const path = root.destination;
		Torrents.space(path, data => {
			if (root.destination === path) root.space = data;
		});
	}

	function accept() {
		if (!root.entry || root.entry.loading || root.entry.error) return;
		Torrents.confirm(root.entry.pid, root.destination, root.skip, { paused: !root.startNow, sequential: root.inOrder, remember: root.remember });
		root.pid = "";
		root.pidUri = "";
	}

	function dismiss() {
		if (root.entry) Torrents.cancel(root.entry.pid);
		root.pid = "";
		root.pidUri = "";
	}

	function toggleFile(index) {
		root.skip = root.skip.includes(index) ? root.skip.filter(other => other !== index) : root.skip.concat([index]);
	}

	Keys.onEscapePressed: root.dismiss()
	Keys.onReturnPressed: root.accept()
	Keys.onEnterPressed: root.accept()

	Rectangle {
		id: scrim

		anchors.fill: parent
		color: Theme.scrim
		opacity: root.shown ? 1 : 0

		Behavior on opacity {
			Anim {}
		}

		MouseArea {
			anchors.fill: parent
			acceptedButtons: Qt.AllButtons
			hoverEnabled: true
			onWheel: wheel => wheel.accepted = true
		}
	}

	Rectangle {
		id: card

		anchors.centerIn: parent
		width: Math.min(640, root.width - 48)
		height: Math.min(root.height - 48, body.implicitHeight + 40)
		radius: Theme.radius.huge
		color: Theme.layer1
		border.width: 1
		border.color: Theme.outline
		scale: root.shown ? 1 : 0.92
		opacity: root.shown ? 1 : 0

		Behavior on scale {
			SpatialAnim {
				duration: root.shown ? Motion.long : Motion.short
			}
		}
		Behavior on opacity {
			Anim {}
		}
		Behavior on height {
			SpatialAnim {}
		}

		ColumnLayout {
			id: body

			anchors.fill: parent
			anchors.margins: 20
			spacing: 14

			// ── what it is ──────────────────────────────────────────────
			RowLayout {
				Layout.fillWidth: true
				spacing: 14

				Rectangle {
					Layout.preferredWidth: 48
					Layout.preferredHeight: 48
					radius: Theme.radius.large
					color: Theme.primaryContainer

					Glyph {
						anchors.centerIn: parent
						icon: (root.entry?.uri ?? "").startsWith("magnet:") ? "magnet" : "file_download_outline"
						size: 24
						color: Theme.primary
					}

					// the link is still being looked up
					Spinner {
						anchors.fill: parent
						anchors.margins: -4
						thickness: 2.5
						visible: root.entry?.loading === true || (root.entry !== null && !root.entry.hasMetadata && !root.entry.error)
					}
				}

				ColumnLayout {
					Layout.fillWidth: true
					spacing: 2

					StyledText {
						Layout.fillWidth: true
						text: root.entry?.name ?? ""
						font.pixelSize: Theme.size.title + 1
						font.weight: Font.DemiBold
						wrapMode: Text.WrapAnywhere
						maximumLineCount: 2
						elide: Text.ElideRight
					}

					StyledText {
						Layout.fillWidth: true
						text: {
							const entry = root.entry;
							if (!entry) return "";
							if (entry.error) return entry.error;
							if (entry.loading) return "Reading the link…";
							if (!entry.hasMetadata) return entry.peers > 0 ? `Getting the file list from ${entry.peers} peer${entry.peers === 1 ? "" : "s"}…` : "Looking for peers…";
							const count = entry.files.length;
							return `${Torrents.size(entry.total)} · ${count} file${count === 1 ? "" : "s"}`;
						}
						font.pixelSize: Theme.size.small
						tone: root.entry?.error ? Theme.danger : Theme.textMuted
						elide: Text.ElideRight
					}
				}

				StyledText {
					visible: Torrents.pending.length > 1
					text: `+${Torrents.pending.length - 1} more`
					font.pixelSize: Theme.size.small
					tone: Theme.textSubtle
				}
			}

			// ── where it goes ───────────────────────────────────────────
			SectionLabel {
				text: "Save to"
			}

			RowLayout {
				Layout.fillWidth: true
				spacing: 8

				Field {
					id: destinationField

					Layout.fillWidth: true
					icon: "folder_download_outline"
					placeholder: "Folder"
					clearable: false
					text: root.destination
					onEdited: text => root.destination = text
					onAccepted: root.accept()
				}

				TextButton {
					icon: "folder_search_outline"
					text: "Choose…"
					onActivated: Torrents.pickFolder(root.destination, path => {
						if (path !== "") root.destination = path;
					})
				}
			}

			// the default and the last places
			Flow {
				Layout.fillWidth: true
				spacing: 6
				visible: places.count > 0

				Repeater {
					id: places

					model: {
						const list = [Torrents.settings.destination].concat(Torrents.settings.recent || []);
						return list.filter((path, i) => path && list.indexOf(path) === i).slice(0, 6);
					}

					Chip {
						required property string modelData
						required property int index

						text: {
							const parts = modelData.replace(Paths.home, "~").split("/").filter(part => part !== "");
							return parts.length > 3 ? `…/${parts.slice(-2).join("/")}` : (modelData.startsWith(Paths.home) ? parts.join("/") : `/${parts.join("/")}`);
						}
						icon: index === 0 ? "star_outline" : "history"
						selected: root.destination === modelData
						onClicked: root.destination = modelData
					}
				}
			}

			// how much room there is
			RowLayout {
				Layout.fillWidth: true
				spacing: 8
				visible: root.space !== null && root.space.free >= 0

				Rectangle {
					Layout.fillWidth: true
					Layout.preferredHeight: 6
					radius: 3
					color: Theme.layer3

					// used already
					Rectangle {
						width: root.space && root.space.total > 0 ? parent.width * (1 - root.space.free / root.space.total) : 0
						height: parent.height
						radius: 3
						color: Theme.textFaint

						Behavior on width {
							Anim {}
						}
					}

					// what this one takes
					Rectangle {
						x: root.space && root.space.total > 0 ? parent.width * (1 - root.space.free / root.space.total) : 0
						width: root.space && root.space.total > 0 && root.wantedSize > 0 ? Math.min(parent.width - x, parent.width * root.wantedSize / root.space.total) : 0
						height: parent.height
						radius: 3
						color: root.tight ? Theme.danger : Theme.primary

						Behavior on width {
							Anim {}
						}
						Behavior on x {
							Anim {}
						}
					}
				}

				StyledText {
					text: {
						if (!root.space) return "";
						const free = `${Torrents.size(root.space.free)} free`;
						if (root.tight) return `${free} – not enough`;
						if (!root.space.exists) return `${free} · the folder will be made`;
						return free;
					}
					font.pixelSize: Theme.size.small
					tone: root.tight ? Theme.danger : Theme.textMuted
					tabular: true
				}
			}

			// ── which files ─────────────────────────────────────────────
			RowLayout {
				Layout.fillWidth: true
				visible: (root.entry?.files ?? []).length > 1

				SectionLabel {
					text: `Files · ${Torrents.size(root.wantedSize)} wanted`
				}

				Item {
					Layout.fillWidth: true
				}

				TextButton {
					variant: "ghost"
					implicitHeight: 26
					text: root.skip.length > 0 ? "All" : "None"
					onActivated: root.skip = root.skip.length > 0 ? [] : root.entry.files.map(file => file.index)
				}
			}

			ListView {
				id: fileList

				Layout.fillWidth: true
				Layout.fillHeight: true
				Layout.preferredHeight: Math.min(240, contentHeight)
				Layout.minimumHeight: Math.min(120, contentHeight)
				visible: (root.entry?.files ?? []).length > 1
				clip: true
				boundsBehavior: Flickable.StopAtBounds
				model: root.entry?.files ?? []
				ScrollBar.vertical: ThinScrollBar {}

				delegate: Clickable {
					id: line

					required property var modelData
					readonly property bool wanted: !root.skip.includes(line.modelData.index)

					width: fileList.width
					height: 34
					radius: Theme.radius.small
					sound: ""
					onClicked: root.toggleFile(line.modelData.index)

					RowLayout {
						anchors.fill: parent
						anchors.leftMargin: 8
						anchors.rightMargin: 8
						spacing: 10

						Glyph {
							icon: line.wanted ? "checkbox_marked" : "checkbox_blank_outline"
							size: 18
							color: line.wanted ? Theme.primary : Theme.textSubtle
						}

						StyledText {
							Layout.fillWidth: true
							text: String(line.modelData.path).split("/").slice(1).join("/") || line.modelData.path
							font.pixelSize: Theme.size.small
							tone: line.wanted ? Theme.text : Theme.textSubtle
							elide: Text.ElideMiddle
						}

						StyledText {
							text: Torrents.size(line.modelData.size)
							font.pixelSize: Theme.size.small
							tone: Theme.textMuted
							tabular: true
						}
					}
				}
			}

			// ── how ─────────────────────────────────────────────────────
			Flow {
				Layout.fillWidth: true
				spacing: 8

				Chip {
					icon: "play"
					text: "Start right away"
					selected: root.startNow
					onClicked: root.startNow = !root.startNow
				}

				Chip {
					icon: "format_list_numbered"
					text: "In order (to watch while it loads)"
					selected: root.inOrder
					onClicked: root.inOrder = !root.inOrder
				}

				Chip {
					icon: "star_outline"
					text: "Always save here"
					visible: root.destination !== Torrents.settings.destination
					selected: root.remember
					onClicked: root.remember = !root.remember
				}
			}

			RowLayout {
				Layout.fillWidth: true
				spacing: 8

				Item {
					Layout.fillWidth: true
				}

				TextButton {
					variant: "ghost"
					text: "Cancel"
					onActivated: root.dismiss()
				}

				TextButton {
					variant: "filled"
					icon: "download"
					text: root.startNow ? "Download" : "Add paused"
					enabled: root.entry !== null && !root.entry.loading && !root.entry.error && root.destination !== "" && (root.wantedSize !== 0)
					onActivated: root.accept()
				}
			}
		}
	}
}
