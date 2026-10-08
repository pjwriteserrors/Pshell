import QtQuick
import Quickshell.Widgets
import qs.style.theme
import qs.style.widgets

// The face of an identity: its picture once it is loaded, its initials until
// then and without a network.
Item {
	id: root

	property string source: ""
	property string name: ""
	property bool pending: false

	readonly property string initials: root.name.split(/\s+/).filter(part => part !== "").slice(0, 2).map(part => part[0].toUpperCase()).join("")
	readonly property bool loaded: picture.status === Image.Ready

	implicitWidth: 56
	implicitHeight: 56

	ClippingRectangle {
		anchors.fill: parent
		radius: width / 2
		color: Theme.primaryContainer
		scale: root.pending && !root.loaded ? 0.9 : 1

		Behavior on scale {
			SpatialAnim {}
		}

		StyledText {
			anchors.centerIn: parent
			text: root.initials
			tone: Theme.primary
			font.pixelSize: Math.round(root.height * 0.36)
			font.weight: Font.Bold
			opacity: root.loaded ? 0 : 1

			Behavior on opacity {
				Anim {}
			}
		}

		Image {
			id: picture

			anchors.fill: parent
			source: root.source
			sourceSize: Qt.size(128, 128)
			fillMode: Image.PreserveAspectCrop
			asynchronous: true
			smooth: true
			mipmap: true
			opacity: root.loaded ? 1 : 0
			scale: root.loaded ? 1 : 1.25

			Behavior on opacity {
				Anim {}
			}
			Behavior on scale {
				SpatialAnim {}
			}
		}
	}

	Spinner {
		anchors.fill: parent
		anchors.margins: -4
		thickness: 2
		visible: opacity > 0.01
		running: root.pending
		opacity: root.pending ? 1 : 0

		Behavior on opacity {
			Anim {}
		}
	}
}
