pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import qs.style.theme
import qs.style.widgets
import qs.core.services

// The film as it will be, left to right: a ruler, the clips with their
// pictures (tiles of the sprite sheet – nothing decoded) and their sound,
// below them the texts, blurs, chapters and volume points along the time.
// A clip's edges trim it, the clip itself moves between the others, a
// click goes there; cuts snap to the playhead, the other cuts and the
// scene changes.
Item {
	id: root

	property var editor: null
	property color accent: Theme.primary
	property bool snapping: true

	readonly property var clips: Video.clipsOf(Video.recipe)
	readonly property var starts: {
		const out = [];
		let t = 0;
		for (const c of root.clips) {
			out.push(t);
			t += Video.clipLength(c);
		}
		return out;
	}
	readonly property real duration: Video.outDuration
	readonly property real margin: 12

	// pixels a second: the whole film fits until zoomed
	readonly property real fitPps: Math.max(0.01, (root.width - root.margin * 2) / Math.max(1, root.duration))
	property bool fitted: true
	property real zoomPps: 50
	readonly property real pps: root.fitted ? root.fitPps : root.zoomPps

	function fit() {
		root.fitted = true;
		flick.contentX = 0;
	}

	function zoomBy(factor) {
		const keep = root.playhead * root.pps - flick.contentX;
		const next = Math.max(root.fitPps, Math.min(600, root.pps * factor));
		root.zoomPps = next;
		root.fitted = next <= root.fitPps * 1.001;
		flick.contentX = Math.max(0, Math.min(flick.contentWidth - flick.width, root.playhead * next - keep));
	}

	readonly property real playhead: root.editor ? root.editor.playhead : 0

	function xOf(t) {
		return root.margin + t * root.pps;
	}

	function timeOf(x) {
		return Math.max(0, Math.min(root.duration, (x - root.margin) / root.pps));
	}

	// the moments a cut likes to land on (output seconds)
	function snapPoints(skipClip) {
		const out = [0, root.duration, root.playhead];
		for (let i = 0; i < root.clips.length; i += 1) {
			if (i === skipClip) continue;
			out.push(root.starts[i], root.starts[i] + Video.clipLength(root.clips[i]));
		}
		for (const t of Video.recipe.texts ?? []) out.push(t.a, t.b);
		for (const c of Video.recipe.chapters ?? []) out.push(c.t);
		// scene changes of the open file, through the clips that hold them
		for (const s of root.editor?.snapTimes ?? []) {
			for (let i = 0; i < root.clips.length; i += 1) {
				const c = root.clips[i];
				if ((c.src || Video.path) === Video.path && s > c.a && s < c.b) out.push(Video.sourceToOut(i, s));
			}
		}
		return out;
	}

	function snap(t, skipClip) {
		if (!root.snapping) return t;
		const reach = 8 / root.pps;
		let best = t, distance = reach;
		for (const p of root.snapPoints(skipClip)) {
			const d = Math.abs(p - t);
			if (d < distance) {
				distance = d;
				best = p;
			}
		}
		return best;
	}

	// while it plays, the playhead stays in sight
	onPlayheadChanged: {
		if (!Video.playing || flick.dragging || root.fitted) return;
		const x = root.xOf(root.playhead);
		if (x < flick.contentX + 20 || x > flick.contentX + flick.width - 40) flick.contentX = Math.max(0, Math.min(flick.contentWidth - flick.width, x - flick.width * 0.2));
	}

	Flickable {
		id: flick

		anchors.fill: parent
		contentWidth: Math.max(width, root.duration * root.pps + root.margin * 2)
		contentHeight: height
		flickableDirection: Flickable.HorizontalFlick
		boundsBehavior: Flickable.StopAtBounds
		clip: true
		interactive: !root.fitted
		ScrollBar.horizontal: ThinScrollBar {}

		Item {
			id: content

			width: flick.contentWidth
			height: flick.height

			// ── the ruler: where a click goes ──────────────────────────────
			Item {
				id: ruler

				width: parent.width
				height: 20

				readonly property real step: {
					const steps = [0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600];
					return steps.find(s => s * root.pps >= 70) ?? 3600;
				}

				Repeater {
					model: Math.min(400, Math.floor(root.duration / ruler.step) + 1)

					Item {
						id: tick

						required property int index
						readonly property real t: tick.index * ruler.step

						x: root.xOf(tick.t)
						height: ruler.height

						Rectangle {
							width: 1
							height: 6
							y: ruler.height - 6
							color: Theme.textFaint
						}

						StyledText {
							x: 4
							y: 1
							text: ruler.step < 1 ? `${Video.formatTime(tick.t)}.${Math.round((tick.t % 1) * 10)}` : Video.formatTime(tick.t)
							tone: Theme.textSubtle
							font.pixelSize: Theme.size.tiny
							tabular: true
						}
					}
				}

				MouseArea {
					anchors.fill: parent
					preventStealing: true
					cursorShape: Qt.SizeHorCursor
					onPressed: mouse => root.editor.seekOut(root.timeOf(mouse.x))
					onPositionChanged: mouse => {
						if (pressed) scrubTimer.want = root.timeOf(mouse.x);
						if (pressed && !scrubTimer.running) scrubTimer.start();
					}
				}
			}

			Timer {
				id: scrubTimer

				property real want: 0

				interval: 70
				onTriggered: root.editor.seekOut(scrubTimer.want)
			}

			// ── the clips ──────────────────────────────────────────────────
			Item {
				id: clipRow

				y: ruler.height + 4
				width: parent.width
				height: Math.max(40, (content.height - ruler.height) * 0.42)

				// a click between clips goes there and drops the selection
				MouseArea {
					anchors.fill: parent
					onClicked: mouse => {
						root.editor.selectedClip = -1;
						root.editor.seekOut(root.timeOf(mouse.x));
					}
				}

				Repeater {
					model: root.clips.length

					ClipBlock {
						required property int index

						clipIndex: index
					}
				}
			}

			// ── the sound of the clips ─────────────────────────────────────
			Item {
				id: waveRow

				y: clipRow.y + clipRow.height + 3
				width: parent.width
				height: Math.max(18, (content.height - ruler.height) * 0.2)

				Repeater {
					model: root.clips.length

					Canvas {
						id: wave

						required property int index
						readonly property var clip: root.clips[wave.index] ?? null
						readonly property bool ours: !!wave.clip && (wave.clip.src || Video.path) === Video.path

						x: root.xOf(root.starts[wave.index] ?? 0)
						width: Math.max(1, Video.clipLength(wave.clip ?? { a: 0, b: 0 }) * root.pps - 2)
						height: waveRow.height
						renderStrategy: Canvas.Cooperative
						visible: wave.ours && Video.wave.length > 0 && !Video.recipe.audio?.mute
						onWidthChanged: requestPaint()
						onClipChanged: requestPaint()
						onVisibleChanged: if (visible) requestPaint()

						Connections {
							target: Video

							function onWaveChanged() {
								wave.requestPaint();
							}
						}

						onPaint: {
							const ctx = getContext("2d");
							ctx.reset();
							const peaks = Video.wave;
							if (!wave.clip || peaks.length === 0 || Video.duration <= 0) return;
							ctx.fillStyle = Qt.alpha(root.accent, 0.55);
							const mid = height / 2;
							const gain = wave.clip.volume ?? 1;
							const columns = Math.max(1, Math.floor(width / 2));
							for (let k = 0; k < columns; k += 1) {
								const t = wave.clip.reverse ? wave.clip.b - (k / columns) * (wave.clip.b - wave.clip.a) : wave.clip.a + (k / columns) * (wave.clip.b - wave.clip.a);
								const p = peaks[Math.min(peaks.length - 1, Math.floor(t / Video.duration * peaks.length))] || 0;
								const h = Math.max(1, Math.min(1, p * gain) * (height - 2));
								ctx.fillRect(k * 2, mid - h / 2, 1.4, h);
							}
						}
					}
				}
			}

			// ── what lies along the time ───────────────────────────────────
			Item {
				id: lanes

				y: waveRow.y + waveRow.height + 4
				width: parent.width
				height: content.height - y - 2
				readonly property real lane: Math.max(10, Math.min(18, lanes.height / 4))

				// texts
				Repeater {
					model: Video.recipe.texts ?? []

					LaneBar {
						required property var modelData

						a: modelData.a
						b: modelData.b
						row: 0
						tone: root.accent
						label: modelData.kind === "arrow" ? "Arrow" : (modelData.kind === "rect" ? "Box" : String(modelData.text || "Text").split("\n")[0])
						selected: root.editor?.selectedItem?.kind === "text" && root.editor.selectedItem.id === modelData.id
						onPicked: {
							root.editor.tool = "text";
							root.editor.selectedItem = { kind: "text", id: modelData.id };
						}
					}
				}

				// blurs
				Repeater {
					model: Video.recipe.blurs ?? []

					LaneBar {
						required property var modelData
						required property int index

						a: modelData.a
						b: modelData.b
						row: 1
						tone: Theme.warning
						label: modelData.kind === "pixel" ? "Pixels" : "Blur"
						selected: root.editor?.selectedItem?.kind === "blur" && root.editor.selectedItem.id === (modelData.id ?? index)
						onPicked: {
							root.editor.tool = "blur";
							root.editor.selectedItem = { kind: "blur", id: modelData.id ?? index };
						}
					}
				}

				// the music under it: from where it starts to the end
				LaneBar {
					visible: !!Video.recipe.audio?.music?.path
					a: Video.recipe.audio?.music?.start ?? 0
					b: root.duration
					row: 2
					tone: Theme.tertiary
					label: Video.nameOf(Video.recipe.audio?.music?.path ?? "")
					onPicked: root.editor.tool = "sound"
				}

				// chapters: flags
				Repeater {
					model: Video.recipe.chapters ?? []

					Item {
						id: flag

						required property var modelData
						required property int index

						x: root.xOf(flag.modelData.t)
						y: lanes.lane * 3
						height: lanes.lane

						Rectangle {
							width: 2
							height: parent.height
							color: Theme.secondary
						}

						StyledText {
							x: 5
							anchors.verticalCenter: parent.verticalCenter
							text: flag.modelData.title || `Chapter ${flag.index + 1}`
							tone: Theme.secondary
							font.pixelSize: Theme.size.tiny
						}

						MouseArea {
							x: -4
							width: 60
							height: parent.height
							onClicked: {
								root.editor.tool = "chapters";
								root.editor.seekOut(flag.modelData.t);
							}
						}
					}
				}

				// the volume's points, joined
				Canvas {
					id: keysCanvas

					readonly property var keys: Video.recipe.audio?.keys ?? []

					width: parent.width
					height: lanes.lane * 2
					y: 0
					visible: keysCanvas.keys.length > 0
					onKeysChanged: requestPaint()
					onWidthChanged: requestPaint()

					Connections {
						target: root

						function onPpsChanged() {
							keysCanvas.requestPaint();
						}
					}

					onPaint: {
						const ctx = getContext("2d");
						ctx.reset();
						const list = keysCanvas.keys.slice().sort((p, q) => p[0] - q[0]);
						if (list.length === 0) return;
						ctx.strokeStyle = Theme.success;
						ctx.lineWidth = 1.5;
						ctx.beginPath();
						const yOf = g => height - 2 - Math.min(1.5, g) / 1.5 * (height - 4);
						ctx.moveTo(root.xOf(0), yOf(list[0][1]));
						for (const k of list) ctx.lineTo(root.xOf(k[0]), yOf(k[1]));
						ctx.lineTo(root.xOf(root.duration), yOf(list[list.length - 1][1]));
						ctx.stroke();
						ctx.fillStyle = Theme.success;
						for (const k of list) {
							ctx.beginPath();
							ctx.arc(root.xOf(k[0]), yOf(k[1]), 3, 0, Math.PI * 2);
							ctx.fill();
						}
					}
				}
			}

			// ── the playhead ───────────────────────────────────────────────
			Rectangle {
				id: head

				x: root.xOf(root.playhead) - 1
				width: 2
				height: content.height
				color: "white"
				z: 20

				Rectangle {
					anchors.horizontalCenter: parent.horizontalCenter
					width: 12
					height: 12
					radius: 3
					rotation: 45
					y: -6
					color: "white"
				}
			}
		}
	}

	// ── one clip ───────────────────────────────────────────────────────────
	component ClipBlock: Item {
		id: block

		property int clipIndex: 0
		readonly property var clip: root.clips[block.clipIndex] ?? ({ a: 0, b: 0 })
		readonly property string src: block.clip.src || Video.path
		readonly property var sheet: Video.sprites[block.src] ?? null
		readonly property bool selected: root.editor?.selectedClip === block.clipIndex
		readonly property real start: root.starts[block.clipIndex] ?? 0
		// moved by its body: where it is being dragged to
		property real dragOffset: 0
		property bool dragging: false

		x: root.xOf(block.start) + block.dragOffset
		y: block.dragging ? -4 : 0
		z: block.dragging ? 10 : (block.selected ? 2 : 1)
		width: Math.max(4, Video.clipLength(block.clip) * root.pps - 2)
		height: clipRow.height

		Component.onCompleted: if (!block.sheet) Video.spritesOf(block.src)

		Behavior on x {
			enabled: !block.dragging && !trimLeft.pressed && !trimRight.pressed
			SpatialAnim {
				duration: Motion.medium
			}
		}
		Behavior on y {
			SpatialAnim {
				duration: Motion.short
			}
		}

		Rectangle {
			id: body

			anchors.fill: parent
			radius: Theme.radius.small
			color: Theme.layer3
			clip: true

			// the pictures along it: one tile per room of a picture
			Row {
				id: strip

				readonly property real tileW: Math.max(24, body.height * (block.sheet ? block.sheet.tile_w / block.sheet.tile_h : 16 / 9))

				height: body.height
				visible: !!block.sheet

				Repeater {
					model: Math.min(160, Math.ceil(block.width / strip.tileW))

					SpriteTile {
						id: piece

						required property int index
						// the source moment at this tile's middle
						readonly property real t: {
							const share = Math.min(1, (piece.index + 0.5) * strip.tileW / Math.max(1, block.width));
							const span = block.clip.b - block.clip.a;
							return block.clip.reverse ? block.clip.b - share * span : block.clip.a + share * span;
						}

						width: strip.tileW
						height: strip.height
						sheet: block.sheet
						tile: Video.tileAt(block.sheet, piece.t)
					}
				}
			}

			Rectangle {
				anchors.fill: parent
				color: "transparent"
				radius: Theme.radius.small
				border.width: block.selected ? 2 : 1
				border.color: block.selected ? root.accent : Qt.rgba(0, 0, 0, 0.4)
			}

			// what is done to it: faster, backwards, held
			Row {
				x: 6
				y: 5
				spacing: 4

				Badge {
					visible: (block.clip.speed ?? 1) !== 1
					text: `${block.clip.speed}×`
				}
				Badge {
					visible: !!block.clip.reverse
					text: "◀"
				}
				Badge {
					visible: (block.clip.hold ?? 0) > 0
					text: `❚❚ ${block.clip.hold} s`
				}
				Badge {
					visible: block.src !== Video.path
					text: Video.nameOf(block.src)
				}
			}
		}

		// the body: a click selects and goes there, a drag moves it among the others
		MouseArea {
			id: grab

			anchors.fill: parent
			anchors.leftMargin: 8
			anchors.rightMargin: 8
			preventStealing: true
			cursorShape: block.dragging ? Qt.ClosedHandCursor : Qt.PointingHandCursor
			property real pressX: 0

			onPressed: mouse => grab.pressX = mouse.x
			onPositionChanged: mouse => {
				if (!pressed) return;
				const dx = mouse.x - grab.pressX;
				if (!block.dragging && Math.abs(dx) > 8 && root.clips.length > 1) block.dragging = true;
				if (block.dragging) block.dragOffset = dx;
			}
			onReleased: mouse => {
				if (!block.dragging) {
					root.editor.selectedClip = block.clipIndex;
					root.editor.seekOut(root.timeOf(block.x + mouse.x + grab.anchors.leftMargin));
					return;
				}
				// where its middle landed among the others
				const middle = root.timeOf(block.x + block.width / 2);
				let to = 0;
				for (let i = 0; i < root.clips.length; i += 1) {
					if (i === block.clipIndex) continue;
					const centre = root.starts[i] + Video.clipLength(root.clips[i]) / 2;
					if (middle > centre) to += 1;
				}
				block.dragging = false;
				block.dragOffset = 0;
				const from = block.clipIndex;
				if (to !== from) {
					root.editor.change(r => {
						const moved = r.clips.splice(from, 1)[0];
						r.clips.splice(to, 0, moved);
					});
					root.editor.selectedClip = to;
				}
			}
		}

		// the edges: trimmed, snapping
		TrimHandle {
			id: trimLeft

			anchors.left: parent.left
			end: false
			clipIndex: block.clipIndex
			selected: block.selected
		}

		TrimHandle {
			id: trimRight

			anchors.right: parent.right
			end: true
			clipIndex: block.clipIndex
			selected: block.selected
		}
	}

	component TrimHandle: MouseArea {
		id: handle

		property bool end: false
		property int clipIndex: 0
		property bool selected: false
		property real pressX: 0
		property var startClip: null
		property real limit: 0

		width: 10
		height: parent.height
		hoverEnabled: true
		preventStealing: true
		cursorShape: Qt.SizeHorCursor

		Rectangle {
			anchors.centerIn: parent
			width: 4
			height: parent.height * 0.5
			radius: 2
			color: handle.containsMouse || handle.pressed || handle.selected ? root.accent : Qt.rgba(1, 1, 1, 0.55)

			Behavior on color {
				ColorAnim {}
			}
		}

		onPressed: mouse => {
			handle.pressX = mapToItem(content, mouse.x, 0).x;
			handle.startClip = Object.assign({}, root.clips[handle.clipIndex]);
			root.editor.selectedClip = handle.clipIndex;
			// how far the edge may go: the file's own length
			handle.limit = Video.metas[handle.startClip.src || Video.path]?.duration ?? Video.duration;
		}
		onPositionChanged: mouse => {
			if (!pressed || !handle.startClip) return;
			const c = handle.startClip;
			const speed = c.speed || 1;
			const x = mapToItem(content, mouse.x, 0).x;
			const start = root.starts[handle.clipIndex];
			// the edge's place on the output's time, snapped, back to the source
			if (handle.end) {
				const outEnd = root.snap(start + (c.b - c.a) / speed + (x - handle.pressX) / root.pps, handle.clipIndex);
				const b = Math.max(c.a + 0.1, Math.min(handle.limit, c.a + (outEnd - start) * speed));
				root.editor.drag(r => {
					r.clips[handle.clipIndex].b = b;
				});
				root.editor.seekOut(Video.sourceToOut(handle.clipIndex, b) - 0.04);
			} else {
				const delta = (x - handle.pressX) / root.pps;
				const outStart = root.snap(start + delta, handle.clipIndex);
				const a = Math.max(0, Math.min(c.b - 0.1, c.a + (outStart - start) * speed));
				root.editor.drag(r => {
					r.clips[handle.clipIndex].a = a;
				});
				root.editor.seekOut(Video.sourceToOut(handle.clipIndex, a));
			}
		}
		onReleased: {
			root.editor.endDrag();
			handle.startClip = null;
		}
	}

	component Badge: Rectangle {
		id: badge

		property string text: ""

		width: badgeText.implicitWidth + 10
		height: 18
		radius: 9
		color: Qt.rgba(0, 0, 0, 0.6)

		StyledText {
			id: badgeText

			anchors.centerIn: parent
			text: badge.text
			tone: "white"
			surface: "transparent"
			font.pixelSize: Theme.size.tiny
			font.weight: Font.DemiBold
		}
	}

	// a stretch of time on a lane: a text, a blur, the music
	component LaneBar: Rectangle {
		id: bar

		property real a: 0
		property real b: 0
		property int row: 0
		property color tone: Theme.primary
		property string label: ""
		property bool selected: false

		signal picked

		x: root.xOf(bar.a)
		y: bar.row * lanes.lane
		width: Math.max(6, (bar.b - bar.a) * root.pps)
		height: lanes.lane - 2
		radius: 4
		color: Qt.alpha(bar.tone, bar.selected ? 0.55 : 0.3)
		border.width: bar.selected ? 1 : 0
		border.color: bar.tone

		StyledText {
			x: 5
			width: parent.width - 8
			anchors.verticalCenter: parent.verticalCenter
			text: bar.label
			font.pixelSize: Theme.size.tiny
			visible: parent.width > 30
		}

		MouseArea {
			anchors.fill: parent
			onClicked: bar.picked()
		}
	}
}
