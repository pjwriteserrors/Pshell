pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.style.theme
import qs.core.services
import qs.style.widgets

// Launcher >t: translates the argument while typing. `>t fr text` or the
// language chips pick the target; Enter copies the translation.
ColumnLayout {
	id: root

	property string argument: ""
	property bool active: false
	signal closeRequested
	// replaces the text after ">t "
	signal argumentRequested(string text)

	// `fr some text` → { target: "fr", text: "some text", inline: true }
	readonly property var parsed: {
		const value = String(root.argument || "").trim();
		const match = /^([a-zA-Z]{2})\s+([\s\S]+)$/.exec(value);
		if (match && Translator.languages.some(language => language.code === match[1].toLowerCase()))
			return { target: match[1].toLowerCase(), text: match[2].trim(), inline: true };
		return { target: Translator.target, text: value, inline: false };
	}
	readonly property bool current: Translator.input !== "" && Translator.input === root.parsed.text && !Translator.pending
	property bool copyWhenReady: false

	spacing: 12

	onParsedChanged: if (root.active) Translator.request(root.parsed.text, root.parsed.target)
	onActiveChanged: {
		root.copyWhenReady = false;
		if (root.active) Translator.request(root.parsed.text, root.parsed.target);
	}

	function move(delta) {}

	function handleKey(event) {
		return false;
	}

	function cancel() {
		return false;
	}

	function activate(modifiers) {
		if (root.parsed.text === "") return;
		if (!root.current) {
			root.copyWhenReady = true;
			return;
		}
		root.copy();
	}

	function copy() {
		root.copyWhenReady = false;
		if (Translator.result === "") return;
		Quickshell.execDetached(["wl-copy", "--", Translator.result]);
		Haptics.play("copied");
		root.closeRequested();
	}

	function pickTarget(code) {
		Translator.target = code;
		if (root.parsed.inline) root.argumentRequested(root.parsed.text);
	}

	function swap() {
		if (Translator.result === "" || Translator.source === "") return;
		Translator.target = Translator.source;
		root.argumentRequested(Translator.result);
	}

	Connections {
		target: Translator

		function onFinished() {
			if (root.copyWhenReady && root.current) root.copy();
		}
	}

	Flow {
		Layout.fillWidth: true
		spacing: 6

		Repeater {
			model: Translator.languages

			delegate: Chip {
				required property var modelData

				text: modelData.label
				selected: root.parsed.target === modelData.code
				onClicked: root.pickTarget(modelData.code)
			}
		}
	}

	Rectangle {
		Layout.fillWidth: true
		Layout.fillHeight: true
		radius: Theme.radius.huge
		color: Theme.layer1

		ColumnLayout {
			anchors.fill: parent
			anchors.margins: 18
			visible: root.parsed.text !== ""
			spacing: 10

			RowLayout {
				Layout.fillWidth: true
				spacing: 8

				StyledText {
					visible: Translator.source !== ""
					text: Translator.languageName(Translator.source)
					tone: Theme.textMuted
					font.pixelSize: Theme.size.label
					font.weight: Font.DemiBold
				}

				Glyph {
					visible: Translator.source !== ""
					icon: "arrow_right"
					size: 14
					color: Theme.textSubtle
				}

				StyledText {
					visible: Translator.resultTarget !== ""
					text: Translator.languageName(Translator.resultTarget)
					tone: Theme.primary
					font.pixelSize: Theme.size.label
					font.weight: Font.DemiBold
				}

				Spinner {
					Layout.preferredWidth: 14
					Layout.preferredHeight: 14
					visible: Translator.pending
				}

				Item {
					Layout.fillWidth: true
				}

				IconButton {
					icon: "swap_horizontal"
					variant: "tonal"
					enabled: Translator.result !== "" && Translator.source !== ""
					onClicked: root.swap()
				}

				IconButton {
					icon: "content_copy"
					variant: "tonal"
					iconSize: 16
					enabled: Translator.result !== ""
					onClicked: root.copy()
				}
			}

			Flickable {
				id: resultFlick

				Layout.fillWidth: true
				Layout.fillHeight: true
				contentHeight: resultText.implicitHeight
				clip: true
				boundsBehavior: Flickable.StopAtBounds
				ScrollBar.vertical: ThinScrollBar {}

				TextEdit {
					id: resultText

					width: resultFlick.width
					text: Translator.result
					readOnly: true
					selectByMouse: true
					wrapMode: TextEdit.Wrap
					color: Translator.error !== "" ? Theme.danger : (root.current ? Theme.text : Theme.textMuted)
					selectionColor: Qt.alpha(Theme.primary, 0.35)
					selectedTextColor: Theme.text
					font.family: Theme.fontFamily
					font.pixelSize: {
						const length = text.length;
						if (length < 60) return 30;
						if (length < 180) return 22;
						return 16;
					}
					font.weight: Font.Medium

					Behavior on color {
						ColorAnim {}
					}
				}
			}

			StyledText {
				Layout.fillWidth: true
				visible: Translator.error !== ""
				text: Translator.error
				tone: Theme.danger
				font.pixelSize: Theme.size.small
			}
		}

		Glyph {
			anchors.centerIn: parent
			visible: root.parsed.text === ""
			icon: "translate"
			size: 40
			color: Theme.textFaint
		}
	}
}
