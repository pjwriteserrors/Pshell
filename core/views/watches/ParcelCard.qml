pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// A parcel as a card: carrier and name, the stages as a track (announced →
// handed over → in transit → depot → out for delivery → delivered) with the
// one it is at lit, the carrier's last words and when, the day it is
// expected. A click opens the carrier's page.
Clickable {
	id: root

	required property var parcel
	readonly property int stage: root.parcel.stage === null || root.parcel.stage === undefined ? -1 : Number(root.parcel.stage)
	readonly property bool problem: root.parcel.state === "problem"
	readonly property bool done: root.parcel.state === "delivered"
	readonly property color accent: root.problem ? Theme.danger : (root.done ? Theme.success : Theme.primary)
	readonly property var labels: ["Announced", "Handed over", "In transit", "Depot", root.parcel.state === "pickup" ? "Pickup" : "Out for delivery", "Delivered"]

	implicitHeight: body.implicitHeight + 24
	radius: Theme.radius.large
	color: root.hovered ? Theme.layer2 : Theme.layer1
	pressedScale: 0.985
	onClicked: Watches.open(root.parcel)

	ColumnLayout {
		id: body

		anchors.left: parent.left
		anchors.right: parent.right
		anchors.top: parent.top
		anchors.margins: 12
		anchors.rightMargin: 8
		spacing: 12

		RowLayout {
			Layout.fillWidth: true
			spacing: 10

			Rectangle {
				Layout.preferredWidth: 38
				Layout.preferredHeight: 38
				radius: Theme.radius.medium
				color: Qt.alpha(root.accent, 0.14)

				Glyph {
					anchors.centerIn: parent
					icon: Watches.glyph(root.parcel)
					size: 18
					color: root.accent
				}
			}

			ColumnLayout {
				Layout.fillWidth: true
				spacing: 2

				StyledText {
					Layout.fillWidth: true
					text: `${root.parcel.carrier_name} · ${root.parcel.label || root.parcel.title || root.parcel.number}`
					elide: Text.ElideRight
					font.pixelSize: Theme.size.body
					font.weight: Font.Medium
				}

				StyledText {
					Layout.fillWidth: true
					text: [Watches.stateNames[root.parcel.state] ?? "", Watches.whenOf(root.parcel.last)].filter(s => s).join("  ·  ")
					font.pixelSize: Theme.size.small
					tone: root.problem ? Theme.danger : Theme.textSubtle
					elide: Text.ElideRight
				}
			}

			ColumnLayout {
				visible: !root.done && Watches.dayOf(root.parcel.expected) !== ""
				spacing: 0

				StyledText {
					Layout.alignment: Qt.AlignRight
					text: Watches.dayOf(root.parcel.expected)
					font.pixelSize: Theme.size.body
					font.weight: Font.DemiBold
					tone: root.accent
				}

				Glyph {
					Layout.alignment: Qt.AlignRight
					icon: "calendar_clock"
					size: 13
					color: Theme.textSubtle
				}
			}

			IconButton {
				implicitWidth: 30
				implicitHeight: 30
				icon: "delete_outline"
				onClicked: Watches.remove(root.parcel.id)
			}
		}

		// ── the track ─────────────────────────────────────────────────────
		Item {
			id: track

			Layout.fillWidth: true
			Layout.leftMargin: 4
			Layout.rightMargin: 4
			implicitHeight: 34
			visible: root.parcel.state !== "manual"

			readonly property real step: (track.width - 12) / 5

			Rectangle {
				x: 6
				y: 5
				width: track.width - 12
				height: 2
				radius: 1
				color: Theme.layer3
			}

			Rectangle {
				x: 6
				y: 5
				width: Math.max(0, root.stage) * track.step
				height: 2
				radius: 1
				color: root.accent

				Behavior on width {
					NumberAnimation {
						duration: Motion.long
						easing.type: Easing.OutCubic
					}
				}
			}

			Repeater {
				model: 6

				delegate: Item {
					id: node

					required property int index
					readonly property bool reached: node.index <= root.stage
					readonly property bool current: node.index === root.stage

					x: 6 + node.index * track.step - width / 2
					width: track.step
					height: track.height

					Rectangle {
						anchors.horizontalCenter: parent.horizontalCenter
						y: 6 - height / 2
						width: node.current ? 12 : 8
						height: width
						radius: width / 2
						color: node.reached ? root.accent : Theme.layer3
						border.width: node.current ? 3 : 0
						border.color: Qt.alpha(root.accent, 0.3)

						Behavior on width {
							NumberAnimation {
								duration: Motion.short
							}
						}
					}

					StyledText {
						// the ends keep inside the card
						x: node.index === 0 ? node.width / 2 - 6 : (node.index === 5 ? node.width / 2 + 6 - width : (node.width - width) / 2)
						y: 16
						text: root.labels[node.index]
						font.pixelSize: Theme.size.tiny
						font.weight: node.current ? Font.DemiBold : Font.Normal
						tone: node.current ? (root.problem ? Theme.danger : Theme.text) : (node.reached ? Theme.textMuted : Theme.textSubtle)
					}
				}
			}
		}

		StyledText {
			Layout.fillWidth: true
			visible: text !== ""
			text: root.parcel.text || ""
			font.pixelSize: Theme.size.small
			tone: Theme.textMuted
			wrapMode: Text.Wrap
			maximumLineCount: 2
			elide: Text.ElideRight
		}
	}
}
