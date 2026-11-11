import QtQuick
import qs.style.theme
import qs.style.widgets

// The 79 classic Bluetooth channels, 2402–2480 MHz, one cell per MHz.
// `used` is a link's AFH map (hex, bit set = in use), `avoid` the channels
// the host marks bad; the Wi-Fi channel lies over them as a band. With
// `editable` a click or a drag across cells marks or frees them.
Item {
	id: root

	property string used: ""
	property var avoid: []
	property var wifi: null
	property bool editable: false
	property real cellGap: 1

	signal changed(var avoid)

	// while a drag marks cells; handed on when it ends
	property var draft: null
	readonly property var shownAvoid: root.draft ?? root.avoid

	implicitHeight: root.editable ? 46 : 22

	readonly property real cell: width / 79
	readonly property var usedBits: {
		const out = [];
		if (!root.used) return out;
		for (let k = 0; k < 79; k++) {
			const byte = parseInt(root.used.substr(Math.floor(k / 8) * 2, 2), 16) || 0;
			out.push((byte >> (k % 8) & 1) === 1);
		}
		return out;
	}
	readonly property var wifiBand: {
		if (!root.wifi || !root.wifi.freq) return null;
		const half = (root.wifi.width || 20) / 2;
		return [root.wifi.freq - half - 2402, root.wifi.freq + half - 2402];
	}

	// the band of the Wi-Fi channel
	Rectangle {
		visible: root.wifiBand !== null
		x: Math.max(0, (root.wifiBand?.[0] ?? 0) * root.cell)
		width: Math.min(root.width, ((root.wifiBand?.[1] ?? 0) - (root.wifiBand?.[0] ?? 0)) * root.cell)
		y: 0
		height: bar.height + 6
		radius: 4
		color: Qt.alpha(Theme.warning, 0.18)
		border.width: 1
		border.color: Qt.alpha(Theme.warning, 0.5)
	}

	Row {
		id: bar

		y: 3
		width: parent.width
		height: root.editable ? 26 : 16
		spacing: 0

		Repeater {
			model: 79

			Item {
				id: slot

				required property int index
				readonly property bool avoided: root.shownAvoid.includes(slot.index)
				readonly property bool inUse: root.usedBits.length ? root.usedBits[slot.index] : !slot.avoided

				width: root.cell
				height: bar.height

				Rectangle {
					anchors.fill: parent
					anchors.leftMargin: root.cellGap / 2
					anchors.rightMargin: root.cellGap / 2
					radius: 1.5
					color: slot.avoided ? Qt.alpha(Theme.danger, 0.55) : (slot.inUse ? Qt.alpha(Theme.primary, 0.75) : Theme.layer3)
					Behavior on color {
						ColorAnimation {
							duration: 140
						}
					}
				}
			}
		}
	}

	// MHz marks under the bar
	Repeater {
		model: root.editable ? [2402, 2412, 2422, 2432, 2442, 2452, 2462, 2472, 2480] : []

		StyledText {
			required property var modelData

			x: Math.min(root.width - width, Math.max(0, (modelData - 2402 + 0.5) * root.cell - width / 2))
			y: bar.y + bar.height + 3
			text: modelData
			font.pixelSize: Theme.size.tiny
			tone: Theme.textSubtle
			tabular: true
		}
	}

	MouseArea {
		anchors.fill: bar
		enabled: root.editable
		cursorShape: Qt.PointingHandCursor
		preventStealing: true

		property bool marking: true
		property int last: -1

		function at(x) {
			return Math.max(0, Math.min(78, Math.floor(x / root.cell)));
		}

		function apply(k) {
			if (k === last) return;
			last = k;
			const set = root.shownAvoid.slice();
			const i = set.indexOf(k);
			if (marking && i < 0) set.push(k);
			if (!marking && i >= 0) set.splice(i, 1);
			set.sort((a, b) => a - b);
			root.draft = set;
		}

		onPressed: mouse => {
			const k = at(mouse.x);
			marking = !root.shownAvoid.includes(k);
			last = -1;
			apply(k);
		}
		onPositionChanged: mouse => {
			if (pressed) apply(at(mouse.x));
		}
		onReleased: {
			const set = root.shownAvoid;
			root.draft = null;
			root.changed(set);
		}
	}
}
