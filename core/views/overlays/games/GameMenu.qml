pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// What can be done with a game, as a card at the pointer (or under the
// button that asked). Entries: [{ icon, label, detail, run, danger,
// confirm, children }]; an entry with children slides over to them. ↑↓,
// Enter, → and ← work; Escape or a click beside it closes it.
Item {
	id: root

	property var entries: []
	property bool open: false
	property real atX: 0
	property real atY: 0
	// the list shown: the entries, or the children of one
	property var stack: []
	readonly property var shown: (root.stack.length > 0 ? root.stack[root.stack.length - 1].children : root.entries).filter(entry => entry.shown !== false)
	readonly property string title: root.stack.length > 0 ? root.stack[root.stack.length - 1].label : ""
	property int at: 0
	property string armed: ""
	property int direction: 1

	signal closed

	function show(entries, x, y) {
		root.entries = entries;
		root.stack = [];
		root.at = 0;
		root.armed = "";
		root.atX = x;
		root.atY = y;
		root.open = true;
		Sounds.play("open");
		keys.forceActiveFocus();
	}

	function close() {
		if (!root.open) return;
		root.open = false;
		root.closed();
	}

	function run(entry) {
		if (!entry || entry.enabled === false) return;
		if (entry.children) {
			root.direction = 1;
			root.stack = root.stack.concat([entry]);
			root.at = 0;
			slide.restart();
			Sounds.play("select");
			return;
		}
		if (entry.confirm && root.armed !== entry.label) {
			root.armed = entry.label;
			Sounds.play("attention");
			return;
		}
		root.close();
		Sounds.play("click");
		entry.run();
	}

	function back() {
		if (root.stack.length === 0) {
			root.close();
			return;
		}
		root.direction = -1;
		root.stack = root.stack.slice(0, -1);
		root.at = 0;
		slide.restart();
	}

	anchors.fill: parent
	visible: card.opacity > 0.01
	z: 50

	// a click beside it closes it
	MouseArea {
		anchors.fill: parent
		enabled: root.open
		acceptedButtons: Qt.AllButtons
		onClicked: root.close()
	}

	Item {
		id: keys

		focus: root.open

		Keys.onEscapePressed: root.back()
		Keys.onLeftPressed: root.back()
		Keys.onUpPressed: root.at = (root.at - 1 + root.shown.length) % Math.max(1, root.shown.length)
		Keys.onDownPressed: root.at = (root.at + 1) % Math.max(1, root.shown.length)
		Keys.onRightPressed: if (root.shown[root.at]?.children) root.run(root.shown[root.at])
		Keys.onReturnPressed: root.run(root.shown[root.at])
		Keys.onEnterPressed: root.run(root.shown[root.at])
		Keys.onSpacePressed: root.run(root.shown[root.at])
	}

	RectangularShadow {
		anchors.fill: card
		radius: card.radius
		blur: 40
		offset.y: 14
		color: Qt.rgba(0, 0, 0, 0.6)
		opacity: card.opacity
		scale: card.scale
	}

	Rectangle {
		id: card

		x: Math.max(16, Math.min(root.width - width - 16, root.atX))
		y: Math.max(16, Math.min(root.height - height - 16, root.atY))
		width: 280
		height: list.implicitHeight + 12
		radius: Theme.radius.large
		color: Qt.tint(Theme.bg, Qt.rgba(1, 1, 1, 0.06))
		border.width: 1
		border.color: Qt.rgba(1, 1, 1, 0.09)
		opacity: root.open ? 1 : 0
		scale: root.open ? 1 : 0.92
		transformOrigin: Item.TopLeft
		clip: true

		Behavior on opacity {
			Anim {
				duration: root.open ? Motion.medium : Motion.short
			}
		}
		Behavior on scale {
			SpatialAnim {
				duration: root.open ? Motion.long : Motion.short
			}
		}
		Behavior on height {
			SpatialAnim {
				duration: Motion.medium
			}
		}

		MouseArea {
			anchors.fill: parent
			acceptedButtons: Qt.AllButtons
		}

		ColumnLayout {
			id: list

			property real offset: 0

			x: 6 + list.offset
			y: 6
			width: parent.width - 12
			spacing: 2

			ParallelAnimation {
				id: slide

				NumberAnimation {
					target: list
					property: "offset"
					from: 40 * root.direction
					to: 0
					duration: Motion.long
					easing.type: Easing.BezierSpline
					easing.bezierCurve: Motion.spatial
				}
				NumberAnimation {
					target: list
					property: "opacity"
					from: 0
					to: 1
					duration: Motion.medium
				}
			}

			// the way back from a sub-list
			Clickable {
				Layout.fillWidth: true
				Layout.preferredHeight: 34
				visible: root.stack.length > 0
				radius: Theme.radius.medium
				color: "transparent"
				onClicked: root.back()

				RowLayout {
					anchors.fill: parent
					anchors.leftMargin: 8
					spacing: 8

					Glyph {
						icon: "chevron_left"
						size: 18
						color: Theme.textMuted
						surface: "transparent"
					}

					StyledText {
						Layout.fillWidth: true
						text: root.title
						tone: Theme.textMuted
						surface: "transparent"
						font.pixelSize: Theme.size.small
						font.weight: Font.Bold
						font.capitalization: Font.AllUppercase
						font.letterSpacing: 1.2
					}
				}
			}

			Repeater {
				model: root.shown

				delegate: Clickable {
					id: row

					required property var modelData
					required property int index
					readonly property bool lit: root.at === row.index
					readonly property bool armedHere: root.armed === row.modelData.label
					property real rise: 0

					Layout.fillWidth: true
					Layout.preferredHeight: row.modelData.detail ? 48 : 38
					radius: Theme.radius.medium
					color: row.armedHere ? Qt.alpha(Theme.danger, 0.22) : (row.lit ? Qt.rgba(1, 1, 1, 0.08) : "transparent")
					opacity: (row.modelData.enabled === false ? 0.4 : 1) * row.rise
					sound: ""
					onClicked: root.run(row.modelData)
					onEntered: root.at = row.index

					transform: Translate {
						x: 12 * (1 - row.rise)
					}

					Component.onCompleted: rising.start()

					SequentialAnimation {
						id: rising

						PauseAnimation {
							duration: 18 * row.index
						}
						NumberAnimation {
							target: row
							property: "rise"
							to: 1
							duration: Motion.medium
							easing.type: Easing.OutCubic
						}
					}

					Behavior on color {
						ColorAnim {}
					}

					RowLayout {
						anchors.fill: parent
						anchors.leftMargin: 10
						anchors.rightMargin: 10
						spacing: 10

						Glyph {
							icon: row.modelData.icon || "circle_small"
							size: 18
							color: row.modelData.danger || row.armedHere ? Theme.danger : (row.lit ? Theme.primary : Theme.textMuted)
							surface: "transparent"
						}

						ColumnLayout {
							Layout.fillWidth: true
							spacing: 0

							StyledText {
								Layout.fillWidth: true
								text: row.armedHere ? (row.modelData.confirm || "Click again") : row.modelData.label
								tone: row.modelData.danger || row.armedHere ? Theme.danger : Theme.text
								surface: "transparent"
								elide: Text.ElideRight
								font.pixelSize: Theme.size.body
								font.weight: row.lit ? Font.DemiBold : Font.Normal
							}

							StyledText {
								Layout.fillWidth: true
								visible: !!row.modelData.detail
								text: row.modelData.detail || ""
								tone: Theme.textSubtle
								surface: "transparent"
								elide: Text.ElideRight
								font.pixelSize: Theme.size.small
							}
						}

						Glyph {
							visible: !!row.modelData.children || !!row.modelData.checked
							icon: row.modelData.children ? "chevron_right" : "check"
							size: 16
							color: row.modelData.checked ? Theme.primary : Theme.textSubtle
							surface: "transparent"
						}
					}
				}
			}
		}
	}
}
