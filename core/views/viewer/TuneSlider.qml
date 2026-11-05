import QtQuick
import qs.style.theme
import qs.style.widgets

// A slider for a change that can go either way: the fill grows from the
// middle (or from the left with `from: 0`), the thumb follows the pointer
// 1:1, a double-click or the arrow beside the value puts it back; the
// wheel scrolls past it and never changes it. `moved` while it is
// dragged (the picture follows live), `committed` when it is let go.
Item {
	id: root

	property string label: ""
	property string icon: ""
	property real value: 0
	property real from: -1
	property real to: 1
	property real step: 0.01
	property color accent: Theme.primary
	property string valueText: (root.shown > 0.0049 && root.from < 0 ? "+" : "") + Math.round(root.shown * 100)
	signal moved(real value)
	signal committed(real value)

	readonly property real span: root.to - root.from
	readonly property real origin: Math.max(root.from, Math.min(root.to, 0))
	readonly property bool changed: Math.abs(root.value) > 1e-4
	property bool dragging: false
	property real dragValue: 0
	readonly property real shown: root.dragging ? root.dragValue : root.value
	readonly property real fraction: (root.shown - root.from) / root.span
	readonly property real originFraction: (root.origin - root.from) / root.span

	implicitHeight: 44
	implicitWidth: 260

	function valueAt(x) {
		const f = Math.max(0, Math.min(1, (x - track.x) / track.width));
		let v = root.from + f * root.span;
		v = Math.round(v / root.step) * root.step;
		// a little pull towards the middle
		if (Math.abs(v - root.origin) < root.span * 0.015) v = root.origin;
		return Math.max(root.from, Math.min(root.to, v));
	}

	Glyph {
		id: glyph

		anchors.left: parent.left
		anchors.top: parent.top
		anchors.topMargin: 2
		icon: root.icon
		size: 15
		color: root.changed ? root.accent : Theme.textMuted
	}

	StyledText {
		anchors.left: glyph.right
		anchors.leftMargin: 8
		anchors.verticalCenter: glyph.verticalCenter
		text: root.label
		font.pixelSize: Theme.size.label
		tone: root.changed ? Theme.text : Theme.textMuted
	}

	// back to how it was, for this one change
	IconButton {
		id: revert

		anchors.right: valueLabel.left
		anchors.rightMargin: 4
		anchors.verticalCenter: glyph.verticalCenter
		width: 22
		height: 22
		icon: "backup_restore"
		iconSize: 14
		opacity: root.changed && !root.dragging ? 1 : 0
		visible: opacity > 0.01
		scale: root.changed ? 1 : 0.6
		onClicked: {
			root.moved(root.origin);
			root.committed(root.origin);
		}

		Behavior on opacity {
			Anim {}
		}
		Behavior on scale {
			SpatialAnim {}
		}
	}

	StyledText {
		id: valueLabel

		anchors.right: parent.right
		anchors.verticalCenter: glyph.verticalCenter
		text: root.valueText
		tabular: true
		font.pixelSize: Theme.size.label
		tone: root.changed || root.dragging ? Theme.text : Theme.textSubtle
	}

	Item {
		id: track

		anchors.left: parent.left
		anchors.right: parent.right
		anchors.bottom: parent.bottom
		anchors.bottomMargin: 6
		height: 14

		Rectangle {
			id: rail

			anchors.verticalCenter: parent.verticalCenter
			width: parent.width
			height: mouse.containsMouse || root.dragging ? 6 : 4
			radius: height / 2
			color: Theme.layer3

			Behavior on height {
				Anim {}
			}
		}

		// the middle mark
		Rectangle {
			visible: root.from < 0
			x: track.width * root.originFraction - 1
			anchors.verticalCenter: parent.verticalCenter
			width: 2
			height: 10
			radius: 1
			color: Theme.textFaint
		}

		Rectangle {
			anchors.verticalCenter: parent.verticalCenter
			x: track.width * Math.min(root.fraction, root.originFraction)
			width: track.width * Math.abs(root.fraction - root.originFraction)
			height: rail.height
			radius: height / 2
			color: root.accent
		}

		Rectangle {
			id: thumb

			x: track.width * root.fraction - width / 2
			anchors.verticalCenter: parent.verticalCenter
			width: root.dragging ? 18 : (mouse.containsMouse ? 16 : 12)
			height: width
			radius: width / 2
			color: root.changed || root.dragging ? root.accent : Theme.text
			border.width: 2
			border.color: Theme.base

			Behavior on width {
				SpatialAnim {}
			}
		}
	}

	MouseArea {
		id: mouse

		anchors.fill: track
		anchors.topMargin: -12
		anchors.bottomMargin: -6
		hoverEnabled: true
		preventStealing: true
		cursorShape: Qt.PointingHandCursor

		onPressed: event => {
			root.dragging = true;
			root.dragValue = root.valueAt(event.x);
			root.moved(root.dragValue);
		}
		onPositionChanged: event => {
			if (!root.dragging) return;
			const v = root.valueAt(event.x);
			if (v === root.dragValue) return;
			root.dragValue = v;
			root.moved(v);
		}
		onReleased: {
			root.dragging = false;
			root.committed(root.dragValue);
		}
		onCanceled: {
			root.dragging = false;
			root.committed(root.dragValue);
		}
		onDoubleClicked: {
			root.dragging = false;
			root.moved(root.origin);
			root.committed(root.origin);
		}
	}

}
