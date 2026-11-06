pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.style.widgets
import qs.core.services

// The video window as an editor: the film above (the same Stage, now
// developed by the recipe's shader), the timeline below, the tools on the
// right. Everything done is a step of the recipe (Video.commit), so it can
// be taken back and is kept per file; nothing touches the file until it is
// exported – beside it, as a new one.
Item {
	id: root

	property Item stage: null
	property color accent: Theme.primary

	signal leave

	// ── what the tools share ───────────────────────────────────────────────
	property string tool: "cut"
	property bool cropping: false
	property real split: 0
	readonly property real playhead: Video.outPosition
	readonly property real duration: Video.outDuration
	property int selectedClip: -1
	// { kind: "text" | "blur" | "chapter", id } or null
	property var selectedItem: null
	// moments a cut likes to snap to (source seconds of the open file: scene changes)
	property var snapTimes: []
	readonly property alias overlay: overlayLoader.item

	readonly property real railWidth: 52
	readonly property real panelWidth: root.width < 900 ? root.railWidth + 290 : root.railWidth + Math.min(380, root.width * 0.28)
	readonly property real timelineHeight: Math.max(170, Math.min(260, root.height * 0.3))

	readonly property var tools: [
		{ id: "cut", label: "Cut", icon: "content_cut", file: "EditCut.qml" },
		{ id: "frame", label: "Frame", icon: "crop_rotate", file: "EditFrame.qml" },
		{ id: "colour", label: "Colour", icon: "palette_outline", file: "EditColour.qml" },
		{ id: "sound", label: "Sound", icon: "waveform", file: "EditSound.qml" },
		{ id: "text", label: "Text", icon: "format_text", file: "EditText.qml" },
		{ id: "blur", label: "Blur", icon: "blur", file: "EditBlur.qml" },
		{ id: "subtitles", label: "Subtitles", icon: "subtitles_outline", file: "EditSubtitles.qml" },
		{ id: "chapters", label: "Chapters", icon: "bookmark_multiple_outline", file: "EditChapters.qml" },
		{ id: "export", label: "Export", icon: "export_variant", file: "EditExport.qml" }
	]

	function setSnapTimes(list) {
		root.snapTimes = list || [];
	}

	function seekOut(t) {
		Video.seekOut(t);
	}

	function say(text, icon) {
		Video.said(text, icon || "information_outline");
	}

	// a step: fn changes a copy of the recipe
	function change(fn) {
		const next = JSON.parse(JSON.stringify(Video.recipe));
		next.clips = Video.clipsOf(next).map(c => Object.assign({}, c));
		const out = fn(next);
		Video.commit(out === undefined ? next : out);
	}

	// a step still moving: shown at once, kept by endDrag
	property string dragStart: ""

	function drag(fn) {
		if (root.dragStart === "") root.dragStart = JSON.stringify(Video.recipe);
		const next = JSON.parse(JSON.stringify(Video.recipe));
		next.clips = Video.clipsOf(next).map(c => Object.assign({}, c));
		const out = fn(next);
		Video.preview(out === undefined ? next : out);
	}

	function endDrag() {
		if (root.dragStart === "") return;
		const moved = Video.recipe;
		Video.recipe = JSON.parse(root.dragStart);
		root.dragStart = "";
		Video.commit(moved);
	}

	// ── cutting ────────────────────────────────────────────────────────────
	// the clip under the playhead in two
	function splitHere() {
		const at = Video.outToSource(root.playhead);
		const clips = Video.clipsOf(Video.recipe);
		const clip = clips[at.index];
		if (!clip || at.t - clip.a < 0.1 || clip.b - at.t < 0.1) return root.say("Too near the clip's edge to cut", "content_cut");
		root.change(r => {
			const c = r.clips[at.index];
			const first = Object.assign({}, c, { b: at.t, hold: 0 });
			const second = Object.assign({}, c, { a: at.t });
			r.clips.splice(at.index, 1, first, second);
		});
		root.selectedClip = at.index + 1;
	}

	function deleteClip(i) {
		const clips = Video.clipsOf(Video.recipe);
		if (i < 0 || i >= clips.length) return;
		if (clips.length === 1) return root.say("The last clip stays – trim it instead", "content_cut");
		const start = Video.sourceToOut(i, clips[i].a);
		root.change(r => {
			r.clips.splice(i, 1);
		});
		root.selectedClip = Math.min(i, clips.length - 2);
		Qt.callLater(() => root.seekOut(start));
	}

	// the selected clip's start or end to the playhead (I and O)
	function trimToPlayhead(end) {
		const at = Video.outToSource(root.playhead);
		root.change(r => {
			const c = r.clips[at.index];
			if (!c) return;
			if (end && at.t > c.a + 0.1) {
				c.b = at.t;
			} else if (!end && at.t < c.b - 0.1) c.a = at.t;
		});
	}

	// more videos at the end (dropped, or joined from Files)
	function addClips(paths) {
		let left = paths.length;
		const found = [];
		for (const p of paths) {
			Video.probe(p, data => {
				if (data?.duration > 0) found.push({ src: p, a: 0, b: data.duration, speed: 1, reverse: false, hold: 0, volume: 1, order: paths.indexOf(p) });
				left -= 1;
				if (left > 0 || found.length === 0) return;
				found.sort((x, y) => x.order - y.order);
				root.change(r => {
					for (const c of found) {
						delete c.order;
						r.clips.push(c);
					}
				});
				for (const c of found) Video.spritesOf(c.src);
				root.say(found.length === 1 ? "One video added at the end" : `${found.length} videos added at the end`, "movie_open_plus_outline");
			});
		}
	}

	function act(name) {
		if (name.startsWith("tool-")) return root.tool = name.slice(5);
		switch (name) {
		case "undo": return Video.undo();
		case "redo": return Video.redo();
		case "split": return root.splitHere();
		case "delete": return root.deleteClip(root.selectedClip >= 0 ? root.selectedClip : Video.outToSource(root.playhead).index);
		case "export": return root.tool = "export";
		case "before-after": return root.split = root.split > 0 ? 0 : 0.5;
		case "leave": return root.leave();
		}
	}

	onToolChanged: {
		if (root.tool !== "frame") root.cropping = false;
		if (root.tool !== "colour") root.split = 0;
	}

	Component.onCompleted: {
		root.forceActiveFocus();
		for (const c of Video.clipsOf(Video.recipe)) if (c.src && c.src !== Video.path) Video.spritesOf(c.src);
	}

	// ── above ──────────────────────────────────────────────────────────────
	Rectangle {
		id: topBar

		width: parent.width
		height: 52
		color: Qt.rgba(0.04, 0.04, 0.05, 0.86)

		Row {
			anchors.left: parent.left
			anchors.leftMargin: 10
			anchors.verticalCenter: parent.verticalCenter
			spacing: 10

			TextButton {
				anchors.verticalCenter: parent.verticalCenter
				text: "Done"
				icon: "arrow_left"
				onClicked: root.leave()
			}

			Column {
				anchors.verticalCenter: parent.verticalCenter

				StyledText {
					width: Math.min(implicitWidth, root.width * 0.3)
					text: Video.title
					tone: "white"
					surface: "transparent"
					font.weight: Font.DemiBold
				}

				StyledText {
					text: Video.edited ? `${Video.formatTime(root.duration)} after the edits · kept until exported` : "Nothing changed yet"
					tone: Qt.rgba(1, 1, 1, 0.6)
					surface: "transparent"
					font.pixelSize: Theme.size.small
				}
			}
		}

		Row {
			anchors.centerIn: parent
			spacing: 4

			BarKey {
				icon: "undo"
				tip: "Take back (Ctrl+Z)"
				enabled: Video.undoStack.length > 0
				onClicked: Video.undo()
			}
			BarKey {
				icon: "redo"
				tip: "Again (Ctrl+Shift+Z)"
				enabled: Video.redoStack.length > 0
				onClicked: Video.redo()
			}
			BarKey {
				icon: "compare"
				tip: "Before and after"
				checked: root.split > 0
				enabled: Video.edited
				onClicked: root.split = root.split > 0 ? 0 : 0.5
			}
			BarKey {
				icon: "restore"
				tip: "Start over"
				enabled: Video.edited
				onClicked: Video.resetRecipe()
			}
		}

		Row {
			anchors.right: parent.right
			anchors.rightMargin: 12
			anchors.verticalCenter: parent.verticalCenter
			spacing: 8

			// what runs (an export, Whisper): a thin ring each
			Repeater {
				model: Video.runningJobs

				Item {
					id: job

					required property var modelData

					anchors.verticalCenter: parent.verticalCenter
					width: 30
					height: 30

					Ring {
						anchors.fill: parent
						value: job.modelData.progress || 0
						color: root.accent
					}

					HoverHandler {
						id: jobHover
					}

					Rectangle {
						visible: jobHover.hovered
						anchors.top: parent.bottom
						anchors.topMargin: 6
						anchors.right: parent.right
						width: jobText.implicitWidth + 16
						height: 26
						radius: 13
						color: Qt.rgba(0.06, 0.06, 0.07, 0.94)
						z: 10

						StyledText {
							id: jobText

							anchors.centerIn: parent
							text: `${job.modelData.text || job.modelData.label} · ${Math.round((job.modelData.progress || 0) * 100)} %`
							tone: "white"
							surface: "transparent"
							font.pixelSize: Theme.size.small
						}
					}
				}
			}

			TextButton {
				anchors.verticalCenter: parent.verticalCenter
				text: "Export"
				icon: "export_variant"
				variant: "filled"
				onClicked: root.tool = "export"
			}
		}
	}

	// ── over the picture: texts, blurs, the crop's handles ─────────────────
	Loader {
		id: overlayLoader

		x: root.stage ? root.stage.frame.x : 0
		y: root.stage ? root.stage.frame.y : 0
		width: root.stage ? root.stage.frame.width : 0
		height: root.stage ? root.stage.frame.height : 0
		source: Qt.resolvedUrl("EditOverlay.qml")
		onLoaded: overlayLoader.item.editor = root
	}

	// ── the tools on the right ─────────────────────────────────────────────
	Rectangle {
		id: panel

		anchors.right: rail.left
		anchors.top: topBar.bottom
		anchors.bottom: timeline.top
		width: root.panelWidth - root.railWidth
		color: Theme.layer1

		Rectangle {
			width: 1
			height: parent.height
			color: Theme.outline
		}

		Repeater {
			model: root.tools

			Loader {
				id: toolSlot

				required property var modelData
				readonly property bool shown: root.tool === toolSlot.modelData.id

				anchors.fill: parent
				anchors.leftMargin: 1
				// a tool once opened stays built: its state (a search, a scroll) is kept
				active: toolSlot.shown || toolSlot.item !== null
				visible: opacity > 0.01
				opacity: toolSlot.shown ? 1 : 0
				source: active ? Qt.resolvedUrl(toolSlot.modelData.file) : ""
				onLoaded: {
					toolSlot.item.editor = root;
					if ("accent" in toolSlot.item) toolSlot.item.accent = Qt.binding(() => root.accent);
				}
				transform: Translate {
					y: toolSlot.shown ? 0 : 12

					Behavior on y {
						SpatialAnim {}
					}
				}

				Behavior on opacity {
					Anim {}
				}
			}
		}
	}

	Rectangle {
		id: rail

		anchors.right: parent.right
		anchors.top: topBar.bottom
		anchors.bottom: timeline.top
		width: root.railWidth
		color: Theme.layer2

		Column {
			anchors.horizontalCenter: parent.horizontalCenter
			y: 10
			spacing: 4

			Repeater {
				model: root.tools

				Clickable {
					id: toolKey

					required property var modelData
					required property int index
					readonly property bool current: root.tool === toolKey.modelData.id

					width: 42
					height: 46
					radius: Theme.radius.medium
					color: toolKey.current ? Qt.alpha(root.accent, 0.22) : (toolKey.hovered ? Theme.layer3 : "transparent")
					onClicked: root.tool = toolKey.modelData.id

					Behavior on color {
						ColorAnim {}
					}

					Column {
						anchors.centerIn: parent
						spacing: 1

						Glyph {
							anchors.horizontalCenter: parent.horizontalCenter
							icon: toolKey.modelData.icon
							size: 20
							color: toolKey.current ? root.accent : Theme.text
						}

						StyledText {
							anchors.horizontalCenter: parent.horizontalCenter
							text: toolKey.modelData.label
							font.pixelSize: 9
							tone: toolKey.current ? root.accent : Theme.textMuted
						}
					}
				}
			}
		}
	}

	// ── below: the timeline ────────────────────────────────────────────────
	Rectangle {
		id: timeline

		anchors.left: parent.left
		anchors.right: parent.right
		anchors.bottom: parent.bottom
		height: root.timelineHeight
		color: Theme.layer1

		Rectangle {
			width: parent.width
			height: 1
			color: Theme.outline
		}

		// the transport: play, the time, cut, zoom
		Item {
			id: transport

			width: parent.width
			height: 44

			Row {
				anchors.left: parent.left
				anchors.leftMargin: 10
				anchors.verticalCenter: parent.verticalCenter
				spacing: 4

				IconButton {
					icon: "skip_previous"
					onClicked: root.seekOut(0)
				}
				IconButton {
					icon: Video.playing ? "pause" : "play"
					variant: "filled"
					onClicked: Video.toggle()
				}
				IconButton {
					icon: "skip_next"
					onClicked: root.seekOut(root.duration - 0.05)
				}

				StyledText {
					anchors.verticalCenter: parent.verticalCenter
					leftPadding: 8
					tabular: true
					text: `${root.clock(root.playhead)} / ${root.clock(root.duration)}`
					font.pixelSize: Theme.size.label
				}
			}

			Row {
				anchors.centerIn: parent
				spacing: 4

				TextButton {
					text: "Split"
					icon: "content_cut"
					onClicked: root.splitHere()
				}
				IconButton {
					icon: "delete_outline"
					enabled: Video.clipsOf(Video.recipe).length > 1
					onClicked: root.act("delete")
				}
			}

			Row {
				anchors.right: parent.right
				anchors.rightMargin: 10
				anchors.verticalCenter: parent.verticalCenter
				spacing: 4

				IconButton {
					icon: "magnet"
					checked: timelineView.snapping
					onClicked: timelineView.snapping = !timelineView.snapping
				}
				IconButton {
					icon: "magnify_minus_outline"
					onClicked: timelineView.zoomBy(1 / 1.5)
				}
				IconButton {
					icon: "fit_to_page_outline"
					onClicked: timelineView.fit()
				}
				IconButton {
					icon: "magnify_plus_outline"
					onClicked: timelineView.zoomBy(1.5)
				}
			}
		}

		Timeline {
			id: timelineView

			anchors.left: parent.left
			anchors.right: parent.right
			anchors.top: transport.bottom
			anchors.bottom: parent.bottom
			editor: root
			accent: root.accent
		}
	}

	// minutes, seconds and the frame's hundredths: cutting wants them
	function clock(t) {
		const s = Math.max(0, t);
		const hundredths = Math.floor((s % 1) * 100);
		return `${Video.formatTime(s)}.${hundredths < 10 ? "0" : ""}${hundredths}`;
	}

	// ── keys ───────────────────────────────────────────────────────────────
	focus: true
	Keys.onPressed: event => {
		const ctrl = event.modifiers & Qt.ControlModifier, shift = event.modifiers & Qt.ShiftModifier;
		let handled = true;
		const fps = Number(Video.meta?.fps) || 25;
		switch (event.key) {
		case Qt.Key_Space:
		case Qt.Key_K:
			Video.toggle();
			break;
		case Qt.Key_Left:
			if (Video.playing) Video.pause();
			root.seekOut(root.playhead - (shift ? 1 : 1 / fps));
			break;
		case Qt.Key_Right:
			if (Video.playing) Video.pause();
			root.seekOut(root.playhead + (shift ? 1 : 1 / fps));
			break;
		case Qt.Key_J:
			root.seekOut(root.playhead - 5);
			break;
		case Qt.Key_L:
			root.seekOut(root.playhead + 5);
			break;
		case Qt.Key_Home:
			root.seekOut(0);
			break;
		case Qt.Key_End:
			root.seekOut(root.duration - 0.05);
			break;
		case Qt.Key_S:
			if (!ctrl) root.splitHere();
			else handled = false;
			break;
		case Qt.Key_I:
			root.trimToPlayhead(false);
			break;
		case Qt.Key_O:
			root.trimToPlayhead(true);
			break;
		case Qt.Key_Delete:
		case Qt.Key_Backspace:
			root.act("delete");
			break;
		case Qt.Key_Z:
			if (ctrl && shift) Video.redo();
			else if (ctrl) Video.undo();
			else handled = false;
			break;
		case Qt.Key_Y:
			if (ctrl) Video.redo();
			else handled = false;
			break;
		case Qt.Key_Plus:
		case Qt.Key_Equal:
			timelineView.zoomBy(1.5);
			break;
		case Qt.Key_Minus:
			timelineView.zoomBy(1 / 1.5);
			break;
		case Qt.Key_Escape:
		case Qt.Key_E:
			if (root.cropping && event.key === Qt.Key_Escape) root.tool = "cut";
			else root.leave();
			break;
		default:
			if (event.key >= Qt.Key_1 && event.key <= Qt.Key_9 && !ctrl) root.tool = root.tools[event.key - Qt.Key_1]?.id ?? root.tool;
			else handled = false;
		}
		event.accepted = handled;
	}

	component BarKey: Clickable {
		id: key

		property string icon: ""
		property string tip: ""
		property bool checked: false

		implicitWidth: 38
		implicitHeight: 38
		radius: key.checked ? Theme.radius.medium : 19
		color: key.checked ? Qt.alpha(root.accent, 0.3) : (key.hovered ? Qt.rgba(1, 1, 1, 0.12) : "transparent")
		tint: "white"
		opacity: key.enabled ? 1 : 0.35

		Glyph {
			anchors.centerIn: parent
			icon: key.icon
			size: 19
			color: "white"
			surface: "transparent"
		}

		Rectangle {
			anchors.top: parent.bottom
			anchors.topMargin: 6
			anchors.horizontalCenter: parent.horizontalCenter
			width: tipText.implicitWidth + 16
			height: 26
			radius: 13
			color: Qt.rgba(0.06, 0.06, 0.07, 0.94)
			visible: key.hovered && key.tip !== ""
			z: 20

			StyledText {
				id: tipText

				anchors.centerIn: parent
				text: key.tip
				tone: "white"
				surface: "transparent"
				font.pixelSize: Theme.size.small
			}
		}
	}
}
