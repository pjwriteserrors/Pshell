import QtQuick
import qs.style.theme

// A page inside PageView.
Item {
	id: root

	required property string pageName
	readonly property var view: parent
	readonly property bool current: root.view && root.view.currentItem === root
	readonly property int order: root.view ? root.view.pageIndex(root) : 0
	default property alias content: holder.data

	width: parent ? parent.width : 0
	implicitHeight: holder.childrenRect.height
	opacity: root.current ? 1 : 0
	visible: opacity > 0.01
	x: root.current ? 0 : (root.order < (root.view?.currentIndex ?? 0) ? -48 : 48)
	enabled: root.current

	Behavior on opacity {
		Anim {
			duration: root.current ? Motion.medium : Motion.short
		}
	}
	Behavior on x {
		SpatialAnim {
			duration: Motion.long
		}
	}

	Item {
		id: holder

		width: parent.width
		height: childrenRect.height
	}
}
