pragma Singleton

import QtQuick

// Central motion scale for the whole shell. Every popup, hover state and
// transition derives its timing from these values so the shell feels like
// one system instead of many hand-tuned animations.
QtObject {
	// durations
	readonly property int fast: ThemeEngine.fast
	readonly property int normal: ThemeEngine.normal
	readonly property int popupOpen: ThemeEngine.popupOpen
	readonly property int popupClose: ThemeEngine.popupClose
	readonly property int large: ThemeEngine.large
	readonly property int largeClose: ThemeEngine.largeClose

	// spatial bounce (Easing.OutBack overshoot parameter)
	readonly property real popupOvershoot: ThemeEngine.popupOvershoot
	readonly property real sheetOvershoot: ThemeEngine.sheetOvershoot
	readonly property real smallOvershoot: ThemeEngine.smallOvershoot
}
