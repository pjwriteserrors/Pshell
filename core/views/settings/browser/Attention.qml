pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services
import qs.core.views.settings

// Settings › Browser: what plays (WebPlayback: sleep timer, calls, the watch)
// and the scroll brake (WebAssist).
ColumnLayout {
	id: root

	spacing: Theme.gap.md

	SettingCard {
		anchor: "browser-playback"
		title: "What plays"
		icon: "play_circle_outline"
		visible: Plugins.on("browser-media")

		FlagRow {
			title: "Pause for calls"
			icon: "phone_ring"
			checked: WebPlayback.calls
			onToggled: on => WebPlayback.set("calls", on)
		}

		FlagRow {
			title: "Watch steers the tab"
			icon: "watch"
			visible: Plugins.on("amazfit")
			checked: WebPlayback.remote
			onToggled: on => WebPlayback.set("remote", on)
		}

		FlagRow {
			title: "Screen off after the sleep timer"
			icon: "monitor_off"
			checked: WebPlayback.screenOff
			onToggled: on => WebPlayback.set("screenOff", on)
		}
	}

	SettingCard {
		anchor: "browser-brake"
		title: "Scroll brake"
		icon: "timer_sand"
		visible: Plugins.on("browser-brake")

		ValueSlider {
			from: 5
			to: 60
			step: 5
			icon: "timer_outline"
			label: "After"
			unit: " min"
			value: WebAssist.brakeMinutes
			onMoved: v => WebAssist.setBrake(v)
		}

		Field {
			id: sites

			Layout.fillWidth: true
			clearable: false
			icon: "web"
			placeholder: "reddit.com, youtube.com/shorts"
			text: WebAssist.brakeSites.join(", ")
			function commit() {
				const list = sites.text.split(",").map(site => site.trim()).filter(site => site !== "");
				if (list.join(", ") !== WebAssist.brakeSites.join(", ")) WebAssist.setBrake(null, list);
				sites.text = Qt.binding(() => WebAssist.brakeSites.join(", "));
			}
			onAccepted: sites.commit()
			onFocusedChanged: if (!sites.focused) sites.commit()
		}
	}
}
