import QtQuick
import qs.style.theme

// Icon label. When `icon` changes the old glyph shrinks away while the new
// one pops in, so state changes (mute, play/pause, wifi strength …) are
// always visible as motion instead of a hard swap.
Item {
	id: root

	property string icon: ""
	property real size: 18
	property color color: Theme.text
	property bool animated: true
	property real spin: 0
	// what the icon is drawn on; "transparent" when unknown (e.g. an image)
	property color surface: Theme.surfaceBehind(root)
	readonly property color shown: Theme.readableOn(root.color, root.surface)

	implicitWidth: size
	implicitHeight: size

	property bool _ready: false

	Component.onCompleted: {
		front.text = Icons.get(root.icon);
		root._ready = true;
	}

	onIconChanged: {
		const next = Icons.get(root.icon);
		if (!root._ready || !root.animated || next === front.text) {
			front.text = next;
			return;
		}
		back.text = front.text;
		front.text = next;
		swap.restart();
	}

	Text {
		id: back

		anchors.centerIn: parent
		opacity: 0
		color: root.shown
		font.family: Icons.family
		font.pixelSize: root.size
		horizontalAlignment: Text.AlignHCenter
		verticalAlignment: Text.AlignVCenter
	}

	Text {
		id: front

		anchors.centerIn: parent
		rotation: root.spin
		color: root.shown
		font.family: Icons.family
		font.pixelSize: root.size
		horizontalAlignment: Text.AlignHCenter
		verticalAlignment: Text.AlignVCenter

		Behavior on color {
			ColorAnim {}
		}
	}

	ParallelAnimation {
		id: swap

		NumberAnimation {
			target: back
			property: "opacity"
			from: 1
			to: 0
			duration: Motion.micro
		}
		NumberAnimation {
			target: back
			property: "scale"
			from: 1
			to: 0.4
			duration: Motion.short
			easing.type: Easing.InCubic
		}
		NumberAnimation {
			target: front
			property: "opacity"
			from: 0
			to: 1
			duration: Motion.short
		}
		NumberAnimation {
			target: front
			property: "scale"
			from: 0.4
			to: 1
			duration: Motion.medium
			easing.type: Easing.BezierSpline
			easing.bezierCurve: Motion.spatialFast
		}
	}
}
