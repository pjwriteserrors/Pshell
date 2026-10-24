import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets

// A word of a sentence that is a choice: it reads like text in its colour,
// a wash comes up under the pointer and a click opens the list to pick from.
// entries: [{value, label, icon, detail}]
Clickable {
	id: root

	property var entries: []
	property string current: ""
	property string icon: ""
	property string fallback: "–"
	property color accent: Theme.primary
	property bool filled: false
	property int listWidth: 260
	property int fontSize: Theme.size.label
	readonly property var entry: (root.entries ?? []).find(e => String(e.value) === String(root.current)) ?? null
	readonly property string label: root.entry?.label ?? root.fallback

	signal picked(var value)

	function open() {
		list.open();
	}

	implicitHeight: 26
	implicitWidth: row.implicitWidth + 14
	radius: 8
	pressedScale: 0.94
	tint: root.accent
	color: root.filled ? Qt.alpha(root.accent, root.hovered || list.opened ? 0.24 : 0.14) : (root.hovered || list.opened ? Qt.alpha(root.accent, 0.12) : "transparent")
	onClicked: list.open()

	Behavior on color {
		ColorAnim {}
	}

	RowLayout {
		id: row

		anchors.centerIn: parent
		spacing: 4

		Glyph {
			visible: root.icon !== ""
			icon: root.icon
			size: root.fontSize + 2
			color: root.accent
		}

		StyledText {
			text: root.label
			tone: root.accent
			font.pixelSize: root.fontSize
			font.weight: Font.DemiBold
		}

		Glyph {
			icon: "chevron_down"
			size: 10
			color: root.accent
			opacity: root.hovered || list.opened ? 0.9 : 0.35
			rotation: list.opened ? 180 : 0

			Behavior on opacity {
				Anim {}
			}
			Behavior on rotation {
				SpatialAnim {
					duration: Motion.medium
				}
			}
		}
	}

	// a dotted line under it: this word can be changed
	Row {
		anchors.left: parent.left
		anchors.right: parent.right
		anchors.bottom: parent.bottom
		anchors.leftMargin: 7
		anchors.rightMargin: 7
		anchors.bottomMargin: 2
		spacing: 3
		visible: !root.filled
		opacity: root.hovered || list.opened ? 0 : 0.45
		clip: true

		Behavior on opacity {
			Anim {}
		}

		Repeater {
			model: Math.ceil(Math.max(0, root.width - 14) / 5)

			Rectangle {
				width: 2
				height: 1
				color: root.accent
			}
		}
	}

	PickList {
		id: list

		y: root.height + 4
		margins: 8
		width: root.listWidth
		entries: root.entries ?? []
		current: root.current
		onPicked: value => root.picked(value)
	}
}
