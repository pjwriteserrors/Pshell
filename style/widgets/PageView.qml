import QtQuick
import qs.style.theme

// Holds several pages (children) and shows the one whose `pageName` matches
// `current`. Pages slide sideways by their order and cross-fade; the height
// follows the visible page.
Item {
	id: root

	property string current: ""
	readonly property Item currentItem: {
		for (const child of root.children)
			if (child.pageName === root.current) return child;
		return root.children.length > 0 ? root.children[0] : null;
	}
	readonly property int currentIndex: {
		for (let i = 0; i < root.children.length; i += 1)
			if (root.children[i] === root.currentItem) return i;
		return 0;
	}

	implicitHeight: root.currentItem ? root.currentItem.implicitHeight : 0

	function pageIndex(item) {
		for (let i = 0; i < root.children.length; i += 1)
			if (root.children[i] === item) return i;
		return 0;
	}
}
