import QtQuick
import qs.style.theme
import qs.core.services

// How a live status looks in a row (the bar, the settings): its glyph –
// inside a ring that fills for `ring` – the value that rolls, and a curve
// (`spark`) or a thin bar (`bar`) beside it; `icon` is the glyph alone.
// It breathes while the source wants attention, sends out a ripple when
// it turns more urgent, hops when a count grows and bursts when a level
// becomes full.
Row {
	id: root

	property string key: ""
	// the style; "" what the settings say
	property string style: ""
	property bool label: Live.optionOf(root.key).label
	property real glyphSize: 16
	property bool animated: true
	readonly property var src: Live.source(root.key)
	readonly property string shape: root.style !== "" ? root.style : Live.styleOf(root.key)
	readonly property color toneColor: Theme.toneColor(root.src?.tone ?? "normal")
	readonly property color valueColor: ["warn", "bad", "good"].includes(root.src?.tone) ? root.toneColor : Theme.text
	readonly property real level: root.src?.level ?? -1

	spacing: 6

	// how urgent, to ripple when it rises
	readonly property int urgency: ({ muted: 0, normal: 1, accent: 2, good: 2, warn: 3, bad: 4 })[root.src?.tone ?? "normal"] ?? 1
	property int lastUrgency: 1
	onUrgencyChanged: {
		if (root.urgency > root.lastUrgency && root.urgency >= 3 && root.animated) ripple.restart();
		root.lastUrgency = root.urgency;
	}
	Component.onCompleted: root.lastUrgency = root.urgency

	// full: a burst
	property real lastLevel: root.level
	onLevelChanged: {
		if (root.animated && root.lastLevel >= 0 && root.lastLevel < 0.999 && root.level >= 0.999) {
			ripple.restart();
			pop.restart();
		}
		root.lastLevel = root.level;
	}

	// a count that grows: the glyph hops
	readonly property string text: root.src?.text ?? ""
	property string lastText: ""
	onTextChanged: {
		const counter = root.src && !root.src.history && root.level < 0;
		const a = parseFloat(root.lastText);
		const b = parseFloat(root.text);
		if (root.animated && counter && !isNaN(a) && !isNaN(b) && b > a) hop.restart();
		root.lastText = root.text;
	}

	// ── the glyph ───────────────────────────────────────────────────────
	Item {
		id: mark

		anchors.verticalCenter: parent.verticalCenter
		width: root.shape === "ring" ? root.glyphSize + 4 : root.glyphSize + 2
		height: width

		// light behind it: breathes a few times when it comes, then stays still
		// (a breath without end redrew the whole bar 60 times a second on
		// every screen, ~30 % CPU while an agent worked)
		Rectangle {
			id: glow

			anchors.centerIn: parent
			width: parent.width + 6
			height: width
			radius: width / 2
			color: root.toneColor
			opacity: 0.22
			visible: root.src?.pulse ?? false
			onVisibleChanged: glow.breathe()
			Component.onCompleted: glow.breathe()

			function breathe() {
				breath.stop();
				glow.opacity = 0.22;
				glow.scale = 1;
				if (glow.visible && root.animated) breath.start();
			}

			SequentialAnimation {
				id: breath

				ParallelAnimation {
					loops: 3
					SequentialAnimation {
						NumberAnimation {
							target: glow
							property: "opacity"
							from: 0.05
							to: 0.32
							duration: 900
							easing.type: Easing.InOutSine
						}
						NumberAnimation {
							target: glow
							property: "opacity"
							from: 0.32
							to: 0.05
							duration: 900
							easing.type: Easing.InOutSine
						}
					}
					SequentialAnimation {
						NumberAnimation {
							target: glow
							property: "scale"
							from: 0.75
							to: 1.15
							duration: 900
							easing.type: Easing.InOutSine
						}
						NumberAnimation {
							target: glow
							property: "scale"
							from: 1.15
							to: 0.75
							duration: 900
							easing.type: Easing.InOutSine
						}
					}
				}
				ParallelAnimation {
					NumberAnimation {
						target: glow
						property: "opacity"
						to: 0.22
						duration: 450
						easing.type: Easing.OutSine
					}
					NumberAnimation {
						target: glow
						property: "scale"
						to: 1
						duration: 450
						easing.type: Easing.OutSine
					}
				}
			}
		}

		// one ring going out when it turns urgent or becomes full
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
				to: 2.3
				duration: 650
				easing.type: Easing.OutCubic
			}
			NumberAnimation {
				target: wave
				property: "opacity"
				from: 0.9
				to: 0
				duration: 650
				easing.type: Easing.OutQuad
			}
		}

		Ring {
			anchors.fill: parent
			visible: root.shape === "ring"
			value: Math.max(0, root.level)
			thickness: 2.4
			color: root.src?.tone === "normal" ? Theme.primary : root.toneColor
			trackColor: Qt.alpha(Theme.text, 0.14)
		}

		Glyph {
			id: glyph

			property real lift: 0

			anchors.horizontalCenter: parent.horizontalCenter
			y: (parent.height - height) / 2 + glyph.lift
			icon: root.src?.glyph ?? "help"
			size: root.shape === "ring" ? root.glyphSize * 0.62 : root.glyphSize
			color: root.src?.tone === "normal" ? Theme.text : root.toneColor

			Behavior on size {
				SpatialAnim {
					duration: Motion.medium
				}
			}
		}

		SequentialAnimation {
			id: hop

			NumberAnimation {
				target: glyph
				property: "lift"
				to: -4
				duration: 120
				easing.type: Easing.OutQuad
			}
			NumberAnimation {
				target: glyph
				property: "lift"
				to: 0
				duration: 420
				easing.type: Easing.OutBounce
			}
		}

		SequentialAnimation {
			id: pop

			NumberAnimation {
				target: mark
				property: "scale"
				to: 1.35
				duration: 140
				easing.type: Easing.OutQuad
			}
			NumberAnimation {
				target: mark
				property: "scale"
				to: 1
				duration: 520
				easing.type: Easing.OutElastic
			}
		}
	}

	StyledText {
		anchors.verticalCenter: parent.verticalCenter
		visible: root.label && root.shape !== "icon"
		text: root.src?.name ?? ""
		tone: Theme.textMuted
		font.pixelSize: Theme.size.small
		font.weight: Font.Medium
	}

	// ── the value, with a bar under it ──────────────────────────────────
	Item {
		anchors.verticalCenter: parent.verticalCenter
		visible: root.shape !== "icon"
		width: value.implicitWidth
		height: value.implicitHeight + (root.shape === "bar" ? 5 : 0)

		RollText {
			id: value

			text: root.text
			tone: root.valueColor
			animated: root.animated
			pixelSize: Theme.size.body
			weight: Font.DemiBold
			maximumWidth: 180
			minimumWidth: widest.implicitWidth
		}

		StyledText {
			id: widest

			visible: false
			text: root.src?.widest ?? ""
			tabular: true
			font.pixelSize: Theme.size.body
			font.weight: Font.DemiBold
		}

		Rectangle {
			visible: root.shape === "bar"
			anchors.bottom: parent.bottom
			width: parent.width
			height: 3
			radius: 1.5
			color: Qt.alpha(Theme.text, 0.14)

			Rectangle {
				width: parent.width * Math.max(0, Math.min(1, root.level))
				height: parent.height
				radius: parent.radius
				color: root.src?.tone === "normal" ? Theme.primary : root.toneColor

				Behavior on width {
					SpatialAnim {
						duration: Motion.long
					}
				}
			}
		}
	}

	// ── a curve of the last minute ──────────────────────────────────────
	Sparkline {
		anchors.verticalCenter: parent.verticalCenter
		visible: root.shape === "spark" && !!root.src?.history
		width: 38
		height: 16
		values: root.shape === "spark" ? (root.src?.history ?? []) : []
		maximum: root.src?.maximum ?? 0
		lineWidth: 1.5
		color: root.src?.tone === "normal" ? Theme.primary : root.toneColor
	}

	// the icon alone: a dot while something happens
	Rectangle {
		anchors.verticalCenter: parent.verticalCenter
		visible: root.shape === "icon" && (root.src?.busy ?? false)
		width: 6
		height: 6
		radius: 3
		color: root.toneColor
	}
}
