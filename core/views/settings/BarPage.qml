pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// What the bar shows and where (BarLayout, BarEditor), and how a new
// wallpaper comes in (Wallpaper): out of the bar, a fade or at once, and
// what the overview shows behind the workspaces.
SettingsPage {
	id: root

	title: "Bar & wallpaper"
	description: "Put the bar together from everything the plugins that are on offer, and choose how a new wallpaper comes in."

	SettingCard {
		anchor: "bar-items"
		title: "Bar"
		subtitle: `${BarLayout.left.length + BarLayout.center.length + BarLayout.right.length} items on the bar, ${BarLayout.shelf.length} more to place`
		icon: "dock_window"

		BarEditor {
			Layout.fillWidth: true
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
}
