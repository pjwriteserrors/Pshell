import QtQuick

// What a clickable surface does with a pointer on it.
//
// Same API as before — drop it in, use onClicked — so every call site that
// already had one answers correctly without knowing any of this. What it does
// is this style's, not the old one's: the field warms with the aether colour
// and a registration tick is cut into its top-left corner, sliding in from
// outside the field the way a mark is made against a rule.
MouseArea {
	id: layer

	property color tint: Arc.aether
	property real cornerRadius: parent?.radius ?? 0
	property bool showHover: true
	property bool rippleEnabled: false      // kept for source compatibility
	property bool veined: true

	readonly property real live: !showHover ? 0 : pressed ? 1 : containsMouse ? 0.6 : 0

	anchors.fill: parent
	hoverEnabled: true
	cursorShape: Qt.PointingHandCursor

	Rectangle {
		anchors.fill: parent
		radius: layer.cornerRadius
		color: Qt.alpha(Arc.aether, 0.12 * layer.live)

		Behavior on color {
			ColorAnimation { duration: Arc.tick }
		}
	}

	// The mark. Two short cuts meeting at the corner, arriving from off the
	// field rather than fading up where they land.
	Item {
		visible: layer.veined
		anchors.left: parent.left
		anchors.top: parent.top
		width: 12
		height: 12
		opacity: layer.live

		transform: Translate {
			x: (1 - layer.live) * -5
			y: (1 - layer.live) * -5

			Behavior on x {
				NumberAnimation {
					duration: Arc.turn
					easing.type: Easing.Bezier
					easing.bezierCurve: Arc.curveDetent
				}
			}
			Behavior on y {
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
			width: parent.width
			height: Arc.rule
			color: Arc.aether
		}

		Rectangle {
			width: Arc.rule
			height: parent.height
			color: Arc.aether
		}
	}
}
