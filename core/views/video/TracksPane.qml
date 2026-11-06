pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.style.widgets
import qs.core.services

// What is heard and what is read: the file's sound tracks, the volume
// following the film's loudness; the subtitles – the file's own, the ones
// beside it, found online (OpenSubtitles) or written here by Whisper – and
// how they sit: sooner or later, larger, on a dark band.
PaneFrame {
	id: root

	title: "Sound and subtitles"

	// ── sound ──────────────────────────────────────────────────────────────
	SectionLabel {
		text: "Sound"
	}

	Repeater {
		model: Video.audioTracks

		Choice {
			required property var modelData

			text: [modelData.title, root.language(modelData.lang)].filter(x => x).join(" · ") || `Track ${modelData.index + 1}`
			detail: modelData.codec
			checked: Video.audioTrack === modelData.index
			onClicked: Video.setAudioTrack(modelData.index)
		}
	}

	StyledText {
		visible: Video.audioTracks.length === 0
		text: Video.hasAudio ? "One sound track" : "This video has no sound"
		tone: Theme.textMuted
		font.pixelSize: Theme.size.small
	}

	PaneLine {
		label: "Even loudness"
		detail: "Quiet words up, loud bangs down – good at night"

		Toggle {
			checked: Video.setting("evenLoudness", false)
			onToggled: checked => Video.setSetting("evenLoudness", checked)
		}
	}

	// ── subtitles ──────────────────────────────────────────────────────────
	SectionLabel {
		text: "Subtitles"
	}

	Choice {
		text: "Off"
		checked: Video.subFile === "" || !Video.setting("subtitles", true)
		onClicked: {
			Video.setSubFile("");
			Video.keepFor(Video.path, { sub: "" });
		}
	}

	Repeater {
		model: Video.subTracks

		Choice {
			required property var modelData

			text: modelData.label || root.language(modelData.lang) || "Subtitles"
			detail: ({ embedded: "In the file", beside: "Beside the file", made: "Written by Whisper", downloaded: "Found online" })[modelData.source] ?? ""
			checked: Video.setting("subtitles", true) && Video.subFile === modelData.file
			onClicked: {
				Video.setSetting("subtitles", true);
				Video.setSubFile(modelData.file);
			}
		}
	}

	PaneLine {
		visible: Video.subFile !== ""
		label: "Timing"
		detail: Video.subDelay === 0 ? "As they are (G sooner, H later)" : `${Video.subDelay > 0 ? "Later" : "Sooner"} by ${Math.abs(Video.subDelay).toFixed(1)} s`

		Row {
			spacing: 4

			IconButton {
				width: 32
				height: 32
				icon: "minus"
				onClicked: Video.setSubDelay(Video.subDelay - 0.1)
			}
			IconButton {
				width: 32
				height: 32
				icon: "restore"
				enabled: Video.subDelay !== 0
				onClicked: Video.setSubDelay(0)
			}
			IconButton {
				width: 32
				height: 32
				icon: "plus"
				onClicked: Video.setSubDelay(Video.subDelay + 0.1)
			}
		}
	}

	PaneLine {
		label: "Size"

		Segmented {
			width: 190
			options: [{ value: "0.8", label: "S" }, { value: "1", label: "M" }, { value: "1.25", label: "L" }, { value: "1.6", label: "XL" }]
			current: String(Video.setting("subSize", 1))
			onSelected: value => Video.setSetting("subSize", Number(value))
		}
	}

	PaneLine {
		label: "On a dark band"
		detail: "Easier to read on bright pictures"

		Toggle {
			checked: Video.setting("subBox", false)
			onToggled: checked => Video.setSetting("subBox", checked)
		}
	}

	// ── found online ───────────────────────────────────────────────────────
	SectionLabel {
		text: "Find subtitles"
	}

	Row {
		width: root.bodyWidth
		spacing: 8

		Field {
			id: langField

			width: 90
			height: 36
			placeholder: "de"
			text: Video.setting("subLang", "") || "de"
			onAccepted: root.search()
		}

		TextButton {
			text: root.searching ? "Looking …" : "Look online"
			icon: "magnify"
			enabled: !root.searching && Video.current
			onClicked: root.search()
		}
	}

	StyledText {
		width: root.bodyWidth
		visible: !Video.setting("opensubtitlesKey", "")
		wrapMode: Text.WordWrap
		text: "OpenSubtitles wants a key of your own (free, opensubtitles.com › API consumers). Put it in Settings."
		tone: Theme.textMuted
		font.pixelSize: Theme.size.small
	}

	StyledText {
		width: root.bodyWidth
		visible: root.searchNote !== ""
		wrapMode: Text.WordWrap
		text: root.searchNote
		tone: Theme.textMuted
		font.pixelSize: Theme.size.small
	}

	Repeater {
		model: root.results

		Clickable {
			id: hit

			required property var modelData

			width: root.bodyWidth
			height: 48
			radius: Theme.radius.medium
			color: hit.hovered ? Theme.layer2 : "transparent"
			onClicked: root.fetch(hit.modelData)

			Column {
				anchors.left: parent.left
				anchors.leftMargin: 10
				anchors.right: parent.right
				anchors.rightMargin: 40
				anchors.verticalCenter: parent.verticalCenter

				StyledText {
					width: parent.width
					text: hit.modelData.name
				}

				StyledText {
					text: `${root.language(hit.modelData.lang)} · ${hit.modelData.downloads ?? 0} downloads${hit.modelData.hash ? " · made for this file" : ""}`
					tone: Theme.textMuted
					font.pixelSize: Theme.size.small
				}
			}

			Glyph {
				anchors.right: parent.right
				anchors.rightMargin: 10
				anchors.verticalCenter: parent.verticalCenter
				icon: "download_outline"
				size: 18
				color: root.accent
			}
		}
	}

	// ── written here ───────────────────────────────────────────────────────
	SectionLabel {
		text: "Write them from the sound"
	}

	StyledText {
		width: root.bodyWidth
		wrapMode: Text.WordWrap
		text: root.whisper.installed ? "Whisper listens and writes them, on this computer – nothing goes out. A film takes a few minutes." : "Whisper listens and writes them, on this computer. It needs to be fetched once (about 300 MB)."
		tone: Theme.textMuted
		font.pixelSize: Theme.size.small
	}

	Row {
		spacing: 8
		visible: root.whisper.installed

		Segmented {
			width: 200
			options: [{ value: "", label: "Any" }, { value: "de", label: "German" }, { value: "en", label: "English" }]
			current: root.whisperLang
			onSelected: value => root.whisperLang = value
		}

		TextButton {
			text: "Write"
			icon: "text_recognition"
			enabled: Video.current && !root.writing
			onClicked: Video.transcribe(root.whisperLang)
		}
	}

	TextButton {
		visible: !root.whisper.installed
		text: root.whisper.installing ? "Fetching Whisper …" : "Fetch Whisper"
		icon: "download_outline"
		enabled: !root.whisper.installing
		onClicked: Video.startJob("whisper_install", {}, "Fetching Whisper", () => root.checkWhisper())
	}

	Repeater {
		model: Video.runningJobs.filter(j => j.kind === "transcribe" || j.kind === "whisper_install")

		Column {
			required property var modelData

			width: root.bodyWidth
			spacing: 6

			StyledText {
				width: parent.width
				text: modelData.text || modelData.label
				tone: Theme.textMuted
				font.pixelSize: Theme.size.small
			}

			Rectangle {
				width: parent.width
				height: 4
				radius: 2
				color: Theme.layer3

				Rectangle {
					width: parent.width * Math.max(0.02, modelData.progress || 0)
					height: parent.height
					radius: 2
					color: root.accent

					Behavior on width {
						SpatialAnim {}
					}
				}
			}
		}
	}

	// ── how it works ───────────────────────────────────────────────────────
	property var results: []
	property bool searching: false
	property string searchNote: ""
	property var whisper: ({ installed: false, installing: false })
	property string whisperLang: Video.setting("subLang", "")
	readonly property bool writing: Video.runningJobs.some(j => j.kind === "transcribe")

	function language(code) {
		const names = { de: "German", deu: "German", ger: "German", en: "English", eng: "English", fr: "French", fre: "French", fra: "French", es: "Spanish", spa: "Spanish", it: "Italian", ita: "Italian", ja: "Japanese", jpn: "Japanese", tr: "Turkish", tur: "Turkish", ru: "Russian", rus: "Russian", pl: "Polish", pol: "Polish", nl: "Dutch", nld: "Dutch" };
		return names[String(code || "").toLowerCase()] ?? String(code || "").toUpperCase();
	}

	function search() {
		const key = Video.setting("opensubtitlesKey", "");
		if (!key) {
			root.searchNote = "A key is needed first (Settings).";
			return;
		}
		const lang = langField.text.trim() || "de";
		Video.setSetting("subLang", lang);
		root.searching = true;
		root.searchNote = "";
		Video.request("subsearch", { path: Video.path, lang: lang, key: key }, (data, error) => {
			root.searching = false;
			root.results = data?.results ?? [];
			if (error) root.searchNote = error;
			else if (root.results.length === 0) root.searchNote = "Nothing found for this video.";
		});
	}

	function fetch(hit) {
		const path = Video.path;
		Video.request("subget", { file_id: hit.file_id, key: Video.setting("opensubtitlesKey", ""), path: path, lang: hit.lang }, (data, error) => {
			if (error || !data?.file) return Video.say(error || "Could not fetch them", "alert_circle_outline");
			Video.loadSubs(path);
			Video.setSubFile(data.file);
			Video.say("Subtitles fetched – they lie beside the video now", "subtitles_outline");
		});
	}

	function checkWhisper() {
		Video.request("whisper_status", {}, data => {
			if (data) root.whisper = data;
		});
	}

	Component.onCompleted: root.checkWhisper()

	// ── a choice of a list ─────────────────────────────────────────────────
	component Choice: Clickable {
		id: choice

		property string text: ""
		property string detail: ""
		property bool checked: false

		width: root.bodyWidth
		height: choice.detail ? 46 : 38
		radius: Theme.radius.medium
		color: choice.checked ? Qt.alpha(root.accent, 0.16) : (choice.hovered ? Theme.layer2 : "transparent")

		Glyph {
			id: mark

			x: 10
			anchors.verticalCenter: parent.verticalCenter
			icon: choice.checked ? "radiobox_marked" : "radiobox_blank"
			size: 18
			color: choice.checked ? root.accent : Theme.textMuted
		}

		Column {
			anchors.left: mark.right
			anchors.leftMargin: 10
			anchors.right: parent.right
			anchors.rightMargin: 10
			anchors.verticalCenter: parent.verticalCenter

			StyledText {
				width: parent.width
				text: choice.text
				font.weight: choice.checked ? Font.DemiBold : Font.Normal
			}

			StyledText {
				width: parent.width
				visible: choice.detail !== ""
				text: choice.detail
				tone: Theme.textMuted
				font.pixelSize: Theme.size.small
			}
		}
	}
}
