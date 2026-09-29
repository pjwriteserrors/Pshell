import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.core.services
import qs.style.widgets

// Guided eye rest. A soft halo breathes, the ring runs down twenty seconds
// while the eye blinks now and then; at the end it turns into a tick and
// fades out. Any key or click ends it early.
ModalWindow {
	id: root

	property real progress: 1
	property bool done: false
	readonly property int seconds: Math.ceil(root.progress * Breaks.eyeRestSeconds)

	modalId: "eyerest"
	scrimColor: Qt.rgba(0, 0, 0, 0.8)

	onModalOpened: {
		root.done = false;
		countdown.restart();
	}

	onShownChanged: if (!root.shown) countdown.stop()

	SequentialAnimation {
		id: countdown

		NumberAnimation {
			target: root
			property: "progress"
			from: 1
			to: 0
			duration: Breaks.eyeRestSeconds * 1000
		}
		ScriptAction {
			script: root.done = true
		}
		PauseAnimation {
			duration: 1100
		}
		ScriptAction {
			script: Breaks.finishEyeRest()
		}
	}

	Item {
		anchors.fill: parent
		focus: true

		Keys.onPressed: event => {
			event.accepted = true;
			Popups.closeModal();
		}

		ColumnLayout {
			anchors.centerIn: parent
			spacing: 34

			Item {
				Layout.alignment: Qt.AlignHCenter
				Layout.preferredWidth: 300
				Layout.preferredHeight: 300

				// breathing halo: four seconds in, four out
				Rectangle {
					id: halo

					anchors.centerIn: parent
					width: 300
					height: 300
					radius: 150
					color: Qt.alpha(Theme.primary, 0.1)
					scale: 0.82

					SequentialAnimation on scale {
						running: root.shown && !root.done
						loops: Animation.Infinite

						NumberAnimation {
							to: 1
							duration: 4000
							easing.type: Easing.InOutSine
						}
						NumberAnimation {
							to: 0.82
							duration: 4000
							easing.type: Easing.InOutSine
						}
					}
				}

				Ring {
					anchors.centerIn: parent
					width: 230
					height: 230
					thickness: 6
					animated: false
					value: root.done ? 1 : root.progress
					color: root.done ? Theme.success : Theme.primary
					trackColor: Qt.rgba(1, 1, 1, 0.08)
				}

				ColumnLayout {
					anchors.centerIn: parent
					spacing: 2

					Glyph {
						id: eye

						Layout.alignment: Qt.AlignHCenter
						icon: root.done ? "check" : "eye_outline"
						size: 58
						color: root.done ? Theme.success : "white"
						surface: "transparent"
						transform: Scale {
							id: lid

							origin.x: eye.width / 2
							origin.y: eye.height / 2
						}
						scale: root.done ? 1.15 : 1

						Behavior on scale {
							SpatialAnim {
								duration: Motion.extraLong
							}
						}

						SequentialAnimation {
							running: root.shown && !root.done
							loops: Animation.Infinite

							PauseAnimation {
								duration: 3600
							}
							NumberAnimation {
								target: lid
								property: "yScale"
								to: 0.08
								duration: 90
								easing.type: Easing.InQuad
							}
							NumberAnimation {
								target: lid
								property: "yScale"
								to: 1
								duration: 160
								easing.type: Easing.OutQuad
							}
						}
					}

					StyledText {
						Layout.alignment: Qt.AlignHCenter
						text: root.seconds
						opacity: root.done ? 0 : 0.75
						tone: "white"
						surface: "transparent"
						font.pixelSize: Theme.size.display
						font.weight: Font.Light
						tabular: true

						Behavior on opacity {
							Anim {}
						}
					}
				}
			}

			StyledText {
				Layout.alignment: Qt.AlignHCenter
				text: root.done ? "Done" : "Look into the distance"
				tone: "white"
				surface: "transparent"
				font.pixelSize: 26
				font.weight: Font.DemiBold
			}
		}
	}
}
