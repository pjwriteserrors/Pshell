import QtQuick

// What can be picked up: pressed and pulled a few pixels, the page carries
// `payload` (a function giving it, or the thing itself) under the pointer
// until it is let go over something that takes it. A plain click is tapped().
MouseArea {
	id: root

	property var page: null
	property var payload: null
	readonly property bool carrying: root.lifted
	property bool lifted: false
	// this press carried something: its release is no click
	property bool carried: false
	property real sx: 0
	property real sy: 0

	signal tapped(var mouse)
	signal doubleTapped(var mouse)
	signal menu(var mouse)

	hoverEnabled: true
	preventStealing: true
	acceptedButtons: Qt.LeftButton | Qt.RightButton
	cursorShape: root.lifted ? Qt.ClosedHandCursor : Qt.PointingHandCursor

	onPressed: mouse => {
		root.sx = mouse.x;
		root.sy = mouse.y;
		root.lifted = false;
		root.carried = false;
	}
	onPositionChanged: mouse => {
		if (!root.pressed || !(root.pressedButtons & Qt.LeftButton) || !root.page) return;
		if (!root.lifted) {
			if (Math.abs(mouse.x - root.sx) < 6 && Math.abs(mouse.y - root.sy) < 6) return;
			const what = typeof root.payload === "function" ? root.payload() : root.payload;
			if (!what) return;
			root.lifted = true;
			root.carried = true;
			root.page.lift(root, mouse, what);
		}
		root.page.haul(root, mouse);
	}
	onReleased: mouse => {
		if (!root.lifted) return;
		root.lifted = false;
		root.page.land();
	}
	onCanceled: {
		if (root.lifted && root.page) root.page.land();
		root.lifted = false;
	}
	onClicked: mouse => {
		if (root.carried) return;
		if (mouse.button === Qt.RightButton) root.menu(mouse);
		else root.tapped(mouse);
	}
	onDoubleClicked: mouse => {
		if (mouse.button === Qt.LeftButton) root.doubleTapped(mouse);
	}
}
