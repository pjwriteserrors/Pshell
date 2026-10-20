import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets

// A strip of a column that is there only at times: it grows to the height
// of what it holds and gives the room back, instead of pushing everything
// below it in one step.
Item {
	id: root

	property bool shown: false
	default property alias content: holder.data
	readonly property real full: holder.childrenRect.height

	Layout.fillWidth: true
	Layout.preferredHeight: root.shown ? root.full : 0
	// seen from the moment it is asked for, so what it holds can take the keyboard
	visible: root.shown || height > 0.5
	opacity: root.shown ? 1 : 0
	clip: height < root.full - 0.5

	Behavior on Layout.preferredHeight {
		SpatialAnim {
			duration: Motion.medium
		}
	}
	Behavior on opacity {
		Anim {
			duration: Motion.short
		}
	}

	Item {
		id: holder

		width: parent.width
		height: childrenRect.height
	}
}
