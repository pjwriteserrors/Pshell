import QtQuick

// Bouncy size/position animation for small UI elements.
NumberAnimation {
	duration: Motion.normal
	easing.type: ThemeEngine.emphasizedEasing
	easing.overshoot: Motion.smallOvershoot
}
