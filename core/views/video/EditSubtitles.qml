pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "../viewer"
import "Edit.js" as Edit

// The subtitles that go with the film: one of its own, one beside it, or
// written by Whisper from what is said; then every line to be corrected –
// its words, when it comes and goes – saved as a copy beside the video (the
// file it came from is never written over), and burnt into the picture or
// put beside the export.
PaneFrame {
	id: root

	property var editor: null
	property color accent: Theme.primary

	readonly property var subs: Video.recipe.subtitles ?? {}
	// the file being corrected, its lines as they are now
	property string file: root.subs.file || Video.subFile
	property var cues: []
	property bool dirty: false
	property bool loading: false
	property bool saving: false
	// Whisper: there, being fetched, or not yet asked
	property var whisper: null
	readonly property bool writing: Video.runningJobs.some(j => j.kind === "transcribe" && j.path === Video.path)
	readonly property bool installing: Video.runningJobs.some(j => j.kind === "whisper_install")

	title: "Subtitles"
	subtitle: root.file ? `${root.cues.length} lines${root.dirty ? " · changed, not saved" : ""}` : "None picked"
	closable: false

	onFileChanged: root.load()
	Component.onCompleted: {
		root.load();
		Video.request("whisper_status", {}, data => root.whisper = data);
	}

	function load() {
		root.dirty = false;
		root.cues = [];
		if (!root.file) return;
		root.loading = true;
		const file = root.file;
		Video.request("cues", { file: file }, data => {
			if (root.file !== file) return;
			root.loading = false;
			root.cues = (data?.cues ?? []).map(c => ({ a: c.a, b: c.b, text: c.text }));
		});
	}

	function use(file) {
		if (root.dirty && file !== root.file) root.editor.say("The changed lines were left unsaved", "subtitles_outline");
		root.editor.change(r => {
			r.subtitles = Object.assign({ file: "", burn: false, beside: false, style: { size: 1, box: false } }, r.subtitles || {}, { file: file });
		});
		root.file = file;
		Video.setSubFile(file);
	}

	function setSubs(changes) {
		root.editor.change(r => {
			r.subtitles = Object.assign({ file: root.file, burn: false, beside: false, style: { size: 1, box: false } }, r.subtitles || {}, changes);
		});
	}

	// shown on the picture while they are corrected
	function touched() {
		root.dirty = true;
		showTimer.restart();
	}

	Timer {
		id: showTimer

		interval: 400
		onTriggered: Video.cues = root.cues.slice().sort((x, y) => x.a - y.a)
	}

	function addHere() {
		const t = Math.round(Video.outToSource(root.editor.playhead).t * 100) / 100;
		const next = root.cues.concat([{ a: t, b: t + 2, text: "" }]);
		next.sort((x, y) => x.a - y.a);
		root.cues = next;
		root.touched();
		const i = next.findIndex(c => c.a === t && c.text === "");
		Qt.callLater(() => cueList.positionViewAtIndex(i, ListView.Contain));
	}

	function removeAt(i) {
		root.cues = root.cues.filter((c, k) => k !== i);
		root.touched();
	}

	function shiftAll(d) {
		root.cues = root.cues.map(c => ({ a: Math.max(0, Math.round((c.a + d) * 1000) / 1000), b: Math.max(0.05, Math.round((c.b + d) * 1000) / 1000), text: c.text }));
		root.touched();
	}

	// a copy beside the video: stem.<lang>.edited.srt (one made here before is ours to write again)
	function save() {
		if (root.saving) return;
		const dir = Video.path.slice(0, Video.path.lastIndexOf("/"));
		const track = Video.subTracks.find(t => t.file === root.file);
		const lang = String(track?.lang || "").toLowerCase().replace(/[^a-z-]/g, "");
		const ours = root.file.endsWith(".edited.srt") && root.file.startsWith(dir + "/");
		const out = ours ? root.file : `${dir}/${Video.nameOf(Video.path)}${lang ? "." + lang : ""}.edited.srt`;
		root.saving = true;
		const cues = root.cues.slice().sort((x, y) => x.a - y.a).filter(c => c.b > c.a);
		Video.request("writesrt", { file: out, cues: cues }, (data, error) => {
			root.saving = false;
			if (error || !data?.file) return root.editor.say(error || "The subtitles could not be saved", "alert_circle_outline");
			root.dirty = false;
			Video.loadSubs(Video.path);
			root.use(data.file);
			root.editor.say(`Saved beside the video as ${data.file.slice(data.file.lastIndexOf("/") + 1)}`, "content_save_outline");
		});
	}

	function writeWithWhisper() {
		Video.transcribe("", result => {
			if (result?.file) root.use(result.file);
		});
	}

	function installWhisper() {
		Video.startJob("whisper_install", {}, "Fetching Whisper", result => {
			Video.request("whisper_status", {}, data => root.whisper = data);
			if (result) root.editor.say("Whisper is there – it can write subtitles now", "check");
		});
	}

	// seconds as "1:02.345", as subtitles want them
	function stamp(t) {
		const ms = Math.round((Number(t) || 0) * 1000);
		const s = Math.floor(ms / 1000);
		const rest = String(ms % 1000).padStart(3, "0");
		return `${Video.formatTime(s)}.${rest}`;
	}

	// ── which ──────────────────────────────────────────────────────────────
	SectionLabel {
		text: "Which"
	}

	Flow {
		width: parent.width
		spacing: 6

		Chip {
			text: "None"
			accent: root.accent
			selected: !root.file
			onClicked: root.use("")
		}

		Repeater {
			model: Video.subTracks

			delegate: Chip {
				required property var modelData

				text: modelData.label || modelData.lang || "Subtitles"
				icon: ({ embedded: "movie_outline", beside: "file_document_outline", made: "creation", downloaded: "download" })[modelData.source] ?? ""
				accent: root.accent
				selected: root.file === modelData.file
				onClicked: root.use(modelData.file)
			}
		}
	}

	PaneLine {
		label: "Write them with Whisper"
		detail: root.whisper && !root.whisper.installed ? "Whisper listens on this computer – it is fetched once (about 300 MB)" : "From what is said, on this computer; a new file beside the video"

		TextButton {
			text: root.writing ? "Writing…" : (root.installing ? "Fetching…" : (root.whisper && !root.whisper.installed ? "Fetch it" : "Write"))
			icon: "creation"
			busy: root.writing || root.installing
			onActivated: root.whisper && !root.whisper.installed ? root.installWhisper() : root.writeWithWhisper()
		}
	}

	// ── into the export ────────────────────────────────────────────────────
	SectionLabel {
		text: "In the export"
		visible: root.file !== ""
	}

	PaneLine {
		visible: root.file !== ""
		label: "Burn into the picture"
		detail: "Always seen, on any player – and never switched off"

		Toggle {
			checked: !!root.subs.burn
			onToggled: checked => root.setSubs({ burn: checked })
		}
	}

	TuneSlider {
		visible: root.file !== "" && !!root.subs.burn
		width: parent.width
		label: "Their size"
		icon: "format_size"
		accent: root.accent
		from: -0.5
		to: 1
		step: 0.05
		value: (Number(root.subs.style?.size) || 1) - 1
		valueText: `${Math.round((shown + 1) * 100)} %`
		onMoved: value => root.editor.drag(r => {
			r.subtitles = Object.assign({}, r.subtitles || {});
			r.subtitles.style = Object.assign({ size: 1, box: false }, r.subtitles.style || {}, { size: Math.round((value + 1) * 100) / 100 });
		})
		onCommitted: root.editor.endDrag()
	}

	PaneLine {
		visible: root.file !== "" && !!root.subs.burn
		label: "On a dark box"
		detail: "Easier to read over a bright picture"

		Toggle {
			checked: !!root.subs.style?.box
			onToggled: checked => root.setSubs({ style: Object.assign({ size: 1 }, root.subs.style || {}, { box: checked }) })
		}
	}

	PaneLine {
		visible: root.file !== ""
		label: "Put beside the export"
		detail: "A .srt with the export's name, cut along with the film"

		Toggle {
			checked: !!root.subs.beside
			onToggled: checked => root.setSubs({ beside: checked })
		}
	}

	// ── the lines ──────────────────────────────────────────────────────────
	SectionLabel {
		text: "The lines"
		visible: root.file !== ""
	}

	Flow {
		width: parent.width
		spacing: 6
		visible: root.file !== ""

		TextButton {
			text: "A line here"
			icon: "plus"
			onActivated: root.addHere()
		}

		TextButton {
			text: "−0.1 s"
			icon: "chevron_left"
			enabled: root.cues.length > 0
			onActivated: root.shiftAll(-0.1)
		}

		TextButton {
			text: "+0.1 s"
			icon: "chevron_right"
			enabled: root.cues.length > 0
			onActivated: root.shiftAll(0.1)
		}

		TextButton {
			text: root.saving ? "Saving…" : "Save a copy"
			icon: "content_save_outline"
			variant: "filled"
			busy: root.saving
			enabled: root.dirty
			onActivated: root.save()
		}
	}

	StyledText {
		visible: root.file !== "" && (root.loading || root.cues.length === 0)
		text: root.loading ? "Reading them…" : "No lines in it"
		tone: Theme.textMuted
	}

	// every line: when (a click goes there), its words, away
	ListView {
		id: cueList

		width: parent.width
		height: Math.min(contentHeight, 520)
		visible: root.file !== "" && root.cues.length > 0
		clip: true
		spacing: 6
		boundsBehavior: Flickable.StopAtBounds
		model: root.cues.length
		cacheBuffer: 400

		delegate: Rectangle {
			id: cueRow

			required property int index
			readonly property var cue: root.cues[cueRow.index] ?? ({ a: 0, b: 0, text: "" })
			readonly property bool now: {
				const t = Video.outToSource(root.editor?.playhead ?? 0).t;
				return t >= cueRow.cue.a && t < cueRow.cue.b;
			}

			width: cueList.width
			height: 96
			radius: Theme.radius.small
			color: cueRow.now ? Qt.alpha(root.accent, 0.14) : Theme.layer1

			Row {
				id: times

				x: 6
				y: 6
				spacing: 4

				Clickable {
					width: 30
					height: 30
					radius: 15
					onClicked: {
						const i = Video.clipsOf(Video.recipe).findIndex(c => (c.src || Video.path) === Video.path && cueRow.cue.a >= c.a && cueRow.cue.a <= c.b);
						if (i >= 0) root.editor.seekOut(Video.sourceToOut(i, cueRow.cue.a));
						else root.editor.say("That line was cut out of the film", "content_cut");
					}

					Glyph {
						anchors.centerIn: parent
						icon: "play"
						size: 16
						color: cueRow.now ? root.accent : Theme.textMuted
					}
				}

				TimeField {
					at: cueRow.cue.a
					onTyped: t => {
						root.cues[cueRow.index].a = t;
						root.touched();
					}
				}

				StyledText {
					anchors.verticalCenter: parent.verticalCenter
					text: "–"
					tone: Theme.textMuted
				}

				TimeField {
					at: cueRow.cue.b
					onTyped: t => {
						root.cues[cueRow.index].b = t;
						root.touched();
					}
				}
			}

			IconButton {
				anchors.right: parent.right
				anchors.rightMargin: 4
				y: 4
				width: 30
				height: 30
				icon: "close"
				onClicked: root.removeAt(cueRow.index)
			}

			AreaField {
				id: words

				x: 6
				anchors.top: times.bottom
				anchors.topMargin: 4
				width: parent.width - 12
				height: 48
				placeholder: "Words"
				Component.onCompleted: words.text = cueRow.cue.text
				onEdited: text => {
					root.cues[cueRow.index].text = text;
					root.touched();
				}
			}
		}
	}

	// a time to be typed: taken when it reads as one
	component TimeField: Field {
		id: timeField

		property real at: 0
		signal typed(real t)

		width: 92
		height: 30
		clearable: false
		fontSize: Theme.size.small
		text: root.stamp(timeField.at)
		onEdited: text => {
			const t = Edit.parse(text);
			if (!isNaN(t)) timeField.typed(t);
		}
	}
}
