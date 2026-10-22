pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// The client's settings: where downloads go, how long they are seeded, the
// speed limits, the port, and whether magnet links open here.
Item {
	id: root

	property bool shown: false

	visible: scrim.opacity > 0.01
	Keys.onEscapePressed: root.shown = false

	// what was typed counts when the sheet closes, without Enter too
	onShownChanged: {
		if (root.shown) return;
		const down = Number(downField.text) || 0;
		const up = Number(upField.text) || 0;
		const port = Number(portField.text) || 6881;
		if (down !== Number(Torrents.settings.downLimit || 0)) Torrents.setSetting("downLimit", down);
		if (up !== Number(Torrents.settings.upLimit || 0)) Torrents.setSetting("upLimit", up);
		if (port !== Number(Torrents.settings.port || 6881)) Torrents.setSetting("port", port);
	}

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
			onPressed: root.shown = false
			onWheel: wheel => wheel.accepted = true
		}
	}

	Rectangle {
		anchors.centerIn: parent
		width: Math.min(560, root.width - 48)
		height: body.implicitHeight + 40
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

		MouseArea {
			anchors.fill: parent
		}

		ColumnLayout {
			id: body

			anchors.left: parent.left
			anchors.right: parent.right
			anchors.top: parent.top
			anchors.margins: 20
			spacing: 12

			RowLayout {
				Layout.fillWidth: true

				StyledText {
					Layout.fillWidth: true
					text: "Torrent settings"
					font.pixelSize: Theme.size.title + 1
					font.weight: Font.DemiBold
				}

				IconButton {
					icon: "close"
					onClicked: root.shown = false
				}
			}

			SectionLabel {
				text: "Downloads go to"
			}

			RowLayout {
				Layout.fillWidth: true
				spacing: 8

				Field {
					Layout.fillWidth: true
					icon: "folder_download_outline"
					clearable: false
					text: Torrents.settings.destination
					onAccepted: Torrents.setSetting("destination", text)
				}

				TextButton {
					text: "Choose…"
					icon: "folder_search_outline"
					onActivated: Torrents.pickFolder(Torrents.settings.destination, path => {
						if (path !== "") Torrents.setSetting("destination", path);
					})
				}
			}

			RowLayout {
				Layout.fillWidth: true

				StyledText {
					Layout.fillWidth: true
					text: "Add paused"
					font.pixelSize: Theme.size.body
				}

				Toggle {
					checked: Torrents.settings.startPaused === true
					onToggled: checked => Torrents.setSetting("startPaused", checked)
				}
			}

			SectionLabel {
				text: "Seeding after the download"
			}

			Segmented {
				Layout.fillWidth: true
				options: [
					{ value: "0", label: "Stop at once" },
					{ value: "1", label: "Until ratio 1" },
					{ value: "2", label: "Until ratio 2" },
					{ value: "-1", label: "Keep seeding" }
				]
				current: String(Torrents.settings.ratio)
				onSelected: value => Torrents.setSetting("ratio", Number(value))
			}

			SectionLabel {
				text: "Speed limits (KB/s, 0 is none)"
			}

			RowLayout {
				Layout.fillWidth: true
				spacing: 8

				Field {
					id: downField

					Layout.fillWidth: true
					icon: "arrow_down_bold"
					clearable: false
					text: String(Torrents.settings.downLimit || 0)
					input.validator: IntValidator {
						bottom: 0
					}
					onAccepted: Torrents.setSetting("downLimit", Number(text) || 0)
				}

				Field {
					id: upField

					Layout.fillWidth: true
					icon: "arrow_up_bold"
					clearable: false
					text: String(Torrents.settings.upLimit || 0)
					input.validator: IntValidator {
						bottom: 0
					}
					onAccepted: Torrents.setSetting("upLimit", Number(text) || 0)
				}
			}

			RowLayout {
				Layout.fillWidth: true
				spacing: 8

				StyledText {
					Layout.fillWidth: true
					text: "Port for incoming peers"
					font.pixelSize: Theme.size.body
				}

				Field {
					id: portField

					Layout.preferredWidth: 110
					clearable: false
					text: String(Torrents.settings.port || 6881)
					input.validator: IntValidator {
						bottom: 1024
						top: 65535
					}
					onAccepted: Torrents.setSetting("port", Number(text) || 6881)
				}
			}

			Rectangle {
				Layout.fillWidth: true
				implicitHeight: hint.implicitHeight + 20
				radius: Theme.radius.medium
				color: Theme.layer2

				RowLayout {
					id: hint

					anchors.left: parent.left
					anchors.right: parent.right
					anchors.verticalCenter: parent.verticalCenter
					anchors.margins: 12
					spacing: 10

					Glyph {
						icon: "magnet"
						size: 18
						color: Theme.primary
					}

					StyledText {
						Layout.fillWidth: true
						wrapMode: Text.WordWrap
						text: Torrents.browsersAsk > 0
							? "Magnet links and .torrent files open here. Your browser still asks once per link while it is open – close it and it is switched over, or tick “always” in its dialog."
							: "Magnet links and .torrent files open here: a click on a mirror in the browser brings up the sheet to pick the folder."
						font.pixelSize: Theme.size.small
						tone: Theme.textMuted
					}
				}
			}
		}
	}
}
