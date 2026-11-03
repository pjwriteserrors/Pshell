pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Shapes
import qs.style.theme
import qs.style.widgets

// The AS50, live: both cups as loud as the headset's own volume, the
// microphone in the right cup glowing with the voice, and the right cup's
// side as it is – the power switch, −, ⏯ and + (lighting up as they are
// pressed, pickable) and the lamp (blue while connected). The battery sits
// on the headband.
Item {
	id: root

	property bool online: true
	// 0..1, the headset's own volume
	property real volume: 0
	property bool muted: false
	// dBFS, −90 when nothing listens; the mic only exists while it is on
	property real level: -90
	property bool micOn: false
	property bool micMuted: false
	property var battery: null
	// "play" | "next" | "previous" -> held; the last volume step (+1 / −1) flashes its key
	property var keys: ({})
	property int nudge: 0
	property string selected: ""

	signal picked(string control)

	readonly property real drawScale: Math.min(width / 440, height / 270)
	readonly property real glow: !root.micOn || root.micMuted ? 0 : Math.max(0, Math.min(1, (root.level + 62) / 42))

	implicitWidth: 440
	implicitHeight: 270
	opacity: root.online ? 1 : 0.45

	Behavior on opacity {
		Anim {
			duration: Motion.long
		}
	}

	Item {
		id: canvas

		width: 440
		height: 270
		anchors.centerIn: parent
		scale: root.drawScale

		Shape {
			anchors.fill: parent
			preferredRendererType: Shape.CurveRenderer

			// the headband
			ShapePath {
				strokeWidth: 16
				strokeColor: Theme.layer3
				fillColor: "transparent"
				capStyle: ShapePath.RoundCap

				PathSvg {
					path: "M 52 140 C 52 26 238 26 238 140"
				}
			}

			ShapePath {
				strokeWidth: 3
				strokeColor: Qt.alpha(Theme.text, 0.12)
				fillColor: "transparent"
				capStyle: ShapePath.RoundCap

				PathSvg {
					path: "M 62 128 C 66 44 224 44 228 128"
				}
			}

			// from the right cup to its side, drawn larger
			ShapePath {
				strokeWidth: 1.5
				strokeColor: Qt.alpha(Theme.text, 0.18)
				fillColor: "transparent"
				dashPattern: [3, 4]
				strokeStyle: ShapePath.DashLine

				PathSvg {
					path: "M 262 150 L 300 130 M 262 214 L 300 236"
				}
			}
		}

		// the battery, on the headband
		Rectangle {
			x: 121
			y: 22
			width: 48
			height: 20
			radius: 6
			visible: root.battery !== null
			color: Theme.layer2
			border.width: 1.5
			border.color: Qt.alpha(Theme.text, 0.2)

			Rectangle {
				x: 3
				y: 3
				height: parent.height - 6
				width: (parent.width - 6) * Math.max(0, Math.min(1, (root.battery ?? 0) / 100))
				radius: 3
				color: (root.battery ?? 100) <= 20 ? Theme.danger : Theme.primary
				opacity: 0.75

				Behavior on width {
					Anim {
						duration: Motion.medium
					}
				}
			}

			StyledText {
				anchors.centerIn: parent
				text: `${root.battery ?? 0}`
				font.pixelSize: 11
				font.weight: Font.DemiBold
			}
		}

		// the cups, from the front
		Repeater {
			model: [{ x: 18, side: "L" }, { x: 202, side: "R" }]

			delegate: Rectangle {
				id: cup

				required property var modelData

				x: cup.modelData.x
				y: 118
				width: 70
				height: 112
				radius: 32
				color: Theme.layer2
				border.width: 1.5
				border.color: Qt.alpha(Theme.text, 0.14)

				Rectangle {
					anchors.centerIn: parent
					width: 48
					height: 88
					radius: 24
					color: Theme.primary
					opacity: root.muted || !root.online ? 0.05 : 0.12 + 0.55 * root.volume

					Behavior on opacity {
						Anim {
							duration: Motion.medium
						}
					}
				}

				StyledText {
					anchors.centerIn: parent
					text: cup.modelData.side
					font.weight: Font.DemiBold
					tone: Theme.textMuted
				}
			}
		}

		// the right cup's side
		Rectangle {
			id: side

			x: 300
			y: 104
			width: 128
			height: 156
			radius: 60
			color: Theme.layer2
			border.width: 1.5
			border.color: Qt.alpha(Theme.text, 0.14)

			// the microphone, built in
			Rectangle {
				x: 18
				y: 62
				width: 14
				height: 14
				radius: 7
				color: root.micMuted && root.micOn ? Theme.dangerContainer : Qt.tint(Theme.layer3, Qt.alpha(Theme.primary, root.glow))
				border.width: 1
				border.color: Qt.alpha(Theme.text, 0.18)
				opacity: root.micOn ? 1 : 0.4

				Rectangle {
					anchors.centerIn: parent
					width: 14 + 24 * root.glow
					height: width
					radius: width / 2
					color: "transparent"
					border.width: 2
					border.color: Theme.primary
					opacity: root.glow * 0.5
				}
			}

			// the power switch
			Rectangle {
				x: 44
				y: 14
				width: 40
				height: 16
				radius: 8
				color: Theme.layer3

				Rectangle {
					x: root.online ? parent.width - width - 2 : 2
					y: 2
					width: 18
					height: 12
					radius: 6
					color: root.online ? Theme.primary : Theme.textFaint

					Behavior on x {
						Anim {
							duration: Motion.short
						}
					}
				}
			}

			// −, ⏯, +
			Repeater {
				model: [
					{ control: "previous", label: "−", y: 38, volume: -1 },
					{ control: "play", label: "⏯", y: 78, volume: 0 },
					{ control: "next", label: "+", y: 118, volume: 1 }
				]

				delegate: Clickable {
					id: key

					required property var modelData
					readonly property bool held: root.keys[key.modelData.control] === true || (key.modelData.volume !== 0 && root.nudge === key.modelData.volume)

					x: 50
					y: key.modelData.y - 4
					width: 60
					height: 34
					radius: 17
					color: key.held ? Theme.primary : (root.selected === key.modelData.control ? Theme.primaryContainer : Theme.layer3)
					onClicked: root.picked(key.modelData.control)

					Behavior on color {
						ColorAnim {
							duration: Motion.short
						}
					}

					StyledText {
						anchors.centerIn: parent
						text: key.modelData.label
						font.pixelSize: key.modelData.volume === 0 ? 17 : 22
						font.weight: Font.DemiBold
						tone: key.held ? Theme.onPrimary : Theme.text
					}
				}
			}

			// the lamp: blue while connected
			Rectangle {
				x: 98
				y: 22
				width: 10
				height: 10
				radius: 5
				color: root.online ? "#3d7bff" : Theme.layer3
				border.width: 1
				border.color: Qt.alpha(Theme.text, 0.18)

				Behavior on color {
					ColorAnim {}
				}
			}
		}
	}
}
