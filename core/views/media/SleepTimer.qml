import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// The sleep timer for the browser's media (WebPlayback): pause in 15, 30 or
// 60 minutes or when the episode ends; while it waits, the time left and a
// way back.
RowLayout {
	id: root

	readonly property bool armed: WebPlayback.sleepMode !== ""

	spacing: 6

	Glyph {
		icon: "power_sleep"
		size: 16
		color: root.armed ? Theme.primary : Theme.textMuted
	}

	Repeater {
		model: root.armed ? [] : [15, 30, 60]

		delegate: Chip {
			required property int modelData

			text: `${modelData} min`
			onClicked: WebPlayback.sleepIn(modelData)
		}
	}

	Chip {
		visible: !root.armed
		text: "End of this"
		onClicked: WebPlayback.sleepAfterThis()
	}

	StyledText {
		Layout.fillWidth: true
		visible: root.armed
		tabular: true
		text: {
			const left = WebPlayback.sleepLeft;
			const time = left > 0 ? `${Math.floor(left / 60)}:${String(Math.floor(left % 60)).padStart(2, "0")}` : "";
			if (WebPlayback.sleepMode === "episode") return time !== "" ? `End of this · ${time}` : "End of this";
			return WebPlayback.sleepFading ? "Fading out" : time;
		}
		tone: Theme.text
		font.pixelSize: Theme.size.label
	}

	Item {
		Layout.fillWidth: true
		visible: !root.armed
	}

	IconButton {
		visible: root.armed
		implicitWidth: 28
		implicitHeight: 28
		iconSize: 16
		icon: "close"
		onClicked: WebPlayback.cancelSleep()
	}
}
