pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.style.theme
import qs.core.services
import qs.style.widgets

// Pinned markdown notes. A slim list on the left switches notes; the right
// side reads rendered markdown or edits the source. Ctrl+S saves.
Drawer {
	id: root

	property string noteId: ""
	property bool editing: false
	property string draftTitle: ""
	property string draftBody: ""
	readonly property var note: Notes.find(root.noteId)
	readonly property bool creating: root.noteId === ""

	panelId: "notes"
	panelWidth: 680
	contentHeight: 470

	function open(id) {
		root.noteId = String(id || "");
		const note = Notes.find(root.noteId);
		if (!note) {
			root.noteId = "";
			root.draftTitle = "";
			root.draftBody = "";
			root.editing = true;
			titleField.text = "";
			body.text = "";
			Qt.callLater(() => titleField.focusInput());
			return;
		}
		root.draftTitle = note.title;
		root.draftBody = note.body;
		root.editing = false;
	}

	function edit() {
		root.draftTitle = root.note?.title ?? "";
		root.draftBody = root.note?.body ?? "";
		titleField.text = root.draftTitle;
		body.text = root.draftBody;
		root.editing = true;
		Qt.callLater(() => body.focusInput());
	}

	function save() {
		if (root.draftBody.trim() === "") return;
		const id = Notes.upsert(root.noteId, root.draftTitle, root.draftBody);
		root.noteId = id;
		root.editing = false;
		Popups.page = id;
	}

	function cancel() {
		if (root.creating) {
			if (Notes.notes.length > 0) root.open(Notes.notes[0].id);
			else Popups.close();
			return;
		}
		root.open(root.noteId);
	}

	onPanelOpened: root.open(Popups.page === "create" ? "" : Popups.page)

	Connections {
		target: Popups
		function onPageChanged() {
			if (root.shown && Popups.current === "notes" && Popups.page !== root.noteId)
				root.open(Popups.page === "create" ? "" : Popups.page);
		}
	}

	Shortcut {
		sequence: "Ctrl+S"
		enabled: root.shown && root.editing
		onActivated: root.save()
	}

	RowLayout {
		anchors.fill: parent
		spacing: 16

		// list
		ColumnLayout {
			Layout.preferredWidth: 180
			Layout.fillHeight: true
			spacing: 8

			TextButton {
				Layout.fillWidth: true
				text: "New note"
				icon: "note_plus"
				variant: root.creating && root.editing ? "filled" : "tonal"
				onActivated: {
					Popups.page = "create";
					root.open("");
				}
			}

			ListView {
				Layout.fillWidth: true
				Layout.fillHeight: true
				clip: true
				spacing: 2
				model: Notes.notes
				boundsBehavior: Flickable.StopAtBounds
				ScrollBar.vertical: ThinScrollBar {}

				delegate: Clickable {
					id: item

					required property var modelData
					readonly property bool current: String(item.modelData.id) === root.noteId

					width: ListView.view.width
					implicitHeight: 48
					radius: Theme.radius.medium
					pressedScale: 0.97
					color: item.current ? Theme.primaryContainer : (item.hovered ? Theme.layer1 : "transparent")
					showHover: false
					onClicked: {
						Popups.page = String(item.modelData.id);
						root.open(item.modelData.id);
					}

					Rectangle {
						x: 6
						anchors.verticalCenter: parent.verticalCenter
						width: 3
						height: item.current ? 26 : 14
						radius: 1.5
						color: Theme.primary

						Behavior on height {
							SpatialAnim {
								duration: Motion.medium
							}
						}
					}

					ColumnLayout {
						x: 16
						width: parent.width - 24
						anchors.verticalCenter: parent.verticalCenter
						spacing: 0

						StyledText {
							Layout.fillWidth: true
							text: Notes.titleOf(item.modelData)
							font.pixelSize: Theme.size.label
							font.weight: Font.DemiBold
						}

						StyledText {
							Layout.fillWidth: true
							text: String(item.modelData.body || "").replace(/[#*`>\-\n]+/g, " ").trim()
							color: Theme.textSubtle
							font.pixelSize: Theme.size.tiny
						}
					}
				}
			}
		}

		// reader / editor
		ColumnLayout {
			Layout.fillWidth: true
			Layout.fillHeight: true
			spacing: 10

			RowLayout {
				Layout.fillWidth: true
				spacing: 6

				Field {
					id: titleField

					Layout.fillWidth: true
					visible: root.editing
					icon: "pencil"
					placeholder: "Title"
					text: root.draftTitle
					fontSize: Theme.size.title
					onEdited: text => root.draftTitle = text
					onAccepted: body.focusInput()
				}

				StyledText {
					Layout.fillWidth: true
					visible: !root.editing
					text: Notes.titleOf(root.note)
					font.pixelSize: Theme.size.heading
					font.weight: Font.Bold
				}

				IconButton {
					visible: !root.editing && !!root.note
					icon: "pencil"
					variant: "tonal"
					onClicked: root.edit()
				}

				TextButton {
					visible: !root.editing && !!root.note
					text: ""
					icon: "delete_outline"
					variant: "danger"
					confirm: true
					confirmText: "Delete note"
					onActivated: {
						Notes.remove(root.noteId);
						if (Notes.notes.length > 0) root.open(Notes.notes[0].id);
						else Popups.close();
					}
				}
			}

			AreaField {
				id: body

				Layout.fillWidth: true
				Layout.fillHeight: true
				visible: root.editing
				monospace: true
				placeholder: "Write markdown…\n\n# Heading\n- list item\n**bold** and `code`"
				text: root.draftBody
				onEdited: text => root.draftBody = text
			}

			Rectangle {
				Layout.fillWidth: true
				Layout.fillHeight: true
				visible: !root.editing
				radius: Theme.radius.large
				color: Theme.layer1

				Flickable {
					anchors.fill: parent
					anchors.margins: 16
					clip: true
					contentWidth: width
					contentHeight: rendered.implicitHeight
					boundsBehavior: Flickable.StopAtBounds
					ScrollBar.vertical: ThinScrollBar {}

					Text {
						id: rendered

						width: parent.width
						color: Theme.text
						linkColor: Theme.primary
						font.family: Theme.fontFamily
						font.pixelSize: Theme.size.body
						wrapMode: Text.Wrap
						textFormat: Text.MarkdownText
						text: Notes.markdown(root.note?.body ?? "")
						onLinkActivated: link => Qt.openUrlExternally(link)

						HoverHandler {
							cursorShape: rendered.hoveredLink !== "" ? Qt.PointingHandCursor : Qt.ArrowCursor
						}
					}
				}
			}

			RowLayout {
				Layout.fillWidth: true
				visible: root.editing
				spacing: 8

				StyledText {
					Layout.fillWidth: true
					text: "Markdown · Ctrl+S to save"
					color: Theme.textSubtle
					font.pixelSize: Theme.size.small
				}

				TextButton {
					text: "Cancel"
					variant: "ghost"
					onActivated: root.cancel()
				}

				TextButton {
					text: root.creating ? "Create & pin" : "Save"
					icon: root.creating ? "pin" : "check"
					variant: "filled"
					enabled: root.draftBody.trim() !== ""
					onActivated: root.save()
				}
			}
		}
	}
}
