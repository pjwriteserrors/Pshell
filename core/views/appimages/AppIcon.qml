import QtQuick
import Quickshell
import qs.style.theme
import qs.style.widgets

// An AppImage's icon: the one it carries (read out of the image), else the
// icon theme's by its name, else a tile with its first letter. It pops in
// once it is loaded instead of appearing.
Item {
	id: root

	// a file or an icon name
	property string icon: ""
	property string name: ""
	property real size: 44
	// grey and small while it waits (a download), round while it works
	property bool dim: false

	readonly property string source: {
		const icon = String(root.icon || "");
		if (icon === "") return "";
		if (icon.startsWith("/")) return `file://${icon}`;
		if (/^https?:\/\//.test(icon)) return icon;
		return Quickshell.iconPath(icon, true);
	}
	readonly property bool loaded: picture.status === Image.Ready

	implicitWidth: root.size
	implicitHeight: root.size

	// the tile behind a letter
	Rectangle {
		anchors.fill: parent
		radius: Math.round(root.size * 0.28)
		color: Theme.primaryContainer
		opacity: root.loaded ? 0 : 1
		scale: root.loaded ? 0.8 : 1

		Behavior on opacity {
			Anim {}
		}
		Behavior on scale {
			SpatialAnim {}
		}

		StyledText {
			anchors.centerIn: parent
			visible: root.name !== ""
			text: root.name.trim().slice(0, 1).toUpperCase()
			tone: Theme.primary
			font.pixelSize: Math.round(root.size * 0.46)
			font.weight: Font.Bold
		}

		Glyph {
			anchors.centerIn: parent
			visible: root.name === ""
			icon: "package_variant"
			size: root.size * 0.5
			color: Theme.primary
		}
	}

	Image {
		id: picture

		anchors.fill: parent
		source: root.source
		sourceSize: Qt.size(root.size * 2, root.size * 2)
		fillMode: Image.PreserveAspectFit
		asynchronous: true
		smooth: true
		mipmap: true
		opacity: root.loaded ? (root.dim ? 0.55 : 1) : 0
		scale: root.loaded ? (root.dim ? 0.9 : 1) : 0.6

		Behavior on opacity {
			Anim {
				duration: Motion.long
			}
		}
		Behavior on scale {
			SpatialAnim {
				duration: Motion.extraLong
			}
		}
	}
}
