import QtQuick

// Palette-neutral decorative frame. Every tone is derived from the owning
// surface so shape themes can become ornate without introducing colors.
Item {
	id: root

	property color surfaceColor: "transparent"
	property real cornerRadius: 0
	property bool compact: false
	property bool interactive: false
	property bool pressed: false
	property string ornamentStyle: ThemeEngine.ornamentStyle
	property real ornamentOpacity: ThemeEngine.ornamentOpacity
	property real lineWidth: ThemeEngine.ornamentLineWidth
	property real frameInset: ThemeEngine.ornamentInset
	property real cornerLength: ThemeEngine.ornamentCornerLength
	property real notchSize: ThemeEngine.ornamentNotchSize
	property bool doubleLine: ThemeEngine.ornamentDoubleLine
	property bool centerMarks: ThemeEngine.ornamentCenterMarks
	property bool trackCaps: ThemeEngine.ornamentTrackCaps

	readonly property bool active: root.ornamentStyle !== "none" && root.ornamentOpacity > 0
	readonly property color ink: ThemeEngine.contrastEdge(root.surfaceColor, 1)
	property real pulse: 0

	visible: root.active
	opacity: root.ornamentOpacity + pulse * ThemeEngine.ornamentGlowOpacity
	z: 902

	Behavior on opacity {
		NumberAnimation { duration: ThemeEngine.fast; easing.type: ThemeEngine.standardEasing }
	}

	onInteractiveChanged: {
		if (root.interactive && root.active) glow.restart();
		else glow.stop();
	}
	onPressedChanged: frame.requestPaint()
	onWidthChanged: frame.requestPaint()
	onHeightChanged: frame.requestPaint()
	onSurfaceColorChanged: frame.requestPaint()
	onCompactChanged: frame.requestPaint()
	onOrnamentStyleChanged: frame.requestPaint()
	onLineWidthChanged: frame.requestPaint()
	onFrameInsetChanged: frame.requestPaint()
	onCornerLengthChanged: frame.requestPaint()
	onNotchSizeChanged: frame.requestPaint()
	onDoubleLineChanged: frame.requestPaint()
	onCenterMarksChanged: frame.requestPaint()
	onTrackCapsChanged: frame.requestPaint()

	SequentialAnimation {
		id: glow
		loops: Animation.Infinite
		NumberAnimation { target: root; property: "pulse"; from: 0; to: 1; duration: Math.max(1, ThemeEngine.ornamentPulseDuration / 2); easing.type: Easing.InOutSine }
		NumberAnimation { target: root; property: "pulse"; from: 1; to: 0; duration: Math.max(1, ThemeEngine.ornamentPulseDuration / 2); easing.type: Easing.InOutSine }
		onStopped: root.pulse = 0
	}

	Canvas {
		id: frame
		anchors.fill: parent
		renderStrategy: Canvas.Cooperative

		function strokeLine(ctx, x1, y1, x2, y2) {
			ctx.beginPath(); ctx.moveTo(x1, y1); ctx.lineTo(x2, y2); ctx.stroke();
		}

		function diamond(ctx, x, y, size, filled) {
			ctx.beginPath();
			ctx.moveTo(x, y - size); ctx.lineTo(x + size, y);
			ctx.lineTo(x, y + size); ctx.lineTo(x - size, y); ctx.closePath();
			if (filled) ctx.fill(); else ctx.stroke();
		}

		function chamferedFrame(ctx, left, top, right, bottom, cut) {
			ctx.beginPath();
			ctx.moveTo(left + cut, top);
			ctx.lineTo(right - cut, top);
			ctx.lineTo(right, top + cut);
			ctx.lineTo(right, bottom - cut);
			ctx.lineTo(right - cut, bottom);
			ctx.lineTo(left + cut, bottom);
			ctx.lineTo(left, bottom - cut);
			ctx.lineTo(left, top + cut);
			ctx.closePath();
			ctx.stroke();
		}

		function chevron(ctx, x, y, sx, sy, size) {
			ctx.beginPath();
			ctx.moveTo(x + sx * size, y);
			ctx.lineTo(x, y + sy * size);
			ctx.lineTo(x + sx * size * 0.48, y + sy * size);
			ctx.stroke();
		}

		onPaint: {
			const ctx = getContext("2d");
			ctx.reset();
			if (!root.active || width < 8 || height < 5) return;

			const inset = Math.max(root.lineWidth, Math.min(root.frameInset, Math.min(width, height) / 4));
			const left = inset, top = inset, right = width - inset, bottom = height - inset;
			const shortSide = Math.min(width, height);
			const notch = Math.min(root.notchSize, Math.max(1.5, shortSide * 0.18));
			ctx.strokeStyle = root.ink;
			ctx.fillStyle = root.ink;
			ctx.lineWidth = root.pressed ? root.lineWidth * 1.35 : root.lineWidth;
			ctx.lineCap = "square";
			ctx.lineJoin = "miter";

			if (root.compact && root.trackCaps) {
				const cy = height / 2;
				const cap = Math.min(height * 0.46, 6.5);
				const gap = Math.max(1.2, height * 0.17);
				ctx.globalAlpha = 0.95;
				strokeLine(ctx, left + cap * 1.25, cy - gap, right - cap * 1.25, cy - gap);
				strokeLine(ctx, left + cap * 1.25, cy + gap, right - cap * 1.25, cy + gap);
				diamond(ctx, left + cap, cy, cap, false);
				diamond(ctx, right - cap, cy, cap, false);
				diamond(ctx, left + cap, cy, Math.max(1.2, cap * 0.28), true);
				diamond(ctx, right - cap, cy, Math.max(1.2, cap * 0.28), true);
				if (width > 58) {
					ctx.globalAlpha = 0.58;
					chevron(ctx, left + cap * 1.7, cy - gap, 1, -1, Math.min(4, cap * 0.7));
					chevron(ctx, right - cap * 1.7, cy + gap, -1, 1, Math.min(4, cap * 0.7));
				}
				if (root.centerMarks && width > 48) {
					ctx.globalAlpha = 1;
					diamond(ctx, width / 2, cy, Math.min(3.5, cap * 0.72), false);
					diamond(ctx, width / 2, cy, Math.min(1.6, cap * 0.32), true);
				}
				return;
			}

			const len = Math.min(root.cornerLength, Math.max(5, Math.min(width, height) * 0.34));
			const cut = Math.min(notch, len * 0.45);
			const enoughForFrame = width > cut * 4 + 12 && height > cut * 2 + 10;

			// The outer silhouette is a complete eight-sided engraved frame. It is
			// deliberately geometric so the underlying palette remains the theme's
			// only source of visual color.
			if (enoughForFrame) {
				ctx.globalAlpha = 0.82;
				chamferedFrame(ctx, left, top, right, bottom, cut);
			}

			function corner(sx, sy) {
				const x = sx < 0 ? left : right;
				const y = sy < 0 ? top : bottom;
				ctx.globalAlpha = 1;
				ctx.beginPath();
				ctx.moveTo(x, y + sy * len * 1.12);
				ctx.lineTo(x, y + sy * cut);
				ctx.lineTo(x + sx * cut, y);
				ctx.lineTo(x + sx * len * 1.12, y);
				ctx.stroke();
				if (len > 9) {
					ctx.globalAlpha = 0.72;
					ctx.beginPath();
					ctx.moveTo(x + sx * (cut + 2), y + sy * 1.5);
					ctx.quadraticCurveTo(x + sx * (cut + 3), y + sy * (cut + 3), x + sx * 1.5, y + sy * (cut + 2));
					ctx.stroke();
					chevron(ctx, x + sx * (cut + 3), y + sy * (cut + 3), sx, sy, Math.min(5, len * 0.28));
					ctx.globalAlpha = 0.92;
					diamond(ctx, x + sx * (cut + 3), y + sy * (cut + 3), Math.min(2.2, len * 0.12), true);
				}
			}
			corner(1, 1); corner(-1, 1); corner(1, -1); corner(-1, -1);

			if (root.doubleLine && width > 34 && height > 22) {
				const inner = inset + Math.max(3, root.lineWidth * 3);
				const il = inner, it = inner, ir = width - inner, ib = height - inner;
				ctx.globalAlpha = 0.48;
				chamferedFrame(ctx, il, it, ir, ib, Math.max(2, cut * 0.72));
			}

			if (root.centerMarks && width > 72) {
				const mark = Math.min(5, Math.max(2.5, height * 0.065));
				const wing = Math.min(18, Math.max(7, width * 0.065));
				ctx.globalAlpha = 0.95;
				diamond(ctx, width / 2, top, mark, false);
				diamond(ctx, width / 2, bottom, mark, false);
				diamond(ctx, width / 2, top, Math.max(1.2, mark * 0.32), true);
				diamond(ctx, width / 2, bottom, Math.max(1.2, mark * 0.32), true);
				ctx.globalAlpha = 0.68;
				strokeLine(ctx, width / 2 - wing, top, width / 2 - mark, top);
				strokeLine(ctx, width / 2 + mark, top, width / 2 + wing, top);
				strokeLine(ctx, width / 2 - wing, bottom, width / 2 - mark, bottom);
				strokeLine(ctx, width / 2 + mark, bottom, width / 2 + wing, bottom);
			}

			if (root.centerMarks && height > 54) {
				const sideMark = Math.min(4, Math.max(2, width * 0.012));
				ctx.globalAlpha = 0.72;
				diamond(ctx, left, height / 2, sideMark, false);
				diamond(ctx, right, height / 2, sideMark, false);
				strokeLine(ctx, left, height / 2 - sideMark - 10, left, height / 2 - sideMark);
				strokeLine(ctx, left, height / 2 + sideMark, left, height / 2 + sideMark + 10);
				strokeLine(ctx, right, height / 2 - sideMark - 10, right, height / 2 - sideMark);
				strokeLine(ctx, right, height / 2 + sideMark, right, height / 2 + sideMark + 10);
			}

			// Sparse rune-like cuts and corner hatching make large cards read as
			// engraved material instead of a plain rectangle.
			if (width > 150 && height > 64) {
				ctx.globalAlpha = 0.28;
				const runeSpan = Math.min(54, width * 0.18);
				for (let i = -2; i <= 2; i += 1) {
					const rx = width / 2 + i * runeSpan / 4;
					if (i !== 0) {
						strokeLine(ctx, rx - 2, top + 1, rx + 2, top + 5);
						strokeLine(ctx, rx - 2, bottom - 1, rx + 2, bottom - 5);
					}
				}
				const hatch = Math.min(12, len * 0.65);
				for (let i = 0; i < 3; i += 1) {
					const shift = i * 3.5;
					strokeLine(ctx, left + cut + shift, top + 2, left + cut + hatch + shift, top + 2);
					strokeLine(ctx, right - cut - shift, bottom - 2, right - cut - hatch - shift, bottom - 2);
				}
			}
			ctx.globalAlpha = 1;
		}
	}

	// A small animated crest gives interactive buttons and cards a jewel-like
	// focus point. It uses the same derived edge tone as the engraved frame.
	Item {
		id: crest
		visible: root.active && root.centerMarks && !root.compact && root.width > 72 && root.height > 24
		width: 12
		height: 12
		anchors.horizontalCenter: parent.horizontalCenter
		y: Math.max(0, root.frameInset - height / 2)
		scale: 1 + root.pulse * 0.32
		rotation: root.pressed ? 90 : 45
		opacity: 0.72 + root.pulse * 0.28

		Behavior on rotation {
			NumberAnimation { duration: ThemeEngine.normal; easing.type: ThemeEngine.emphasizedEasing }
		}

		Rectangle {
			anchors.fill: parent
			color: "transparent"
			border.width: Math.max(1, root.lineWidth)
			border.color: root.ink
		}

		Rectangle {
			width: 4
			height: 4
			anchors.centerIn: parent
			color: root.ink
		}
	}

	Repeater {
		model: 2

		delegate: Item {
			required property int index
			readonly property bool leftSide: index === 0
			visible: root.active && root.centerMarks && !root.compact
				&& root.width > 52 && root.height > 30
			width: 13
			height: 24
			x: leftSide ? -3 : root.width - width + 3
			y: (root.height - height) / 2
			opacity: 0.64 + root.pulse * 0.3
			scale: root.pressed ? 0.82 : 1 + root.pulse * 0.12

			Rectangle {
				width: 9
				height: 9
				anchors.centerIn: parent
				rotation: 45
				color: root.surfaceColor
				border.width: Math.max(1, root.lineWidth)
				border.color: root.ink
			}

			Rectangle {
				width: 3
				height: 3
				anchors.centerIn: parent
				rotation: 45
				color: root.ink
			}

			Rectangle {
				width: 8
				height: Math.max(1, root.lineWidth)
				anchors.verticalCenter: parent.verticalCenter
				x: leftSide ? 5 : 0
				color: root.ink
			}

			Rectangle {
				width: 5
				height: 5
				anchors.horizontalCenter: parent.horizontalCenter
				y: 1
				rotation: 45
				color: "transparent"
				border.width: Math.max(1, root.lineWidth * 0.8)
				border.color: root.ink
			}

			Rectangle {
				width: 5
				height: 5
				anchors.horizontalCenter: parent.horizontalCenter
				y: parent.height - height - 1
				rotation: 45
				color: "transparent"
				border.width: Math.max(1, root.lineWidth * 0.8)
				border.color: root.ink
			}
		}
	}
}
