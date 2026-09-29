pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets

// A small menu of a shelf: [{ label, icon, run, danger, checked }] or
// { separator: true }. An entry with `checked` (a function, so the toggle
// follows the setting while the menu is open) shows a toggle and keeps the
// menu open.
Rectangle {
	id: root

	property var entries: []
	signal done

	implicitWidth: 230
	implicitHeight: column.implicitHeight + 12
	radius: Theme.radius.large
	color: Theme.layer1
	border.width: 1
	border.color: Theme.outline
	opacity: visible ? 1 : 0
	scale: visible ? 1 : 0.94
	transformOrigin: Item.TopLeft

	Behavior on opacity {
		Anim {
			duration: Motion.short
		}
	}

	Behavior on scale {
		SpatialAnim {
			duration: Motion.medium
		}
	}

	ColumnLayout {
		id: column

		anchors.fill: parent
		anchors.margins: 6
		spacing: 0

		Repeater {
			model: root.entries

			delegate: Loader {
				id: entry

				required property var modelData

				Layout.fillWidth: true
				sourceComponent: entry.modelData.separator ? separator : row

				Component {
					id: separator

					Rectangle {
						implicitHeight: 9
						color: "transparent"

						Rectangle {
							anchors.centerIn: parent
							width: parent.width - 12
							height: 1
							color: Theme.outline
						}
					}
				}

				Component {
					id: row

					Clickable {
						implicitHeight: 34
						radius: Theme.radius.small
						pressedScale: 0.98
						onClicked: {
							entry.modelData.run();
							if (entry.modelData.checked === undefined) root.done();
						}

						RowLayout {
							anchors.fill: parent
							anchors.leftMargin: 8
							anchors.rightMargin: 6
							spacing: 10

							Glyph {
								icon: entry.modelData.icon ?? ""
								size: 16
								color: entry.modelData.danger ? Theme.danger : Theme.textMuted
							}

							StyledText {
								Layout.fillWidth: true
								text: entry.modelData.label
								tone: entry.modelData.danger ? Theme.danger : Theme.text
								elide: Text.ElideRight
								font.pixelSize: Theme.size.body
							}

							Toggle {
								visible: entry.modelData.checked !== undefined
								checked: typeof entry.modelData.checked === "function" ? entry.modelData.checked() : !!entry.modelData.checked
								scale: 0.8
								onToggled: entry.modelData.run()
							}
						}
					}
				}
			}
		}
	}
}
