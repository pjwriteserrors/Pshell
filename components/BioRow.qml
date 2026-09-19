pragma ComponentBehavior: Bound

import QtQuick

// A row in a list. Hovering does not paint a grey band behind it — a vein
// lights up along its left edge, the tissue under it warms, and the row leans
// away from the vein as if the stroke were pushing it. Everything in this shell
// now reads left to right out of the spine, and a row answers the same way.
Item {
	id: row

	property bool selected: false
	property bool interactive: true
	property real inset: Bio.s3
	property alias containsMouse: touch.containsMouse
	property alias acceptedButtons: touch.acceptedButtons
	readonly property real live: interactive ? Math.max(touch.live, selected ? 0.55 : 0) : (selected ? 0.55 : 0)

	default property alias content: slot.data

	signal clicked(var event)

	implicitHeight: 34

	Rectangle {
		anchors.fill: parent
		anchors.leftMargin: Bio.s2
		color: Qt.alpha(Bio.organ, 0.10 * row.live)
		radius: 2
	}

	// The vein: the whole hover state, in one stroke.
	Rectangle {
		anchors.left: parent.left
		anchors.verticalCenter: parent.verticalCenter
		width: Bio.rib * 1.6
		height: parent.height * (0.32 + 0.6 * row.live)
		radius: width / 2
		color: Bio.organ
		opacity: row.live

		Behavior on opacity {
			NumberAnimation { duration: Bio.twitch }
		}
		Behavior on height {
			NumberAnimation { duration: Bio.grow; easing.type: Easing.OutCubic }
		}
	}

	// The row's own touch layer sits *under* its contents, not over them: a
	// button, a toggle or a menu entry placed in a row has to get the click
	// first, and whatever it does not take falls through to the row. Put this
	// last and everything inside the row goes deaf.
	BioTouch {
		id: touch
		enabled: row.interactive
		visible: row.interactive
		onClicked: event => row.clicked(event)
	}

	Item {
		id: slot
		anchors.fill: parent
		anchors.leftMargin: row.inset
		anchors.rightMargin: row.inset * 0.6

		transform: Translate {
			x: row.live * 5

			Behavior on x {
				NumberAnimation { duration: Bio.grow; easing.type: Easing.OutCubic }
			}
		}
	}
}
