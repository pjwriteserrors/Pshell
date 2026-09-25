pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.style.theme
import qs.core.services
import qs.style.widgets

// Launcher >ai: Ollama actions on the clipboard text. Picking an action (or
// typing an own instruction) hands prompt + clipboard to the launcher, which
// runs them as a new temporary chat.
ColumnLayout {
	id: root

	property string argument: ""
	property bool active: false
	property string model: ""
	property bool busy: false
	property string clipboard: ""
	property bool reading: false
	property int currentIndex: 0
	readonly property string instruction: String(root.argument || "").trim()
	readonly property bool ready: root.clipboard.trim() !== "" && !root.busy
	readonly property var actions: {
		const fixed = [
			{ id: "explain", icon: "lightbulb", title: "Explain", prompt: "Erkläre den Text aus der Zwischenablage verständlich. Antworte auf Deutsch." },
			{ id: "summarize", icon: "text_short", title: "Summarize", prompt: "Fasse den Text aus der Zwischenablage kurz und präzise zusammen. Antworte auf Deutsch." },
			{ id: "translate", icon: "translate", title: "Translate", prompt: "Übersetze den Text aus der Zwischenablage: Ist er auf Deutsch, übersetze ihn ins Englische, sonst ins Deutsche. Gib nur die Übersetzung aus." },
			{ id: "improve", icon: "auto_fix", title: "Improve wording", prompt: "Verbessere Formulierung, Rechtschreibung und Grammatik des Textes aus der Zwischenablage. Behalte Sprache, Bedeutung und Ton bei und gib nur den verbesserten Text aus." },
			{ id: "reply", icon: "reply", title: "Reply draft", prompt: "Schreibe einen passenden Antwortentwurf auf die Nachricht aus der Zwischenablage. Antworte auf Deutsch." }
		];
		if (root.instruction === "") return fixed;
		return [{
			id: "custom",
			icon: "creation",
			title: root.instruction,
			prompt: `${root.instruction}\n\n(Bezieht sich auf den Text aus der Zwischenablage. Antworte auf Deutsch, sofern nicht anders verlangt.)`
		}].concat(fixed);
	}

	signal runRequested(string prompt, string text)

	spacing: 12

	onActiveChanged: {
		if (!root.active) return;
		root.currentIndex = 0;
		root.readClipboard();
	}
	onInstructionChanged: root.currentIndex = 0

	function readClipboard() {
		root.reading = true;
		paste.exec(["timeout", "2s", "wl-paste", "--no-newline", "--type", "text/plain"]);
	}

	function move(delta) {
		root.currentIndex = Math.max(0, Math.min(root.actions.length - 1, root.currentIndex + delta));
	}

	function handleKey(event) {
		return false;
	}

	function cancel() {
		return false;
	}

	function activate(modifiers) {
		root.run(root.actions[root.currentIndex]);
	}

	function run(action) {
		if (!action || !root.ready) return;
		root.runRequested(action.prompt, root.clipboard.replace(/\r\n/g, "\n"));
	}

	Process {
		id: paste

		stdout: StdioCollector {
			onStreamFinished: {
				root.reading = false;
				root.clipboard = String(text || "");
			}
		}
	}

	// clipboard preview
	Rectangle {
		Layout.fillWidth: true
		implicitHeight: preview.implicitHeight + 28
		radius: Theme.radius.huge
		color: Theme.layer1

		ColumnLayout {
			id: preview

			x: 16
			y: 14
			width: parent.width - 32
			spacing: 8

			RowLayout {
				Layout.fillWidth: true
				spacing: 8

				Glyph {
					icon: "content_paste"
					size: 15
					color: Theme.primary
				}

				StyledText {
					text: "Clipboard"
					font.pixelSize: Theme.size.label
					font.weight: Font.DemiBold
				}

				StyledText {
					visible: root.clipboard !== ""
					text: `${root.clipboard.length} chars`
					tone: Theme.textSubtle
					tabular: true
					font.pixelSize: Theme.size.small
				}

				Item {
					Layout.fillWidth: true
				}

				Glyph {
					icon: "robot"
					size: 14
					color: Theme.textSubtle
				}

				StyledText {
					text: root.model || "No model"
					tone: Theme.textSubtle
					font.pixelSize: Theme.size.small
				}
			}

			StyledText {
				Layout.fillWidth: true
				text: root.clipboard.trim() !== "" ? root.clipboard.trim() : (root.reading ? "" : "Empty")
				tone: root.clipboard.trim() !== "" ? Theme.text : Theme.textSubtle
				wrapMode: Text.Wrap
				maximumLineCount: 5
				textFormat: Text.PlainText
				font.pixelSize: Theme.size.body
			}
		}
	}

	ListView {
		id: actionList

		Layout.fillWidth: true
		Layout.fillHeight: true
		clip: true
		spacing: 2
		model: root.actions
		currentIndex: root.currentIndex
		boundsBehavior: Flickable.StopAtBounds
		ScrollBar.vertical: ThinScrollBar {}

		delegate: ListItem {
			id: actionRow

			required property var modelData
			required property int index

			width: actionList.width
			icon: actionRow.modelData.icon
			title: actionRow.modelData.title
			selected: root.currentIndex === actionRow.index
			enabled: root.ready
			opacity: root.ready ? 1 : 0.45
			onEntered: root.currentIndex = actionRow.index
			onClicked: root.run(actionRow.modelData)
		}
	}
}
