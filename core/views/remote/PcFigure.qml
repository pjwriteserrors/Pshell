import QtQuick
import QtQuick.Shapes
import qs.style.theme
import qs.style.widgets

// A PC drawn as a monitor beside a tower (or a laptop), with what its screen
// shows: "off", "boot", "login", "desktop", "stream". The tower's power
// button (the laptop's key) is the way to wake it: held until its ring is
// full. `armed` lets it be held; `holding` reports the hold.
Item {
	id: root

	property string kind: "pc"
	property string screen: "off"
	property bool led: false
	property bool ledBlink: false
	property string user: ""
	property bool armed: true
	property real holdTime: 650
	property bool active: true
	// how lit the whole figure is (0 asleep … 1 day)
	property real light: 0
	readonly property real hold: holdRing.fill
	readonly property bool laptop: root.kind === "laptop"
	// where the screen's middle is, for the beams
	readonly property point screenCenter: Qt.point(glass.x + glass.width / 2 + body.x, glass.y + glass.height / 2 + body.y)
	readonly property point buttonCenter: Qt.point(powerKey.x + powerKey.width / 2 + body.x, powerKey.y + powerKey.height / 2 + body.y)

	signal pressedLong
	signal touched

	implicitWidth: 300
	implicitHeight: 210

	readonly property color shell: Qt.tint("#161a26", Qt.rgba(1, 1, 1, 0.05 + 0.07 * root.light))
	readonly property color rim: Qt.rgba(1, 1, 1, 0.1 + 0.18 * root.light)

	Item {
		id: body

		anchors.fill: parent

		// ── the monitor (or the laptop's lid) ────────────────────────────────
		Rectangle {
			id: lid

			x: root.laptop ? 50 : 18
			y: root.laptop ? 14 : 4
			width: root.laptop ? 200 : 206
			height: root.laptop ? 132 : 136
			radius: 12
			color: root.shell
			border.width: 1
			border.color: root.rim

			Rectangle {
				id: glass

				anchors.fill: parent
				anchors.margins: 7
				anchors.bottomMargin: root.laptop ? 9 : 12
				radius: 6
				clip: true
				color: "#05070d"

				// desktop: the accent's colours, a bar on top
				Rectangle {
					anchors.fill: parent
					opacity: root.screen === "desktop" || root.screen === "stream" ? 1 : 0
					gradient: Gradient {
						orientation: Gradient.Vertical
						GradientStop {
							position: 0
							color: Qt.darker(Theme.primary, 1.6)
						}
						GradientStop {
							position: 1
							color: Qt.darker(Theme.tertiary, 2.2)
						}
					}

					Behavior on opacity {
						Anim {
							duration: Motion.extraLong
						}
					}

					Rectangle {
						x: 6
						y: 5
						width: parent.width - 12
						height: 7
						radius: 3.5
						color: Qt.rgba(0, 0, 0, 0.35)
					}

					Repeater {
						model: 3

						delegate: Rectangle {
							required property int index

							x: 14 + index * 44
							y: 26 + (index % 2) * 18
							width: 36 + (index === 1 ? 18 : 0)
							height: 26
							radius: 4
							color: Qt.rgba(1, 1, 1, 0.12)
						}
					}

					// streaming: a sun in the corner
					Glyph {
						anchors.right: parent.right
						anchors.bottom: parent.bottom
						anchors.margins: 6
						icon: "white_balance_sunny"
						size: 16
						color: "#ffd36b"
						surface: "transparent"
						opacity: root.screen === "stream" ? 1 : 0

						Behavior on opacity {
							Anim {}
						}

						RotationAnimation on rotation {
							running: root.active && root.screen === "stream"
							loops: Animation.Infinite
							from: 0
							to: 360
							duration: 9000
						}
					}
				}

				// boot: a mark that breathes, three dots that walk
				Item {
					anchors.fill: parent
					opacity: root.screen === "boot" ? 1 : 0

					Behavior on opacity {
						Anim {}
					}

					Glyph {
						id: bootMark

						anchors.centerIn: parent
						anchors.verticalCenterOffset: -8
						icon: "power"
						size: 30
						color: Theme.primary
						surface: "transparent"

						SequentialAnimation on opacity {
							running: root.active && root.screen === "boot"
							loops: Animation.Infinite

							NumberAnimation {
								to: 0.35
								duration: 700
								easing.type: Easing.InOutSine
							}
							NumberAnimation {
								to: 1
								duration: 700
								easing.type: Easing.InOutSine
							}
						}
					}

					Row {
						anchors.horizontalCenter: parent.horizontalCenter
						anchors.top: bootMark.bottom
						anchors.topMargin: 12
						spacing: 6

						Repeater {
							model: 3

							delegate: Rectangle {
								id: bootDot

								required property int index

								width: 5
								height: 5
								radius: 2.5
								color: Qt.rgba(1, 1, 1, 0.8)
								opacity: 0.25

								SequentialAnimation on opacity {
									running: root.active && root.screen === "boot"
									loops: Animation.Infinite

									PauseAnimation {
										duration: bootDot.index * 180
									}
									NumberAnimation {
										to: 1
										duration: 260
									}
									NumberAnimation {
										to: 0.25
										duration: 420
									}
									PauseAnimation {
										duration: (2 - bootDot.index) * 180
									}
								}
							}
						}
					}
				}

				// login: the avatar, a ring going round it
				Item {
					anchors.fill: parent
					opacity: root.screen === "login" ? 1 : 0

					Behavior on opacity {
						Anim {}
					}

					Rectangle {
						anchors.fill: parent
						gradient: Gradient {
							GradientStop {
								position: 0
								color: "#0b1020"
							}
							GradientStop {
								position: 1
								color: Qt.darker(Theme.primary, 3.2)
							}
						}
					}

					Rectangle {
						id: avatar

						anchors.centerIn: parent
						anchors.verticalCenterOffset: -8
						width: 40
						height: 40
						radius: 20
						color: Qt.alpha(Theme.primary, 0.25)

						Glyph {
							anchors.centerIn: parent
							icon: "account"
							size: 24
							color: "white"
							surface: "transparent"
						}
					}

					Ring {
						anchors.centerIn: avatar
						width: 52
						height: 52
						thickness: 2.5
						value: 0.3
						trackColor: "transparent"
						color: Theme.primary

						RotationAnimation on rotation {
							running: root.active && root.screen === "login"
							loops: Animation.Infinite
							from: 0
							to: 360
							duration: 1300
						}
					}

					StyledText {
						anchors.horizontalCenter: parent.horizontalCenter
						anchors.top: avatar.bottom
						anchors.topMargin: 10
						text: root.user || "Signing in"
						tone: Qt.rgba(1, 1, 1, 0.75)
						surface: "transparent"
						font.pixelSize: 10
						font.weight: Font.DemiBold
					}
				}

				// the glass catches the light
				Rectangle {
					width: parent.width * 0.5
					height: parent.height * 2
					x: parent.width * 0.55
					y: -parent.height * 0.4
					rotation: 24
					opacity: 0.06 + 0.04 * (1 - root.light)
					gradient: Gradient {
						orientation: Gradient.Horizontal
						GradientStop {
							position: 0
							color: Qt.rgba(1, 1, 1, 0)
						}
						GradientStop {
							position: 0.5
							color: Qt.rgba(1, 1, 1, 1)
						}
						GradientStop {
							position: 1
							color: Qt.rgba(1, 1, 1, 0)
						}
					}
				}
			}
		}

		// ── stand and foot (pc) ──────────────────────────────────────────────
		Rectangle {
			visible: !root.laptop
			x: lid.x + lid.width / 2 - 9
			y: lid.y + lid.height
			width: 18
			height: 26
			color: Qt.darker(root.shell, 1.15)
		}

		Rectangle {
			visible: !root.laptop
			x: lid.x + lid.width / 2 - 46
			y: lid.y + lid.height + 24
			width: 92
			height: 7
			radius: 3.5
			color: root.shell
			border.width: 1
			border.color: root.rim
		}

		// ── the laptop's deck ─────────────────────────────────────────────────
		Shape {
			visible: root.laptop
			x: lid.x - 26
			y: lid.y + lid.height
			width: lid.width + 52
			height: 20
			preferredRendererType: Shape.CurveRenderer

			ShapePath {
				fillColor: root.shell
				strokeColor: root.rim
				strokeWidth: 1
				startX: 26
				startY: 0
				PathLine {
					x: 26 + lid.width
					y: 0
				}
				PathLine {
					x: lid.width + 52
					y: 14
				}
				PathQuad {
					x: lid.width + 44
					y: 20
					controlX: lid.width + 52
					controlY: 20
				}
				PathLine {
					x: 8
					y: 20
				}
				PathQuad {
					x: 0
					y: 14
					controlX: 0
					controlY: 20
				}
				PathLine {
					x: 26
					y: 0
				}
			}
		}

		// ── the tower ────────────────────────────────────────────────────────
		Rectangle {
			id: tower

			visible: !root.laptop
			x: 236
			y: 22
			width: 58
			height: 148
			radius: 9
			color: root.shell
			border.width: 1
			border.color: root.rim

			// the vents
			Column {
				anchors.horizontalCenter: parent.horizontalCenter
				y: 70
				spacing: 5

				Repeater {
					model: 6

					delegate: Rectangle {
						width: 30
						height: 2
						radius: 1
						color: Qt.rgba(0, 0, 0, 0.35)
					}
				}
			}

			// the drive light
			Rectangle {
				id: towerLed

				x: tower.width / 2 - 2
				y: 56
				width: 4
				height: 4
				radius: 2
				color: root.led ? "#7dffb0" : Qt.rgba(1, 1, 1, 0.12)

				SequentialAnimation on opacity {
					running: root.active && root.ledBlink
					loops: Animation.Infinite
					onRunningChanged: if (!running) towerLed.opacity = 1

					NumberAnimation {
						to: 0.2
						duration: 140
					}
					NumberAnimation {
						to: 1
						duration: 90
					}
					PauseAnimation {
						duration: 260
					}
				}
			}
		}

		// ── the power key: hold it ───────────────────────────────────────────
		Item {
			id: powerKey

			readonly property bool hot: keyMouse.containsMouse && root.armed

			x: root.laptop ? lid.x + lid.width + 6 : tower.x + tower.width / 2 - 15
			y: root.laptop ? lid.y + lid.height + 1 : tower.y + 14
			width: 30
			height: 30

			// a halo calls for a hand while it can be held
			Rectangle {
				id: halo

				property real pulse: 0

				anchors.centerIn: parent
				width: 30 + 26 * halo.pulse
				height: width
				radius: width / 2
				color: "transparent"
				border.width: 1.5
				border.color: Theme.primary
				opacity: root.armed && !root.led ? 0.55 * (1 - halo.pulse) : 0

				NumberAnimation on pulse {
					running: root.active && root.armed && !root.led
					loops: Animation.Infinite
					from: 0
					to: 1
					duration: 1800
					easing.type: Easing.OutCubic
				}
			}

			Rectangle {
				anchors.centerIn: parent
				width: 24
				height: 24
				radius: 12
				color: root.led ? Qt.alpha(Theme.primary, 0.3) : Qt.rgba(1, 1, 1, powerKey.hot ? 0.16 : 0.07)
				border.width: 1
				border.color: root.led ? Theme.primary : Qt.rgba(1, 1, 1, powerKey.hot ? 0.5 : 0.22)
				scale: keyMouse.pressed && root.armed ? 0.9 : 1

				Behavior on scale {
					SpatialAnim {
						duration: Motion.short
					}
				}
				Behavior on color {
					ColorAnim {}
				}

				Glyph {
					anchors.centerIn: parent
					icon: "power"
					size: 14
					color: root.led ? Theme.primary : Qt.rgba(1, 1, 1, powerKey.hot ? 0.95 : 0.6)
					surface: "transparent"
				}
			}

			Ring {
				id: holdRing

				property real fill: 0

				anchors.centerIn: parent
				width: 36
				height: 36
				thickness: 3
				animated: false
				value: holdRing.fill
				trackColor: "transparent"
				color: Theme.primary
				visible: holdRing.fill > 0

				NumberAnimation on fill {
					id: filling

					running: false
					to: 1
					onFinished: if (holdRing.fill >= 1) {
						root.pressedLong();
						holdRing.fill = 0;
					}
				}
				NumberAnimation on fill {
					id: draining

					running: false
					to: 0
					duration: 220
				}
			}

			MouseArea {
				id: keyMouse

				anchors.fill: parent
				anchors.margins: -10
				hoverEnabled: true
				cursorShape: root.armed ? Qt.PointingHandCursor : Qt.ArrowCursor
				onPressed: {
					if (!root.armed) return;
					root.touched();
					draining.stop();
					filling.duration = root.holdTime * (1 - holdRing.fill);
					filling.start();
				}
				onReleased: {
					filling.stop();
					if (holdRing.fill > 0) draining.start();
				}
				onCanceled: {
					filling.stop();
					draining.start();
				}
			}
		}
	}
}
