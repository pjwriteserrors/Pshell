import QtQuick
import QtQuick.Effects
import qs.style.theme
import qs.style.widgets
import qs.core.services

// What every card shares: a 16:9 picture that lifts toward the pointer with a
// glow of its own colour, words under it. `overlay` lies on the picture.
Item {
	id: root

	property string source: ""
	property string large: ""
	property var colors: null
	property bool spoiler: false
	property bool dimmed: false
	property color accent: Theme.primary
	default property alias underneath: words.data
	property alias overlay: overlayHolder.data
	readonly property alias picture: frame
	readonly property bool hovered: hover.hovered
	readonly property bool lifted: hover.hovered
	readonly property real pictureHeight: Math.round(root.width * 9 / 16)

	signal clicked
	signal rightClicked

	HoverHandler {
		id: hover
	}

	Item {
		id: frame

		width: parent.width
		height: root.pictureHeight
		scale: area.pressed ? 1.02 : (hover.hovered ? 1.05 : 1)
		transformOrigin: Item.Center

		Behavior on scale {
			SpatialAnim {
				duration: Motion.long
			}
		}

		// the glow, only while it matters
		Rectangle {
			anchors.fill: parent
			radius: Theme.radius.large
			color: root.accent
			opacity: hover.hovered ? 0.55 : 0
			visible: opacity > 0.01
			layer.enabled: visible
			layer.effect: MultiEffect {
				blurEnabled: true
				blur: 1
				blurMax: 32
				autoPaddingEnabled: true
			}

			Behavior on opacity {
				Anim {
					duration: Motion.long
				}
			}
		}

		Thumb {
			anchors.fill: parent
			radius: Theme.radius.large
			source: root.source
			large: ""
			colors: root.colors
			spoiler: root.spoiler
			revealed: hover.hovered
			dimmed: root.dimmed
			zoom: hover.hovered ? 1.05 : 1
		}

		// a thin edge of light, so dark pictures keep their shape
		Rectangle {
			anchors.fill: parent
			radius: Theme.radius.large
			color: "transparent"
			border.width: 1
			border.color: Qt.rgba(1, 1, 1, hover.hovered ? 0.28 : 0.07)

			Behavior on border.color {
				ColorAnim {}
			}
		}

		MouseArea {
			id: area

			anchors.fill: parent
			acceptedButtons: Qt.LeftButton | Qt.RightButton
			cursorShape: Qt.PointingHandCursor
			onClicked: mouse => mouse.button === Qt.RightButton ? root.rightClicked() : root.clicked()
		}

		Item {
			id: overlayHolder

			anchors.fill: parent
		}
	}

	Item {
		id: words

		anchors.left: parent.left
		anchors.right: parent.right
		anchors.top: frame.bottom
		anchors.bottom: parent.bottom
		anchors.topMargin: 9
	}
}
