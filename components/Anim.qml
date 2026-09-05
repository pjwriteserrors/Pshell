import QtQuick

// Default fade/move animation: no overshoot, decisive deceleration.
NumberAnimation {
	duration: Motion.normal
	easing.type: ThemeEngine.standardEasing
}
