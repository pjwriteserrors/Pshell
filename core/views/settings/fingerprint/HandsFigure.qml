pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.style.widgets

// Two hands, seen from the back, and the sensor between them: a fingertip
// carries a print once that finger is enrolled; the one picked is ringed,
// fills up while it is enrolled and flashes when a test answers. The sensor
// lights while a finger lies on it and breathes while it waits for one.
Item {
	id: root

	property var enrolled: []
	property string selected: ""
	property string active: ""      // the finger being enrolled or tested
	property real progress: -1      // 0…1 while enrolling, else −1
	property bool fingerPresent: false
	property bool fingerNeeded: false
	property bool online: true
	signal picked(string finger)

	// a flash on a fingertip: good or bad
	function flash(finger, ok) {
		flashFinger = finger;
		flashGood = ok;
		flashAnim.restart();
	}
	property string flashFinger: ""
	property bool flashGood: true
	property real flashLevel: 0

	SequentialAnimation {
		id: flashAnim

		NumberAnimation {
			target: root
			property: "flashLevel"
			from: 0
			to: 1
			duration: Motion.short
		}
		PauseAnimation {
			duration: 600
		}
		NumberAnimation {
			target: root
			property: "flashLevel"
			to: 0
			duration: Motion.long
		}
	}

	implicitHeight: 240
	opacity: root.online ? 1 : 0.45

	// a right hand's fingers: name, x from the palm's middle, length, angle; the left is its mirror
	readonly property var shape: [
		{ part: "thumb", x: -50, y: 46, len: 56, angle: -50 },
		{ part: "index-finger", x: -35, y: 6, len: 74, angle: -7 },
		{ part: "middle-finger", x: -11, y: 2, len: 84, angle: -1 },
		{ part: "ring-finger", x: 13, y: 4, len: 78, angle: 5 },
		{ part: "little-finger", x: 36, y: 12, len: 60, angle: 13 }
	]
	readonly property real unit: Math.min(1.4, Math.max(0.6, Math.min(width / 560, height / 215)))
	// where the palms start: the drawing (fingers ≈ 92, palm 100) in the middle
	readonly property real palmTop: (height - 192 * unit) / 2 + 92 * unit

	Repeater {
		model: ["left", "right"]

		Item {
			id: hand

			required property string modelData
			readonly property real side: hand.modelData === "left" ? -1 : 1

			width: 1
			height: 1
			x: root.width / 2 + hand.side * 140 * root.unit
			y: root.palmTop

			// the palm
			Rectangle {
				x: -52 * root.unit
				y: 0
				width: 104 * root.unit
				height: 100 * root.unit
				radius: 34 * root.unit
				color: Theme.layer2
				border.width: 1
				border.color: Theme.layer3
			}

			Repeater {
				model: root.shape

				Item {
					id: digit

					required property var modelData
					readonly property string finger: `${hand.modelData}-${digit.modelData.part}`
					readonly property bool has: root.enrolled.includes(digit.finger)
					readonly property bool picked: root.selected === digit.finger
					readonly property bool busy: root.active === digit.finger || (root.active === "any" && digit.has)
					readonly property real w: (digit.modelData.part === "thumb" ? 26 : 22) * root.unit
					readonly property real len: digit.modelData.len * root.unit

					x: hand.side * digit.modelData.x * root.unit - digit.w / 2
					y: digit.modelData.y * root.unit - digit.len + digit.w / 2
					width: digit.w
					height: digit.len
					rotation: hand.side * digit.modelData.angle
					transformOrigin: Item.Bottom

					Rectangle {
						anchors.fill: parent
						radius: width / 2
						color: Theme.layer2
						border.width: 1
						border.color: Theme.layer3
					}

					Clickable {
						id: tip

						readonly property real flash: root.flashFinger === digit.finger || (root.flashFinger === "any" && digit.has) ? root.flashLevel : 0

						x: (digit.w - width) / 2
						y: -2 * root.unit
						width: digit.w + 8 * root.unit
						height: width
						radius: width / 2
						pressedScale: 0.9
						color: tip.flash > 0 ? Qt.tint(digit.has ? Theme.primary : Theme.layer3, Qt.alpha(root.flashGood ? Theme.success : Theme.danger, tip.flash))
							: (digit.has ? Theme.primary : (tip.hovered ? Theme.layer3 : Theme.layer1))
						border.width: digit.picked ? 2.5 : 1
						border.color: digit.picked ? Theme.text : Theme.layer3
						rotation: -digit.rotation
						onClicked: root.picked(digit.finger)

						Behavior on color {
							ColorAnim {}
						}

						Glyph {
							anchors.centerIn: parent
							icon: "fingerprint"
							size: parent.width * 0.62
							color: digit.has ? Theme.onPrimary : Theme.textMuted
							opacity: digit.has || tip.hovered || digit.picked ? 1 : 0.35
						}

						Ring {
							anchors.centerIn: parent
							visible: digit.busy && root.progress >= 0
							width: parent.width + 10 * root.unit
							height: width
							thickness: 3
							value: root.progress
							trackColor: "transparent"
						}

						Rectangle {
							anchors.centerIn: parent
							visible: digit.busy && root.progress < 0
							width: parent.width + 10 * root.unit
							height: width
							radius: width / 2
							color: "transparent"
							border.width: 2
							border.color: Theme.primary
							SequentialAnimation on opacity {
								running: digit.busy && root.progress < 0
								loops: Animation.Infinite
								NumberAnimation { to: 0.2; duration: 700 }
								NumberAnimation { to: 1; duration: 700 }
							}
						}
					}
				}
			}
		}
	}

	// the sensor
	Rectangle {
		id: sensor

		anchors.horizontalCenter: parent.horizontalCenter
		y: root.palmTop + 18 * root.unit
		width: 46 * root.unit
		height: width
		radius: 12 * root.unit
		color: root.fingerPresent ? Theme.primaryContainer : Theme.layer1
		border.width: root.fingerPresent || root.fingerNeeded ? 2 : 1
		border.color: root.fingerPresent || root.fingerNeeded ? Theme.primary : Theme.layer3

		Behavior on color {
			ColorAnim {}
		}

		Glyph {
			id: sensorGlyph

			anchors.centerIn: parent
			icon: root.online ? "fingerprint" : "fingerprint_off"
			size: parent.width * 0.6
			color: root.fingerPresent || root.fingerNeeded ? Theme.primary : Theme.textMuted
			SequentialAnimation on opacity {
				running: root.fingerNeeded && !root.fingerPresent
				loops: Animation.Infinite
				onRunningChanged: if (!running) sensorGlyph.opacity = 1
				NumberAnimation { to: 0.3; duration: 800; easing.type: Easing.InOutSine }
				NumberAnimation { to: 1; duration: 800; easing.type: Easing.InOutSine }
			}
		}
	}
}
