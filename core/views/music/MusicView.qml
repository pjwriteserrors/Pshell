pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import Quickshell
import qs.style.theme
import qs.style.widgets
import qs.core.services

// The music's window: the cover large, the song's name, its wave to go
// anywhere in it and the keys; beside it what comes next or the words.
// Narrow it is the player alone, low it is a strip (the small window, M).
// The colour of the cover tints the accent, the cover blurred lies behind
// everything and the sound moves faintly along the bottom.
FocusScope {
	id: root

	property bool shown: false
	readonly property bool mini: root.height < 230
	readonly property bool side: !root.mini && root.width >= 860 && Music.pane !== ""
	readonly property bool audiobook: Music.duration > 1200 || Music.chapters.length > 1

	// the cover's colour, readable on the window
	property color accent: Music.accentHex !== "" ? Theme.legible(Music.accentHex, 3.0) : Theme.primary

	Behavior on accent {
		ColorAnimation {
			duration: Motion.extraLong
		}
	}

	function takeFocus() {
		root.forceActiveFocus();
	}

	// ── what lies behind ───────────────────────────────────────────────────
	Rectangle {
		anchors.fill: parent
		color: Theme.base
	}

	Item {
		id: ambient

		anchors.fill: parent
		visible: Music.setting("ambient", true)

		// two layers that cross-fade when the cover changes
		property bool aFront: true

		Connections {
			target: Music

			function onArtChanged() {
				const back = ambient.aFront ? ambientB : ambientA;
				back.source = Music.art ? "file://" + Music.art : "";
				ambient.aFront = !ambient.aFront;
			}
		}

		Component.onCompleted: ambientA.source = Music.art ? "file://" + Music.art : ""

		AmbientLayer {
			id: ambientA

			front: ambient.aFront
		}

		AmbientLayer {
			id: ambientB

			front: !ambient.aFront
		}

		Rectangle {
			anchors.fill: parent
			color: Theme.base
			opacity: Theme.dark ? 0.6 : 0.7
		}
	}

	component AmbientLayer: Item {
		id: layer

		property alias source: picture.source
		property bool front: false

		anchors.fill: parent
		opacity: layer.front && picture.status === Image.Ready ? 0.7 : 0

		Behavior on opacity {
			NumberAnimation {
				duration: 900
			}
		}

		Image {
			id: picture

			anchors.fill: parent
			// a few pixels only: their colours, no shapes
			sourceSize: Qt.size(6, 6)
			fillMode: Image.PreserveAspectCrop
			smooth: true
			asynchronous: true
			visible: false
		}

		MultiEffect {
			anchors.fill: parent
			source: picture
			blurEnabled: true
			blur: 1
			blurMax: 64
			blurMultiplier: 1
			saturation: 0.1
		}
	}

	// the sound, faint along the bottom
	ExternalCava {
		id: cava

		bars: 64
		framerate: 50
		active: root.shown && Music.playing && !root.mini && Music.setting("visualizer", true)
	}

	Row {
		id: bars

		anchors.left: parent.left
		anchors.right: parent.right
		anchors.bottom: parent.bottom
		height: Math.min(120, root.height * 0.2)
		spacing: 3
		opacity: cava.active ? 0.28 : 0
		visible: opacity > 0.01

		Behavior on opacity {
			Anim {
				duration: Motion.extraLong
			}
		}

		Repeater {
			model: cava.bars

			delegate: Rectangle {
				required property int index

				anchors.bottom: parent.bottom
				width: (bars.width - (cava.bars - 1) * bars.spacing) / cava.bars
				height: Math.max(2, (cava.values[index] || 0) * bars.height)
				radius: width / 2
				color: root.accent
			}
		}
	}

	// ── keys ───────────────────────────────────────────────────────────────
	Keys.onPressed: event => {
		const shift = event.modifiers & Qt.ShiftModifier;
		const ctrl = event.modifiers & Qt.ControlModifier;
		switch (event.key) {
		case Qt.Key_Space:
		case Qt.Key_K:
		case Qt.Key_MediaPlay:
		case Qt.Key_MediaTogglePlayPause:
			Music.toggle();
			break;
		case Qt.Key_Left:
			if (ctrl) Music.previous();
			else Music.seekBy(shift ? -30 : -5);
			break;
		case Qt.Key_Right:
			if (ctrl) Music.next();
			else Music.seekBy(shift ? 30 : 5);
			break;
		case Qt.Key_N:
		case Qt.Key_MediaNext:
			Music.next();
			break;
		case Qt.Key_P:
		case Qt.Key_MediaPrevious:
			Music.previous();
			break;
		case Qt.Key_Up:
			Music.setVolume(Music.volume + 5);
			break;
		case Qt.Key_Down:
			Music.setVolume(Music.volume - 5);
			break;
		case Qt.Key_Q:
			Music.showPane("queue");
			break;
		case Qt.Key_L:
			Music.showPane("lyrics");
			break;
		case Qt.Key_M:
			Music.toggleMini(root.width, root.height);
			break;
		case Qt.Key_S:
			Music.toggleShuffle();
			break;
		case Qt.Key_R:
			Music.cycleRepeat();
			break;
		case Qt.Key_BracketLeft:
			Music.setSpeed(Math.max(0.5, Music.speed - 0.25));
			break;
		case Qt.Key_BracketRight:
			Music.setSpeed(Math.min(3, Music.speed + 0.25));
			break;
		case Qt.Key_Backspace:
			Music.setSpeed(1);
			break;
		case Qt.Key_Escape:
			Music.close();
			break;
		default:
			// 0 … 9 go to a tenth of the song
			if (event.key >= Qt.Key_0 && event.key <= Qt.Key_9 && !ctrl) {
				Music.seek((event.key - Qt.Key_0) / 10 * Music.duration);
				break;
			}
			return;
		}
		event.accepted = true;
	}

	// songs dropped in: into the queue (with Shift: next)
	DropArea {
		id: drop

		anchors.fill: parent
		keys: ["text/uri-list"]
		onDropped: dropEvent => {
			const paths = (dropEvent.urls || []).map(u => String(u)).filter(u => u.startsWith("file://"));
			if (paths.length === 0) return;
			Music.add(paths, false);
			dropEvent.accept();
		}
	}

	Rectangle {
		anchors.fill: parent
		anchors.margins: 10
		radius: Theme.radius.huge
		color: Qt.alpha(root.accent, 0.08)
		border.width: 2
		border.color: Qt.alpha(root.accent, 0.6)
		opacity: drop.containsDrag ? 1 : 0
		visible: opacity > 0.01
		z: 50

		Behavior on opacity {
			Anim {}
		}

		StyledText {
			anchors.centerIn: parent
			text: Music.queue.length === 0 ? "Drop to play" : "Drop to add to the queue"
			tone: root.accent
			font.pixelSize: Theme.size.heading
			font.weight: Font.Bold
		}
	}

	// ── the player ─────────────────────────────────────────────────────────
	Item {
		id: player

		visible: !root.mini
		opacity: root.mini ? 0 : 1
		anchors.top: parent.top
		anchors.bottom: parent.bottom
		anchors.left: parent.left
		width: root.side ? Math.round(root.width * 0.54) : root.width

		Behavior on width {
			enabled: root.shown
			SpatialAnim {}
		}

		Behavior on opacity {
			Anim {}
		}

		readonly property real coverSize: Math.max(120, Math.min(player.width - 120, player.height - 300, 460))

		Column {
			id: stack

			anchors.centerIn: parent
			anchors.verticalCenterOffset: -8
			width: Math.min(player.width - 80, 560)
			spacing: 0

			CoverArt {
				id: cover

				anchors.horizontalCenter: parent.horizontalCenter
				width: player.coverSize
				height: player.coverSize
				accent: root.accent

				Behavior on width {
					enabled: root.shown
					SpatialAnim {}
				}
				Behavior on height {
					enabled: root.shown
					SpatialAnim {}
				}

				MouseArea {
					anchors.fill: parent
					cursorShape: Qt.PointingHandCursor
					onClicked: Music.toggle()
				}
			}

			Item {
				width: 1
				height: 26
			}

			SwapText {
				width: parent.width
				text: Music.current ? Music.titleOf(Music.path) : (Music.queue.length === 0 ? "Nothing to play" : "Stopped")
				pixelSize: Theme.size.display
				weight: Font.Black
				tone: Theme.text
			}

			Item {
				width: 1
				height: 4
			}

			SwapText {
				width: parent.width
				text: {
					const t = Music.song;
					if (!Music.current) return Music.queue.length === 0 ? "Open a song in Files, or drop some here" : "";
					return [t?.artist, t?.album].filter(x => x).join(" · ");
				}
				pixelSize: Theme.size.title
				weight: Font.Medium
				tone: Theme.textMuted
			}

			// what the file is, small; the chapter of an audiobook
			StyledText {
				width: parent.width
				horizontalAlignment: Text.AlignHCenter
				topPadding: 6
				visible: text !== ""
				tone: Theme.textSubtle
				font.pixelSize: Theme.size.small
				tabular: true
				text: {
					const t = Music.song;
					if (!t) return "";
					if (Music.chapterNow >= 0 && Music.chapters.length > 1) return `${Music.chapters[Music.chapterNow].title} · ${Music.chapterNow + 1} of ${Music.chapters.length}`;
					const parts = [t.codec];
					if (t.rate) parts.push(`${(t.rate / 1000).toFixed(t.rate % 1000 === 0 ? 0 : 1)} kHz`);
					if (t.bits) parts.push(`${t.bits} bit`);
					else if (t.kbps) parts.push(`${t.kbps} kbps`);
					return parts.filter(p => p).join(" · ");
				}
			}

			Item {
				width: 1
				height: 22
			}

			WaveSeek {
				width: parent.width
				height: 56
				accent: root.accent
			}

			Item {
				width: parent.width
				height: 24

				StyledText {
					anchors.left: parent.left
					anchors.verticalCenter: parent.verticalCenter
					tabular: true
					tone: Theme.textMuted
					font.pixelSize: Theme.size.small
					text: Music.formatTime(Music.position)
				}

				StyledText {
					anchors.right: parent.right
					anchors.verticalCenter: parent.verticalCenter
					tabular: true
					tone: Theme.textMuted
					font.pixelSize: Theme.size.small
					text: Music.duration > 0 ? `−${Music.formatTime(Math.max(0, Music.duration - Music.position) / Music.speed)}` : ""
				}
			}

			Item {
				width: 1
				height: 6
			}

			// the keys
			Row {
				anchors.horizontalCenter: parent.horizontalCenter
				spacing: 14

				IconButton {
					anchors.verticalCenter: parent.verticalCenter
					width: 40
					height: 40
					icon: "shuffle"
					checked: Music.shuffled
					onClicked: Music.toggleShuffle()
				}

				IconButton {
					anchors.verticalCenter: parent.verticalCenter
					visible: root.audiobook
					width: 44
					height: 44
					icon: "rewind_30"
					onClicked: Music.seekBy(-30)
				}

				IconButton {
					anchors.verticalCenter: parent.verticalCenter
					width: 52
					height: 52
					icon: "skip_previous"
					iconSize: 30
					enabled: Music.queue.length > 0
					onClicked: Music.previous()
				}

				PlayButton {
					anchors.verticalCenter: parent.verticalCenter
					size: 72
					accent: root.accent
				}

				IconButton {
					anchors.verticalCenter: parent.verticalCenter
					width: 52
					height: 52
					icon: "skip_next"
					iconSize: 30
					enabled: Music.queue.length > 1 || Music.repeatMode !== "off"
					onClicked: Music.next()
				}

				IconButton {
					anchors.verticalCenter: parent.verticalCenter
					visible: root.audiobook
					width: 44
					height: 44
					icon: "fast_forward_30"
					onClicked: Music.seekBy(30)
				}

				IconButton {
					anchors.verticalCenter: parent.verticalCenter
					width: 40
					height: 40
					icon: Music.repeatMode === "one" ? "repeat_once" : (Music.repeatMode === "all" ? "repeat" : "repeat_off")
					checked: Music.repeatMode !== "off"
					onClicked: Music.cycleRepeat()
				}
			}

			Item {
				width: 1
				height: 14
			}

			// the rest
			Row {
				anchors.horizontalCenter: parent.horizontalCenter
				spacing: 6

				ToolChip {
					icon: "speedometer"
					text: Music.speed === 1 ? "1×" : `${Music.speed}×`
					active: Music.speed !== 1
					tip: "Speed – click for faster, right-click back to normal"
					onClicked: {
						const steps = [1, 1.25, 1.5, 1.75, 2, 0.75];
						const i = steps.indexOf(Music.speed);
						Music.setSpeed(steps[(i + 1) % steps.length]);
					}
					onRightClicked: Music.setSpeed(1)
				}

				ToolChip {
					icon: "sleep"
					active: Music.sleepAt !== 0
					text: {
						if (Music.sleepAt === -1) return "after this";
						if (Music.sleepAt > 0) return `${Math.max(1, Math.ceil((Music.sleepAt - clock.now) / 60000))} min`;
						return "";
					}
					tip: "Sleep timer – 15, 30, 60 minutes, after this song, off"
					onClicked: {
						if (Music.sleepAt === 0) Music.sleep(15);
						else if (Music.sleepAt === -1) Music.sleep(0);
						else {
							const left = (Music.sleepAt - Date.now()) / 60000;
							if (left <= 15) Music.sleep(30);
							else if (left <= 30) Music.sleep(60);
							else Music.sleep(-1);
						}
					}
					onRightClicked: Music.sleep(0)
				}

				PillSlider {
					anchors.verticalCenter: parent.verticalCenter
					width: 150
					height: 32
					icon: Music.volume <= 0 ? "volume_off" : (Music.volume < 40 ? "volume_low" : (Music.volume < 80 ? "volume_medium" : "volume_high"))
					iconInteractive: true
					value: Music.volume / 100
					stepSize: 0.05
					wheelEnabled: false
					accent: root.accent
					showValue: false
					onMoved: value => Music.setVolume(value * 100)
					onIconClicked: Music.setVolume(Music.volume > 0 ? 0 : 100)
				}

				ToolChip {
					icon: "text_box_outline"
					active: Music.pane === "lyrics"
					tip: "Lyrics (L)"
					onClicked: Music.showPane("lyrics")
				}

				ToolChip {
					icon: "playlist_music"
					active: Music.pane === "queue"
					tip: "Queue (Q)"
					onClicked: Music.showPane("queue")
				}

				ToolChip {
					icon: "arrow_collapse"
					tip: "Small window (M)"
					onClicked: Music.toggleMini(root.width, root.height)
				}
			}
		}
	}

	// a clock for the sleep timer's minutes
	QtObject {
		id: clock

		property real now: Date.now()
	}

	Timer {
		running: Music.sleepAt > 0 && root.shown
		repeat: true
		interval: 15000
		triggeredOnStart: true
		onTriggered: clock.now = Date.now()
	}

	// ── beside it: the queue or the words ──────────────────────────────────
	Item {
		id: sidePane

		anchors.top: parent.top
		anchors.bottom: parent.bottom
		anchors.right: parent.right
		anchors.topMargin: 28
		anchors.bottomMargin: 20
		anchors.rightMargin: 24
		width: root.width - player.width - 24
		opacity: root.side ? 1 : 0
		visible: opacity > 0.01

		Behavior on opacity {
			Anim {
				duration: Motion.long
			}
		}

		Loader {
			id: queueLoader

			anchors.fill: parent
			active: Music.pane === "queue"
			opacity: Music.pane === "queue" ? 1 : 0

			Behavior on opacity {
				Anim {}
			}

			sourceComponent: QueuePane {
				accent: root.accent
			}
		}

		Loader {
			id: lyricsLoader

			anchors.fill: parent
			active: Music.pane === "lyrics"
			opacity: Music.pane === "lyrics" ? 1 : 0

			Behavior on opacity {
				Anim {}
			}

			sourceComponent: LyricsPane {
				accent: root.accent
			}
		}
	}

	// ── the small window: a strip ──────────────────────────────────────────
	Item {
		id: strip

		anchors.fill: parent
		anchors.margins: 12
		visible: root.mini
		opacity: root.mini ? 1 : 0

		Behavior on opacity {
			Anim {}
		}

		CoverArt {
			id: smallCover

			anchors.left: parent.left
			anchors.verticalCenter: parent.verticalCenter
			width: Math.min(parent.height, 120)
			height: width
			corner: Theme.radius.large
			accent: root.accent
			lifted: false
		}

		Column {
			anchors.left: smallCover.right
			anchors.leftMargin: 14
			anchors.right: stripKeys.left
			anchors.rightMargin: 10
			anchors.verticalCenter: parent.verticalCenter
			spacing: 4

			SwapText {
				width: parent.width
				text: Music.current ? Music.titleOf(Music.path) : "Nothing to play"
				pixelSize: Theme.size.title
				weight: Font.Bold
				tone: Theme.text
				centered: false
			}

			SwapText {
				width: parent.width
				text: Music.song?.artist ?? ""
				pixelSize: Theme.size.small
				weight: Font.Medium
				tone: Theme.textMuted
				centered: false
			}

			Item {
				width: 1
				height: 6
			}

			WaveSeek {
				width: parent.width
				height: 8
				slim: true
				accent: root.accent
			}
		}

		Row {
			id: stripKeys

			anchors.right: parent.right
			anchors.verticalCenter: parent.verticalCenter
			spacing: 2

			IconButton {
				anchors.verticalCenter: parent.verticalCenter
				width: 36
				height: 36
				icon: "skip_previous"
				onClicked: Music.previous()
			}

			PlayButton {
				anchors.verticalCenter: parent.verticalCenter
				size: 44
				accent: root.accent
			}

			IconButton {
				anchors.verticalCenter: parent.verticalCenter
				width: 36
				height: 36
				icon: "skip_next"
				onClicked: Music.next()
			}

			IconButton {
				anchors.verticalCenter: parent.verticalCenter
				width: 32
				height: 32
				icon: "arrow_expand"
				onClicked: Music.toggleMini(root.width, root.height)
			}
		}
	}

	// ── a line of news ─────────────────────────────────────────────────────
	Rectangle {
		id: toast

		function show(text, icon) {
			toastText.text = text;
			toastGlyph.icon = icon || "information_outline";
			toast.opacity = 1;
			toastTimer.restart();
		}

		anchors.horizontalCenter: parent.horizontalCenter
		anchors.bottom: parent.bottom
		anchors.bottomMargin: 18
		width: toastRow.implicitWidth + 28
		height: 40
		radius: 20
		color: Theme.layer3
		opacity: 0
		visible: opacity > 0
		z: 70

		Behavior on opacity {
			Anim {}
		}

		Row {
			id: toastRow

			anchors.centerIn: parent
			spacing: 10

			Glyph {
				id: toastGlyph

				anchors.verticalCenter: parent.verticalCenter
				size: 18
				color: root.accent
			}

			StyledText {
				id: toastText

				anchors.verticalCenter: parent.verticalCenter
			}
		}

		Timer {
			id: toastTimer

			interval: 3000
			onTriggered: toast.opacity = 0
		}
	}

	Connections {
		target: Music

		function onSaid(text, icon) {
			toast.show(text, icon);
		}
	}

	// ── small parts ────────────────────────────────────────────────────────
	// the big round key: its glyph turns between play and pause
	component PlayButton: Clickable {
		id: play

		property real size: 64
		property color accent: Theme.primary

		width: play.size
		height: play.size
		radius: Music.playing ? play.size * 0.32 : play.size / 2
		color: play.accent
		tint: Theme.onPrimary
		sound: ""
		enabled: Music.queue.length > 0 || Music.current
		opacity: enabled ? 1 : 0.4
		onClicked: Music.toggle()

		Behavior on radius {
			SpatialAnim {}
		}

		Glyph {
			anchors.centerIn: parent
			anchors.horizontalCenterOffset: Music.playing ? 0 : play.size * 0.03
			icon: Music.playing ? "pause" : "play"
			size: play.size * 0.48
			color: Theme.contrast(play.accent, Qt.color("#000000")) > Theme.contrast(play.accent, Qt.color("#ffffff")) ? "#111111" : "#ffffff"
		}
	}

	// a small round tool with a word beside it when it says something
	component ToolChip: Clickable {
		id: chip

		property string icon: ""
		property string text: ""
		property string tip: ""
		property bool active: false

		acceptedButtons: Qt.LeftButton | Qt.RightButton
		implicitWidth: chipRow.implicitWidth + (chip.text !== "" ? 22 : 16)
		implicitHeight: 32
		radius: 16
		color: chip.active ? Qt.alpha(root.accent, 0.2) : (chip.hovered ? Theme.layer2 : Qt.alpha(Theme.layer2, 0.6))
		tint: Theme.text

		Behavior on implicitWidth {
			SpatialAnim {
				duration: Motion.medium
			}
		}

		Row {
			id: chipRow

			anchors.centerIn: parent
			spacing: 6

			Glyph {
				anchors.verticalCenter: parent.verticalCenter
				icon: chip.icon
				size: 17
				color: chip.active ? root.accent : Theme.text
			}

			StyledText {
				anchors.verticalCenter: parent.verticalCenter
				visible: chip.text !== ""
				text: chip.text
				tabular: true
				font.pixelSize: Theme.size.small
				font.weight: Font.DemiBold
				tone: chip.active ? root.accent : Theme.text
			}
		}
	}

	// a line that fades and rises into its next words
	component SwapText: Item {
		id: swap

		property string text: ""
		property real pixelSize: Theme.size.body
		property int weight: Font.Normal
		property color tone: Theme.text
		property bool centered: true
		property string shownText: ""

		implicitHeight: label.implicitHeight
		height: label.implicitHeight
		clip: false

		Component.onCompleted: swap.shownText = swap.text
		onTextChanged: {
			if (swap.shownText === swap.text) return;
			if (!root.shown) {
				swap.shownText = swap.text;
				return;
			}
			change.restart();
		}

		SequentialAnimation {
			id: change

			ParallelAnimation {
				NumberAnimation {
					target: label
					property: "opacity"
					to: 0
					duration: Motion.short
				}
				NumberAnimation {
					target: label
					property: "y"
					to: -6
					duration: Motion.short
				}
			}
			ScriptAction {
				script: {
					swap.shownText = swap.text;
					label.y = 8;
				}
			}
			ParallelAnimation {
				NumberAnimation {
					target: label
					property: "opacity"
					to: 1
					duration: Motion.long
				}
				NumberAnimation {
					target: label
					property: "y"
					to: 0
					duration: Motion.long
					easing.type: Easing.BezierSpline
					easing.bezierCurve: Motion.spatial
				}
			}
		}

		Text {
			id: label

			width: swap.width
			text: swap.shownText
			color: swap.tone
			horizontalAlignment: swap.centered ? Text.AlignHCenter : Text.AlignLeft
			elide: Text.ElideRight
			maximumLineCount: 1
			font.family: Theme.fontFamily
			font.pixelSize: swap.pixelSize
			font.weight: swap.weight
		}
	}
}
