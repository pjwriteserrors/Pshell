pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "../viewer"
import "Edit.js" as Edit

// The clip under the playhead (or the one picked on the timeline): where it
// starts and ends to the frame, how fast it runs, backwards, a held last
// frame, how loud. Below: cutting, the silences taken out, snapping to the
// film's scene changes, and whether it can be cut without re-encoding.
PaneFrame {
	id: root

	property var editor: null

	readonly property var clips: Video.clipsOf(Video.recipe)
	readonly property int index: {
		if (!root.editor) return 0;
		const picked = root.editor.selectedClip;
		if (picked >= 0 && picked < root.clips.length) return picked;
		return Video.outToSource(root.editor.playhead).index;
	}
	readonly property var clip: root.clips[root.index] ?? null
	readonly property string src: root.clip?.src || Video.path
	readonly property real frame: 1 / Math.max(1, Number(Video.metas[root.src]?.fps) || 25)
	readonly property real srcDuration: Number(Video.metas[root.src]?.duration) || (root.src === Video.path ? Video.duration : 0)

	// the silences found, and what taking them out would cut
	property var silences: null
	property bool findingSilences: false
	readonly property var withoutSilences: root.silences ? root.cutAway(root.clips, root.silences) : null
	readonly property real silentTime: root.withoutSilences ? root.totalOf(root.clips) - root.totalOf(root.withoutSilences) : 0

	property var sceneTimes: Edit.scenes[Video.path] ?? []
	property bool findingScenes: false
	readonly property bool snapping: (root.editor?.snapTimes?.length ?? 0) > 0

	readonly property bool cutOnly: Edit.cutOnly(Video.recipe, root.clips)

	title: "Cut"
	subtitle: root.clip ? `Clip ${root.index + 1} of ${root.clips.length} · ${Edit.length(Video.clipLength(root.clip))} in the film` : "Nothing to cut yet"
	closable: false

	Connections {
		target: Video

		function onPathChanged() {
			root.silences = null;
			root.sceneTimes = Edit.scenes[Video.path] ?? [];
		}
	}

	// one change to the clip shown
	function setClip(changes, live) {
		const i = root.index;
		const fn = r => {
			if (r.clips[i]) Object.assign(r.clips[i], changes);
		};
		if (live) root.editor.drag(fn);
		else root.editor.change(fn);
	}

	// its start or end moved, kept inside the file and a frame apart
	function nudge(end, delta) {
		const c = root.clip;
		if (!c) return;
		if (end) root.setClip({ b: Math.max(c.a + root.frame, Math.min(root.srcDuration || c.b + Math.max(0, delta), c.b + delta)) });
		else root.setClip({ a: Math.max(0, Math.min(c.b - root.frame, c.a + delta)) });
	}

	function duplicate() {
		const i = root.index;
		root.editor.change(r => {
			r.clips.splice(i + 1, 0, Object.assign({}, r.clips[i]));
		});
		root.editor.selectedClip = i + 1;
		root.editor.say("The clip twice, one after the other", "content_duplicate");
	}

	function totalOf(list) {
		return list.reduce((sum, c) => sum + Video.clipLength(c), 0);
	}

	// the clips with the silent parts taken out: a little kept on each side,
	// so a word's breath is not cut off
	function cutAway(list, parts) {
		const pad = 0.12;
		const out = [];
		for (const c of list) {
			if ((c.src || Video.path) !== Video.path) {
				out.push(c);
				continue;
			}
			let pieces = [[c.a, c.b]];
			for (const part of parts) {
				const s = part[0] + pad, e = part[1] - pad;
				if (e - s < 0.2) continue;
				pieces = pieces.flatMap(p => {
					if (e <= p[0] || s >= p[1]) return [p];
					const kept = [];
					if (s - p[0] > 0.15) kept.push([p[0], s]);
					if (p[1] - e > 0.15) kept.push([e, p[1]]);
					return kept;
				});
			}
			pieces.forEach((p, k) => out.push(Object.assign({}, c, { a: p[0], b: p[1], hold: k === pieces.length - 1 ? (c.hold || 0) : 0 })));
		}
		return out.length > 0 ? out : list;
	}

	function findSilences() {
		if (root.findingSilences) return;
		root.findingSilences = true;
		const path = Video.path;
		Video.startJob("silences", { path: path }, "Finding the silences", result => {
			root.findingSilences = false;
			if (!result || Video.path !== path) return;
			root.silences = result.parts || [];
			if (root.silences.length === 0) root.editor.say("No silent parts in it", "volume_off");
		});
	}

	function applySilences() {
		const next = root.withoutSilences;
		if (!next) return;
		const removed = root.silentTime;
		root.editor.change(r => {
			r.clips = next.map(c => Object.assign({}, c));
		});
		root.silences = null;
		root.editor.selectedClip = -1;
		root.editor.say(`${Edit.length(removed)} of silence taken out`, "content_cut");
	}

	function setSnapping(on) {
		if (!on) return root.editor.setSnapTimes([]);
		if (root.sceneTimes.length > 0) return root.editor.setSnapTimes(root.sceneTimes);
		if (root.findingScenes) return;
		root.findingScenes = true;
		const path = Video.path;
		Video.startJob("scenes", { path: path }, "Finding the scene changes", result => {
			root.findingScenes = false;
			if (!result || Video.path !== path) return;
			Edit.scenes[path] = result.times || [];
			root.sceneTimes = Edit.scenes[path];
			root.editor.setSnapTimes(root.sceneTimes);
			if (root.sceneTimes.length === 0) root.editor.say("No scene changes found – one long shot", "movie_open_outline");
		});
	}

	// a source moment of the open file in the film (-1 when it was cut away)
	function outOf(t) {
		const i = root.clips.findIndex(c => (c.src || Video.path) === Video.path && t >= c.a && t <= c.b);
		return i < 0 ? -1 : Video.sourceToOut(i, t);
	}

	// ── the clip ───────────────────────────────────────────────────────────
	SectionLabel {
		text: "The clip"
	}

	TrimLine {
		label: "Starts"
		at: root.clip?.a ?? 0
		end: false
	}

	TrimLine {
		label: "Ends"
		at: root.clip?.b ?? 0
		end: true
	}

	TuneSlider {
		width: parent.width
		label: "Speed"
		icon: "speedometer"
		accent: root.accent
		from: -2
		to: 4
		step: 0.01
		enabled: !!root.clip
		value: Math.log2(root.clip?.speed || 1)
		valueText: `${Math.round(Math.pow(2, shown) * 100) / 100}×`
		onMoved: value => root.setClip({ speed: Math.round(Math.pow(2, value) * 100) / 100 }, true)
		onCommitted: value => {
			root.setClip({ speed: Math.round(Math.pow(2, value) * 100) / 100 }, true);
			root.editor.endDrag();
		}
	}

	Flow {
		width: parent.width
		spacing: 6

		Repeater {
			model: [{ v: 0.25, label: "¼×" }, { v: 0.5, label: "½×" }, { v: 1, label: "1×" }, { v: 1.5, label: "1.5×" }, { v: 2, label: "2×" }, { v: 4, label: "4×" },
				{ v: 8, label: "Time-lapse 8×", icon: "timer_sand" }, { v: 16, label: "16×", icon: "timer_sand" }]

			delegate: Chip {
				required property var modelData

				text: modelData.label
				icon: modelData.icon ?? ""
				accent: root.accent
				selected: Math.abs((root.clip?.speed || 1) - modelData.v) < 1e-3
				onClicked: root.setClip({ speed: modelData.v })
			}
		}
	}

	PaneLine {
		label: "Backwards"
		detail: "The clip runs from its end to its start"

		Toggle {
			checked: !!root.clip?.reverse
			onToggled: checked => root.setClip({ reverse: checked })
		}
	}

	TuneSlider {
		width: parent.width
		label: "Hold the last frame"
		icon: "pause_circle_outline"
		accent: root.accent
		from: 0
		to: 5
		step: 0.1
		value: root.clip?.hold || 0
		valueText: shown > 0 ? `${shown.toFixed(1)} s` : "Off"
		onMoved: value => root.setClip({ hold: Math.round(value * 10) / 10 }, true)
		onCommitted: root.editor.endDrag()
	}

	TuneSlider {
		width: parent.width
		label: "The clip's volume"
		icon: "volume_high"
		accent: root.accent
		// around 100 %: the fill grows from the middle, the way back is 100 %
		from: -1
		to: 1
		step: 0.01
		value: (root.clip?.volume ?? 1) - 1
		valueText: `${Math.round((shown + 1) * 100)} %`
		onMoved: value => root.setClip({ volume: Math.abs(value) < 0.02 ? 1 : Math.round((value + 1) * 100) / 100 }, true)
		onCommitted: root.editor.endDrag()
	}

	// ── cutting ────────────────────────────────────────────────────────────
	SectionLabel {
		text: "Cutting"
	}

	Flow {
		width: parent.width
		spacing: 8

		TextButton {
			text: "Split here (S)"
			icon: "content_cut"
			variant: "filled"
			onActivated: root.editor.splitHere()
		}

		TextButton {
			text: "Twice"
			icon: "content_duplicate"
			enabled: !!root.clip
			onActivated: root.duplicate()
		}

		TextButton {
			text: "Delete"
			icon: "delete_outline"
			variant: "danger"
			enabled: root.clips.length > 1
			onActivated: root.editor.deleteClip(root.index)
		}
	}

	// ── the silences ───────────────────────────────────────────────────────
	SectionLabel {
		text: "Silences"
	}

	PaneLine {
		label: "Take out the quiet parts"
		detail: root.silences === null ? "Pauses longer than half a second, found in the sound" : (root.silences.length === 0 ? "None found" : `${root.silences.length} quiet ${root.silences.length === 1 ? "part" : "parts"} – ${Edit.length(root.silentTime)} would go`)

		TextButton {
			text: root.findingSilences ? "Listening…" : (root.silences === null ? "Find them" : "Again")
			icon: "waveform"
			busy: root.findingSilences
			visible: root.silences === null || root.silences.length === 0
			onActivated: root.findSilences()
		}
	}

	Row {
		spacing: 8
		visible: (root.silences?.length ?? 0) > 0 && root.silentTime > 0.05

		TextButton {
			text: `Cut ${Edit.length(root.silentTime)} out`
			icon: "content_cut"
			variant: "filled"
			onActivated: root.applySilences()
		}

		TextButton {
			text: "Leave them"
			variant: "ghost"
			onActivated: root.silences = null
		}
	}

	// ── scenes ─────────────────────────────────────────────────────────────
	SectionLabel {
		text: "Scenes"
	}

	PaneLine {
		label: "Snap to scene changes"
		detail: root.findingScenes ? "Looking through the film…" : (root.sceneTimes.length > 0 ? `${root.sceneTimes.length} cuts in the film – edges and the playhead stick to them` : "Found once, then edges and the playhead stick to them")

		Toggle {
			checked: root.snapping || root.findingScenes
			onToggled: checked => root.setSnapping(checked)
		}
	}

	Flow {
		width: parent.width
		spacing: 6
		visible: root.snapping

		Repeater {
			model: root.snapping ? root.sceneTimes.slice(0, 80) : []

			delegate: Chip {
				id: scene

				required property real modelData
				readonly property real out: root.outOf(modelData)

				text: Edit.time(modelData)
				accent: root.accent
				opacity: scene.out < 0 ? 0.4 : 1
				selected: scene.out >= 0 && Math.abs((root.editor?.playhead ?? -9) - scene.out) < 0.05
				onClicked: if (scene.out >= 0) root.editor.seekOut(scene.out)
			}
		}
	}

	// ── without re-encoding ────────────────────────────────────────────────
	SectionLabel {
		text: "Without re-encoding"
	}

	PaneLine {
		label: "Cut at keyframes only"
		detail: "Fast and without any loss when only cuts were made; the cuts move to the nearest keyframe"

		Toggle {
			checked: Video.setting("losslessFirst", true)
			onToggled: checked => Video.setSetting("losslessFirst", checked)
		}
	}

	Row {
		width: parent.width
		spacing: 8

		Glyph {
			id: losslessGlyph

			icon: root.cutOnly ? "check_circle_outline" : "information_outline"
			size: 16
			color: root.cutOnly ? root.accent : Theme.textMuted
		}

		StyledText {
			width: parent.width - losslessGlyph.width - 8
			wrapMode: Text.WordWrap
			font.pixelSize: Theme.size.small
			tone: Theme.textMuted
			text: root.cutOnly ? (Video.setting("losslessFirst", true) ? "Only cuts so far: the export copies the parts as they are" : "Only cuts so far – it could be copied as it is")
				: `Re-encoded on export, for ${Edit.cutOnlyBlockers(Video.recipe, root.clips).join(", ")}`
		}
	}

	// a start or an end: the time, and steps of a frame or a second
	component TrimLine: Item {
		id: line

		property string label: ""
		property real at: 0
		property bool end: false

		width: parent?.width ?? 300
		height: 40

		Column {
			anchors.verticalCenter: parent.verticalCenter
			spacing: 1

			StyledText {
				text: line.label
				font.pixelSize: Theme.size.small
				tone: Theme.textMuted
			}

			StyledText {
				text: Edit.time(line.at)
				tabular: true
				font.weight: Font.DemiBold
			}
		}

		Row {
			anchors.right: parent.right
			anchors.verticalCenter: parent.verticalCenter
			spacing: 2

			Repeater {
				model: [{ d: -1, icon: "chevron_double_left" }, { d: -root.frame, icon: "chevron_left" }, { d: root.frame, icon: "chevron_right" }, { d: 1, icon: "chevron_double_right" }]

				delegate: IconButton {
					required property var modelData

					width: 30
					height: 30
					icon: modelData.icon
					enabled: !!root.clip
					onClicked: root.nudge(line.end, modelData.d)
				}
			}

			// to the playhead (I and O)
			IconButton {
				width: 30
				height: 30
				icon: line.end ? "ray_end" : "ray_start"
				variant: "tonal"
				enabled: !!root.clip
				onClicked: root.editor.trimToPlayhead(line.end)
			}
		}
	}
}
