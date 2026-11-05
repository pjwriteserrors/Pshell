import QtQuick
import qs.style.theme
import qs.style.widgets

// A value over the last minutes that scrolls on smoothly as each sample
// comes in: the first series as a filled area, the others as lines over it.
// The scale follows the peak instead of jumping (or stays at `maximum`), it
// draws in from the left when it first shows, and the pointer reads off a
// moment.
Item {
	id: root

	// [[values], …] newest last, all the same length
	property var series: []
	property var colors: [Theme.primary]
	// a fixed top of the scale (1 for shares); 0 follows the peak
	property real maximum: 0
	property real minimumScale: 1
	// how many samples the width spans
	property int span: 120
	property bool fill: true
	property real lineWidth: 2
	property bool guides: true
	property bool readout: true
	property real stepSeconds: 1
	// how a value is said on the guides and the readout
	property var format: value => `${Math.round(value * 100)}%`
	property var names: []

	readonly property real peak: {
		if (root.maximum > 0) return root.maximum;
		let top = 0;
		for (const values of root.series ?? []) {
			for (const value of values ?? []) top = Math.max(top, Number(value) || 0);
		}
		return root.niceCeiling(Math.max(top, root.minimumScale));
	}
	property real scale_: root.peak
	property real shift: 0
	property real reveal: 0
	property real pointer: -1
	property var last: []

	Behavior on scale_ {
		NumberAnimation {
			duration: 700
			easing.type: Easing.OutCubic
		}
	}

	onScale_Changed: canvas.requestPaint()
	onShiftChanged: canvas.requestPaint()
	onRevealChanged: canvas.requestPaint()
	onPointerChanged: canvas.requestPaint()
	onColorsChanged: canvas.requestPaint()
	onWidthChanged: canvas.requestPaint()
	onHeightChanged: canvas.requestPaint()
	Component.onCompleted: drawIn.restart()

	// per curve, the sample that just fell out on the left: drawn just past
	// the edge while the line slides, so a full graph runs on without its
	// left end snapping back each tick
	property var heads: []
	property var lastAll: []

	onSeriesChanged: {
		const all = root.series ?? [];
		const now = all[0] ?? [];
		const before = root.last;
		const shifted = before.length > 1 && now.length > 1 && now.length === before.length && now[now.length - 2] === before[before.length - 1];
		root.heads = shifted ? all.map((values, s) => root.lastAll[s]?.[0]) : [];
		root.last = now.slice();
		root.lastAll = all.map(values => (values ?? []).slice(0, 1));
		// one more sample: slide in instead of jumping
		if (before.length > 1 && now.length > 1 && root.visible && (now.length > before.length || shifted))
			slide.restart();
		canvas.requestPaint();
	}

	function niceCeiling(value) {
		if (value <= 0) return 1;
		const exponent = Math.pow(10, Math.floor(Math.log10(value)));
		for (const factor of [1, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10]) {
			if (exponent * factor >= value) return exponent * factor;
		}
		return exponent * 10;
	}

	NumberAnimation {
		id: slide

		target: root
		property: "shift"
		from: 1
		to: 0
		duration: Math.max(300, root.stepSeconds * 1000)
	}

	NumberAnimation {
		id: drawIn

		target: root
		property: "reveal"
		from: 0
		to: 1
		duration: 900
		easing.type: Easing.OutCubic
	}

	Repeater {
		model: root.guides ? [1, 0.5] : []

		StyledText {
			required property real modelData

			x: 6
			y: canvas.y + canvas.height * (1 - modelData) + 2
			text: root.format(root.scale_ * modelData)
			font.pixelSize: Theme.size.tiny
			tone: Theme.textSubtle
			tabular: true
		}
	}

	Canvas {
		id: canvas

		anchors.fill: parent
		anchors.topMargin: root.guides ? 4 : 1
		renderStrategy: Canvas.Cooperative

		onPaint: {
			const ctx = getContext("2d");
			ctx.reset();
			const w = width;
			const h = height;
			if (w <= 0 || h <= 0) return;
			if (root.guides) {
				ctx.strokeStyle = Theme.outline;
				ctx.lineWidth = 1;
				ctx.setLineDash([3, 4]);
				for (const level of [0.5, 1]) {
					const y = Math.round(h * (1 - level)) + 0.5;
					ctx.beginPath();
					ctx.moveTo(0, y);
					ctx.lineTo(w, y);
					ctx.stroke();
				}
				ctx.setLineDash([]);
			}
			const step = w / Math.max(1, root.span - 1);
			const top = Math.max(1e-9, root.scale_);
			const reveal = root.reveal;
			ctx.save();
			ctx.beginPath();
			ctx.rect(0, 0, w * reveal, h);
			ctx.clip();
			const list = root.series ?? [];
			for (let s = list.length - 1; s >= 0; s -= 1) {
				const head = root.shift > 0 ? root.heads[s] : undefined;
				const values = head !== undefined ? [head].concat(list[s] ?? []) : (list[s] ?? []);
				if (values.length < 2) continue;
				const color = root.colors[s] ?? root.colors[0] ?? Theme.primary;
				const n = values.length;
				// with the head one more point: it lands a step left of the line
				const offset = (root.span - n + root.shift) * step;
				const point = i => [offset + i * step, h - Math.max(0, Math.min(1, (Number(values[i]) || 0) / top)) * (h - root.lineWidth) - root.lineWidth / 2];
				ctx.beginPath();
				const first = point(0);
				ctx.moveTo(first[0], first[1]);
				for (let i = 1; i < n; i += 1) {
					const prev = point(i - 1);
					const cur = point(i);
					const mid = (prev[0] + cur[0]) / 2;
					ctx.bezierCurveTo(mid, prev[1], mid, cur[1], cur[0], cur[1]);
				}
				ctx.strokeStyle = color;
				ctx.lineWidth = s === 0 ? root.lineWidth : Math.max(1.2, root.lineWidth - 0.5);
				ctx.lineJoin = "round";
				ctx.stroke();
				if (root.fill && s === 0) {
					const lastPoint = point(n - 1);
					ctx.lineTo(lastPoint[0], h);
					ctx.lineTo(first[0], h);
					ctx.closePath();
					const gradient = ctx.createLinearGradient(0, 0, 0, h);
					gradient.addColorStop(0, Qt.alpha(color, 0.32));
					gradient.addColorStop(1, Qt.alpha(color, 0.02));
					ctx.fillStyle = gradient;
					ctx.fill();
				}
			}
			ctx.restore();
			if (root.pointer >= 0 && list.length > 0) {
				const values = list[0] ?? [];
				const n = values.length;
				const offset = (root.span - n + root.shift) * step;
				const index = Math.round((root.pointer - offset) / step);
				if (index >= 0 && index < n) {
					const x = offset + index * step;
					ctx.strokeStyle = Qt.alpha(Theme.text, 0.35);
					ctx.lineWidth = 1;
					ctx.beginPath();
					ctx.moveTo(Math.round(x) + 0.5, 0);
					ctx.lineTo(Math.round(x) + 0.5, h);
					ctx.stroke();
					for (let s = 0; s < list.length; s += 1) {
						const value = Number(list[s]?.[index]) || 0;
						const y = h - Math.max(0, Math.min(1, value / top)) * (h - root.lineWidth) - root.lineWidth / 2;
						ctx.fillStyle = root.colors[s] ?? root.colors[0];
						ctx.beginPath();
						ctx.arc(x, y, 3.5, 0, Math.PI * 2);
						ctx.fill();
					}
				}
			}
		}
	}

	HoverHandler {
		id: hover

		enabled: root.readout
		onPointChanged: root.pointer = hover.hovered ? hover.point.position.x : -1
		onHoveredChanged: if (!hover.hovered) root.pointer = -1
	}

	// what the pointer reads off
	Rectangle {
		readonly property var values: root.series?.[0] ?? []
		readonly property real step: canvas.width / Math.max(1, root.span - 1)
		readonly property int index: Math.round((root.pointer - (root.span - values.length + root.shift) * step) / step)
		readonly property bool shows: root.pointer >= 0 && index >= 0 && index < values.length

		visible: opacity > 0
		opacity: shows ? 1 : 0
		x: Math.max(4, Math.min(root.width - width - 4, root.pointer - width / 2))
		y: 4
		width: tip.implicitWidth + 16
		height: tip.implicitHeight + 8
		radius: Theme.radius.small
		color: Theme.layer3

		Behavior on opacity {
			Anim {
				duration: Motion.short
			}
		}

		StyledText {
			id: tip

			anchors.centerIn: parent
			font.pixelSize: Theme.size.small
			tabular: true
			text: {
				if (!parent.shows) return "";
				const ago = Math.round((parent.values.length - 1 - parent.index) * root.stepSeconds);
				const parts = (root.series ?? []).map((values, s) => `${root.names[s] ? `${root.names[s]} ` : ""}${root.format(Number(values?.[parent.index]) || 0)}`);
				return `${parts.join("  ·  ")}   ${ago === 0 ? "now" : `${ago} s ago`}`;
			}
		}
	}
}
