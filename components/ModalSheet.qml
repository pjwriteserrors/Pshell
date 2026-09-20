pragma ComponentBehavior: Bound

import QtQuick

// The wrapper every full-screen modal sits in (power, Studio, the pickers).
//
// A modal is the book. It is lowered from the chain like every other panel, but
// it arrives shut: two boards, clasped, with a rune stamped on the front. Then
// it opens — the boards turn outward about the gutter, in real perspective, and
// what was underneath them is the page.
//
// Closing puts the boards back the way they came and takes the book up. Nothing
// here fades, and nothing is centred in the air with a drop shadow under it.
//
// Place inside a full-screen PanelWindow.
Item {
	id: sheet

	required property bool open
	property real scrimOpacity: 0.62
	property real sheetWidth: 400
	property real sheetHeight: 300

	default property alias content: container.data
	readonly property Item containerItem: container

	signal dismissRequested()

	property real openProgress: open ? 1 : 0

	// Two movements, deliberately not one. The book is lowered first and only
	// then opened, so the reader sees an object arrive and then be used.
	readonly property real lower: Math.max(0, Math.min(1, openProgress / 0.46))
	readonly property real turn: Math.max(0, Math.min(1, (openProgress - 0.40) / 0.60))

	anchors.fill: parent

	// Every modal answers Escape, whatever is inside it. Unhandled keys travel
	// up from the focused item, so a search field inside still gets first
	// refusal.
	focus: true

	Keys.onEscapePressed: event => {
		event.accepted = true;
		sheet.dismissRequested();
	}

	Behavior on openProgress {
		NumberAnimation {
			duration: sheet.open ? Arc.unroll + Arc.turn : Arc.reroll + 60
			easing.type: Easing.Bezier
			easing.bezierCurve: sheet.open ? Arc.curveUnroll : Arc.curveReroll
		}
	}

	Rectangle {
		anchors.fill: parent
		color: Arc.well
		opacity: sheet.open ? sheet.scrimOpacity : 0

		Behavior on opacity {
			NumberAnimation {
				duration: sheet.open ? Arc.draw : Arc.recoil
				easing.type: Easing.Bezier
				easing.bezierCurve: Arc.curveKindle
			}
		}

		MouseArea {
			anchors.fill: parent
			onClicked: sheet.dismissRequested()
		}
	}

	// The candle the open book is read by.
	ArcHalo {
		anchors.centerIn: rig
		width: rig.width * 1.45
		height: rig.height * 1.45
		color: Arc.aether
		strength: 0.15 * sheet.openProgress
		spread: 0.46
		flicker: true
		visible: sheet.openProgress > 0.02
	}

	Item {
		id: rig

		width: Math.min(sheet.sheetWidth, sheet.width - Arc.s7 * 2)
		height: Math.min(sheet.sheetHeight, sheet.height - Arc.gantryDepth - Arc.s6 * 2)
		x: Math.round((sheet.width - width) / 2)

		readonly property real restY: Math.round(Arc.gantryDepth + Arc.s5
			+ Math.max(0, (sheet.height - Arc.gantryDepth - Arc.s5 - Arc.s6 - height) / 2))

		// It comes down off the chain rather than appearing where it ends up.
		y: Math.round(rig.restY - (1 - sheet.lower) * 96)
		opacity: Math.min(1, sheet.lower * 2.4)

		// The cords it is lowered on.
		Repeater {
			model: 2
			delegate: Rectangle {
				required property int index
				x: index === 0 ? Arc.s6 : rig.width - Arc.s6
				y: -(rig.y - Arc.gantryDepth + Arc.s3)
				width: Arc.ruleThin
				height: Math.max(0, rig.y - Arc.gantryDepth + Arc.s3)
				color: Qt.alpha(Arc.gilt, 0.45 * sheet.lower)
			}
		}

		Item {
			id: container
			anchors.fill: parent
		}

		// The boards. They exist only while the book is being opened or shut,
		// so an open modal is not paying for them.
		Repeater {
			model: 2

			delegate: Item {
				id: board

				required property int index
				readonly property bool leftBoard: index === 0

				x: leftBoard ? 0 : rig.width / 2
				width: rig.width / 2
				height: rig.height
				visible: sheet.turn < 0.995 && sheet.openProgress > 0.004
				z: 10

				transform: Matrix4x4 {
					// Real perspective, built by hand: Qt Quick's Rotation on
					// the y axis alone only foreshortens, and a board that
					// merely squashes does not read as a cover being turned.
					readonly property real angle: (board.leftBoard ? -1 : 1) * 96 * sheet.turn
					readonly property real pivotX: board.leftBoard ? board.width : 0
					readonly property real pivotY: board.height / 2

					matrix: {
						const d = 1600;
						const rad = angle * Math.PI / 180;
						const c = Math.cos(rad), s = Math.sin(rad);
						const toPivot = Qt.matrix4x4(1, 0, 0, pivotX, 0, 1, 0, pivotY, 0, 0, 1, 0, 0, 0, 0, 1);
						const persp = Qt.matrix4x4(1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, -1 / d, 1);
						const rotate = Qt.matrix4x4(c, 0, s, 0, 0, 1, 0, 0, -s, 0, c, 0, 0, 0, 0, 1);
						const fromPivot = Qt.matrix4x4(1, 0, 0, -pivotX, 0, 1, 0, -pivotY, 0, 0, 1, 0, 0, 0, 0, 1);
						return toPivot.times(persp).times(rotate).times(fromPivot);
					}
				}

				Rectangle {
					anchors.fill: parent
					color: Arc.leaf3

					Rectangle {
						anchors.fill: parent
						anchors.margins: 5
						color: "transparent"
						border.width: Arc.ruleThin
						border.color: Arc.giltDim
					}
				}

				// The stamp on the front board, and the ribs down the spine on
				// the back of it.
				ArcRune {
					anchors.centerIn: parent
					width: Math.min(parent.width, parent.height) * 0.34
					height: width
					seed: 11
					weight: Arc.ruleHeavy
					lineColor: Arc.gilt
					visible: !board.leftBoard
					opacity: 1 - sheet.turn
				}

				Column {
					anchors.right: parent.right
					anchors.verticalCenter: parent.verticalCenter
					spacing: 9
					visible: board.leftBoard
					opacity: 1 - sheet.turn

					Repeater {
						model: 4
						delegate: Rectangle {
							width: 16
							height: Arc.rule
							color: Arc.giltFaint
						}
					}
				}
			}
		}
	}
}
