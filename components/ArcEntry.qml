pragma ComponentBehavior: Bound

import QtQuick

// A line in a list.
//
// No band, no plate, no tint behind it. Touching it lights a rune out in the
// margin and draws a ley line under the words, left to right, at the speed a
// hand moves; choosing it leaves that line lit and warms the words. Those are
// two different events and they are meant to look it — one is the pointer
// passing over, the other is a decision.
Item {
	id: entry

	property bool selected: false
	property bool interactive: true
	property real inset: Arc.s4
	property alias containsMouse: touch.containsMouse
	property alias acceptedButtons: touch.acceptedButtons
	readonly property real live: interactive ? Math.max(touch.live, selected ? 0.55 : 0) : (selected ? 0.55 : 0)
	readonly property real hovered: interactive && touch.containsMouse ? 1 : 0

	default property alias content: slot.data

	signal clicked(var event)

	implicitHeight: 34

	// The rune out in the margin: the mark that says the pointer is here.
	ArcRune {
		id: marker
		anchors.left: parent.left
		anchors.verticalCenter: parent.verticalCenter
		width: 11
		height: 15
		seed: 3
		weight: Arc.ruleThin
		lineColor: Arc.aether
		opacity: entry.hovered

		transform: Translate {
			x: (1 - entry.hovered) * -7

			Behavior on x {
				NumberAnimation {
					duration: Arc.turn
					easing.type: Easing.Bezier
					easing.bezierCurve: Arc.curveSnap
				}
			}
		}

		Behavior on opacity {
			NumberAnimation { duration: Arc.tick }
		}
	}

	// The ley: drawn under the words, and the whole of both states.
	Rectangle {
		id: ley
		anchors.left: parent.left
		anchors.leftMargin: entry.inset
		anchors.bottom: parent.bottom
		anchors.bottomMargin: 1
		height: Arc.ruleThin
		width: entry.live > 0.05 ? parent.width - entry.inset * 1.6 : 0
		color: entry.selected ? Arc.aether : Arc.goldDim

		Behavior on width {
			NumberAnimation {
				duration: Arc.draw
				easing.type: Easing.Bezier
				easing.bezierCurve: Arc.curveInk
			}
		}

		Behavior on color {
			ColorAnimation { duration: Arc.tick }
		}
	}

	ArcHalo {
		anchors.left: parent.left
		anchors.right: parent.right
		anchors.bottom: parent.bottom
		height: 26
		color: Arc.aether
		strength: 0.22
		spread: 0.5
		opacity: entry.selected ? 1 : 0
		visible: opacity > 0.01

		Behavior on opacity {
			NumberAnimation { duration: Arc.turn; easing.type: Easing.Bezier; easing.bezierCurve: Arc.curveKindle }
		}
	}

	// The row's own touch layer sits *under* its contents: a button or a
	// switch inside a row has to get the click first, and whatever it does not
	// take falls through to here. Put this last and everything inside goes
	// deaf.
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
		anchors.rightMargin: entry.inset * 0.5

		transform: Translate {
			x: entry.hovered * 5

			Behavior on x {
				NumberAnimation {
					duration: Arc.turn
					easing.type: Easing.Bezier
					easing.bezierCurve: Arc.curveSnap
				}
			}
		}
	}
}
