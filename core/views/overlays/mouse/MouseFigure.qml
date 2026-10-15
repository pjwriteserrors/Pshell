pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Shapes
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "Controls.js" as Controls

// The mouse from above, drawn: every control a spot to click, and alive –
// a button pressed on the real mouse lights up here, the wheels turn with
// the real ones, a gesture shows where it is going.
Item {
	id: root

	property string selected: ""
	property var pressed: ({})
	property bool live: true
	property bool ratchet: true
	property real battery: -1
	property bool charging: false
	// the swipe in progress: its control and how far (in swipe distances)
	property string moving: ""
	property real moveX: 0
	property real moveY: 0

	signal picked(string control)

	readonly property real drawScale: Math.min(width / 300, height / 420)

	function turnWheel(delta) {
		wheel.offset = (wheel.offset + delta * 4 + 1000) % 10;
		wheel.kick();
	}

	function turnThumb(delta) {
		thumb.offset = (thumb.offset + delta * 0.5 + 1000) % 8;
	}

	implicitWidth: 300
	implicitHeight: 420

	Item {
		id: canvas

		width: 300
		height: 420
		anchors.centerIn: parent
		scale: root.drawScale

		// a soft shadow under the body
		Rectangle {
			x: 40
			y: 380
			width: 220
			height: 44
			radius: 22
			color: Theme.shadow
			opacity: 0.5
			scale: 1
		}

		Shape {
			id: body

			anchors.fill: parent
			preferredRendererType: Shape.CurveRenderer

			ShapePath {
				strokeWidth: 1.5
				strokeColor: Qt.alpha(Theme.text, 0.14)
				fillGradient: LinearGradient {
					x1: 150
					y1: 0
					x2: 150
					y2: 420

					GradientStop {
						position: 0
						color: Qt.tint(Theme.layer3, Qt.alpha(Theme.text, 0.04))
					}
					GradientStop {
						position: 1
						color: Theme.layer2
					}
				}

				PathSvg {
					path: "M 168 18 C 215 16 252 40 262 92 C 272 150 276 230 268 300 C 262 360 228 404 172 410 C 120 414 78 398 62 368 C 44 360 22 340 18 300 C 14 262 22 228 44 212 C 64 198 80 190 86 170 C 90 120 96 70 112 40 C 126 24 146 19 168 18 Z"
				}
			}

			// the thumb rest, a little apart from the body
			ShapePath {
				strokeWidth: 0
				strokeColor: "transparent"
				fillColor: Qt.alpha(Theme.text, root.selected === "haptic" ? 0.0 : 0.035)

				PathSvg {
					path: "M 62 368 C 44 360 22 340 18 300 C 14 262 22 228 44 212 C 58 230 66 270 70 310 C 72 335 70 352 62 368 Z"
				}
			}

			// the buttons' seams
			ShapePath {
				strokeWidth: 1.4
				strokeColor: Qt.alpha(Theme.text, 0.12)
				fillColor: "transparent"
				capStyle: ShapePath.RoundCap

				PathSvg {
					path: "M 166 20 L 165 52 M 165 132 L 165 172 M 88 170 C 140 186 204 186 266 162"
				}
			}
		}

		// left and right button glow when pressed or picked
		Shape {
			anchors.fill: parent
			preferredRendererType: Shape.CurveRenderer
			opacity: root.pressed.left ? 1 : (root.selected === "left" ? 0.55 : 0)

			Behavior on opacity {
				Anim {
					duration: Motion.short
				}
			}

			ShapePath {
				strokeWidth: 0
				strokeColor: "transparent"
				fillColor: Qt.alpha(Theme.primary, 0.22)

				PathSvg {
					path: "M 165 20 C 146 20 126 24 112 40 C 96 70 90 120 88 170 C 120 180 140 183 165 184 Z"
				}
			}
		}

		Shape {
			anchors.fill: parent
			preferredRendererType: Shape.CurveRenderer
			opacity: root.pressed.right ? 1 : (root.selected === "right" ? 0.55 : 0)

			Behavior on opacity {
				Anim {
					duration: Motion.short
				}
			}

			ShapePath {
				strokeWidth: 0
				strokeColor: "transparent"
				fillColor: Qt.alpha(Theme.primary, 0.22)

				PathSvg {
					path: "M 167 20 C 215 18 252 40 262 92 C 266 118 267 140 266 162 C 230 176 200 183 167 184 Z"
				}
			}
		}

		// the haptic panel ripples when it is pressed
		Item {
			id: ripple

			x: 40
			y: 330
			width: 1
			height: 1

			Repeater {
				model: 3

				delegate: Rectangle {
					id: wave

					required property int index

					anchors.centerIn: parent
					width: 26
					height: 26
					radius: 13
					color: "transparent"
					border.width: 2
					border.color: Theme.primary
					opacity: 0
					scale: 1

					SequentialAnimation {
						running: !!root.pressed.haptic
						loops: Animation.Infinite

						PauseAnimation {
							duration: wave.index * 220
						}
						ParallelAnimation {
							NumberAnimation {
								target: wave
								property: "scale"
								from: 0.6
								to: 2.6
								duration: 900
								easing.type: Easing.OutCubic
							}
							NumberAnimation {
								target: wave
								property: "opacity"
								from: 0.7
								to: 0
								duration: 900
								easing.type: Easing.OutCubic
							}
						}
					}
				}
			}
		}

		// ── the wheel ──────────────────────────────────────────────────────
		Rectangle {
			id: wheel

			property real offset: 0
			property real bump: 0

			function kick() {
				kickAnim.restart();
			}

			x: 154
			y: 54
			width: 23
			height: 76
			radius: 11
			color: root.selected === "middle" || root.pressed.middle ? Theme.primary : Theme.layer3
			border.width: 1
			border.color: Qt.alpha(Theme.text, 0.18)
			clip: true
			scale: 1 + wheel.bump * 0.06

			Behavior on color {
				ColorAnim {}
			}

			SequentialAnimation {
				id: kickAnim

				NumberAnimation {
					target: wheel
					property: "bump"
					to: 1
					duration: Motion.micro
				}
				NumberAnimation {
					target: wheel
					property: "bump"
					to: 0
					duration: Motion.medium
					easing.type: Easing.OutCubic
				}
			}

			Column {
				y: -10 + wheel.offset
				x: 4
				spacing: 6

				Behavior on y {
					enabled: root.ratchet
					SpatialAnim {
						duration: Motion.short
					}
				}

				Repeater {
					model: 18

					delegate: Rectangle {
						width: 15
						height: 1.5
						radius: 1
						color: Qt.alpha(root.selected === "middle" || root.pressed.middle ? Theme.onPrimary : Theme.text, 0.32)
					}
				}
			}

			// free spin: the ridges blur into a gleam
			Rectangle {
				anchors.fill: parent
				radius: parent.radius
				opacity: root.ratchet ? 0 : 0.5
				gradient: Gradient {
					GradientStop {
						position: 0
						color: "transparent"
					}
					GradientStop {
						position: 0.5
						color: Qt.alpha(Theme.text, 0.35)
					}
					GradientStop {
						position: 1
						color: "transparent"
					}
				}

				Behavior on opacity {
					Anim {
						duration: Motion.medium
					}
				}
			}
		}

		// the SmartShift button
		Rectangle {
			x: 157
			y: 136
			width: 17
			height: 14
			radius: 5
			color: root.selected === "shift" || root.pressed.shift ? Theme.primary : Theme.layer3
			border.width: 1
			border.color: Qt.alpha(Theme.text, 0.18)

			Behavior on color {
				ColorAnim {}
			}
		}

		// ── the thumb side ─────────────────────────────────────────────────
		Rectangle {
			id: thumb

			property real offset: 0

			x: 44
			y: 186
			width: 40
			height: 17
			radius: 8
			rotation: -28
			color: root.selected === "thumb" ? Theme.primary : Theme.layer3
			border.width: 1
			border.color: Qt.alpha(Theme.text, 0.18)
			clip: true

			Behavior on color {
				ColorAnim {}
			}

			Row {
				x: -8 + thumb.offset
				y: 3
				spacing: 6

				Behavior on x {
					SpatialAnim {
						duration: Motion.short
					}
				}

				Repeater {
					model: 9

					delegate: Rectangle {
						width: 1.5
						height: 11
						radius: 1
						color: Qt.alpha(root.selected === "thumb" ? Theme.onPrimary : Theme.text, 0.32)
					}
				}
			}
		}

		Repeater {
			model: [{ id: "forward", x: 36, y: 222 }, { id: "back", x: 31, y: 251 }]

			delegate: Rectangle {
				id: side

				required property var modelData

				x: side.modelData.x
				y: side.modelData.y
				width: 34
				height: 14
				radius: 7
				rotation: -14
				color: root.selected === side.modelData.id || root.pressed[side.modelData.id] ? Theme.primary : Theme.layer3
				border.width: 1
				border.color: Qt.alpha(Theme.text, 0.18)

				Behavior on color {
					ColorAnim {}
				}
			}
		}

		// the gesture button: a dimple under the thumb
		Rectangle {
			x: 24
			y: 289
			width: 24
			height: 22
			radius: 11
			color: root.selected === "gesture" || root.pressed.gesture ? Theme.primary : Theme.layer3
			border.width: 1
			border.color: Qt.alpha(Theme.text, 0.18)

			Behavior on color {
				ColorAnim {}
			}
		}

		// ── spots: what can be clicked ─────────────────────────────────────
		Repeater {
			model: Controls.controls

			delegate: Item {
				id: spot

				required property var modelData
				readonly property bool picked: root.selected === spot.modelData.id
				readonly property bool down: !!root.pressed[spot.modelData.id]
				readonly property bool small: spot.modelData.id !== "left" && spot.modelData.id !== "right"

				x: spot.modelData.spot[0] * 300 - width / 2
				y: spot.modelData.spot[1] * 420 - height / 2
				width: spot.small ? 30 : 80
				height: spot.small ? 30 : 90
				z: spot.picked ? 3 : 2

				Rectangle {
					anchors.centerIn: parent
					width: 30
					height: 30
					radius: 15
					visible: spot.small
					color: "transparent"
					border.width: 2
					border.color: Theme.primary
					opacity: spot.picked ? 1 : (hover.hovered ? 0.6 : 0)
					scale: spot.down ? 1.35 : (spot.picked ? 1.12 : (hover.hovered ? 1 : 0.7))

					Behavior on opacity {
						Anim {
							duration: Motion.short
						}
					}
					Behavior on scale {
						SpatialAnim {
							duration: Motion.medium
						}
					}

					// a breath around the picked one
					Rectangle {
						anchors.centerIn: parent
						width: parent.width
						height: width
						radius: width / 2
						color: "transparent"
						border.width: 2
						border.color: Theme.primary
						visible: spot.picked
						opacity: 0

						SequentialAnimation on scale {
							running: spot.picked && root.visible
							loops: Animation.Infinite

							NumberAnimation {
								from: 1
								to: 1.8
								duration: 1400
								easing.type: Easing.OutCubic
							}
						}
						SequentialAnimation on opacity {
							running: spot.picked && root.visible
							loops: Animation.Infinite

							NumberAnimation {
								from: 0.5
								to: 0
								duration: 1400
								easing.type: Easing.OutCubic
							}
						}
					}
				}

				HoverHandler {
					id: hover

					cursorShape: Qt.PointingHandCursor
				}

				TapHandler {
					onTapped: {
						Sounds.play("select");
						root.picked(spot.modelData.id);
					}
				}

				// the name, on hover
				Rectangle {
					readonly property bool leftSide: spot.modelData.side === "left"

					anchors.verticalCenter: parent.verticalCenter
					x: leftSide ? -width - 6 : parent.width + 6
					width: name.implicitWidth + 16
					height: 24
					radius: 12
					color: Theme.layer3
					border.width: 1
					border.color: Theme.outline
					opacity: hover.hovered && !spot.picked ? 1 : 0
					visible: opacity > 0.01
					scale: hover.hovered ? 1 : 0.85

					Behavior on opacity {
						Anim {
							duration: Motion.short
						}
					}
					Behavior on scale {
						SpatialAnim {
							duration: Motion.medium
						}
					}

					StyledText {
						id: name

						anchors.centerIn: parent
						text: spot.modelData.label
						font.pixelSize: Theme.size.small
						font.weight: Font.Medium
					}
				}
			}
		}

		// ── where a swipe is going ─────────────────────────────────────────
		Item {
			id: trail

			readonly property var meta: Controls.byId(root.moving)
			readonly property bool shown: root.moving !== "" && !!root.pressed[root.moving] && (Math.abs(root.moveX) + Math.abs(root.moveY)) > 0.05

			visible: opacity > 0.01
			opacity: trail.shown ? 1 : 0
			x: trail.meta ? trail.meta.spot[0] * 300 : 0
			y: trail.meta ? trail.meta.spot[1] * 420 : 0
			z: 5

			Behavior on opacity {
				Anim {
					duration: Motion.short
				}
			}

			Rectangle {
				id: dot

				readonly property real reach: Math.min(1.25, Math.hypot(root.moveX, root.moveY))

				x: Math.max(-1.25, Math.min(1.25, root.moveX)) * 60 - width / 2
				y: Math.max(-1.25, Math.min(1.25, root.moveY)) * 60 - height / 2
				width: 18
				height: 18
				radius: 9
				color: dot.reach >= 1 ? Theme.primary : Theme.text
				border.width: 3
				border.color: Qt.alpha(Theme.primary, 0.35)

				Behavior on x {
					SpatialAnim {
						duration: Motion.micro
					}
				}
				Behavior on y {
					SpatialAnim {
						duration: Motion.micro
					}
				}
			}
		}
	}
}
