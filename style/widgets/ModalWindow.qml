import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.style.theme
import qs.core.services

// Full-screen surface for session menu and pickers. The desktop dims, the
// content rises a little while scaling up; closing is a quick fade.
PanelWindow {
	id: root

	required property string modalId
	property bool exclusiveKeyboard: false
	property real scrimOpacity: 1
	property color scrimColor: Theme.scrim
	readonly property bool shown: Popups.modal === root.modalId
	property real reveal: 0
	// which way it goes, set before reveal changes so the Behavior takes
	// the right duration and curve
	property bool entering: false
	// out of the way, clicks going to what is below
	property bool aside: false
	property real veil: root.aside ? 0 : 1
	property var targetScreen: Popups.primaryScreen
	// Closed, the window stays: a strip of one pixel that lets every click
	// through. Hidden it would be destroyed, and the next opening built a new
	// one with its whole scene, a first frame that swallowed the way in.
	// The content keeps the screen's size meanwhile: lay it out against
	// these, not against the window.
	readonly property bool expanded: root.shown || root.reveal > 0.002
	readonly property real areaWidth: root.screen?.width ?? root.width
	readonly property real areaHeight: root.screen?.height ?? root.height
	// the window has the screen's size only once the compositor answered
	readonly property bool placed: Math.abs(root.width - root.areaWidth) < 2 && root.height > 1
	onPlacedChanged: if (root.shown && root.placed) root.reveal = 1
	default property alias content: holder.data
	readonly property Item contentItem: holder

	signal modalOpened

	// built when it opens (Popups.wanted): then it rises just the same
	onShownChanged: root.followShown()
	// Visible only a moment after it was built: on a reload Quickshell takes
	// over the old window of an instance that is visible from the start, and
	// moving that one to another screen (the new instance starts on the
	// primary one) crashes it in QWindow::setScreen. So the old one goes and
	// a new one is made.
	property bool alive: false
	Component.onCompleted: {
		Qt.callLater(() => root.alive = true);
		if (root.shown) root.followShown();
	}

	function followShown() {
		if (root.shown) {
			root.targetScreen = Popups.modalScreen || Popups.primaryScreen;
			root.modalOpened();
			Qt.callLater(() => holder.forceActiveFocus());
		}
		root.entering = root.shown;
		if (!root.shown || root.placed) root.reveal = root.shown ? 1 : 0;
	}

	Behavior on reveal {
		NumberAnimation {
			duration: root.entering ? Motion.long : Motion.medium
			easing.type: Easing.BezierSpline
			easing.bezierCurve: root.entering ? Motion.decel : Motion.accel
		}
	}

	Behavior on veil {
		NumberAnimation {
			duration: Motion.medium
		}
	}

	screen: root.targetScreen
	mask: root.aside || !root.expanded ? nothing : null
	visible: root.alive
	color: "transparent"
	anchors {
		left: true
		right: true
		top: true
		bottom: root.expanded
	}
	implicitHeight: 1
	exclusiveZone: 0
	WlrLayershell.namespace: `shell-${root.modalId}`
	WlrLayershell.layer: WlrLayer.Overlay
	WlrLayershell.exclusionMode: ExclusionMode.Ignore
	WlrLayershell.keyboardFocus: root.shown ? (root.exclusiveKeyboard ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.OnDemand) : WlrKeyboardFocus.None

	Rectangle {
		anchors.fill: parent
		color: root.scrimColor
		opacity: root.reveal * root.scrimOpacity * root.veil
	}

	Region {
		id: nothing
	}

	MouseArea {
		anchors.fill: parent
		onClicked: Popups.closeModal()
	}

	FocusScope {
		id: holder

		width: root.areaWidth
		height: root.areaHeight
		focus: true
		opacity: root.reveal * root.veil
		scale: 0.94 + 0.06 * root.reveal
		transform: Translate {
			y: 24 * (1 - root.reveal)
		}

		Keys.onEscapePressed: Popups.closeModal()
	}
}
