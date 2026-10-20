pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtMultimedia
import qs.style.theme
import qs.style.widgets
import qs.core.services

// Cutting a recording to the part that matters, or making a GIF of it: the
// video plays, two handles on its line mark the start and the end.
DialogFrame {
	id: root

	property string path: ""
	// "cut" or "gif"
	property string mode: "cut"
	property real length: 0
	property real start: 0
	property real end: 0
	property bool exact: true
	property int fps: 15
	property int gifWidth: 720

	function open(path, mode) {
		root.path = path;
		root.mode = mode || "cut";
		root.length = 0;
		root.start = 0;
		root.end = 0;
		root.show();
		keys.forceActiveFocus();
		Files.request("duration", { path: path }, data => {
			root.length = Number(data?.duration) || 0;
			root.end = root.mode === "gif" ? Math.min(root.length, 6) : root.length;
		});
	}

	function run() {
		if (root.end - root.start < 0.2) return;
		if (root.mode === "gif") Files.startJob("gif", { path: root.path, start: root.start, end: root.end, fps: root.fps, width: root.gifWidth });
		else Files.startJob("trim", { path: root.path, start: root.start, end: root.end, exact: root.exact });
		player.stop();
		root.hide();
	}

	onShownChanged: if (!root.shown) player.stop()

	cardWidth: 760
	onDismissed: root.hide()

	Item {
		id: keys

		focus: root.shown
		Keys.onEscapePressed: root.hide()
		Keys.onReturnPressed: root.run()
		Keys.onEnterPressed: root.run()
		Keys.onSpacePressed: player.playbackState === MediaPlayer.PlayingState ? player.pause() : root.playPart()
	}

	function playPart() {
		player.position = Math.round(root.start * 1000);
		player.play();
	}

	MediaPlayer {
		id: player

		source: root.shown && root.path !== "" ? Files.uri(root.path) : ""
		videoOutput: video
		audioOutput: AudioOutput {
			volume: 0.6
		}
		// the first picture shows before anything plays
		onMediaStatusChanged: if (player.mediaStatus === MediaPlayer.LoadedMedia && player.playbackState === MediaPlayer.StoppedState) {
			player.play();
			player.pause();
		}
		// the part plays, not more
		onPositionChanged: if (player.playbackState === MediaPlayer.PlayingState && player.position / 1000 >= root.end) player.pause()
	}

	ColumnLayout {
		width: parent.width
		spacing: 12

		RowLayout {
			spacing: 12

			Rectangle {
				width: 40
				height: 40
				radius: 13
				color: Qt.tint(Theme.layer2, Qt.alpha(Theme.tertiary, 0.2))

				Glyph {
					anchors.centerIn: parent
					icon: root.mode === "gif" ? "file_gif_box" : "content_cut"
					size: 20
					color: Theme.tertiary
				}
			}

			ColumnLayout {
				Layout.fillWidth: true
				spacing: 1

				StyledText {
					text: root.mode === "gif" ? "Make a GIF" : "Cut the recording"
					font.pixelSize: Theme.size.title
					font.weight: Font.DemiBold
				}

				StyledText {
					Layout.fillWidth: true
					text: `${Files.nameOf(root.path)} · ${Format.clock(root.start, 1)} – ${Format.clock(root.end, 1)} (${(root.end - root.start).toFixed(1)} s of ${root.length.toFixed(1)} s)`
					tone: Theme.textSubtle
					font.pixelSize: Theme.size.small
					elide: Text.ElideMiddle
				}
			}

			Segmented {
				Layout.preferredWidth: 180
				height: 32
				options: [{ value: "cut", label: "Cut" }, { value: "gif", label: "GIF" }]
				current: root.mode
				onSelected: value => root.mode = value
			}
		}

		Rectangle {
			Layout.fillWidth: true
			Layout.preferredHeight: Math.max(200, Math.min(420, root.height - 340))
			radius: Theme.radius.large
			color: "black"
			clip: true

			VideoOutput {
				id: video

				anchors.fill: parent
				fillMode: VideoOutput.PreserveAspectFit
			}

			IconButton {
				anchors.centerIn: parent
				width: 54
				height: 54
				iconSize: 26
				variant: "tonal"
				icon: player.playbackState === MediaPlayer.PlayingState ? "pause" : "play"
				opacity: player.playbackState === MediaPlayer.PlayingState ? 0 : 0.9
				onClicked: root.playPart()

				Behavior on opacity {
					Anim {}
				}
			}

			MouseArea {
				anchors.fill: parent
				z: -1
				onClicked: player.playbackState === MediaPlayer.PlayingState ? player.pause() : root.playPart()
			}
		}

		// the line of the recording, the part between the handles
		Item {
			id: line

			Layout.fillWidth: true
			Layout.preferredHeight: 44

			readonly property real perSecond: root.length > 0 ? line.width / root.length : 0

			Rectangle {
				anchors.verticalCenter: parent.verticalCenter
				width: parent.width
				height: 10
				radius: 5
				color: Theme.layer2
			}

			Rectangle {
				x: root.start * line.perSecond
				width: Math.max(2, (root.end - root.start) * line.perSecond)
				anchors.verticalCenter: parent.verticalCenter
				height: 10
				radius: 5
				color: Theme.tertiary
			}

			// where it plays
			Rectangle {
				x: player.position / 1000 * line.perSecond - 1
				width: 2
				height: parent.height
				color: Theme.text
				opacity: player.playbackState === MediaPlayer.StoppedState ? 0 : 0.8
			}

			Repeater {
				model: ["start", "end"]

				delegate: Rectangle {
					id: handle

					required property string modelData

					x: (handle.modelData === "start" ? root.start : root.end) * line.perSecond - width / 2
					anchors.verticalCenter: parent.verticalCenter
					width: 16
					height: 34
					radius: 6
					color: Theme.tertiary
					border.width: 2
					border.color: Theme.base

					MouseArea {
						anchors.fill: parent
						anchors.margins: -8
						cursorShape: Qt.SizeHorCursor
						onPositionChanged: mouse => {
							const at = mapToItem(line, mouse.x, mouse.y);
							const seconds = Math.max(0, Math.min(root.length, at.x / Math.max(0.0001, line.perSecond)));
							if (handle.modelData === "start") root.start = Math.min(seconds, root.end - 0.2);
							else root.end = Math.max(seconds, root.start + 0.2);
							player.position = Math.round((handle.modelData === "start" ? root.start : root.end) * 1000);
						}
					}
				}
			}
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 10
			visible: root.mode === "cut"

			Toggle {
				checked: root.exact
				onToggled: on => root.exact = on
			}

			StyledText {
				Layout.fillWidth: true
				text: root.exact ? "To the frame (encoded again, takes a moment)" : "At the nearest keyframe (instant, may start a little earlier)"
				tone: Theme.textMuted
				font.pixelSize: Theme.size.small
			}
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 10
			visible: root.mode === "gif"

			Segmented {
				Layout.fillWidth: true
				height: 32
				options: [{ value: "10", label: "10 fps" }, { value: "15", label: "15 fps" }, { value: "24", label: "24 fps" }]
				current: String(root.fps)
				onSelected: value => root.fps = Number(value)
			}

			Segmented {
				Layout.fillWidth: true
				height: 32
				options: [{ value: "480", label: "480 px" }, { value: "720", label: "720 px" }, { value: "1080", label: "1080 px" }]
				current: String(root.gifWidth)
				onSelected: value => root.gifWidth = Number(value)
			}
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 8

			StyledText {
				Layout.fillWidth: true
				text: "Space plays the part · a new file is made beside it"
				tone: Theme.textSubtle
				font.pixelSize: Theme.size.small
			}

			TextButton {
				text: "Cancel"
				variant: "ghost"
				onClicked: root.hide()
			}

			TextButton {
				text: root.mode === "gif" ? "Make the GIF" : "Cut"
				icon: root.mode === "gif" ? "file_gif_box" : "content_cut"
				variant: "filled"
				enabled: root.end - root.start >= 0.2
				onClicked: root.run()
			}
		}
	}
}
