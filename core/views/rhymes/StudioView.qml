pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import qs.style.theme
import qs.style.widgets
import qs.core.services

// The song as tracks: the beat and the recordings, clips moved along the
// bars, cut and trimmed; below them the mixer, and a track's effects.
Item {
	id: studio

	readonly property real duration: Math.max(Rhymes.beatDuration, Rhymes.studio.duration || 0, 10)
	readonly property real fit: Math.max(4, (lanes.width - 40) / studio.duration)
	// pixels a second; 0 = the whole song in view
	property real zoom: 0
	readonly property real pps: studio.zoom > 0 ? studio.zoom : studio.fit
	property real scrollX: 0
	readonly property real contentWidth: studio.duration * studio.pps + 40
	property string selected: ""
	property string fxTrack: ""
	property bool mixerOpen: Rhymes.setting("mixer", true)
	readonly property real beatLength: Rhymes.song?.bpm > 0 ? 60 / Rhymes.song.bpm : 0
	readonly property int rowHeight: 68
	readonly property int headWidth: 176

	function xOf(t) {
		return t * studio.pps - studio.scrollX;
	}

	function timeOf(x) {
		return Math.max(0, (x + studio.scrollX) / studio.pps);
	}

	// to the nearest sixteenth when the song has a tempo
	function snap(t, free) {
		if (free || studio.beatLength <= 0) return t;
		const step = studio.beatLength / 4;
		const offset = Rhymes.song?.offset || 0;
		return offset + Math.round((t - offset) / step) * step;
	}

	function scrollBy(dx) {
		studio.scrollX = Math.max(0, Math.min(studio.contentWidth - lanes.width, studio.scrollX + dx));
	}

	function zoomAt(factor, x) {
		const t = studio.timeOf(x);
		studio.zoom = Math.max(studio.fit, Math.min(600, studio.pps * factor));
		studio.scrollX = Math.max(0, t * studio.pps - x);
		if (studio.zoom <= studio.fit * 1.01) {
			studio.zoom = 0;
			studio.scrollX = 0;
		}
	}

	function trackColor(index) {
		const tones = [Theme.primary, Theme.tertiary, Theme.success, Theme.warning, Theme.secondary, Theme.danger];
		return tones[index % tones.length];
	}

	// the playhead stays in view while playing
	Connections {
		target: Rhymes

		function onPositionChanged() {
			if (!Rhymes.beatPlaying || studio.zoom === 0) return;
			const x = studio.xOf(Rhymes.position);
			if (x > lanes.width - 60 || x < 0) studio.scrollX = Math.max(0, Rhymes.position * studio.pps - 80);
		}
	}

	Component.onCompleted: if (Rhymes.tracks.length === 0) Rhymes.loadStudio()

	// ── the bar on top ───────────────────────────────────────────────────
	Row {
		id: tools

		x: 12
		y: 6
		height: 40
		spacing: 6

		// a take from the spot chosen on the tracks
		Clickable {
			anchors.verticalCenter: parent.verticalCenter
			width: recordRow.implicitWidth + 24
			height: 34
			radius: 17
			color: Rhymes.recording ? Theme.danger : Qt.alpha(Theme.danger, 0.14)
			tint: Rhymes.recording ? "#ffffff" : Theme.danger
			enabled: Rhymes.hasBeat
			sound: ""
			onClicked: Rhymes.record()

			Behavior on color {
				ColorAnim {}
			}

			Row {
				id: recordRow

				anchors.centerIn: parent
				spacing: 8

				Rectangle {
					anchors.verticalCenter: parent.verticalCenter
					width: 12
					height: 12
					radius: Rhymes.recording ? 2 : 6
					color: Rhymes.recording ? "#ffffff" : Theme.danger
				}

				StyledText {
					anchors.verticalCenter: parent.verticalCenter
					text: Rhymes.recording ? Format.clock(Math.max(0, Rhymes.position - Rhymes.recordFrom), 1) : `from ${Format.clock(Rhymes.recordFrom, 1)}`
					tabular: true
					font.weight: Font.Medium
					tone: Rhymes.recording ? "#ffffff" : Theme.danger
				}
			}
		}

		TextButton {
			anchors.verticalCenter: parent.verticalCenter
			icon: "plus"
			text: "Track"
			variant: "ghost"
			onClicked: Rhymes.addTrack("")
		}

		IconButton {
			anchors.verticalCenter: parent.verticalCenter
			width: 34
			height: 34
			icon: "content_cut"
			enabled: Rhymes.clips.some(c => c.start < Rhymes.position && Rhymes.position < c.start + c.length)
			opacity: enabled ? 1 : 0.4
			onClicked: studio.selected !== "" ? Rhymes.splitClip(studio.selected, Rhymes.position) : Rhymes.splitAtPlayhead()
		}

		IconButton {
			anchors.verticalCenter: parent.verticalCenter
			width: 34
			height: 34
			icon: "headphones"
			checked: Rhymes.monitorOn
			onClicked: Rhymes.setMonitor(!Rhymes.monitorOn)
		}

		IconButton {
			anchors.verticalCenter: parent.verticalCenter
			width: 34
			height: 34
			icon: "magnify_minus_outline"
			enabled: studio.zoom > 0
			opacity: enabled ? 1 : 0.4
			onClicked: studio.zoomAt(0.67, lanes.width / 2)
		}

		IconButton {
			anchors.verticalCenter: parent.verticalCenter
			width: 34
			height: 34
			icon: "magnify_plus_outline"
			onClicked: studio.zoomAt(1.5, Math.max(0, studio.xOf(Rhymes.position)))
		}
	}

	// the line sung now, large, and the one after it
	Item {
		id: nowLine

		readonly property var after: {
			void Rhymes.analysis;
			const all = Rhymes.marks();
			const at = Rhymes.playingMark ? Rhymes.playingMark.t : Rhymes.position;
			const next = all.find(m => m.t > at + 0.01);
			return next ? Rhymes.lines.get(next.shows)?.text ?? "" : "";
		}

		anchors.left: tools.right
		anchors.leftMargin: 20
		anchors.right: rightTools.left
		anchors.rightMargin: 20
		y: 6
		height: 40
		visible: Rhymes.playingMark !== null || Rhymes.beatPlaying

		Row {
			anchors.verticalCenter: parent.verticalCenter
			width: parent.width
			spacing: 16

			StyledText {
				id: nowText

				anchors.verticalCenter: parent.verticalCenter
				width: Math.min(implicitWidth, nowLine.width * 0.62)
				text: Rhymes.playingMark ? Rhymes.lines.get(Rhymes.playingMark.shows)?.text ?? "" : ""
				elide: Text.ElideRight
				font.pixelSize: Theme.size.title ?? 18
				font.weight: Font.DemiBold
				tone: Theme.primary
			}

			StyledText {
				anchors.verticalCenter: parent.verticalCenter
				width: nowLine.width - nowText.width - 16
				text: nowLine.after
				elide: Text.ElideRight
				tone: Theme.textSubtle
			}
		}
	}

	Row {
		id: rightTools

		anchors.right: parent.right
		anchors.rightMargin: 12
		y: 6
		height: 40
		spacing: 6

		// the beat's key (right click: listen again)
		Clickable {
			anchors.verticalCenter: parent.verticalCenter
			width: keyRow.implicitWidth + 24
			height: 34
			radius: 17
			color: Theme.layer1
			visible: Rhymes.hasBeat
			acceptedButtons: Qt.RightButton
			onRightClicked: Rhymes.findKey()

			Row {
				id: keyRow

				anchors.centerIn: parent
				spacing: 8

				Glyph {
					anchors.verticalCenter: parent.verticalCenter
					icon: "music_note"
					size: 15
					color: Theme.textMuted
				}

				StyledText {
					anchors.verticalCenter: parent.verticalCenter
					text: Rhymes.jobRunning("key") ? "…" : (Rhymes.song?.key?.name ?? "Key")
					font.weight: Font.Medium
				}

				StyledText {
					anchors.verticalCenter: parent.verticalCenter
					visible: !!Rhymes.song?.key && !Rhymes.jobRunning("key")
					text: Rhymes.song?.key?.camelot ?? ""
					tabular: true
					tone: Theme.textMuted
				}
			}
		}

		TextButton {
			anchors.verticalCenter: parent.verticalCenter
			icon: "file_export_outline"
			text: Rhymes.jobRunning("stems") ? "Exporting…" : "Export tracks"
			variant: "ghost"
			busy: Rhymes.jobRunning("stems")
			onClicked: Rhymes.exportTracks()
		}

		IconButton {
			anchors.verticalCenter: parent.verticalCenter
			width: 34
			height: 34
			icon: "tune_vertical"
			checked: studio.mixerOpen
			onClicked: {
				studio.mixerOpen = !studio.mixerOpen;
				Rhymes.setSetting("mixer", studio.mixerOpen);
			}
		}
	}

	// ── the tracks ───────────────────────────────────────────────────────
	Item {
		id: timeline

		anchors.top: tools.bottom
		anchors.topMargin: 6
		anchors.left: parent.left
		anchors.right: parent.right
		anchors.bottom: mixer.top

		// the ruler: bars, click to put the spot there
		Item {
			id: ruler

			x: studio.headWidth
			width: parent.width - studio.headWidth
			height: 26
			clip: true

			Repeater {
				model: {
					const bar = studio.beatLength * (Rhymes.song?.bar || 4);
					const out = [];
					if (bar > 0) {
						// fewer numbers when they would crowd
						let every = 1;
						while (bar * every * studio.pps < 44) every *= 2;
						const first = Math.max(0, Math.floor((studio.scrollX / studio.pps - (Rhymes.song?.offset || 0)) / bar / every) * every);
						for (let n = first; n < first + 200; n += every) {
							const t = (Rhymes.song?.offset || 0) + n * bar;
							if (t > studio.duration || studio.xOf(t) > ruler.width) break;
							out.push({ t: t, label: String(n + 1) });
						}
					} else {
						let every = 1;
						while (every * studio.pps < 56) every *= 2;
						for (let t = Math.floor(studio.scrollX / studio.pps / every) * every; t <= studio.duration && studio.xOf(t) <= ruler.width; t += every)
							out.push({ t: t, label: Format.clock(t) });
					}
					return out;
				}

				Item {
					required property var modelData

					x: studio.xOf(modelData.t)
					height: ruler.height

					Rectangle {
						width: 1
						height: 8
						anchors.bottom: parent.bottom
						color: Theme.outline
					}

					StyledText {
						x: 4
						y: 3
						text: parent.modelData.label
						tabular: true
						font.pixelSize: Theme.size.small
						tone: Theme.textSubtle
					}
				}
			}

			MouseArea {
				anchors.fill: parent
				onClicked: mouse => {
					const t = studio.timeOf(mouse.x);
					Rhymes.cue = t;
					Rhymes.seek(t);
				}
			}
		}

		Flickable {
			id: rows

			anchors.top: ruler.bottom
			anchors.left: parent.left
			anchors.right: parent.right
			anchors.bottom: hbar.top
			contentHeight: column.height + 20
			clip: true
			boundsBehavior: Flickable.StopAtBounds
			ScrollBar.vertical: ThinScrollBar {}

			Column {
				id: column

				width: rows.width
				spacing: 4

				LyricsRow {}

				Repeater {
					model: Rhymes.tracks

					TrackRow {}
				}

				// a track more, dropped onto
				Clickable {
					x: 12
					width: studio.headWidth - 24
					height: 36
					radius: Theme.radius.medium
					color: "transparent"
					onClicked: Rhymes.addTrack("")

					Row {
						anchors.centerIn: parent
						spacing: 6

						Glyph {
							anchors.verticalCenter: parent.verticalCenter
							icon: "plus"
							size: 16
							color: Theme.textMuted
						}

						StyledText {
							anchors.verticalCenter: parent.verticalCenter
							text: "Track"
							tone: Theme.textMuted
						}
					}
				}
			}
		}

		// the playhead and the spot, over every lane
		Item {
			id: lanes

			anchors.top: ruler.top
			anchors.left: ruler.left
			anchors.right: parent.right
			height: Math.min(parent.height - hbar.height, ruler.height + column.height - 44 - rows.contentY)
			clip: true

			Rectangle {
				x: studio.xOf(Rhymes.cue) - 1
				width: 2
				height: parent.height
				color: Theme.textFaint
				visible: x >= -2 && x <= parent.width
			}

			Rectangle {
				x: studio.xOf(Rhymes.position) - 1
				width: 2
				height: parent.height
				color: Theme.primary
				visible: x >= -2 && x <= parent.width
			}

			Rectangle {
				x: studio.xOf(Rhymes.loopA)
				width: (Rhymes.loopB - Rhymes.loopA) * studio.pps
				height: ruler.height
				color: Theme.primary
				opacity: 0.18
				visible: Rhymes.looping
			}
		}

		// across: the wheel with Shift, Ctrl to zoom
		WheelHandler {
			target: null
			acceptedModifiers: Qt.ShiftModifier
			onWheel: event => studio.scrollBy(-(event.angleDelta.y || event.angleDelta.x) / 2)
		}

		WheelHandler {
			target: null
			acceptedModifiers: Qt.ControlModifier
			onWheel: event => studio.zoomAt(event.angleDelta.y > 0 ? 1.25 : 0.8, event.x - studio.headWidth)
		}

		ScrollBar {
			id: hbar

			anchors.left: ruler.left
			anchors.right: parent.right
			anchors.bottom: parent.bottom
			height: 10
			orientation: Qt.Horizontal
			policy: studio.zoom > 0 ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff
			size: Math.min(1, lanes.width / studio.contentWidth)
			position: studio.scrollX / studio.contentWidth
			onPositionChanged: if (pressed) studio.scrollX = position * studio.contentWidth
		}
	}

	// ── the mixer ────────────────────────────────────────────────────────
	Rectangle {
		id: mixer

		anchors.left: parent.left
		anchors.right: parent.right
		anchors.bottom: parent.bottom
		height: studio.mixerOpen ? Math.min(300, studio.height * 0.45) : 0
		color: Theme.layer1
		radius: Theme.radius.huge
		clip: true

		Behavior on height {
			SpatialAnim {}
		}

		Flickable {
			id: strips

			anchors.fill: parent
			anchors.margins: 10
			contentWidth: stripRow.width
			flickableDirection: Flickable.HorizontalFlick
			boundsBehavior: Flickable.StopAtBounds
			clip: true
			ScrollBar.horizontal: ThinScrollBar {}

			Row {
				id: stripRow

				height: strips.height
				spacing: 8

				Repeater {
					model: Rhymes.tracks

					Strip {}
				}
			}
		}
	}

	// ── a track's effects, over the right side ───────────────────────────
	Rectangle {
		anchors.fill: parent
		color: Theme.scrim
		opacity: studio.fxTrack !== "" ? 1 : 0
		visible: opacity > 0

		Behavior on opacity {
			Anim {}
		}

		MouseArea {
			anchors.fill: parent
			onClicked: studio.fxTrack = ""
		}
	}

	FxPanel {
		width: Math.min(380, studio.width - 40)
		height: parent.height - 16
		y: 8
		x: studio.fxTrack !== "" ? studio.width - width - 8 : studio.width + 20
		track: studio.fxTrack
		onCloseRequested: studio.fxTrack = ""

		Behavior on x {
			SpatialAnim {}
		}
	}

	SmallMenu {
		id: clipMenu
	}

	Keys.onPressed: event => {
		if (event.modifiers & (Qt.ControlModifier | Qt.AltModifier)) return;
		if (event.key === Qt.Key_Space) {
			Rhymes.playPause();
		} else if (event.key === Qt.Key_S) {
			studio.selected !== "" ? Rhymes.splitClip(studio.selected, Rhymes.position) : Rhymes.splitAtPlayhead();
		} else if ((event.key === Qt.Key_Delete || event.key === Qt.Key_Backspace) && studio.selected !== "") {
			Rhymes.dropTake(studio.selected);
			studio.selected = "";
		} else return;
		event.accepted = true;
	}

	// ── the words, each timed line where it starts ───────────────────────
	component LyricsRow: Item {
		id: words

		readonly property var marks: {
			void Rhymes.analysis;
			void Rhymes.song;
			void Rhymes.lines.count;
			const all = Rhymes.marks();
			return all.map((m, i) => ({ t: m.t, end: i + 1 < all.length ? all[i + 1].t : Math.min(studio.duration, m.t + 6), row: m.row, ref: m.ref, text: Rhymes.lines.get(m.shows)?.text ?? "" }));
		}

		width: column.width
		height: 44
		visible: words.marks.length > 0

		Rectangle {
			x: 8
			width: studio.headWidth - 14
			height: parent.height
			radius: Theme.radius.large
			color: Theme.layer1

			Row {
				x: 14
				anchors.verticalCenter: parent.verticalCenter
				spacing: 8

				Glyph {
					anchors.verticalCenter: parent.verticalCenter
					icon: "text_box_outline"
					size: 16
					color: Theme.textMuted
				}

				StyledText {
					anchors.verticalCenter: parent.verticalCenter
					text: "Lyrics"
					font.weight: Font.Medium
				}
			}
		}

		Item {
			x: studio.headWidth
			width: parent.width - studio.headWidth - 8
			height: parent.height
			clip: true

			Repeater {
				model: words.marks

				Clickable {
					id: block

					required property var modelData
					readonly property bool now: Rhymes.playingMark !== null && Rhymes.playingMark.t === block.modelData.t && Rhymes.playingMark.row === block.modelData.row

					x: studio.xOf(block.modelData.t)
					width: Math.max(6, (block.modelData.end - block.modelData.t) * studio.pps - 2)
					height: parent.height
					radius: Theme.radius.small
					color: block.now ? Theme.primary : Theme.layer1
					tint: block.now ? Theme.onPrimary : Theme.text
					sound: ""
					onClicked: {
						Rhymes.cue = block.modelData.t;
						Rhymes.seek(block.modelData.t);
						studio.forceActiveFocus();
					}

					Behavior on color {
						ColorAnim {}
					}

					StyledText {
						x: 8
						anchors.verticalCenter: parent.verticalCenter
						width: parent.width - 12
						text: block.modelData.text
						elide: Text.ElideRight
						visible: parent.width > 24
						font.weight: block.now ? Font.DemiBold : Font.Normal
						tone: block.now ? Theme.onPrimary : Theme.textMuted
					}
				}
			}
		}
	}

	// ── one track: its head and its lane ─────────────────────────────────
	component TrackRow: Item {
		id: row

		required property var modelData
		required property int index
		readonly property color tone: studio.trackColor(row.index)
		readonly property bool beat: row.modelData.kind === "beat"
		readonly property bool armed: Rhymes.armed === row.modelData.id

		width: column.width
		height: studio.rowHeight

		Rectangle {
			id: head

			x: 8
			width: studio.headWidth - 14
			height: parent.height
			radius: Theme.radius.large
			color: Theme.layer1

			Rectangle {
				x: 8
				y: 10
				width: 4
				height: parent.height - 20
				radius: 2
				color: row.tone
			}

			TextInput {
				id: name

				x: 20
				y: 9
				width: parent.width - 28
				text: row.modelData.name
				color: Theme.text
				font.family: Theme.fontFamily
				font.pixelSize: Theme.size.body
				font.weight: Font.Medium
				clip: true
				selectByMouse: true
				onEditingFinished: if (text.trim() !== "" && text !== row.modelData.name) Rhymes.editTrack(row.modelData.id, { name: text.trim() })
			}

			Row {
				x: 16
				anchors.bottom: parent.bottom
				anchors.bottomMargin: 6
				spacing: 2

				SmallToggle {
					text: "M"
					on: row.modelData.mute
					tone: Theme.warning
					onClicked: Rhymes.editTrack(row.modelData.id, { mute: !row.modelData.mute })
				}

				SmallToggle {
					text: "S"
					on: row.modelData.solo
					tone: Theme.success
					onClicked: Rhymes.editTrack(row.modelData.id, { solo: !row.modelData.solo })
				}

				IconButton {
					width: 26
					height: 26
					visible: !row.beat
					icon: "record"
					iconColor: row.armed ? Theme.danger : Theme.textFaint
					onClicked: Rhymes.armedTrack = row.modelData.id
				}

				IconButton {
					width: 26
					height: 26
					icon: "tune_vertical"
					iconColor: row.modelData.fx.length > 0 ? Theme.primary : Theme.textFaint
					onClicked: studio.fxTrack = row.modelData.id
				}

				IconButton {
					width: 26
					height: 26
					visible: !row.beat
					icon: "dots_vertical"
					onClicked: trackMenu.show(this, 0, height)
				}
			}

			SmallMenu {
				id: trackMenu

				entries: [
					{ text: "Up", icon: "arrow_up", enabled: row.index > 0, action: () => Rhymes.moveTrack(row.modelData.id, row.index - 1) },
					{ text: "Down", icon: "arrow_down", enabled: row.index < Rhymes.tracks.length - 1, action: () => Rhymes.moveTrack(row.modelData.id, row.index + 1) },
					{ text: "Delete with its takes", icon: "delete_outline", danger: true, action: () => Rhymes.dropTrack(row.modelData.id) }
				]
			}
		}

		// the lane
		Rectangle {
			id: lane

			x: studio.headWidth
			width: parent.width - studio.headWidth - 8
			height: parent.height
			radius: Theme.radius.medium
			color: row.armed && Rhymes.recording ? Qt.alpha(Theme.danger, 0.08) : Qt.alpha(Theme.layer1, 0.5)
			clip: true

			// the bars
			Repeater {
				model: {
					const bar = studio.beatLength * (Rhymes.song?.bar || 4);
					if (bar <= 0 || bar * studio.pps < 14) return [];
					const out = [];
					const offset = Rhymes.song?.offset || 0;
					const first = Math.max(0, Math.floor((studio.scrollX / studio.pps - offset) / bar));
					for (let n = first; n < first + 400; n += 1) {
						const x = studio.xOf(offset + n * bar);
						if (x > lane.width) break;
						out.push(x);
					}
					return out;
				}

				Rectangle {
					required property real modelData

					x: modelData
					width: 1
					height: lane.height
					color: Theme.outline
					opacity: 0.5
				}
			}

			// the beat: its wave all along
			WaveShape {
				visible: row.beat
				x: studio.xOf(0)
				width: (Rhymes.beatDuration || studio.duration) * studio.pps
				height: lane.height
				values: Rhymes.wave
				from: 0
				span: 1
				tone: row.tone
			}

			MouseArea {
				anchors.fill: parent
				onClicked: mouse => {
					studio.selected = "";
					studio.forceActiveFocus();
					const t = studio.timeOf(mouse.x);
					Rhymes.cue = t;
					Rhymes.seek(t);
				}
			}

			Repeater {
				model: row.beat ? [] : Rhymes.clips.filter(c => c.track === row.modelData.id)

				ClipItem {
					tone: row.tone
					rowIndex: row.index
				}
			}
		}
	}

	// ── a clip: moved by its body, trimmed by its edges ──────────────────
	component ClipItem: Rectangle {
		id: clip

		required property var modelData
		property color tone: Theme.primary
		property int rowIndex: 0
		readonly property bool chosen: studio.selected === clip.modelData.clip
		readonly property real full: clip.modelData.full || (clip.modelData.in + clip.modelData.length)
		// while dragged: how far, and which edge
		property real shift: 0
		property real trimLeft: 0
		property real trimRight: 0
		property int rowShift: 0
		readonly property real start: clip.modelData.start + clip.shift + clip.trimLeft
		readonly property real length: clip.modelData.length - clip.trimLeft + clip.trimRight

		x: studio.xOf(clip.start)
		y: 4 + clip.rowShift * (studio.rowHeight + 4)
		z: clip.rowShift !== 0 || clip.shift !== 0 ? 5 : 1
		width: Math.max(4, clip.length * studio.pps)
		height: studio.rowHeight - 8
		radius: Theme.radius.small
		color: Qt.alpha(clip.tone, clip.modelData.on ? (clip.chosen ? 0.38 : 0.24) : 0.08)
		border.width: clip.chosen ? 2 : 1
		border.color: Qt.alpha(clip.tone, clip.chosen ? 0.95 : 0.5)

		WaveShape {
			anchors.fill: parent
			anchors.topMargin: 16
			values: Rhymes.waves[Rhymes.takePath(clip.modelData.file)] ?? []
			from: clip.full > 0 ? (clip.modelData.in + clip.trimLeft) / clip.full : 0
			span: clip.full > 0 ? clip.length / clip.full : 1
			tone: clip.tone
			opacity: clip.modelData.on ? 1 : 0.4
		}

		StyledText {
			x: 6
			y: 2
			width: parent.width - 12
			text: clip.modelData.name
			elide: Text.ElideRight
			font.pixelSize: Theme.size.small
			tone: Theme.text
			visible: parent.width > 40
		}

		// fades
		Canvas {
			anchors.fill: parent
			visible: clip.modelData.fadeIn > 0 || clip.modelData.fadeOut > 0
			onPaint: {
				const g = getContext("2d");
				g.reset();
				g.fillStyle = Qt.alpha(Theme.base, 0.5);
				const a = clip.modelData.fadeIn * studio.pps, b = clip.modelData.fadeOut * studio.pps;
				g.beginPath();
				g.moveTo(0, 0);
				g.lineTo(a, 0);
				g.lineTo(0, height);
				g.closePath();
				g.moveTo(width, 0);
				g.lineTo(width - b, 0);
				g.lineTo(width, height);
				g.closePath();
				g.fill();
			}
			onWidthChanged: requestPaint()
		}

		MouseArea {
			id: body

			property real pressX: 0
			property real pressY: 0

			anchors.fill: parent
			anchors.leftMargin: 7
			anchors.rightMargin: 7
			acceptedButtons: Qt.LeftButton | Qt.RightButton
			cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
			onPressed: mouse => {
				studio.selected = clip.modelData.clip;
				studio.forceActiveFocus();
				const p = mapToItem(studio, mouse.x, mouse.y);
				pressX = p.x;
				pressY = p.y;
				if (mouse.button === Qt.RightButton) {
					clipMenu.entries = [
						{ text: "Cut at the playhead", icon: "content_cut", enabled: clip.modelData.start < Rhymes.position && Rhymes.position < clip.modelData.start + clip.modelData.length, action: () => Rhymes.splitClip(clip.modelData.clip, Rhymes.position) },
						{ text: clip.modelData.fadeIn > 0 ? "No fade in" : "Fade in", icon: "gradient_horizontal", action: () => Rhymes.editTake(clip.modelData.clip, { fadeIn: clip.modelData.fadeIn > 0 ? 0 : 0.25 }) },
						{ text: clip.modelData.fadeOut > 0 ? "No fade out" : "Fade out", icon: "gradient_horizontal", action: () => Rhymes.editTake(clip.modelData.clip, { fadeOut: clip.modelData.fadeOut > 0 ? 0 : 0.4 }) },
						{ text: clip.modelData.on ? "Mute" : "Unmute", icon: clip.modelData.on ? "volume_off" : "volume_high", action: () => Rhymes.editTake(clip.modelData.clip, { on: !clip.modelData.on }) },
						{ text: "Delete", icon: "delete_outline", danger: true, action: () => Rhymes.dropTake(clip.modelData.clip) }
					];
					clipMenu.show(clip, mouse.x, mouse.y);
				}
			}
			onPositionChanged: mouse => {
				if (!pressed || !(mouse.buttons & Qt.LeftButton)) return;
				const p = mapToItem(studio, mouse.x, mouse.y);
				const free = mouse.modifiers & Qt.ShiftModifier;
				const want = studio.snap(clip.modelData.start + (p.x - pressX) / studio.pps, free);
				clip.shift = want - clip.modelData.start;
				const audio = Rhymes.tracks.map((t, i) => t.kind === "audio" ? i : -1).filter(i => i >= 0);
				const target = Math.round((p.y - pressY) / (studio.rowHeight + 4)) + clip.rowIndex;
				clip.rowShift = audio.includes(target) ? target - clip.rowIndex : 0;
			}
			onReleased: {
				if (clip.shift === 0 && clip.rowShift === 0) return;
				const changes = { start: Math.round((clip.modelData.start + clip.shift) * 1000) / 1000 };
				if (clip.rowShift !== 0) changes.track = Rhymes.tracks[clip.rowIndex + clip.rowShift].id;
				clip.shift = 0;
				clip.rowShift = 0;
				Rhymes.editTake(clip.modelData.clip, changes);
			}
			onDoubleClicked: Rhymes.play(clip.modelData.start)
		}

		// the edges
		Repeater {
			model: ["left", "right"]

			MouseArea {
				id: edge

				required property string modelData
				property real pressX: 0

				x: edge.modelData === "left" ? 0 : clip.width - width
				width: 7
				height: clip.height
				cursorShape: Qt.SizeHorCursor
				hoverEnabled: true

				Rectangle {
					anchors.fill: parent
					radius: 2
					color: clip.tone
					opacity: edge.containsMouse || edge.pressed ? 0.7 : 0
				}

				onPressed: mouse => {
					studio.selected = clip.modelData.clip;
					pressX = mapToItem(studio, mouse.x, 0).x;
				}
				onPositionChanged: mouse => {
					if (!pressed) return;
					const d = (mapToItem(studio, mouse.x, 0).x - pressX) / studio.pps;
					const m = clip.modelData;
					if (edge.modelData === "left") {
						const to = studio.snap(m.start + d, mouse.modifiers & Qt.ShiftModifier);
						clip.trimLeft = Math.max(-m.in, Math.min(m.length - 0.05, to - m.start));
					} else {
						const end = studio.snap(m.start + m.length + d, mouse.modifiers & Qt.ShiftModifier);
						clip.trimRight = Math.max(0.05 - m.length, Math.min(clip.full - m.in - m.length, end - m.start - m.length));
					}
				}
				onReleased: {
					const m = clip.modelData;
					const changes = edge.modelData === "left"
						? { start: m.start + clip.trimLeft, in: m.in + clip.trimLeft, length: m.length - clip.trimLeft }
						: { length: m.length + clip.trimRight };
					clip.trimLeft = 0;
					clip.trimRight = 0;
					Rhymes.editTake(m.clip, changes);
				}
			}
		}
	}

	// ── a channel of the mixer ───────────────────────────────────────────
	component Strip: Rectangle {
		id: strip

		required property var modelData
		required property int index
		readonly property color tone: studio.trackColor(strip.index)

		width: 104
		height: stripRow.height
		radius: Theme.radius.large
		color: Theme.layer2

		Column {
			x: 8
			y: 8
			width: parent.width - 16
			spacing: 6

			Row {
				spacing: 6

				Rectangle {
					anchors.verticalCenter: parent.verticalCenter
					width: 8
					height: 8
					radius: 4
					color: strip.tone
				}

				StyledText {
					width: strip.width - 34
					text: strip.modelData.name
					elide: Text.ElideRight
					font.weight: Font.Medium
				}
			}

			// the effects: how many, a click opens them
			Clickable {
				width: parent.width
				height: 28
				radius: Theme.radius.medium
				color: strip.modelData.fx.length > 0 ? Qt.alpha(Theme.primary, 0.16) : Theme.layer1
				onClicked: studio.fxTrack = strip.modelData.id

				StyledText {
					anchors.centerIn: parent
					width: parent.width - 10
					horizontalAlignment: Text.AlignHCenter
					elide: Text.ElideRight
					text: strip.modelData.fx.length > 0 ? strip.modelData.fx.filter(f => f.on !== false).map(f => f.name).join(" · ") || "Off" : "Effects"
					font.pixelSize: Theme.size.small
					tone: strip.modelData.fx.length > 0 ? Theme.text : Theme.textMuted
				}
			}

			// pan
			Item {
				width: parent.width
				height: 18

				Rectangle {
					anchors.verticalCenter: parent.verticalCenter
					width: parent.width
					height: 4
					radius: 2
					color: Theme.layer1
				}

				Rectangle {
					anchors.verticalCenter: parent.verticalCenter
					x: Math.min(parent.width / 2, parent.width / 2 + strip.modelData.pan * parent.width / 2)
					width: Math.abs(strip.modelData.pan) * parent.width / 2
					height: 4
					radius: 2
					color: strip.tone
				}

				Rectangle {
					anchors.verticalCenter: parent.verticalCenter
					x: (strip.modelData.pan + 1) / 2 * (parent.width - width)
					width: 10
					height: 10
					radius: 5
					color: Theme.text
				}

				MouseArea {
					anchors.fill: parent
					onPositionChanged: mouse => {
						if (pressed) Rhymes.editTrack(strip.modelData.id, { pan: Math.round(Math.max(-1, Math.min(1, mouse.x / width * 2 - 1)) * 20) / 20 });
					}
					onDoubleClicked: Rhymes.editTrack(strip.modelData.id, { pan: 0 })
				}
			}

			// the fader: −60 … +6 dB
			Item {
				id: fader

				readonly property real most: 6
				readonly property real least: -60
				readonly property real at: (Math.max(fader.least, strip.modelData.volume) - fader.least) / (fader.most - fader.least)

				width: parent.width
				height: strip.height - 8 - 28 - 18 - 30 - 34 - 34

				Rectangle {
					anchors.horizontalCenter: parent.horizontalCenter
					width: 6
					height: parent.height
					radius: 3
					color: Theme.layer1

					Rectangle {
						anchors.bottom: parent.bottom
						width: parent.width
						height: parent.height * fader.at
						radius: 3
						color: strip.modelData.mute ? Theme.textFaint : strip.tone
					}

					// 0 dB
					Rectangle {
						anchors.horizontalCenter: parent.horizontalCenter
						y: parent.height * (1 - (0 - fader.least) / (fader.most - fader.least))
						width: 18
						height: 1
						color: Theme.textFaint
					}
				}

				Rectangle {
					anchors.horizontalCenter: parent.horizontalCenter
					y: (1 - fader.at) * (fader.height - height)
					width: 34
					height: 14
					radius: 7
					color: Theme.text
				}

				MouseArea {
					anchors.fill: parent
					onPositionChanged: mouse => {
						if (!pressed) return;
						const v = fader.least + (1 - Math.max(0, Math.min(1, mouse.y / height))) * (fader.most - fader.least);
						Rhymes.editTrack(strip.modelData.id, { volume: Math.round(v * 2) / 2 });
					}
					onDoubleClicked: Rhymes.editTrack(strip.modelData.id, { volume: 0 })
				}
			}

			StyledText {
				width: parent.width
				horizontalAlignment: Text.AlignHCenter
				text: strip.modelData.volume <= -60 ? "−∞" : `${strip.modelData.volume > 0 ? "+" : ""}${strip.modelData.volume.toFixed(1)} dB`
				tabular: true
				font.pixelSize: Theme.size.small
				tone: Theme.textMuted
			}

			Row {
				anchors.horizontalCenter: parent.horizontalCenter
				spacing: 4

				SmallToggle {
					text: "M"
					on: strip.modelData.mute
					tone: Theme.warning
					onClicked: Rhymes.editTrack(strip.modelData.id, { mute: !strip.modelData.mute })
				}

				SmallToggle {
					text: "S"
					on: strip.modelData.solo
					tone: Theme.success
					onClicked: Rhymes.editTrack(strip.modelData.id, { solo: !strip.modelData.solo })
				}
			}
		}
	}

	component SmallToggle: Clickable {
		id: toggle

		property string text: ""
		property bool on: false
		property color tone: Theme.primary

		width: 26
		height: 26
		radius: 13
		color: toggle.on ? toggle.tone : Theme.layer1
		tint: toggle.on ? Theme.onPrimary : Theme.text

		StyledText {
			anchors.centerIn: parent
			text: toggle.text
			font.pixelSize: Theme.size.small
			font.weight: Font.Bold
			tone: toggle.on ? Theme.onPrimary : Theme.textMuted
		}
	}

	// a stretch of a recording's loudness
	component WaveShape: Canvas {
		id: shape

		property var values: []
		property real from: 0
		property real span: 1
		property color tone: Theme.primary

		onValuesChanged: requestPaint()
		onFromChanged: requestPaint()
		onSpanChanged: requestPaint()
		onWidthChanged: requestPaint()
		onHeightChanged: requestPaint()
		onPaint: {
			const g = getContext("2d");
			g.reset();
			const v = shape.values || [];
			if (v.length === 0 || shape.width <= 0) return;
			g.fillStyle = Qt.alpha(shape.tone, 0.75);
			const step = 2;
			const mid = shape.height / 2;
			for (let x = 0; x < shape.width; x += step) {
				const i = Math.floor((shape.from + x / shape.width * shape.span) * v.length);
				if (i < 0 || i >= v.length) continue;
				const h = Math.max(1, Number(v[i]) * shape.height * 0.9);
				g.fillRect(x, mid - h / 2, step - 0.5, h);
			}
		}
	}
}
