import QtQuick
import qs.style.theme
import qs.style.widgets

// The water bottle. Its level is what is left in the real bottle: drag it
// (or scroll, 25 ml a step) to where the real one stands. The marks sit at
// the quarters. The surface waves while it is on screen and sloshes when
// the level changes; what was drunk rises out of the bottle. Each size has
// a bottle of its own (a small PET bottle with a grip, a long-necked glass
// bottle, a big sports bottle with a loop); switching morphs one into the
// other.
Item {
	id: root

	// millilitres left / bottle size
	property int remaining: 0
	property int size: 750
	property bool running: true

	// a reading was made: millilitres left
	signal levelSet(int remaining)

	property int preview: -1
	readonly property int shownLeft: root.preview >= 0 ? root.preview : root.remaining
	property real level: root.shownLeft / root.size
	property real phase: 0
	property real amplitude: 2

	readonly property var shapes: ({
		500: { w: 70, h: 158, cap: 12, capExtra: 4, neck: 0.46, neckH: 7, shoulder: 18, corner: 12, waist: 5, loop: 0, ridges: 1 },
		750: { w: 92, h: 196, cap: 14, capExtra: 6, neck: 0.36, neckH: 12, shoulder: 26, corner: 16, waist: 0, loop: 0, ridges: 0 },
		1000: { w: 108, h: 216, cap: 20, capExtra: 10, neck: 0.5, neckH: 5, shoulder: 14, corner: 22, waist: 0, loop: 1, ridges: 0 }
	})
	readonly property var shape: root.shapes[root.size] || root.shapes[750]

	property real shapeWidth: root.shape.w
	property real shapeHeight: root.shape.h
	property real capHeight: root.shape.cap
	property real capExtra: root.shape.capExtra
	property real neckRatio: root.shape.neck
	property real neckHeight: root.shape.neckH
	property real shoulder: root.shape.shoulder
	property real corner: root.shape.corner
	property real waist: root.shape.waist
	property real loop: root.shape.loop
	property real ridges: root.shape.ridges

	Behavior on shapeWidth { SpatialAnim { duration: Motion.extraLong + 200 } }
	Behavior on shapeHeight { SpatialAnim { duration: Motion.extraLong + 200 } }
	Behavior on capHeight { SpatialAnim { duration: Motion.extraLong + 200 } }
	Behavior on capExtra { SpatialAnim { duration: Motion.extraLong + 200 } }
	Behavior on neckRatio { SpatialAnim { duration: Motion.extraLong + 200 } }
	Behavior on neckHeight { SpatialAnim { duration: Motion.extraLong + 200 } }
	Behavior on shoulder { SpatialAnim { duration: Motion.extraLong + 200 } }
	Behavior on corner { SpatialAnim { duration: Motion.extraLong + 200 } }
	Behavior on waist { SpatialAnim { duration: Motion.extraLong + 200 } }
	Behavior on loop { Anim { duration: Motion.extraLong } }
	Behavior on ridges { Anim { duration: Motion.extraLong } }

	readonly property real wall: 3
	// room above the cap for the loop
	readonly property real loopRoom: root.loop * 12
	readonly property real neckWidth: root.width * root.neckRatio
	readonly property real bodyTop: root.loopRoom + root.capHeight + root.neckHeight + root.shoulder
	readonly property real bodyBottom: root.height - root.wall
	// the level runs over the straight body; full is where the shoulder starts
	readonly property real fillTop: root.bodyTop + 4
	readonly property real fillBottom: root.bodyBottom - 2

	implicitWidth: root.shapeWidth
	implicitHeight: root.shapeHeight

	function snap(ml) {
		return Math.max(0, Math.min(root.size, Math.round(ml / 25) * 25));
	}

	function levelAt(y) {
		return root.snap((root.fillBottom - y) / (root.fillBottom - root.fillTop) * root.size);
	}

	function drank(ml) {
		gain.text = `−${ml} ml`;
		rise.restart();
	}

	Behavior on level {
		enabled: root.preview < 0
		SpatialAnim {
			duration: Motion.extraLong * 2
		}
	}

	onRemainingChanged: slosh.restart()

	NumberAnimation on phase {
		running: root.running && root.visible
		from: 0
		to: Math.PI * 2
		duration: 2600
		loops: Animation.Infinite
	}

	SequentialAnimation {
		id: slosh

		NumberAnimation {
			target: root
			property: "amplitude"
			to: 8
			duration: Motion.short
			easing.type: Easing.OutQuad
		}
		NumberAnimation {
			target: root
			property: "amplitude"
			to: 2
			duration: 1800
			easing.type: Easing.OutElastic
			easing.amplitude: 1.4
			easing.period: 0.35
		}
	}

	Canvas {
		id: canvas

		readonly property color water: Theme.primary
		readonly property color glass: Theme.textSubtle

		anchors.fill: parent
		renderStrategy: Canvas.Cooperative
		onWaterChanged: requestPaint()
		onGlassChanged: requestPaint()

		Connections {
			target: root
			function onWidthChanged() {
				canvas.requestPaint();
			}
			function onHeightChanged() {
				canvas.requestPaint();
			}
			function onCapHeightChanged() {
				canvas.requestPaint();
			}
			function onCapExtraChanged() {
				canvas.requestPaint();
			}
			function onNeckRatioChanged() {
				canvas.requestPaint();
			}
			function onNeckHeightChanged() {
				canvas.requestPaint();
			}
			function onShoulderChanged() {
				canvas.requestPaint();
			}
			function onCornerChanged() {
				canvas.requestPaint();
			}
			function onWaistChanged() {
				canvas.requestPaint();
			}
			function onLoopChanged() {
				canvas.requestPaint();
			}
			function onRidgesChanged() {
				canvas.requestPaint();
			}
			function onPhaseChanged() {
				canvas.requestPaint();
			}
			function onLevelChanged() {
				canvas.requestPaint();
			}
			function onAmplitudeChanged() {
				canvas.requestPaint();
			}
		}

		function outline(ctx) {
			const w = root.width;
			const half = root.wall / 2;
			const neckLeft = (w - root.neckWidth) / 2;
			const neckRight = neckLeft + root.neckWidth;
			const neckTop = root.loopRoom + root.capHeight;
			const shoulderTop = neckTop + root.neckHeight;
			const radius = root.corner;
			// the grip: the sides draw in around the middle of the body
			const gripTop = root.bodyTop + (root.bodyBottom - root.bodyTop) * 0.34;
			const gripBottom = root.bodyTop + (root.bodyBottom - root.bodyTop) * 0.66;
			const gripMid = (gripTop + gripBottom) / 2;
			ctx.beginPath();
			ctx.moveTo(neckLeft, neckTop);
			ctx.lineTo(neckLeft, shoulderTop);
			ctx.bezierCurveTo(neckLeft, shoulderTop + root.shoulder * 0.6, half, shoulderTop + root.shoulder * 0.4, half, root.bodyTop);
			ctx.lineTo(half, gripTop);
			ctx.quadraticCurveTo(half + root.waist * 2, gripMid, half, gripBottom);
			ctx.lineTo(half, root.bodyBottom - radius);
			ctx.quadraticCurveTo(half, root.bodyBottom, half + radius, root.bodyBottom);
			ctx.lineTo(w - half - radius, root.bodyBottom);
			ctx.quadraticCurveTo(w - half, root.bodyBottom, w - half, root.bodyBottom - radius);
			ctx.lineTo(w - half, gripBottom);
			ctx.quadraticCurveTo(w - half - root.waist * 2, gripMid, w - half, gripTop);
			ctx.lineTo(w - half, root.bodyTop);
			ctx.bezierCurveTo(w - half, shoulderTop + root.shoulder * 0.4, neckRight, shoulderTop + root.shoulder * 0.6, neckRight, shoulderTop);
			ctx.lineTo(neckRight, neckTop);
		}

		function wave(ctx, phase, lift, amplitude, style) {
			const y = root.fillBottom - (root.fillBottom - root.fillTop) * root.level + lift;
			const steps = 24;
			ctx.beginPath();
			ctx.moveTo(0, root.height);
			for (let i = 0; i <= steps; i += 1)
				ctx.lineTo(root.width * i / steps, y + Math.sin(phase + i / steps * Math.PI * 2) * amplitude);
			ctx.lineTo(root.width, root.height);
			ctx.closePath();
			ctx.fillStyle = style;
			ctx.fill();
		}

		onPaint: {
			const ctx = getContext("2d");
			ctx.reset();
			const w = root.width;

			// cap, with a carrying loop and grip ridges where the bottle has them
			const capWidth = root.neckWidth + root.capExtra;
			const capLeft = (w - capWidth) / 2;
			if (root.loop > 0.01) {
				ctx.strokeStyle = Qt.alpha(canvas.glass, canvas.glass.a * root.loop);
				ctx.lineWidth = 3;
				ctx.beginPath();
				ctx.moveTo(w / 2 - capWidth * 0.3, root.loopRoom + 2);
				ctx.bezierCurveTo(w / 2 - capWidth * 0.34, root.loopRoom - 14 * root.loop, w / 2 + capWidth * 0.34, root.loopRoom - 14 * root.loop, w / 2 + capWidth * 0.3, root.loopRoom + 2);
				ctx.stroke();
			}
			ctx.fillStyle = canvas.glass;
			ctx.beginPath();
			ctx.roundedRect(capLeft, root.loopRoom, capWidth, root.capHeight - 2, 3, 3);
			ctx.fill();
			if (root.ridges > 0.01) {
				ctx.strokeStyle = Qt.alpha(Theme.base, 0.5 * root.ridges);
				ctx.lineWidth = 1;
				for (let x = capLeft + 4; x < capLeft + capWidth - 3; x += 4) {
					ctx.beginPath();
					ctx.moveTo(x, root.loopRoom + 2);
					ctx.lineTo(x, root.loopRoom + root.capHeight - 4);
					ctx.stroke();
				}
			}

			// body, water clipped to it
			ctx.save();
			canvas.outline(ctx);
			ctx.closePath();
			ctx.fillStyle = Qt.alpha(Theme.text, 0.04);
			ctx.fill();
			ctx.clip();
			if (root.level > 0.001) {
				canvas.wave(ctx, root.phase + 1.9, 2, root.amplitude * 0.8, Qt.alpha(canvas.water, 0.35));
				const gradient = ctx.createLinearGradient(0, root.fillTop, 0, root.height);
				gradient.addColorStop(0, Qt.lighter(canvas.water, 1.2));
				gradient.addColorStop(1, canvas.water);
				canvas.wave(ctx, root.phase, 0, root.amplitude, gradient);
			}
			ctx.restore();

			// quarter marks
			ctx.strokeStyle = Qt.alpha(Theme.text, 0.35);
			ctx.lineWidth = 1.5;
			for (let q = 1; q < 4; q += 1) {
				const y = root.fillBottom - (root.fillBottom - root.fillTop) * q / 4;
				ctx.beginPath();
				ctx.moveTo(w - root.wall - (q === 2 ? 14 : 9), y);
				ctx.lineTo(w - root.wall - 2, y);
				ctx.stroke();
			}

			canvas.outline(ctx);
			ctx.lineWidth = root.wall;
			ctx.lineCap = "round";
			ctx.lineJoin = "round";
			ctx.strokeStyle = canvas.glass;
			ctx.stroke();
		}
	}

	StyledText {
		anchors.horizontalCenter: parent.horizontalCenter
		y: root.bodyTop + 10
		text: root.shownLeft >= 1000 ? `${(root.shownLeft / 1000).toFixed(2)}` : `${root.shownLeft}`
		tone: root.level > 0.8 ? Theme.onPrimary : Theme.text
		font.pixelSize: Theme.size.title
		font.weight: Font.Bold
		tabular: true

		StyledText {
			anchors.top: parent.bottom
			anchors.horizontalCenter: parent.horizontalCenter
			text: "ml"
			tone: root.level > 0.72 ? Qt.alpha(Theme.onPrimary, 0.8) : Theme.textSubtle
			font.pixelSize: Theme.size.tiny
		}
	}

	// what was drunk rises out of the neck
	StyledText {
		id: gain

		anchors.horizontalCenter: parent.horizontalCenter
		y: 0
		opacity: 0
		tone: Theme.primary
		font.pixelSize: Theme.size.body
		font.weight: Font.Bold
		tabular: true

		ParallelAnimation {
			id: rise

			NumberAnimation {
				target: gain
				property: "y"
				from: root.bodyTop
				to: -22
				duration: 1400
				easing.type: Easing.OutCubic
			}
			SequentialAnimation {
				NumberAnimation {
					target: gain
					property: "opacity"
					to: 1
					duration: 180
				}
				PauseAnimation {
					duration: 800
				}
				NumberAnimation {
					target: gain
					property: "opacity"
					to: 0
					duration: 420
				}
			}
		}
	}

	MouseArea {
		anchors.fill: parent
		cursorShape: pressed ? Qt.ClosedHandCursor : Qt.SizeVerCursor
		preventStealing: true
		onPressed: mouse => root.preview = root.levelAt(mouse.y)
		onPositionChanged: mouse => {
			if (pressed) root.preview = root.levelAt(mouse.y);
		}
		onReleased: {
			const left = root.preview;
			if (left !== root.remaining) root.levelSet(left);
			root.preview = -1;
		}
		onCanceled: root.preview = -1
		onWheel: wheel => {
			const base = root.preview >= 0 ? root.preview : root.remaining;
			root.preview = root.snap(base + (wheel.angleDelta.y > 0 ? 25 : -25));
			commitWheel.restart();
		}
	}

	Timer {
		id: commitWheel

		interval: 700
		onTriggered: {
			const left = root.preview;
			if (left >= 0 && left !== root.remaining) root.levelSet(left);
			root.preview = -1;
		}
	}
}
