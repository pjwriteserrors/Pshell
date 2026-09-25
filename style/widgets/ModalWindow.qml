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
	property real reveal: root.shown ? 1 : 0
	property var targetScreen: Popups.primaryScreen
	default property alias content: holder.data
	readonly property Item contentItem: holder

	signal modalOpened

	onShownChanged: {
		if (root.shown) {
			root.targetScreen = Popups.modalScreen || Popups.primaryScreen;
			root.modalOpened();
			Qt.callLater(() => holder.forceActiveFocus());
		}
	}

	Behavior on reveal {
		NumberAnimation {
			duration: root.shown ? Motion.long : Motion.medium
			easing.type: Easing.BezierSpline
			easing.bezierCurve: root.shown ? Motion.decel : Motion.accel
		}
	}

	screen: root.targetScreen
	visible: root.shown || root.reveal > 0.002
	color: "transparent"
	anchors {
		left: true
		right: true
		top: true
		bottom: true
	}
	exclusiveZone: 0
	WlrLayershell.namespace: `shell-${root.modalId}`
	WlrLayershell.layer: WlrLayer.Overlay
	WlrLayershell.exclusionMode: ExclusionMode.Ignore
	WlrLayershell.keyboardFocus: root.shown ? (root.exclusiveKeyboard ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.OnDemand) : WlrKeyboardFocus.None

	Rectangle {
		anchors.fill: parent
		color: root.scrimColor
		opacity: root.reveal * root.scrimOpacity
	}

	MouseArea {
		anchors.fill: parent
		onClicked: Popups.closeModal()
	}

	FocusScope {
		id: holder

		anchors.fill: parent
		focus: true
		opacity: root.reveal
		scale: 0.94 + 0.06 * root.reveal
		transform: Translate {
			y: 24 * (1 - root.reveal)
		}

		Keys.onEscapePressed: Popups.closeModal()
	}
}
