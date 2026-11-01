import QtQuick
import qs.style.theme
import qs.style.widgets
import qs.core.services

// A live status of the shell as a tray item (widget `live:<id>`): a ring
// around its glyph, a curve with the value over it, a glyph over a bar or
// over the value, or the glyph alone – as set in the settings. The tile
// takes on the tone while something happens, breathes while it wants
// attention, ripples when it turns urgent and pops when a level is full;
// idle and set to hide, it fades back.
Item {
	id: root

	required property string key
	readonly property var src: Live.source(root.key)
	readonly property string shape: Live.styleOf(root.key)
	readonly property bool idle: !(root.src?.busy ?? false)
	readonly property bool hideIdle: Live.optionOf(root.key).hide
	readonly property real unit: root.height
	readonly property color toneColor: Theme.toneColor(root.src?.tone ?? "normal")
	readonly property color accent: root.src?.tone === "normal" ? Theme.primary : root.toneColor
	readonly property color valueColor: ["warn", "bad", "good"].includes(root.src?.tone) ? root.toneColor : Theme.text
	readonly property real level: root.src?.level ?? -1

	opacity: root.src?.available ? (root.idle && root.hideIdle ? 0.4 : 1) : 0.25

	Behavior on opacity {
		Anim {
			duration: Motion.long
		}
	}

	Component.onCompleted: {
		Live.hold(root.key, 1);
		root.lastUrgency = root.urgency;
	}
	Component.onDestruction: Live.hold(root.key, -1)

	readonly property int urgency: ({ muted: 0, normal: 1, accent: 2, good: 2, warn: 3, bad: 4 })[root.src?.tone ?? "normal"] ?? 1
	property int lastUrgency: 1
	onUrgencyChanged: {
		if (root.urgency > root.lastUrgency && root.urgency >= 3) ripple.restart();
		root.lastUrgency = root.urgency;
	}
	property real lastLevel: root.level
	onLevelChanged: {
		if (root.lastLevel >= 0 && root.lastLevel < 0.999 && root.level >= 0.999) {
			ripple.restart();
			pop.restart();
		}
		root.lastLevel = root.level;
	}
	readonly property string text: root.src?.text ?? ""
	property string lastText: ""
	onTextChanged: {
		const a = parseFloat(root.lastText);
		const b = parseFloat(root.text);
		if (root.src && !root.src.history && root.level < 0 && !isNaN(a) && !isNaN(b) && b > a) hop.restart();
		root.lastText = root.text;
	}

	// the tone over the tile while something happens
	Rectangle {
		anchors.fill: parent
		radius: root.unit * 0.27
		color: root.accent
		opacity: !root.idle && root.src?.tone !== "normal" && root.src?.tone !== "muted" ? 0.13 : 0

		Behavior on opacity {
			Anim {
				duration: Motion.long
			}
		}
		Behavior on color {
			ColorAnim {}
		}
	}

	// ── the glyph, in a ring or not ─────────────────────────────────────
	Item {
		id: mark

		readonly property real size: {
			switch (root.shape) {
			case "ring": return root.unit * 0.6;
			case "spark": return root.unit * 0.24;
			case "icon": return root.unit * 0.52;
			}
			return root.unit * 0.4;
		}

		width: mark.size
		height: mark.size
		x: root.shape === "spark" ? root.unit * 0.13 : (root.width - width) / 2
		y: {
			switch (root.shape) {
			case "ring": return root.unit * 0.09;
			case "spark": return root.unit * 0.12;
			case "icon": return (root.height - height) / 2;
			}
			return root.unit * 0.13;
		}

		Behavior on size {
			SpatialAnim {
				duration: Motion.long
			}
		}

		Rectangle {
			id: glow

			anchors.centerIn: parent
			width: parent.width * 1.35
			height: width
			radius: width / 2
			color: root.toneColor
			opacity: 0
			visible: root.src?.pulse ?? false

			SequentialAnimation on opacity {
				running: glow.visible
				loops: Animation.Infinite
				onRunningChanged: if (!running) glow.opacity = 0
				NumberAnimation {
					from: 0.04
					to: 0.3
					duration: 900
					easing.type: Easing.InOutSine
				}
				NumberAnimation {
					from: 0.3
					to: 0.04
					duration: 900
					easing.type: Easing.InOutSine
				}
			}
		}

		Rectangle {
			id: wave

			anchors.centerIn: parent
			width: parent.width
			height: width
			radius: width / 2
			color: "transparent"
			border.width: 2
			border.color: root.toneColor
			opacity: 0
		}

		ParallelAnimation {
			id: ripple

			NumberAnimation {
				target: wave
				property: "scale"
				from: 0.8
				to: 2.1
				duration: 700
				easing.type: Easing.OutCubic
			}
			NumberAnimation {
				target: wave
				property: "opacity"
				from: 0.9
				to: 0
				duration: 700
			}
		}

		Ring {
			anchors.fill: parent
			visible: root.shape === "ring"
			value: Math.max(0, root.level)
			thickness: Math.max(2.5, root.unit * 0.06)
			color: root.accent
			trackColor: Qt.alpha(Theme.text, 0.13)
		}

		Glyph {
			id: glyph

			property real lift: 0

			anchors.horizontalCenter: parent.horizontalCenter
			y: (parent.height - height) / 2 + glyph.lift
			icon: root.src?.glyph ?? "help"
			size: root.shape === "ring" ? mark.size * 0.46 : mark.size
			color: root.src?.tone === "normal" ? Theme.text : root.toneColor
		}

		SequentialAnimation {
			id: hop

			NumberAnimation {
				target: glyph
				property: "lift"
				to: -root.unit * 0.08
				duration: 120
				easing.type: Easing.OutQuad
			}
			NumberAnimation {
				target: glyph
				property: "lift"
				to: 0
				duration: 460
				easing.type: Easing.OutBounce
			}
		}

		SequentialAnimation {
			id: pop

			NumberAnimation {
				target: mark
				property: "scale"
				to: 1.3
				duration: 140
				easing.type: Easing.OutQuad
			}
			NumberAnimation {
				target: mark
				property: "scale"
				to: 1
				duration: 560
				easing.type: Easing.OutElastic
			}
		}

		// the icon alone: a dot while something happens
		Rectangle {
			visible: root.shape === "icon" && !root.idle
			anchors.right: parent.right
			anchors.top: parent.top
			anchors.margins: -2
			width: Math.max(6, root.unit * 0.12)
			height: width
			radius: width / 2
			color: root.toneColor
			border.width: 1.5
			border.color: Theme.layer2
		}
	}

	// ── the value ───────────────────────────────────────────────────────
	RollText {
		visible: root.shape !== "icon"
		x: root.shape === "spark" ? mark.x + mark.width + root.unit * 0.06 : (root.width - width) / 2
		y: root.shape === "spark" ? mark.y + (mark.height - height) / 2 : (root.shape === "ring" ? mark.y + mark.height + root.unit * 0.02 : mark.y + mark.height + root.unit * 0.04)
		text: root.text
		tone: root.valueColor
		pixelSize: Math.max(8, root.unit * (root.shape === "spark" ? 0.2 : 0.18))
		weight: root.shape === "spark" ? Font.DemiBold : Font.Medium
		maximumWidth: root.width - root.unit * 0.2
		alignment: root.shape === "spark" ? Qt.AlignLeft : Qt.AlignHCenter
	}

	// ── a curve or a bar along the bottom ───────────────────────────────
	Sparkline {
		visible: root.shape === "spark"
		anchors.left: parent.left
		anchors.right: parent.right
		anchors.bottom: parent.bottom
		anchors.margins: root.unit * 0.1
		height: root.unit * 0.42
		values: root.shape === "spark" ? (root.src?.history ?? []) : []
		maximum: root.src?.maximum ?? 0
		lineWidth: 1.5
		color: root.accent
	}

	Rectangle {
		visible: root.shape === "bar" && root.level >= 0
		anchors.left: parent.left
		anchors.right: parent.right
		anchors.bottom: parent.bottom
		anchors.margins: root.unit * 0.14
		height: Math.max(3, root.unit * 0.06)
		radius: height / 2
		color: Qt.alpha(Theme.text, 0.13)

		Rectangle {
			width: parent.width * Math.max(0, Math.min(1, root.level))
			height: parent.height
			radius: parent.radius
			color: root.accent

			Behavior on width {
				SpatialAnim {
					duration: Motion.long
				}
			}
		}
	}
}
