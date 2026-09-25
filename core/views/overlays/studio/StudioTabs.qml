import QtQuick
import qs.style.theme
import qs.core.services
import qs.style.widgets

// The page switcher every Studio page carries. Ctrl+1…5 jump to a page,
// Ctrl+Tab / Ctrl+Shift+Tab step through them.
Segmented {
	id: root

	options: Popups.studioPages.map(page => ({ value: page.modal, label: page.label, icon: page.icon }))
	current: Popups.modal
	implicitWidth: 640
	onSelected: value => Popups.openModal(value, Popups.modalScreen)

	Repeater {
		model: Popups.studioPages

		delegate: Item {
			required property var modelData
			required property int index

			Shortcut {
				sequence: `Ctrl+${index + 1}`
				onActivated: Popups.openModal(modelData.modal, Popups.modalScreen)
			}
		}
	}

	Shortcut {
		sequence: "Ctrl+Tab"
		onActivated: Popups.stepStudio(1)
	}

	Shortcut {
		sequences: ["Ctrl+Shift+Tab", "Ctrl+Backtab"]
		onActivated: Popups.stepStudio(-1)
	}
}
