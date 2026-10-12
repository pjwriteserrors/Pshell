pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// A folder as the wallpaper: its pictures as a mosaic, how often the next
// one comes, and whether they come in order or at random. The shell's theme
// follows each one, as it does for any wallpaper.
DialogFrame {
	id: root

	property string folder: ""
	property var pictures: []
	property int minutes: 60
	property bool shuffle: true

	function open(folder) {
		root.folder = folder;
		root.pictures = [];
		const current = FileLibrary.setting("wallRotation");
		root.minutes = current?.folder === folder ? Number(current.minutes) || 60 : 60;
		root.shuffle = current?.folder === folder ? current.shuffle !== false : true;
		root.show();
		keys.forceActiveFocus();
		Files.request("list", { path: folder }, data => {
			root.pictures = (data?.entries ?? []).filter(entry => !entry.dir && !entry.hidden && /^image\//.test(entry.mime)).sort((a, b) => b.mtime - a.mtime);
		});
	}

	readonly property bool running: FileLibrary.setting("wallRotation")?.folder === root.folder

	cardWidth: 720
	onDismissed: root.hide()

	Item {
		id: keys

		focus: root.shown
		Keys.onEscapePressed: root.hide()
	}

	ColumnLayout {
		width: parent.width
		spacing: 12

		RowLayout {
			spacing: 12

			Rectangle {
				width: 40
				height: 40
				radius: 13
				color: Qt.tint(Theme.layer2, Qt.alpha(Theme.tertiary, 0.2))

				Glyph {
					anchors.centerIn: parent
					icon: "wallpaper"
					size: 20
					color: Theme.tertiary
				}
			}

			ColumnLayout {
				Layout.fillWidth: true
				spacing: 1

				StyledText {
					text: "Wallpapers from this folder"
					font.pixelSize: Theme.size.title
					font.weight: Font.DemiBold
				}

				StyledText {
					Layout.fillWidth: true
					text: `${Files.pretty(root.folder)} · ${root.pictures.length} picture${root.pictures.length === 1 ? "" : "s"}${root.running ? " · running" : ""}`
					tone: Theme.textSubtle
					font.pixelSize: Theme.size.small
					elide: Text.ElideMiddle
				}
			}
		}

		// the mosaic: every picture, small, a click puts one on now
		Rectangle {
			Layout.fillWidth: true
			Layout.preferredHeight: Math.min(330, Math.max(120, root.height - 330))
			radius: Theme.radius.large
			color: Theme.layer2
			clip: true

			GridView {
				id: mosaic

				anchors.fill: parent
				anchors.margins: 6
				cellWidth: Math.floor(width / Math.max(3, Math.floor(width / 120)))
				cellHeight: Math.round(cellWidth * 0.62)
				model: root.pictures
				boundsBehavior: Flickable.StopAtBounds

				delegate: Item {
					id: tile

					required property var modelData
					required property int index

					width: mosaic.cellWidth
					height: mosaic.cellHeight
					opacity: 0

					Component.onCompleted: fade.start()

					NumberAnimation {
						id: fade

						target: tile
						property: "opacity"
						to: 1
						duration: Motion.medium
					}

					FileThumb {
						anchors.fill: parent
						anchors.margins: 3
						compact: true
						radius: 8
						path: tile.modelData.path
						name: tile.modelData.name
						mime: tile.modelData.mime
						kind: "image"
						thumb: tile.modelData.thumb
						canThumb: tile.modelData.canThumb
						hovered: tileMouse.containsMouse
					}

					MouseArea {
						id: tileMouse

						anchors.fill: parent
						hoverEnabled: true
						cursorShape: Qt.PointingHandCursor
						onClicked: root.view?.setWallpaper(tile.modelData.path)
					}
				}
			}

			EmptyState {
				anchors.centerIn: parent
				visible: root.pictures.length === 0
				icon: "image_off_outline"
				title: "No pictures in it"
			}
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 10

			StyledText {
				text: "The next one every"
				tone: Theme.textMuted
				font.pixelSize: Theme.size.small
			}

			Segmented {
				Layout.fillWidth: true
				height: 32
				options: [{ value: "15", label: "15 min" }, { value: "60", label: "hour" }, { value: "180", label: "3 hours" }, { value: "1440", label: "day" }]
				current: String(root.minutes)
				onSelected: value => root.minutes = Number(value)
			}
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 10

			Toggle {
				checked: root.shuffle
				onToggled: on => root.shuffle = on
			}

			StyledText {
				Layout.fillWidth: true
				text: root.shuffle ? "At random" : "In order, newest first"
				tone: Theme.textMuted
				font.pixelSize: Theme.size.small
			}

			TextButton {
				visible: root.running
				text: "Stop"
				variant: "ghost"
				onClicked: {
					FileLibrary.set("wallRotation", null);
					root.hide();
				}
			}

			TextButton {
				text: root.running ? "Keep it" : "Start"
				icon: "play_outline"
				variant: "filled"
				enabled: root.pictures.length > 1
				onClicked: {
					FileLibrary.set("wallRotation", { folder: root.folder, minutes: root.minutes, shuffle: root.shuffle, last: "", at: 0 });
					Files.rotateWallpaper(true);
					root.hide();
				}
			}
		}
	}

	property var view: null
}
