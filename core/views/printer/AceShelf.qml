pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import qs.style.theme
import qs.core.services
import qs.style.widgets

// The ACE from the front: its spools side by side on a shelf, each with its
// material and colour under it. The one that feeds turns and glows, and the
// filament runs from it up to the printer as a flowing line. A spool lifts
// under the pointer.
Item {
	id: root

	readonly property var box: Printer.ace
	// the slot that feeds: as the ACE says, else the one a single-colour print was sent with
	readonly property int feeding: {
		if (!Printer.printing) return -1;
		const loaded = root.box?.loaded ?? -1;
		if (loaded >= 0) return loaded;
		const mapping = Printer.printingJob?.mapping ?? [];
		return mapping.length === 1 ? (Printer.slot(mapping[0].slot)?.index ?? -1) : -1;
	}
	readonly property real cell: root.width / Math.max(1, Printer.slots.length)
	readonly property real spoolSize: Math.min(root.cell * 0.68, root.height * 0.34, 128)
	// the spools and their labels, in the middle of the height
	readonly property real spoolTop: Math.max(56, (root.height - root.spoolSize - 96) / 2 + 24)
	readonly property real shelfY: root.spoolTop + root.spoolSize

	// the filament, from the feeding spool up and out at the top
	Shape {
		anchors.fill: parent
		visible: root.feeding >= 0
		preferredRendererType: Shape.CurveRenderer

		ShapePath {
			id: path

			readonly property real fromX: root.cell * (root.feeding + 0.5)
			readonly property real fromY: root.spoolTop + root.spoolSize * 0.08

			strokeColor: Qt.alpha(Printer.hot, 0.85)
			strokeWidth: 3
			fillColor: "transparent"
			capStyle: ShapePath.RoundCap
			strokeStyle: ShapePath.DashLine
			dashPattern: [3, 2.5]
			startX: path.fromX
			startY: path.fromY

			NumberAnimation on dashOffset {
				running: root.feeding >= 0 && root.visible
				from: 11
				to: 0
				duration: 900
				loops: Animation.Infinite
			}

			PathCubic {
				x: root.width / 2
				y: 0
				control1X: path.fromX
				control1Y: root.height * 0.08
				control2X: root.width / 2
				control2Y: root.height * 0.2
			}
		}
	}

	// where it goes
	Rectangle {
		anchors.horizontalCenter: parent.horizontalCenter
		y: -4
		width: 10
		height: 10
		radius: 5
		visible: root.feeding >= 0
		color: Printer.hot
	}

	// the shelf
	Rectangle {
		x: 8
		y: root.shelfY + 6
		width: root.width - 16
		height: 6
		radius: 3
		color: Qt.alpha(Theme.fg, 0.08)
	}

	Repeater {
		model: Printer.slots

		delegate: Item {
			id: holder

			required property var modelData
			required property int index
			readonly property bool empty: holder.modelData.type === ""
			readonly property bool feeds: root.feeding === holder.modelData.index
			readonly property color colour: holder.empty ? Theme.textFaint : Printer.rgb(holder.modelData.color)

			x: root.cell * holder.index
			width: root.cell
			height: root.height
			opacity: 0

			Component.onCompleted: appear.start()

			SequentialAnimation {
				id: appear

				PauseAnimation {
					duration: holder.index * 80
				}
				ParallelAnimation {
					NumberAnimation {
						target: holder
						property: "opacity"
						to: 1
						duration: 300
					}
					NumberAnimation {
						target: drop
						property: "y"
						from: -30
						to: 0
						duration: 620
						easing.type: Easing.OutBounce
					}
				}
			}

			HoverHandler {
				id: hover
			}

			// the colour's glow behind the spool
			Rectangle {
				anchors.horizontalCenter: parent.horizontalCenter
				y: root.spoolTop - root.spoolSize * 0.15
				width: root.spoolSize * 1.3
				height: width
				radius: width / 2
				visible: !holder.empty
				color: Qt.alpha(holder.colour, holder.feeds ? 0.3 : (hover.hovered ? 0.18 : 0.08))
				scale: holder.feeds ? 1.05 : 1

				Behavior on color {
					ColorAnim {}
				}

				SequentialAnimation on scale {
					running: holder.feeds && root.visible
					loops: Animation.Infinite
					NumberAnimation { to: 1.12; duration: 1100; easing.type: Easing.InOutSine }
					NumberAnimation { to: 0.98; duration: 1100; easing.type: Easing.InOutSine }
				}
			}

			Item {
				id: lift

				width: parent.width
				height: parent.height
				y: hover.hovered ? -6 : 0

				Behavior on y {
					SpatialAnim {}
				}

				Item {
					id: drop

					width: parent.width
					height: parent.height

					Spool {
						anchors.horizontalCenter: parent.horizontalCenter
						y: root.spoolTop
						width: root.spoolSize
						height: root.spoolSize
						slot: holder.modelData
						feeding: holder.feeds
						rotation: hover.hovered && !holder.feeds ? 30 : 0

						Behavior on rotation {
							SpatialAnim {}
						}
					}
				}
			}

			ColumnLayout {
				anchors.horizontalCenter: parent.horizontalCenter
				y: root.shelfY + 22
				width: Math.min(parent.width - 12, 150)
				spacing: 3

				StyledText {
					Layout.fillWidth: true
					horizontalAlignment: Text.AlignHCenter
					text: holder.empty ? "Empty" : holder.modelData.type
					elide: Text.ElideRight
					font.pixelSize: Theme.size.body
					font.weight: Font.DemiBold
					tone: holder.empty ? Theme.textFaint : Theme.text
				}

				StyledText {
					Layout.fillWidth: true
					horizontalAlignment: Text.AlignHCenter
					visible: !holder.empty
					text: "#" + holder.modelData.color.map(v => v.toString(16).padStart(2, "0")).join("").toUpperCase()
					tone: Theme.textMuted
					font.pixelSize: Theme.size.tiny
					font.family: Theme.monoFamily
				}

				// how much is left, when the ACE knows (RFID spools)
				Rectangle {
					Layout.alignment: Qt.AlignHCenter
					Layout.topMargin: 3
					Layout.preferredWidth: 64
					Layout.preferredHeight: 4
					radius: 2
					visible: !holder.empty && holder.modelData.percent > 0
					color: Qt.alpha(Theme.fg, 0.1)

					Rectangle {
						width: parent.width * Math.min(1, holder.modelData.percent / 100)
						height: parent.height
						radius: 2
						color: holder.colour
					}
				}

				Rectangle {
					Layout.alignment: Qt.AlignHCenter
					Layout.topMargin: 4
					Layout.preferredHeight: 20
					Layout.preferredWidth: badge.implicitWidth + 16
					radius: 10
					color: holder.feeds ? Qt.alpha(Printer.hot, 0.16) : Theme.layer2

					StyledText {
						id: badge

						anchors.centerIn: parent
						text: holder.feeds ? "Feeding" : `Slot ${holder.modelData.slot + 1}`
						font.pixelSize: Theme.size.tiny
						font.weight: Font.DemiBold
						tone: holder.feeds ? Printer.hot : Theme.textMuted
					}
				}
			}
		}
	}
}
