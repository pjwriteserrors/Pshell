pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Shapes
import qs.style.theme
import qs.style.widgets

// The steps of a launch as stations on a line. A station is idle, ready
// (already so before the launch: a soft tick), active (an arc runs round
// it and a spark travels the line towards it), done, or failed (it shakes).
// The line fills up to where the launch is.
Item {
	id: root

	// [{ icon, title, detail, state }]
	property var stations: []
	// how far the line is filled, in stations (0 … count-1, fractions allowed)
	property real progress: 0
	property bool active: true

	readonly property int count: root.stations.length
	readonly property real station: 52
	readonly property real span: root.count > 1 ? (root.width - root.station - 80) / (root.count - 1) : 0

	function centerX(index) {
		return 40 + root.station / 2 + index * root.span;
	}

	implicitWidth: 560
	implicitHeight: 112

	Behavior on progress {
		NumberAnimation {
			duration: Motion.extraLong
			easing.type: Easing.BezierSpline
			easing.bezierCurve: Motion.emphasized
		}
	}

	// the line, and how far it is filled
	Rectangle {
		id: track

		x: root.centerX(0)
		y: root.station / 2 - height / 2
		width: Math.max(0, root.centerX(root.count - 1) - root.centerX(0))
		height: 3
		radius: 1.5
		color: Qt.rgba(1, 1, 1, 0.1)

		Rectangle {
			height: parent.height
			radius: parent.radius
			width: root.count > 1 ? parent.width * Math.max(0, Math.min(1, root.progress / (root.count - 1))) : 0
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

		// the spark running towards the active station
		Rectangle {
			id: spark

			readonly property int to: root.stations.findIndex(station => station.state === "active")
			property real travel: 0

			visible: spark.to > 0 && root.active
			width: 26
			height: 7
			radius: 3.5
			y: (parent.height - height) / 2
			x: spark.to > 0 ? (root.centerX(spark.to - 1) - track.x) + (root.span - root.station) * spark.travel + root.station / 2 - width / 2 : 0
			opacity: Math.sin(Math.PI * spark.travel)
			gradient: Gradient {
				orientation: Gradient.Horizontal
				GradientStop {
					position: 0
					color: Qt.alpha(Theme.primary, 0)
				}
				GradientStop {
					position: 1
					color: "white"
				}
			}

			NumberAnimation on travel {
				running: spark.visible
				loops: Animation.Infinite
				from: 0
				to: 1
				duration: 1100
				easing.type: Easing.InOutQuad
			}
		}
	}

	Repeater {
		model: root.stations

		delegate: Item {
			id: node

			required property var modelData
			required property int index
			readonly property string state: node.modelData.state
			readonly property bool lit: node.state === "done" || node.state === "active" || node.state === "ready"
			property real shake: 0

			x: root.centerX(node.index) - width / 2
			width: 150
			height: root.height

			onStateChanged: {
				if (node.state === "failed") shaking.restart();
				if (node.state === "done") pop.restart();
			}

			SequentialAnimation {
				id: shaking

				NumberAnimation {
					target: node
					property: "shake"
					to: -7
					duration: 60
				}
				NumberAnimation {
					target: node
					property: "shake"
					to: 6
					duration: 80
				}
				NumberAnimation {
					target: node
					property: "shake"
					to: -4
					duration: 80
				}
				NumberAnimation {
					target: node
					property: "shake"
					to: 2
					duration: 80
				}
				NumberAnimation {
					target: node
					property: "shake"
					to: 0
					duration: 90
				}
			}

			Item {
				id: disc

				anchors.horizontalCenter: parent.horizontalCenter
				anchors.horizontalCenterOffset: node.shake
				width: root.station
				height: root.station

				// a halo while it works
				Rectangle {
					id: halo

					property real level: 0.1

					anchors.centerIn: parent
					width: parent.width + 18
					height: width
					radius: width / 2
					color: Theme.primary
					opacity: node.state === "active" ? halo.level : 0

					Behavior on opacity {
						Anim {}
					}

					SequentialAnimation on level {
						running: node.state === "active" && root.active
						loops: Animation.Infinite

						NumberAnimation {
							to: 0.22
							duration: 900
							easing.type: Easing.InOutSine
						}
						NumberAnimation {
							to: 0.06
							duration: 900
							easing.type: Easing.InOutSine
						}
					}
				}

				Rectangle {
					id: face

					anchors.fill: parent
					radius: node.state === "done" || node.state === "failed" ? 18 : width / 2
					color: {
						switch (node.state) {
						case "done": return Theme.primary;
						case "failed": return Theme.danger;
						case "active": return Qt.tint(Theme.base, Qt.alpha(Theme.primary, 0.28));
						case "ready": return Qt.tint(Theme.base, Qt.alpha(Theme.primary, 0.16));
						default: return Qt.tint(Theme.base, Qt.rgba(1, 1, 1, 0.06));
						}
					}
					border.width: node.state === "idle" ? 1 : 0
					border.color: Qt.rgba(1, 1, 1, 0.1)

					Behavior on color {
						ColorAnim {
							duration: Motion.medium
						}
					}
					Behavior on radius {
						SpatialAnim {
							duration: Motion.medium
						}
					}

					Glyph {
						anchors.centerIn: parent
						icon: node.state === "done" ? "check_bold" : (node.state === "failed" ? "alert_circle_outline" : node.modelData.icon)
						size: 22
						color: node.state === "done" ? Theme.onPrimary : (node.state === "failed" ? Theme.bg : (node.lit ? Theme.primary : Theme.textMuted))
						surface: face.color
					}
				}

				// the arc that runs round it while it works
				Shape {
					anchors.fill: parent
					anchors.margins: -5
					visible: node.state === "active"
					preferredRendererType: Shape.CurveRenderer

					ShapePath {
						strokeColor: Theme.primary
						strokeWidth: 2.5
						fillColor: "transparent"
						capStyle: ShapePath.RoundCap

						PathAngleArc {
							id: arc

							centerX: (root.station + 10) / 2
							centerY: (root.station + 10) / 2
							radiusX: (root.station + 10) / 2 - 1.5
							radiusY: radiusX
							startAngle: 0
							sweepAngle: 80
						}
					}

					RotationAnimation on rotation {
						running: node.state === "active" && root.active
						loops: Animation.Infinite
						from: 0
						to: 360
						duration: 1100
					}
				}

				// a small tick on a station that is ready before the launch
				Rectangle {
					anchors.right: parent.right
					anchors.bottom: parent.bottom
					anchors.margins: -2
					width: 18
					height: 18
					radius: 9
					color: Theme.primary
					scale: node.state === "ready" ? 1 : 0
					border.width: 2
					border.color: Theme.base

					Behavior on scale {
						SpatialAnim {
							duration: Motion.medium
						}
					}

					Glyph {
						anchors.centerIn: parent
						icon: "check_bold"
						size: 10
						color: Theme.onPrimary
						surface: Theme.primary
						animated: false
					}
				}

				ParallelAnimation {
					id: pop

					SequentialAnimation {
						NumberAnimation {
							target: disc
							property: "scale"
							to: 1.16
							duration: 140
							easing.type: Easing.OutCubic
						}
						NumberAnimation {
							target: disc
							property: "scale"
							to: 1
							duration: 480
							easing.type: Easing.BezierSpline
							easing.bezierCurve: Motion.spatial
						}
					}
					SequentialAnimation {
						ScriptAction {
							script: burst.visible = true
						}
						NumberAnimation {
							target: burst
							property: "scale"
							from: 1
							to: 1.9
							duration: 600
							easing.type: Easing.OutCubic
						}
						ScriptAction {
							script: burst.visible = false
						}
					}
				}

				Rectangle {
					id: burst

					anchors.centerIn: parent
					width: parent.width
					height: width
					radius: width / 2
					visible: false
					color: "transparent"
					border.width: 2
					border.color: Theme.primary
					opacity: 2 - burst.scale
				}
			}

			Column {
				anchors.horizontalCenter: parent.horizontalCenter
				y: root.station + 12
				width: parent.width
				spacing: 2

				StyledText {
					width: parent.width
					horizontalAlignment: Text.AlignHCenter
					text: node.modelData.title
					tone: node.state === "idle" ? Qt.rgba(1, 1, 1, 0.6) : "white"
					surface: "transparent"
					font.pixelSize: Theme.size.body
					font.weight: Font.DemiBold
				}

				// the detail changes with a little slide
				Item {
					width: parent.width
					height: detail.implicitHeight

					StyledText {
						id: detail

						property string shown: node.modelData.detail

						width: parent.width
						horizontalAlignment: Text.AlignHCenter
						text: detail.shown
						tone: node.state === "failed" ? Theme.danger : Qt.rgba(1, 1, 1, 0.5)
						surface: "transparent"
						font.pixelSize: Theme.size.small

						onShownChanged: swap.restart()

						transform: Translate {
							id: slide
						}

						ParallelAnimation {
							id: swap

							NumberAnimation {
								target: detail
								property: "opacity"
								from: 0
								to: 1
								duration: Motion.medium
							}
							NumberAnimation {
								target: slide
								property: "y"
								from: 6
								to: 0
								duration: Motion.long
								easing.type: Easing.BezierSpline
								easing.bezierCurve: Motion.spatial
							}
						}
					}
				}
			}
		}
	}
}
