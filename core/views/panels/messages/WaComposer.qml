pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.style.theme
import qs.core.services
import qs.style.widgets

// Where a WhatsApp message is written. Enter sends, Ctrl+Enter breaks the
// line; *bold*, _italic_, ~struck~ and `code` are written as in WhatsApp.
// Files – pasted, dropped or picked – go as what they are; the smiley holds
// emoji, stickers and GIFs, the microphone records a voice message, and in a
// group @ names someone.
ColumnLayout {
	id: root

	property string chat: ""
	property bool group: false
	// the message that is answered, or the one of one's own that is changed
	property var reply: null
	property var editing: null
	// [{ path, as }]
	property var files: []
	// photos and videos as they are, not as WhatsApp shrinks them
	property bool whole: false
	property bool picking: false
	property bool polling: false
	// { "@Name": id } of who was named
	property var named: ({})
	readonly property string words: field.text.trim()
	readonly property bool ready: root.words !== "" || root.files.length > 0
	// the name that is being written after an @
	readonly property string naming: {
		if (!root.group) return "";
		const found = field.text.slice(0, field.area.cursorPosition).match(/(?:^|\s)@([\p{L}\p{N}]*)$/u);
		return found ? `@${found[1]}` : "";
	}
	readonly property var offers: root.naming === "" ? [] : (WhatsApp.info?.people ?? []).filter(person => !person.me
		&& String(person.name).toLowerCase().includes(root.naming.slice(1).toLowerCase())).slice(0, 6)

	function focusInput() {
		field.focusInput();
	}

	// another chat: what was being written here is kept, what was written there comes back
	function swap(from, to) {
		if (from !== "") WhatsApp.keep(from, { text: field.text, reply: root.reply });
		const kept = WhatsApp.drafts[to] ?? null;
		field.text = kept?.text ?? "";
		root.reply = kept?.reply ?? null;
		root.editing = null;
		root.files = [];
		root.named = {};
		root.polling = false;
		field.area.cursorPosition = field.area.length;
	}

	function answer(message) {
		root.editing = null;
		root.reply = message;
		field.focusInput();
	}

	function change(message) {
		root.reply = null;
		root.editing = message;
		field.text = message.text;
		field.area.cursorPosition = field.area.length;
		field.focusInput();
	}

	function add(paths) {
		const files = root.files.slice();
		for (const entry of paths) {
			const path = decodeURIComponent(String(entry).replace(/^file:\/\//, ""));
			if (path.startsWith("/") && !files.some(file => file.path === path)) files.push({ path: path, as: "" });
		}
		root.files = files;
		field.focusInput();
	}

	function insert(text) {
		field.area.insert(field.area.cursorPosition, text);
	}

	function name(person) {
		const at = field.area.cursorPosition;
		const label = `@${String(person.name).replace(/\s+/g, " ")}`;
		field.area.remove(at - root.naming.length, at);
		field.area.insert(at - root.naming.length, `${label} `);
		const named = Object.assign({}, root.named);
		named[label] = person.id;
		root.named = named;
	}

	function submit() {
		if (!root.ready || root.chat === "") return;
		// names become the numbers WhatsApp names people by
		let text = root.words;
		const mentions = [];
		for (const label of Object.keys(root.named).sort((a, b) => b.length - a.length)) {
			if (!text.includes(label)) continue;
			text = text.split(label).join(`@${root.named[label].split("@")[0]}`);
			mentions.push(root.named[label]);
		}
		if (root.editing !== null) {
			WhatsApp.act("edit", root.editing.id, { text: text, mentions: mentions });
		} else {
			const files = root.files.map(file => ({ path: file.path, as: file.as || (root.whole ? "document" : "") }));
			WhatsApp.send(root.chat, text, root.reply?.id ?? "", files, mentions);
		}
		root.clear();
	}

	function clear() {
		field.text = "";
		root.files = [];
		root.reply = null;
		root.editing = null;
		root.named = {};
		WhatsApp.keep(root.chat, null);
		pause.stop();
		if (typing.running) WhatsApp.typingIn(root.chat, false);
		typing.stop();
	}

	spacing: 6

	// the others see that something is being written, and when it stopped
	Timer {
		id: typing

		interval: 9000
	}

	Timer {
		id: pause

		interval: 4000
		onTriggered: {
			typing.stop();
			WhatsApp.typingIn(root.chat, false);
		}
	}

	WaPicker {
		id: picker

		Layout.fillWidth: true
		Layout.preferredHeight: root.picking ? 300 : 0
		visible: Layout.preferredHeight > 0.5
		opacity: root.picking ? 1 : 0
		onEmoji: sign => root.insert(sign)
		onSticker: file => {
			WhatsApp.send(root.chat, "", root.reply?.id ?? "", [{ path: file, as: "sticker" }], []);
			root.reply = null;
			root.picking = false;
		}
		onFound: (url, kind) => {
			WhatsApp.sendFound(root.chat, url, kind, root.reply?.id ?? "");
			root.reply = null;
			root.picking = false;
		}

		Behavior on Layout.preferredHeight {
			SpatialAnim {
				duration: Motion.medium
			}
		}
		Behavior on opacity {
			Anim {
				duration: Motion.short
			}
		}
	}

	// a poll: a question and its answers
	Rectangle {
		visible: root.polling
		Layout.fillWidth: true
		implicitHeight: pollForm.implicitHeight + 16
		radius: Theme.radius.large
		color: Theme.layer1

		ColumnLayout {
			id: pollForm

			// the answers, and how many of their fields show: one more once the last is filled
			property var options: Array(12).fill("")
			property int count: 2
			property bool multi: false

			function reset() {
				question.text = "";
				pollForm.options = Array(12).fill("");
				pollForm.count = 2;
				pollForm.round += 1;
			}

			// a new poll starts with empty fields
			property int round: 0

			x: 8
			y: 8
			width: parent.width - 16
			spacing: 6

			Field {
				id: question

				Layout.fillWidth: true
				implicitHeight: 36
				icon: "poll"
				placeholder: "Question"
			}

			Repeater {
				model: 12

				delegate: Field {
					id: answerField

					required property int index
					readonly property int round: pollForm.round

					visible: index < pollForm.count
					Layout.fillWidth: true
					implicitHeight: 34
					placeholder: `Answer ${index + 1}`
					onRoundChanged: answerField.text = ""
					onEdited: text => {
						pollForm.options[index] = text;
						if (index === pollForm.count - 1 && text !== "" && pollForm.count < 12) pollForm.count += 1;
					}
				}
			}

			RowLayout {
				Layout.fillWidth: true
				spacing: 8

				Chip {
					text: "Several answers"
					selected: pollForm.multi
					onClicked: pollForm.multi = !pollForm.multi
				}

				Item {
					Layout.fillWidth: true
				}

				TextButton {
					text: "Send"
					icon: "send"
					variant: "filled"
					enabled: question.text.trim() !== "" && pollForm.count > 2
					onActivated: {
						WhatsApp.chatDo("poll", root.chat, { text: question.text, options: pollForm.options, multi: pollForm.multi });
						pollForm.reset();
						root.polling = false;
					}
				}
			}
		}
	}

	// who can be named
	Flow {
		visible: root.offers.length > 0
		Layout.fillWidth: true
		spacing: 6

		Repeater {
			model: root.offers

			delegate: Chip {
				required property var modelData

				icon: "account"
				text: modelData.name
				onClicked: root.name(modelData)
			}
		}
	}

	// what is answered or changed
	Reveal {
		shown: root.reply !== null || root.editing !== null

		Rectangle {
			width: parent.width
			implicitHeight: 46
			radius: Theme.radius.large
			color: Theme.layer1
			clip: true

			Rectangle {
				width: 3
				height: parent.height
				radius: 1.5
				color: Theme.primary
			}

			RowLayout {
				anchors.fill: parent
				anchors.leftMargin: 12
				anchors.rightMargin: 4
				spacing: 8

				Glyph {
					icon: root.editing !== null ? "pencil" : "reply"
					size: 15
					color: Theme.primary
				}

				ColumnLayout {
					Layout.fillWidth: true
					spacing: 0

					StyledText {
						text: root.editing !== null ? "Edit" : (root.reply?.mine ? "You" : String(root.reply?.name ?? "").replace(/^~/, ""))
						tone: Theme.primary
						font.pixelSize: Theme.size.small
						font.weight: Font.DemiBold
					}

					StyledText {
						Layout.fillWidth: true
						text: {
							const message = root.editing ?? root.reply;
							if (!message) return "";
							return String(message.text || message.kind).replace(/\s+/g, " ");
						}
						tone: Theme.textMuted
						elide: Text.ElideRight
						font.pixelSize: Theme.size.small
					}
				}

				IconButton {
					implicitWidth: 30
					implicitHeight: 30
					icon: "close"
					onClicked: {
						if (root.editing !== null) field.text = "";
						root.reply = null;
						root.editing = null;
					}
				}
			}
		}
	}

	Flow {
		visible: root.files.length > 0
		Layout.fillWidth: true
		spacing: 6

		Repeater {
			model: root.files

			delegate: Chip {
				required property var modelData

				icon: /\.(png|jpe?g|gif|webp|bmp)$/i.test(modelData.path) ? "image_outline" : "paperclip"
				text: `${modelData.path.split("/").pop()}  ✕`
				onClicked: root.files = root.files.filter(file => file.path !== modelData.path)
			}
		}

		Chip {
			visible: root.files.some(file => /\.(png|jpe?g|webp|bmp|mp4|mov|mkv|webm)$/i.test(file.path))
			icon: "file_outline"
			text: "As files"
			selected: root.whole
			onClicked: root.whole = !root.whole
		}
	}

	// a voice message is being recorded
	RowLayout {
		visible: WhatsApp.recording
		Layout.fillWidth: true
		spacing: 8

		IconButton {
			implicitWidth: 48
			implicitHeight: 48
			icon: "delete_outline"
			variant: "danger"
			onClicked: WhatsApp.record("cancel")
		}

		Rectangle {
			Layout.fillWidth: true
			implicitHeight: 48
			radius: 24
			color: Theme.layer1

			RowLayout {
				anchors.fill: parent
				anchors.leftMargin: 18
				spacing: 8

				Rectangle {
					implicitWidth: 10
					implicitHeight: 10
					radius: 5
					color: Theme.danger

					SequentialAnimation on opacity {
						running: WhatsApp.recording
						loops: Animation.Infinite

						Anim {
							to: 0.25
							duration: 600
						}
						Anim {
							to: 1
							duration: 600
						}
					}
				}

				StyledText {
					id: elapsed

					property real now: Date.now()

					Layout.fillWidth: true
					text: Format.clock((elapsed.now - WhatsApp.recordingSince) / 1000)
					tabular: true
					font.pixelSize: Theme.size.body

					Timer {
						interval: 500
						repeat: true
						running: WhatsApp.recording
						onTriggered: elapsed.now = Date.now()
					}
				}
			}
		}

		IconButton {
			implicitWidth: 48
			implicitHeight: 48
			icon: "send"
			variant: "filled"
			onClicked: {
				WhatsApp.record("stop", root.chat, root.reply?.id ?? "");
				root.reply = null;
			}
		}
	}

	// the field, with what goes with a message on its left and what sends it on its right
	Rectangle {
		visible: !WhatsApp.recording
		Layout.fillWidth: true
		implicitHeight: bar.implicitHeight + 8
		radius: Math.min(24, height / 2)
		color: field.focused ? Theme.layer2 : Theme.layer1
		border.width: field.focused ? 1.5 : 0
		border.color: Qt.alpha(Theme.primary, 0.85)

		Behavior on color {
			ColorAnim {}
		}

		RowLayout {
			id: bar

			x: 4
			y: 4
			width: parent.width - 8
			spacing: 2

			IconButton {
				Layout.alignment: Qt.AlignBottom
				implicitWidth: 40
				implicitHeight: 40
				icon: "emoticon_happy_outline"
				checked: root.picking
				onClicked: {
					root.picking = !root.picking;
					root.polling = false;
					if (root.picking) picker.show(picker.tab);
					else field.focusInput();
				}
			}

			IconButton {
				Layout.alignment: Qt.AlignBottom
				implicitWidth: 40
				implicitHeight: 40
				icon: "paperclip"
				onClicked: if (!chooser.running) chooser.running = true
			}

			IconButton {
				Layout.alignment: Qt.AlignBottom
				implicitWidth: 40
				implicitHeight: 40
				icon: "poll"
				checked: root.polling
				onClicked: {
					root.polling = !root.polling;
					root.picking = false;
				}
			}

			AreaField {
				id: field

				Layout.fillWidth: true
				Layout.preferredHeight: Math.max(40, Math.min(200, Math.ceil(field.area.contentHeight) + 22))
				color: "transparent"
				border.width: 0
				placeholder: "Message"
				autocorrect: true
				asksPaste: true
				onPasting: if (!clipboard.running) clipboard.running = true
				onEdited: text => {
					if (root.chat === "" || root.editing !== null) return;
					if (text === "") {
						if (typing.running) pause.triggered();
						pause.stop();
						return;
					}
					if (!typing.running) {
						typing.start();
						WhatsApp.typingIn(root.chat, true);
					}
					pause.restart();
				}
			}

			IconButton {
				Layout.alignment: Qt.AlignBottom
				implicitWidth: 40
				implicitHeight: 40
				icon: root.ready ? "send" : "microphone"
				variant: root.ready ? "filled" : "ghost"
				onClicked: root.ready ? root.submit() : WhatsApp.record("start", root.chat)
			}
		}
	}

	// Enter sends (or takes the first name that is offered), Ctrl+Enter breaks the line.
	// The field takes the key before any shortcut would, so it is asked first.
	function pressed(event) {
		if (event.key !== Qt.Key_Return && event.key !== Qt.Key_Enter) return;
		if (event.modifiers & Qt.ControlModifier) {
			field.area.insert(field.area.cursorPosition, "\n");
			event.accepted = true;
		} else if (!(event.modifiers & (Qt.ShiftModifier | Qt.AltModifier))) {
			if (root.offers.length > 0) root.name(root.offers[0]);
			else root.submit();
			event.accepted = true;
		}
	}

	Component.onCompleted: {
		field.area.Keys.pressed.connect(root.pressed);
		field.area.topPadding = 7;
		field.area.bottomPadding = 7;
	}

	Shortcut {
		sequence: "Escape"
		enabled: field.focused && (root.reply !== null || root.editing !== null || root.picking)
		onActivated: {
			if (root.picking) root.picking = false;
			else {
				if (root.editing !== null) field.text = "";
				root.reply = null;
				root.editing = null;
			}
		}
	}

	// the desktop's own file chooser
	Process {
		id: chooser

		command: ["python3", `${Paths.scripts}/pick_files.py`]
		stdout: SplitParser {
			onRead: line => root.add([line])
		}
	}

	// Ctrl+V: a picture or copied files go with the message, words into it
	Process {
		id: clipboard

		command: ["python3", `${Paths.scripts}/messages/paste.py`]
		stdout: SplitParser {
			onRead: line => {
				let held = { kind: "text", text: "" };
				try {
					held = JSON.parse(line);
				} catch (error) {}
				if (held.kind === "image") root.add([held.path]);
				else if (held.kind === "files") root.add(held.paths);
				else if (held.text) root.insert(held.text);
			}
		}
	}
}
