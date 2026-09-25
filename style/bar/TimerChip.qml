import QtQuick
import qs.style.theme
import qs.core.services
import qs.style.widgets

// qtrack live activity. Tracking: a tinted capsule with a breathing dot,
// the running clock and the project. Paused: muted capsule. Idle: a quiet
// "Track" affordance. Always present so the timer is never out of sight.
BarButton {
	id: root

	readonly property bool live: Tmpo.tracking
	readonly property bool held: !Tmpo.tracking && Tmpo.paused
	// width without the project name, and what the name would add
	readonly property real fixedWidth: root.padding * 2 + 22 + 14 + (duration.visible ? 7 + duration.implicitWidth : 0)
	readonly property real textWant: 7 + Math.min(170, project.implicitWidth)
	// extra width the bar can spare for the name
	property real room: 1e6

	panelId: "timer"
	tooltip: Tmpo.tracking ? `${Tmpo.project} — ${Tmpo.description}` : (Tmpo.paused ? "Timer paused · click to resume" : "Start a timer")
	padding: 6
	onClicked: toggle()
	onMiddleClicked: {
		if (Tmpo.tracking) Tmpo.pause();
		else if (Tmpo.canResume || Tmpo.paused) Tmpo.resume();
	}

	Rectangle {
		anchors.verticalCenter: parent.verticalCenter
		height: 26
		width: content.implicitWidth + 22
		radius: 13
		color: root.live ? Theme.primaryContainer : (root.held ? Theme.layer2 : "transparent")

		Behavior on width {
			SpatialAnim {
				duration: Motion.medium
			}
		}
		Behavior on color {
			ColorAnim {
				duration: Motion.medium
			}
		}

		Row {
			id: content

			anchors.centerIn: parent
			spacing: 7

			Item {
				anchors.verticalCenter: parent.verticalCenter
				width: 14
				height: 14

				Rectangle {
					id: dot

					anchors.centerIn: parent
					visible: root.live
					width: 8
					height: 8
					radius: 4
					color: Theme.primary
				}

				Rectangle {
					anchors.centerIn: parent
					visible: root.live
					width: 8
					height: 8
					radius: width / 2
					color: "transparent"
					border.width: 1.5
					border.color: Theme.primary

					SequentialAnimation on scale {
						running: root.live
						loops: Animation.Infinite
						NumberAnimation {
							from: 1
							to: 2.3
							duration: 1400
							easing.type: Easing.OutCubic
						}
						PauseAnimation {
							duration: 2600
						}
					}
					SequentialAnimation on opacity {
						running: root.live
						loops: Animation.Infinite
						NumberAnimation {
							from: 0.9
							to: 0
							duration: 1400
							easing.type: Easing.OutCubic
						}
						PauseAnimation {
							duration: 2600
						}
					}
				}

				Glyph {
					anchors.centerIn: parent
					visible: !root.live
					icon: root.held ? "pause_circle" : "timer_outline"
					size: 15
					color: root.held ? Theme.textMuted : Theme.textSubtle
				}
			}

			StyledText {
				id: duration

				anchors.verticalCenter: parent.verticalCenter
				visible: root.live || root.held
				text: Tmpo.duration || "--"
				tabular: true
				font.pixelSize: Theme.size.body
				font.weight: Font.Bold
				tone: root.live ? Theme.text : Theme.textMuted
			}

			StyledText {
				id: project

				anchors.verticalCenter: parent.verticalCenter
				visible: width > 0
				width: root.room >= 7 + 40 ? Math.min(implicitWidth, 170, root.room - 7) : 0
				text: root.live || root.held ? (Tmpo.project || "No project") : "Track"
				font.pixelSize: Theme.size.label
				font.weight: Font.Medium
				tone: root.live ? Theme.textMuted : Theme.textSubtle
			}
		}
	}
}
