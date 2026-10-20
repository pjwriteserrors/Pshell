pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.style.theme
import qs.core.services
import qs.style.widgets

// The assistant, beside the chat and unlike it: its own ground and colour,
// no faces, no mail. Here the user says what was done and how the mail
// should read; what the local model writes of it is a sheet that is taken
// into the field the mail is written in, to be worked on there. Nothing said
// here is ever sent to anyone.
Rectangle {
	id: root

	// the chat it helps with
	property string chat: ""
	readonly property var said: MailAssist.said(root.chat)
	readonly property bool busy: MailAssist.writing === root.chat && root.chat !== ""
	readonly property color accent: Theme.tertiary

	// notes for the model
	signal ask(string text)
	// a draft is taken
	signal use(string text)
	signal done

	function focusInput() {
		notes.focusInput();
	}

	onVisibleChanged: if (root.visible) MailAssist.look()

	function submit() {
		if (root.busy || notes.text.trim() === "") return;
		root.ask(notes.text);
		notes.text = "";
	}

	radius: Theme.radius.large
	color: Qt.tint(Theme.bg, Qt.alpha(root.accent, 0.08))
	border.width: 1
	border.color: Qt.alpha(root.accent, 0.45)

	// nothing below is reached through it
	MouseArea {
		anchors.fill: parent
		acceptedButtons: Qt.AllButtons
		onWheel: wheel => wheel.accepted = true
	}

	ColumnLayout {
		anchors.fill: parent
		anchors.margins: 12
		spacing: 10

		RowLayout {
			Layout.fillWidth: true
			spacing: 8

			Glyph {
				icon: "creation"
				size: 18
				color: root.accent
			}

			StyledText {
				Layout.fillWidth: true
				text: "Assistant"
				tone: root.accent
				font.pixelSize: Theme.size.title
				font.weight: Font.Bold
			}

			IconButton {
				visible: root.said.length > 0
				icon: "delete_outline"
				onClicked: MailAssist.forget(root.chat)
			}

			IconButton {
				icon: "close"
				onClicked: root.done()
			}
		}

		ListView {
			id: list

			Layout.fillWidth: true
			Layout.fillHeight: true
			clip: true
			spacing: 8
			boundsBehavior: Flickable.StopAtBounds
			ScrollBar.vertical: ThinScrollBar {}
			model: root.said
			onCountChanged: Qt.callLater(list.positionViewAtEnd)
			onContentHeightChanged: Qt.callLater(list.positionViewAtEnd)

			delegate: Item {
				id: entry

				required property var modelData
				readonly property bool draft: entry.modelData.role === "assistant"

				ListView.onAdd: appear.restart()

				Anim {
					id: appear

					target: entry
					property: "opacity"
					from: 0
					to: 1
				}

				width: list.width - 10
				height: entry.draft ? sheet.height : note.height

				// what the user said
				Rectangle {
					id: note

					visible: !entry.draft
					anchors.right: parent.right
					width: Math.min(parent.width * 0.88, noteText.implicitWidth + 24)
					height: noteText.height + 16
					radius: Theme.radius.large
					color: Theme.layer3

					StyledText {
						id: noteText

						x: 12
						y: 8
						width: Math.min(implicitWidth, entry.width * 0.88 - 24)
						text: entry.draft ? "" : entry.modelData.text
						wrapMode: Text.Wrap
						font.pixelSize: Theme.size.body
					}
				}

				// what the model wrote: a mail that is not one yet
				Rectangle {
					id: sheet

					visible: entry.draft
					width: parent.width
					height: sheetColumn.implicitHeight + 24
					radius: Theme.radius.medium
					color: Theme.layer1
					border.width: 1
					border.color: Qt.alpha(root.accent, 0.5)

					Column {
						id: sheetColumn

						x: 12
						y: 12
						width: parent.width - 24
						spacing: 10

						TextEdit {
							width: parent.width
							readOnly: true
							selectByMouse: true
							textFormat: TextEdit.PlainText
							wrapMode: TextEdit.Wrap
							color: Theme.text
							selectionColor: Qt.alpha(root.accent, 0.4)
							selectedTextColor: Theme.text
							font.family: Theme.fontFamily
							font.pixelSize: Theme.size.body
							text: entry.draft ? entry.modelData.text : ""
						}

						TextButton {
							anchors.right: parent.right
							text: "Use"
							icon: "arrow_left"
							variant: "filled"
							onActivated: root.use(entry.modelData.text)
						}
					}
				}
			}

			footer: Item {
				width: list.width
				height: root.busy ? 34 : 0
				visible: root.busy

				Spinner {
					x: 12
					anchors.verticalCenter: parent.verticalCenter
					width: 18
					height: 18
					color: root.accent
				}
			}

			EmptyState {
				anchors.centerIn: parent
				visible: root.said.length === 0 && !root.busy
				icon: "creation"
				title: "Runs on this computer"
			}
		}

		// which model writes: the smallest answers soonest, the largest writes best
		RowLayout {
			Layout.fillWidth: true
			visible: MailAssist.models.length > 1
			spacing: 8

			StyledText {
				text: "Fast"
				tone: Theme.textSubtle
				font.pixelSize: Theme.size.small
			}

			PillSlider {
				Layout.fillWidth: true
				implicitHeight: 34
				accent: root.accent
				stepSize: 1 / Math.max(1, MailAssist.models.length - 1)
				value: MailAssist.level / Math.max(1, MailAssist.models.length - 1)
				valueText: MailAssist.model.replace(/:latest$/, "")
				dimmed: root.busy
				onMoved: value => {
					if (!root.busy) MailAssist.pick(Math.round(value * (MailAssist.models.length - 1)));
				}
			}

			StyledText {
				text: "Good"
				tone: Theme.textSubtle
				font.pixelSize: Theme.size.small
			}
		}

		StyledText {
			Layout.fillWidth: true
			visible: MailAssist.error !== ""
			text: MailAssist.error
			tone: Theme.danger
			wrapMode: Text.Wrap
			font.pixelSize: Theme.size.small
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 6

			AreaField {
				id: notes

				Layout.fillWidth: true
				Layout.preferredHeight: Math.max(40, Math.min(160, notes.area.contentHeight + 28))
				placeholder: root.said.length === 0 ? "What was done, how should the mail read?" : "What should change?"
				autocorrect: true
				border.color: Qt.alpha(root.accent, 0.85)
			}

			IconButton {
				Layout.alignment: Qt.AlignBottom
				implicitWidth: 40
				implicitHeight: 40
				icon: root.busy ? "close" : "creation"
				variant: "tonal"
				iconColor: root.accent
				enabled: root.busy || notes.text.trim() !== ""
				onClicked: root.busy ? MailAssist.stop() : root.submit()
			}
		}
	}

	Shortcut {
		sequences: ["Ctrl+Return", "Ctrl+Enter"]
		enabled: notes.focused
		onActivated: root.submit()
	}
}
