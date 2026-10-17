import QtQuick
import qs.style.theme
import qs.style.widgets

// The heart through the day: one value per 10 minutes since midnight as a
// smooth line over a fading area, gaps where the watch measured nothing,
// the resting pulse dashed. `progress` (0…1) draws it in from the left; the
// pointer shows the time and the pulse under it.
Item {
	id: root

	// 144 means, 0 where nothing was measured
	property var values: []
	property real resting: 0
	property real progress: 1
	property color color: Theme.secondary

	readonly property var measured: root.values.filter(v => v > 0)
	readonly property real low: root.measured.length ? Math.max(0, Math.min(...root.measured, root.resting || 999) - 8) : 40
	readonly property real high: root.measured.length ? Math.max(...root.measured) + 8 : 120
	readonly property real slots: 144

	implicitHeight: 150

	function xOf(index) {
		return chart.width * (index + 0.5) / root.slots;
	}

	function yOf(value) {
		return chart.height * (1 - (value - root.low) / Math.max(1, root.high - root.low));
	}

	onValuesChanged: chart.requestPaint()
	onProgressChanged: chart.requestPaint()
	onColorChanged: chart.requestPaint()

	Canvas {
		id: chart

		anchors.fill: parent
		anchors.leftMargin: 30
		anchors.bottomMargin: 20
		anchors.topMargin: 6
		antialiasing: true
		renderStrategy: Canvas.Cooperative

		onWidthChanged: requestPaint()
		onHeightChanged: requestPaint()

		onPaint: {
			const ctx = getContext("2d");
			ctx.reset();
			const values = root.values || [];
			const until = root.slots * root.progress;
			// runs of measured values: each a stroke and an area of its own
			const runs = [];
			let run = [];
			for (let i = 0; i < values.length && i < until; i += 1) {
				if (values[i] > 0) run.push([root.xOf(i), root.yOf(values[i])]);
				else if (run.length) {
					runs.push(run);
					run = [];
				}
			}
			if (run.length) runs.push(run);

			const fill = ctx.createLinearGradient(0, 0, 0, height);
			fill.addColorStop(0, Qt.alpha(root.color, 0.34));
			fill.addColorStop(1, Qt.alpha(root.color, 0));

			for (const points of runs) {
				const path = () => {
					ctx.moveTo(points[0][0], points[0][1]);
					for (let i = 1; i < points.length; i += 1) {
						const [x0, y0] = points[i - 1];
						const [x1, y1] = points[i];
						const mid = (x0 + x1) / 2;
						ctx.bezierCurveTo(mid, y0, mid, y1, x1, y1);
					}
				};
				ctx.beginPath();
				path();
				ctx.lineTo(points[points.length - 1][0], height);
				ctx.lineTo(points[0][0], height);
				ctx.closePath();
				ctx.fillStyle = fill;
				ctx.fill();

				ctx.beginPath();
				path();
				ctx.lineWidth = 2.2;
				ctx.lineJoin = "round";
				ctx.lineCap = "round";
				ctx.strokeStyle = root.color;
				ctx.stroke();
			}

			// where the line has got to: a dot leading it in
			if (runs.length && root.progress < 1) {
				const last = runs[runs.length - 1];
				const [x, y] = last[last.length - 1];
				ctx.beginPath();
				ctx.arc(x, y, 4, 0, Math.PI * 2);
				ctx.fillStyle = root.color;
				ctx.fill();
			}
		}

		// the resting pulse
		Row {
			y: root.yOf(root.resting)
			width: chart.width
			visible: root.resting > 0
			spacing: 4

			Repeater {
				model: Math.max(0, Math.ceil(chart.width / 8))

				delegate: Rectangle {
					width: 4
					height: 1
					color: Theme.textFaint
				}
			}
		}

		HoverHandler {
			id: hover
		}

		readonly property int slot: Math.max(0, Math.min(root.slots - 1, Math.floor(hover.point.position.x / Math.max(1, chart.width) * root.slots)))
		readonly property real value: root.values[chart.slot] ?? 0

		Rectangle {
			x: root.xOf(chart.slot)
			width: 1
			height: chart.height
			color: Theme.textMuted
			opacity: hover.hovered && chart.value > 0 ? 1 : 0

			Behavior on opacity {
				Anim {}
			}
		}

		Rectangle {
			x: root.xOf(chart.slot) - 5
			y: root.yOf(chart.value) - 5
			width: 10
			height: 10
			radius: 5
			color: root.color
			border.width: 2
			border.color: Theme.layer1
			opacity: hover.hovered && chart.value > 0 ? 1 : 0

			Behavior on opacity {
				Anim {}
			}
		}

		Rectangle {
			id: bubble

			x: Math.max(0, Math.min(chart.width - width, root.xOf(chart.slot) - width / 2))
			y: Math.max(-4, root.yOf(chart.value) - height - 12)
			width: words.implicitWidth + 18
			height: 24
			radius: 12
			color: Theme.layer3
			opacity: hover.hovered && chart.value > 0 ? 1 : 0
			visible: opacity > 0

			Behavior on opacity {
				Anim {}
			}

			StyledText {
				id: words

				anchors.centerIn: parent
				text: `${String(Math.floor(chart.slot / 6)).padStart(2, "0")}:${String(chart.slot % 6 * 10).padStart(2, "0")} · ${Math.round(chart.value)} bpm`
				font.pixelSize: Theme.size.small
				font.weight: Font.DemiBold
				tabular: true
			}
		}
	}

	// the scale: the top and the bottom of it
	StyledText {
		anchors.left: parent.left
		y: chart.y - 4
		text: Math.round(root.high)
		tone: Theme.textSubtle
		font.pixelSize: Theme.size.tiny
		tabular: true
	}

	StyledText {
		anchors.left: parent.left
		y: chart.y + chart.height - 10
		text: Math.round(root.low)
		tone: Theme.textSubtle
		font.pixelSize: Theme.size.tiny
		tabular: true
	}

	// the hours
	Repeater {
		model: 5

		delegate: StyledText {
			required property int index

			x: chart.x + chart.width * index / 4 - implicitWidth / 2
			anchors.bottom: parent.bottom
			text: String(index * 6).padStart(2, "0")
			tone: Theme.textSubtle
			font.pixelSize: Theme.size.tiny
			tabular: true
		}
	}
}
