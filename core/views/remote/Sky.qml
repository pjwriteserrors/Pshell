import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
import qs.style.theme
import qs.style.widgets

// The sky the PC stands under. `dawn` goes from night (it is off) to day (it
// streams); the stars fade, the horizon warms. `sun` rises behind the PC
// (Sunshine), the moon in the corner is this PC (Moonlight). Between them
// two routes: the magic packet's (moon → netcore → the PC, `packet` 0…1 as
// a shooting star) and the stream's (the PC → moon, lit by `beam`).
Item {
	id: root

	property real dawn: 0
	property real sun: 0
	property real beam: 0
	property real packet: -1
	property bool active: true
	property bool relayLit: false
	// where the PC's screen is, in this item
	property point target: Qt.point(width / 2, height * 0.6)
	readonly property point moon: Qt.point(112, 84)
	readonly property point relay: Qt.point(width * 0.34, 44)
	readonly property real horizonY: height - 64

	Behavior on dawn {
		Anim {
			duration: 1600
			easing.type: Easing.InOutSine
		}
	}
	Behavior on sun {
		SpatialAnim {
			duration: 2200
		}
	}
	Behavior on beam {
		Anim {
			duration: 900
		}
	}

	function mix(a, b, t) {
		return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, a.a + (b.a - a.a) * t);
	}

	// ── the sky ──────────────────────────────────────────────────────────────
	Rectangle {
		anchors.fill: parent
		radius: 28
		gradient: Gradient {
			GradientStop {
				position: 0
				color: root.mix(Qt.color("#04060f"), Qt.darker(Theme.primary, 2.6), root.dawn * 0.8)
			}
			GradientStop {
				position: 0.62
				color: root.mix(Qt.color("#0a1024"), Qt.darker(Theme.tertiary, 1.9), root.dawn * 0.8)
			}
			GradientStop {
				position: 1
				color: root.mix(Qt.color("#121a33"), Qt.lighter(Theme.tertiary, 1.05), root.dawn * 0.7)
			}
		}
	}

	Item {
		id: world

		anchors.fill: parent
		layer.enabled: true
		layer.effect: MultiEffect {
			maskEnabled: true
			maskSource: frame
		}

		// ── the stars ────────────────────────────────────────────────────────
		Repeater {
			model: 64

			delegate: Rectangle {
				id: star

				required property int index
				// the same sky each time: a little hash of the index
				readonly property real rx: ((index * 7919) % 997) / 997
				readonly property real ry: ((index * 104729) % 991) / 991
				readonly property real big: ((index * 31) % 7) === 0 ? 1 : 0
				property real twinkle: 1

				x: star.rx * root.width
				y: star.ry * (root.horizonY - 30)
				width: 1.5 + star.big * 1.5
				height: width
				radius: width / 2
				color: "white"
				opacity: (0.3 + 0.55 * star.twinkle) * (1 - root.dawn)

				SequentialAnimation on twinkle {
					running: root.active && root.dawn < 0.9
					loops: Animation.Infinite

					PauseAnimation {
						duration: (star.index * 373) % 2600
					}
					NumberAnimation {
						to: 0.15
						duration: 900 + (star.index * 211) % 1400
						easing.type: Easing.InOutSine
					}
					NumberAnimation {
						to: 1
						duration: 900 + (star.index * 157) % 1400
						easing.type: Easing.InOutSine
					}
				}
			}
		}

		// ── the sun (Sunshine), behind the PC ────────────────────────────────
		Item {
			id: sunItem

			x: root.target.x - width / 2
			y: root.horizonY + 40 - (root.horizonY - 10) * 0.62 * root.sun
			width: 150
			height: 150
			opacity: Math.min(1, root.sun * 1.6)

			Rectangle {
				id: sunGlow

				anchors.centerIn: parent
				width: 260
				height: 260
				radius: 130
				color: "#ffbf5a"
				visible: false
			}

			MultiEffect {
				anchors.fill: sunGlow
				source: sunGlow
				blurEnabled: true
				blurMax: 64
				blur: 1
				opacity: 0.45
			}

			// the rays, slowly turning
			Item {
				anchors.centerIn: parent
				width: 230
				height: 230

				RotationAnimation on rotation {
					running: root.active && root.sun > 0.05
					loops: Animation.Infinite
					from: 0
					to: 360
					duration: 60000
				}

				Repeater {
					model: 16

					delegate: Rectangle {
						required property int index

						x: parent.width / 2 - width / 2
						y: 0
						width: index % 2 ? 3 : 5
						height: parent.height / 2 - 60
						radius: width / 2
						color: "#ffd98a"
						opacity: 0.35
						transformOrigin: Item.Bottom
						transform: Rotation {
							origin.x: 2
							origin.y: 115
							angle: index * 22.5
						}
					}
				}
			}

			Rectangle {
				anchors.centerIn: parent
				width: 96
				height: 96
				radius: 48
				gradient: Gradient {
					GradientStop {
						position: 0
						color: "#fff1b8"
					}
					GradientStop {
						position: 1
						color: "#ffb347"
					}
				}
			}
		}

		// ── the hill the PC stands on ────────────────────────────────────────
		Rectangle {
			x: -root.width * 0.4
			y: root.horizonY
			width: root.width * 1.8
			height: root.width
			radius: width / 2
			color: root.mix(Qt.color("#070a14"), Qt.darker(Theme.primary, 4.2), root.dawn)
			border.width: 1.5
			border.color: Qt.alpha(root.mix(Qt.color("#4a5a8a"), Qt.color("#ffd9a0"), root.dawn), 0.45)
		}

		// ── the routes ───────────────────────────────────────────────────────
		Shape {
			anchors.fill: parent
			preferredRendererType: Shape.CurveRenderer

			// the packet's way: faint dots
			ShapePath {
				strokeColor: Qt.rgba(1, 1, 1, 0.14 + 0.2 * (root.packet >= 0 ? 1 : 0))
				strokeWidth: 1.2
				fillColor: "transparent"
				strokeStyle: ShapePath.DashLine
				dashPattern: [1, 5]
				capStyle: ShapePath.RoundCap
				startX: root.moon.x + 22
				startY: root.moon.y - 8
				PathQuad {
					x: root.relay.x
					y: root.relay.y
					controlX: (root.moon.x + root.relay.x) / 2
					controlY: 8
				}
				PathQuad {
					x: root.target.x
					y: root.target.y - 40
					controlX: root.target.x - 10
					controlY: root.relay.y - 10
				}
			}

			// the stream's way: lit while it flows
			ShapePath {
				id: stream

				property real flow: 0

				strokeColor: Qt.alpha(Theme.primary, 0.85 * root.beam)
				strokeWidth: 2.4
				fillColor: "transparent"
				strokeStyle: ShapePath.DashLine
				dashPattern: [4, 6]
				dashOffset: -stream.flow
				capStyle: ShapePath.RoundCap
				startX: root.target.x - 40
				startY: root.target.y - 10
				PathCubic {
					x: root.moon.x + 18
					y: root.moon.y + 24
					control1X: root.target.x - 160
					control1Y: root.target.y - 20
					control2X: root.moon.x + 60
					control2Y: root.moon.y + 110
				}

				NumberAnimation on flow {
					running: root.active && root.beam > 0.05
					loops: Animation.Infinite
					from: 0
					to: 20
					duration: 700
				}
			}
		}

		// ── netcore, a star that relays ──────────────────────────────────────
		Item {
			x: root.relay.x - 14
			y: root.relay.y - 14
			width: 28
			height: 28

			Rectangle {
				anchors.centerIn: parent
				width: root.relayLit ? 26 : 14
				height: width
				radius: width / 2
				color: Qt.alpha(Theme.primary, root.relayLit ? 0.35 : 0.12)

				Behavior on width {
					SpatialAnim {
						duration: Motion.medium
					}
				}
			}

			Glyph {
				anchors.centerIn: parent
				icon: "server"
				size: 13
				color: root.relayLit ? "white" : Qt.rgba(1, 1, 1, 0.6)
				surface: "transparent"
			}

			StyledText {
				anchors.horizontalCenter: parent.horizontalCenter
				anchors.top: parent.bottom
				anchors.topMargin: 2
				text: "netcore"
				tone: Qt.rgba(1, 1, 1, 0.45)
				surface: "transparent"
				font.pixelSize: 9
				font.weight: Font.DemiBold
				font.letterSpacing: 1
			}
		}

		// ── the shooting star (the magic packet) ─────────────────────────────
		Repeater {
			model: 7

			delegate: Rectangle {
				id: spark

				required property int index
				readonly property real t: root.packet - spark.index * 0.022
				readonly property point at: root.along(Math.max(0, Math.min(1, spark.t)))

				visible: root.packet >= 0 && spark.t >= 0 && spark.t <= 1
				x: spark.at.x - width / 2
				y: spark.at.y - height / 2
				width: spark.index === 0 ? 8 : 6 - spark.index * 0.6
				height: width
				radius: width / 2
				color: spark.index === 0 ? "white" : Theme.primary
				opacity: 1 - spark.index / 7
			}
		}
	}

	// ── the moon (this PC, Moonlight) ────────────────────────────────────────
	Canvas {
		id: moonArt

		x: root.moon.x - 30
		y: root.moon.y - 30
		width: 60
		height: 60
		onPaint: {
			const ctx = getContext("2d");
			ctx.reset();
			ctx.fillStyle = "#e9ecf8";
			ctx.beginPath();
			ctx.arc(30, 30, 22, 0, Math.PI * 2);
			ctx.fill();
			ctx.globalCompositeOperation = "destination-out";
			ctx.beginPath();
			ctx.arc(40, 22, 19, 0, Math.PI * 2);
			ctx.fill();
		}
		opacity: 0.95 - 0.35 * root.dawn

		Rectangle {
			anchors.centerIn: parent
			width: 70
			height: 70
			radius: 35
			color: "transparent"
			border.width: 1.5
			border.color: Theme.primary
			opacity: root.beam
		}
	}

	// a point on the packet's way (two quadratic halves)
	function along(t) {
		const a = Qt.point(root.moon.x + 22, root.moon.y - 8);
		const c1 = Qt.point((root.moon.x + root.relay.x) / 2, 8);
		const b = root.relay;
		const c2 = Qt.point(root.target.x - 10, root.relay.y - 10);
		const e = Qt.point(root.target.x, root.target.y - 40);
		const quad = (p0, c, p1, u) => Qt.point((1 - u) * (1 - u) * p0.x + 2 * (1 - u) * u * c.x + u * u * p1.x, (1 - u) * (1 - u) * p0.y + 2 * (1 - u) * u * c.y + u * u * p1.y);
		return t < 0.5 ? quad(a, c1, b, t * 2) : quad(b, c2, e, (t - 0.5) * 2);
	}

	Rectangle {
		id: frame

		anchors.fill: parent
		radius: 28
		visible: false
		layer.enabled: true
	}
}
