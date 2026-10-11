import QtQuick
import qs.style.theme
import qs.style.widgets
import qs.core.services

// What dialogs of the file manager stand on: the files dim behind, the card
// blooms up in the middle, Escape or a click beside it closes it.
Item {
	id: root

	property bool shown: false
	property real cardWidth: 440
	property bool dismissable: true
	default property alias content: body.data
	readonly property alias card: card
	signal closed
	signal dismissed

	function show() {
		root.shown = true;
		Sounds.play("open");
	}

	function hide() {
		root.shown = false;
	}

	// however it went away (also a dialog bound to something that ended)
	onShownChanged: if (!root.shown) root.closed()

	visible: scrim.opacity > 0.01

	Rectangle {
		id: scrim

		anchors.fill: parent
		color: Theme.scrim
		opacity: root.shown ? 1 : 0

		Behavior on opacity {
			Anim {
				duration: Motion.medium
			}
		}

		MouseArea {
			anchors.fill: parent
			acceptedButtons: Qt.AllButtons
			// the files behind do not light up under it
			hoverEnabled: true
			onPressed: if (root.dismissable) root.dismissed()
			onWheel: wheel => wheel.accepted = true
		}
	}

	Rectangle {
		id: card

		anchors.centerIn: parent
		width: Math.min(root.cardWidth, root.width - 40)
		height: body.childrenRect.height + 44
		radius: Theme.radius.huge
		color: Theme.layer1
		border.width: 1
		border.color: Theme.outline
		scale: root.shown ? 1 : 0.9
		opacity: root.shown ? 1 : 0

		Behavior on scale {
			SpatialAnim {
				duration: root.shown ? Motion.long : Motion.short
			}
		}
		Behavior on opacity {
			Anim {
				duration: root.shown ? Motion.medium : Motion.short
			}
		}

		// the card's shadow
		Rectangle {
			z: -1
			anchors.fill: parent
			anchors.topMargin: 10
			anchors.bottomMargin: -18
			anchors.leftMargin: 6
			anchors.rightMargin: 6
			radius: parent.radius
			color: Theme.shadow
			opacity: 0.5
		}

		MouseArea {
			anchors.fill: parent
			acceptedButtons: Qt.AllButtons
		}

		Item {
			id: body

			x: 22
			y: 22
			width: card.width - 44
			height: childrenRect.height
		}
	}
}
