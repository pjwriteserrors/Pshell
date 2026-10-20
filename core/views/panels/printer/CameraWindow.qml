pragma ComponentBehavior: Bound

import QtQuick
import QtMultimedia
import Quickshell
import qs.style.theme
import qs.core.services
import qs.style.widgets

// The printer's camera in a window of its own (its FLV stream on :18088,
// which runs only while Printer.camera asks for it). Over the picture: a
// live badge, the job and its progress; closing the window stops the stream.
FloatingWindow {
	id: root

	title: `${Printer.name} · Camera`
	visible: Printer.camera
	implicitWidth: 760
	implicitHeight: 470
	minimumSize: Qt.size(420, 280)
	color: "black"

	// closed with the compositor's own means
	onVisibleChanged: if (!root.visible && Printer.camera) Printer.setCamera(false)

	readonly property bool playing: player.playbackState === MediaPlayer.PlayingState && player.hasVideo
	property int attempts: 0

	MediaPlayer {
		id: player

		source: root.visible && Printer.cameraUrl !== "" ? Printer.cameraUrl : ""
		videoOutput: output
		// the printer starts streaming a moment after it was asked
		onErrorOccurred: (error, message) => {
			if (root.visible && root.attempts < 8) retry.restart();
		}
		onSourceChanged: {
			root.attempts = 0;
			if (source !== "") Qt.callLater(play);
		}
		onMediaStatusChanged: {
			if (mediaStatus === MediaPlayer.LoadedMedia || mediaStatus === MediaPlayer.BufferedMedia) play();
		}
	}

	Timer {
		id: retry

		interval: 1500
		onTriggered: {
			root.attempts += 1;
			player.stop();
			player.play();
		}
	}

	VideoOutput {
		id: output

		anchors.fill: parent
		fillMode: VideoOutput.PreserveAspectFit
		opacity: root.playing ? 1 : 0

		Behavior on opacity {
			NumberAnimation {
				duration: 500
			}
		}
	}

	// waiting for the first picture
	Column {
		anchors.centerIn: parent
		spacing: 12
		visible: !root.playing

		Spinner {
			anchors.horizontalCenter: parent.horizontalCenter
			width: 38
			height: 38
			visible: root.attempts < 8
			color: Printer.hot
		}

		StyledText {
			anchors.horizontalCenter: parent.horizontalCenter
			text: root.attempts >= 8 ? "The camera does not answer" : "Waking the camera"
			tone: "white"
			surface: "black"
			opacity: 0.75
		}
	}

	// the top: live badge, name
	Rectangle {
		anchors.left: parent.left
		anchors.right: parent.right
		anchors.top: parent.top
		height: 64
		gradient: Gradient {
			GradientStop {
				position: 0
				color: Qt.rgba(0, 0, 0, 0.6)
			}
			GradientStop {
				position: 1
				color: "transparent"
			}
		}

		Rectangle {
			id: badge

			anchors.left: parent.left
			anchors.top: parent.top
			anchors.margins: 14
			width: live.implicitWidth + 26
			height: 24
			radius: 12
			color: Qt.rgba(0, 0, 0, 0.45)

			Rectangle {
				id: dot

				anchors.left: parent.left
				anchors.leftMargin: 9
				anchors.verticalCenter: parent.verticalCenter
				width: 8
				height: 8
				radius: 4
				color: root.playing ? "#ff4040" : "#888888"

				SequentialAnimation on opacity {
					running: root.playing
					loops: Animation.Infinite
					NumberAnimation {
						to: 0.25
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

			Text {
				id: live

				anchors.left: dot.right
				anchors.leftMargin: 6
				anchors.verticalCenter: parent.verticalCenter
				text: "LIVE"
				color: "white"
				font.family: Theme.fontFamily
				font.pixelSize: 11
				font.weight: Font.Bold
				font.letterSpacing: 1.4
			}
		}

		Text {
			anchors.right: parent.right
			anchors.top: parent.top
			anchors.margins: 16
			text: Printer.light ? "" : "Light is off"
			color: "white"
			opacity: 0.7
			font.family: Theme.fontFamily
			font.pixelSize: 12
		}
	}

	// the bottom: what prints, how far
	Rectangle {
		anchors.left: parent.left
		anchors.right: parent.right
		anchors.bottom: parent.bottom
		height: 74
		visible: Printer.printing
		gradient: Gradient {
			GradientStop {
				position: 0
				color: "transparent"
			}
			GradientStop {
				position: 1
				color: Qt.rgba(0, 0, 0, 0.7)
			}
		}

		Text {
			anchors.left: parent.left
			anchors.bottom: bar.top
			anchors.margins: 14
			anchors.bottomMargin: 8
			text: `${Printer.title(Printer.printingJob) || Printer.nameOf(Printer.project?.filename)} · ${Printer.status}`
			color: "white"
			font.family: Theme.fontFamily
			font.pixelSize: 13
			font.weight: Font.DemiBold
		}

		Text {
			anchors.right: parent.right
			anchors.bottom: bar.top
			anchors.margins: 14
			anchors.bottomMargin: 8
			text: `${Math.round(Printer.progress * 100)} % · ${Format.duration(Printer.secondsLeft)} left`
			color: "white"
			opacity: 0.85
			font.family: Theme.fontFamily
			font.pixelSize: 12
			font.features: { "tnum": 1 }
		}

		Rectangle {
			id: bar

			anchors.left: parent.left
			anchors.right: parent.right
			anchors.bottom: parent.bottom
			anchors.margins: 14
			height: 4
			radius: 2
			color: Qt.rgba(1, 1, 1, 0.18)

			Rectangle {
				width: parent.width * Printer.progress
				height: parent.height
				radius: 2
				color: Printer.hot

				Behavior on width {
					NumberAnimation {
						duration: 800
						easing.type: Easing.OutCubic
					}
				}
			}
		}
	}
}
