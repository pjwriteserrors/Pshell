pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import Quickshell
import qs.style.theme
import qs.style.widgets
import qs.core.services
import qs.core.views.files

// The videos' window: the film as large as it goes, the bars above and below
// fading away while it is watched (and the pointer with them), the film's
// colours glowing around it. Beside it, as a sheet when narrow, the
// episodes, the tracks and subtitles, what the file is and the settings;
// E turns the window into the editor (EditorView.qml). Small (picture in
// picture) it keeps only the keys that matter. See core/services/Video.qml.
FocusScope {
	id: root

	property bool shown: false
	readonly property bool small: Video.pip || root.width < 520 || root.height < 300
	readonly property bool editing: Video.editing
	// a pane beside the film when there is room, else over it
	readonly property bool canSide: !root.small && root.width >= 1000
	property string pane: ""
	readonly property real paneWidth: root.pane !== "" && !root.editing ? Math.min(400, Math.max(300, root.width * 0.3)) : 0

	function openPane(name) {
		root.pane = root.pane === name ? "" : name;
		root.wake();
	}

	// the film's colour (its tiles, read once), readable
	property color accent: Video.sprite?.accent ? Theme.legible(Video.sprite.accent, 3.0) : Theme.primary

	Behavior on accent {
		ColorAnimation {
			duration: Motion.extraLong
		}
	}

	function takeFocus() {
		root.forceActiveFocus();
	}

	// ── the bars come with the pointer and go while it rests ───────────────
	property bool awake: true
	readonly property bool chrome: root.awake || !Video.playing || root.pane !== "" || menu.open || seek.hovering || controlsHover.hovered || topHover.hovered || Video.loading || !Video.current

	function wake() {
		root.awake = true;
		sleepTimer.restart();
	}

	Timer {
		id: sleepTimer

		interval: 2600
		onTriggered: if (Video.playing) root.awake = false
	}

	onShownChanged: if (root.shown) root.wake()

	Rectangle {
		anchors.fill: parent
		color: "black"
	}

	// ── the picture ────────────────────────────────────────────────────────
	Stage {
		id: stage

		anchors.fill: parent
		editing: root.editing
		accent: root.accent
		padRight: root.editing ? (editor.item?.panelWidth ?? 0) : (root.canSide ? root.paneWidth : 0)
		padBottom: root.editing ? (editor.item?.timelineHeight ?? 0) : 0
		padTop: root.editing ? 52 : 0
		padLeft: root.editing ? 12 : 0
		cropless: editor.item?.cropping ?? false
		split: editor.item?.split ?? 0
		subtitleLift: root.chrome && !root.editing ? (root.small ? 56 : 120) : 0
		Component.onCompleted: Video.videoOutput = stage.video

		Behavior on padRight {
			SpatialAnim {
				duration: Motion.long
			}
		}
	}

	// the first frame grows in from the spot it was opened from (VideoGhost),
	// here the picture only fades: what sits on it already shows the frame
	Spinner {
		anchors.centerIn: stage
		width: 44
		height: 44
		color: root.accent
		visible: opacity > 0.01
		opacity: Video.loading || (Video.current && Video.startPending && !Video.error) ? 1 : 0

		Behavior on opacity {
			Anim {
				duration: Motion.long
			}
		}
	}

	// ── nothing open, or it would not play ────────────────────────────────
	Column {
		anchors.centerIn: parent
		spacing: 14
		visible: !Video.current || Video.error !== ""
		width: Math.min(parent.width - 48, 420)

		Glyph {
			anchors.horizontalCenter: parent.horizontalCenter
			icon: Video.error ? "movie_off_outline" : "movie_open_outline"
			size: 54
			color: Qt.rgba(1, 1, 1, 0.5)
			surface: "transparent"
		}

		StyledText {
			anchors.horizontalCenter: parent.horizontalCenter
			width: parent.width
			horizontalAlignment: Text.AlignHCenter
			wrapMode: Text.WordWrap
			text: Video.error || "Drop a video here, or open one in Files"
			tone: Qt.rgba(1, 1, 1, 0.78)
			surface: "transparent"
			font.pixelSize: Theme.size.title
		}

		// the last ones, to take up again
		Column {
			anchors.horizontalCenter: parent.horizontalCenter
			spacing: 6
			visible: !Video.current && Video.recent.length > 0

			Repeater {
				model: Video.recent.slice(0, 4)

				Clickable {
					id: recentRow

					required property string modelData

					width: 380
					height: 44
					radius: Theme.radius.medium
					color: recentRow.hovered ? Qt.rgba(1, 1, 1, 0.1) : Qt.rgba(1, 1, 1, 0.05)
					tint: "white"
					onClicked: Video.open(recentRow.modelData)

					Row {
						anchors.fill: parent
						anchors.leftMargin: 12
						anchors.rightMargin: 12
						spacing: 10

						Glyph {
							anchors.verticalCenter: parent.verticalCenter
							icon: "play_circle_outline"
							size: 20
							color: "white"
							surface: "transparent"
						}

						StyledText {
							anchors.verticalCenter: parent.verticalCenter
							width: parent.width - 30
							text: Video.titleOf(recentRow.modelData)
							tone: "white"
							surface: "transparent"
						}
					}
				}
			}
		}
	}

	// ── the pointer on the picture ─────────────────────────────────────────
	MouseArea {
		id: pointer

		anchors.fill: parent
		enabled: !root.editing
		hoverEnabled: true
		acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
		cursorShape: root.chrome || !Video.playing ? Qt.ArrowCursor : Qt.BlankCursor
		property real pressX: 0
		property real pressY: 0
		property real startPanX: 0
		property real startPanY: 0
		property bool panned: false

		onPositionChanged: mouse => {
			if (Math.abs(mouse.x - pointer.lastX) + Math.abs(mouse.y - pointer.lastY) > 3) root.wake();
			pointer.lastX = mouse.x;
			pointer.lastY = mouse.y;
			if (pointer.pressed && stage.zoom > 1) {
				pointer.panned = pointer.panned || Math.abs(mouse.x - pointer.pressX) + Math.abs(mouse.y - pointer.pressY) > 6;
				stage.panX = pointer.startPanX + mouse.x - pointer.pressX;
				stage.panY = pointer.startPanY + mouse.y - pointer.pressY;
				stage.clampPan();
			}
		}
		property real lastX: 0
		property real lastY: 0

		onPressed: mouse => {
			pointer.pressX = mouse.x;
			pointer.pressY = mouse.y;
			pointer.startPanX = stage.panX;
			pointer.startPanY = stage.panY;
			pointer.panned = false;
		}
		onClicked: mouse => {
			if (mouse.button === Qt.RightButton) return root.showMenu(mouse.x, mouse.y);
			if (mouse.button === Qt.MiddleButton) return Video.togglePip();
			if (pointer.panned) return;
			if (root.pane !== "" && !root.canSide) {
				root.pane = "";
				return;
			}
			// one click plays or pauses – a moment later, a second one would be a double click
			clickTimer.restart();
		}
		onDoubleClicked: mouse => {
			clickTimer.stop();
			// the edges go back and on, the middle is the whole screen
			const share = mouse.x / Math.max(1, pointer.width);
			if (share < 0.28) root.jumpBy(-10, mouse.x, mouse.y);
			else if (share > 0.72) root.jumpBy(10, mouse.x, mouse.y);
			else Video.toggleFullscreen();
		}
		onWheel: wheel => {
			// the wheel never changes a value: with Ctrl it looks closer
			if (wheel.modifiers & Qt.ControlModifier) stage.zoomAt(wheel.angleDelta.y > 0 ? 1.15 : 1 / 1.15, wheel.x, wheel.y);
			else wheel.accepted = false;
		}
	}

	Timer {
		id: clickTimer

		interval: 230
		onTriggered: {
			Video.toggle();
			flash.show(Video.playing ? "play" : "pause");
		}
	}

	PinchHandler {
		target: null
		enabled: !root.editing
		onScaleChanged: delta => stage.zoomAt(delta, centroid.position.x, centroid.position.y)
	}

	function jumpBy(seconds, x, y) {
		Video.seekBy(seconds);
		ripple.show(seconds, x, y);
	}

	// a quick mark in the middle: what the click did
	Item {
		id: flash

		function show(icon) {
			flashGlyph.icon = icon;
			flashAnim.restart();
		}

		anchors.centerIn: stage
		width: 84
		height: 84
		opacity: 0
		scale: 0.8

		Rectangle {
			anchors.fill: parent
			radius: width / 2
			color: Qt.rgba(0, 0, 0, 0.45)
		}

		Glyph {
			id: flashGlyph

			anchors.centerIn: parent
			size: 42
			color: "white"
			surface: "transparent"
			animated: false
		}

		ParallelAnimation {
			id: flashAnim

			SequentialAnimation {
				NumberAnimation {
					target: flash
					property: "opacity"
					from: 0
					to: 1
					duration: 90
				}
				PauseAnimation {
					duration: 260
				}
				NumberAnimation {
					target: flash
					property: "opacity"
					to: 0
					duration: 320
				}
			}
			NumberAnimation {
				target: flash
				property: "scale"
				from: 0.8
				to: 1.15
				duration: 670
				easing.type: Easing.OutCubic
			}
		}
	}

	// back or on by ten: a ring that spreads from the side clicked
	Item {
		id: ripple

		property int sign: 1
		property int count: 0

		function show(seconds, x, y) {
			ripple.count = rippleAnim.running && Math.sign(seconds) === ripple.sign ? ripple.count + Math.abs(seconds) : Math.abs(seconds);
			ripple.sign = Math.sign(seconds);
			rippleAnim.restart();
		}

		x: ripple.sign > 0 ? root.width * 0.62 : 0
		width: root.width * 0.38
		height: root.height
		opacity: 0

		Rectangle {
			id: rippleRing

			anchors.centerIn: parent
			width: parent.height * 0.5
			height: width
			radius: width / 2
			color: Qt.rgba(1, 1, 1, 0.12)
		}

		Column {
			anchors.centerIn: parent
			spacing: 4

			Glyph {
				anchors.horizontalCenter: parent.horizontalCenter
				icon: ripple.sign > 0 ? "fast_forward" : "rewind"
				size: 34
				color: "white"
				surface: "transparent"
				animated: false
			}

			StyledText {
				anchors.horizontalCenter: parent.horizontalCenter
				text: `${ripple.count} s`
				tone: "white"
				surface: "transparent"
				font.weight: Font.DemiBold
			}
		}

		ParallelAnimation {
			id: rippleAnim

			SequentialAnimation {
				NumberAnimation {
					target: ripple
					property: "opacity"
					to: 1
					duration: 80
				}
				PauseAnimation {
					duration: 380
				}
				NumberAnimation {
					target: ripple
					property: "opacity"
					to: 0
					duration: 300
				}
			}
			NumberAnimation {
				target: rippleRing
				property: "scale"
				from: 0.6
				to: 1.25
				duration: 760
				easing.type: Easing.OutCubic
			}
		}
	}

	// ── above: the name and the ways in ────────────────────────────────────
	Item {
		id: topBar

		anchors.left: parent.left
		anchors.right: parent.right
		anchors.rightMargin: root.canSide ? root.paneWidth : 0
		height: root.small ? 44 : 76
		visible: opacity > 0.01 && !root.editing
		opacity: root.chrome && !root.editing ? 1 : 0
		transform: Translate {
			y: root.chrome ? 0 : -14

			Behavior on y {
				SpatialAnim {
					duration: Motion.long
				}
			}
		}

		Behavior on opacity {
			Anim {
				duration: Motion.long
			}
		}
		Behavior on anchors.rightMargin {
			SpatialAnim {
				duration: Motion.long
			}
		}

		HoverHandler {
			id: topHover
		}

		Rectangle {
			anchors.fill: parent
			anchors.bottomMargin: -30
			gradient: Gradient {
				GradientStop {
					position: 0
					color: Qt.rgba(0, 0, 0, 0.62)
				}
				GradientStop {
					position: 1
					color: "transparent"
				}
			}
		}

		Column {
			anchors.left: parent.left
			anchors.leftMargin: root.small ? 12 : 22
			anchors.right: topButtons.left
			anchors.rightMargin: 12
			anchors.verticalCenter: parent.verticalCenter
			spacing: 2

			StyledText {
				width: parent.width
				text: Video.title
				tone: "white"
				surface: "transparent"
				font.pixelSize: root.small ? Theme.size.body : Theme.size.heading
				font.weight: Font.DemiBold
			}

			StyledText {
				width: parent.width
				visible: !root.small && text !== ""
				text: [Video.episode?.label ?? "", Video.list.length > 1 ? `${Video.index + 1} of ${Video.list.length}` : "", Video.chapterNow >= 0 ? (Video.chapters[Video.chapterNow]?.title ?? "") : ""].filter(x => x).join("  ·  ")
				tone: Qt.rgba(1, 1, 1, 0.66)
				surface: "transparent"
				font.pixelSize: Theme.size.label
			}
		}

		Row {
			id: topButtons

			anchors.right: parent.right
			anchors.rightMargin: root.small ? 6 : 14
			anchors.verticalCenter: parent.verticalCenter
			spacing: 2

			OsdButton {
				tipBelow: true
				visible: !root.small && Video.list.length > 1
				icon: "playlist_play"
				tip: "Episodes (Q)"
				checked: root.pane === "playlist"
				onClicked: root.openPane("playlist")
			}
			OsdButton {
				tipBelow: true
				visible: !root.small
				icon: "subtitles_outline"
				tip: "Sound and subtitles (Shift+S)"
				checked: root.pane === "tracks"
				onClicked: root.openPane("tracks")
			}
			OsdButton {
				tipBelow: true
				visible: !root.small
				icon: "information_outline"
				tip: "About the file (I)"
				checked: root.pane === "info"
				onClicked: root.openPane("info")
			}
			OsdButton {
				tipBelow: true
				visible: !root.small
				icon: "tune_variant"
				tip: "Settings"
				checked: root.pane === "settings"
				onClicked: root.openPane("settings")
			}
			OsdButton {
				tipBelow: true
				visible: !root.small && Video.current
				icon: "movie_edit_outline"
				tip: "Edit (E)"
				onClicked: root.startEditing()
			}
			OsdButton {
				tipBelow: true
				icon: "close"
				tip: "Close (Esc)"
				onClicked: Video.close()
			}
		}
	}

	// ── below: the line along the film and the keys ────────────────────────
	Item {
		id: controls

		anchors.left: parent.left
		anchors.right: parent.right
		anchors.rightMargin: root.canSide ? root.paneWidth : 0
		anchors.bottom: parent.bottom
		height: root.small ? 52 : 104
		visible: opacity > 0.01 && !root.editing && Video.current
		opacity: root.chrome && !root.editing ? 1 : 0
		transform: Translate {
			y: root.chrome ? 0 : 18

			Behavior on y {
				SpatialAnim {
					duration: Motion.long
				}
			}
		}

		Behavior on opacity {
			Anim {
				duration: Motion.long
			}
		}
		Behavior on anchors.rightMargin {
			SpatialAnim {
				duration: Motion.long
			}
		}

		HoverHandler {
			id: controlsHover
		}

		Rectangle {
			anchors.fill: parent
			anchors.topMargin: -50
			gradient: Gradient {
				GradientStop {
					position: 0
					color: "transparent"
				}
				GradientStop {
					position: 1
					color: Qt.rgba(0, 0, 0, 0.72)
				}
			}
		}

		SeekBar {
			id: seek

			anchors.left: parent.left
			anchors.right: parent.right
			anchors.leftMargin: root.small ? 12 : 22
			anchors.rightMargin: root.small ? 12 : 22
			y: root.small ? 2 : 14
			accent: root.accent
			mark: Video.resumedFrom
			onSeekTo: seconds => Video.seek(seconds)
		}

		Item {
			anchors.left: parent.left
			anchors.right: parent.right
			anchors.leftMargin: root.small ? 6 : 16
			anchors.rightMargin: root.small ? 6 : 16
			anchors.top: seek.bottom
			anchors.bottom: parent.bottom
			anchors.bottomMargin: root.small ? 2 : 8

			Row {
				id: leftKeys

				anchors.left: parent.left
				anchors.verticalCenter: parent.verticalCenter
				spacing: root.small ? 0 : 4

				OsdButton {
					visible: !root.small && Video.list.length > 1
					icon: "skip_previous"
					tip: "Before (Page Up)"
					enabled: Video.hasPrevious || Video.position > 5
					onClicked: Video.previous()
				}
				OsdButton {
					visible: !root.small
					icon: "rewind_10"
					tip: "10 s back (J)"
					onClicked: Video.seekBy(-10)
				}
				PlayKey {
					size: root.small ? 38 : 48
					accent: root.accent
				}
				OsdButton {
					visible: !root.small
					icon: "fast_forward_10"
					tip: "10 s on (L)"
					onClicked: Video.seekBy(10)
				}
				OsdButton {
					visible: !root.small && Video.list.length > 1
					icon: "skip_next"
					tip: "Next (Page Down)"
					enabled: Video.hasNext
					onClicked: Video.next()
				}

				// the volume: the icon mutes, the line beside it grows on rest
				Item {
					id: volume

					readonly property bool open: volumeHover.hovered || volumeSlider.dragging
					width: muteKey.width + (volume.open && !root.small ? 104 : 0)
					height: 40
					clip: true

					Behavior on width {
						SpatialAnim {
							duration: Motion.medium
						}
					}

					HoverHandler {
						id: volumeHover
					}

					OsdButton {
						id: muteKey

						anchors.verticalCenter: parent.verticalCenter
						icon: Video.muted || Video.volume === 0 ? "volume_off" : (Video.volume < 40 ? "volume_low" : (Video.volume < 75 ? "volume_medium" : "volume_high"))
						tip: "Sound on or off (M)"
						onClicked: Video.muted = !Video.muted
					}

					PillSlider {
						id: volumeSlider

						anchors.left: muteKey.right
						anchors.leftMargin: 4
						anchors.verticalCenter: parent.verticalCenter
						width: 96
						height: 22
						wheelEnabled: false
						showValue: false
						accent: root.accent
						value: Video.muted ? 0 : Video.volume / 100
						onMoved: value => Video.setVolume(value * 100)
					}
				}

				// the time: a click shows what is left instead
				Clickable {
					anchors.verticalCenter: parent.verticalCenter
					width: timeLabel.implicitWidth + 16
					height: 32
					radius: 16
					color: "transparent"
					tint: "white"
					onClicked: Video.setSetting("timeLeft", !Video.setting("timeLeft", false))

					StyledText {
						id: timeLabel

						anchors.centerIn: parent
						tabular: true
						tone: "white"
						surface: "transparent"
						font.pixelSize: root.small ? Theme.size.small : Theme.size.label
						text: Video.setting("timeLeft", false) && Video.duration > 0 ? `−${Video.formatTime(Video.duration - Video.position)}` : `${Video.formatTime(Video.position)}${root.small ? "" : " / " + Video.formatTime(Video.duration)}`
					}
				}
			}

			Row {
				anchors.right: parent.right
				anchors.verticalCenter: parent.verticalCenter
				spacing: root.small ? 0 : 4

				OsdChip {
					id: speedChip

					anchors.verticalCenter: parent.verticalCenter
					visible: !root.small && Video.speed !== 1
					text: `${Video.speed}×`
					tip: "Speed ([ and ], Backspace 1×)"
					active: true
					onClicked: root.showSpeedMenu(speedChip)
				}
				OsdButton {
					id: speedKey

					visible: !root.small && Video.speed === 1
					icon: "speedometer"
					tip: "Speed ([ and ])"
					onClicked: root.showSpeedMenu(speedKey)
				}
				OsdButton {
					visible: !root.small
					icon: "repeat"
					tip: Video.looping ? "Loop: off (B)" : (Video.loopA >= 0 ? "Loop: set its end (B)" : "Loop a stretch (B)")
					checked: Video.loopA >= 0
					onClicked: Video.cycleLoop()
				}
				OsdButton {
					visible: !root.small && Video.subTracks.length > 0
					icon: Video.setting("subtitles", true) && Video.subFile ? "subtitles" : "subtitles_outline"
					tip: "Subtitles on or off (S)"
					checked: Video.setting("subtitles", true) && Video.subFile !== ""
					onClicked: root.toggleSubtitles()
				}
				OsdButton {
					visible: !root.small
					icon: "camera_outline"
					tip: "The picture as a file (Ctrl+Shift+S), copied (Ctrl+C)"
					onClicked: Video.snapshot(false)
				}
				OsdButton {
					id: shareKey

					visible: !root.small
					icon: "share_variant_outline"
					tip: "Share"
					onClicked: shareLoader.open(shareKey)
				}
				OsdButton {
					id: sleepKey

					visible: !root.small
					icon: "sleep"
					tip: "Sleep timer"
					checked: Video.sleepAt !== 0
					onClicked: root.showSleepMenu(sleepKey)
				}
				OsdButton {
					icon: Video.pip ? "arrow_expand" : "picture_in_picture_bottom_right_outline"
					tip: Video.pip ? "Back to its size (P)" : "Picture in picture (P)"
					onClicked: Video.togglePip()
				}
				OsdButton {
					visible: !Video.pip
					icon: Video.fullscreen ? "fullscreen_exit" : "fullscreen"
					tip: "Whole screen (F)"
					onClicked: Video.toggleFullscreen()
				}
			}
		}
	}

	// ── chips over the film ────────────────────────────────────────────────
	Column {
		id: chips

		anchors.right: parent.right
		anchors.rightMargin: (root.canSide ? root.paneWidth : 0) + (root.small ? 10 : 24)
		anchors.bottom: parent.bottom
		anchors.bottomMargin: root.chrome ? controls.height + 12 : 24
		spacing: 8
		visible: !root.editing

		Behavior on anchors.bottomMargin {
			SpatialAnim {
				duration: Motion.long
			}
		}

		// taken up where it was: the start instead
		BigChip {
			anchors.right: parent.right
			shownWhen: Video.resumedFrom > 0 && resumeShow.running
			icon: "restart"
			text: `Went on at ${Video.formatTime(Video.resumedFrom)} – from the start`
			onClicked: {
				Video.seek(0);
				resumeShow.stop();
			}

			Timer {
				id: resumeShow

				interval: 7000
			}

			Connections {
				target: Video

				function onResumedFromChanged() {
					if (Video.resumedFrom > 0) resumeShow.restart();
				}
			}
		}

		BigChip {
			anchors.right: parent.right
			shownWhen: Video.inIntro && !Video.introSkipped && Video.setting("skipIntro", "ask") === "ask"
			icon: "debug_step_over"
			text: "Skip the intro"
			strong: true
			onClicked: Video.skipIntro()
		}
	}

	// the next episode, as the credits come
	Clickable {
		id: nextCard

		readonly property bool due: Video.nearEnd && !root.small && !nextCard.dismissed
		property bool dismissed: false
		property real countdown: 10

		anchors.right: parent.right
		anchors.rightMargin: (root.canSide ? root.paneWidth : 0) + 24
		anchors.bottom: parent.bottom
		anchors.bottomMargin: root.chrome ? controls.height + 12 : 24
		width: 320
		height: 96
		radius: Theme.radius.large
		color: Qt.rgba(0.05, 0.05, 0.06, 0.88)
		tint: "white"
		visible: opacity > 0.01
		opacity: nextCard.due ? 1 : 0
		scale: nextCard.due ? 1 : 0.94
		onClicked: Video.next()

		Behavior on opacity {
			Anim {
				duration: Motion.long
			}
		}
		Behavior on scale {
			SpatialAnim {
				duration: Motion.long
			}
		}
		Behavior on anchors.bottomMargin {
			SpatialAnim {
				duration: Motion.long
			}
		}

		Connections {
			target: Video

			function onPathChanged() {
				nextCard.dismissed = false;
				nextCard.countdown = 10;
				nextFrame.source = "";
				if (Video.hasNext) Video.frameOf(Video.list[Video.index + 1], 60, file => nextFrame.source = file ? "file://" + file : "", 320);
			}
		}

		// credits: on after ten seconds, unless it is the film's end anyway
		Timer {
			running: nextCard.due && Video.playing && Video.setting("autoNext", true) && !!Video.outro
			repeat: true
			interval: 1000
			onTriggered: {
				nextCard.countdown -= 1;
				if (nextCard.countdown <= 0) Video.next();
			}
		}

		Image {
			id: nextFrame

			x: 8
			y: 8
			width: 128
			height: 80
			fillMode: Image.PreserveAspectCrop
			asynchronous: true
			layer.enabled: true
			layer.effect: MultiEffect {
				maskEnabled: true
				maskSource: nextMask
			}
		}

		Rectangle {
			id: nextMask

			width: 128
			height: 80
			radius: Theme.radius.medium
			visible: false
			layer.enabled: true
		}

		Column {
			anchors.left: nextFrame.right
			anchors.leftMargin: 12
			anchors.right: parent.right
			anchors.rightMargin: 34
			anchors.verticalCenter: parent.verticalCenter
			spacing: 3

			StyledText {
				text: Video.outro && Video.playing && Video.setting("autoNext", true) ? `Next in ${nextCard.countdown}` : "Next"
				tone: root.accent
				surface: "transparent"
				font.pixelSize: Theme.size.small
				font.weight: Font.DemiBold
			}

			StyledText {
				width: parent.width
				text: Video.hasNext ? Video.titleOf(Video.list[Video.index + 1]) : ""
				tone: "white"
				surface: "transparent"
				wrapMode: Text.WordWrap
				maximumLineCount: 2
				font.weight: Font.DemiBold
			}
		}

		OsdButton {
			anchors.right: parent.right
			anchors.top: parent.top
			anchors.margins: 4
			width: 28
			height: 28
			icon: "close"
			onClicked: nextCard.dismissed = true
		}
	}

	// ── panes ──────────────────────────────────────────────────────────────
	Rectangle {
		id: paneScrim

		anchors.fill: parent
		color: Theme.scrim
		visible: opacity > 0.01
		opacity: root.pane !== "" && !root.canSide && !root.editing ? 1 : 0

		Behavior on opacity {
			Anim {}
		}

		MouseArea {
			anchors.fill: parent
			enabled: paneScrim.visible
			onClicked: root.pane = ""
		}
	}

	Rectangle {
		id: paneBox

		readonly property bool open: root.pane !== "" && !root.editing

		anchors.top: parent.top
		anchors.bottom: parent.bottom
		width: root.canSide ? root.paneWidth : Math.min(root.width - 40, 380)
		x: paneBox.open ? root.width - paneBox.width : root.width + 20
		color: Theme.layer1
		visible: x < root.width
		layer.enabled: !root.canSide

		Behavior on x {
			SpatialAnim {
				duration: Motion.long
			}
		}

		Rectangle {
			width: 1
			height: parent.height
			color: Theme.outline
		}

		Item {
			anchors.fill: parent

			PaneSlot {
				name: "playlist"
				sourceComponent: PlaylistPane {
					accent: root.accent
					onClose: root.pane = ""
				}
			}
			PaneSlot {
				name: "tracks"
				sourceComponent: TracksPane {
					accent: root.accent
					onClose: root.pane = ""
				}
			}
			PaneSlot {
				name: "info"
				sourceComponent: InfoPane {
					accent: root.accent
					onClose: root.pane = ""
				}
			}
			PaneSlot {
				name: "settings"
				sourceComponent: SettingsPane {
					accent: root.accent
					onClose: root.pane = ""
				}
			}
		}
	}

	component PaneSlot: Loader {
		id: slot

		property string name: ""
		readonly property bool shown: root.pane === slot.name

		anchors.fill: parent
		active: slot.shown || slot.opacity > 0.01
		opacity: slot.shown ? 1 : 0
		visible: opacity > 0.01
		transform: Translate {
			y: slot.shown ? 0 : 14

			Behavior on y {
				SpatialAnim {}
			}
		}

		Behavior on opacity {
			Anim {}
		}
	}

	// ── the editor ─────────────────────────────────────────────────────────
	function startEditing() {
		if (!Video.current) return;
		root.pane = "";
		if (Video.pip) Video.togglePip();
		Video.startEditing();
	}

	Loader {
		id: editor

		anchors.fill: parent
		active: root.editing
		visible: status === Loader.Ready
		opacity: status === Loader.Ready ? 1 : 0
		z: 5
		onLoaded: editor.item.stage = stage

		Behavior on opacity {
			Anim {
				duration: Motion.long
			}
		}

		sourceComponent: Component {
			EditorView {
				accent: root.accent
				onLeave: {
					Video.stopEditing();
					root.takeFocus();
				}
			}
		}
	}

	Connections {
		target: Video

		function onPathChanged() {
			stage.resetView();
			stage.viewRot = 0;
			stage.aspectOverride = 0;
			if (Video.openEditor) {
				Video.openEditor = false;
				Qt.callLater(root.startEditing);
			}
		}

		function onSaid(text, icon) {
			toast.show(text, icon);
		}

		function onAct(name) {
			root.act(name);
		}

		function onSeeked(to) {
			root.wake();
		}
	}

	// ── menus ──────────────────────────────────────────────────────────────
	property real calmUntil: 0

	FileMenu {
		id: menu

		anchors.fill: parent
		z: 50
		onClosed: {
			root.calmUntil = Date.now() + 300;
			root.takeFocus();
		}
	}

	function anchorOf(item) {
		const p = item.mapToItem(root, 0, 0);
		return { x: p.x, y: p.y + item.height };
	}

	function showSpeedMenu(item) {
		const at = root.anchorOf(item);
		menu.show([0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 3].map(v => ({ label: v === 1 ? "Normal" : `${v}×`, checked: Math.abs(Video.speed - v) < 0.01, run: () => Video.setSpeed(v) }))
			.concat([{ separator: true }, { label: "Keep the pitch", checked: Video.setting("keepPitch", true), run: () => Video.setSetting("keepPitch", !Video.setting("keepPitch", true)) }]), at.x - 60, at.y - 380);
	}

	function showSleepMenu(item) {
		const at = root.anchorOf(item);
		menu.show([
			{ header: Video.sleepAt > 0 ? `Fades out at ${new Date(Video.sleepAt).toLocaleTimeString(Qt.locale(), "HH:mm")}` : (Video.sleepAt === -1 ? "Stops at the end" : "Sleep timer") },
			{ label: "At the end of this video", icon: "flag_checkered", checked: Video.sleepAt === -1, run: () => Video.sleep(-1) },
			{ label: "In 15 minutes", icon: "timer_outline", run: () => Video.sleep(15) },
			{ label: "In 30 minutes", icon: "timer_outline", run: () => Video.sleep(30) },
			{ label: "In an hour", icon: "timer_outline", run: () => Video.sleep(60) },
			{ label: "Off", icon: "timer_off_outline", enabled: Video.sleepAt !== 0, run: () => Video.sleep(0) }
		], at.x - 120, at.y - 260);
	}

	function toggleSubtitles() {
		if (!Video.subFile && Video.subTracks.length > 0) {
			Video.setSubFile(Video.subTracks[0].file);
			Video.setSetting("subtitles", true);
		} else Video.setSetting("subtitles", !Video.setting("subtitles", true));
		Video.say(Video.setting("subtitles", true) ? "Subtitles on" : "Subtitles off", "subtitles_outline");
	}

	function showMenu(x, y) {
		if (!Video.current) return;
		const path = Video.path;
		const at = Video.position;
		menu.show([
			{ label: Video.playing ? "Pause" : "Play", icon: Video.playing ? "pause" : "play", shortcut: "Space", run: () => Video.toggle() },
			{ label: "Edit", icon: "movie_edit_outline", shortcut: "E", run: () => root.startEditing() },
			{ separator: true },
			{ label: "Sound and subtitles", icon: "subtitles_outline", shortcut: "Shift+S", run: () => root.openPane("tracks") },
			{ label: "Episodes", icon: "playlist_play", shortcut: "Q", shown: Video.list.length > 1, run: () => root.openPane("playlist") },
			{ label: "Look", icon: "aspect_ratio", children: [
				{ label: "Fill the window", checked: stage.fill, run: () => stage.fill = !stage.fill },
				{ label: "Turn a quarter", icon: "rotate_right", shortcut: "R", run: () => stage.viewRot = (stage.viewRot + 1) % 4 },
				{ separator: true },
				{ header: "Shape" },
				{ label: "As the file says", checked: stage.aspectOverride === 0, run: () => stage.aspectOverride = 0 },
				{ label: "16:9", checked: Math.abs(stage.aspectOverride - 16 / 9) < 0.01, run: () => stage.aspectOverride = 16 / 9 },
				{ label: "4:3", checked: Math.abs(stage.aspectOverride - 4 / 3) < 0.01, run: () => stage.aspectOverride = 4 / 3 },
				{ label: "21:9", checked: Math.abs(stage.aspectOverride - 21 / 9) < 0.01, run: () => stage.aspectOverride = 21 / 9 },
				{ label: "1:1", checked: Math.abs(stage.aspectOverride - 1) < 0.01, run: () => stage.aspectOverride = 1 },
				{ separator: true },
				{ label: "Zoom back", icon: "magnify_minus_outline", enabled: stage.zoom > 1, shortcut: "Z", run: () => stage.resetView() }
			] },
			{ separator: true },
			{ label: "Save this picture", icon: "camera_outline", shortcut: "Ctrl+Shift+S", run: () => Video.snapshot(false) },
			{ label: "Copy this picture", icon: "content_copy", shortcut: "Ctrl+C", run: () => Video.snapshot(true) },
			{ label: "Edit this picture", icon: "image_edit_outline", shown: Plugins.on("viewer"), run: () => Video.request("snapshot", { path: path, t: at }, data => {
					if (data?.file) Viewer.open(data.file);
				}) },
			{ label: "A GIF of the next 5 seconds", icon: "file_gif_box", run: () => Video.gif(path, at, Math.min(Video.duration, at + 5)) },
			{ label: Video.looping ? "A GIF of the loop" : "A GIF of a loop (set it with B)", icon: "file_gif_box", enabled: Video.looping, run: () => Video.gif(path, Video.loopA, Video.loopB) },
			{ label: "Save the loop as a video", icon: "content_cut", enabled: Video.looping, run: () => Video.cutPart(path, Video.loopA, Video.loopB) },
			{ separator: true },
			{ label: "Picture in picture", icon: "picture_in_picture_bottom_right_outline", shortcut: "P", run: () => Video.togglePip() },
			{ label: "Whole screen", icon: "fullscreen", shortcut: "F", run: () => Video.toggleFullscreen() },
			{ label: "Show in Files", icon: "folder_open_outline", run: () => Files.reveal(path) },
			{ label: (Video.progressOf(path)?.watched ? "Not seen yet" : "Seen"), icon: "eye_check_outline", run: () => Video.setWatched(path, !Video.progressOf(path)?.watched) }
		], x, y);
	}

	// ── sharing (ShareMenu.qml) ────────────────────────────────────────────
	Loader {
		id: shareLoader

		property var anchorItem: null

		function open(item) {
			shareLoader.anchorItem = item;
			if (shareLoader.status === Loader.Ready) shareLoader.place();
			else shareLoader.active = true;
		}

		function place() {
			const at = root.anchorOf(shareLoader.anchorItem ?? root);
			if (shareLoader.item.popup) shareLoader.item.popup(at.x, at.y);
			else if (shareLoader.item.show) shareLoader.item.show(at.x, at.y);
			else if (shareLoader.item.open !== undefined) shareLoader.item.open = true;
		}

		anchors.fill: parent
		active: false
		z: 55
		source: Qt.resolvedUrl("ShareMenu.qml")
		onLoaded: {
			shareLoader.item.path = Qt.binding(() => Video.path);
			shareLoader.place();
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
		y: root.small ? 10 : (root.editing ? 60 : 24)
		width: Math.min(root.width - 24, toastRow.implicitWidth + 28)
		height: 40
		radius: 20
		color: Qt.rgba(0.07, 0.07, 0.08, 0.9)
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
				surface: "transparent"
			}

			StyledText {
				id: toastText

				anchors.verticalCenter: parent.verticalCenter
				tone: "white"
				surface: "transparent"
			}
		}

		Timer {
			id: toastTimer

			interval: 3000
			onTriggered: toast.opacity = 0
		}
	}

	// ── videos dropped on the window ───────────────────────────────────────
	DropArea {
		anchors.fill: parent
		keys: ["text/uri-list"]
		onDropped: drop => {
			const paths = (drop.urls || []).map(u => Video.plainPath(u.toString())).filter(p => Video.isVideo(p));
			const words = (drop.urls || []).map(u => Video.plainPath(u.toString())).filter(p => /\.(srt|vtt|ass|ssa)$/i.test(p));
			if (words.length > 0 && Video.current) {
				Video.setSubFile(words[0]);
				Video.say("Subtitles from the file dropped", "subtitles_outline");
			}
			if (paths.length === 0) return;
			if (root.editing) editor.item?.addClips(paths);
			else Video.openMany(paths);
		}
	}

	// ── keys ───────────────────────────────────────────────────────────────
	function act(name) {
		switch (name) {
		case "play-pause": return Video.toggle();
		case "fullscreen": return Video.toggleFullscreen();
		case "pip": return Video.togglePip();
		case "edit": return root.editing ? editor.item?.leave() : root.startEditing();
		case "info": return root.openPane("info");
		case "subtitles": return root.openPane("tracks");
		case "audio": return root.openPane("tracks");
		case "playlist": return root.openPane("playlist");
		case "settings": return root.openPane("settings");
		case "snapshot": return Video.snapshot(false);
		case "copy-frame": return Video.snapshot(true);
		case "close-pane": return root.pane = "";
		case "rotate": return stage.viewRot = (stage.viewRot + 1) % 4;
		case "fill": return stage.fill = !stage.fill;
		case "menu": return root.showMenu(root.width / 2, root.height / 2);
		}
		if (root.editing && editor.item) editor.item.act(name);
	}

	Keys.onPressed: event => {
		if (root.editing) return;
		const ctrl = event.modifiers & Qt.ControlModifier, shift = event.modifiers & Qt.ShiftModifier;
		root.wake();
		let handled = true;
		switch (event.key) {
		case Qt.Key_Space:
		case Qt.Key_K:
			Video.toggle();
			flash.show(Video.playing ? "play" : "pause");
			break;
		case Qt.Key_Left:
			if (ctrl) Video.previous();
			else root.jumpBy(shift ? -30 : -5, root.width * 0.15, root.height / 2);
			break;
		case Qt.Key_Right:
			if (ctrl) Video.next();
			else root.jumpBy(shift ? 30 : 5, root.width * 0.85, root.height / 2);
			break;
		case Qt.Key_J:
			root.jumpBy(-10, root.width * 0.15, root.height / 2);
			break;
		case Qt.Key_L:
			root.jumpBy(10, root.width * 0.85, root.height / 2);
			break;
		case Qt.Key_Up:
			Video.setVolume(Video.volume + 5);
			Video.say(`Volume ${Video.volume} %`, "volume_high");
			break;
		case Qt.Key_Down:
			Video.setVolume(Video.volume - 5);
			Video.say(`Volume ${Video.volume} %`, "volume_medium");
			break;
		case Qt.Key_M:
			Video.muted = !Video.muted;
			break;
		case Qt.Key_F:
		case Qt.Key_Return:
		case Qt.Key_Enter:
			Video.toggleFullscreen();
			break;
		case Qt.Key_P:
			Video.togglePip();
			break;
		case Qt.Key_E:
			root.startEditing();
			break;
		case Qt.Key_I:
			root.openPane("info");
			break;
		case Qt.Key_Q:
			root.openPane("playlist");
			break;
		case Qt.Key_S:
			if (ctrl && shift) Video.snapshot(false);
			else if (shift) root.openPane("tracks");
			else root.toggleSubtitles();
			break;
		case Qt.Key_C:
			if (ctrl) Video.snapshot(true);
			else handled = false;
			break;
		case Qt.Key_A:
			if (Video.audioTracks.length > 1) {
				const next = (Video.audioTrack + 1) % Video.audioTracks.length;
				Video.setAudioTrack(next);
				const t = Video.audioTracks[next];
				Video.say(`Sound: ${[t.title, t.lang].filter(x => x).join(" · ") || "track " + (next + 1)}`, "translate");
			}
			break;
		case Qt.Key_B:
			Video.cycleLoop();
			break;
		case Qt.Key_BracketLeft:
			Video.setSpeed(Video.speed - 0.25);
			Video.say(`Speed ${Video.speed}×`, "speedometer");
			break;
		case Qt.Key_BracketRight:
			Video.setSpeed(Video.speed + 0.25);
			Video.say(`Speed ${Video.speed}×`, "speedometer");
			break;
		case Qt.Key_Backspace:
			Video.setSpeed(1);
			break;
		case Qt.Key_Comma:
			Video.step(-1);
			break;
		case Qt.Key_Period:
			Video.step(1);
			break;
		case Qt.Key_PageUp:
			Video.previous();
			break;
		case Qt.Key_PageDown:
			Video.next();
			break;
		case Qt.Key_N:
			Video.next();
			break;
		case Qt.Key_Home:
			Video.seek(0);
			break;
		case Qt.Key_End:
			Video.seek(Video.duration - 3);
			break;
		case Qt.Key_Z:
			if (stage.zoom > 1) stage.resetView();
			else stage.zoomAt(2, root.width / 2, root.height / 2);
			break;
		case Qt.Key_R:
			stage.viewRot = (stage.viewRot + 1) % 4;
			break;
		case Qt.Key_G:
			Video.subDelay !== 0 || shift ? Video.setSubDelay(Video.subDelay + (shift ? 0.1 : -0.1)) : Video.setSubDelay(-0.1);
			Video.say(`Subtitles ${Video.subDelay > 0 ? "+" : ""}${Video.subDelay.toFixed(1)} s`, "subtitles_outline");
			break;
		case Qt.Key_H:
			Video.setSubDelay(Video.subDelay + 0.1);
			Video.say(`Subtitles ${Video.subDelay > 0 ? "+" : ""}${Video.subDelay.toFixed(1)} s`, "subtitles_outline");
			break;
		case Qt.Key_Escape:
			if (Date.now() < root.calmUntil) break;
			if (root.pane !== "") root.pane = "";
			else if (stage.zoom > 1) stage.resetView();
			else if (Video.fullscreen) Video.toggleFullscreen();
			else if (Video.pip) Video.togglePip();
			else Video.close();
			break;
		default:
			if (event.key >= Qt.Key_0 && event.key <= Qt.Key_9 && !ctrl) Video.seek(Video.duration * (event.key - Qt.Key_0) / 10);
			else handled = false;
		}
		event.accepted = handled;
	}

	// ── small parts ────────────────────────────────────────────────────────
	// a round key drawn on the film: white, a dark glass when hovered
	component OsdButton: Clickable {
		id: osd

		property string icon: ""
		property string tip: ""
		property bool checked: false
		property bool tipBelow: false

		implicitWidth: root.small ? 34 : 40
		implicitHeight: root.small ? 34 : 40
		radius: osd.checked ? Theme.radius.medium : height / 2
		color: osd.checked ? Qt.alpha(root.accent, 0.32) : (osd.hovered ? Qt.rgba(1, 1, 1, 0.14) : "transparent")
		tint: "white"
		opacity: osd.enabled ? 1 : 0.38

		Behavior on radius {
			SpatialAnim {}
		}

		Glyph {
			anchors.centerIn: parent
			icon: osd.icon
			size: Math.round(osd.height * 0.52)
			color: "white"
			surface: "transparent"
		}

		ToolTipLabel {
			text: osd.tip
			below: osd.tipBelow
			shown: osd.hovered && osd.tip !== ""
		}
	}

	component OsdChip: Clickable {
		id: chip

		property string text: ""
		property string tip: ""
		property bool active: false

		implicitWidth: chipLabel.implicitWidth + 20
		implicitHeight: 30
		radius: 15
		color: chip.active ? Qt.alpha(root.accent, 0.32) : (chip.hovered ? Qt.rgba(1, 1, 1, 0.14) : Qt.rgba(1, 1, 1, 0.08))
		tint: "white"

		StyledText {
			id: chipLabel

			anchors.centerIn: parent
			text: chip.text
			tone: "white"
			surface: "transparent"
			font.pixelSize: Theme.size.label
			font.weight: Font.DemiBold
			tabular: true
		}
	}

	// a chip that rises when it is due and sinks when it is not
	component BigChip: Clickable {
		id: big

		property string icon: ""
		property string text: ""
		property bool shownWhen: false
		property bool strong: false

		implicitWidth: bigRow.implicitWidth + 30
		implicitHeight: 44
		radius: 22
		color: big.strong ? (big.hovered ? Qt.lighter(root.accent, 1.1) : root.accent) : (big.hovered ? Qt.rgba(0.16, 0.16, 0.18, 0.95) : Qt.rgba(0.07, 0.07, 0.08, 0.85))
		tint: big.strong ? Theme.onPrimary : "white"
		visible: opacity > 0.01
		opacity: big.shownWhen ? 1 : 0
		transform: Translate {
			x: big.shownWhen ? 0 : 24

			Behavior on x {
				SpatialAnim {
					duration: Motion.long
				}
			}
		}

		Behavior on opacity {
			Anim {
				duration: Motion.long
			}
		}

		Row {
			id: bigRow

			anchors.centerIn: parent
			spacing: 8

			Glyph {
				anchors.verticalCenter: parent.verticalCenter
				icon: big.icon
				size: 18
				color: big.strong ? Theme.readableOn("white", root.accent) : "white"
				surface: "transparent"
			}

			StyledText {
				anchors.verticalCenter: parent.verticalCenter
				text: big.text
				tone: big.strong ? Theme.readableOn("white", root.accent) : "white"
				surface: "transparent"
				font.weight: Font.DemiBold
			}
		}
	}

	// the big key: its shape turns with its glyph
	component PlayKey: Clickable {
		id: play

		property real size: 48
		property color accent: Theme.primary

		width: play.size
		height: play.size
		anchors.verticalCenter: parent?.verticalCenter
		radius: Video.playing ? play.size * 0.32 : play.size / 2
		color: play.hovered ? Qt.lighter(play.accent, 1.1) : play.accent
		tint: Theme.onPrimary
		sound: ""
		onClicked: Video.toggle()

		Behavior on radius {
			SpatialAnim {}
		}

		Glyph {
			anchors.centerIn: parent
			anchors.horizontalCenterOffset: Video.playing ? 0 : play.size * 0.03
			icon: Video.ended ? "replay" : (Video.playing ? "pause" : "play")
			size: Math.round(play.size * 0.5)
			color: Theme.readableOn("white", play.accent)
			surface: "transparent"
		}
	}

	component ToolTipLabel: Rectangle {
		id: tipBox

		property string text: ""
		property bool shown: false
		property bool below: false

		anchors.horizontalCenter: parent.horizontalCenter
		y: tipBox.below ? parent.height + 6 : -height - 6
		width: tipText.implicitWidth + 16
		height: 26
		radius: 13
		color: Qt.rgba(0.06, 0.06, 0.07, 0.92)
		opacity: tipBox.shown ? 1 : 0
		visible: opacity > 0.01
		z: 100

		Behavior on opacity {
			SequentialAnimation {
				PauseAnimation {
					duration: tipBox.shown ? 500 : 0
				}
				Anim {
					duration: Motion.short
				}
			}
		}

		StyledText {
			id: tipText

			anchors.centerIn: parent
			text: tipBox.text
			tone: "white"
			surface: "transparent"
			font.pixelSize: Theme.size.small
		}
	}
}
