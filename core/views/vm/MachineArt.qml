pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import qs.style.theme
import qs.style.widgets

// A machine drawn as a monitor. Off, its screen is dark glass a sheen runs
// over now and then; starting, the screen wakes in the accent colours, the
// logo's panes flip in one after the other and the boot dots run; once the
// machine answers, a ripple goes out. It leans a little towards the pointer.
Item {
	id: root

	property var machine: null
	// "off" | "waking" (the machine starts) | "booting" (waits for the OS) | "on"
	property string phase: "off"
	property bool active: true
	// where the pointer is over the art, -1…1 on both axes; 0 is the middle
	property point lean: Qt.point(0, 0)
	property string caption: ""

	readonly property bool windows: root.machine?.family === "windows"
	property real power: root.phase === "off" ? 0 : 1
	property real wake: root.phase === "off" ? 0 : (root.phase === "waking" ? 0.55 : 1)

	function celebrate() {
		ripple.restart();
	}

	implicitWidth: 380
	implicitHeight: 300

	Behavior on power {
		NumberAnimation {
			duration: root.power < 0.5 ? 900 : 600
			easing.type: Easing.BezierSpline
			easing.bezierCurve: Motion.decel
		}
	}
	Behavior on wake {
		NumberAnimation {
			duration: 900
			easing.type: Easing.BezierSpline
			easing.bezierCurve: Motion.standard
		}
	}

	// the panes flip in whenever the machine wakes
	onPhaseChanged: {
		if (root.phase === "off") {
			for (let i = 0; i < panes.count; i += 1) panes.itemAt(i).flip = 0;
			return;
		}
		if (panes.count > 0 && panes.itemAt(0).flip === 0) flipIn.restart();
	}
	Component.onCompleted: {
		if (root.phase !== "off")
			for (let i = 0; i < panes.count; i += 1) panes.itemAt(i).flip = 1;
	}

	SequentialAnimation {
		id: flipIn

		PauseAnimation {
			duration: 260
		}
		ScriptAction {
			script: {
				for (let i = 0; i < panes.count; i += 1) panes.itemAt(i).start();
			}
		}
	}

	// the light the screen throws behind it
	Item {
		id: glowSource

		// centred on the bezel (18 + 216 / 2 from the top)
		anchors.horizontalCenter: parent.horizontalCenter
		y: 126 - height / 2
		width: bezel.width + 120
		height: bezel.height + 120
		visible: false
		layer.enabled: true

		Rectangle {
			anchors.centerIn: parent
			width: bezel.width - 30
			height: bezel.height - 40
			radius: 40
			gradient: Gradient {
				orientation: Gradient.Horizontal
				GradientStop {
					position: 0
					color: Theme.primary
				}
				GradientStop {
					position: 1
					color: Theme.tertiary
				}
			}
		}
	}

	MultiEffect {
		id: glow

		property real breathe: 1

		anchors.fill: glowSource
		source: glowSource
		blurEnabled: true
		blurMax: 64
		blur: 1
		opacity: root.power * 0.55 * glow.breathe

		SequentialAnimation on breathe {
			running: root.active && root.power > 0.5
			loops: Animation.Infinite

			NumberAnimation {
				to: 0.7
				duration: 2200
				easing.type: Easing.InOutSine
			}
			NumberAnimation {
				to: 1
				duration: 2200
				easing.type: Easing.InOutSine
			}
		}
	}

	// the shadow the monitor stands in
	Rectangle {
		anchors.horizontalCenter: parent.horizontalCenter
		y: foot.y + 2
		width: 230
		height: 18
		radius: 9
		color: "black"
		opacity: 0.35
		layer.enabled: true
		layer.effect: MultiEffect {
			blurEnabled: true
			blurMax: 24
			blur: 1
		}
	}

	Item {
		id: body

		anchors.fill: parent
		transform: [
			Rotation {
				origin.x: body.width / 2
				origin.y: body.height / 2
				axis {
					x: 0
					y: 1
					z: 0
				}
				angle: root.lean.x * 7
			},
			Rotation {
				origin.x: body.width / 2
				origin.y: body.height / 2
				axis {
					x: 1
					y: 0
					z: 0
				}
				angle: -root.lean.y * 5
			}
		]

		Rectangle {
			id: neck

			anchors.horizontalCenter: parent.horizontalCenter
			y: bezel.y + bezel.height - 4
			width: 54
			height: 40
			gradient: Gradient {
				GradientStop {
					position: 0
					color: "#05060a"
				}
				GradientStop {
					position: 1
					color: Qt.tint("#1a1c22", Qt.alpha(Theme.primary, 0.08))
				}
			}
		}

		Rectangle {
			id: foot

			anchors.horizontalCenter: parent.horizontalCenter
			y: neck.y + neck.height - 2
			width: 150
			height: 10
			radius: 5
			color: Qt.tint("#1d1f26", Qt.alpha(Theme.primary, 0.1))

			Rectangle {
				anchors.horizontalCenter: parent.horizontalCenter
				width: parent.width - 30
				height: 1
				color: Qt.rgba(1, 1, 1, 0.12)
			}
		}

		Rectangle {
			id: bezel

			anchors.horizontalCenter: parent.horizontalCenter
			y: 18
			width: 344
			height: 216
			radius: 18
			color: Qt.tint("#0b0c10", Qt.alpha(Theme.primary, 0.05))
			border.width: 1
			border.color: Qt.rgba(1, 1, 1, 0.09)

			Rectangle {
				id: screen

				anchors.fill: parent
				anchors.margins: 9
				radius: 11
				color: "#050608"
				clip: true

				// the desktop of the machine, in the shell's colours
				Item {
					anchors.fill: parent
					opacity: root.power

					Rectangle {
						anchors.fill: parent
						gradient: Gradient {
							orientation: Gradient.Horizontal
							GradientStop {
								position: 0
								color: Qt.darker(Theme.primary, 2.6)
							}
							GradientStop {
								position: 1
								color: Qt.darker(Theme.tertiary, 3.2)
							}
						}
					}

					// two petals of light, like a bloom
					Repeater {
						model: [
							{ x: 0.18, y: 0.05, w: 0.95, h: 0.8, r: -24, c: Theme.primary },
							{ x: 0.42, y: 0.32, w: 0.85, h: 0.75, r: 18, c: Theme.secondary }
						]

						delegate: Rectangle {
							id: petal

							required property var modelData
							required property int index

							x: screen.width * petal.modelData.x - 30 * (1 - root.wake)
							y: screen.height * petal.modelData.y
							width: screen.width * petal.modelData.w
							height: screen.height * petal.modelData.h
							radius: height / 2
							rotation: petal.modelData.r + (1 - root.wake) * 30 * (petal.index ? -1 : 1)
							opacity: 0.55 * root.wake
							gradient: Gradient {
								GradientStop {
									position: 0
									color: Qt.alpha(petal.modelData.c, 0.85)
								}
								GradientStop {
									position: 1
									color: Qt.alpha(petal.modelData.c, 0)
								}
							}
							layer.enabled: true
							layer.effect: MultiEffect {
								blurEnabled: true
								blurMax: 48
								blur: 1
							}
						}
					}

					// darker while it boots, so the dots read
					Rectangle {
						anchors.fill: parent
						color: "black"
						opacity: root.phase === "booting" || root.phase === "waking" ? 0.35 : 0

						Behavior on opacity {
							Anim {
								duration: Motion.extraLong
							}
						}
					}
				}

				// a sheen crosses the dark glass now and then
				Rectangle {
					id: sheen

					property real travel: 0

					width: 90
					height: screen.height * 2
					y: -screen.height / 2
					x: -width * 2 + (screen.width + width * 3) * sheen.travel
					rotation: 24
					opacity: (1 - root.power) * 0.9
					gradient: Gradient {
						orientation: Gradient.Horizontal
						GradientStop {
							position: 0
							color: Qt.rgba(1, 1, 1, 0)
						}
						GradientStop {
							position: 0.5
							color: Qt.rgba(1, 1, 1, 0.06)
						}
						GradientStop {
							position: 1
							color: Qt.rgba(1, 1, 1, 0)
						}
					}

					SequentialAnimation on travel {
						running: root.active && root.power < 0.5
						loops: Animation.Infinite

						PauseAnimation {
							duration: 900
						}
						NumberAnimation {
							from: 0
							to: 1
							duration: 1600
							easing.type: Easing.InOutQuad
						}
						PauseAnimation {
							duration: 4200
						}
					}
				}

				// the screen lights up white for a moment when the machine answers
				Rectangle {
					id: flash

					anchors.fill: parent
					color: "white"
					opacity: 0
				}

				// the logo
				Item {
					id: logo

					anchors.centerIn: parent
					anchors.verticalCenterOffset: root.phase === "booting" || root.phase === "waking" ? -24 : 0
					width: 76
					height: 76
					scale: 1

					Behavior on anchors.verticalCenterOffset {
						SpatialAnim {}
					}

					Grid {
						anchors.centerIn: parent
						visible: root.windows
						columns: 2
						spacing: 4

						Repeater {
							id: panes

							model: 4

							delegate: Rectangle {
								id: pane

								required property int index
								property real flip: 0

								function start() {
									flipAnim.restart();
								}

								width: 34
								height: 34
								radius: 3
								color: Qt.tint(Qt.rgba(1, 1, 1, 0.07 + 0.88 * pane.flip), Qt.alpha(Theme.primary, 0.18 * pane.flip))
								border.width: 1
								border.color: Qt.rgba(1, 1, 1, 0.14 * (1 - pane.flip))
								transform: Rotation {
									origin.x: 17
									origin.y: 17
									axis {
										x: 0
										y: 1
										z: 0
									}
									angle: pane.flip > 0 && pane.flip < 1 ? (1 - pane.flip) * 180 : 0
								}

								SequentialAnimation {
									id: flipAnim

									PauseAnimation {
										duration: [0, 1, 3, 2][pane.index] * 120
									}
									NumberAnimation {
										target: pane
										property: "flip"
										from: 0
										to: 1
										duration: 620
										easing.type: Easing.BezierSpline
										easing.bezierCurve: Motion.spatial
									}
								}
							}
						}
					}

					Glyph {
						anchors.centerIn: parent
						visible: !root.windows
						icon: root.machine?.family === "linux" ? "linux" : "monitor"
						size: 64
						color: Qt.rgba(1, 1, 1, 0.12 + 0.85 * root.power)
						surface: "transparent"
					}
				}

				BootDots {
					anchors.horizontalCenter: parent.horizontalCenter
					anchors.top: logo.bottom
					anchors.topMargin: 10
					running: root.active && (root.phase === "booting" || root.phase === "waking")
				}

				StyledText {
					anchors.horizontalCenter: parent.horizontalCenter
					anchors.bottom: parent.bottom
					anchors.bottomMargin: 10
					text: root.caption
					tone: Qt.rgba(1, 1, 1, 0.72)
					surface: "transparent"
					font.pixelSize: Theme.size.small
					font.weight: Font.Medium
					opacity: root.caption !== "" ? 1 : 0

					Behavior on opacity {
						Anim {}
					}
				}

				// glass: a soft highlight over the top
				Rectangle {
					anchors.fill: parent
					radius: parent.radius
					gradient: Gradient {
						GradientStop {
							position: 0
							color: Qt.rgba(1, 1, 1, 0.05)
						}
						GradientStop {
							position: 0.45
							color: Qt.rgba(1, 1, 1, 0)
						}
					}
				}
			}

			// the power light on the bezel
			Rectangle {
				anchors.horizontalCenter: parent.horizontalCenter
				anchors.bottom: parent.bottom
				anchors.bottomMargin: 2
				width: 18
				height: 3
				radius: 1.5
				color: root.phase === "off" ? Qt.rgba(1, 1, 1, 0.12) : Theme.primary

				Behavior on color {
					ColorAnim {}
				}
			}
		}

		// the ripple when the machine answers
		Rectangle {
			id: ring

			anchors.centerIn: bezel
			width: bezel.width
			height: bezel.height
			radius: bezel.radius
			color: "transparent"
			border.width: 2
			border.color: Theme.primary
			opacity: 0
		}
	}

	ParallelAnimation {
		id: ripple

		NumberAnimation {
			target: ring
			property: "scale"
			from: 1
			to: 1.22
			duration: 900
			easing.type: Easing.OutCubic
		}
		NumberAnimation {
			target: ring
			property: "opacity"
			from: 0.9
			to: 0
			duration: 900
			easing.type: Easing.OutCubic
		}
		SequentialAnimation {
			NumberAnimation {
				target: flash
				property: "opacity"
				from: 0
				to: 0.5
				duration: 90
			}
			NumberAnimation {
				target: flash
				property: "opacity"
				to: 0
				duration: 700
				easing.type: Easing.OutCubic
			}
		}
		SequentialAnimation {
			NumberAnimation {
				target: logo
				property: "scale"
				to: 1.14
				duration: 160
				easing.type: Easing.OutCubic
			}
			NumberAnimation {
				target: logo
				property: "scale"
				to: 1
				duration: 520
				easing.type: Easing.BezierSpline
				easing.bezierCurve: Motion.spatial
			}
		}
	}
}
