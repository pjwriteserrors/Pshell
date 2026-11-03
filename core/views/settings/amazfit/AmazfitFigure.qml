import QtQuick
import qs.style.theme
import qs.style.widgets

// The watch, drawn: the Active 2 Square's rounded case with its two crowns,
// the time it says, its battery as a ring around the screen, the heart rate
// beating while the watch shares it, and the keys it sends lighting up.
Item {
	id: root

	property bool online: false
	property var battery: null
	property bool charging: false
	property int hr: 0
	property string time: ""
	property var keys: ({})
	property string zepp: "idle"

	implicitWidth: 300
	implicitHeight: 280

	readonly property real caseW: Math.min(root.width * 0.5, root.height * 0.82 * 390 / 450)
	readonly property real caseH: root.caseW * 450 / 390

	// the strap
	Rectangle {
		anchors.horizontalCenter: watchCase.horizontalCenter
		width: root.caseW * 0.62
		height: root.height
		radius: width * 0.3
		color: Theme.layer2
		opacity: 0.7
	}

	// the crowns
	Repeater {
		model: 2

		delegate: Rectangle {
			required property int index

			x: watchCase.x + watchCase.width - 3
			y: watchCase.y + watchCase.height * (index === 0 ? 0.26 : 0.62)
			width: 9
			height: watchCase.height * 0.12
			radius: 4
			color: (index === 0 ? root.keys.play : root.keys.volup) ? Theme.primary : Theme.layer3

			Behavior on color {
				ColorAnim {}
			}
		}
	}

	Rectangle {
		id: watchCase

		anchors.centerIn: parent
		width: root.caseW
		height: root.caseH
		radius: width * 0.28
		color: Theme.layer3
		border.width: 2
		border.color: Theme.outline

		Rectangle {
			id: screen

			anchors.fill: parent
			anchors.margins: parent.width * 0.06
			radius: parent.radius * 0.82
			color: root.online ? "#08090b" : Theme.layer2

			Behavior on color {
				ColorAnim {}
			}

			// the battery around the screen
			Ring {
				anchors.centerIn: parent
				width: Math.min(parent.width, parent.height) * 0.86
				height: width
				value: root.battery === null ? 0 : root.battery / 100
				thickness: 5
				color: root.charging ? Theme.success : (root.battery !== null && root.battery <= 15 ? Theme.danger : Theme.primary)
				opacity: root.online ? 0.9 : 0.25
			}

			Column {
				anchors.centerIn: parent
				spacing: 2

				StyledText {
					anchors.horizontalCenter: parent.horizontalCenter
					text: root.online ? root.time : "—"
					font.pixelSize: screen.width * 0.2
					font.weight: Font.DemiBold
					color: root.online ? "white" : Theme.textFaint
				}

				Row {
					anchors.horizontalCenter: parent.horizontalCenter
					spacing: 4
					visible: root.online

					Glyph {
						id: heart

						icon: "heart"
						size: screen.width * 0.09
						color: root.hr > 0 ? "#ff5a6e" : "#5a5f66"

						SequentialAnimation on scale {
							running: root.hr > 0
							loops: Animation.Infinite

							NumberAnimation {
								to: 1.25
								duration: 90
							}

							NumberAnimation {
								to: 1
								duration: Math.max(150, 60000 / Math.max(root.hr, 30) - 90)
							}
						}
					}

					StyledText {
						text: root.hr > 0 ? `${root.hr}` : (root.battery !== null ? `${root.battery} %` : "")
						font.pixelSize: screen.width * 0.08
						color: "#d0d4da"
					}
				}

				StyledText {
					anchors.horizontalCenter: parent.horizontalCenter
					visible: root.online
					text: root.zepp === "ready" ? "Zepp OS" : (root.zepp === "nokey" ? "GATT only" : root.zepp)
					font.pixelSize: screen.width * 0.06
					color: root.zepp === "ready" ? "#8fd18f" : "#8a8f96"
				}
			}
		}
	}

	// the keys it sends, around the case
	Row {
		anchors.bottom: parent.bottom
		anchors.horizontalCenter: parent.horizontalCenter
		spacing: 6

		Repeater {
			model: [["previous", "skip_previous"], ["play", "play_pause"], ["next", "skip_next"], ["voldown", "volume_minus"], ["volup", "volume_plus"], ["mute", "volume_off"], ["keyboard", "keyboard"]]

			delegate: Rectangle {
				required property var modelData

				width: 26
				height: 26
				radius: 13
				color: root.keys[modelData[0]] ? Theme.primary : Theme.layer2
				scale: root.keys[modelData[0]] ? 1.15 : 1

				Behavior on color {
					ColorAnim {}
				}

				Behavior on scale {
					Anim {}
				}

				Glyph {
					anchors.centerIn: parent
					icon: parent.modelData[1]
					size: 14
					color: root.keys[parent.modelData[0]] ? Theme.onPrimary : Theme.textMuted
				}
			}
		}
	}
}
