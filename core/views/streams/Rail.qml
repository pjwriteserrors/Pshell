pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services
import qs.core.views

// A row of cards with a heading, running past the edge of the window. Arrows
// come up at its ends while the pointer is on it; cards grow out of it on hover,
// new ones spring in, the others make way.
ColumnLayout {
	id: root

	property string title: ""
	property string note: ""
	// [{ key }]
	property var keys: []
	property Component card: null
	property real cardWidth: 340
	property real cardHeight: 240
	property real margin: 44

	spacing: 0
	visible: rows.count > 0

	onKeysChanged: rows.sync(root.keys)
	Component.onCompleted: rows.sync(root.keys)

	SyncedModel {
		id: rows
	}

	RowLayout {
		Layout.leftMargin: root.margin
		Layout.rightMargin: root.margin
		spacing: 10

		StyledText {
			text: root.title
			font.pixelSize: Theme.size.heading + 2
			font.weight: Font.Bold
		}
		StyledText {
			Layout.alignment: Qt.AlignBaseline
			visible: root.note !== ""
			text: root.note
			font.pixelSize: Theme.size.label
			tone: Theme.textMuted
		}
	}

	Item {
		id: strip

		Layout.fillWidth: true
		Layout.preferredHeight: root.cardHeight + 34

		HoverHandler {
			id: stripHover
		}

		ListView {
			id: list

			anchors.fill: parent
			orientation: ListView.Horizontal
			spacing: 14
			leftMargin: root.margin
			rightMargin: root.margin
			model: rows
			clip: true
			boundsBehavior: Flickable.StopAtBounds
			cacheBuffer: 800

			add: Transition {
				ParallelAnimation {
					SpatialAnim {
						property: "scale"
						from: 0.8
						to: 1
						duration: Motion.extraLong
					}
					Anim {
						property: "opacity"
						from: 0
						to: 1
						duration: Motion.long
					}
				}
			}
			remove: Transition {
				ParallelAnimation {
					Anim {
						property: "opacity"
						to: 0
						duration: Motion.long
					}
					Anim {
						property: "scale"
						to: 0.85
						duration: Motion.long
					}
				}
			}
			displaced: Transition {
				SpatialAnim {
					property: "x"
					duration: Motion.long
				}
			}
			move: Transition {
				SpatialAnim {
					property: "x"
					duration: Motion.long
				}
			}

			delegate: Item {
				id: holder

				required property string key
				required property int index

				width: root.cardWidth
				height: list.height
				z: loader.item?.lifted ? 10 : 0

				Loader {
					id: loader

					anchors.fill: parent
					anchors.topMargin: 17
					anchors.bottomMargin: 17
					sourceComponent: root.card
					onLoaded: item.cardKey = Qt.binding(() => holder.key)
				}
			}
		}

		NumberAnimation {
			id: glide

			target: list
			property: "contentX"
			duration: Motion.extraLong + 120
			easing.type: Easing.BezierSpline
			easing.bezierCurve: Motion.emphasized
		}

		function step(direction) {
			const low = -list.leftMargin;
			const high = Math.max(low, list.contentWidth - list.width + list.rightMargin);
			const by = Math.max(root.cardWidth + 14, Math.floor(list.width / (root.cardWidth + 14)) * (root.cardWidth + 14));
			glide.to = Math.max(low, Math.min(high, list.contentX + direction * by));
			glide.restart();
		}

		component Arrow: Rectangle {
			id: arrow

			required property int direction
			property bool can: true

			anchors.top: parent.top
			anchors.bottom: parent.bottom
			anchors.topMargin: 17
			anchors.bottomMargin: 50
			width: 54
			opacity: stripHover.hovered && arrow.can ? 1 : 0
			visible: opacity > 0
			gradient: Gradient {
				orientation: Gradient.Horizontal
				GradientStop {
					position: arrow.direction < 0 ? 0 : 1
					color: Qt.alpha(Theme.base, 0.92)
				}
				GradientStop {
					position: arrow.direction < 0 ? 1 : 0
					color: Qt.alpha(Theme.base, 0)
				}
			}

			Behavior on opacity {
				Anim {}
			}

			Glyph {
				anchors.centerIn: parent
				icon: arrow.direction < 0 ? "chevron_left" : "chevron_right"
				size: arrowArea.containsMouse ? 42 : 34
				color: Theme.text

				Behavior on size {
					SpatialAnim {
						duration: Motion.medium
					}
				}
			}

			MouseArea {
				id: arrowArea

				anchors.fill: parent
				hoverEnabled: true
				onClicked: strip.step(arrow.direction)
			}
		}

		Arrow {
			anchors.left: parent.left
			direction: -1
			can: list.contentX > -list.leftMargin + 2
		}
		Arrow {
			anchors.right: parent.right
			direction: 1
			can: list.contentX + list.width < list.contentWidth + list.rightMargin - 2 + list.leftMargin - list.leftMargin
		}
	}
}
