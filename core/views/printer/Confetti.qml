import QtQuick
import qs.style.theme
import qs.core.services

// A burst of confetti in the spools' colours, for a print that finished.
// burst() throws it from the middle; one clock moves every piece.
Item {
	id: root

	property var colours: [Theme.primary, Printer.hot, Theme.secondary, Theme.success]
	property real time: 0
	property int seed: 0

	function burst() {
		root.seed += 1;
		clock.restart();
	}

	visible: clock.running

	NumberAnimation {
		id: clock

		target: root
		property: "time"
		from: 0
		to: 1
		duration: 2600
	}

	Repeater {
		model: 110

		delegate: Rectangle {
			id: piece

			required property int index
			// the same piece flies another way each burst
			readonly property real r1: piece.rand(1)
			readonly property real r2: piece.rand(2)
			readonly property real r3: piece.rand(3)
			readonly property real angle: -Math.PI / 2 + (piece.r1 - 0.5) * Math.PI * 1.3
			readonly property real speed: (0.45 + piece.r2 * 0.75) * root.height
			readonly property real t: root.time * 2.6

			function rand(k) {
				const v = Math.sin((piece.index + 1) * 12.9898 * k + root.seed * 78.233) * 43758.5453;
				return v - Math.floor(v);
			}

			width: 7 + piece.r3 * 7
			height: piece.index % 3 === 0 ? width : width * 0.45
			radius: piece.index % 3 === 0 ? width / 2 : 1
			color: root.colours[piece.index % root.colours.length]
			x: root.width / 2 + Math.cos(piece.angle) * piece.speed * piece.t * 0.55 - width / 2
			y: root.height * 0.55 + Math.sin(piece.angle) * piece.speed * piece.t + 0.5 * root.height * 1.6 * piece.t * piece.t
			rotation: piece.t * (piece.r2 - 0.5) * 1440
			opacity: root.time < 0.75 ? 1 : (1 - root.time) * 4
		}
	}
}
