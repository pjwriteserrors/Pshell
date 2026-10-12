pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// What can be taken back, newest first: copies, moves, renames, the trash,
// PDFs and pictures made, conversions. Any of them can be undone, not only
// the last one.
DialogFrame {
	id: root

	property var entries: []

	function open() {
		root.entries = [];
		root.show();
		root.refresh();
		keys.forceActiveFocus();
	}

	function refresh() {
		Files.history(list => root.entries = list);
	}

	function iconOf(kind) {
		switch (kind) {
		case "trash": return "trash_can_outline";
		case "copy": case "paste": return "content_copy";
		case "move": case "auto": return "file_move_outline";
		case "rename": case "batchrename": return "form_textbox";
		case "mkdir": return "folder_plus_outline";
		case "newfile": return "file_plus_outline";
		case "extract": return "package_variant";
		case "compress": return "zip_box_outline";
		case "convert": return "swap_horizontal";
		case "pdf": return "file_pdf_box";
		case "image": return "image_edit_outline";
		case "tags": return "tag_outline";
		case "rule": return "playlist_check";
		case "restoreversion": return "history";
		case "download": return "download";
		default: return "undo";
		}
	}

	Connections {
		target: Files

		function onJobFinished(job) {
			if (root.shown) refreshTimer.restart();
		}
	}

	Timer {
		id: refreshTimer

		interval: 200
		onTriggered: root.refresh()
	}

	cardWidth: 480
	onDismissed: root.hide()

	Item {
		id: keys

		focus: root.shown
		Keys.onEscapePressed: root.hide()
	}

	ColumnLayout {
		width: parent.width
		spacing: 12

		RowLayout {
			spacing: 12

			Rectangle {
				width: 40
				height: 40
				radius: 13
				color: Qt.tint(Theme.layer2, Qt.alpha(Theme.primary, 0.2))

				Glyph {
					anchors.centerIn: parent
					icon: "history"
					size: 20
					color: Theme.primary
				}
			}

			ColumnLayout {
				Layout.fillWidth: true
				spacing: 1

				StyledText {
					text: "What can be undone"
					font.pixelSize: Theme.size.title
					font.weight: Font.DemiBold
				}

				StyledText {
					text: "Newest first; any of them can be taken back"
					tone: Theme.textSubtle
					font.pixelSize: Theme.size.small
				}
			}
		}

		StyledText {
			Layout.fillWidth: true
			visible: root.entries.length === 0
			text: "Nothing to undo yet. What you copy, move, rename or throw away shows up here."
			tone: Theme.textMuted
			wrapMode: Text.WordWrap
		}

		Flickable {
			Layout.fillWidth: true
			Layout.preferredHeight: Math.min(list.implicitHeight, Math.max(160, root.height - 240))
			contentHeight: list.implicitHeight
			clip: true
			boundsBehavior: Flickable.StopAtBounds
			visible: root.entries.length > 0

			Column {
				id: list

				width: parent.width
				spacing: 2

				add: Transition {
					NumberAnimation {
						property: "opacity"
						from: 0
						to: 1
						duration: Motion.medium
					}
				}

				Repeater {
					model: root.entries

					delegate: Rectangle {
						id: entry

						required property var modelData
						required property int index

						width: list.width
						height: 50
						radius: Theme.radius.medium
						color: Qt.alpha(Theme.layer2, entryMouse.containsMouse ? 1 : 0)

						Behavior on color {
							ColorAnim {}
						}

						MouseArea {
							id: entryMouse

							anchors.fill: parent
							hoverEnabled: true
							acceptedButtons: Qt.NoButton
						}

						Rectangle {
							x: 8
							anchors.verticalCenter: parent.verticalCenter
							width: 32
							height: 32
							radius: 10
							color: Theme.layer3

							Glyph {
								anchors.centerIn: parent
								icon: root.iconOf(entry.modelData.kind)
								size: 16
								color: Theme.textMuted
							}
						}

						Column {
							x: 50
							anchors.verticalCenter: parent.verticalCenter
							width: parent.width - 50 - undoButton.width - 14

							StyledText {
								width: parent.width
								text: entry.modelData.title
								elide: Text.ElideRight
							}

							StyledText {
								width: parent.width
								text: `${Files.whenText(entry.modelData.at)}${entry.index === 0 ? " · Ctrl+Z" : ""}`
								tone: Theme.textSubtle
								font.pixelSize: Theme.size.small
							}
						}

						TextButton {
							id: undoButton

							anchors.right: parent.right
							anchors.rightMargin: 6
							anchors.verticalCenter: parent.verticalCenter
							height: 30
							text: "Undo"
							icon: "undo"
							variant: entry.index === 0 ? "filled" : "tonal"
							onClicked: {
								Files.undoAt(entry.modelData.at);
								Sounds.play("select");
							}
						}
					}
				}
			}
		}

		TextButton {
			Layout.alignment: Qt.AlignRight
			text: "Close"
			variant: "ghost"
			onClicked: root.hide()
		}
	}
}
