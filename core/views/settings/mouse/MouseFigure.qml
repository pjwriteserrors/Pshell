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
			x: 50
			y: 372
			width: 210
			height: 46
			radius: 23
			color: Theme.shadow
			opacity: 0.45
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
					path: "M 100 40 C 130 14 210 12 240 40 C 262 70 272 150 270 220 C 268 300 262 360 232 392 C 205 412 130 414 95 396 C 60 388 26 360 20 318 C 16 280 24 236 52 214 C 70 200 80 186 84 160 C 88 110 88 70 100 40 Z"
				}
			}

			// light from the upper left: the body has some volume
			ShapePath {
				strokeWidth: 0
				strokeColor: "transparent"
				fillGradient: LinearGradient {
					x1: 30
					y1: 60
					x2: 280
					y2: 300

					GradientStop {
						position: 0
						color: Qt.alpha(Theme.text, 0.07)
					}
					GradientStop {
						position: 0.5
						color: Qt.alpha(Theme.text, 0.015)
					}
					GradientStop {
						position: 1
						color: Qt.rgba(0, 0, 0, 0.22)
					}
				}

				PathSvg {
					path: "M 100 40 C 130 14 210 12 240 40 C 262 70 272 150 270 220 C 268 300 262 360 232 392 C 205 412 130 414 95 396 C 60 388 26 360 20 318 C 16 280 24 236 52 214 C 70 200 80 186 84 160 C 88 110 88 70 100 40 Z"
				}
			}

			// the thumb rest, a little apart from the body
			ShapePath {
				strokeWidth: 0
				strokeColor: "transparent"
				fillColor: Qt.alpha(Theme.text, root.selected === "haptic" ? 0.0 : 0.035)

				PathSvg {
					path: "M 95 396 C 60 388 26 360 20 318 C 16 280 24 236 52 214 C 66 240 76 290 80 330 C 83 360 90 382 95 396 Z"
				}
			}

			// the buttons' seams
			ShapePath {
				strokeWidth: 1.4
				strokeColor: Qt.alpha(Theme.text, 0.12)
				fillColor: "transparent"
				capStyle: ShapePath.RoundCap

				PathSvg {
					path: "M 169 14 L 169 46 M 169 124 L 169 132 M 169 152 L 169 190 M 85 164 C 130 188 214 192 269 176"
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
					path: "M 168 15 C 140 15 116 24 100 40 C 88 70 88 110 85 164 C 115 180 140 188 168 190 Z"
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
					path: "M 170 15 C 200 14 226 22 240 40 C 258 66 266 120 269 176 C 230 188 200 191 170 190 Z"
				}
			}
		}

		// the haptic panel ripples when it is pressed
		Item {
			id: ripple

			x: 54
			y: 346
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

			x: 158
			y: 48
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
			x: 161
			y: 134
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

			x: 40
			y: 196
			width: 40
			height: 17
			radius: 8
			rotation: -38
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
			model: [{ id: "forward", x: 40, y: 232 }, { id: "back", x: 34, y: 258 }]

			delegate: Rectangle {
				id: side

				required property var modelData

				x: side.modelData.x
				y: side.modelData.y
				width: 34
				height: 14
				radius: 7
				rotation: -24
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
			x: 28
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
