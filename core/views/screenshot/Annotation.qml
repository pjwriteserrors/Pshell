pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Shapes
import QtQuick.Effects
import qs.style.theme

// One annotation of the screenshot editor, drawn in image pixel coordinates
// so the export keeps native resolution. `spec` is a plain object:
//   { type, color, size, opacity, fill, points | x1 y1 x2 y2 | x y text fontSize | n }
// Pixelate, blur and the magnifier sample `source` (the untouched screenshot).
//   magnifier: x1 y1 source spot, x2 y2 loupe centre, r loupe radius, zoom
//   measure: x1 y1 x2 y2, fontSize, box (W × H instead of a line)
//   erase: x1 y1 x2 y2, edges { top, bottom, left, right } colour profiles
// Spotlights draw nothing here: the editor dims around all of them at once.
Item {
	id: root

	property var spec: null
	property Item source: null
	property real dx: 0
	property real dy: 0

	readonly property string type: root.spec?.type ?? ""
	readonly property color tint: root.spec?.color ?? "#ef4444"
	readonly property real size: Number(root.spec?.size ?? 4)
	readonly property real alpha: Number(root.spec?.opacity ?? 1)
	readonly property bool filled: !!root.spec?.fill
	readonly property real boxX: Math.min(root.spec?.x1 ?? 0, root.spec?.x2 ?? 0)
	readonly property real boxY: Math.min(root.spec?.y1 ?? 0, root.spec?.y2 ?? 0)
	readonly property real boxWidth: Math.abs((root.spec?.x2 ?? 0) - (root.spec?.x1 ?? 0))
	readonly property real boxHeight: Math.abs((root.spec?.y2 ?? 0) - (root.spec?.y1 ?? 0))

	// the magnifier moves only its loupe
	x: root.type === "magnifier" ? 0 : root.dx
	y: root.type === "magnifier" ? 0 : root.dy

	function contrastOn(c) {
		const lum = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;
		return lum > 0.6 ? "#111111" : "#ffffff";
	}

	// quadratic smoothing through the midpoints of the recorded points
	function smoothPath(points, ox, oy) {
		if (!points || points.length === 0) return "";
		const p = points.map(v => [v[0] - ox, v[1] - oy]);
		if (p.length === 1) return `M ${p[0][0]} ${p[0][1]} L ${p[0][0] + 0.01} ${p[0][1]}`;
		let d = `M ${p[0][0]} ${p[0][1]}`;
		for (let i = 1; i < p.length - 1; i += 1) {
			const mx = (p[i][0] + p[i + 1][0]) / 2;
			const my = (p[i][1] + p[i + 1][1]) / 2;
			d += ` Q ${p[i][0]} ${p[i][1]} ${mx} ${my}`;
		}
		const last = p[p.length - 1];
		return `${d} L ${last[0]} ${last[1]}`;
	}

	Loader {
		active: root.spec !== null
		sourceComponent: {
			switch (root.type) {
			case "brush":
			case "marker":
				return strokeComp;
			case "line":
				return lineComp;
			case "arrow":
				return arrowComp;
			case "rect":
				return rectComp;
			case "ellipse":
				return ellipseComp;
			case "text":
				return textComp;
			case "step":
				return stepComp;
			case "pixelate":
				return pixelComp;
			case "blur":
				return blurComp;
			case "magnifier":
				return magnifierComp;
			case "measure":
				return root.spec.box ? boxMeasureComp : measureComp;
			case "erase":
				return eraseComp;
			}
			return null;
		}
	}

	// ── freehand brush and highlighter ─────────────────────────────────────
	Component {
		id: strokeComp

		Shape {
			id: stroke

			readonly property bool marker: root.type === "marker"
			readonly property real width_: stroke.marker ? Math.max(10, root.size * 3.5) : root.size
			readonly property var pts: root.spec.points ?? []
			readonly property real minX: Math.min(...stroke.pts.map(p => p[0])) - stroke.width_
			readonly property real minY: Math.min(...stroke.pts.map(p => p[1])) - stroke.width_
			readonly property real maxX: Math.max(...stroke.pts.map(p => p[0])) + stroke.width_
			readonly property real maxY: Math.max(...stroke.pts.map(p => p[1])) + stroke.width_

			x: stroke.minX
			y: stroke.minY
			width: Math.max(1, stroke.maxX - stroke.minX)
			height: Math.max(1, stroke.maxY - stroke.minY)
			preferredRendererType: Shape.CurveRenderer
			opacity: root.alpha * (stroke.marker ? 0.42 : 1)
			layer.enabled: stroke.opacity < 1

			ShapePath {
				strokeColor: root.tint
				strokeWidth: stroke.width_
				fillColor: "transparent"
				capStyle: stroke.marker ? ShapePath.SquareCap : ShapePath.RoundCap
				joinStyle: ShapePath.RoundJoin

				PathSvg {
					path: root.smoothPath(stroke.pts, stroke.minX, stroke.minY)
				}
			}
		}
	}

	// ── straight line ──────────────────────────────────────────────────────
	Component {
		id: lineComp

		Shape {
			id: line

			readonly property real pad: root.size
			x: root.boxX - line.pad
			y: root.boxY - line.pad
			width: root.boxWidth + line.pad * 2
			height: root.boxHeight + line.pad * 2
			preferredRendererType: Shape.CurveRenderer
			opacity: root.alpha
			layer.enabled: root.alpha < 1

			ShapePath {
				strokeColor: root.tint
				strokeWidth: root.size
				fillColor: "transparent"
				capStyle: ShapePath.RoundCap
				startX: root.spec.x1 - line.x
				startY: root.spec.y1 - line.y

				PathLine {
					x: root.spec.x2 - line.x
					y: root.spec.y2 - line.y
				}
			}
		}
	}

	// ── arrow: shaft plus a filled head that grows with the stroke ─────────
	Component {
		id: arrowComp

		Shape {
			id: arrow

			readonly property real ddx: root.spec.x2 - root.spec.x1
			readonly property real ddy: root.spec.y2 - root.spec.y1
			readonly property real len: Math.max(0.001, Math.sqrt(arrow.ddx * arrow.ddx + arrow.ddy * arrow.ddy))
			readonly property real ux: arrow.ddx / arrow.len
			readonly property real uy: arrow.ddy / arrow.len
			readonly property real head: Math.min(arrow.len * 0.6, Math.max(16, root.size * 3.6))
			readonly property real halfWidth: arrow.head * 0.52
			readonly property real pad: arrow.head
			readonly property real baseX: root.spec.x2 - arrow.ux * arrow.head * 0.82
			readonly property real baseY: root.spec.y2 - arrow.uy * arrow.head * 0.82

			x: root.boxX - arrow.pad
			y: root.boxY - arrow.pad
			width: root.boxWidth + arrow.pad * 2
			height: root.boxHeight + arrow.pad * 2
			preferredRendererType: Shape.CurveRenderer
			opacity: root.alpha
			layer.enabled: root.alpha < 1

			ShapePath {
				strokeColor: root.tint
				strokeWidth: root.size
				fillColor: "transparent"
				capStyle: ShapePath.RoundCap
				startX: root.spec.x1 - arrow.x
				startY: root.spec.y1 - arrow.y

				PathLine {
					x: arrow.baseX - arrow.x
					y: arrow.baseY - arrow.y
				}
			}

			ShapePath {
				strokeColor: root.tint
				strokeWidth: Math.max(1, root.size * 0.5)
				fillColor: root.tint
				joinStyle: ShapePath.RoundJoin
				startX: root.spec.x2 - arrow.x
				startY: root.spec.y2 - arrow.y

				PathLine {
					x: root.spec.x2 - arrow.ux * arrow.head - arrow.uy * arrow.halfWidth - arrow.x
					y: root.spec.y2 - arrow.uy * arrow.head + arrow.ux * arrow.halfWidth - arrow.y
				}
				PathLine {
					x: root.spec.x2 - arrow.ux * arrow.head + arrow.uy * arrow.halfWidth - arrow.x
					y: root.spec.y2 - arrow.uy * arrow.head - arrow.ux * arrow.halfWidth - arrow.y
				}
				PathLine {
					x: root.spec.x2 - arrow.x
					y: root.spec.y2 - arrow.y
				}
			}
		}
	}

	// ── rectangle ──────────────────────────────────────────────────────────
	Component {
		id: rectComp

		Rectangle {
			x: root.boxX
			y: root.boxY
			width: root.boxWidth
			height: root.boxHeight
			radius: Math.min(root.size * 0.6, 6, width / 2, height / 2)
			color: root.filled ? root.tint : "transparent"
			border.width: root.filled ? 0 : root.size
			border.color: root.tint
			antialiasing: true
			opacity: root.alpha
			layer.enabled: root.alpha < 1
		}
	}

	// ── ellipse ────────────────────────────────────────────────────────────
	Component {
		id: ellipseComp

		Shape {
			id: ellipse

			x: root.boxX - root.size
			y: root.boxY - root.size
			width: root.boxWidth + root.size * 2
			height: root.boxHeight + root.size * 2
			preferredRendererType: Shape.CurveRenderer
			opacity: root.alpha
			layer.enabled: root.alpha < 1

			ShapePath {
				strokeColor: root.filled ? "transparent" : root.tint
				strokeWidth: root.filled ? 0 : root.size
				fillColor: root.filled ? root.tint : "transparent"

				PathAngleArc {
					centerX: ellipse.width / 2
					centerY: ellipse.height / 2
					radiusX: Math.max(0.5, root.boxWidth / 2 - (root.filled ? 0 : root.size / 2))
					radiusY: Math.max(0.5, root.boxHeight / 2 - (root.filled ? 0 : root.size / 2))
					startAngle: 0
					sweepAngle: 360
				}
			}
		}
	}

	// ── text (fill puts it on a solid label) ───────────────────────────────
	Component {
		id: textComp

		Item {
			readonly property real pad: root.filled ? Math.round(root.spec.fontSize * 0.28) : 0

			x: root.spec.x - pad
			y: root.spec.y - pad
			width: label.implicitWidth + pad * 2
			height: label.implicitHeight + pad * 2
			opacity: root.alpha
			layer.enabled: root.alpha < 1

			Rectangle {
				anchors.fill: parent
				visible: root.filled
				radius: parent.pad
				color: root.tint
			}

			Text {
				id: label

				x: parent.pad
				y: parent.pad
				text: root.spec.text
				color: root.filled ? root.contrastOn(root.tint) : root.tint
				font.family: Theme.fontFamily
				font.pixelSize: root.spec.fontSize
				font.weight: Font.DemiBold
				textFormat: Text.PlainText
			}
		}
	}

	// ── numbered step marker ───────────────────────────────────────────────
	Component {
		id: stepComp

		Rectangle {
			readonly property real diameter: Math.max(22, root.spec.fontSize * 1.45)

			x: root.spec.x - diameter / 2
			y: root.spec.y - diameter / 2
			width: diameter
			height: diameter
			radius: diameter / 2
			color: root.tint
			border.width: Math.max(2, diameter * 0.07)
			border.color: Qt.alpha(root.contrastOn(root.tint), 0.9)
			antialiasing: true
			opacity: root.alpha
			layer.enabled: root.alpha < 1

			Text {
				anchors.centerIn: parent
				text: String(root.spec.n)
				color: root.contrastOn(root.tint)
				font.family: Theme.fontFamily
				font.pixelSize: parent.diameter * 0.52
				font.weight: Font.Bold
				font.features: { "tnum": 1 }
			}
		}
	}

	// ── pixelate: the region rendered into a tiny texture, scaled up sharp ─
	Component {
		id: pixelComp

		Item {
			readonly property real block: Math.max(8, root.size * 3)

			x: root.boxX
			y: root.boxY
			width: Math.max(1, root.boxWidth)
			height: Math.max(1, root.boxHeight)
			clip: true

			ShaderEffectSource {
				anchors.fill: parent
				sourceItem: root.source
				sourceRect: Qt.rect(root.boxX + root.dx, root.boxY + root.dy, parent.width, parent.height)
				textureSize: Qt.size(Math.max(1, Math.round(parent.width / parent.block)), Math.max(1, Math.round(parent.height / parent.block)))
				smooth: false
				live: true
				recursive: false
			}
		}
	}

	// ── blur ───────────────────────────────────────────────────────────────
	Component {
		id: blurComp

		Item {
			id: blurBox

			readonly property real pad: 48

			x: root.boxX
			y: root.boxY
			width: Math.max(1, root.boxWidth)
			height: Math.max(1, root.boxHeight)
			clip: true

			ShaderEffectSource {
				id: blurSource

				width: blurBox.width + blurBox.pad * 2
				height: blurBox.height + blurBox.pad * 2
				visible: false
				sourceItem: root.source
				sourceRect: Qt.rect(root.boxX + root.dx - blurBox.pad, root.boxY + root.dy - blurBox.pad, blurSource.width, blurSource.height)
				live: true
				recursive: false
			}

			MultiEffect {
				x: -blurBox.pad
				y: -blurBox.pad
				width: blurSource.width
				height: blurSource.height
				source: blurSource
				autoPaddingEnabled: false
				blurEnabled: true
				blur: 1
				blurMax: 64
				blurMultiplier: 0.6 + root.size * 0.08
			}
		}
	}

	// ── magnifier: round loupe with an enlarged copy of the source spot ────
	Component {
		id: magnifierComp

		Item {
			id: mag

			readonly property real r: Math.max(8, Number(root.spec.r ?? 60))
			readonly property real zoom: Math.max(1, Number(root.spec.zoom ?? 2.5))
			readonly property real sx: root.spec.x1
			readonly property real sy: root.spec.y1
			readonly property real cx: root.spec.x2 + root.dx
			readonly property real cy: root.spec.y2 + root.dy
			readonly property real sr: mag.r / mag.zoom
			readonly property real ring: Math.max(2, root.size)
			readonly property real thin: Math.max(1.5, root.size * 0.45)
			readonly property real ddx: mag.cx - mag.sx
			readonly property real ddy: mag.cy - mag.sy
			readonly property real len: Math.sqrt(mag.ddx * mag.ddx + mag.ddy * mag.ddy)
			readonly property bool apart: mag.len > mag.r + mag.sr + 2

			opacity: root.alpha
			layer.enabled: root.alpha < 1

			// connector from the source ring to the loupe
			Shape {
				visible: mag.apart
				preferredRendererType: Shape.CurveRenderer

				ShapePath {
					strokeColor: root.tint
					strokeWidth: mag.thin
					fillColor: "transparent"
					capStyle: ShapePath.RoundCap
					startX: mag.sx + mag.ddx / Math.max(1, mag.len) * mag.sr
					startY: mag.sy + mag.ddy / Math.max(1, mag.len) * mag.sr

					PathLine {
						x: mag.cx - mag.ddx / Math.max(1, mag.len) * mag.r
						y: mag.cy - mag.ddy / Math.max(1, mag.len) * mag.r
					}
				}
			}

			Rectangle {
				visible: mag.apart
				x: mag.sx - mag.sr
				y: mag.sy - mag.sr
				width: mag.sr * 2
				height: mag.sr * 2
				radius: mag.sr
				color: "transparent"
				border.width: mag.thin
				border.color: root.tint
				antialiasing: true
			}

			RectangularShadow {
				x: mag.cx - mag.r
				y: mag.cy - mag.r + mag.r * 0.06
				width: mag.r * 2
				height: mag.r * 2
				radius: mag.r
				blur: Math.max(8, mag.r * 0.25)
				color: Qt.rgba(0, 0, 0, 0.4)
			}

			Item {
				id: lens

				x: mag.cx - mag.r
				y: mag.cy - mag.r
				width: mag.r * 2
				height: mag.r * 2

				ShaderEffectSource {
					id: zoomed

					anchors.fill: parent
					visible: false
					sourceItem: root.source
					sourceRect: Qt.rect(mag.sx - mag.sr, mag.sy - mag.sr, mag.sr * 2, mag.sr * 2)
					textureSize: Qt.size(Math.ceil(lens.width), Math.ceil(lens.height))
					smooth: true
					live: true
					recursive: false
				}

				Rectangle {
					id: lensMask

					anchors.fill: parent
					radius: width / 2
					visible: false
					layer.enabled: true
					antialiasing: true
				}

				MultiEffect {
					anchors.fill: parent
					source: zoomed
					maskEnabled: true
					maskSource: lensMask
					maskThresholdMin: 0.5
					maskSpreadAtMin: 1
				}

				Rectangle {
					anchors.fill: parent
					radius: width / 2
					color: "transparent"
					border.width: mag.ring
					border.color: root.tint
					antialiasing: true
				}
			}
		}
	}

	// ── measure: a line with end ticks and its length ──────────────────────
	component MeasureLabel: Rectangle {
		id: measureLabel

		property string main: ""
		property string extra: ""

		readonly property real fs: Math.max(8, Number(root.spec?.fontSize ?? 14))

		width: labelRow.implicitWidth + measureLabel.fs * 1.1
		height: measureLabel.fs * 1.9
		radius: height / 2
		color: root.tint
		antialiasing: true

		Row {
			id: labelRow

			anchors.centerIn: parent
			spacing: measureLabel.fs * 0.55

			Text {
				text: measureLabel.main
				color: root.contrastOn(root.tint)
				font.family: Theme.fontFamily
				font.pixelSize: measureLabel.fs
				font.weight: Font.Bold
				font.features: { "tnum": 1 }
			}

			Text {
				visible: text !== ""
				text: measureLabel.extra
				color: root.contrastOn(root.tint)
				opacity: 0.72
				font.family: Theme.fontFamily
				font.pixelSize: measureLabel.fs * 0.86
				font.weight: Font.DemiBold
				font.features: { "tnum": 1 }
			}
		}
	}

	Component {
		id: measureComp

		Item {
			id: ruler

			readonly property real ddx: root.spec.x2 - root.spec.x1
			readonly property real ddy: root.spec.y2 - root.spec.y1
			readonly property real len: Math.sqrt(ruler.ddx * ruler.ddx + ruler.ddy * ruler.ddy)
			readonly property real ux: ruler.len > 0 ? ruler.ddx / ruler.len : 1
			readonly property real uy: ruler.len > 0 ? ruler.ddy / ruler.len : 0
			// normal pointing up (or left for vertical lines)
			readonly property bool flip: -ruler.ux > 0 || (ruler.ux === 0 && ruler.uy > 0)
			readonly property real nx: ruler.flip ? -ruler.uy : ruler.uy
			readonly property real ny: ruler.flip ? ruler.ux : -ruler.ux
			readonly property real stroke: Math.max(1.5, root.size * 0.6)
			readonly property real tick: Math.max(10, root.size * 3)
			readonly property int adx: Math.round(Math.abs(ruler.ddx))
			readonly property int ady: Math.round(Math.abs(ruler.ddy))

			opacity: root.alpha
			layer.enabled: root.alpha < 1

			Shape {
				preferredRendererType: Shape.CurveRenderer

				ShapePath {
					strokeColor: root.tint
					strokeWidth: ruler.stroke
					fillColor: "transparent"
					capStyle: ShapePath.RoundCap
					startX: root.spec.x1
					startY: root.spec.y1

					PathLine {
						x: root.spec.x2
						y: root.spec.y2
					}
					PathMove {
						x: root.spec.x1 + ruler.nx * ruler.tick / 2
						y: root.spec.y1 + ruler.ny * ruler.tick / 2
					}
					PathLine {
						x: root.spec.x1 - ruler.nx * ruler.tick / 2
						y: root.spec.y1 - ruler.ny * ruler.tick / 2
					}
					PathMove {
						x: root.spec.x2 + ruler.nx * ruler.tick / 2
						y: root.spec.y2 + ruler.ny * ruler.tick / 2
					}
					PathLine {
						x: root.spec.x2 - ruler.nx * ruler.tick / 2
						y: root.spec.y2 - ruler.ny * ruler.tick / 2
					}
				}
			}

			MeasureLabel {
				// clear of the line whichever way it runs
				readonly property real off: ruler.tick / 2 + 4 + Math.abs(ruler.nx) * width / 2 + Math.abs(ruler.ny) * height / 2

				main: `${Math.round(ruler.len)} px`
				extra: ruler.adx > 0 && ruler.ady > 0 ? `${ruler.adx} × ${ruler.ady}` : ""
				x: (root.spec.x1 + root.spec.x2) / 2 + ruler.nx * off - width / 2
				y: (root.spec.y1 + root.spec.y2) / 2 + ruler.ny * off - height / 2
			}
		}
	}

	Component {
		id: boxMeasureComp

		Item {
			id: boxMeasure

			readonly property real stroke: Math.max(1.5, root.size * 0.5)

			opacity: root.alpha
			layer.enabled: root.alpha < 1

			Shape {
				x: root.boxX
				y: root.boxY
				width: Math.max(1, root.boxWidth)
				height: Math.max(1, root.boxHeight)
				preferredRendererType: Shape.CurveRenderer

				ShapePath {
					strokeColor: root.tint
					strokeWidth: boxMeasure.stroke
					strokeStyle: ShapePath.DashLine
					dashPattern: [4, 3]
					fillColor: Qt.alpha(root.tint, 0.08)
					startX: 0
					startY: 0

					PathLine { x: root.boxWidth; y: 0 }
					PathLine { x: root.boxWidth; y: root.boxHeight }
					PathLine { x: 0; y: root.boxHeight }
					PathLine { x: 0; y: 0 }
				}
			}

			MeasureLabel {
				readonly property bool inside: root.boxWidth > width + 12 && root.boxHeight > height + 12

				main: `${Math.round(root.boxWidth)} × ${Math.round(root.boxHeight)}`
				x: root.boxX + root.boxWidth / 2 - width / 2
				y: inside ? root.boxY + root.boxHeight / 2 - height / 2 : root.boxY + root.boxHeight + 6
			}
		}
	}

	// ── smart erase: the border colours blended over the region ────────────
	// A small grid is filled by transfinite (Coons) interpolation of the four
	// edge profiles and stretched smoothly over the box.
	Component {
		id: eraseComp

		Item {
			id: erase

			readonly property var edges: root.spec.edges ?? null
			readonly property int gw: Math.max(2, Math.min(64, Math.ceil(root.boxWidth / 8)))
			readonly property int gh: Math.max(2, Math.min(64, Math.ceil(root.boxHeight / 8)))

			x: root.boxX
			y: root.boxY
			width: Math.max(1, root.boxWidth)
			height: Math.max(1, root.boxHeight)
			clip: true

			// still sampling (or just being drawn)
			Rectangle {
				anchors.fill: parent
				visible: erase.edges === null
				color: Qt.rgba(1, 1, 1, 0.18)
				border.width: 1
				border.color: Qt.rgba(0, 0, 0, 0.35)
			}

			Canvas {
				id: grid

				visible: erase.edges !== null
				width: erase.gw
				height: erase.gh
				smooth: true
				transform: Scale {
					xScale: erase.width / erase.gw
					yScale: erase.height / erase.gh
				}

				function at(profile, t) {
					const n = profile.length;
					if (n === 1) return profile[0];
					const f = Math.max(0, Math.min(n - 1, t * (n - 1)));
					const i = Math.min(n - 2, Math.floor(f));
					const k = f - i;
					const a = profile[i];
					const b = profile[i + 1];
					return [a[0] + (b[0] - a[0]) * k, a[1] + (b[1] - a[1]) * k, a[2] + (b[2] - a[2]) * k];
				}

				onPaint: {
					const e = erase.edges;
					if (!e) return;
					const ctx = grid.getContext("2d");
					const w = erase.gw;
					const h = erase.gh;
					// one cell per grid pixel (putImageData draws nothing here)
					ctx.reset();
					const tl = grid.at(e.top, 0).map((v, c) => (v + grid.at(e.left, 0)[c]) / 2);
					const tr = grid.at(e.top, 1).map((v, c) => (v + grid.at(e.right, 0)[c]) / 2);
					const bl = grid.at(e.bottom, 0).map((v, c) => (v + grid.at(e.left, 1)[c]) / 2);
					const br = grid.at(e.bottom, 1).map((v, c) => (v + grid.at(e.right, 1)[c]) / 2);
					const tops = [];
					const bottoms = [];
					for (let x = 0; x < w; x += 1) {
						const u = w > 1 ? x / (w - 1) : 0;
						tops.push(grid.at(e.top, u));
						bottoms.push(grid.at(e.bottom, u));
					}
					for (let y = 0; y < h; y += 1) {
						const v = h > 1 ? y / (h - 1) : 0;
						const l = grid.at(e.left, v);
						const r = grid.at(e.right, v);
						for (let x = 0; x < w; x += 1) {
							const u = w > 1 ? x / (w - 1) : 0;
							const t = tops[x];
							const b = bottoms[x];
							const rgb = [0, 1, 2].map(c => {
								const value = (1 - v) * t[c] + v * b[c] + (1 - u) * l[c] + u * r[c]
									- ((1 - u) * (1 - v) * tl[c] + u * (1 - v) * tr[c] + (1 - u) * v * bl[c] + u * v * br[c]);
								return Math.max(0, Math.min(255, Math.round(value)));
							});
							ctx.fillStyle = `rgb(${rgb[0]},${rgb[1]},${rgb[2]})`;
							ctx.fillRect(x, y, 1, 1);
						}
					}
				}

				onWidthChanged: grid.requestPaint()
				onHeightChanged: grid.requestPaint()
				Component.onCompleted: grid.requestPaint()

				Connections {
					target: erase

					function onEdgesChanged() {
						grid.requestPaint();
					}
				}
			}
		}
	}
}
