pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "FileKinds.js" as Kinds

// A name that is taken while copying or moving: both files side by side,
// which one is newer and bigger, and what to do – replace (the old one goes
// to the trash), merge two folders, keep both, skip or give it a new name;
// for this one or for all that follow.
DialogFrame {
	id: root

	readonly property var job: Files.conflict
	readonly property var conflict: root.job?.conflict ?? null
	readonly property bool folders: !!root.conflict?.merge
	property bool renaming: false

	shown: !!root.conflict
	dismissable: false
	cardWidth: 560

	onConflictChanged: {
		root.renaming = false;
		forAll.checked = false;
		if (root.conflict) {
			Sounds.play("attention");
			keys.forceActiveFocus();
		}
	}

	function pick(choice) {
		if (choice === "rename") {
			Files.resolve("rename", false, nameField.text.trim());
			return;
		}
		Files.resolve(choice, forAll.checked, "");
	}

	Item {
		id: keys

		focus: root.shown && !root.renaming
		// a letter for each answer: Replace / Merge, Keep both, Skip, All
		Keys.onPressed: event => {
			switch (event.key) {
			case Qt.Key_Escape:
				Files.cancel(root.job.id);
				break;
			case Qt.Key_R:
			case Qt.Key_M:
			case Qt.Key_Return:
			case Qt.Key_Enter:
				root.pick(root.folders ? "merge" : "replace");
				break;
			case Qt.Key_K:
			case Qt.Key_B:
				root.pick("keep");
				break;
			case Qt.Key_S:
				root.pick("skip");
				break;
			case Qt.Key_A:
				forAll.checked = !forAll.checked;
				break;
			case Qt.Key_N:
				renameButton.clicked(null);
				break;
			default:
				return;
			}
			event.accepted = true;
		}
	}

	component Side: ColumnLayout {
		id: side

		property var entry: null
		property string label: ""
		property bool newer: false
		property bool bigger: false

		spacing: 8

		StyledText {
			text: side.label
			tone: Theme.textSubtle
			font.pixelSize: Theme.size.small
			font.weight: Font.DemiBold
		}

		Rectangle {
			Layout.fillWidth: true
			Layout.preferredHeight: 130
			radius: Theme.radius.large
			color: Theme.layer2

			FileThumb {
				anchors.centerIn: parent
				width: 140
				height: 110
				path: String(side.entry?.path || "")
				name: String(side.entry?.name || "")
				mime: String(side.entry?.mime || "")
				dir: !!side.entry?.dir
				kind: Kinds.kindOf(side.entry)
				thumb: String(side.entry?.thumb || "")
				canThumb: !!side.entry?.canThumb
				isText: !!side.entry?.text
			}
		}

		StyledText {
			Layout.fillWidth: true
			text: String(side.entry?.name || "")
			font.weight: Font.DemiBold
			elide: Text.ElideMiddle
		}

		RowLayout {
			spacing: 6

			StyledText {
				text: side.entry?.dir ? "Folder" : Files.sizeText(side.entry?.size ?? 0)
				tone: side.bigger ? Theme.text : Theme.textMuted
				font.pixelSize: Theme.size.label
				font.weight: side.bigger ? Font.DemiBold : Font.Normal
			}

			StyledText {
				text: "·"
				tone: Theme.textSubtle
			}

			StyledText {
				text: Files.whenText(side.entry?.mtime ?? 0)
				tone: side.newer ? Theme.text : Theme.textMuted
				font.pixelSize: Theme.size.label
				font.weight: side.newer ? Font.DemiBold : Font.Normal
			}

			Rectangle {
				visible: side.newer
				width: newerLabel.implicitWidth + 12
				height: 18
				radius: 9
				color: Theme.primarySoft

				Text {
					id: newerLabel

					anchors.centerIn: parent
					text: "newer"
					color: Theme.primary
					font.family: Theme.fontFamily
					font.pixelSize: Theme.size.tiny
					font.weight: Font.Bold
				}
			}
		}
	}

	ColumnLayout {
		width: parent.width
		spacing: 16

		ColumnLayout {
			spacing: 3

			StyledText {
				text: root.folders ? "A folder of that name is already there" : "A file of that name is already there"
				font.pixelSize: Theme.size.title
				font.weight: Font.DemiBold
			}

			StyledText {
				text: `“${root.conflict?.target?.name ?? ""}” in ${Files.pretty(Files.parentOf(root.conflict?.target?.path ?? ""))}`
				tone: Theme.textMuted
				elide: Text.ElideMiddle
				Layout.maximumWidth: parent.width
			}
		}

		RowLayout {
			spacing: 16

			Side {
				Layout.fillWidth: true
				Layout.preferredWidth: 1
				label: "COMING"
				entry: root.conflict?.source ?? null
				newer: (root.conflict?.source?.mtime ?? 0) > (root.conflict?.target?.mtime ?? 0)
				bigger: (root.conflict?.source?.size ?? 0) > (root.conflict?.target?.size ?? 0)
			}

			Glyph {
				icon: "arrow_right"
				size: 22
				color: Theme.textSubtle
			}

			Side {
				Layout.fillWidth: true
				Layout.preferredWidth: 1
				label: "ALREADY THERE"
				entry: root.conflict?.target ?? null
				newer: (root.conflict?.target?.mtime ?? 0) > (root.conflict?.source?.mtime ?? 0)
				bigger: (root.conflict?.target?.size ?? 0) > (root.conflict?.source?.size ?? 0)
			}
		}

		RowLayout {
			visible: root.renaming
			Layout.fillWidth: true
			spacing: 8

			Field {
				id: nameField

				Layout.fillWidth: true
				icon: "form_textbox"
				onAccepted: root.pick("rename")
				onEscapePressed: root.renaming = false
			}

			TextButton {
				text: "Use this name"
				variant: "filled"
				onClicked: root.pick("rename")
			}
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 8

			Toggle {
				id: forAll

				onToggled: on => forAll.checked = on
			}

			StyledText {
				text: "For all that follow  A"
				tone: Theme.textMuted
				font.pixelSize: Theme.size.label

				MouseArea {
					anchors.fill: parent
					onClicked: forAll.checked = !forAll.checked
				}
			}

			Item {
				Layout.fillWidth: true
			}

			TextButton {
				text: "Stop"
				variant: "ghost"
				onClicked: Files.cancel(root.job.id)
			}
		}

		Flow {
			Layout.fillWidth: true
			spacing: 8

			TextButton {
				text: root.folders ? "Merge  M" : "Replace  R"
				icon: root.folders ? "call_merge" : "file_replace_outline"
				variant: "filled"
				onClicked: root.pick(root.folders ? "merge" : "replace")
			}
			TextButton {
				text: "Keep both  K"
				icon: "content_duplicate"
				onClicked: root.pick("keep")
			}
			TextButton {
				text: "Skip  S"
				icon: "debug_step_over"
				onClicked: root.pick("skip")
			}
			TextButton {
				id: renameButton

				text: "Rename…"
				icon: "form_textbox"
				variant: "ghost"
				visible: !root.renaming
				onClicked: {
					root.renaming = true;
					nameField.text = String(root.conflict?.suggestion ?? "");
					Qt.callLater(() => nameField.focusInput());
				}
			}
		}

		StyledText {
			Layout.fillWidth: true
			visible: !root.folders
			text: "What is replaced goes to the trash, so Undo (Ctrl+Z) brings it back."
			tone: Theme.textSubtle
			font.pixelSize: Theme.size.small
			wrapMode: Text.WordWrap
		}
	}
}
