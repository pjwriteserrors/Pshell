pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// Which model writes recaps and fills character sheets: Ollama on this machine, or
// the Claude or Codex subscription the command line tools are signed in to.
ColumnLayout {
	id: root

	property var status: null
	property string result: ""
	property bool testing: false
	readonly property string provider: Streams.settings.aiProvider ?? "ollama"
	readonly property string model: Streams.settings.aiModel ?? ""
	readonly property var current: root.status?.[root.provider] ?? null

	function load() {
		Streams.call("aiStatus", {}, data => root.status = data);
	}

	function test() {
		root.testing = true;
		root.result = "";
		Streams.call("aiTest", {}, (data, error) => {
			root.testing = false;
			root.result = error ? error : `It answers: "${data.answer}" (${data.seconds} s)`;
		});
	}

	spacing: 12
	Component.onCompleted: load()
	onVisibleChanged: if (visible) load()

	SectionHeading {
		text: "AI"
	}
	StyledText {
		Layout.fillWidth: true
		text: "Writes recaps and fills character sheets, one small question at a time."
		tone: Theme.textMuted
		wrapMode: Text.Wrap
	}
	Segmented {
		Layout.preferredWidth: 420
		Layout.preferredHeight: 34
		options: [{ value: "ollama", label: "On this PC (Ollama)" }, { value: "claude", label: "Claude" }, { value: "codex", label: "Codex" }]
		current: root.provider
		onSelected: value => {
			Streams.setSetting("aiProvider", value);
			Streams.setSetting("aiModel", "");
			root.result = "";
		}
	}
	Flow {
		Layout.fillWidth: true
		spacing: 5

		Chip {
			text: "Default"
			selected: root.model === ""
			onClicked: Streams.setSetting("aiModel", "")
		}
		Repeater {
			model: root.current?.models ?? []

			Chip {
				required property string modelData

				text: modelData.replace("hf.co/", "")
				selected: root.model === modelData
				onClicked: Streams.setSetting("aiModel", modelData)
			}
		}
	}
	StyledText {
		Layout.fillWidth: true
		text: {
			if (!root.status) return "";
			if (!root.current?.ready) return ({ ollama: "Ollama is not running. Start it, or fetch a model with: ollama pull llama3.1:8b", claude: "Sign in once in a terminal with: claude", codex: "Sign in once in a terminal with: codex login" })[root.provider];
			if (root.provider === "ollama") return "Stays on this PC. A question takes 10 to 30 seconds here.";
			return `Uses your ${root.provider === "claude" ? "Claude" : "ChatGPT"} subscription, no API key, and counts toward its limits. Subtitles and titles go to ${root.provider === "claude" ? "Anthropic" : "OpenAI"}. It runs with no tools, so nothing in a video can make it do anything.`;
		}
		color: root.current?.ready ? Theme.textMuted : Theme.warning
		font.pixelSize: Theme.size.small
		wrapMode: Text.Wrap
	}
	RowLayout {
		spacing: 10

		TextButton {
			text: root.testing ? "Asking…" : "Try it"
			variant: "tonal"
			busy: root.testing
			onActivated: root.test()
		}
		StyledText {
			Layout.fillWidth: true
			text: root.result
			font.pixelSize: Theme.size.small
			wrapMode: Text.Wrap
		}
	}
}
