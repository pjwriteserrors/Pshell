import QtQuick
import QtQuick.Controls
import qs.style.theme

// Scroll indicator that stays out of the way until you scroll or hover it.
ScrollBar {
	id: bar

	policy: ScrollBar.AsNeeded
	padding: 2
	implicitWidth: 10

	contentItem: Rectangle {
		implicitWidth: bar.hovered || bar.pressed ? 6 : 3
		radius: width / 2
		color: bar.pressed ? Theme.textMuted : Theme.textSubtle
		opacity: bar.active || bar.hovered ? 1 : 0

		Behavior on opacity {
			Anim {
				duration: Motion.medium
			}
		}
		Behavior on implicitWidth {
			Anim {
				duration: Motion.short
			}
		}
	}

	background: Item {}
}
