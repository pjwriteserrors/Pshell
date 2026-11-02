pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtMultimedia
import qs.style.theme
import qs.style.widgets

// The short video of the episode before, ahead of the next one. Its own player,
// so that the episode's progress never hears of it.
Rectangle {
	id: root

	property string title: ""
	property string file: ""
	property real volume: 1
	property bool muted: false
	property real ui: 1
	// what the recap says about each passage, in case the passage does not show it
	property var lines: []
	readonly property string saying: {
		const at = player.position / 1000;
		return root.lines.find(line => at >= line.from && at < line.to)?.text ?? "";
	}
	property bool ending: false

	signal finished

	function command(what) {
		if (what === "pause" || (what === "toggle" && root.playing)) player.pause();
		else player.play();
	}

	readonly property bool playing: player.playbackState === MediaPlayer.PlayingState
	readonly property real position: player.position / 1000
	readonly property real duration: player.duration / 1000

	// never from inside the player's own signal: finishing destroys it
	function end() {
		if (root.ending) return;
		root.ending = true;
		player.stop();
		leave.restart();
	}

	Timer {
		id: leave

		interval: 50
		onTriggered: root.finished()
	}

	color: "black"

	MediaPlayer {
		id: player

		source: root.file ? `file://${root.file}` : ""
		videoOutput: picture
		audioOutput: AudioOutput {
			volume: root.volume
			muted: root.muted
		}
		onMediaStatusChanged: if (mediaStatus === MediaPlayer.EndOfMedia) root.end()
		onErrorOccurred: root.end()
	}

	Component.onCompleted: player.play()

	VideoOutput {
		id: picture

		anchors.fill: parent
	}

	ColumnLayout {
		anchors.left: parent.left
		anchors.top: parent.top
		anchors.margins: 32 * root.ui
		spacing: 2

		Text {
			text: "Previously"
			color: "white"
			style: Text.Outline
			styleColor: Qt.rgba(0, 0, 0, 0.5)
			font.family: Theme.fontFamily
			font.pixelSize: 26 * root.ui
			font.weight: Font.Black
		}
		Text {
			text: root.title
			color: Qt.rgba(1, 1, 1, 0.85)
			style: Text.Outline
			styleColor: Qt.rgba(0, 0, 0, 0.5)
			font.family: Theme.fontFamily
			font.pixelSize: 15 * root.ui
		}
	}

	Rectangle {
		anchors.right: parent.right
		anchors.bottom: parent.bottom
		anchors.margins: 32 * root.ui
		width: skip.implicitWidth + 36 * root.ui
		height: 44 * root.ui
		radius: height / 2
		color: skipArea.containsMouse ? "white" : Qt.rgba(1, 1, 1, 0.85)

		Behavior on color {
			ColorAnim {}
		}

		Text {
			id: skip

			anchors.centerIn: parent
			text: "Skip to the episode"
			color: "black"
			font.family: Theme.fontFamily
			font.pixelSize: 15 * root.ui
			font.weight: Font.Bold
		}
		MouseArea {
			id: skipArea

			anchors.fill: parent
			hoverEnabled: true
			cursorShape: Qt.PointingHandCursor
			onClicked: root.end()
		}
	}

	Rectangle {
		anchors.horizontalCenter: parent.horizontalCenter
		anchors.bottom: parent.bottom
		anchors.bottomMargin: 92 * root.ui
		width: Math.min(parent.width * 0.7, saying.implicitWidth + 44 * root.ui)
		height: saying.implicitHeight + 24 * root.ui
		radius: 14 * root.ui
		color: Qt.rgba(0, 0, 0, 0.72)
		opacity: root.saying ? 1 : 0

		Behavior on opacity {
			Anim {}
		}

		Text {
			id: saying

			anchors.centerIn: parent
			width: Math.min(implicitWidth, root.width * 0.7 - 44 * root.ui)
			text: root.saying
			color: "white"
			horizontalAlignment: Text.AlignHCenter
			wrapMode: Text.Wrap
			font.family: Theme.fontFamily
			font.pixelSize: 19 * root.ui
		}
	}

	Rectangle {
		anchors.left: parent.left
		anchors.bottom: parent.bottom
		height: 4 * root.ui
		width: parent.width * (player.duration > 0 ? player.position / player.duration : 0)
		color: Theme.primary
	}
}
