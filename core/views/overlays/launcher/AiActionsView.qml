pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.style.theme
import qs.core.services
import qs.style.widgets
import "../../../lib/AiIntents.js" as Intents

// Launcher >ai: the AI line. What is typed is matched to the features by
// its words (lib/AiIntents.js) – the actions on the clipboard, a chat, a
// translation, a search through the files, the chats and the models – and
// the best fit comes first; ↑↓ pick another one.
ColumnLayout {
	id: root

	property string argument: ""
	property bool active: false
	// the chat's model, and what is installed
	property string model: ""
	property var models: []
	readonly property string actionModel: root.models.includes(AiActions.model) ? AiActions.model : root.model
	property bool busy: false
	property string clipboard: ""
	property bool reading: false
	property int currentIndex: 0
	readonly property string instruction: String(root.argument || "").trim()
	readonly property bool hasClipboard: root.clipboard.trim() !== ""
	readonly property var intents: {
		const quoted = rest => rest !== "" ? ` “${rest}”` : "";
		const clipboard = AiActions.fixed.map(action => ({
			id: action.id,
			icon: action.icon,
			label: action.title,
			hint: "Clipboard",
			words: action.words,
			shown: root.hasClipboard,
			run: () => root.runRequested(action.prompt, root.clipboard.replace(/\r\n/g, "\n"))
		}));
		return [
			{ id: "translate-text", icon: "translate", label: rest => rest !== "" ? `Translate${quoted(rest)}` : "Translate…", shown: Plugins.on("translate"),
				words: ["übersetz", "uebersetz", "translat"],
				run: rest => root.commandRequested(`>t ${rest}`) }
		].concat(clipboard).concat([
			{ id: "files", icon: "folder_search_outline", label: rest => rest !== "" ? `Find${quoted(rest)} in your files` : "Find in your files…", shown: Files.enabled,
				words: ["such", "find", "wo ist", "wo sind", "where"],
				hints: ["rechnung", "invoice", "vertrag", "foto", "photo", "bild", "picture", "screenshot", "datei", "file", "dokument", "document", "pdf", "brief", "letter"],
				run: rest => root.filesRequested(rest) },
			{ id: "chat", icon: "chat", label: rest => rest !== "" ? `Ask ${root.model || "the chat"}:${quoted(rest)}` : "New chat",
				words: ["frag", "ask", "chat", "hilf", "help", "schreib", "write", "erzähl", "tell", "wie", "how", "warum", "why", "was", "what"],
				run: (rest, prompt) => root.chatRequested(rest !== "" ? prompt : "") },
			{ id: "chats", icon: "forum", label: "Earlier chats", words: ["verlauf", "history", "chats", "früher", "frueher", "letzte", "last", "alte", "old"],
				run: () => root.commandRequested(">chats ") },
			{ id: "models", icon: "robot", label: "Models", shown: Plugins.on("ollama"), words: ["modell", "model", "ollama", "download", "install", "lad"],
				run: () => root.commandRequested(">ollama ") },
			{ id: "custom", fallback: true, icon: "content_paste", label: rest => `With the clipboard: “${rest}”`, shown: root.hasClipboard,
				run: (rest, prompt) => root.runRequested(`${prompt}\n\n(Bezieht sich auf den Text aus der Zwischenablage. Antworte auf Deutsch, sofern nicht anders verlangt.)`, root.clipboard.replace(/\r\n/g, "\n")) },
			{ id: "ask", fallback: true, instead: "chat", icon: "chat", label: rest => `Ask ${root.model || "the chat"}: “${rest}”`,
				run: (rest, prompt) => root.chatRequested(prompt) }
		]);
	}
	readonly property var actions: Intents.rank(root.instruction, root.intents)

	signal runRequested(string prompt, string text)
	signal chatRequested(string prompt)
	signal commandRequested(string query)
	signal filesRequested(string query)

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
		if (!action || root.busy) return;
		action.run();
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

				Clickable {
					implicitWidth: modelRow.implicitWidth + 16
					implicitHeight: 24
					radius: height / 2
					interactive: root.models.length > 0
					onClicked: modelPicker.open()

					RowLayout {
						id: modelRow

						anchors.centerIn: parent
						spacing: 5

						Glyph {
							icon: "robot"
							size: 14
							color: Theme.textSubtle
						}

						StyledText {
							text: root.actionModel || "No model"
							tone: Theme.textSubtle
							font.pixelSize: Theme.size.small
						}

						Glyph {
							visible: root.models.length > 0
							icon: "chevron_down"
							size: 14
							color: Theme.textSubtle
						}
					}

					PickList {
						id: modelPicker

						x: parent ? parent.width - width : 0
						y: parent ? parent.height + 4 : 0
						current: root.models.includes(AiActions.model) ? AiActions.model : ""
						entries: [{ value: "", label: "Like the chat", detail: root.model, icon: "message_outline" }].concat(root.models.map(name => ({ value: name, label: name, icon: "robot_outline" })))
						onPicked: value => AiActions.setModel(value)
					}
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
			title: actionRow.modelData.label
			subtitle: actionRow.modelData.hint ?? ""
			selected: root.currentIndex === actionRow.index
			enabled: !root.busy
			opacity: root.busy ? 0.45 : 1
			onPointed: root.currentIndex = actionRow.index
			onClicked: root.run(actionRow.modelData)
		}
	}
}
