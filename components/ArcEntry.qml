pragma ComponentBehavior: Bound

import QtQuick

// An entry in an index.
//
// Two different events, deliberately not the same event at two strengths.
// Hovering writes a mark in the margin — a lozenge and a tick slide in from
// outside the page and the entry gives way to them. Selecting rules the entry
// underneath: an ink line drawn left to right at the speed a nib travels,
// which is a thing that stays on the page rather than a thing that follows the
// pointer.
Item {
	id: entry

	property bool selected: false
	property bool interactive: true
	property real inset: Arc.s3
	property alias containsMouse: touch.containsMouse
	property alias acceptedButtons: touch.acceptedButtons
	readonly property real live: interactive ? Math.max(touch.live, selected ? 0.55 : 0) : (selected ? 0.55 : 0)
	readonly property real hovered: interactive && touch.containsMouse ? 1 : 0

	default property alias content: slot.data

	signal clicked(var event)

	implicitHeight: 34

	// The page warms under the entry. Never a grey band.
	Rectangle {
		anchors.fill: parent
		anchors.leftMargin: Arc.s2
		color: Qt.alpha(Arc.aether, 0.09 * entry.live)
	}

	// The marginal mark, written outside the text block and sliding in.
	Item {
		id: margin
		anchors.left: parent.left
		anchors.verticalCenter: parent.verticalCenter
		width: Arc.s3
		height: parent.height
		opacity: entry.hovered

		transform: Translate {
			x: (1 - entry.hovered) * -9

			Behavior on x {
				NumberAnimation {
					duration: Arc.turn
					easing.type: Easing.Bezier
					easing.bezierCurve: Arc.curveDetent
				}
			}
		}

		Behavior on opacity {
			NumberAnimation { duration: Arc.tick }
		}

		Rectangle {
			anchors.centerIn: parent
			width: 5
			height: 5
			rotation: 45
			color: Arc.aether
		}

		Rectangle {
			anchors.verticalCenter: parent.verticalCenter
			anchors.left: parent.left
			anchors.leftMargin: 1
			width: 3
			height: Arc.ruleThin
			color: Qt.alpha(Arc.aether, 0.7)
		}
	}

	// The rule: drawn, not faded. It is the whole selected state.
	Rectangle {
		id: ruled
		anchors.left: parent.left
		anchors.leftMargin: Arc.s2
		anchors.bottom: parent.bottom
		height: Arc.ruleThin
		width: entry.selected ? parent.width - Arc.s2 * 2 : 0
		color: Arc.aether

		Behavior on width {
			NumberAnimation {
				duration: Arc.draw
				easing.type: Easing.Bezier
				easing.bezierCurve: Arc.curveInk
			}
		}
	}

	// The entry's own touch layer sits *under* its contents: a button, a lever
	// or a menu item inside an entry has to get the click first, and whatever
	// it does not take falls through to here. Put this last and everything
	// inside the entry goes deaf.
	ArcTouch {
		id: touch
		enabled: entry.interactive
		visible: entry.interactive
		onClicked: event => entry.clicked(event)
	}

	Item {
		id: slot
		anchors.fill: parent
		anchors.leftMargin: entry.inset
		anchors.rightMargin: entry.inset * 0.6

		transform: Translate {
			x: entry.hovered * 6

			Behavior on x {
				NumberAnimation {
					duration: Arc.turn
					easing.type: Easing.Bezier
					easing.bezierCurve: Arc.curveDetent
				}
			}
		}
	}
}
