pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import qs.style.theme
import qs.style.widgets
import qs.core.services

// The song along its length, as loud as it is: what has played in the
// accent, the rest faint. Clicking or dragging goes there, hovering shows
// the time. Drawn once per song (two canvases, the played one clipped), so
// playing only moves a clip's edge. Chapters are ticks above it.
Item {
	id: root

	property color accent: Theme.primary
	// a thin line instead of the wave (the small window)
	property bool slim: false

	readonly property var peaks: Music.wave
	readonly property bool hasWave: root.peaks.length > 0
	readonly property real shownProgress: seek.pressed ? seek.dragRatio : Music.progress

	implicitHeight: root.slim ? 18 : 64

	// the bars rise in when a new song's wave comes
	property real grow: 0

	onPeaksChanged: {
		base.requestPaint();
		played.requestPaint();
		// the peaks themselves: hasWave may not have heard of them yet
		if (root.peaks.length > 0) growAnim.restart();
		else root.grow = 0;
	}

	// the wave was there before this
	Component.onCompleted: if (root.hasWave) root.grow = 1

	NumberAnimation {
		id: growAnim

		target: root
		property: "grow"
		from: 0
		to: 1
		duration: Motion.extraLong
		easing.type: Easing.BezierSpline
		easing.bezierCurve: Motion.spatial
	}

	function paint(canvas, colour) {
		const ctx = canvas.getContext("2d");
		ctx.reset();
		const w = canvas.width, h = canvas.height;
		const peaks = root.peaks;
		if (peaks.length === 0 || w <= 0) return;
		const bar = 3, gap = 2;
		const count = Math.max(1, Math.floor((w + gap) / (bar + gap)));
		ctx.fillStyle = colour;
		for (let i = 0; i < count; i += 1) {
			const from = Math.floor(i * peaks.length / count);
			const to = Math.max(from + 1, Math.floor((i + 1) * peaks.length / count));
			let level = 0;
			for (let j = from; j < to; j += 1) level = Math.max(level, peaks[j]);
			const bh = Math.max(3, level * h * 0.94);
			const x = i * (bar + gap);
			const y = (h - bh) / 2;
			ctx.beginPath();
			ctx.roundedRect(x, y, bar, bh, 1.5, 1.5);
			ctx.fill();
		}
	}

	// the wave
	Item {
		id: waveArea

		anchors.fill: parent
		visible: !root.slim && root.hasWave
		transform: Scale {
			origin.y: waveArea.height / 2
			yScale: 0.2 + 0.8 * root.grow
		}
		opacity: root.grow

		Canvas {
			id: base

			anchors.fill: parent
			renderStrategy: Canvas.Cooperative
			onPaint: root.paint(base, Qt.alpha(Theme.text, 0.2))
			// a paint asked for before the canvas can draw is lost
			onAvailableChanged: if (available) requestPaint()
			onWidthChanged: requestPaint()
			onHeightChanged: requestPaint()
		}

		Item {
			anchors.top: parent.top
			anchors.bottom: parent.bottom
			width: parent.width * root.shownProgress
			clip: true

			// drawn white once, tinted on the GPU: the accent may glide
			Canvas {
				id: played

				width: waveArea.width
				height: waveArea.height
				renderStrategy: Canvas.Cooperative
				visible: false
				onPaint: root.paint(played, "#ffffff")
				onAvailableChanged: if (available) requestPaint()
				onWidthChanged: requestPaint()
				onHeightChanged: requestPaint()
			}

			MultiEffect {
				width: waveArea.width
				height: waveArea.height
				source: played
				colorization: 1
				colorizationColor: root.accent
				brightness: -0.0001
			}
		}
	}

	// a line while there is no wave yet, or in the small window
	Rectangle {
		anchors.verticalCenter: parent.verticalCenter
		width: parent.width
		height: seek.containsMouse || seek.pressed ? 6 : 4
		radius: height / 2
		color: Qt.alpha(Theme.text, 0.14)
		visible: root.slim || !root.hasWave
		opacity: root.slim ? 1 : 1 - root.grow

		Behavior on height {
			Anim {
				duration: Motion.short
			}
		}

		Rectangle {
			width: parent.width * root.shownProgress
			height: parent.height
			radius: parent.radius
			color: root.accent
		}
	}

	// the chapters of an audiobook
	Repeater {
		model: Music.duration > 0 ? Music.chapters : []

		delegate: Rectangle {
			required property var modelData
			required property int index

			visible: index > 0
			x: root.width * modelData.t / Music.duration - 1
			y: root.slim ? 0 : -6
			width: 2
			height: root.slim ? root.height : root.height + 12
			radius: 1
			color: Qt.alpha(Theme.text, 0.32)
		}
	}

	// where it plays: a thin bright line through the wave
	Rectangle {
		visible: !root.slim && root.hasWave
		x: root.width * root.shownProgress - 1
		width: 2
		height: root.height
		radius: 1
		color: root.accent
		opacity: root.grow
	}

	// the time under the pointer
	Rectangle {
		id: tip

		readonly property real at: seek.hoverRatio * Music.duration
		visible: (seek.containsMouse || seek.pressed) && Music.duration > 0
		x: Math.max(0, Math.min(root.width - width, seek.mouseX - width / 2))
		y: -height - 8
		width: tipText.implicitWidth + 16
		height: 24
		radius: 12
		color: Theme.layer3

		StyledText {
			id: tipText

			anchors.centerIn: parent
			tabular: true
			font.pixelSize: Theme.size.small
			text: {
				const chapter = Music.chapters.filter(c => c.t <= tip.at).pop();
				const time = Music.formatTime(seek.pressed ? seek.dragRatio * Music.duration : tip.at);
				return chapter && Music.chapters.length > 1 ? `${time} · ${chapter.title}` : time;
			}
		}
	}

	MouseArea {
		id: seek

		property real hoverRatio: 0
		property real dragRatio: 0

		anchors.fill: parent
		anchors.topMargin: root.slim ? -6 : 0
		anchors.bottomMargin: root.slim ? -6 : 0
		hoverEnabled: true
		cursorShape: Qt.PointingHandCursor
		enabled: Music.duration > 0
		onPositionChanged: mouse => {
			seek.hoverRatio = Math.max(0, Math.min(1, mouse.x / root.width));
			if (seek.pressed) seek.dragRatio = seek.hoverRatio;
		}
		onPressed: mouse => {
			seek.hoverRatio = Math.max(0, Math.min(1, mouse.x / root.width));
			seek.dragRatio = seek.hoverRatio;
		}
		onReleased: Music.seek(seek.dragRatio * Music.duration)
	}
}
