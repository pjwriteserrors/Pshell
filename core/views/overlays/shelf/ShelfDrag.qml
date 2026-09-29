import QtQuick
import qs.core.services

// The pointer layer of a shelf entry: a click selects, a double click
// opens, a right click asks for the menu, and a drag carries `items` out of
// the shell to any app (files as URIs, links, text). The drag moves an
// invisible ghost, so the entry itself stays where it is; a snapshot of
// `preview` follows the pointer.
MouseArea {
	id: root

	property var items: []
	property Item preview: null
	readonly property bool dragging: root.drag.active

	signal selected(bool add)
	signal menuRequested(real x, real y)
	signal opened

	acceptedButtons: Qt.LeftButton | Qt.RightButton
	hoverEnabled: true
	// a list around it must not turn the drag into scrolling
	preventStealing: true
	cursorShape: root.pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
	drag.target: ghost
	drag.threshold: 6

	onPressed: event => {
		ghost.x = event.x;
		ghost.y = event.y;
		if (root.preview) root.preview.grabToImage(result => ghost.Drag.imageSource = result.url, Qt.size(72, 72));
	}
	onClicked: event => {
		if (event.button === Qt.RightButton) root.menuRequested(event.x, event.y);
		else root.selected((event.modifiers & Qt.ControlModifier) !== 0);
	}
	onDoubleClicked: event => {
		if (event.button === Qt.LeftButton) root.opened();
	}

	Item {
		id: ghost

		width: 1
		height: 1

		Drag.dragType: Drag.Automatic
		Drag.active: root.drag.active
		Drag.supportedActions: Qt.CopyAction | Qt.MoveAction | Qt.LinkAction
		Drag.proposedAction: Qt.CopyAction
		Drag.hotSpot: Qt.point(36, 36)
		Drag.mimeData: Shelf.mimeFor(root.items)
	}
}
