pragma ComponentBehavior: Bound

import QtQuick
import "ArcInk.js" as Ink

// A pane of glass hanging in the void.
//
// It has no frame. The only line it gets is the light caught along its upper
// edge, brightest in the middle and running out at both ends — everywhere else
// the pane simply stops being dark. Large panes also carry the four corner
// marks a conjuring leaves behind, which are two short strokes that do not
// meet; there is nothing along the edges between them.
//
// That absence is the style. A box drawn round a thing is a thing somebody
// manufactured, and nothing in this sanctum was.
//
//   chamber  a full pane: fill, upper light, corner marks
//   plate    a tile: fill and upper light, nothing else
//   capsule  a channel of light for a reading to run along
//   field    a fill and a hairline, for a cell that is only a background
Item {
	id: pane

	property string variant: "chamber"

	property color lineColor: Arc.goldDim
	property color liveColor: Arc.aether
	property color fillTop: "transparent"
	property color fillBottom: "transparent"
	property real weight: Arc.rule
	property real inset: 0

	// 0 at rest, 1 when the pane is live. Only ever an opacity.
	property real intensity: 0
	property bool crest: variant === "chamber"
	property bool beading: true

	// There is no frame to keep clear of, so content may go anywhere; the
	// corner marks are the only thing that wants a little air.
	readonly property real cornerReach: variant === "chamber" ? Math.min(22, Math.min(width, height) * 0.14) : 0
	readonly property real railHeight: 0
	readonly property real innerMargin: cornerReach * 0.5

	onLineColorChanged: glassLayer.requestPaint()
	onFillTopChanged: glassLayer.requestPaint()
	onFillBottomChanged: glassLayer.requestPaint()
	onLiveColorChanged: liveLayer.requestPaint()
	onWeightChanged: repaint()
	onVariantChanged: repaint()
	onCrestChanged: repaint()
	onBeadingChanged: repaint()

	function repaint() {
		glassLayer.requestPaint();
		liveLayer.requestPaint();
	}

	function paintGlass(ctx, w, h) {
		if (pane.fillTop.a > 0.004 || pane.fillBottom.a > 0.004) {
			const body = ctx.createLinearGradient(0, 0, 0, h);
			body.addColorStop(0, pane.fillTop);
			body.addColorStop(1, pane.fillBottom);
			ctx.fillStyle = body;
			ctx.fillRect(pane.inset, pane.inset, w - pane.inset * 2, h - pane.inset * 2);
		}

		if (pane.variant === "capsule") {
			// A channel is a line, not a tube: the light runs in it and the
			// track is only there so the light has somewhere to be.
			Ink.ley(ctx, pane.inset, h / 2, w - pane.inset, h / 2,
				Math.max(1, pane.weight), pane.lineColor, null, -1);
			return;
		}

		if (!pane.beading) return;
		Ink.paneEdge(ctx, pane.inset, pane.inset, w - pane.inset * 2,
			pane.lineColor, Qt.alpha(pane.lineColor, 0), 1);
	}

	Canvas {
		id: glassLayer
		anchors.fill: parent
		renderStrategy: Canvas.Cooperative

		onPaint: {
			const ctx = getContext("2d");
			ctx.reset();
			if (width <= 2 || height <= 2) return;
			pane.paintGlass(ctx, width, height);
			if (pane.crest && pane.cornerReach > 4)
				Ink.corners(ctx, pane.inset + 1, pane.inset + 1,
					width - pane.inset * 2 - 2, height - pane.inset * 2 - 2,
					pane.cornerReach, pane.weight, Arc.goldFaint);
		}
	}

	// What the pane looks like when it is live. Never a second border: the
	// upper light brightens and the corner marks take the live colour.
	Canvas {
		id: liveLayer
		anchors.fill: parent
		renderStrategy: Canvas.Cooperative
		opacity: pane.intensity
		visible: opacity > 0.004

		Behavior on opacity {
			NumberAnimation {
				duration: Arc.turn
				easing.type: Easing.Bezier
				easing.bezierCurve: Arc.curveKindle
			}
		}

		onPaint: {
			const ctx = getContext("2d");
			ctx.reset();
			if (width <= 2 || height <= 2) return;
			if (pane.variant === "capsule") {
				Ink.ley(ctx, pane.inset, height / 2, width - pane.inset, height / 2,
					Math.max(1, pane.weight * 1.4), pane.liveColor, null, -1);
				return;
			}
			if (pane.beading)
				Ink.paneEdge(ctx, pane.inset, pane.inset, width - pane.inset * 2,
					pane.liveColor, Qt.alpha(pane.liveColor, 0), 1);
			if (pane.crest && pane.cornerReach > 4)
				Ink.corners(ctx, pane.inset + 1, pane.inset + 1,
					width - pane.inset * 2 - 2, height - pane.inset * 2 - 2,
					pane.cornerReach, pane.weight * 1.3, pane.liveColor);
		}
	}
}
