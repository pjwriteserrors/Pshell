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
	readonly property bool canSide: !root.mini && root.width >= 860
	readonly property bool side: root.canSide && Music.pane !== ""
	// narrow: the pane asked for lies over the player for a while
	property string sheet: ""

	function openPane(name) {
		if (root.canSide) Music.showPane(name);
		else root.sheet = root.sheet === name ? "" : name;
	}

	function paneShown(name) {
		return root.canSide ? Music.pane === name : root.sheet === name;
	}
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
		id: ambientLayer

		property alias source: picture.source
		property bool front: false

		anchors.fill: parent
		opacity: ambientLayer.front && picture.status === Image.Ready ? 0.7 : 0

		Behavior on opacity {
			NumberAnimation {
				duration: 900
			}
		}

		// blurred where it is small, then stretched: soft at any size, cheap
		Item {
			id: small

			width: 64
			height: Math.max(16, Math.round(64 * ambientLayer.height / Math.max(1, ambientLayer.width)))
			scale: ambientLayer.width / 64
			transformOrigin: Item.TopLeft
			layer.enabled: true
			layer.smooth: true

			Image {
				id: picture

				anchors.fill: parent
				anchors.margins: -8
				sourceSize: Qt.size(24, 24)
				fillMode: Image.PreserveAspectCrop
				smooth: true
				asynchronous: true
				visible: false
			}

			MultiEffect {
				anchors.fill: picture
				source: picture
				blurEnabled: true
				blur: 1
				blurMax: 32
				blurMultiplier: 1
				saturation: 0.1
			}
		}
	}

	// the sound, faint along the bottom
	ExternalCava {
		id: cava

		bars: 64
		framerate: 50
		active: root.shown && Music.playing && !root.mini && Music.visualizer !== "off"
	}

	Row {
		id: bars

		anchors.left: parent.left
		anchors.right: parent.right
		anchors.bottom: parent.bottom
		height: Math.min(120, root.height * 0.2)
		spacing: 3
		opacity: cava.active && Music.visualizer === "bars" ? 0.28 : 0
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
			root.openPane("queue");
			break;
		case Qt.Key_L:
			root.openPane("lyrics");
			break;
		case Qt.Key_E:
			root.openPane("sound");
			break;
		case Qt.Key_T:
			root.openPane("tags");
			break;
		case Qt.Key_B:
			Music.cycleLoop();
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
			if (sleepMenu.open) sleepMenu.open = false;
			else if (root.sheet !== "" && !root.canSide) root.sheet = "";
			else Music.close();
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
	// Laid out by its room: the cover above the words when there is height,
	// beside them when the window is wide and low, gone when it would be a
	// stamp. A change of layout glides; resizing by hand follows at once.
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

		readonly property real margin: Math.round(Math.max(20, Math.min(44, Math.min(player.width, player.height) * 0.06)))
		readonly property bool compact: player.height < 560 || player.width < 440
		// so low that only one row of tools fits under the keys
		readonly property bool low: !player.wide && player.height < 400
		readonly property real gap: player.compact ? 20 : 30
		// beside the words the cover leaves them room for a row of tools at least
		readonly property real wideCover: Math.min(player.height - 2 * player.margin, player.width * 0.44, 440, player.width - player.gap - 2 * player.margin - 280)
		readonly property bool wide: player.width > player.height * 1.15 && player.height < 640 && player.wideCover >= 140
		readonly property real infoW: player.wide ? Math.min(520, player.width - player.wideCover - player.gap - 2 * player.margin) : Math.min(560, player.width - 2 * player.margin)
		readonly property real tallCover: Math.min(player.width - 2 * player.margin, player.height - info.height - player.gap - 2 * player.margin, 460)
		readonly property real coverSize: player.wide ? player.wideCover : Math.max(0, player.tallCover)
		readonly property bool coverShown: player.wide || player.tallCover >= 112
		readonly property real contentW: player.wide ? player.coverSize + player.gap + player.infoW : player.infoW
		readonly property real contentH: player.wide ? Math.max(player.coverSize, info.height) : (player.coverShown ? player.coverSize + player.gap : 0) + info.height
		readonly property real startX: Math.round((player.width - player.contentW) / 2)
		readonly property real startY: Math.round(Math.max(player.margin * 0.5, (player.height - player.contentH) / 2))

		// a new layout glides into place for a moment
		property bool settling: false

		function settle() {
			if (!root.shown) return;
			player.settling = true;
			settleTimer.restart();
		}

		onWideChanged: player.settle()
		onCoverShownChanged: player.settle()

		Timer {
			id: settleTimer

			interval: Motion.extraLong + 60
			onTriggered: player.settling = false
		}

		// the sound in a ring around the cover
		Item {
			id: ring

			readonly property real inner: player.coverSize * 0.5 + 10
			readonly property real reach: Math.max(14, player.coverSize * 0.12)

			x: cover.x + cover.width / 2
			y: cover.y + cover.height / 2
			opacity: cava.active && Music.visualizer === "ring" && player.coverShown ? 0.55 : 0
			visible: opacity > 0.01

			Behavior on opacity {
				Anim {
					duration: Motion.extraLong
				}
			}

			Repeater {
				model: Music.visualizer === "ring" ? 72 : 0

				delegate: Rectangle {
					required property int index
					// the low notes at the top, the high ones below, the same on both sides
					readonly property real level: cava.values[Math.floor((index < 36 ? index : 72 - index) / 36 * (cava.bars - 1))] || 0

					width: 3
					height: 2 + level * ring.reach
					radius: 1.5
					color: root.accent
					antialiasing: true
					x: -width / 2
					y: -ring.inner - height
					transform: Rotation {
						origin.x: 1.5
						origin.y: ring.inner + height
						angle: index * 5
					}
				}
			}
		}

		CoverArt {
			id: cover

			x: player.wide ? player.startX : Math.round((player.width - player.coverSize) / 2)
			y: player.wide ? Math.round((player.height - player.coverSize) / 2) : player.startY
			width: player.coverSize
			height: player.coverSize
			corner: Math.min(Theme.radius.huge, Math.max(Theme.radius.medium, player.coverSize * 0.06))
			accent: root.accent
			opacity: player.coverShown ? 1 : 0
			scale: player.coverShown ? 1 : 0.86
			visible: opacity > 0.01

			Behavior on x {
				enabled: player.settling
				SpatialAnim {
					duration: Motion.extraLong
				}
			}
			Behavior on y {
				enabled: player.settling
				SpatialAnim {
					duration: Motion.extraLong
				}
			}
			Behavior on width {
				enabled: player.settling
				SpatialAnim {
					duration: Motion.extraLong
				}
			}
			Behavior on height {
				enabled: player.settling
				SpatialAnim {
					duration: Motion.extraLong
				}
			}
			Behavior on opacity {
				Anim {}
			}
			Behavior on scale {
				SpatialAnim {}
			}

			MouseArea {
				anchors.fill: parent
				cursorShape: Qt.PointingHandCursor
				onClicked: Music.toggle()
			}
		}

		Column {
			id: info

			readonly property bool centered: !player.wide

			x: player.wide ? player.startX + player.coverSize + player.gap : Math.round((player.width - player.infoW) / 2)
			y: player.wide ? Math.round((player.height - info.height) / 2) : player.startY + (player.coverShown ? player.coverSize + player.gap : 0)
			width: player.infoW
			spacing: 0

			Behavior on x {
				enabled: player.settling
				SpatialAnim {
					duration: Motion.extraLong
				}
			}
			Behavior on y {
				enabled: player.settling
				SpatialAnim {
					duration: Motion.extraLong
				}
			}

			SwapText {
				width: parent.width
				text: Music.current ? Music.titleOf(Music.path) : (Music.queue.length === 0 ? "Nothing to play" : "Stopped")
				pixelSize: player.compact ? 24 : Theme.size.display
				weight: Font.Black
				tone: Theme.text
				centered: info.centered
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
					const artist = Music.artistOf(Music.path);
					return [artist, t?.album].filter(x => x).join(" · ");
				}
				pixelSize: player.compact ? Theme.size.body : Theme.size.title
				weight: Font.Medium
				tone: Theme.textMuted
				centered: info.centered
			}

			// what the file is, small; the chapter of an audiobook; the loop
			Item {
				width: 1
				height: 6
				visible: fileLine.visible
			}

			SwapText {
				id: fileLine

				width: parent.width
				visible: text !== "" && player.height >= 360
				centered: info.centered
				tone: Music.looping ? root.accent : Theme.textSubtle
				pixelSize: Theme.size.small
				text: {
					const t = Music.song;
					if (!t) return "";
					if (Music.looping) return `Looping ${Music.formatTime(Music.loopA)} – ${Music.formatTime(Music.loopB)}`;
					if (Music.chapterNow >= 0 && Music.chapters.length > 1) return `${Music.chapters[Music.chapterNow].title} · ${Music.chapterNow + 1} of ${Music.chapters.length}`;
					const parts = [t.codec];
					if (t.rate) parts.push(`${(t.rate / 1000).toFixed(t.rate % 1000 === 0 ? 0 : 1)} kHz`);
					if (t.bits) parts.push(`${t.bits} bit`);
					else if (t.kbps) parts.push(`${t.kbps} kbps`);
					if (Music.eqOn) parts.push(Music.setting("eqPreset", "EQ"));
					return parts.filter(p => p).join(" · ");
				}
			}

			Item {
				width: 1
				height: player.compact ? 14 : 22
			}

			WaveSeek {
				width: parent.width
				height: player.compact ? 44 : 56
				accent: root.accent
			}

			Item {
				width: parent.width
				height: 22

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
				height: player.compact ? 2 : 6
			}

			// the keys
			Row {
				id: keys

				readonly property real big: player.compact ? 60 : 72
				readonly property real step: player.compact ? 44 : 52

				x: info.centered ? Math.round((info.width - keys.width) / 2) : -8
				spacing: player.infoW < 340 ? 6 : 14

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
					visible: root.audiobook && player.infoW >= 380
					width: 42
					height: 42
					icon: "rewind_30"
					onClicked: Music.seekBy(-30)
				}

				IconButton {
					anchors.verticalCenter: parent.verticalCenter
					width: keys.step
					height: keys.step
					icon: "skip_previous"
					iconSize: keys.step * 0.58
					enabled: Music.queue.length > 0
					onClicked: Music.previous()
				}

				PlayButton {
					anchors.verticalCenter: parent.verticalCenter
					size: keys.big
					accent: root.accent
				}

				IconButton {
					anchors.verticalCenter: parent.verticalCenter
					width: keys.step
					height: keys.step
					icon: "skip_next"
					iconSize: keys.step * 0.58
					enabled: Music.queue.length > 1 || Music.repeatMode !== "off"
					onClicked: Music.next()
				}

				IconButton {
					anchors.verticalCenter: parent.verticalCenter
					visible: root.audiobook && player.infoW >= 380
					width: 42
					height: 42
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
				height: player.compact ? 10 : 16
			}

			// the rest: one row when it fits, else two
			Grid {
				id: tools

				readonly property bool oneRow: player.low || toolsA.implicitWidth + toolsB.implicitWidth + 8 <= info.width

				x: info.centered ? Math.round((info.width - tools.width) / 2) : 0
				columns: tools.oneRow ? 2 : 1
				columnSpacing: 8
				rowSpacing: 8
				horizontalItemAlignment: info.centered ? Grid.AlignHCenter : Grid.AlignLeft

				Row {
					id: toolsA

					visible: !player.low
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
						id: sleepChip

						icon: Music.sleepThen === "shutdown" ? "power" : (Music.sleepThen === "suspend" ? "power_sleep" : "sleep")
						active: Music.sleepAt !== 0
						text: {
							if (Music.sleepAt === -1) return "after this";
							if (Music.sleepAt > 0) return `${Math.max(1, Math.ceil((Music.sleepAt - clock.now) / 60000))} min`;
							return "";
						}
						tip: "Sleep timer – click for 15, 30, 60 minutes or after this song; right-click for more"
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
						onRightClicked: sleepMenu.open = !sleepMenu.open
					}

					ToolChip {
						icon: "repeat_variant"
						active: Music.loopA >= 0
						text: Music.looping ? "A–B" : (Music.loopA >= 0 ? "A…" : "")
						tip: "Loop a stretch – click at its start, again at its end, again to stop (B)"
						onClicked: Music.cycleLoop()
						onRightClicked: Music.clearLoop()
					}

					PillSlider {
						anchors.verticalCenter: parent.verticalCenter
						width: player.compact ? 120 : 150
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
				}

				Row {
					id: toolsB

					spacing: 6

					// low: the speed comes along, the rest waits for more room (or its keys)
					ToolChip {
						visible: player.low
						icon: "speedometer"
						text: Music.speed === 1 ? "" : `${Music.speed}×`
						active: Music.speed !== 1
						tip: "Speed – click for faster, right-click back to normal"
						onClicked: {
							const steps = [1, 1.25, 1.5, 1.75, 2, 0.75];
							Music.setSpeed(steps[(steps.indexOf(Music.speed) + 1) % steps.length]);
						}
						onRightClicked: Music.setSpeed(1)
					}

					ToolChip {
						icon: "equalizer"
						active: root.paneShown("sound") || Music.eqOn
						tip: "Sound – equalizer, pitch, fading between songs (E)"
						onClicked: root.openPane("sound")
					}

					ToolChip {
						icon: "tag_outline"
						active: root.paneShown("tags")
						tip: "Tags and cover (T)"
						onClicked: root.openPane("tags")
					}

					ToolChip {
						icon: "text_box_outline"
						active: root.paneShown("lyrics")
						tip: "Lyrics (L)"
						onClicked: root.openPane("lyrics")
					}

					ToolChip {
						icon: "playlist_music"
						active: root.paneShown("queue")
						tip: "Queue (Q)"
						onClicked: root.openPane("queue")
					}

					ToolChip {
						icon: "arrow_collapse"
						tip: "Small window (M)"
						onClicked: Music.toggleMini(root.width, root.height)
					}
				}
			}
		}

		// a click beside the card closes it
		MouseArea {
			anchors.fill: parent
			z: 29
			visible: sleepMenu.open
			onClicked: sleepMenu.open = false
		}

		// what the sleep timer may do after: a few words on a card above its chip
		Rectangle {
			id: sleepMenu

			property bool open: false
			property point at: Qt.point(0, 0)

			onOpenChanged: if (sleepMenu.open) sleepMenu.at = sleepChip.mapToItem(player, 0, 0)

			x: Math.max(8, Math.min(player.width - width - 8, sleepMenu.at.x + sleepChip.width / 2 - width / 2))
			y: sleepMenu.at.y - height - 8
			width: 220
			height: sleepColumn.implicitHeight + 12
			radius: Theme.radius.large
			color: Theme.layer3
			z: 30
			opacity: sleepMenu.open ? 1 : 0
			scale: sleepMenu.open ? 1 : 0.94
			transformOrigin: Item.Bottom
			visible: opacity > 0.01

			Behavior on opacity {
				Anim {}
			}
			Behavior on scale {
				SpatialAnim {}
			}

			Column {
				id: sleepColumn

				anchors.centerIn: parent
				width: parent.width - 12

				Repeater {
					model: [
						{ label: "In 15 minutes", run: () => Music.sleep(15) },
						{ label: "In 30 minutes", run: () => Music.sleep(30) },
						{ label: "In an hour", run: () => Music.sleep(60) },
						{ label: "After this song", run: () => Music.sleep(-1) },
						{ label: Music.sleepThen === "suspend" ? "✓ Then suspend the PC" : "Then suspend the PC", run: () => Music.sleepThen = Music.sleepThen === "suspend" ? "" : "suspend", keep: true },
						{ label: Music.sleepThen === "shutdown" ? "✓ Then shut the PC down" : "Then shut the PC down", run: () => Music.sleepThen = Music.sleepThen === "shutdown" ? "" : "shutdown", keep: true },
						{ label: "Off", run: () => Music.sleep(0) }
					]

					delegate: Clickable {
						id: entry

						required property var modelData

						width: sleepColumn.width
						height: 32
						radius: Theme.radius.medium
						color: entry.hovered ? Theme.layer2 : "transparent"
						onClicked: {
							entry.modelData.run();
							if (!entry.modelData.keep) sleepMenu.open = false;
						}

						StyledText {
							anchors.verticalCenter: parent.verticalCenter
							x: 12
							text: entry.modelData.label
						}
					}
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

	// ── beside it, or over it when narrow: the queue, the words, the sound, the tags
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

		PaneHost {
			anchors.fill: parent
			which: root.side ? Music.pane : ""
		}
	}

	// narrow: the pane rises over the player as a sheet
	Item {
		id: sheet

		readonly property bool open: root.sheet !== "" && !root.mini && !root.canSide
		// the last one stays while it slides away
		property string shownName: ""

		onOpenChanged: if (sheet.open) sheet.shownName = root.sheet
		Connections {
			target: root

			function onSheetChanged() {
				if (root.sheet !== "") sheet.shownName = root.sheet;
			}
		}

		anchors.left: parent.left
		anchors.right: parent.right
		height: parent.height
		y: sheet.open ? 0 : parent.height + 20
		visible: y < parent.height
		z: 40

		Behavior on y {
			SpatialAnim {
				duration: Motion.extraLong
			}
		}

		// the player behind it, dimmed
		Rectangle {
			anchors.fill: parent
			color: Theme.base
			opacity: 0.97
		}

		MouseArea {
			anchors.fill: parent
			// nothing goes through to the player
		}

		PaneHost {
			anchors.fill: parent
			anchors.topMargin: 22
			anchors.leftMargin: 20
			anchors.rightMargin: 20
			anchors.bottomMargin: 14
			which: sheet.open || sheet.visible ? sheet.shownName : ""
		}

		IconButton {
			anchors.top: parent.top
			anchors.right: parent.right
			anchors.topMargin: 14
			anchors.rightMargin: 14
			width: 36
			height: 36
			icon: "close"
			onClicked: root.sheet = ""
		}
	}

	component PaneHost: Item {
		id: host

		property string which: ""

		PaneSlot {
			name: "queue"
			which: host.which
			sourceComponent: QueuePane {
				accent: root.accent
			}
		}

		PaneSlot {
			name: "lyrics"
			which: host.which
			sourceComponent: LyricsPane {
				accent: root.accent
			}
		}

		PaneSlot {
			name: "sound"
			which: host.which
			sourceComponent: SoundPane {
				accent: root.accent
			}
		}

		PaneSlot {
			name: "tags"
			which: host.which
			sourceComponent: TagsPane {
				accent: root.accent
			}
		}
	}

	// one pane: made when first wanted, crossfading and rising a little as it comes
	component PaneSlot: Loader {
		id: slot

		property string name: ""
		property string which: ""
		readonly property bool shown: slot.which === slot.name

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

			// a voice message: its speed at hand
			ToolChip {
				anchors.verticalCenter: parent.verticalCenter
				visible: Music.voicePath !== "" && Music.path === Music.voicePath
				text: `${Music.speed}×`
				active: Music.speed !== 1
				tip: "Speed of voice messages"
				onClicked: {
					const steps = [1, 1.5, 2];
					const next = steps[(steps.indexOf(Music.speed) + 1) % steps.length];
					Music.setSetting("voiceSpeed", next);
					Music.setSpeed(next);
				}
			}

			IconButton {
				anchors.verticalCenter: parent.verticalCenter
				width: 36
				height: 36
				icon: "skip_previous"
				// a voice message: back and on mean nothing
				visible: Music.voicePath === "" || Music.path !== Music.voicePath
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
				visible: Music.voicePath === "" || Music.path !== Music.voicePath
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
