pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.style.theme
import qs.core.services
import qs.style.widgets
import qs.core.views.overlays.launcher

// Todo lists pinned to the desktop (launcher >todo → pin). One transparent
// layer on the primary screen between wallpaper and windows; only the cards
// take input. Cards are dragged by their header, positions persist in
// Todos.pins, and each card follows its file live.
PanelWindow {
	id: root

	// cards currently shown; their rectangles form the input mask
	property var cards: []

	screen: Popups.primaryScreen
	visible: Todos.pins.length > 0
	anchors.top: true
	anchors.bottom: true
	anchors.left: true
	anchors.right: true
	exclusionMode: ExclusionMode.Ignore
	color: "transparent"
	WlrLayershell.namespace: "shell-todo"
	WlrLayershell.layer: WlrLayer.Bottom
	WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
	mask: Region {
		regions: root.cards.map(card => card.region)
	}

	Repeater {
		model: Todos.pins.map(pin => pin.path)

		onItemAdded: (index, item) => root.cards = root.cards.concat([item])
		onItemRemoved: (index, item) => root.cards = root.cards.filter(card => card !== item)

		delegate: Item {
			id: card

			required property string modelData
			readonly property var pin: Todos.pins.find(entry => entry.path === card.modelData) ?? { x: 80, y: 90 }
			readonly property real pinX: Math.max(0, Math.min(root.width - card.width, card.pin.x))
			readonly property real pinY: Math.max(0, Math.min(root.height - card.height, card.pin.y))
			readonly property Region region: Region {
				x: card.x
				y: card.y
				width: card.width
				height: card.height
				radius: Theme.radius.huge
			}

			x: card.pinX
			y: card.pinY
			width: 310
			height: column.implicitHeight + 24

			HoverHandler {
				id: cardHover
			}

			RectangularShadow {
				anchors.fill: surface
				radius: surface.radius
				blur: 26
				spread: -4
				offset.y: 8
				color: Qt.alpha(Theme.shadow, 0.35)
			}

			Rectangle {
				id: surface

				anchors.fill: parent
				radius: Theme.radius.huge
				color: Qt.alpha(Theme.base, 0.9)
			}

			ColumnLayout {
				id: column

				x: 12
				y: 12
				width: card.width - 24
				spacing: 8

				Item {
					Layout.fillWidth: true
					implicitHeight: 34

					MouseArea {
						id: dragArea

						anchors.fill: parent
						cursorShape: dragArea.drag.active ? Qt.ClosedHandCursor : Qt.OpenHandCursor
						drag.target: card
						drag.minimumX: 0
						drag.minimumY: 0
						drag.maximumX: root.width - card.width
						drag.maximumY: root.height - card.height
						drag.threshold: 2
						onReleased: {
							if (card.x === card.pinX && card.y === card.pinY) return;
							Todos.movePin(card.modelData, card.x, card.y);
							card.x = Qt.binding(() => card.pinX);
							card.y = Qt.binding(() => card.pinY);
						}
					}

					RowLayout {
						anchors.fill: parent
						anchors.leftMargin: 6
						spacing: 8

						Glyph {
							icon: "format_list_checks"
							size: 18
							color: Theme.primary
						}

						StyledText {
							Layout.fillWidth: true
							text: Todos.displayName(card.modelData)
							font.pixelSize: Theme.size.title
							font.weight: Font.Bold
						}

						StyledText {
							visible: doc.progress.total > 0
							text: `${doc.progress.done}/${doc.progress.total}`
							tone: doc.progress.done === doc.progress.total ? Theme.primary : Theme.textSubtle
							tabular: true
							font.pixelSize: Theme.size.label
							font.weight: Font.DemiBold
						}

						IconButton {
							Layout.preferredWidth: 28
							Layout.preferredHeight: 28
							icon: "pin_off"
							iconSize: 15
							opacity: cardHover.hovered ? 1 : 0.4
							onClicked: Todos.unpin(card.modelData)
						}
					}
				}

				Rectangle {
					Layout.fillWidth: true
					Layout.leftMargin: 6
					Layout.rightMargin: 6
					visible: doc.progress.total > 0
					implicitHeight: 3
					radius: 1.5
					color: Theme.layer3

					Rectangle {
						height: parent.height
						radius: parent.radius
						width: parent.width * (doc.progress.total > 0 ? doc.progress.done / doc.progress.total : 0)
						color: Theme.primary

						Behavior on width {
							SpatialAnim {
								duration: Motion.medium
							}
						}
					}
				}

				Flickable {
					Layout.fillWidth: true
					Layout.preferredHeight: Math.min(doc.implicitHeight, 520)
					visible: !doc.empty
					contentHeight: doc.implicitHeight
					clip: true
					boundsBehavior: Flickable.StopAtBounds
					interactive: contentHeight > height

					TodoDocument {
						id: doc

						width: parent.width
						path: card.modelData
						compact: true
					}
				}
			}
		}
	}
}
