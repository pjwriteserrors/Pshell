pragma Singleton

import QtQuick
import Quickshell

// Tells a pointer that moved from one that things moved under: a popup that
// opens beneath the resting pointer, a list that is filtered or scrolled by
// the keyboard. Lists select on hover only when moved() says so.
Singleton {
	id: root

	// where the pointer was last seen, and on which surface
	property var surface: null
	property real x: 0
	property real y: 0
	property bool seen: false

	// x, y: the pointer in `item`
	function moved(item, x, y) {
		let top = item;
		while (top.parent) top = top.parent;
		const at = item.mapToItem(null, x, y);
		const known = root.seen && top === root.surface;
		const rests = known && Math.abs(at.x - root.x) < 1 && Math.abs(at.y - root.y) < 1;
		root.surface = top;
		root.x = at.x;
		root.y = at.y;
		root.seen = true;
		return known && !rests;
	}

	// what opens next meets the pointer anew
	Connections {
		target: Popups
		function onCurrentChanged() {
			root.seen = false;
		}
		function onModalChanged() {
			root.seen = false;
		}
	}
}
