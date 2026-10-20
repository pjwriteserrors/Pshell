import QtQuick
import qs.style.theme
import qs.style.widgets
import qs.core.services

// Download and upload rate over time: the download as a filled area, the
// upload as a line over it. "live" takes one sample a second ([[down, up]])
// and scrolls on smoothly as each comes in; "whole" is the download from
// start to end ([[unix, down, up, progress]]) with the progress as a thin
// rising line on a scale of its own. The scale follows the peak instead of
// jumping, the pointer reads off a moment.
Item {
	id: root

	// "live" | "whole"
	property string mode: "live"
	property var samples: []
	property color downColor: Theme.primary
	property color upColor: Torrents.upColor
	// seconds the live view spans
	property int span: 180

	readonly property real peak: {
		let top = 0;
		const list = root.samples || [];
		for (const sample of list) {
			const down = root.mode === "live" ? sample[0] : sample[1];
			const up = root.mode === "live" ? sample[1] : sample[2];
			top = Math.max(top, Number(down) || 0, Number(up) || 0);
		}
		return root.niceCeiling(Math.max(top, 64 * 1024));
	}
	property real scale_: root.peak
	// 1 → 0 while the newest sample slides in from the right
	property real shift: 0
	property var last: []
	// where the pointer is over the chart, -1 when it is not
	property real pointer: -1
	// draws in from the left when the mode changes or the chart first shows
	property real reveal: 1

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
	onDownColorChanged: canvas.requestPaint()
	onModeChanged: drawIn.restart()
	Component.onCompleted: drawIn.restart()

	onSamplesChanged: {
		const now = root.samples || [];
		const before = root.last;
		root.last = now;
		// moved on by one second: slide instead of jumping
		const same = (a, b) => a && b && a[0] === b[0] && a[1] === b[1];
		const moved = before.length > 0 && now.length >= 2 && (now.length !== before.length || !same(now[0], before[0]) || !same(now[now.length - 1], before[before.length - 1]))
			&& same(now[now.length - 2], before[before.length - 1]);
		if (root.mode === "live" && moved) slide.restart();
		canvas.requestPaint();
	}

	function niceCeiling(value) {
		const exponent = Math.pow(2, Math.ceil(Math.log2(value)));
		for (const factor of [0.5, 0.625, 0.75, 1]) {
			if (exponent * factor >= value) return exponent * factor;
		}
		return exponent;
	}

	NumberAnimation {
		id: slide

		target: root
		property: "shift"
		from: 1
		to: 0
		duration: 1000
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

	// guides and their rates
	Repeater {
		model: [1, 0.5]

		StyledText {
			required property real modelData

			x: 4
			y: canvas.y + canvas.height * (1 - modelData) + 2
			text: Format.rate(root.scale_ * modelData)
			font.pixelSize: Theme.size.tiny
			tone: Theme.textSubtle
			tabular: true
		}
	}

	Canvas {
		id: canvas

		anchors.fill: parent
		anchors.topMargin: 6
		anchors.bottomMargin: 18
		renderStrategy: Canvas.Cooperative
		antialiasing: true

		onWidthChanged: requestPaint()
		onHeightChanged: requestPaint()

		// x of each sample (0…1 across the chart) and its values
		function points() {
			const list = root.samples || [];
			if (root.mode === "live") {
				const step = 1 / Math.max(1, root.span - 1);
				const n = list.length;
				return list.map((sample, i) => ({
					x: 1 - (n - 1 - i - root.shift) * step,
					down: Number(sample[0]) || 0,
					up: Number(sample[1]) || 0,
					progress: -1
				}));
			}
			if (list.length < 2) return [];
			const first = list[0][0];
			const lastAt = list[list.length - 1][0];
			const width = Math.max(1, lastAt - first);
			return list.map(sample => ({
				x: (sample[0] - first) / width,
				down: Number(sample[1]) || 0,
				up: Number(sample[2]) || 0,
				progress: Number(sample[3]) || 0
			}));
		}

		onPaint: {
			const ctx = getContext("2d");
			ctx.reset();
			const w = width;
			const h = height;
			// guides
			ctx.strokeStyle = Qt.alpha(Theme.text, 0.07);
			ctx.lineWidth = 1;
			ctx.setLineDash([3, 5]);
			for (const g of [0.5, 1]) {
				ctx.beginPath();
				ctx.moveTo(0, Math.round(h - g * h) + 0.5);
				ctx.lineTo(w, Math.round(h - g * h) + 0.5);
				ctx.stroke();
			}
			ctx.setLineDash([]);
			ctx.beginPath();
			ctx.moveTo(0, h - 0.5);
			ctx.lineTo(w, h - 0.5);
			ctx.strokeStyle = Qt.alpha(Theme.text, 0.12);
			ctx.stroke();

			const pts = points();
			if (pts.length < 2) return;
			const limit = root.reveal * w;
			ctx.save();
			ctx.beginPath();
			ctx.rect(0, -4, limit, h + 8);
			ctx.clip();

			const y = value => h - h * Math.max(0, Math.min(1, value / root.scale_));
			const trace = key => {
				ctx.moveTo(pts[0].x * w, y(pts[0][key]));
				for (let i = 1; i < pts.length; i += 1) {
					const prev = pts[i - 1];
					const cur = pts[i];
					const mid = (prev.x + cur.x) / 2 * w;
					ctx.bezierCurveTo(mid, y(prev[key]), mid, y(cur[key]), cur.x * w, y(cur[key]));
				}
			};

			// the download, filled
			const gradient = ctx.createLinearGradient(0, 0, 0, h);
			gradient.addColorStop(0, Qt.alpha(root.downColor, 0.38));
			gradient.addColorStop(1, Qt.alpha(root.downColor, 0.02));
			ctx.beginPath();
			trace("down");
			ctx.lineTo(pts[pts.length - 1].x * w, h);
			ctx.lineTo(pts[0].x * w, h);
			ctx.closePath();
			ctx.fillStyle = gradient;
			ctx.fill();
			ctx.beginPath();
			trace("down");
			ctx.strokeStyle = root.downColor;
			ctx.lineWidth = 2;
			ctx.lineJoin = "round";
			ctx.stroke();

			// the upload, a line
			ctx.beginPath();
			trace("up");
			ctx.strokeStyle = root.upColor;
			ctx.lineWidth = 1.5;
			ctx.stroke();

			// the progress, on its own scale (0…100 %)
			if (root.mode === "whole") {
				ctx.beginPath();
				for (let i = 0; i < pts.length; i += 1) {
					const px = pts[i].x * w;
					const py = h - h * pts[i].progress;
					if (i === 0) ctx.moveTo(px, py);
					else ctx.lineTo(px, py);
				}
				ctx.strokeStyle = Qt.alpha(Theme.text, 0.45);
				ctx.lineWidth = 1.25;
				ctx.setLineDash([4, 4]);
				ctx.stroke();
				ctx.setLineDash([]);
			}

			// the newest sample, a dot
			if (root.mode === "live") {
				const end = pts[pts.length - 1];
				ctx.beginPath();
				ctx.arc(Math.min(end.x * w, w - 3), y(end.down), 3.5, 0, Math.PI * 2);
				ctx.fillStyle = root.downColor;
				ctx.fill();
			}
			ctx.restore();

			// what is under the pointer
			if (root.pointer >= 0) {
				const at = root.nearest(pts, root.pointer / w);
				if (at) {
					const px = at.x * w;
					ctx.beginPath();
					ctx.moveTo(px + 0.5, 0);
					ctx.lineTo(px + 0.5, h);
					ctx.strokeStyle = Qt.alpha(Theme.text, 0.3);
					ctx.lineWidth = 1;
					ctx.stroke();
					for (const [key, color] of [["down", root.downColor], ["up", root.upColor]]) {
						ctx.beginPath();
						ctx.arc(px, y(at[key]), 4, 0, Math.PI * 2);
						ctx.fillStyle = color;
						ctx.fill();
					}
				}
			}
		}

		MouseArea {
			anchors.fill: parent
			hoverEnabled: true
			onPositionChanged: mouse => root.pointer = mouse.x
			onExited: root.pointer = -1
		}
	}

	function nearest(pts, fraction) {
		let best = null;
		let distance = 2;
		for (const point of pts) {
			const d = Math.abs(point.x - fraction);
			if (d < distance) {
				distance = d;
				best = point;
			}
		}
		return best;
	}

	// what the pointer reads off
	readonly property var hovered: {
		if (root.pointer < 0 || canvas.width <= 0) return null;
		const pts = canvas.points();
		const at = root.nearest(pts, root.pointer / canvas.width);
		if (!at) return null;
		const index = pts.indexOf(at);
		let label = "";
		if (root.mode === "live") {
			const ago = Math.round((1 - at.x) * (root.span - 1));
			label = ago <= 0 ? "now" : `${ago} s ago`;
		} else {
			const sample = root.samples[index];
			label = sample ? `${Qt.formatTime(new Date(sample[0] * 1000), "HH:mm")} · ${Math.round(at.progress * 100)} %` : "";
		}
		return { x: at.x * canvas.width, down: at.down, up: at.up, label: label };
	}

	Rectangle {
		visible: root.hovered !== null
		x: Math.max(0, Math.min(root.width - width, (root.hovered?.x ?? 0) - width / 2))
		y: -height - 6
		width: readout.implicitWidth + 18
		height: readout.implicitHeight + 10
		radius: Theme.radius.small
		color: Theme.layer3

		StyledText {
			id: readout

			anchors.centerIn: parent
			text: root.hovered ? `↓ ${Format.rate(root.hovered.down)}   ↑ ${Format.rate(root.hovered.up)}   ${root.hovered.label}` : ""
			font.pixelSize: Theme.size.small
			tabular: true
		}
	}

	// the time along the bottom
	StyledText {
		anchors.left: parent.left
		anchors.bottom: parent.bottom
		text: root.mode === "live" ? `${Math.round(root.span / 60)} min ago` : (root.samples.length > 0 ? Torrents.when(root.samples[0][0]) : "")
		font.pixelSize: Theme.size.tiny
		tone: Theme.textSubtle
	}

	StyledText {
		anchors.right: parent.right
		anchors.bottom: parent.bottom
		text: root.mode === "live" ? "now" : (root.samples.length > 1 ? Torrents.when(root.samples[root.samples.length - 1][0]) : "")
		font.pixelSize: Theme.size.tiny
		tone: Theme.textSubtle
	}

	EmptyState {
		anchors.centerIn: parent
		visible: (root.samples || []).length < 2
		icon: "chart_areaspline"
		title: root.mode === "live" ? "Nothing yet" : "No history yet"
		subtitle: root.mode === "live" ? "The rate shows here once data flows" : "The whole download is drawn here as it goes"
	}
}
