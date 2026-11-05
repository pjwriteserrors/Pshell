import QtQuick
import qs.style.theme

// A value whose characters roll like a counter: a character that changed
// slides out and the new one in – upwards when the number grew, downwards
// when it fell – while the ones that stayed keep still. A text that is no
// number (or too long to roll) glides in as a whole and elides at
// `maximumWidth`. `minimumWidth` keeps room for the widest value.
Item {
	id: root

	property string text: ""
	property color tone: Theme.text
	property real pixelSize: Theme.size.body
	property int weight: Font.DemiBold
	property real maximumWidth: 1e6
	property real minimumWidth: 0
	property int alignment: Qt.AlignLeft
	property bool animated: true
	// for values that change every second: a short, small nudge instead of a
	// roll, so a screen full of them stays quiet
	property bool calm: false
	readonly property real travel: root.calm ? 0.35 : 1
	// 1 the value grew, -1 it fell
	property int direction: 1
	property string before: ""
	readonly property bool rolls: root.text.length <= 14 && /\d/.test(root.text)

	function numberOf(text) {
		const value = parseFloat(String(text).replace(/[^0-9.,\-]/g, "").replace(",", "."));
		return isNaN(value) ? null : value;
	}

	onTextChanged: {
		const a = root.numberOf(root.before);
		const b = root.numberOf(root.text);
		root.direction = a === null || b === null || b >= a ? 1 : -1;
		root.before = root.text;
		if (!root.rolls && root.animated && whole.text !== root.text) swap.restart();
		else if (!root.rolls) whole.text = root.text;
	}
	// set once the first value stands: digits that come in later rise in
	property bool ready: false
	Component.onCompleted: {
		root.before = root.text;
		whole.text = root.text;
		Qt.callLater(() => root.ready = true);
	}

	readonly property real naturalWidth: root.rolls ? row.width : Math.min(root.maximumWidth, whole.implicitWidth)
	implicitWidth: Math.max(root.minimumWidth, root.naturalWidth)
	implicitHeight: probe.implicitHeight

	Behavior on implicitWidth {
		enabled: root.animated && !root.calm
		SpatialAnim {
			duration: Motion.medium
		}
	}

	StyledText {
		id: probe

		visible: false
		text: "0"
		font.pixelSize: root.pixelSize
		font.weight: root.weight
	}

	// ── rolling ─────────────────────────────────────────────────────────
	Row {
		id: row

		visible: root.rolls
		// slots count from the right, so a unit stays put and a new digit comes in in front
		layoutDirection: Qt.RightToLeft
		x: root.alignment === Qt.AlignRight ? root.width - width : (root.alignment === Qt.AlignHCenter ? (root.width - width) / 2 : 0)
		height: root.height

		Repeater {
			model: root.rolls ? root.text.length : 0

			delegate: Item {
				id: slot

				required property int index
				readonly property string ch: root.text.charAt(root.text.length - 1 - slot.index)
				property string shown: ""
				property string old: ""
				// 0 the old character, 1 the new one
				property real t: 1

				width: now.implicitWidth
				height: root.height
				clip: true

				Behavior on width {
					enabled: root.animated && !root.calm
					SpatialAnim {
						duration: Motion.medium
					}
				}

				onChChanged: {
					if (!root.animated || !slot.visible) {
						slot.shown = slot.ch;
						return;
					}
					slot.old = slot.shown;
					slot.shown = slot.ch;
					roll.restart();
				}
				Component.onCompleted: {
					slot.shown = slot.ch;
					// a digit that comes in later rises from below
					if (root.animated && root.ready) {
						slot.old = "";
						roll.restart();
					}
				}

				StyledText {
					y: -root.direction * slot.height * root.travel * slot.t
					text: slot.old
					tone: root.tone
					opacity: 1 - slot.t
					tabular: true
					font.pixelSize: root.pixelSize
					font.weight: root.weight
					height: slot.height
				}

				StyledText {
					id: now

					y: root.direction * slot.height * root.travel * (1 - slot.t)
					text: slot.shown
					tone: root.tone
					opacity: root.calm ? slot.t : 0.25 + 0.75 * slot.t
					tabular: true
					font.pixelSize: root.pixelSize
					font.weight: root.weight
					height: slot.height
				}

				NumberAnimation {
					id: roll

					target: slot
					property: "t"
					from: 0
					to: 1
					// characters further left roll a touch later, like a counter
					duration: root.calm ? 160 : 420 + slot.index * 25
					easing.type: root.calm ? Easing.OutCubic : Easing.BezierSpline
					easing.bezierCurve: Motion.spatial
				}
			}
		}
	}

	// ── a text that glides in as a whole ────────────────────────────────
	StyledText {
		id: whole

		property real lift: 0

		visible: !root.rolls
		width: Math.min(root.maximumWidth, implicitWidth)
		x: root.alignment === Qt.AlignRight ? root.width - width : (root.alignment === Qt.AlignHCenter ? (root.width - width) / 2 : 0)
		y: whole.lift
		height: root.height
		tone: root.tone
		font.pixelSize: root.pixelSize
		font.weight: root.weight
	}

	SequentialAnimation {
		id: swap

		ParallelAnimation {
			NumberAnimation {
				target: whole
				property: "opacity"
				to: 0
				duration: 110
			}
			NumberAnimation {
				target: whole
				property: "lift"
				to: -5
				duration: 110
				easing.type: Easing.InQuad
			}
		}
		ScriptAction {
			script: {
				whole.text = root.text;
				whole.lift = 6;
			}
		}
		ParallelAnimation {
			NumberAnimation {
				target: whole
				property: "opacity"
				to: 1
				duration: 220
			}
			NumberAnimation {
				target: whole
				property: "lift"
				to: 0
				duration: 380
				easing.type: Easing.BezierSpline
				easing.bezierCurve: Motion.spatial
			}
		}
	}
}
