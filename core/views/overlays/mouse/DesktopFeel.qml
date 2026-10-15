pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// What the desktop does, felt: switching a workspace, the focus going to
// another monitor, windows coming and going, a window asking for you. A
// pulse each, or none.
ColumnLayout {
	id: root

	spacing: 8

	readonly property var moments: [
		{ id: "workspace", label: "Another workspace", icon: "view_grid_outline", fallback: "" },
		{ id: "monitor", label: "Focus to another monitor", icon: "monitor_multiple", fallback: "" },
		{ id: "open", label: "A window opens", icon: "window_open_variant", fallback: "" },
		{ id: "close", label: "A window closes", icon: "window_close", fallback: "" },
		{ id: "urgent", label: "A window wants attention", icon: "bell_ring_outline", fallback: "" }
	]
	readonly property var pulses: [
		{ value: "", label: "Off" },
		{ value: "WHISPER COLLISION", label: "Whisper" },
		{ value: "SUBTLE COLLISION", label: "Tick" },
		{ value: "DAMP STATE CHANGE", label: "Soft" },
		{ value: "KNOCK", label: "Knock" }
	]

	function set(moment, wave) {
		const feel = Object.assign({}, Mouse.option("feel", {}));
		if (wave) feel[moment] = wave;
		else delete feel[moment];
		Mouse.setOption("feel", feel);
		if (wave) Mouse.play(wave);
	}

	RowLayout {
		Layout.fillWidth: true
		spacing: 14

		Rectangle {
			Layout.preferredWidth: 36
			Layout.preferredHeight: 36
			radius: Theme.radius.medium
			color: Theme.primarySoft

			Glyph {
				anchors.centerIn: parent
				icon: "gesture_tap_hold"
				size: 18
				color: Theme.primary
			}
		}

		ColumnLayout {
			Layout.fillWidth: true
			spacing: 1

			StyledText {
				text: "Feel the desktop"
				font.weight: Font.DemiBold
			}

			StyledText {
				Layout.fillWidth: true
				text: "A pulse when something happens you would otherwise have to watch for"
				tone: Theme.textSubtle
				font.pixelSize: Theme.size.small
				wrapMode: Text.WordWrap
			}
		}
	}

	Repeater {
		model: root.moments

		delegate: RowLayout {
			id: row

			required property var modelData

			Layout.fillWidth: true
			Layout.leftMargin: 50
			spacing: 10

			Glyph {
				icon: row.modelData.icon
				size: 15
				color: Theme.textMuted
			}

			StyledText {
				Layout.fillWidth: true
				text: row.modelData.label
			}

			Segmented {
				Layout.preferredWidth: 340
				implicitHeight: 32
				options: root.pulses
				current: Mouse.option("feel", {})[row.modelData.id] ?? ""
				onSelected: value => root.set(row.modelData.id, value)
			}
		}
	}
}
