pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.style.theme
import qs.core.services
import qs.style.widgets

// Where a message is written: the text, what goes with it and the send
// button. A picture – pasted, dropped or picked – stands in the text where
// the cursor is; any other file is attached. Marked text is made bold, italic
// or underlined (Ctrl+B, I, U). The text box holds the snippets: texts that
// are written again and again. Ctrl+Enter sends; the eye shows the mail as it
// would arrive.
ColumnLayout {
	id: root

	// attached files
	property var files: []
	property string placeholder: "Message"
	property real maxHeight: 260
	// a forward needs no words of its own
	property bool allowEmpty: false
	// who the mail goes to: decides which snippets are offered and whose name they carry
	property var people: []
	// the words alone; a picture counts as one sign
	property string plain: ""
	readonly property bool blank: root.plain.trim() === "" && root.files.length === 0
	readonly property bool ready: root.allowEmpty || !root.blank
	property bool snippets: false
	readonly property var offered: Snippets.offered(root.people.map(person => person.email))
	// the customer the chat is with: a snippet can be kept for it alone
	readonly property var customer: Customers.of(Mail.shown).find(customer => root.people.some(person => customer.people.includes(person.email))) ?? null
	property bool forCustomer: false
	// the assistant is there: the wand asks it for a greeting, thanks and a last sentence
	property bool assist: false
	property bool framing: false

	signal submit
	signal preview
	signal frame
	// what is written changed
	signal edited

	onFilesChanged: root.edited()

	function clear() {
		field.text = "";
		root.files = [];
	}

	// what is being written, to be put back later; null when there is nothing
	function written() {
		return root.blank ? null : { html: root.markup(), files: root.files };
	}

	function restore(kept) {
		field.text = kept?.html ?? "";
		root.files = kept?.files ?? [];
		field.area.cursorPosition = field.area.length;
	}

	function markup() {
		return field.area.length > 0 ? field.area.getFormattedText(0, field.area.length) : "";
	}

	// the words without the pictures between them
	function words() {
		return root.plain.replace(/￼/g, "").trim();
	}

	function focusInput() {
		field.focusInput();
	}

	function escaped(text) {
		return String(text).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
	}

	// at the cursor, in place of what is marked
	function put(markup) {
		const area = field.area;
		if (area.selectionStart !== area.selectionEnd) area.remove(area.selectionStart, area.selectionEnd);
		area.insert(area.cursorPosition, markup);
	}

	// all of it anew, in one step that can be undone
	function fill(text) {
		field.area.selectAll();
		root.type(text);
		field.focusInput();
	}

	// lines before and after what is written
	function wrap(before, after) {
		const area = field.area;
		const breaks = text => root.escaped(text).replace(/\r?\n/g, "<br>");
		const empty = root.words() === "";
		if (after !== "") area.insert(area.length, breaks(after));
		if (before !== "") area.insert(0, breaks(before));
		// an empty mail is written on between the two
		area.cursorPosition = empty ? before.length : area.length;
		field.focusInput();
	}

	function type(text) {
		root.put(root.escaped(text).replace(/\r?\n/g, "<br>"));
	}

	function add(paths) {
		const files = root.files.slice();
		for (const entry of paths) {
			const path = decodeURIComponent(String(entry).replace(/^file:\/\//, ""));
			if (!path.startsWith("/")) continue;
			if (/\.(png|jpe?g|gif|webp|bmp)$/i.test(path)) {
				// as wide as it is, up to what the field shows well
				probe.source = `file://${path}`;
				const width = Math.round(Math.min(360, probe.implicitWidth > 0 ? probe.implicitWidth : 360));
				probe.source = "";
				root.put(`<img src="file://${path.replace(/"/g, "&quot;")}" width="${width}">`);
			} else if (!files.includes(path)) {
				files.push(path);
			}
		}
		root.files = files;
	}

	function toggle(style) {
		const font = field.area.cursorSelection.font;
		if (style === "bold") field.area.cursorSelection.font.bold = !font.bold;
		else if (style === "italic") field.area.cursorSelection.font.italic = !font.italic;
		else field.area.cursorSelection.font.underline = !font.underline;
	}

	spacing: 6

	Image {
		id: probe

		visible: false
		asynchronous: false
		cache: false
	}

	// the snippets, and the field that keeps what is written as a new one
	Rectangle {
		Layout.fillWidth: true
		Layout.preferredHeight: root.snippets ? Math.min(260, shelf.implicitHeight + 16) : 0
		visible: Layout.preferredHeight > 0.5
		opacity: root.snippets ? 1 : 0
		radius: Theme.radius.large
		color: Theme.layer1
		clip: true

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

		ColumnLayout {
			id: shelf

			x: 8
			y: 8
			width: parent.width - 16
			spacing: 4

			ListView {
				Layout.fillWidth: true
				Layout.preferredHeight: Math.min(190, contentHeight)
				visible: count > 0
				clip: true
				spacing: 2
				boundsBehavior: Flickable.StopAtBounds
				ScrollBar.vertical: ThinScrollBar {}
				model: ScriptModel {
					values: root.offered.map(snippet => snippet.id)
				}

				delegate: Clickable {
					id: row

					required property string modelData
					readonly property var snippet: root.offered.find(snippet => snippet.id === row.modelData) ?? { id: "", name: "", text: "", customer: "" }

					width: ListView.view.width
					implicitHeight: 40
					radius: Theme.radius.medium
					pressedScale: 0.98
					showHover: false
					color: row.hovered ? Theme.layer2 : "transparent"
					onClicked: {
						root.type(Snippets.filled(row.snippet, root.people[0]?.name ?? ""));
						root.snippets = false;
						root.focusInput();
					}

					RowLayout {
						anchors.fill: parent
						anchors.leftMargin: 10
						anchors.rightMargin: 4
						spacing: 8

						Glyph {
							icon: row.snippet.customer ? Mail.grouping(Mail.shown).icon : "text_box"
							size: 15
							color: Theme.textSubtle
						}

						StyledText {
							text: row.snippet.name
							font.pixelSize: Theme.size.label
							font.weight: Font.DemiBold
						}

						StyledText {
							Layout.fillWidth: true
							text: String(row.snippet.text).replace(/\s+/g, " ")
							tone: Theme.textMuted
							elide: Text.ElideRight
							font.pixelSize: Theme.size.small
						}

						IconButton {
							implicitWidth: 28
							implicitHeight: 28
							icon: "delete_outline"
							opacity: row.hovered ? 1 : 0
							onClicked: Snippets.remove(row.modelData)
						}
					}
				}
			}

			RowLayout {
				Layout.fillWidth: true
				spacing: 6

				Field {
					id: title

					Layout.fillWidth: true
					implicitHeight: 36
					icon: "plus"
					placeholder: "Keep the text as"
					onAccepted: keeper.clicked(null)
				}

				Chip {
					visible: root.customer !== null
					implicitHeight: 32
					icon: Mail.grouping(Mail.shown).icon
					text: root.customer?.name ?? ""
					selected: root.forCustomer
					onClicked: root.forCustomer = !root.forCustomer
				}

				IconButton {
					id: keeper

					implicitWidth: 36
					implicitHeight: 36
					icon: "check"
					variant: "filled"
					enabled: title.text.trim() !== "" && root.words() !== ""
					onClicked: {
						if (!enabled) return;
						Snippets.add(title.text, root.plain.replace(/￼/g, "").trim(), root.forCustomer && root.customer ? root.customer.id : "");
						title.text = "";
					}
				}
			}
		}
	}

	Flow {
		Layout.fillWidth: true
		visible: root.files.length > 0
		spacing: 6

		Repeater {
			model: root.files

			delegate: Chip {
				required property string modelData

				icon: "paperclip"
				text: `${modelData.split("/").pop()}  ✕`
				onClicked: root.files = root.files.filter(path => path !== modelData)
			}
		}
	}

	RowLayout {
		Layout.fillWidth: true
		spacing: 6

		IconButton {
			Layout.alignment: Qt.AlignBottom
			implicitWidth: 40
			implicitHeight: 40
			icon: "paperclip"
			variant: "tonal"
			onClicked: if (!picker.running) picker.running = true
		}

		IconButton {
			Layout.alignment: Qt.AlignBottom
			implicitWidth: 40
			implicitHeight: 40
			icon: "text_box"
			variant: "tonal"
			checked: root.snippets
			onClicked: root.snippets = !root.snippets
		}

		IconButton {
			visible: root.assist
			Layout.alignment: Qt.AlignBottom
			implicitWidth: 40
			implicitHeight: 40
			icon: root.framing ? "" : "auto_fix"
			variant: "tonal"
			iconColor: Theme.tertiary
			interactive: !root.framing
			onClicked: root.frame()

			Spinner {
				anchors.centerIn: parent
				visible: root.framing
				width: 18
				height: 18
				color: Theme.tertiary
			}
		}

		AreaField {
			id: field

			Layout.fillWidth: true
			Layout.preferredHeight: Math.max(40, Math.min(root.maxHeight, field.area.contentHeight + 28))
			placeholder: root.placeholder
			autocorrect: true
			rich: true
			asksPaste: true
			onPasting: if (!clipboard.running) clipboard.running = true
			onEdited: {
				root.plain = field.area.getText(0, field.area.length);
				root.edited();
			}

			// what is marked gets its look here
			Rectangle {
				anchors.right: parent.right
				anchors.top: parent.top
				anchors.margins: 5
				width: looks.width + 6
				height: 30
				radius: 15
				color: Theme.layer3
				opacity: field.area.selectedText !== "" ? 1 : 0
				visible: opacity > 0.01

				Behavior on opacity {
					Anim {
						duration: Motion.short
					}
				}

				Row {
					id: looks

					anchors.centerIn: parent

					Repeater {
						model: ["bold", "italic", "underline"]

						delegate: IconButton {
							required property string modelData

							implicitWidth: 26
							implicitHeight: 26
							icon: `format_${modelData}`
							onClicked: root.toggle(modelData)
						}
					}
				}
			}
		}

		IconButton {
			Layout.alignment: Qt.AlignBottom
			implicitWidth: 40
			implicitHeight: 40
			icon: "eye_outline"
			variant: "tonal"
			enabled: root.ready
			onClicked: root.preview()
		}

		IconButton {
			Layout.alignment: Qt.AlignBottom
			implicitWidth: 40
			implicitHeight: 40
			icon: "send"
			variant: "filled"
			enabled: root.ready
			onClicked: root.submit()
		}
	}

	Shortcut {
		sequences: ["Ctrl+Return", "Ctrl+Enter"]
		enabled: field.focused && root.ready
		onActivated: root.submit()
	}

	Shortcut {
		sequence: "Ctrl+B"
		enabled: field.focused
		onActivated: root.toggle("bold")
	}

	Shortcut {
		sequence: "Ctrl+I"
		enabled: field.focused
		onActivated: root.toggle("italic")
	}

	Shortcut {
		sequence: "Ctrl+U"
		enabled: field.focused
		onActivated: root.toggle("underline")
	}

	// the desktop's own file chooser
	Process {
		id: picker

		command: ["python3", `${Paths.scripts}/pick_files.py`]
		stdout: SplitParser {
			onRead: line => root.add([line])
		}
	}

	// Ctrl+V: a picture or copied files go with the mail, words into it
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
				else if (held.text) root.type(held.text);
			}
		}
	}
}
