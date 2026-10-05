pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.core.services
import qs.style.widgets

// The fast reader (Reader): the word on its spot, the words around it, how
// far the text is, and the controls. The settings fold out from the cog.
// Space plays and pauses, the arrows step by sentence and change the speed.
Drawer {
	id: root

	property bool settings: false

	panelId: "reader"
	panelWidth: 780
	centered: true
	contentHeight: layout.implicitHeight

	onPanelOpened: root.settings = false

	ColumnLayout {
		id: layout

		anchors.left: parent.left
		anchors.right: parent.right
		spacing: 18
		focus: true

		Keys.onPressed: event => {
			switch (event.key) {
			case Qt.Key_Space:
				Reader.toggle();
				break;
			case Qt.Key_Left:
				Reader.back();
				break;
			case Qt.Key_Right:
				Reader.forward();
				break;
			case Qt.Key_Up:
				Reader.setSpeed(Reader.wpm + 25);
				break;
			case Qt.Key_Down:
				Reader.setSpeed(Reader.wpm - 25);
				break;
			case Qt.Key_R:
				Reader.restart();
				break;
			default:
				return;
			}
			event.accepted = true;
		}

		Rectangle {
			id: stage

			// from the middle of the word to its guide, and on to its neighbour
			readonly property real guide: Reader.pixels * 0.62 + 10
			readonly property real neighbour: stage.guide + 26 + 22

			Layout.fillWidth: true
			Layout.bottomMargin: 6
			implicitHeight: 236 + Reader.pixels
			radius: Theme.radius.huge
			color: Theme.layer1

			Behavior on implicitHeight {
				SpatialAnim {
					duration: Motion.medium
				}
			}

			MouseArea {
				anchors.fill: parent
				cursorShape: Qt.PointingHandCursor
				onClicked: Reader.toggle()
			}

			// the corners of the frame
			Repeater {
				model: 4

				delegate: Item {
					id: corner

					required property int index
					readonly property bool atRight: corner.index % 2 === 1
					readonly property bool atBottom: corner.index > 1

					x: corner.atRight ? stage.width - width - 14 : 14
					y: corner.atBottom ? stage.height - height - 14 : 14
					width: 14
					height: 14

					Rectangle {
						x: 0
						y: corner.atBottom ? parent.height - 1 : 0
						width: parent.width
						height: 1
						color: Theme.textFaint
					}

					Rectangle {
						x: corner.atRight ? parent.width - 1 : 0
						y: 0
						width: 1
						height: parent.height
						color: Theme.textFaint
					}
				}
			}

			StyledText {
				anchors.horizontalCenter: parent.horizontalCenter
				anchors.verticalCenter: parent.verticalCenter
				anchors.verticalCenterOffset: -stage.neighbour
				width: Math.min(implicitWidth, stage.width - 80)
				text: Reader.previous
				tone: Theme.textSubtle
				font.pixelSize: Theme.size.title
				font.weight: Font.Medium
			}

			StyledText {
				anchors.horizontalCenter: parent.horizontalCenter
				anchors.verticalCenter: parent.verticalCenter
				anchors.verticalCenterOffset: stage.neighbour
				width: Math.min(implicitWidth, stage.width - 80)
				text: Reader.next
				tone: Theme.textSubtle
				font.pixelSize: Theme.size.title
				font.weight: Font.Medium
			}

			// the guides the marked letter stands between
			Rectangle {
				anchors.horizontalCenter: parent.horizontalCenter
				y: stage.height / 2 - stage.guide - height
				width: 1
				height: 26
				color: Theme.textFaint
			}

			Rectangle {
				anchors.horizontalCenter: parent.horizontalCenter
				y: stage.height / 2 + stage.guide
				width: 1
				height: 26
				color: Theme.textFaint
			}

			// the word, with its marked letter in the middle whatever its length
			Item {
				id: word

				readonly property string text: Reader.word
				readonly property int at: Reader.pivot(word.text)
				readonly property real reach: Math.max(before.implicitWidth, after.implicitWidth) + marked.implicitWidth / 2

				anchors.centerIn: parent
				visible: Reader.counting === 0
				// a word wider than the frame shrinks into it
				scale: Math.min(1, (stage.width / 2 - 32) / Math.max(1, word.reach))

				StyledText {
					id: marked

					anchors.centerIn: parent
					text: word.text.charAt(word.at)
					tone: Theme.primary
					elide: Text.ElideNone
					font.pixelSize: Reader.pixels
					font.weight: Font.DemiBold
				}

				StyledText {
					id: before

					anchors.right: marked.left
					anchors.baseline: marked.baseline
					text: word.text.slice(0, word.at)
					elide: Text.ElideNone
					font.pixelSize: Reader.pixels
					font.weight: Font.DemiBold
				}

				StyledText {
					id: after

					anchors.left: marked.right
					anchors.baseline: marked.baseline
					text: word.text.slice(word.at + 1)
					elide: Text.ElideNone
					font.pixelSize: Reader.pixels
					font.weight: Font.DemiBold
				}
			}

			StyledText {
				anchors.centerIn: parent
				visible: Reader.counting > 0
				text: String(Reader.counting)
				tone: Theme.primary
				tabular: true
				font.pixelSize: Reader.pixels
				font.weight: Font.DemiBold
			}

			// sits on the frame's lower edge while the words stand still
			Rectangle {
				anchors.horizontalCenter: parent.horizontalCenter
				anchors.verticalCenter: parent.bottom
				width: status.implicitWidth + 26
				height: 24
				radius: height / 2
				color: Theme.layer3
				opacity: Reader.playing ? 0 : 1

				Behavior on opacity {
					Anim {
						duration: Motion.short
					}
				}

				SectionLabel {
					id: status

					anchors.centerIn: parent
					text: Reader.finished ? "Done" : "Paused"
					tone: Theme.textMuted
				}
			}
		}

		// how far the text is; a click or a drag goes there
		Item {
			Layout.fillWidth: true
			implicitHeight: 14

			Rectangle {
				anchors.verticalCenter: parent.verticalCenter
				width: parent.width
				height: 3
				radius: height / 2
				color: Theme.layer2

				Rectangle {
					width: Math.max(parent.height, parent.width * Reader.progress)
					height: parent.height
					radius: height / 2
					color: Theme.primary
				}
			}

			MouseArea {
				anchors.fill: parent
				cursorShape: Qt.PointingHandCursor
				onPressed: mouse => Reader.seek(mouse.x / width * (Reader.words.length - 1))
				onPositionChanged: mouse => Reader.seek(mouse.x / width * (Reader.words.length - 1))
			}
		}

		Rectangle {
			Layout.alignment: Qt.AlignHCenter
			implicitWidth: controls.implicitWidth + 28
			implicitHeight: 68
			radius: height / 2
			color: Theme.layer1

			RowLayout {
				id: controls

				anchors.centerIn: parent
				spacing: 10

				IconButton {
					implicitWidth: 40
					implicitHeight: 40
					icon: "restart"
					onClicked: Reader.restart()
				}

				IconButton {
					implicitWidth: 40
					implicitHeight: 40
					icon: "chevron_double_left"
					onClicked: Reader.back()
				}

				IconButton {
					implicitWidth: 52
					implicitHeight: 52
					icon: Reader.playing ? "pause" : "play"
					variant: "filled"
					onClicked: Reader.toggle()
				}

				IconButton {
					implicitWidth: 40
					implicitHeight: 40
					icon: "chevron_double_right"
					onClicked: Reader.forward()
				}

				Rectangle {
					Layout.leftMargin: 6
					Layout.rightMargin: 6
					implicitWidth: speed.implicitWidth + 8
					implicitHeight: 40
					radius: height / 2
					color: Theme.layer2

					RowLayout {
						id: speed

						anchors.centerIn: parent
						spacing: 2

						IconButton {
							implicitWidth: 32
							implicitHeight: 32
							iconSize: 14
							icon: "minus"
							onClicked: Reader.setSpeed(Reader.wpm - 25)
						}

						StyledText {
							Layout.preferredWidth: 40
							horizontalAlignment: Text.AlignHCenter
							text: String(Reader.wpm)
							tabular: true
							font.family: Theme.monoFamily
						}

						IconButton {
							implicitWidth: 32
							implicitHeight: 32
							iconSize: 14
							icon: "plus"
							onClicked: Reader.setSpeed(Reader.wpm + 25)
						}
					}
				}

				IconButton {
					implicitWidth: 40
					implicitHeight: 40
					icon: "cog"
					checked: root.settings
					onClicked: root.settings = !root.settings
				}
			}
		}

		Item {
			Layout.fillWidth: true
			Layout.topMargin: root.settings ? 0 : -layout.spacing
			implicitHeight: root.settings ? options.implicitHeight : 0
			clip: true
			opacity: root.settings ? 1 : 0

			Behavior on implicitHeight {
				SpatialAnim {
					duration: Motion.medium
				}
			}
			Behavior on opacity {
				Anim {}
			}

			GridLayout {
				id: options

				width: parent.width
				columns: 2
				columnSpacing: 16
				rowSpacing: 12

				StyledText {
					Layout.fillWidth: true
					text: "Speed"
					tone: Theme.textMuted
				}

				RowLayout {
					spacing: 6

					Repeater {
						model: Reader.speeds

						delegate: Chip {
							required property var modelData

							text: `${modelData.wpm} · ${modelData.label}`
							selected: Reader.wpm === modelData.wpm
							onClicked: Reader.setSpeed(modelData.wpm)
						}
					}
				}

				StyledText {
					Layout.fillWidth: true
					text: "Font size"
					tone: Theme.textMuted
				}

				Segmented {
					Layout.alignment: Qt.AlignRight
					implicitWidth: 220
					implicitHeight: 32
					current: Reader.size
					options: Reader.sizes
					onSelected: value => Reader.setSize(value)
				}

				StyledText {
					Layout.fillWidth: true
					text: "Punctuation pause"
					tone: Theme.textMuted
				}

				Toggle {
					Layout.alignment: Qt.AlignRight
					checked: Reader.punctuation
					onToggled: checked => Reader.setPunctuation(checked)
				}

				StyledText {
					Layout.fillWidth: true
					text: "Countdown before start"
					tone: Theme.textMuted
				}

				Toggle {
					Layout.alignment: Qt.AlignRight
					checked: Reader.countdown
					onToggled: checked => Reader.setCountdown(checked)
				}
			}
		}
	}
}
