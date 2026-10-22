pragma ComponentBehavior: Bound

import QtQuick
import QtMultimedia
import Quickshell
import qs.style.theme
import qs.core.services
import qs.style.widgets

// A picture of a mail, large, over all of Messages: as big as it is or as
// there is room for. From here it goes to the clipboard, into the downloads
// or to the program that shows pictures. A click beside it or Escape closes.
// A video is played here the same way: a click or Space holds and resumes it,
// the bar under it goes to another moment.
Rectangle {
	id: root

	readonly property string source: Mail.picture
	readonly property bool open: root.source !== ""
	// the picture that is shown stays while the view fades out
	property string shown: ""
	property bool copied: false
	readonly property bool video: /\.(mp4|m4v|mov|webm|mkv|3gp)$/i.test(root.shown)

	onSourceChanged: {
		if (root.source !== "") root.shown = root.source;
		root.copied = false;
	}

	color: Qt.rgba(0, 0, 0, 0.88)
	opacity: root.open ? 1 : 0
	visible: opacity > 0.01

	Behavior on opacity {
		Anim {
			duration: Motion.short
		}
	}

	Connections {
		target: Mail
		function onPictureCopied() {
			root.copied = true;
			uncopy.restart();
		}
	}

	Timer {
		id: uncopy

		interval: 1600
		onTriggered: root.copied = false
	}

	// beside the picture: back to the chat
	MouseArea {
		anchors.fill: parent
		acceptedButtons: Qt.AllButtons
		hoverEnabled: true
		onClicked: Mail.picture = ""
		onWheel: wheel => wheel.accepted = true
	}

	Image {
		id: picture

		readonly property real room: Math.min(1, (root.width - 48) / Math.max(1, implicitWidth), (root.height - 120) / Math.max(1, implicitHeight))

		anchors.centerIn: parent
		anchors.verticalCenterOffset: 22
		width: implicitWidth * room
		height: implicitHeight * room
		source: root.shown === "" || root.video ? "" : (root.shown.startsWith("/") ? `file://${root.shown}` : root.shown)
		asynchronous: true
		cache: false
		smooth: true
		mipmap: true
		scale: root.open ? 1 : 0.96

		Behavior on scale {
			SpatialAnim {
				duration: Motion.medium
			}
		}

		// a click on the picture is none beside it
		MouseArea {
			anchors.fill: parent
		}
	}

	// a video, while it is looked at
	Loader {
		id: film

		anchors.fill: parent
		active: root.open && root.video
		sourceComponent: Item {
			id: screen

			readonly property bool playing: player.playbackState === MediaPlayer.PlayingState
			readonly property real room: Math.min((screen.width - 48) / Math.max(1, output.sourceRect.width), (screen.height - 190) / Math.max(1, output.sourceRect.height))

			function toggle() {
				if (screen.playing) player.pause();
				else player.play();
			}

			MediaPlayer {
				id: player

				source: `file://${root.shown}`
				videoOutput: output
				audioOutput: AudioOutput {
					id: sound
				}
				Component.onCompleted: play()
				// at its end it starts over with the next click
				onPlaybackStateChanged: if (playbackState === MediaPlayer.StoppedState && position > 0) position = 0
			}

			VideoOutput {
				id: output

				anchors.centerIn: parent
				anchors.verticalCenterOffset: -8
				width: Math.round(output.sourceRect.width * screen.room)
				height: Math.round(output.sourceRect.height * screen.room)

				MouseArea {
					anchors.fill: parent
					cursorShape: Qt.PointingHandCursor
					onClicked: screen.toggle()
				}

				Rectangle {
					anchors.centerIn: parent
					width: 64
					height: 64
					radius: 32
					color: Qt.rgba(0, 0, 0, 0.55)
					opacity: screen.playing ? 0 : 1
					scale: screen.playing ? 1.3 : 1

					Behavior on opacity {
						Anim {
							duration: Motion.short
						}
					}
					Behavior on scale {
						SpatialAnim {
							duration: Motion.medium
						}
					}

					Glyph {
						anchors.centerIn: parent
						icon: "play"
						size: 32
						color: "white"
						surface: "transparent"
					}
				}
			}

			EmptyState {
				anchors.centerIn: parent
				visible: player.error !== MediaPlayer.NoError
				icon: "alert_circle"
				title: "The video cannot be played"
			}

			Rectangle {
				anchors.horizontalCenter: parent.horizontalCenter
				anchors.bottom: parent.bottom
				anchors.bottomMargin: 18
				width: Math.min(560, parent.width - 48)
				height: 48
				radius: 24
				color: Theme.layer1

				// a click on the bar is none beside the video
				MouseArea {
					anchors.fill: parent
				}

				IconButton {
					id: hold

					x: 6
					anchors.verticalCenter: parent.verticalCenter
					implicitWidth: 36
					implicitHeight: 36
					icon: screen.playing ? "pause" : "play"
					variant: "filled"
					onClicked: screen.toggle()
				}

				StyledText {
					id: passed

					anchors.left: hold.right
					anchors.leftMargin: 10
					anchors.verticalCenter: parent.verticalCenter
					width: 38
					text: Format.clock(Math.floor(player.position / 1000))
					tone: Theme.textMuted
					tabular: true
					font.pixelSize: Theme.size.label
				}

				Item {
					id: track

					anchors.left: passed.right
					anchors.right: whole.left
					anchors.margins: 8
					anchors.verticalCenter: parent.verticalCenter
					height: 24

					Rectangle {
						anchors.verticalCenter: parent.verticalCenter
						width: parent.width
						height: seek.containsMouse || seek.pressed ? 6 : 4
						radius: height / 2
						color: Qt.alpha(Theme.text, 0.14)

						Behavior on height {
							SpatialAnim {
								duration: Motion.short
							}
						}

						Rectangle {
							width: parent.width * (player.duration > 0 ? Math.min(1, player.position / player.duration) : 0)
							height: parent.height
							radius: parent.radius
							color: Theme.primary
						}
					}

					MouseArea {
						id: seek

						anchors.fill: parent
						hoverEnabled: true
						cursorShape: Qt.PointingHandCursor
						function go(x) {
							if (player.duration > 0) player.position = player.duration * Math.max(0, Math.min(1, x / width));
						}
						onPressed: event => seek.go(event.x)
						onPositionChanged: event => {
							if (pressed) seek.go(event.x);
						}
					}
				}

				StyledText {
					id: whole

					anchors.right: mute.left
					anchors.rightMargin: 4
					anchors.verticalCenter: parent.verticalCenter
					text: Format.clock(Math.floor(player.duration / 1000))
					tone: Theme.textMuted
					tabular: true
					font.pixelSize: Theme.size.label
				}

				IconButton {
					id: mute

					anchors.right: parent.right
					anchors.rightMargin: 6
					anchors.verticalCenter: parent.verticalCenter
					implicitWidth: 36
					implicitHeight: 36
					icon: sound.muted ? "volume_off" : "volume_high"
					onClicked: sound.muted = !sound.muted
				}
			}

			Shortcut {
				sequence: "Space"
				onActivated: screen.toggle()
			}
		}
	}

	Spinner {
		anchors.centerIn: parent
		visible: root.open && picture.status === Image.Loading
		width: 26
		height: 26
	}

	EmptyState {
		anchors.centerIn: parent
		visible: root.open && picture.status === Image.Error
		icon: "image_outline"
		title: "The picture cannot be shown"
	}

	Row {
		anchors.top: parent.top
		anchors.right: parent.right
		anchors.margins: 12
		spacing: 6

		IconButton {
			visible: !root.video
			icon: root.copied ? "check" : "content_copy"
			variant: "tonal"
			onClicked: Mail.withPicture("copy", root.shown)
		}

		IconButton {
			visible: !root.video
			icon: "download"
			variant: "tonal"
			onClicked: Mail.withPicture("save", root.shown)
		}

		IconButton {
			icon: "open_in_new"
			variant: "tonal"
			onClicked: Qt.openUrlExternally(root.shown.startsWith("/") ? `file://${root.shown}` : root.shown)
		}

		IconButton {
			icon: "close"
			variant: "tonal"
			onClicked: Mail.picture = ""
		}
	}

	Shortcut {
		sequence: "Escape"
		enabled: root.open && root.visible
		onActivated: Mail.picture = ""
	}

	Shortcut {
		sequence: "Ctrl+C"
		enabled: root.open && root.visible && !root.video
		onActivated: Mail.withPicture("copy", root.shown)
	}
}
