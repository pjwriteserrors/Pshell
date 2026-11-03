pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Shapes
import qs.style.theme
import qs.style.widgets

// The PC 8.2 USB, live: the cups as loud as their channel, the boom's
// capsule glowing with the microphone, the remote on the cable with its
// two buttons lighting up as they are pressed and its lamp red while the
// switch has muted the microphone. The buttons can be picked.
Item {
	id: root

	property bool online: true
	// 0..1 per channel
	property real leftLevel: 1
	property real rightLevel: 1
	property bool muted: false
	// dBFS, −90 when nothing listens
	property real level: -90
	property bool micMuted: false
	property bool cableMuted: false
	property bool sidetone: true
	// "up" | "down" -> held
	property var keys: ({})
	property string selected: ""

	signal picked(string control)

	readonly property real drawScale: Math.min(width / 420, height / 270)
	readonly property real glow: root.micMuted || root.cableMuted ? 0 : Math.max(0, Math.min(1, (root.level + 62) / 42))

	implicitWidth: 420
	implicitHeight: 270
	opacity: root.online ? 1 : 0.45

	Behavior on opacity {
		Anim {
			duration: Motion.long
		}
	}

	Item {
		id: canvas

		width: 420
		height: 270
		anchors.centerIn: parent
		scale: root.drawScale

		Shape {
			anchors.fill: parent
			preferredRendererType: Shape.CurveRenderer

			// the headband
			ShapePath {
				strokeWidth: 14
				strokeColor: Theme.layer3
				fillColor: "transparent"
				capStyle: ShapePath.RoundCap

				PathSvg {
					path: "M 62 132 C 62 30 238 30 238 132"
				}
			}

			ShapePath {
				strokeWidth: 3
				strokeColor: Qt.alpha(Theme.text, 0.12)
				fillColor: "transparent"
				capStyle: ShapePath.RoundCap

				PathSvg {
					path: "M 70 120 C 74 46 226 46 230 120"
				}
			}

			// the boom, from the left cup to the mouth
			ShapePath {
				strokeWidth: 5
				strokeColor: Theme.layer3
				fillColor: "transparent"
				capStyle: ShapePath.RoundCap

				PathSvg {
					path: "M 64 196 C 74 236 116 246 150 238"
				}
			}

			// the cable to the remote
			ShapePath {
				strokeWidth: 2.5
				strokeColor: Qt.alpha(Theme.text, 0.22)
				fillColor: "transparent"

				PathSvg {
					path: "M 52 214 C 46 262 210 262 250 220 C 290 180 318 196 342 196"
				}
			}
		}

		// the cups
		Repeater {
			model: [{ x: 30, side: "L", v: root.leftLevel }, { x: 206, side: "R", v: root.rightLevel }]

			delegate: Rectangle {
				id: cup

				required property var modelData

				x: cup.modelData.x
				y: 116
				width: 64
				height: 100
				radius: 30
				color: Theme.layer2
				border.width: 1.5
				border.color: Qt.alpha(Theme.text, 0.14)

				Rectangle {
					anchors.centerIn: parent
					width: 44
					height: 78
					radius: 22
					color: Theme.primary
					opacity: root.muted ? 0.05 : 0.12 + 0.55 * cup.modelData.v

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

		// the microphone's capsule
		Rectangle {
			x: 144
			y: 228
			width: 22
			height: 16
			radius: 8
			color: root.micMuted || root.cableMuted ? Theme.dangerContainer : Qt.tint(Theme.layer3, Qt.alpha(Theme.primary, root.glow))
			border.width: 1.5
			border.color: Qt.alpha(Theme.text, 0.16)

			Rectangle {
				anchors.centerIn: parent
				width: 22 + 26 * root.glow
				height: width
				radius: width / 2
				color: "transparent"
				border.width: 2
				border.color: Theme.primary
				opacity: root.glow * 0.5
			}

			// the voice back into the cup: the sidetone
			Glyph {
				anchors.left: parent.right
				anchors.leftMargin: 4
				anchors.verticalCenter: parent.verticalCenter
				icon: "account_voice"
				size: 14
				color: root.sidetone ? Theme.textMuted : Theme.textFaint
				opacity: root.sidetone ? 1 : 0.4
			}
		}

		// the remote
		Rectangle {
			id: remote

			x: 342
			y: 108
			width: 52
			height: 150
			radius: 26
			color: Theme.layer2
			border.width: 1.5
			border.color: Qt.alpha(Theme.text, 0.14)

			Repeater {
				model: [{ control: "up", label: "+", y: 8 }, { control: "down", label: "−", y: 94 }]

				delegate: Clickable {
					id: key

					required property var modelData
					readonly property bool held: root.keys[key.modelData.control] === true

					x: 4
					y: key.modelData.y
					width: 44
					height: 48
					radius: 22
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
						font.pixelSize: 24
						font.weight: Font.DemiBold
						tone: key.held ? Theme.onPrimary : Theme.text
					}
				}
			}

			// the mute switch's lamp
			Rectangle {
				anchors.horizontalCenter: parent.horizontalCenter
				y: 68
				width: 12
				height: 12
				radius: 6
				color: root.cableMuted ? Theme.danger : Theme.layer3
				border.width: 1
				border.color: Qt.alpha(Theme.text, 0.18)

				Behavior on color {
					ColorAnim {}
				}
			}
		}
	}
}
