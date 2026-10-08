import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets

// A number on a pill slider, in real units: `from`…`to` in steps of `step`.
// The value text says it the way niri means it (`format`).
Item {
	id: root

	property real from: 0
	property real to: 1
	property real step: 0.01
	property real value: 0
	property string icon: ""
	property string label: ""
	property string unit: ""
	property int decimals: 0
	property var format: null
	property color accent: Theme.primary
	readonly property bool dragging: slider.dragging

	signal moved(real value)

	function snap(v) {
		const stepped = Math.round((v - root.from) / root.step) * root.step + root.from;
		return Number(Math.max(root.from, Math.min(root.to, stepped)).toFixed(Math.max(root.decimals, 4)));
	}

	function text(v) {
		if (root.format) return root.format(v);
		return `${Number(v).toFixed(root.decimals)}${root.unit}`;
	}

	Layout.fillWidth: true
	implicitWidth: 260
	implicitHeight: 40

	PillSlider {
		id: slider

		anchors.fill: parent
		value: (root.value - root.from) / Math.max(1e-9, root.to - root.from)
		stepSize: root.step / Math.max(1e-9, root.to - root.from)
		icon: root.icon
		label: root.label
		accent: root.accent
		valueText: root.text(root.from + slider.display * (root.to - root.from))
		onMoved: v => root.moved(root.snap(root.from + v * (root.to - root.from)))
	}
}
