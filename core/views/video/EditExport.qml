pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "../viewer"
import "Edit.js" as Edit

// The film made: what for (a card each – the best, anywhere, small, a chat
// that takes only so much, a GIF, only the sound), then the quality, the
// size, the frame rate, a size to stay under; a line saying what will
// happen; and the export itself with its progress, then play, show, share.
PaneFrame {
	id: root

	property var editor: null
	property color accent: Theme.primary

	readonly property var presets: [
		{ id: "original", label: "Original quality", detail: "MKV, as good as the film", icon: "diamond_stone", container: "mkv", vcodec: "auto", crf: 18, target_mb: 0, max_side: 0, fps: 0, audio_kbps: 192 },
		{ id: "mp4", label: "MP4 for anywhere", detail: "H.264 – every phone and player", icon: "play_box_outline", container: "mp4", vcodec: "h264", crf: 20, target_mb: 0, max_side: 0, fps: 0, audio_kbps: 160 },
		{ id: "small", label: "Small", detail: "HEVC – half the size, newer players", icon: "arrow_collapse", container: "mp4", vcodec: "hevc", crf: 26, target_mb: 0, max_side: 0, fps: 0, audio_kbps: 128 },
		{ id: "whatsapp", label: "WhatsApp", detail: "Under 16 MB, 720p", icon: "whatsapp", container: "mp4", vcodec: "h264", crf: 23, target_mb: 15, max_side: 1280, fps: 30, audio_kbps: 96 },
		{ id: "discord", label: "Discord", detail: "Under 10 MB", icon: "message_outline", container: "mp4", vcodec: "h264", crf: 23, target_mb: 9.5, max_side: 1280, fps: 30, audio_kbps: 96 },
		{ id: "webm", label: "WebM", detail: "VP9 for the web", icon: "web", container: "webm", vcodec: "vp9", crf: 32, target_mb: 0, max_side: 0, fps: 0, audio_kbps: 128 },
		{ id: "gif", label: "GIF", detail: "Moving picture, no sound", icon: "file_gif_box", container: "gif", vcodec: "auto", crf: 20, target_mb: 0, max_side: 480, fps: 15, audio_kbps: 0 },
		{ id: "audio", label: "Only the sound", detail: "M4A", icon: "music_note_outline", container: "m4a", vcodec: "auto", crf: 20, target_mb: 0, max_side: 0, fps: 0, audio_kbps: 192, audio_only: true }
	]

	property string presetId: Video.setting("preset", "mp4")
	readonly property var preset: root.presets.find(p => p.id === root.presetId) ?? root.presets[1]
	// changed by hand, on top of the preset (forgotten with another preset)
	property var tweaks: ({})
	readonly property var chosen: Object.assign({}, root.preset, { hw: true }, root.tweaks)
	readonly property bool still: root.preset.container === "gif"
	readonly property bool soundOnly: !!root.preset.audio_only

	readonly property real seconds: Math.max(0.1, root.editor?.duration ?? Video.outDuration)
	readonly property bool lossless: Video.setting("losslessFirst", true) && Edit.cutOnly(Video.recipe, Video.clipsOf(Video.recipe)) && root.chosen.vcodec === "auto" && !root.still && !root.soundOnly
		&& !(root.chosen.target_mb > 0) && !(root.chosen.max_side > 0) && !(root.chosen.fps > 0)

	// the export of this film that runs, and the last one made
	property bool rendering: false
	property var result: null
	readonly property var job: Video.runningJobs.find(j => j.kind === "export" && j.path === Video.path) ?? null
	readonly property bool busy: root.rendering || !!root.job

	title: "Export"
	subtitle: `${Edit.length(root.seconds)} · beside the video, as a new file`
	closable: false

	function pick(id) {
		root.presetId = id;
		root.tweaks = {};
		Video.setSetting("preset", id);
	}

	function tweak(key, value) {
		const next = Object.assign({}, root.tweaks);
		if (value === root.preset[key]) delete next[key];
		else next[key] = value;
		root.tweaks = next;
	}

	// what will happen, in a line
	readonly property string plan: {
		if (root.soundOnly) return "Only the sound, with its edits, as M4A";
		if (root.lossless) {
			const size = Number(Video.meta?.size) || 0;
			const share = Video.duration > 0 ? root.seconds / Video.duration : 1;
			return `Cut without re-encoding – fast, no loss; the cuts move to keyframes${size > 0 ? ` · about ${Math.round(size * share / 1e6)} MB` : ""}`;
		}
		const how = root.chosen.hw ? "with the graphics card" : "in software";
		if (root.chosen.target_mb > 0) {
			const kbps = Math.max(50, Math.round(root.chosen.target_mb * 8192 / root.seconds - (root.chosen.audio_kbps || 0)));
			return `Re-encoded ${how} to stay under ${root.chosen.target_mb} MB – about ${kbps >= 1000 ? (kbps / 1000).toFixed(1) + " Mbit/s" : kbps + " kbit/s"} for the picture`;
		}
		if (root.still) return `A GIF ${root.chosen.max_side || 480} px wide at ${root.chosen.fps || 15} frames a second`;
		return `Re-encoded ${how}, the size as the picture needs it`;
	}

	function start() {
		if (root.busy) return;
		root.result = null;
		root.rendering = true;
		const preset = Object.assign({}, root.chosen);
		delete preset.label;
		delete preset.detail;
		delete preset.icon;
		const go = overlays => {
			root.rendering = false;
			Video.exportWith(preset, overlays, result => root.result = result);
		};
		// the texts and arrows as pictures first, at the export's size
		if (root.editor?.overlay && (Video.recipe.texts?.length ?? 0) > 0) root.editor.overlay.renderTexts(go);
		else go([]);
	}

	// ── what for ───────────────────────────────────────────────────────────
	Grid {
		id: cards

		width: parent.width
		columns: 2
		spacing: 8

		Repeater {
			model: root.presets

			delegate: Clickable {
				id: card

				required property var modelData
				readonly property bool current: root.presetId === modelData.id

				width: (cards.width - 8) / 2
				height: 74
				radius: Theme.radius.medium
				color: card.current ? Qt.alpha(root.accent, 0.2) : (card.hovered ? Theme.layer3 : Theme.layer2)
				border.width: card.current ? 1.5 : 0
				border.color: root.accent
				onClicked: root.pick(card.modelData.id)

				Behavior on color {
					ColorAnim {}
				}

				Glyph {
					x: 10
					y: 10
					icon: card.modelData.icon
					size: 18
					color: card.current ? root.accent : Theme.textMuted
				}

				StyledText {
					x: 10
					y: 32
					width: card.width - 20
					elide: Text.ElideRight
					text: card.modelData.label
					font.weight: Font.DemiBold
					font.pixelSize: Theme.size.label
				}

				StyledText {
					x: 10
					y: 50
					width: card.width - 20
					elide: Text.ElideRight
					text: card.modelData.detail
					font.pixelSize: Theme.size.small
					tone: Theme.textMuted
				}
			}
		}
	}

	// ── how ────────────────────────────────────────────────────────────────
	RevertHeader {
		width: parent.width
		text: "How"
		changed: Object.keys(root.tweaks).length > 0
		onReverted: root.tweaks = {}
	}

	TuneSlider {
		visible: !root.soundOnly && !root.still
		width: parent.width
		label: root.chosen.target_mb > 0 ? "Quality (the size decides)" : "Quality"
		icon: "high_definition"
		accent: root.accent
		enabled: !(root.chosen.target_mb > 0) && !root.lossless
		opacity: enabled ? 1 : 0.45
		// around the preset's: right is better and bigger
		from: -10
		to: 10
		step: 1
		value: root.preset.crf - root.chosen.crf
		valueText: `${shown > 0 ? "better" : (shown < 0 ? "smaller" : "as the preset")} · crf ${root.preset.crf - Math.round(shown)}`
		onMoved: value => root.tweak("crf", root.preset.crf - Math.round(value))
	}

	PaneLine {
		visible: !root.soundOnly
		label: "Largest side"
		detail: root.chosen.max_side > 0 ? `${root.chosen.max_side} px at most` : "As the film"

		Segmented {
			width: 240
			// the long side for 1440p … 480p
			options: [{ value: "0", label: "As is" }, { value: "2560", label: "1440" }, { value: "1920", label: "1080" }, { value: "1280", label: "720" }, root.still ? { value: "480", label: "480" } : { value: "854", label: "480" }]
			current: String(root.chosen.max_side)
			onSelected: value => root.tweak("max_side", Number(value))
		}
	}

	PaneLine {
		visible: !root.soundOnly
		label: "Frames a second"

		Segmented {
			width: 200
			options: [{ value: "0", label: "As is" }, { value: "60", label: "60" }, { value: "30", label: "30" }, { value: "24", label: "24" }].concat(root.still ? [{ value: "15", label: "15" }] : [])
			current: String(root.chosen.fps)
			onSelected: value => root.tweak("fps", Number(value))
		}
	}

	PaneLine {
		visible: !root.soundOnly && !root.still
		label: "Stay under"
		detail: "MB – empty for the quality above"

		Field {
			width: 80
			height: 34
			placeholder: "MB"
			clearable: false
			text: root.chosen.target_mb > 0 ? String(root.chosen.target_mb) : ""
			onEdited: text => {
				const mb = Number(String(text).replace(",", "."));
				root.tweak("target_mb", mb > 0 ? mb : 0);
			}
		}
	}

	PaneLine {
		visible: !root.soundOnly && !root.still
		label: "The graphics card"
		detail: "Much faster; in software when it would not take it"

		Toggle {
			checked: root.chosen.hw
			onToggled: checked => root.tweak("hw", checked)
		}
	}

	// what will happen
	Rectangle {
		width: parent.width
		height: planText.implicitHeight + 20
		radius: Theme.radius.medium
		color: Theme.layer2

		Glyph {
			id: planGlyph

			x: 10
			y: 10
			icon: root.lossless ? "lightning_bolt_outline" : "information_outline"
			size: 16
			color: root.lossless ? root.accent : Theme.textMuted
		}

		StyledText {
			id: planText

			anchors.left: planGlyph.right
			anchors.leftMargin: 8
			anchors.right: parent.right
			anchors.rightMargin: 10
			y: 10
			wrapMode: Text.WordWrap
			text: root.plan
			font.pixelSize: Theme.size.small
		}
	}

	// ── the export ─────────────────────────────────────────────────────────
	TextButton {
		visible: !root.busy
		text: "Export"
		icon: "export_variant"
		variant: "filled"
		enabled: Video.current
		onActivated: root.start()
	}

	Column {
		width: parent.width
		spacing: 8
		visible: root.busy

		Row {
			width: parent.width
			spacing: 8

			StyledText {
				width: parent.width - cancel.width - 8
				anchors.verticalCenter: parent.verticalCenter
				elide: Text.ElideRight
				text: root.rendering ? "Making the texts into pictures…" : `${root.job?.text || "Exporting"} · ${Math.round((root.job?.progress ?? 0) * 100)} %`
				font.pixelSize: Theme.size.label
			}

			TextButton {
				id: cancel

				text: "Cancel"
				variant: "ghost"
				enabled: !!root.job
				onActivated: Video.cancelJob(root.job.id)
			}
		}

		Rectangle {
			width: parent.width
			height: 6
			radius: 3
			color: Theme.layer3

			Rectangle {
				width: parent.width * (root.job?.progress ?? 0)
				height: parent.height
				radius: 3
				color: root.accent

				Behavior on width {
					SpatialAnim {}
				}
			}
		}
	}

	// made: what it became, and on with it
	Rectangle {
		width: parent.width
		visible: !!root.result?.file && !root.busy
		height: doneColumn.implicitHeight + 20
		radius: Theme.radius.medium
		color: Qt.alpha(root.accent, 0.12)

		Column {
			id: doneColumn

			x: 10
			y: 10
			width: parent.width - 20
			spacing: 8

			StyledText {
				width: parent.width
				elide: Text.ElideMiddle
				text: root.result?.file ? root.result.file.slice(root.result.file.lastIndexOf("/") + 1) : ""
				font.weight: Font.DemiBold
			}

			StyledText {
				width: parent.width
				wrapMode: Text.WordWrap
				text: [root.result?.lossless ? "Cut without re-encoding" : (root.result?.hw ? "Made with the graphics card" : "Made in software"),
					root.result?.size ? `${(root.result.size / 1e6).toFixed(1)} MB` : "", root.result?.duration ? Edit.length(root.result.duration) : ""].filter(v => v).join(" · ")
				font.pixelSize: Theme.size.small
				tone: Theme.textMuted
			}

			Flow {
				width: parent.width
				spacing: 6

				TextButton {
					text: "Play"
					icon: "play"
					onActivated: Video.open(root.result.file)
				}

				TextButton {
					text: "Show in Files"
					icon: "folder_open_outline"
					onActivated: Files.reveal(root.result.file)
				}

				TextButton {
					id: shareButton

					text: "Share"
					icon: "share_variant_outline"
					onActivated: {
						shareMenu.path = root.result.file;
						const p = shareButton.mapToItem(shareMenu, 0, shareButton.height);
						shareMenu.popup(p.x, p.y);
					}
				}
			}
		}
	}


	// over the whole window: a menu does not fit into the panel
	ShareMenu {
		id: shareMenu

		parent: root.Window.contentItem
		anchors.fill: parent
		z: 60
	}
}
