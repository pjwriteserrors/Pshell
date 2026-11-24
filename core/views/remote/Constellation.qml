import QtQuick
import QtQuick.Shapes
import qs.style.theme
import qs.style.widgets

// The steps of a wake as a constellation along a gentle arc: each step a
// star that lights when it is reached, the line between them drawn as far
// as the journey got. A step this wake skips stays a dim ring.
// stations: [{ icon, title, detail, state: "idle"|"active"|"done"|"failed"|"skip" }]
Item {
	id: root

	property var stations: []
	// how far the line is drawn, in stations (0 … n-1)
	property real progress: 0
	property bool active: true

	implicitWidth: 720
	implicitHeight: 112

	Behavior on progress {
		SpatialAnim {
			duration: Motion.long * 2
		}
	}

	readonly property int count: root.stations.length
	function px(i) {
		return root.count < 2 ? root.width / 2 : 46 + i * (root.width - 92) / (root.count - 1);
	}
	function py(i) {
		const u = root.count < 2 ? 0.5 : i / (root.count - 1);
		return 30 - Math.sin(u * Math.PI) * 14;
	}

	// the whole way, faint
	Shape {
		anchors.fill: parent
		preferredRendererType: Shape.CurveRenderer

		ShapePath {
			strokeColor: Qt.rgba(1, 1, 1, 0.1)
			strokeWidth: 1.5
			fillColor: "transparent"
			strokeStyle: ShapePath.DashLine
			dashPattern: [2, 4]
			startX: root.px(0)
			startY: root.py(0)
			PathPolyline {
				path: Array.from({ length: root.count }, (_, i) => Qt.point(root.px(i), root.py(i)))
			}
		}

		// the way gone, lit
		ShapePath {
			strokeColor: Theme.primary
			strokeWidth: 2
			fillColor: "transparent"
			capStyle: ShapePath.RoundCap
			startX: root.px(0)
			startY: root.py(0)
			PathPolyline {
				path: {
					const out = [];
					const reach = Math.max(0, Math.min(root.count - 1, root.progress));
					for (let i = 0; i <= Math.floor(reach); i++) out.push(Qt.point(root.px(i), root.py(i)));
					const frac = reach - Math.floor(reach);
					if (frac > 0 && Math.floor(reach) + 1 < root.count) {
						const a = Math.floor(reach);
						out.push(Qt.point(root.px(a) + (root.px(a + 1) - root.px(a)) * frac, root.py(a) + (root.py(a + 1) - root.py(a)) * frac));
					}
					return out;
				}
			}
		}
	}

	Repeater {
		model: root.stations

		delegate: Item {
			id: station

			required property var modelData
			required property int index
			readonly property string state: station.modelData.state
			readonly property bool lit: station.state === "done" || station.state === "active"

			x: root.px(station.index) - 60
			y: root.py(station.index) - 16
			width: 120
			height: root.height

			// the star
			Item {
				id: star

				anchors.horizontalCenter: parent.horizontalCenter
				width: 32
				height: 32

				Rectangle {
					id: flare

					property real pulse: 0

					anchors.centerIn: parent
					width: 32 + 22 * flare.pulse
					height: width
					radius: width / 2
					color: station.state === "failed" ? Theme.danger : Theme.primary
					opacity: station.state === "active" ? 0.35 * (1 - flare.pulse) : 0

					NumberAnimation on pulse {
						running: root.active && station.state === "active"
						loops: Animation.Infinite
						from: 0
						to: 1
						duration: 1400
						easing.type: Easing.OutCubic
					}
				}

				Rectangle {
					anchors.centerIn: parent
					width: station.state === "skip" ? 22 : 30
					height: width
					radius: width / 2
					color: {
						if (station.state === "failed") return Qt.alpha(Theme.danger, 0.3);
						if (station.state === "done") return Theme.primary;
						if (station.state === "active") return Qt.alpha(Theme.primary, 0.3);
						return Qt.rgba(1, 1, 1, station.state === "skip" ? 0 : 0.06);
					}
					border.width: station.state === "done" ? 0 : 1.5
					border.color: {
						if (station.state === "failed") return Theme.danger;
						if (station.state === "active") return Theme.primary;
						return Qt.rgba(1, 1, 1, station.state === "skip" ? 0.12 : 0.24);
					}

					Behavior on color {
						ColorAnim {}
					}
					Behavior on width {
						SpatialAnim {
							duration: Motion.medium
						}
					}

					Glyph {
						anchors.centerIn: parent
						icon: station.state === "done" ? "check_bold" : station.modelData.icon
						size: station.state === "skip" ? 11 : 15
						color: station.state === "done" ? Theme.onPrimary : (station.state === "failed" ? Theme.danger : (station.lit ? "white" : Qt.rgba(1, 1, 1, station.state === "skip" ? 0.25 : 0.55)))
						surface: "transparent"
					}
				}
			}

			StyledText {
				id: title

				anchors.horizontalCenter: parent.horizontalCenter
				anchors.top: star.bottom
				anchors.topMargin: 8
				text: station.modelData.title
				tone: station.lit || station.state === "failed" ? "white" : Qt.rgba(1, 1, 1, station.state === "skip" ? 0.3 : 0.6)
				surface: "transparent"
				font.pixelSize: Theme.size.small
				font.weight: Font.DemiBold
			}

			StyledText {
				anchors.horizontalCenter: parent.horizontalCenter
				anchors.top: title.bottom
				anchors.topMargin: 2
				width: parent.width
				horizontalAlignment: Text.AlignHCenter
				elide: Text.ElideRight
				text: station.modelData.detail ?? ""
				tone: station.state === "failed" ? Theme.danger : Qt.rgba(1, 1, 1, 0.45)
				surface: "transparent"
				font.pixelSize: Theme.size.tiny
			}
		}
	}
}
