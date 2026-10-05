pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Widgets
import qs.style.theme
import qs.core.services
import qs.style.widgets

// Clipboard history. Type to filter, arrows to move, Enter to copy back,
// Delete to drop an entry. Images show as thumbnails. With the phone
// reachable over KDE Connect every entry can be sent to it.
Drawer {
	id: root

	property string query: ""
	property int selected: 0
	readonly property var filtered: {
		const q = root.query.trim().toLowerCase();
		if (q === "") return Clipboard.entries;
		return Clipboard.entries.filter(entry => String(entry.preview || "").toLowerCase().includes(q));
	}

	panelId: "clipboard"
	panelWidth: 460
	contentHeight: 540

	function move(delta) {
		if (root.filtered.length === 0) return;
		root.selected = Math.max(0, Math.min(root.filtered.length - 1, root.selected + delta));
		list.positionViewAtIndex(root.selected, ListView.Contain);
	}

	function activate(entry) {
		if (!entry) return;
		Clipboard.restore(entry);
		Popups.close();
	}

	onPanelOpened: {
		root.query = "";
		search.text = "";
		root.selected = 0;
		Clipboard.refresh();
		Qt.callLater(() => search.focusInput());
	}
	onFilteredChanged: root.selected = Math.max(0, Math.min(root.selected, root.filtered.length - 1))

	ColumnLayout {
		anchors.fill: parent
		spacing: 12

		RowLayout {
			Layout.fillWidth: true
			spacing: 8

			StyledText {
				text: Words.of("clipboard.title", "Clipboard")
				font.pixelSize: Theme.size.heading
				font.weight: Font.Bold
			}

			StyledText {
				text: Clipboard.entries.length
				tone: Theme.textSubtle
				font.pixelSize: Theme.size.heading
				font.weight: Font.Bold
				tabular: true
			}

			Item {
				Layout.fillWidth: true
			}

			TextButton {
				visible: Clipboard.entries.length > 0
				text: "Clear all"
				icon: "broom"
				variant: "ghost"
				confirm: true
				confirmText: "Clear everything?"
				onActivated: Clipboard.wipe()
			}
		}

		Field {
			id: search

			Layout.fillWidth: true
			icon: "magnify"
			placeholder: "Search clipboard"
			onEdited: text => {
				root.query = text;
				root.selected = 0;
			}
			onDownPressed: root.move(1)
			onUpPressed: root.move(-1)
			onAccepted: root.activate(root.filtered[root.selected])
			onDeletePressed: Clipboard.remove(root.filtered[root.selected])
		}

		Item {
			Layout.fillWidth: true
			Layout.fillHeight: true

			EmptyState {
				anchors.centerIn: parent
				visible: root.filtered.length === 0 && !Clipboard.loading
				icon: root.query !== "" ? "magnify" : "clipboard_outline"
				title: root.query !== "" ? "No matches" : "Clipboard is empty"
				subtitle: root.query !== "" ? "" : "Copied text and images will collect here."
			}

			ListView {
				id: list

				anchors.fill: parent
				clip: true
				spacing: 4
				model: root.filtered
				currentIndex: root.selected
				boundsBehavior: Flickable.StopAtBounds
				highlightFollowsCurrentItem: false
				ScrollBar.vertical: ThinScrollBar {}

				displaced: Transition {
					SpatialAnim {
						property: "y"
						duration: Motion.medium
					}
				}
				remove: Transition {
					ParallelAnimation {
						Anim {
							property: "opacity"
							to: 0
							duration: Motion.short
						}
						Anim {
							property: "x"
							to: 60
							duration: Motion.short
						}
					}
				}

				delegate: Clickable {
					id: entry

					required property var modelData
					required property int index
					readonly property bool current: entry.index === root.selected

					width: ListView.view.width
					implicitHeight: entry.modelData.isImage ? 92 : Math.min(72, textPreview.implicitHeight + 24)
					radius: Theme.radius.medium
					pressedScale: 0.98
					color: entry.current ? Theme.primaryContainer : (entry.hovered ? Theme.layer1 : "transparent")
					showHover: false
					onPointed: root.selected = entry.index
					onClicked: root.activate(entry.modelData)

					Rectangle {
						x: 0
						anchors.verticalCenter: parent.verticalCenter
						width: 3
						height: entry.current ? parent.height - 22 : 0
						radius: 1.5
						color: Theme.primary

						Behavior on height {
							SpatialAnim {
								duration: Motion.medium
							}
						}
					}

					RowLayout {
						anchors.fill: parent
						anchors.leftMargin: 14
						anchors.rightMargin: 8
						spacing: 12

						ClippingRectangle {
							visible: entry.modelData.isImage
							Layout.preferredWidth: 104
							Layout.preferredHeight: 72
							radius: Theme.radius.medium
							color: Theme.layer2

							Image {
								id: thumb

								anchors.fill: parent
								fillMode: Image.PreserveAspectCrop
								asynchronous: true
								cache: false
								smooth: true
								mipmap: true
							}

							Process {
								running: entry.modelData.isImage
								command: Clipboard.decodeCommand(entry.modelData)
								onExited: thumb.source = `file://${entry.modelData.previewPath}?t=${Date.now()}`
							}
						}

						ColumnLayout {
							Layout.fillWidth: true
							spacing: 2

							StyledText {
								id: textPreview

								Layout.fillWidth: true
								visible: !entry.modelData.isImage
								text: String(entry.modelData.preview).trim()
								textFormat: Text.PlainText
								wrapMode: Text.WrapAnywhere
								maximumLineCount: 2
								font.pixelSize: Theme.size.label
							}

							StyledText {
								visible: entry.modelData.isImage
								text: "Image"
								font.weight: Font.DemiBold
							}

							StyledText {
								visible: entry.modelData.isImage
								text: entry.modelData.meta
								tone: Theme.textMuted
								font.pixelSize: Theme.size.small
							}
						}

						IconButton {
							Layout.preferredWidth: 30
							Layout.preferredHeight: 30
							visible: Phone.reachable
							icon: "cellphone_arrow_down"
							iconSize: 16
							opacity: entry.hovered || entry.current ? 1 : 0
							onClicked: Phone.sendClipboardEntry(entry.modelData)

							Behavior on opacity {
								Anim {
									duration: Motion.short
								}
							}
						}

						IconButton {
							Layout.preferredWidth: 30
							Layout.preferredHeight: 30
							icon: "delete_outline"
							iconSize: 16
							variant: "danger"
							opacity: entry.hovered || entry.current ? 1 : 0
							onClicked: Clipboard.remove(entry.modelData)

							Behavior on opacity {
								Anim {
									duration: Motion.short
								}
							}
						}
					}
				}
			}
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 14

			Repeater {
				model: [
					{ key: "↵", label: "copy" },
					{ key: "↑↓", label: "move" },
					{ key: "Del", label: "remove" },
					{ key: "Esc", label: "close" }
				]

				delegate: RowLayout {
					required property var modelData
					spacing: 5

					Rectangle {
						Layout.preferredHeight: 20
						Layout.preferredWidth: Math.max(22, keyLabel.implicitWidth + 10)
						radius: 6
						color: Theme.layer2

						StyledText {
							id: keyLabel
							anchors.centerIn: parent
							text: modelData.key
							font.pixelSize: Theme.size.tiny
							font.weight: Font.Bold
						}
					}

					StyledText {
						text: modelData.label
						tone: Theme.textSubtle
						font.pixelSize: Theme.size.small
					}
				}
			}
		}
	}
}
