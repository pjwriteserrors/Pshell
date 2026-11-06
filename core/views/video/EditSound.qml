pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "../viewer"
import "Edit.js" as Edit

// The film's sound: louder or softer, faded in and out, less hiss, even
// loudness, none at all, or another sound in its place; music under it
// that steps back while someone speaks; and points along the film where
// the volume goes up or down (drawn on the timeline, joined by lines).
PaneFrame {
	id: root

	property var editor: null
	property color accent: Theme.primary

	readonly property var sound: Video.recipe.audio ?? {}
	readonly property var music: root.sound.music ?? {}
	readonly property var keys: (root.sound.keys ?? []).slice().sort((a, b) => a[0] - b[0])
	// the volume a new point gets (linear)
	property real pointGain: 0.5
	// which file the chooser is asked for: "replace" or "music"
	property string picking: ""

	title: "Sound"
	subtitle: root.sound.mute ? "Silent" : (root.sound.replace ? `In place of it: ${Video.nameOf(root.sound.replace)}` : (root.music.path ? `With ${Video.nameOf(root.music.path)} under it` : (Video.hasAudio ? "The film's own" : "The film has no sound")))
	closable: false

	function set(changes, live) {
		const fn = r => {
			r.audio = Object.assign({}, r.audio || {}, changes);
		};
		if (live) root.editor.drag(fn);
		else root.editor.change(fn);
	}

	function setMusic(changes, live) {
		const fn = r => {
			r.audio = r.audio || {};
			r.audio.music = Object.assign({ path: "", gain: -8, start: 0, duck: true }, r.audio.music || {}, changes);
		};
		if (live) root.editor.drag(fn);
		else root.editor.change(fn);
	}

	function pick(what) {
		root.picking = what;
		picker.running = true;
	}

	function addPoint() {
		const t = Math.round(root.editor.playhead * 100) / 100;
		const gain = root.pointGain;
		root.editor.change(r => {
			r.audio = r.audio || {};
			const keys = (r.audio.keys || []).filter(k => Math.abs(k[0] - t) > 0.05);
			// a first point: the volume before it stays as it was
			if (keys.length === 0 && t > 0.5) keys.push([0, 1]);
			keys.push([t, gain]);
			keys.sort((a, b) => a[0] - b[0]);
			r.audio.keys = keys;
		});
	}

	function setPoint(t, gain, live) {
		const fn = r => {
			r.audio.keys = (r.audio.keys || []).map(k => Math.abs(k[0] - t) < 1e-3 ? [k[0], gain] : k);
		};
		if (live) root.editor.drag(fn);
		else root.editor.change(fn);
	}

	function removePoint(t) {
		root.editor.change(r => {
			r.audio.keys = (r.audio.keys || []).filter(k => Math.abs(k[0] - t) > 1e-3);
		});
	}

	function db(linear) {
		return linear <= 0.001 ? "silent" : `${Math.round(20 * Math.log10(linear) * 10) / 10} dB`;
	}

	// ── the film's own ─────────────────────────────────────────────────────
	RevertHeader {
		width: parent.width
		text: "The film's sound"
		changed: !!(root.sound.gain || root.sound.fadeIn || root.sound.fadeOut || root.sound.denoise || root.sound.normalize || root.sound.mute)
		onReverted: root.set({ gain: 0, fadeIn: 0, fadeOut: 0, denoise: 0, normalize: false, mute: false })
	}

	// which of the file's sound tracks goes into the film (a language, a commentary)
	PaneLine {
		visible: Video.audioTracks.length > 1
		label: "Sound track"
		detail: "The one the export takes; the preview switches along"

		Segmented {
			width: Math.min(220, 64 * Video.audioTracks.length)
			options: Video.audioTracks.map(t => ({ value: String(t.index), label: t.lang || t.title || `${t.index + 1}` }))
			current: String(root.sound.track ?? Math.max(0, Video.audioTrack))
			onSelected: value => {
				root.set({ track: Number(value) });
				Video.setAudioTrack(Number(value));
			}
		}
	}

	PaneLine {
		label: "None at all"
		detail: "The export is silent (or has only the music)"

		Toggle {
			checked: !!root.sound.mute
			onToggled: checked => root.set({ mute: checked })
		}
	}

	TuneSlider {
		width: parent.width
		label: "Louder or softer"
		icon: "volume_high"
		accent: root.accent
		enabled: !root.sound.mute
		opacity: enabled ? 1 : 0.45
		// −20 … +12 dB, 0 in its place
		from: -20
		to: 12
		step: 0.5
		value: Number(root.sound.gain) || 0
		valueText: `${shown > 0 ? "+" : ""}${shown.toFixed(1)} dB`
		onMoved: value => root.set({ gain: value }, true)
		onCommitted: root.editor.endDrag()
	}

	TuneSlider {
		width: parent.width
		label: "Fade in"
		icon: "volume_plus"
		accent: root.accent
		from: 0
		to: 10
		step: 0.1
		value: Number(root.sound.fadeIn) || 0
		valueText: shown > 0 ? `${shown.toFixed(1)} s` : "Off"
		onMoved: value => root.set({ fadeIn: value }, true)
		onCommitted: root.editor.endDrag()
	}

	TuneSlider {
		width: parent.width
		label: "Fade out"
		icon: "volume_minus"
		accent: root.accent
		from: 0
		to: 10
		step: 0.1
		value: Number(root.sound.fadeOut) || 0
		valueText: shown > 0 ? `${shown.toFixed(1)} s` : "Off"
		onMoved: value => root.set({ fadeOut: value }, true)
		onCommitted: root.editor.endDrag()
	}

	TuneSlider {
		width: parent.width
		label: "Less noise"
		icon: "waveform"
		accent: root.accent
		from: 0
		to: 1
		value: Number(root.sound.denoise) || 0
		valueText: shown > 0 ? `${Math.round(shown * 100)}` : "Off"
		onMoved: value => root.set({ denoise: Math.round(value * 100) / 100 }, true)
		onCommitted: root.editor.endDrag()
	}

	PaneLine {
		label: "Even loudness"
		detail: "As loud as other videos (−16 LUFS, as the platforms want it)"

		Toggle {
			checked: !!root.sound.normalize
			onToggled: checked => root.set({ normalize: checked })
		}
	}

	StyledText {
		width: parent.width
		wrapMode: Text.WordWrap
		text: "Heard and seen as it will be only in the export; the preview plays the film as it is."
		font.pixelSize: Theme.size.small
		tone: Theme.textSubtle
	}

	// ── the picture's fades ────────────────────────────────────────────────
	RevertHeader {
		width: parent.width
		text: "The picture"
		changed: (Number(Video.recipe.fade?.in) || 0) > 0 || (Number(Video.recipe.fade?.out) || 0) > 0
		onReverted: root.editor.change(r => r.fade = { in: 0, out: 0 })
	}

	TuneSlider {
		width: parent.width
		label: "Picture fades in from black"
		icon: "brightness_4"
		accent: root.accent
		from: 0
		to: 5
		step: 0.1
		value: Number(Video.recipe.fade?.in) || 0
		valueText: shown > 0 ? `${shown.toFixed(1)} s` : "Off"
		onMoved: value => root.editor.drag(r => r.fade = Object.assign({ in: 0, out: 0 }, r.fade || {}, { in: Math.round(value * 10) / 10 }))
		onCommitted: root.editor.endDrag()
	}

	TuneSlider {
		width: parent.width
		label: "Picture fades out to black"
		icon: "brightness_4"
		accent: root.accent
		from: 0
		to: 5
		step: 0.1
		value: Number(Video.recipe.fade?.out) || 0
		valueText: shown > 0 ? `${shown.toFixed(1)} s` : "Off"
		onMoved: value => root.editor.drag(r => r.fade = Object.assign({ in: 0, out: 0 }, r.fade || {}, { out: Math.round(value * 10) / 10 }))
		onCommitted: root.editor.endDrag()
	}

	TextButton {
		text: "The sound's fades too"
		icon: "link_variant"
		variant: "ghost"
		visible: (Number(Video.recipe.fade?.in) || 0) !== (Number(root.sound.fadeIn) || 0) || (Number(Video.recipe.fade?.out) || 0) !== (Number(root.sound.fadeOut) || 0)
		onActivated: root.editor.change(r => r.fade = { in: Number(r.audio?.fadeIn) || 0, out: Number(r.audio?.fadeOut) || 0 })
	}

	// ── another sound ──────────────────────────────────────────────────────
	RevertHeader {
		width: parent.width
		text: "Another sound in its place"
		changed: !!root.sound.replace
		onReverted: root.set({ replace: "" })
	}

	FileLine {
		file: root.sound.replace || ""
		empty: "The film's own sound is used"
		onPicked: root.pick("replace")
		onCleared: root.set({ replace: "" })
	}

	// ── music under it ─────────────────────────────────────────────────────
	RevertHeader {
		width: parent.width
		text: "Music under it"
		changed: !!root.music.path
		onReverted: root.setMusic({ path: "" })
	}

	FileLine {
		file: root.music.path || ""
		empty: "No music"
		onPicked: root.pick("music")
		onCleared: root.setMusic({ path: "" })
	}

	Column {
		width: parent.width
		spacing: 10
		visible: !!root.music.path
		opacity: visible ? 1 : 0

		Behavior on opacity {
			Anim {}
		}

		TuneSlider {
			width: parent.width
			label: "The music's volume"
			icon: "music_note_outline"
			accent: root.accent
			from: -30
			to: 6
			step: 0.5
			value: Number(root.music.gain ?? -8)
			valueText: `${shown > 0 ? "+" : ""}${shown.toFixed(1)} dB`
			onMoved: value => root.setMusic({ gain: value }, true)
			onCommitted: root.editor.endDrag()
		}

		PaneLine {
			label: "Starts at"
			detail: Edit.time(root.music.start || 0) + " in the film"

			TextButton {
				text: "At the playhead"
				icon: "ray_start"
				onActivated: root.setMusic({ start: Math.round(root.editor.playhead * 10) / 10 })
			}
		}

		PaneLine {
			label: "Softer while someone speaks"
			detail: "The music steps back under voices"

			Toggle {
				checked: root.music.duck ?? true
				onToggled: checked => root.setMusic({ duck: checked })
			}
		}
	}

	// ── volume along the film ──────────────────────────────────────────────
	RevertHeader {
		width: parent.width
		text: "Volume along the film"
		changed: root.keys.length > 0
		onReverted: root.set({ keys: [] })
	}

	TuneSlider {
		width: parent.width
		label: "A new point's volume"
		icon: "tune_vertical"
		accent: root.accent
		from: 0
		to: 2
		step: 0.01
		value: root.pointGain
		valueText: `${Math.round(shown * 100)} %`
		onMoved: value => root.pointGain = value
	}

	TextButton {
		text: `A point here, at ${Edit.time(root.editor?.playhead ?? 0)}`
		icon: "plus"
		variant: "filled"
		onActivated: root.addPoint()
	}

	StyledText {
		width: parent.width
		visible: root.keys.length === 0
		wrapMode: Text.WordWrap
		text: "Between two points the volume goes along a straight line; after the last it stays."
		font.pixelSize: Theme.size.small
		tone: Theme.textSubtle
	}

	// by count, so a point's slider is not built anew while it is dragged
	Repeater {
		model: root.keys.length

		delegate: Item {
			id: point

			required property int index
			readonly property var modelData: root.keys[point.index] ?? [0, 1]
			readonly property real t: modelData[0]

			width: parent?.width ?? 300
			height: 48

			Clickable {
				id: when

				width: 64
				height: 30
				anchors.verticalCenter: parent.verticalCenter
				radius: 15
				color: Theme.layer2
				onClicked: root.editor.seekOut(point.t)

				StyledText {
					anchors.centerIn: parent
					text: Edit.time(point.t)
					tabular: true
					font.pixelSize: Theme.size.small
				}
			}

			TuneSlider {
				anchors.left: when.right
				anchors.leftMargin: 10
				anchors.right: remove.left
				anchors.rightMargin: 6
				anchors.verticalCenter: parent.verticalCenter
				label: root.db(point.modelData[1])
				icon: "volume_medium"
				accent: root.accent
				from: 0
				to: 2
				value: point.modelData[1]
				valueText: `${Math.round(shown * 100)} %`
				onMoved: value => root.setPoint(point.t, Math.round(value * 100) / 100, true)
				onCommitted: root.editor.endDrag()
			}

			IconButton {
				id: remove

				anchors.right: parent.right
				anchors.verticalCenter: parent.verticalCenter
				width: 30
				height: 30
				icon: "close"
				onClicked: root.removePoint(point.t)
			}
		}
	}

	// a sound file: its name, another one, none
	component FileLine: Item {
		id: line

		property string file: ""
		property string empty: ""
		signal picked
		signal cleared

		width: parent?.width ?? 300
		height: 40

		Glyph {
			id: fileGlyph

			anchors.verticalCenter: parent.verticalCenter
			icon: line.file ? "music_box_outline" : "music_off"
			size: 18
			color: line.file ? root.accent : Theme.textMuted
		}

		StyledText {
			anchors.left: fileGlyph.right
			anchors.leftMargin: 10
			anchors.right: buttons.left
			anchors.rightMargin: 8
			anchors.verticalCenter: parent.verticalCenter
			elide: Text.ElideMiddle
			text: line.file ? line.file.slice(line.file.lastIndexOf("/") + 1) : line.empty
			tone: line.file ? Theme.text : Theme.textMuted
		}

		Row {
			id: buttons

			anchors.right: parent.right
			anchors.verticalCenter: parent.verticalCenter
			spacing: 4

			TextButton {
				text: line.file ? "Another" : "Pick"
				icon: "folder_music_outline"
				onActivated: line.picked()
			}

			IconButton {
				width: 30
				height: 30
				visible: line.file !== ""
				icon: "close"
				onClicked: line.cleared()
			}
		}
	}

	Process {
		id: picker

		command: ["python3", `${Paths.scripts}/pick_files.py`, "--single", "--start", Video.path.slice(0, Video.path.lastIndexOf("/")), "--filter", "Sound|*.mp3 *.m4a *.aac *.opus *.ogg *.flac *.wav *.wma *.mka", root.picking === "music" ? "Music under the film" : "A sound for the film"]
		stdout: StdioCollector {
			onStreamFinished: {
				const file = String(this.text).trim().split("\n")[0];
				if (!file) return;
				if (root.picking === "music") root.setMusic({ path: file, start: root.music.path ? (root.music.start || 0) : 0 });
				else root.set({ replace: file });
			}
		}
	}
}
