import QtQuick
import qs.style.theme
import qs.core.services
import qs.style.widgets

// A little print that prints itself while there is nothing to print: a
// nozzle lays a vase layer by layer, back and forth, in the colour of the
// ACE's spools one after the other; done, it hops and the next one starts.
Item {
	id: root

	property bool running: true
	readonly property int count: 26
	readonly property real step: Math.max(5, Math.round(root.height * 0.021))
	readonly property real base: root.height * 0.72
	// the vase's outline, a width for each layer (0…1)
	readonly property var widths: {
		// a vase: a foot, a belly, a neck and a lip, smoothed between
		const points = [0.5, 0.78, 0.9, 0.86, 0.68, 0.46, 0.36, 0.38, 0.52];
		return Array.from({ length: root.count }, (_, i) => {
			const at = i / (root.count - 1) * (points.length - 1);
			const k = Math.min(points.length - 2, Math.floor(at));
			const f = at - k;
			const ease = f * f * (3 - 2 * f);
			return points[k] + (points[k + 1] - points[k]) * ease;
		});
	}
	readonly property real span: root.width * 0.36
	readonly property var colours: {
		// a spool too dark to see on the stage is left out
		const loaded = Printer.slots.filter(slot => slot.type !== "" && (slot.color[0] * 0.3 + slot.color[1] * 0.59 + slot.color[2] * 0.11) > 60).map(slot => Printer.rgb(slot.color));
		return loaded.length > 0 ? loaded : [Theme.primary, Printer.hot, Theme.secondary];
	}
	property int round: 0
	readonly property color colour: root.colours[root.round % root.colours.length]
	property real t: 0

	SequentialAnimation {
		running: root.running && root.visible
		loops: Animation.Infinite

		NumberAnimation {
			target: root
			property: "t"
			from: 0
			to: root.count
			duration: root.count * 330
		}
		ScriptAction {
			script: hop.restart()
		}
		PauseAnimation {
			duration: 1500
		}
		NumberAnimation {
			target: vase
			property: "opacity"
			to: 0
			duration: 300
		}
		ScriptAction {
			script: {
				root.t = 0;
				root.round += 1;
				vase.opacity = 1;
			}
		}
	}

	// the bed
	Rectangle {
		x: root.width / 2 - width / 2
		y: root.base
		width: root.span * 1.6
		height: 4
		radius: 2
		color: Qt.alpha(Theme.fg, 0.14)
	}

	Item {
		id: vase

		anchors.fill: parent
		transformOrigin: Item.Bottom

		SequentialAnimation {
			id: hop

			NumberAnimation { target: vase; property: "scale"; to: 1.08; duration: 140; easing.type: Easing.OutQuad }
			NumberAnimation { target: vase; property: "scale"; to: 1; duration: 520; easing.type: Easing.OutBack; easing.overshoot: 3 }
		}

		Repeater {
			model: root.count

			delegate: Rectangle {
				id: line

				required property int index
				readonly property real full: root.span * root.widths[line.index]
				readonly property real done: Math.max(0, Math.min(1, root.t - line.index))
				// every other layer runs the other way
				readonly property bool back: line.index % 2 === 1

				x: root.width / 2 - line.full / 2 + (line.back ? line.full * (1 - line.done) : 0)
				y: root.base - (line.index + 1) * root.step
				width: line.full * line.done
				height: root.step - 0.5
				radius: height / 2
				color: Qt.darker(root.colour, 1 + (line.index % 2) * 0.08 + (root.count - line.index) * 0.008)
				visible: line.done > 0
			}
		}
	}

	// the nozzle
	Item {
		id: nozzle

		readonly property int at: Math.min(root.count - 1, Math.floor(root.t))
		readonly property real part: Math.min(1, root.t - nozzle.at)
		readonly property real full: root.span * root.widths[nozzle.at]
		readonly property bool back: nozzle.at % 2 === 1

		width: 22
		height: 34
		x: root.width / 2 - nozzle.full / 2 + nozzle.full * (nozzle.back ? 1 - nozzle.part : nozzle.part) - width / 2
		y: root.base - (nozzle.at + 1) * root.step - height
		opacity: vase.opacity

		Behavior on y {
			NumberAnimation {
				duration: 160
			}
		}

		// the hot end
		Rectangle {
			anchors.horizontalCenter: parent.horizontalCenter
			width: 22
			height: 18
			radius: 4
			color: Theme.layer3
			border.width: 1
			border.color: Theme.outline
		}

		// the tip, glowing
		Rectangle {
			anchors.horizontalCenter: parent.horizontalCenter
			y: 18
			width: 10
			height: 12
			radius: 2
			color: Printer.hot
		}

		Rectangle {
			anchors.horizontalCenter: parent.horizontalCenter
			y: 22
			width: 26
			height: 26
			radius: 13
			z: -1
			color: Qt.alpha(Printer.hot, 0.25)

			SequentialAnimation on opacity {
				running: root.running && root.visible
				loops: Animation.Infinite
				NumberAnimation { to: 0.3; duration: 500 }
				NumberAnimation { to: 1; duration: 500 }
			}
		}
	}
}
