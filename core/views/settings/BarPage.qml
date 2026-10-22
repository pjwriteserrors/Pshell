pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// What the bar shows and where (BarLayout, BarEditor), how a new
// wallpaper comes in (Wallpaper): out of the bar, a fade or at once, and
// what the overview shows behind the workspaces; what game mode does.
SettingsPage {
	id: root

	title: "Desktop"
	description: "Put the bar together from everything the plugins that are on offer, choose how a new wallpaper comes in and what game mode does."

	component Switch: RowLayout {
		id: line

		property string text: ""
		property string detail: ""
		property bool checked: false
		signal toggled(bool on)

		Layout.fillWidth: true
		spacing: 14

		ColumnLayout {
			Layout.fillWidth: true
			spacing: 1

			StyledText {
				text: line.text
				font.weight: Font.Medium
			}

			StyledText {
				Layout.fillWidth: true
				text: line.detail
				tone: Theme.textSubtle
				font.pixelSize: Theme.size.small
				wrapMode: Text.WordWrap
			}
		}

		Toggle {
			checked: line.checked
			onToggled: on => line.toggled(on)
		}
	}

	SettingCard {
		anchor: "bar-items"
		title: "Bar"
		subtitle: `${BarLayout.left.length + BarLayout.center.length + BarLayout.right.length} items on the bar, ${BarLayout.shelf.length} more to place`
		icon: "dock_window"

		BarEditor {
			Layout.fillWidth: true
		}
	}

	// how the panels hanging from the bar open
	SettingCard {
		anchor: "popup-motion"
		title: "Popups"
		subtitle: "How the panels open out of the bar. Each tile plays its motion; click one to use it."
		icon: "animation_play_outline"
		modified: PopupMotion.style !== "classic" || PopupMotion.speed !== 1
		onReset: {
			PopupMotion.set("style", "classic");
			PopupMotion.set("speed", 1);
		}

		GridLayout {
			Layout.fillWidth: true
			columns: 3
			columnSpacing: 10
			rowSpacing: 10

			Repeater {
				model: PopupMotion.styles

				delegate: PopupMotionTile {
					required property var modelData

					Layout.fillWidth: true
					Layout.preferredHeight: 150
					entry: modelData
					playing: root.active
					onPicked: PopupMotion.set("style", modelData.id)
				}
			}
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 12

			ValueSlider {
				from: 0.6
				to: 1.6
				step: 0.05
				label: "Speed"
				value: PopupMotion.speed
				format: v => v < 0.9 ? `${Math.round(v * 100)}% – slower` : (v > 1.1 ? `${Math.round(v * 100)}% – quicker` : `${Math.round(v * 100)}%`)
				onMoved: v => PopupMotion.set("speed", Math.round(v * 20) / 20)
			}
		}
	}

	SettingCard {
		anchor: "wallpaper-change"
		title: "New wallpaper"
		subtitle: "How a picture takes over from the last one"
		icon: "wallpaper"
		visible: Wallpaper.enabled

		Segmented {
			Layout.fillWidth: true
			options: [{ value: "bloom", label: "Out of the bar", icon: "creation" }, { value: "fade", label: "Fade", icon: "blur" }, { value: "none", label: "At once", icon: "flash" }]
			current: Wallpaper.transition
			onSelected: value => Wallpaper.setTransition(value)
		}
	}

	SettingCard {
		anchor: "wallpaper-backdrop"
		title: "Behind the workspaces"
		subtitle: "What the overview and the gaps between workspaces show"
		icon: "view_dashboard_outline"
		visible: Wallpaper.enabled

		Segmented {
			Layout.fillWidth: true
			options: [{ value: "sharp", label: "The wallpaper" }, { value: "blur", label: "Blurred" }, { value: "dim", label: "Dimmed" }]
			current: Wallpaper.backdrop
			onSelected: value => Wallpaper.setBackdrop(value)
		}
	}

	SettingCard {
		anchor: "game-mode"
		title: "Game mode"
		subtitle: GameMode.active ? `On${GameMode.title !== "" ? ` – ${GameMode.title}` : ""}` : "Comes on by itself while a game's window is open"
		icon: "gamepad_variant"
		visible: GameMode.enabled

		Segmented {
			Layout.fillWidth: true
			options: [{ value: "auto", label: "With the games" }, { value: "on", label: "Always on" }, { value: "off", label: "Off" }]
			current: GameMode.force
			onSelected: value => GameMode.setForce(value)
		}

		Switch {
			text: "Rest Find my mouse"
			detail: "Shaking the mouse in a game does not light it up"
			checked: GameMode.pauseFindMouse
			onToggled: on => GameMode.setOption("pauseFindMouse", on)
		}

		Switch {
			text: "Quiet notifications"
			detail: "Do not disturb while a game runs"
			checked: GameMode.quietNotifications
			onToggled: on => GameMode.setOption("quietNotifications", on)
		}
	}
}
