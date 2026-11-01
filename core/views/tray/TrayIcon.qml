import QtQuick
import QtQuick.Effects
import qs.style.theme
import qs.style.widgets
import qs.core.services

// What an item of a tray looks like: the app's or the file's own picture,
// or – for commands, shell lines and links – its glyph on a tile of its own
// colour, shaped like an app icon so the two sit well side by side.
Item {
	id: root

	property var item: null
	property bool lifted: false
	property bool shadow: true
	readonly property string source: AppTray.iconOf(root.item)
	readonly property bool tile: root.source === "" || picture.status === Image.Error
	readonly property real hue: AppTray.hueOf(root.item)
	readonly property color tint: Qt.tint(Qt.hsla(root.hue, 0.55, Theme.dark ? 0.46 : 0.52, 1), Qt.alpha(Theme.primary, 0.28))

	Image {
		id: picture

		anchors.fill: parent
		visible: false
		source: root.source
		// one size for every scale: a growing icon must not decode again
		sourceSize: Qt.size(128, 128)
		fillMode: root.item?.kind === "file" && AppTray.isImage(root.item.path) ? Image.PreserveAspectCrop : Image.PreserveAspectFit
		smooth: true
		mipmap: true
		asynchronous: true
	}

	// a picture of a file is shown as a rounded photo
	Rectangle {
		id: photoMask

		anchors.fill: parent
		radius: width * 0.22
		visible: false
		layer.enabled: true
	}

	MultiEffect {
		anchors.fill: parent
		visible: !root.tile
		source: picture
		maskEnabled: root.item?.kind === "file" && AppTray.isImage(root.item.path)
		maskSource: photoMask
		shadowEnabled: root.shadow
		shadowColor: Theme.shadow
		shadowBlur: root.lifted ? 0.9 : 0.6
		shadowVerticalOffset: root.lifted ? root.height * 0.08 : root.height * 0.04
		shadowOpacity: root.lifted ? 0.75 : 0.5
		autoPaddingEnabled: true
		brightness: root.lifted ? 0.06 : 0
	}

	// the tile of a glyph
	Item {
		anchors.fill: parent
		visible: root.tile

		RectangularShadow {
			anchors.fill: face
			visible: root.shadow
			radius: face.radius
			offset.y: root.lifted ? root.height * 0.08 : root.height * 0.04
			blur: root.lifted ? root.height * 0.3 : root.height * 0.18
			color: Qt.alpha(Theme.shadow, root.lifted ? 0.6 : 0.4)
		}

		Rectangle {
			id: face

			anchors.fill: parent
			anchors.margins: parent.width * 0.06
			radius: width * 0.27
			gradient: Gradient {
				GradientStop {
					position: 0
					color: Qt.lighter(root.tint, root.lifted ? 1.35 : 1.22)
				}
				GradientStop {
					position: 1
					color: Qt.darker(root.tint, 1.25)
				}
			}

			// a sheen on the upper half
			Rectangle {
				anchors.left: parent.left
				anchors.right: parent.right
				anchors.top: parent.top
				anchors.margins: 1
				height: parent.height * 0.48
				radius: parent.radius - 1
				gradient: Gradient {
					GradientStop {
						position: 0
						color: Qt.rgba(1, 1, 1, 0.22)
					}
					GradientStop {
						position: 1
						color: Qt.rgba(1, 1, 1, 0)
					}
				}
			}

			Rectangle {
				anchors.fill: parent
				radius: parent.radius
				color: "transparent"
				border.width: 1
				border.color: Qt.rgba(1, 1, 1, 0.14)
			}

			Glyph {
				anchors.centerIn: parent
				icon: AppTray.glyphOf(root.item)
				size: parent.width * 0.52
				color: "#ffffff"
				surface: "transparent"
				animated: false
			}

			// a link shows where it goes
			StyledText {
				visible: root.item?.kind === "link" && parent.width > 36
				anchors.horizontalCenter: parent.horizontalCenter
				anchors.bottom: parent.bottom
				anchors.bottomMargin: parent.height * 0.06
				width: parent.width - 6
				horizontalAlignment: Text.AlignHCenter
				text: AppTray.hostOf(root.item?.url ?? "").split(".")[0]
				tone: Qt.rgba(1, 1, 1, 0.85)
				surface: "transparent"
				font.pixelSize: Math.max(7, parent.height * 0.15)
				font.weight: Font.DemiBold
			}
		}
	}

	// a shell line that runs in a terminal, a folder: a small mark in the corner
	Rectangle {
		visible: root.item?.kind === "shell" && root.item?.terminal === true
		anchors.right: parent.right
		anchors.bottom: parent.bottom
		width: parent.width * 0.34
		height: width
		radius: width / 2
		color: Theme.layer3
		border.width: 1
		border.color: Theme.outline

		Glyph {
			anchors.centerIn: parent
			icon: "console_line"
			size: parent.width * 0.62
			color: Theme.text
			animated: false
		}
	}
}
