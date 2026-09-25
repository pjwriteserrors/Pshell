import QtQuick
import qs.style.theme
import qs.core.services
import qs.style.widgets

// Pressable bar element. It does not paint its own hover state: it hands
// its geometry to the bar, whose single highlight glides between elements.
// When `panelId` is set the button registers where its panel should hang
// and shows an accent underline while that panel is open.
Item {
	id: root

	required property var bar
	property string panelId: ""
	property string tooltip: ""
	property bool wheelEnabled: false
	property real padding: 10
	property int acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
	// plain actions (focus a window, …) dismiss any open panel
	property bool closesPopups: root.panelId === ""
	// set when the press already closed this button's panel
	property bool swallowClick: false
	// the mouse button that toggles this button's panel
	property int toggleButton: Qt.LeftButton
	// a second button that toggles a different panel of the same element
	property int altToggleButton: 0

	// Closing happens on press, not on click: the first click after a panel
	// had keyboard focus often loses its release while the focus moves, so
	// a click-based close needed two clicks.
	function closeOnPress(button) {
		if (Popups.current === "") return false;
		if (button !== root.toggleButton && button !== root.altToggleButton) {
			if (button === Qt.LeftButton && root.closesPopups) Popups.close();
			return false;
		}
		const own = Popups.opener === root
			|| (root.panelId !== "" && Popups.current === root.panelId && Popups.screen === root.bar.screen && Popups.page === "");
		if (own) {
			Popups.close();
			return true;
		}
		if (root.closesPopups) Popups.close();
		return false;
	}
	readonly property bool hovered: mouse.containsMouse
	readonly property bool pressed: mouse.pressed
	readonly property bool active: root.panelId !== "" && Popups.current === root.panelId && Popups.screen === root.bar.screen
	default property alias content: holder.data

	signal clicked(var mouse)
	signal rightClicked(var mouse)
	signal middleClicked(var mouse)
	signal scrolled(var wheel)

	implicitHeight: Theme.barHeight
	implicitWidth: holder.childrenRect.width + root.padding * 2

	function register() {
		if (root.panelId === "" || !root.visible) return;
		const point = root.mapToItem(null, root.width / 2, 0);
		Popups.registerAnchor(root.bar.screen, root.panelId, point.x);
	}

	function toggle(page) {
		root.register();
		Popups.toggle(root.panelId, root.bar.screen, page, undefined, root);
	}

	// the default anchor for panelId; secondary openers only register on click
	property bool primaryAnchor: true

	// panels opened by keybind/IPC ask the bar where to hang
	Connections {
		target: Popups
		enabled: root.primaryAnchor && root.panelId !== ""
		function onAnchorRequested(screen, id) {
			if (id === root.panelId && screen === root.bar.screen) root.register();
		}
	}

	Component.onCompleted: if (root.primaryAnchor) Qt.callLater(root.register)
	onWidthChanged: if (root.primaryAnchor) Qt.callLater(root.register)

	Item {
		id: holder

		x: root.padding
		anchors.verticalCenter: parent.verticalCenter
		width: childrenRect.width
		height: parent.height
		scale: mouse.pressed ? 0.9 : 1

		Behavior on scale {
			NumberAnimation {
				duration: mouse.pressed ? Motion.micro : Motion.long
				easing.type: Easing.BezierSpline
				easing.bezierCurve: mouse.pressed ? Motion.standard : Motion.spatialFast
			}
		}
	}

	Rectangle {
		anchors.horizontalCenter: parent.horizontalCenter
		anchors.bottom: parent.bottom
		anchors.bottomMargin: 3
		height: 3
		radius: 1.5
		width: root.active ? Math.min(18, root.width - 12) : 0
		color: Theme.primary
		opacity: root.active ? 1 : 0

		Behavior on width {
			SpatialAnim {
				duration: Motion.medium
			}
		}
		Behavior on opacity {
			Anim {
				duration: Motion.short
			}
		}
	}

	MouseArea {
		id: mouse

		anchors.fill: parent
		hoverEnabled: true
		acceptedButtons: root.acceptedButtons
		cursorShape: Qt.PointingHandCursor
		onContainsMouseChanged: root.bar.setHover(root, containsMouse)
		onPressed: event => {
			root.swallowClick = root.closeOnPress(event.button);
		}
		onClicked: event => {
			if (root.swallowClick) {
				root.swallowClick = false;
				return;
			}
			if (event.button === Qt.RightButton) root.rightClicked(event);
			else if (event.button === Qt.MiddleButton) root.middleClicked(event);
			else root.clicked(event);
		}
		onWheel: wheel => {
			if (!root.wheelEnabled) {
				wheel.accepted = false;
				return;
			}
			root.scrolled(wheel);
		}
	}
}
