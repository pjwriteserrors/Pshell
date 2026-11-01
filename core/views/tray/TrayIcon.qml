import QtQuick
import QtQuick.Effects
import Qt.labs.folderlistmodel
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
	readonly property string kind: String(root.item?.kind ?? "")
	// a group shows its first items, a stacked folder its newest files
	readonly property bool grouped: root.kind === "group"
	readonly property bool stacked: root.kind === "file" && !!root.item?.folder && !!root.item?.stack
	// a picture that is cut to a rounded square (photos, covers)
	readonly property bool photo: (root.kind === "file" && AppTray.isImage(root.item?.path)) || root.kind === "game"
	readonly property string source: root.grouped || root.stacked ? "" : AppTray.iconOf(root.item)
	readonly property bool tile: !root.grouped && !root.stacked && (root.source === "" || picture.status === Image.Error)
	readonly property real hue: AppTray.hueOf(root.item)
	readonly property color tint: Qt.tint(Qt.hsla(root.hue, 0.55, Theme.dark ? 0.46 : 0.52, 1), Qt.alpha(Theme.primary, 0.28))

	Image {
		id: picture

		anchors.fill: parent
		visible: false
		source: root.source
		// one size for every scale: a growing icon must not decode again
		sourceSize: Qt.size(128, 128)
		fillMode: root.photo ? Image.PreserveAspectCrop : Image.PreserveAspectFit
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
		visible: !root.tile && !root.grouped && !root.stacked
		source: picture
		maskEnabled: root.photo
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

	// a group: its first four items on a tile
	Rectangle {
		visible: root.grouped
		anchors.fill: parent
		anchors.margins: parent.width * 0.04
		radius: width * 0.27
		color: Qt.alpha(Theme.text, root.lifted ? 0.16 : 0.1)
		border.width: 1
		border.color: Theme.outline

		Grid {
			anchors.centerIn: parent
			columns: 2
			spacing: parent.width * 0.06

			Repeater {
				model: root.grouped ? (root.item.items ?? []).slice(0, 4) : []

				delegate: Loader {
					required property var modelData

					width: root.width * 0.36
					height: width
					// one level only: a group in a group is drawn as its tile
					source: "TrayIcon.qml"
					onLoaded: {
						item.item = modelData;
						item.shadow = false;
					}
				}
			}
		}
	}

	// a folder as a stack: its three newest files, fanned
	FolderListModel {
		id: newest

		folder: root.stacked ? `file://${root.item.path}` : ""
		showDirs: true
		showDotAndDotDot: false
		showHidden: false
		sortField: FolderListModel.Time
	}

	Item {
		visible: root.stacked
		anchors.fill: parent

		Repeater {
			model: root.stacked ? Math.min(3, newest.count) : 0

			delegate: Rectangle {
				id: sheet

				required property int index
				readonly property string path: String(newest.get(sheet.index, "filePath") ?? "")
				readonly property bool image: AppTray.isImage(sheet.path)

				z: 3 - sheet.index
				width: root.width * 0.74
				height: width
				anchors.centerIn: parent
				anchors.verticalCenterOffset: -sheet.index * root.height * 0.05
				rotation: (sheet.index - 1) * (root.lifted ? 12 : 7)
				radius: width * 0.18
				color: Theme.layer2
				border.width: 1
				border.color: Theme.outline

				Behavior on rotation {
					SpatialAnim {
						duration: Motion.medium
					}
				}

				Image {
					anchors.fill: parent
					anchors.margins: sheet.image ? 2 : parent.width * 0.15
					source: sheet.image ? `file://${sheet.path}` : AppIcons.app(AppTray.themeIconOf({ path: sheet.path, folder: newest.get(sheet.index, "fileIsDir") }), ["text-x-generic"])
					sourceSize: Qt.size(96, 96)
					fillMode: sheet.image ? Image.PreserveAspectCrop : Image.PreserveAspectFit
					asynchronous: true
				}
			}
		}

		// an empty folder is a folder
		Image {
			visible: newest.count === 0
			anchors.fill: parent
			source: AppIcons.app("folder", ["inode-directory"])
			sourceSize: Qt.size(128, 128)
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
