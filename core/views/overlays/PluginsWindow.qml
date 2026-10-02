pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.style.theme
import qs.core.services
import qs.style.widgets

// >plugins: everything the shell can do, each with a preview and a switch
// (core/services/Plugins.qml). Typing filters, ↑↓ and Tab move, Enter
// switches the selected plugin.
ModalWindow {
	id: root

	modalId: "plugins"
	exclusiveKeyboard: true
	onModalOpened: {
		search.text = "";
		root.category = "";
		grid.currentIndex = 0;
		search.focusInput();
	}

	// "" shows every category
	property string category: ""
	readonly property string query: search.text.trim().toLowerCase()
	readonly property var matches: Plugins.list.filter(plugin => (root.category === "" || plugin.category === root.category)
		&& (root.query === "" || `${plugin.name} ${plugin.id} ${plugin.category}`.toLowerCase().includes(root.query)))
	readonly property int onCount: Plugins.list.filter(plugin => Plugins.on(plugin.id)).length

	onMatchesChanged: grid.currentIndex = Math.max(0, Math.min(grid.currentIndex, root.matches.length - 1))

	function move(delta) {
		if (root.matches.length === 0) return;
		grid.currentIndex = Math.max(0, Math.min(root.matches.length - 1, grid.currentIndex + delta));
	}

	function switchCurrent() {
		const plugin = root.matches[grid.currentIndex];
		if (plugin) Plugins.toggle(plugin.id);
	}

	Rectangle {
		anchors.centerIn: parent
		width: Math.min(1240, root.width - 120)
		height: Math.min(900, root.height - 120)
		radius: Theme.radius.huge + 6
		color: Theme.base

		MouseArea {
			anchors.fill: parent
			acceptedButtons: Qt.AllButtons
		}

		ColumnLayout {
			anchors.fill: parent
			anchors.margins: 22
			spacing: 16

			RowLayout {
				Layout.fillWidth: true
				spacing: 14

				Rectangle {
					Layout.preferredWidth: 46
					Layout.preferredHeight: 46
					radius: Theme.radius.large
					color: Theme.primaryContainer

					Glyph {
						anchors.centerIn: parent
						icon: "puzzle"
						size: 22
						color: Theme.primary
					}
				}

				ColumnLayout {
					spacing: 0

					SectionLabel {
						text: `${root.onCount} / ${Plugins.list.length}`
					}

					StyledText {
						text: Words.of("plugins.title", "Plugins")
						font.pixelSize: Theme.size.heading
						font.weight: Font.Bold
					}
				}

				Item {
					Layout.fillWidth: true
				}

				Field {
					id: search

					Layout.preferredWidth: 300
					icon: "magnify"
					placeholder: "Search"
					onEscapePressed: Popups.closeModal()
					onUpPressed: root.move(-grid.columns)
					onDownPressed: root.move(grid.columns)
					onTabPressed: root.move(1)
					onAccepted: root.switchCurrent()
				}
			}

			Segmented {
				Layout.fillWidth: true
				Layout.preferredHeight: 38
				current: root.category
				options: [{ value: "", label: "All" }].concat(Plugins.categories.map(name => ({ value: name, label: name })))
				onSelected: value => root.category = value
			}

			GridView {
				id: grid

				readonly property int columns: Math.max(1, Math.floor(width / 290))

				Layout.fillWidth: true
				Layout.fillHeight: true
				clip: true
				cellWidth: width / columns
				cellHeight: 250
				model: root.matches
				boundsBehavior: Flickable.StopAtBounds
				ScrollBar.vertical: ThinScrollBar {}

				delegate: Item {
					id: cell

					required property var modelData
					required property int index
					readonly property bool on: Plugins.on(cell.modelData.id)
					readonly property var missing: Plugins.missing(cell.modelData.id)
					readonly property bool selected: GridView.isCurrentItem

					width: grid.cellWidth
					height: grid.cellHeight

					Clickable {
						anchors.fill: parent
						anchors.margins: 6
						radius: Theme.radius.large
						color: cell.selected ? Theme.layer2 : Theme.layer1
						pressedScale: 0.98
						onClicked: {
							grid.currentIndex = cell.index;
							Plugins.toggle(cell.modelData.id);
						}

						Rectangle {
							id: frame

							anchors.left: parent.left
							anchors.right: parent.right
							anchors.top: parent.top
							anchors.margins: 8
							height: 174
							radius: Theme.radius.medium
							color: Theme.layer3
							clip: true

							Image {
								id: preview

								anchors.fill: parent
								anchors.margins: 6
								source: Plugins.preview(cell.modelData.id)
								// small things of the bar are not blown up
								property bool small: false

								fillMode: small ? Image.Pad : Image.PreserveAspectFit
								onStatusChanged: if (status === Image.Ready) small = implicitWidth < width && implicitHeight < height
								asynchronous: true
								smooth: true
								mipmap: true
								opacity: cell.on ? 1 : 0.35

								Behavior on opacity {
									Anim {}
								}
							}

							Glyph {
								anchors.centerIn: parent
								visible: preview.status !== Image.Ready
								icon: cell.modelData.icon || "puzzle"
								size: 40
								color: cell.on ? Theme.textSubtle : Theme.textFaint
							}
						}

						RowLayout {
							anchors.left: parent.left
							anchors.right: parent.right
							anchors.top: frame.bottom
							anchors.bottom: parent.bottom
							anchors.leftMargin: 14
							anchors.rightMargin: 12
							spacing: 8

							ColumnLayout {
								Layout.fillWidth: true
								spacing: 0

								StyledText {
									Layout.fillWidth: true
									text: cell.modelData.name
									tone: cell.on ? Theme.text : Theme.textMuted
									font.weight: Font.DemiBold
									elide: Text.ElideRight
								}

								StyledText {
									Layout.fillWidth: true
									visible: cell.missing.length > 0
									text: `Needs ${cell.missing.join(", ")}`
									tone: Theme.warning
									font.pixelSize: Theme.size.small
									elide: Text.ElideRight
								}
							}

							Toggle {
								checked: Plugins.wanted(cell.modelData.id)
								opacity: cell.missing.length > 0 ? 0.5 : 1
								onToggled: {
									grid.currentIndex = cell.index;
									Plugins.toggle(cell.modelData.id);
								}
							}
						}
					}
				}
			}
		}
	}
}
