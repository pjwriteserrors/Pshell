pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell.Widgets
import qs.style.theme
import qs.core.services
import qs.style.widgets

// The browsers' downloads (core/services/Downloads.qml). A download fills
// its card from the left while it runs, with a light running through what
// is there already; the ring around its file type counts along. Finished
// ones turn green and stay until dismissed: a click opens the file, the
// folder button shows it in the file manager. The tune button folds out
// what the bar shows and which file manager is asked.
ColumnLayout {
	id: root

	// the section is on the screen
	property bool shown: false
	property bool settings: false

	spacing: 8

	onShownChanged: {
		if (root.shown) Downloads.seen();
		else root.settings = false;
	}

	Connections {
		target: Downloads
		function onUnseenChanged() {
			if (root.shown) Downloads.seen();
		}
	}

	function glyph(item) {
		const name = item.name.toLowerCase();
		if (item.mime.startsWith("image/") || /\.(png|jpe?g|gif|webp|svg|avif|heic)$/.test(name)) return "image";
		if (item.mime.startsWith("video/") || /\.(mp4|mkv|webm|mov|avi)$/.test(name)) return "video";
		if (item.mime.startsWith("audio/") || /\.(mp3|flac|ogg|opus|wav|m4a)$/.test(name)) return "music";
		if (item.mime === "application/pdf" || name.endsWith(".pdf")) return "file_pdf_box";
		if (/\.(zip|tar|gz|xz|zst|bz2|7z|rar|deb|rpm|iso|img|appimage|flatpak)$/.test(name)) return "package_variant";
		return "file_document";
	}

	RowLayout {
		Layout.fillWidth: true
		Layout.leftMargin: 4
		spacing: 8

		SectionLabel {
			text: "Downloads"
		}

		// a browser is connected
		Rectangle {
			implicitWidth: 7
			implicitHeight: 7
			radius: 3.5
			color: Downloads.connected ? Theme.success : Theme.textFaint

			Behavior on color {
				ColorAnim {}
			}
		}

		Item {
			Layout.fillWidth: true
		}

		StyledText {
			visible: Downloads.running.length > 0
			text: Network.formatSpeed(Downloads.speed)
			tabular: true
			tone: Theme.primary
			font.pixelSize: Theme.size.label
			font.weight: Font.Bold
		}

		IconButton {
			implicitWidth: 28
			implicitHeight: 28
			icon: "tune"
			iconSize: 15
			checked: root.settings
			onClicked: root.settings = !root.settings
		}
	}

	Rectangle {
		Layout.fillWidth: true
		visible: root.settings
		implicitHeight: options.implicitHeight + 24
		radius: Theme.radius.large
		color: Theme.layer1

		ColumnLayout {
			id: options

			x: 12
			y: 12
			width: parent.width - 24
			spacing: 10

			SectionLabel {
				text: "Bar"
			}

			Flow {
				Layout.fillWidth: true
				spacing: 6

				Repeater {
					model: [
						{ name: "hideWhenIdle", label: "Hide when idle", on: Downloads.hideWhenIdle },
						{ name: "showPercent", label: "Percentage", on: Downloads.showPercent },
						{ name: "showSpeed", label: "Speed", on: Downloads.showSpeed }
					]

					delegate: Chip {
						required property var modelData
						text: modelData.label
						icon: modelData.on ? "check_bold" : ""
						selected: modelData.on
						onClicked: Downloads.set(modelData.name, !modelData.on)
					}
				}
			}

			SectionLabel {
				text: "File manager"
			}

			Flow {
				Layout.fillWidth: true
				spacing: 6

				Repeater {
					model: ["auto"].concat(Downloads.managers)

					delegate: Chip {
						required property string modelData
						text: modelData === "auto" ? "Auto" : modelData.charAt(0).toUpperCase() + modelData.slice(1)
						selected: (Downloads.managers.includes(Downloads.fileManager) ? Downloads.fileManager : "auto") === modelData
						onClicked: Downloads.set("fileManager", modelData)
					}
				}
			}
		}
	}

	Repeater {
		model: Downloads.order

		delegate: Clickable {
			id: card

			required property string modelData
			readonly property var item: Downloads.table[card.modelData] ?? null
			readonly property string state_: card.item?.state ?? ""
			readonly property bool running: card.state_ === "running"
			readonly property bool done: card.state_ === "done"
			readonly property bool sized: (card.item?.total ?? 0) > 0
			readonly property real ratio: card.done ? 1 : (card.sized ? Math.min(1, card.item.received / card.item.total) : 0)
			readonly property color accent: card.done ? Theme.success : (card.state_ === "failed" ? Theme.danger : (card.running ? Theme.primary : Theme.textMuted))

			Layout.fillWidth: true
			implicitHeight: 66
			radius: Theme.radius.large
			color: Theme.layer1
			pressedScale: 0.985
			showHover: card.done
			interactive: card.done
			onClicked: Downloads.open(card.modelData)

			ClippingRectangle {
				anchors.fill: parent
				radius: card.radius
				color: "transparent"

				// what is there already
				Rectangle {
					id: fill

					height: parent.height
					// without a size the whole card is the fill
					width: parent.width * (card.sized || card.done ? card.ratio : 1)
					opacity: card.done || card.state_ === "failed" ? 0 : (card.sized ? 1 : 0.5)
					gradient: Gradient {
						orientation: Gradient.Horizontal
						GradientStop { position: 0; color: Qt.alpha(card.accent, 0.07) }
						GradientStop { position: 1; color: Qt.alpha(card.accent, 0.26) }
					}

					Behavior on width {
						NumberAnimation {
							duration: 1000
						}
					}
					Behavior on opacity {
						NumberAnimation {
							duration: 900
							easing.type: Easing.OutCubic
						}
					}

					// the light that runs through it
					Rectangle {
						id: sheen

						property real travel: 0

						visible: card.running
						x: -width + (fill.width + width) * sheen.travel
						width: 90
						height: parent.height
						gradient: Gradient {
							orientation: Gradient.Horizontal
							GradientStop { position: 0; color: Qt.alpha(card.accent, 0) }
							GradientStop { position: 0.5; color: Qt.alpha(card.accent, 0.22) }
							GradientStop { position: 1; color: Qt.alpha(card.accent, 0) }
						}

						NumberAnimation on travel {
							running: card.running && root.shown
							from: 0
							to: 1
							duration: 1700
							loops: Animation.Infinite
						}
					}

					// its front
					Rectangle {
						anchors.right: parent.right
						visible: card.sized && !card.done
						width: 2
						height: parent.height
						color: Qt.alpha(card.accent, 0.7)
					}
				}
			}

			RowLayout {
				anchors.fill: parent
				anchors.leftMargin: 12
				anchors.rightMargin: 10
				spacing: 12

				Item {
					Layout.preferredWidth: 42
					Layout.preferredHeight: 42

					Ring {
						anchors.fill: parent
						value: card.ratio
						thickness: 3
						color: card.accent
						trackColor: Qt.alpha(Theme.text, 0.1)
					}

					Glyph {
						anchors.centerIn: parent
						icon: card.done ? "check_bold" : (card.state_ === "failed" ? "alert" : (card.item ? root.glyph(card.item) : "download"))
						size: 18
						color: card.done || card.state_ === "failed" ? card.accent : Theme.text
					}
				}

				ColumnLayout {
					Layout.fillWidth: true
					spacing: 2

					StyledText {
						Layout.fillWidth: true
						text: card.item?.name ?? ""
						font.weight: Font.DemiBold
						elide: Text.ElideMiddle
					}

					StyledText {
						Layout.fillWidth: true
						text: {
							const item = card.item;
							if (!item) return "";
							if (card.done) return Downloads.formatSize(item.total || item.received);
							if (card.state_ === "failed") return "Failed";
							const size = card.sized ? `${Downloads.formatSize(item.received)} of ${Downloads.formatSize(item.total)}` : Downloads.formatSize(item.received);
							return card.running ? size : `Paused  ·  ${size}`;
						}
						tabular: true
						tone: card.state_ === "failed" ? Theme.danger : Theme.textMuted
						font.pixelSize: Theme.size.label
					}
				}

				ColumnLayout {
					visible: card.running || card.state_ === "paused"
					spacing: 0

					StyledText {
						Layout.alignment: Qt.AlignRight
						visible: card.sized
						text: `${Math.floor(card.ratio * 100)}%`
						tabular: true
						tone: card.accent
						font.pixelSize: Theme.size.title
						font.weight: Font.Bold
					}

					StyledText {
						Layout.alignment: Qt.AlignRight
						visible: card.running
						text: card.item ? [Network.formatSpeed(card.item.speed), Downloads.formatEta(card.item.eta)].filter(part => part !== "").join("  ·  ") : ""
						tabular: true
						tone: Theme.textMuted
						font.pixelSize: Theme.size.small
					}
				}

				IconButton {
					implicitWidth: 30
					implicitHeight: 30
					visible: card.running || card.state_ === "paused" || (card.state_ === "failed" && card.item.canResume)
					icon: card.running ? "pause" : "play"
					iconSize: 16
					variant: "tonal"
					onClicked: card.running ? Downloads.pause(card.modelData) : Downloads.resume(card.modelData)
				}

				IconButton {
					implicitWidth: 30
					implicitHeight: 30
					visible: card.done
					icon: "folder_open"
					iconSize: 16
					variant: "tonal"
					onClicked: Downloads.reveal(card.modelData)
				}

				IconButton {
					implicitWidth: 30
					implicitHeight: 30
					icon: "close"
					iconSize: 16
					onClicked: card.running || card.state_ === "paused" ? Downloads.cancel(card.modelData) : Downloads.dismiss(card.modelData)
				}
			}
		}
	}

	Rectangle {
		Layout.fillWidth: true
		visible: Downloads.order.length === 0
		implicitHeight: 54
		radius: Theme.radius.large
		color: Theme.layer1

		Row {
			anchors.centerIn: parent
			spacing: 8

			Glyph {
				anchors.verticalCenter: parent.verticalCenter
				icon: Downloads.connected ? "download" : "link_off"
				size: 16
				color: Theme.textSubtle
			}

			StyledText {
				anchors.verticalCenter: parent.verticalCenter
				text: Downloads.connected ? "No downloads" : "No browser connected"
				tone: Theme.textMuted
				font.pixelSize: Theme.size.label
			}
		}
	}
}
