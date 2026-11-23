pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.style.widgets
import qs.core.services

// The beat along the bottom: its wave with the bars, where each line starts
// and the chosen spot that Stop goes back to. A click chooses the spot,
// Shift and a drag mark a stretch played again and again.
Item {
	id: bar

	implicitHeight: 92

	readonly property real duration: Math.max(0.001, Rhymes.beatDuration || 0)
	readonly property bool known: Rhymes.beatDuration > 0

	function xOf(seconds) {
		return wave.width * Math.max(0, Math.min(1, seconds / bar.duration));
	}

	function timeOf(x) {
		return Math.max(0, Math.min(bar.duration, x / Math.max(1, wave.width) * bar.duration));
	}

	// the beat's length is known once it was loaded
	Component.onCompleted: if (Rhymes.hasBeat && !bar.known) Rhymes.ensureBeat(() => {})

	Connections {
		target: Rhymes

		function onBeatPathChanged() {
			if (Rhymes.hasBeat) Rhymes.ensureBeat(() => {});
		}
	}

	Row {
		id: keys

		x: 14
		anchors.verticalCenter: parent.verticalCenter
		spacing: 6

		Clickable {
			id: playKey

			width: 48
			height: 48
			radius: Rhymes.beatPlaying ? 16 : 24
			color: Theme.primary
			tint: Theme.onPrimary
			sound: ""
			onClicked: Rhymes.playPause()

			Behavior on radius {
				SpatialAnim {}
			}

			Glyph {
				anchors.centerIn: parent
				anchors.horizontalCenterOffset: Rhymes.beatPlaying ? 0 : 1.5
				icon: Rhymes.beatPlaying ? "stop" : "play"
				size: 24
				color: Theme.onPrimary
			}
		}

		Column {
			anchors.verticalCenter: parent.verticalCenter
			width: 74
			spacing: 0

			StyledText {
				text: Format.clock(Rhymes.position, 1)
				tabular: true
				font.pixelSize: Theme.size.title
				font.weight: Font.Medium
			}

			StyledText {
				text: Format.clock(Rhymes.beatDuration)
				tabular: true
				font.pixelSize: Theme.size.small
				tone: Theme.textSubtle
			}
		}
	}

	// ── the wave ───────────────────────────────────────────────────────────
	Item {
		id: wave

		anchors.left: keys.right
		anchors.leftMargin: 14
		anchors.right: tools.left
		anchors.rightMargin: 14
		anchors.verticalCenter: parent.verticalCenter
		height: 58

		// the bars of the beat
		Canvas {
			id: grid

			anchors.fill: parent
			opacity: 0.9
			onPaint: {
				const ctx = getContext("2d");
				ctx.reset();
				const bpm = Rhymes.song?.bpm ?? 0;
				if (!(bpm > 0) || !bar.known) return;
				const beat = 60 / bpm;
				const per = Rhymes.song?.bar || 4;
				const step = beat * per;
				// too close together: every fourth bar
				const every = width / (bar.duration / step) < 6 ? 4 : 1;
				ctx.fillStyle = Theme.textFaint;
				let n = 0;
				for (let t = (Rhymes.song?.offset ?? 0) % step; t < bar.duration; t += step, n += 1) {
					if (n % every !== 0) continue;
					const x = Math.round(bar.xOf(t));
					ctx.globalAlpha = n % (every * 4) === 0 ? 0.9 : 0.4;
					ctx.fillRect(x, 0, 1, n % (every * 4) === 0 ? height : 6);
				}
			}

			Connections {
				target: Rhymes

				function onSongChanged() {
					grid.requestPaint();
				}

				function onBeatDurationChanged() {
					grid.requestPaint();
				}
			}

			onWidthChanged: grid.requestPaint()
		}

		component WaveCanvas: Canvas {
			id: canvas

			property color tone: Theme.textFaint

			onToneChanged: requestPaint()
			onWidthChanged: requestPaint()
			onPaint: {
				const ctx = getContext("2d");
				ctx.reset();
				const values = Rhymes.wave;
				if (!values || values.length === 0) return;
				ctx.fillStyle = canvas.tone;
				const n = Math.max(1, Math.floor(wave.width / 3));
				const middle = height / 2;
				for (let i = 0; i < n; i += 1) {
					const v = values[Math.floor(i / n * values.length)] || 0;
					const h = Math.max(2, v * (height - 14));
					ctx.fillRect(i * 3, middle - h / 2, 2, h);
				}
			}

			Connections {
				target: Rhymes

				function onWaveChanged() {
					canvas.requestPaint();
				}
			}
		}

		WaveCanvas {
			anchors.fill: parent
			tone: Theme.layer3
			opacity: Rhymes.wave.length > 0 ? 1 : 0

			Behavior on opacity {
				Anim {
					duration: Motion.extraLong
				}
			}
		}

		// what was played: the same wave in the accent, cut at the position
		Item {
			width: bar.xOf(Rhymes.position)
			height: parent.height
			clip: true

			WaveCanvas {
				width: wave.width
				height: wave.height
				tone: Theme.primary
			}
		}

		// the stretch played again and again
		Rectangle {
			x: bar.xOf(Rhymes.loopA)
			width: bar.xOf(Rhymes.loopB) - x
			height: parent.height
			radius: 6
			color: Theme.primarySoft
			border.width: 1
			border.color: Qt.alpha(Theme.primary, 0.5)
			opacity: Rhymes.looping ? 1 : 0
			visible: opacity > 0

			Behavior on opacity {
				Anim {}
			}
		}

		// where each line starts
		Repeater {
			model: {
				void Rhymes.analysis;
				void Rhymes.song;
				return Rhymes.marks().map(m => ({ row: m.row, t: m.t, text: Rhymes.lines.get(m.shows).text }));
			}

			Item {
				id: mark

				required property var modelData
				readonly property bool current: Rhymes.row === mark.modelData.row

				x: bar.xOf(mark.modelData.t) - 6
				y: -6
				width: 12
				height: wave.height + 6
				z: 2

				Rectangle {
					anchors.horizontalCenter: parent.horizontalCenter
					y: 6
					width: mark.current ? 2 : 1
					height: wave.height
					color: mark.current ? Theme.primary : Theme.textSubtle
					opacity: mark.current ? 1 : 0.6
				}

				Rectangle {
					anchors.horizontalCenter: parent.horizontalCenter
					width: mark.current || markHover.hovered ? 9 : 6
					height: width
					radius: width / 2
					color: mark.current ? Theme.primary : Theme.textMuted

					Behavior on width {
						SpatialAnim {}
					}
				}

				HoverHandler {
					id: markHover
				}

				TapHandler {
					onTapped: {
						Rhymes.jump(mark.modelData.row, 0);
						Rhymes.play(Math.max(0, mark.modelData.t - 0.15));
					}
				}

				// the line, over the wave
				Rectangle {
					visible: markHover.hovered
					x: Math.min(-tipText.implicitWidth / 2, wave.width - mark.x - tipText.implicitWidth - 24)
					y: -tipText.implicitHeight - 14
					width: tipText.implicitWidth + 16
					height: tipText.implicitHeight + 8
					radius: Theme.radius.small
					color: Theme.layer3

					StyledText {
						id: tipText

						anchors.centerIn: parent
						text: mark.modelData.text.slice(0, 60)
						font.pixelSize: Theme.size.small
					}
				}
			}
		}

		// the chosen spot
		Rectangle {
			x: bar.xOf(Rhymes.cue) - 1
			width: 2
			height: parent.height
			radius: 1
			color: Theme.tertiary
			opacity: bar.known ? 0.9 : 0

			Behavior on x {
				SpatialAnim {
					duration: Motion.short
				}
			}

			Rectangle {
				anchors.horizontalCenter: parent.horizontalCenter
				anchors.bottom: parent.bottom
				width: 8
				height: 8
				radius: 2
				rotation: 45
				color: Theme.tertiary
			}
		}

		// the position
		Rectangle {
			x: bar.xOf(Rhymes.position) - 1
			width: 2
			height: parent.height + 8
			y: -4
			radius: 1
			color: Theme.text
			opacity: Rhymes.beatPlaying ? 1 : 0

			Behavior on opacity {
				Anim {}
			}
		}

		// the time under the pointer
		Rectangle {
			visible: area.containsMouse && bar.known
			x: Math.max(0, Math.min(wave.width - width, area.mouseX - width / 2))
			y: wave.height + 2
			width: hoverText.implicitWidth + 10
			height: hoverText.implicitHeight + 4
			radius: 4
			color: Theme.layer3

			StyledText {
				id: hoverText

				anchors.centerIn: parent
				text: Format.clock(bar.timeOf(area.mouseX), 1)
				tabular: true
				font.pixelSize: Theme.size.tiny
			}
		}

		MouseArea {
			id: area

			property real from: -1

			anchors.fill: parent
			hoverEnabled: true
			cursorShape: Qt.PointingHandCursor
			onPressed: mouse => {
				area.from = mouse.modifiers & Qt.ShiftModifier ? bar.timeOf(mouse.x) : -1;
				if (area.from >= 0) Rhymes.setLoop(area.from, area.from);
			}
			onPositionChanged: mouse => {
				if (area.pressed && area.from >= 0) {
					const t = bar.timeOf(mouse.x);
					Rhymes.loopA = Math.min(area.from, t);
					Rhymes.loopB = Math.max(area.from, t);
				}
			}
			onReleased: mouse => {
				if (area.from >= 0) {
					Rhymes.setLoop(Rhymes.loopA, Rhymes.loopB);
					if (Rhymes.looping) Rhymes.play(Rhymes.loopA);
					area.from = -1;
					return;
				}
				const t = bar.timeOf(mouse.x);
				if (Rhymes.beatPlaying) Rhymes.play(t);
				else Rhymes.seek(t);
			}
		}
	}

	// ── the tempo, the speed, the loop ─────────────────────────────────────
	Row {
		id: tools

		anchors.right: parent.right
		anchors.rightMargin: 14
		anchors.verticalCenter: parent.verticalCenter
		spacing: 4

		Clickable {
			id: tempo

			anchors.verticalCenter: parent.verticalCenter
			width: tempoColumn.implicitWidth + 20
			height: 44
			radius: Theme.radius.medium
			color: "transparent"
			acceptedButtons: Qt.LeftButton | Qt.RightButton
			// a tap of the click counts the tempo; a right click asks the helper again
			onClicked: Rhymes.tap()
			onRightClicked: Rhymes.request("tempo", { id: Rhymes.song.id })

			Column {
				id: tempoColumn

				anchors.centerIn: parent

				RollText {
					anchors.horizontalCenter: parent.horizontalCenter
					text: Rhymes.jobRunning("tempo") ? "…" : ((Rhymes.song?.bpm ?? 0) > 0 ? String(Rhymes.song.bpm) : "–")
					pixelSize: Theme.size.title
					weight: Font.Medium
				}

				StyledText {
					anchors.horizontalCenter: parent.horizontalCenter
					text: "BPM"
					font.pixelSize: Theme.size.tiny
					font.letterSpacing: 1
					tone: Theme.textSubtle
				}
			}
		}

		Clickable {
			anchors.verticalCenter: parent.verticalCenter
			width: 52
			height: 36
			radius: Theme.radius.medium
			color: Rhymes.speed !== 1 ? Theme.primarySoft : "transparent"
			// 1×, slower to practise, a little faster
			onClicked: {
				const steps = [1, 0.85, 0.7, 1.1];
				Rhymes.setSpeed(steps[(steps.indexOf(Rhymes.speed) + 1) % steps.length]);
			}

			StyledText {
				anchors.centerIn: parent
				text: `${Rhymes.speed}×`
				tone: Rhymes.speed !== 1 ? Theme.primary : Theme.textMuted
			}
		}

		IconButton {
			anchors.verticalCenter: parent.verticalCenter
			width: 36
			height: 36
			icon: "metronome"
			checked: Rhymes.metronome
			onClicked: Rhymes.toggleMetronome()
		}

		IconButton {
			anchors.verticalCenter: parent.verticalCenter
			width: 36
			height: 36
			icon: "repeat"
			checked: Rhymes.looping
			onClicked: Rhymes.loopSection(Rhymes.row)
		}

		IconButton {
			anchors.verticalCenter: parent.verticalCenter
			width: 36
			height: 36
			icon: "dots_vertical"
			onClicked: beatMenu.show(this, 0, -beatMenu.implicitHeight - 4)
		}
	}

	SmallMenu {
		id: beatMenu

		parent: bar
		entries: [
			{ text: "Another beat", icon: "swap_horizontal", action: () => Rhymes.pickBeat() },
			{ text: "Play in Music", icon: "playlist_music", action: () => Rhymes.playInMusic(Rhymes.song?.id) },
			{ text: "No beat", icon: "close", danger: true, action: () => Rhymes.dropBeat() }
		]
	}
}
