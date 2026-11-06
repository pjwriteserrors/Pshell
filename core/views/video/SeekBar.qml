pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.style.widgets
import qs.core.services

// The line along the film: what was played in the accent, the chapters as
// parts of it, the intro and the credits faint, a loop's ends. Resting on it
// shows the picture of that moment from the sprite sheet (nothing decoded),
// its time and its chapter; dragging goes there while the film follows.
Item {
	id: root

	property color accent: Theme.primary
	property real position: Video.position
	property real duration: Video.duration
	property var chapters: Video.chapters
	property var sheet: Video.sprite
	property var intro: Video.intro
	property var outro: Video.outro
	property real loopA: Video.loopA
	property real loopB: Video.loopB
	// seen before: where it was left (a faint tick)
	property real mark: -1

	signal seekTo(real seconds)
	readonly property bool scrubbing: drag.pressed
	readonly property bool hovering: drag.containsMouse || drag.pressed
	readonly property real pointerTime: root.duration > 0 ? Math.max(0, Math.min(1, drag.mouseX / Math.max(1, root.width))) * root.duration : 0
	property real dragTime: 0
	readonly property real shownPosition: drag.pressed ? root.dragTime : root.position

	implicitHeight: 28

	function share(t) {
		return root.duration > 0 ? Math.max(0, Math.min(1, t / root.duration)) : 0;
	}

	// the parts: one per chapter, or the whole
	readonly property var parts: {
		const list = root.chapters || [];
		if (list.length < 2 || root.duration <= 0) return [[0, 1]];
		const out = [];
		for (let i = 0; i < list.length; i += 1) {
			const a = root.share(list[i].t);
			const b = i + 1 < list.length ? root.share(list[i + 1].t) : 1;
			if (b > a) out.push([a, b]);
		}
		return out;
	}

	property real thickness: root.hovering ? 8 : 4

	Behavior on thickness {
		SpatialAnim {
			duration: Motion.short
		}
	}

	Item {
		id: track

		anchors.verticalCenter: parent.verticalCenter
		width: parent.width
		height: root.thickness

		Repeater {
			model: root.parts

			Item {
				id: part

				required property var modelData
				readonly property real a: part.modelData[0]
				readonly property real b: part.modelData[1]
				readonly property real gap: root.parts.length > 1 ? 1.5 : 0

				x: part.a * track.width + (part.a > 0 ? part.gap : 0)
				width: Math.max(1, (part.b - part.a) * track.width - (part.a > 0 ? part.gap : 0) - (part.b < 1 ? part.gap : 0))
				height: track.height

				Rectangle {
					anchors.fill: parent
					radius: height / 2
					color: Qt.rgba(1, 1, 1, 0.22)
				}

				// played: a clip of the accent, so playing only moves an edge
				Item {
					height: parent.height
					width: Math.max(0, Math.min(part.width, root.share(root.shownPosition) * track.width - part.x))
					clip: true

					Rectangle {
						width: part.width
						height: parent.height
						radius: height / 2
						color: root.accent
					}
				}

				// what the pointer would reach
				Item {
					visible: drag.containsMouse && !drag.pressed
					height: parent.height
					x: Math.max(0, Math.min(part.width, root.share(root.shownPosition) * track.width - part.x))
					width: Math.max(0, Math.min(part.width, drag.mouseX - part.x) - x)
					clip: true

					Rectangle {
						x: -parent.x
						width: part.width
						height: parent.height
						radius: height / 2
						color: Qt.rgba(1, 1, 1, 0.22)
					}
				}
			}
		}

		// the intro and the credits a series shares
		Repeater {
			model: [root.intro, root.outro].filter(r => !!r)

			Rectangle {
				required property var modelData

				x: root.share(modelData[0]) * track.width
				width: Math.max(2, (root.share(modelData[1]) - root.share(modelData[0])) * track.width)
				height: 2
				y: -5
				radius: 1
				color: Qt.alpha(root.accent, 0.55)
			}
		}

		// a loop's two ends and what lies between
		Rectangle {
			visible: root.loopA >= 0
			x: root.share(root.loopA) * track.width
			width: root.loopB > root.loopA ? Math.max(2, (root.share(root.loopB) - root.share(root.loopA)) * track.width) : 2
			y: -3
			height: track.height + 6
			radius: 3
			color: Qt.alpha(root.accent, 0.25)
			border.width: 1
			border.color: root.accent
		}

		Rectangle {
			visible: root.mark > 0 && root.duration > 0
			x: root.share(root.mark) * track.width - 1
			width: 2
			height: track.height
			color: Qt.rgba(1, 1, 1, 0.7)
		}

		// the knob
		Rectangle {
			property real size: root.hovering ? 16 : 0

			x: root.share(root.shownPosition) * track.width - width / 2
			anchors.verticalCenter: parent.verticalCenter
			width: size
			height: size
			radius: size / 2
			color: root.accent
			border.width: 2
			border.color: Qt.rgba(1, 1, 1, 0.9)

			Behavior on size {
				SpatialAnim {
					duration: Motion.short
				}
			}
		}
	}

	MouseArea {
		id: drag

		anchors.fill: parent
		anchors.topMargin: -6
		anchors.bottomMargin: -6
		hoverEnabled: true
		cursorShape: Qt.PointingHandCursor
		preventStealing: true
		onPressed: mouse => {
			root.dragTime = root.pointerTime;
			root.seekTo(root.dragTime);
		}
		onPositionChanged: mouse => {
			if (!drag.pressed) return;
			root.dragTime = root.pointerTime;
			if (!follow.running) follow.start();
		}
		onReleased: root.seekTo(root.dragTime)
	}

	// while dragging the film follows, a few times a second
	Timer {
		id: follow

		interval: 90
		onTriggered: root.seekTo(root.dragTime)
	}

	// ── the moment under the pointer ───────────────────────────────────────
	Rectangle {
		id: preview

		readonly property real t: drag.pressed ? root.dragTime : root.pointerTime
		readonly property bool hasPicture: !!root.sheet
		readonly property real pw: preview.hasPicture ? Math.min(240, Math.max(160, root.width * 0.18)) : 0
		readonly property real ph: preview.hasPicture ? preview.pw / Math.max(0.5, Math.min(2.6, (root.sheet?.tile_w ?? 16) / (root.sheet?.tile_h ?? 9))) : 0
		readonly property string chapter: {
			const list = root.chapters || [];
			let found = "";
			for (const c of list)
				if (c.t <= preview.t) found = c.title || "";
			return found;
		}

		width: Math.max(preview.pw, label.implicitWidth + 16) + 6
		height: preview.ph + label.implicitHeight + (preview.chapter ? chapterLabel.implicitHeight : 0) + 14
		x: Math.max(0, Math.min(root.width - width, drag.mouseX - width / 2))
		y: -height - 12
		radius: Theme.radius.medium
		color: Qt.rgba(0.06, 0.06, 0.07, 0.92)
		border.width: 1
		border.color: Qt.rgba(1, 1, 1, 0.1)
		opacity: root.hovering && root.duration > 0 ? 1 : 0
		visible: opacity > 0.01
		scale: root.hovering ? 1 : 0.92
		transformOrigin: Item.Bottom

		Behavior on opacity {
			Anim {
				duration: Motion.short
			}
		}
		Behavior on scale {
			SpatialAnim {
				duration: Motion.short
			}
		}

		SpriteTile {
			id: tile

			x: 3
			y: 3
			width: preview.pw
			height: preview.ph
			sheet: root.sheet
			tile: Video.tileAt(root.sheet, preview.t)
			visible: preview.hasPicture
			layer.enabled: true
			layer.smooth: true
		}

		StyledText {
			id: chapterLabel

			anchors.horizontalCenter: parent.horizontalCenter
			y: preview.ph + 6
			width: Math.min(implicitWidth, preview.width - 12)
			visible: preview.chapter !== ""
			text: preview.chapter
			tone: Qt.rgba(1, 1, 1, 0.75)
			surface: "transparent"
			font.pixelSize: Theme.size.small
		}

		StyledText {
			id: label

			anchors.horizontalCenter: parent.horizontalCenter
			anchors.bottom: parent.bottom
			anchors.bottomMargin: 4
			text: Video.formatTime(preview.t)
			tabular: true
			tone: "white"
			surface: "transparent"
			font.pixelSize: Theme.size.label
			font.weight: Font.DemiBold
		}
	}
}
