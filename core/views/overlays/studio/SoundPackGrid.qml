pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// The sound packs, a tile each: a click picks one and plays a click, a
// switch and a notification of it. A pack this machine does not have yet
// shows where it comes from, and installs from its zip when that lies in
// ~/Downloads (scripts/sound_packs.py). Studio's Sounds page and the Sounds
// page of the settings both show it.
ColumnLayout {
	id: root

	property real tileWidth: 250
	readonly property int columns: Math.max(1, Math.floor((root.width + grid.columnSpacing) / (root.tileWidth + grid.columnSpacing)))

	spacing: 10

	Component.onCompleted: Sounds.refreshPacks()

	GridLayout {
		id: grid

		Layout.fillWidth: true
		columns: root.columns
		columnSpacing: 10
		rowSpacing: 10

		Repeater {
			model: Sounds.packs.concat(Sounds.available.map(entry => Object.assign({ missing: true }, entry)))

			delegate: PackTile {
				required property var modelData

				Layout.fillWidth: true
				Layout.fillHeight: true
				Layout.alignment: Qt.AlignTop
				Layout.preferredWidth: root.tileWidth
				entry: modelData
			}
		}
	}

	RowLayout {
		Layout.fillWidth: true
		visible: Sounds.installError !== ""
		spacing: 8

		Glyph {
			icon: "alert_circle_outline"
			size: 16
			color: Theme.danger
		}

		StyledText {
			Layout.fillWidth: true
			text: Sounds.installError
			tone: Theme.danger
			font.pixelSize: Theme.size.small
			wrapMode: Text.WrapAnywhere
		}
	}

	StyledText {
		Layout.fillWidth: true
		visible: Sounds.available.some(entry => !entry.zip)
		text: "A pack that is not here yet: download its zip into ~/Downloads and it can be installed, or run scripts/sound_packs.py install <zip>. Packs that may not be passed on stay out of the repository and are built on each machine."
		tone: Theme.textFaint
		font.pixelSize: Theme.size.small
		wrapMode: Text.WordWrap
	}

	component PackTile: Clickable {
		id: tile

		property var entry: ({})
		readonly property bool missing: tile.entry.missing === true
		readonly property bool picked: !tile.missing && Sounds.current?.id === tile.entry.id
		readonly property bool busy: Sounds.installing === tile.entry.id

		implicitHeight: body.implicitHeight + 28
		radius: Theme.radius.large
		pressedScale: 0.97
		interactive: !tile.missing
		sound: ""
		color: tile.picked ? Theme.primaryContainer : (tile.hovered ? Theme.layer3 : Theme.layer2)
		border.width: tile.picked ? 1.5 : 0
		border.color: Theme.primary
		onClicked: Sounds.setPack(tile.entry.id)

		ColumnLayout {
			id: body

			anchors.left: parent.left
			anchors.right: parent.right
			anchors.top: parent.top
			anchors.margins: 14
			spacing: 10
			opacity: tile.missing ? 0.75 : 1

			RowLayout {
				Layout.fillWidth: true
				spacing: 12

				// the pack plays: three bars that bounce while it is the one
				Rectangle {
					Layout.preferredWidth: 40
					Layout.preferredHeight: 40
					radius: 20
					color: tile.picked ? Theme.primary : Theme.layer3

					Row {
						anchors.centerIn: parent
						height: 18
						spacing: 3

						Repeater {
							model: 3

							delegate: Rectangle {
								id: bar

								required property int index
								property real level: 0.4

								y: (18 - bar.height) / 2
								width: 4
								height: 6 + bar.level * 12
								radius: 2
								color: tile.picked ? Theme.onPrimary : Theme.textMuted

								SequentialAnimation on level {
									running: tile.picked
									loops: Animation.Infinite

									NumberAnimation {
										to: 1
										duration: 260 + bar.index * 90
										easing.type: Easing.OutQuad
									}
									NumberAnimation {
										to: 0.25
										duration: 340 + bar.index * 70
										easing.type: Easing.InOutQuad
									}
								}
							}
						}
					}
				}

				ColumnLayout {
					Layout.fillWidth: true
					spacing: 0

					StyledText {
						Layout.fillWidth: true
						text: tile.entry.name ?? tile.entry.id
						tone: tile.picked ? Theme.primary : Theme.text
						font.weight: Font.DemiBold
						elide: Text.ElideRight
					}

					StyledText {
						Layout.fillWidth: true
						text: `by ${tile.entry.author ?? "?"}`
						tone: Theme.textSubtle
						font.pixelSize: Theme.size.small
						elide: Text.ElideRight
					}
				}

				IconButton {
					visible: !tile.missing && !tile.entry.builtin
					icon: "delete_outline"
					implicitWidth: 28
					implicitHeight: 28
					opacity: tile.hovered ? 1 : 0
					onClicked: Sounds.remove(tile.entry.id)
				}
			}

			StyledText {
				Layout.fillWidth: true
				text: tile.entry.description ?? ""
				tone: Theme.textMuted
				font.pixelSize: Theme.size.small
				wrapMode: Text.WordWrap
			}

			RowLayout {
				Layout.fillWidth: true
				spacing: 8

				Glyph {
					Layout.alignment: Qt.AlignTop
					icon: tile.missing ? "download" : (tile.entry.builtin ? "check_circle" : "monitor")
					size: 14
					color: Theme.textFaint
				}

				StyledText {
					Layout.fillWidth: true
					wrapMode: Text.WordWrap
					text: tile.missing ? (tile.entry.zip ? "Zip found in Downloads" : "Not on this machine") : (tile.entry.builtin ? `In the shell · ${tile.entry.license}` : `On this machine · ${tile.entry.license}`)
					tone: Theme.textFaint
					font.pixelSize: Theme.size.small
				}
			}

			TextButton {
				Layout.fillWidth: true
				visible: tile.missing
				implicitHeight: 32
				variant: tile.entry.zip ? "filled" : "tonal"
				icon: tile.entry.zip ? "download" : "web"
				text: tile.busy ? "Building…" : (tile.entry.zip ? "Install" : "Get it")
				busy: tile.busy
				enabled: Sounds.installing === ""
				onActivated: {
					if (tile.entry.zip) Sounds.install(tile.entry);
					else Qt.openUrlExternally(tile.entry.url);
				}
			}
		}
	}
}
