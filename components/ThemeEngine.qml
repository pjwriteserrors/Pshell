pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

QtObject {
	id: root

	property string requestedThemeId: "atelier"
	property string currentThemeId: "atelier"
	property var availableThemes: []
	property var activeTokens: ({})
	property bool ready: false
	property bool stateLoaded: false
	property string error: ""

	readonly property string statePath: `${Quickshell.shellDir}/ui-theme.json`
	readonly property string catalogScriptPath: `${Quickshell.shellDir}/scripts/theme_engine.py`
	readonly property var fallbackTokens: ({
		radiusTiny: 1, radiusSmall: 2, radiusMedium: 3, radiusLarge: 4,
		fast: 120, normal: 220, popupOpen: 320, popupClose: 220,
		large: 420, largeClose: 280, standardEasing: "outCubic",
		emphasizedEasing: "outBack", popupOpenEasing: "outBack",
		modalOpenEasing: "outBack", exitEasing: "outCubic",
		elasticAmplitude: 1, elasticPeriod: 0.3,
		popupOvershoot: 1.05, sheetOvershoot: 1.15, smallOvershoot: 1.4,
		popupStartScale: 0.94, popupTravel: -14,
		popupContentRevealStart: 0.2, popupOpacityMultiplier: 1.6,
		popupShadowDepth: 1,
		modalStartScale: 0.92, modalBottomTravelFactor: 0.16,
		modalShadowDepth: 1.15, controlDepth: 0, controlHoverDepth: 0,
		controlPressedDepth: 0, bevelOpacity: 0, insetOpacity: 0,
		controlEffectsEnabled: false, shadowEnabled: false,
		shadowBlur: 0, shadowOffset: 0, shadowSpread: 0,
		darkShadowOpacity: 0, lightShadowOpacity: 0,
		hoverScale: 1, pressedScale: 1,
		outlineWidth: 0, outlineOpacity: 0, hardShadow: false,
		pressTravel: 0, hoverLift: 0, rippleEnabled: true,
		hoverTintOpacity: 0.08, pressedTintOpacity: 0.14,
		toastStartScale: 1, toastTravel: 0, toastRotation: 0,
		toastOpen: 320, solidSurfaces: false,
		ornamentStyle: "none", ornamentOpacity: 0,
		ornamentLineWidth: 1, ornamentInset: 3,
		ornamentCornerLength: 14, ornamentNotchSize: 4,
		ornamentDoubleLine: false, ornamentCenterMarks: false,
			ornamentTrackCaps: false, ornamentGlowOpacity: 0,
			ornamentPulseDuration: 1800,
			dialogueNotifications: false
	})
	readonly property var tokens: Object.assign({}, root.fallbackTokens, root.activeTokens || {})

	readonly property real radiusTiny: Number(root.tokens.radiusTiny)
	readonly property real radiusSmall: Number(root.tokens.radiusSmall)
	readonly property real radiusMedium: Number(root.tokens.radiusMedium)
	readonly property real radiusLarge: Number(root.tokens.radiusLarge)
	readonly property int fast: Number(root.tokens.fast)
	readonly property int normal: Number(root.tokens.normal)
	readonly property int popupOpen: Number(root.tokens.popupOpen)
	readonly property int popupClose: Number(root.tokens.popupClose)
	readonly property int large: Number(root.tokens.large)
	readonly property int largeClose: Number(root.tokens.largeClose)
	readonly property int standardEasing: root.easingValue(root.tokens.standardEasing)
	readonly property int emphasizedEasing: root.easingValue(root.tokens.emphasizedEasing)
	readonly property int popupOpenEasing: root.easingValue(root.tokens.popupOpenEasing)
	readonly property int modalOpenEasing: root.easingValue(root.tokens.modalOpenEasing)
	readonly property int exitEasing: root.easingValue(root.tokens.exitEasing)
	readonly property real elasticAmplitude: Number(root.tokens.elasticAmplitude)
	readonly property real elasticPeriod: Number(root.tokens.elasticPeriod)
	readonly property real popupOvershoot: Number(root.tokens.popupOvershoot)
	readonly property real sheetOvershoot: Number(root.tokens.sheetOvershoot)
	readonly property real smallOvershoot: Number(root.tokens.smallOvershoot)
	readonly property real popupStartScale: Number(root.tokens.popupStartScale)
	readonly property real popupTravel: Number(root.tokens.popupTravel)
	readonly property real popupContentRevealStart: Number(root.tokens.popupContentRevealStart)
	readonly property real popupOpacityMultiplier: Number(root.tokens.popupOpacityMultiplier)
	readonly property real popupShadowDepth: Number(root.tokens.popupShadowDepth)
	readonly property real modalStartScale: Number(root.tokens.modalStartScale)
	readonly property real modalBottomTravelFactor: Number(root.tokens.modalBottomTravelFactor)
	readonly property real modalShadowDepth: Number(root.tokens.modalShadowDepth)
	readonly property real controlDepth: Number(root.tokens.controlDepth)
	readonly property real controlHoverDepth: Number(root.tokens.controlHoverDepth)
	readonly property real controlPressedDepth: Number(root.tokens.controlPressedDepth)
	readonly property real bevelOpacity: Number(root.tokens.bevelOpacity)
	readonly property real insetOpacity: Number(root.tokens.insetOpacity)
	readonly property bool controlEffectsEnabled: Boolean(root.tokens.controlEffectsEnabled)
	readonly property bool shadowEnabled: Boolean(root.tokens.shadowEnabled)
	readonly property real shadowBlur: Number(root.tokens.shadowBlur)
	readonly property real shadowOffset: Number(root.tokens.shadowOffset)
	readonly property real shadowSpread: Number(root.tokens.shadowSpread)
	readonly property real darkShadowOpacity: Number(root.tokens.darkShadowOpacity)
	readonly property real lightShadowOpacity: Number(root.tokens.lightShadowOpacity)
	readonly property real hoverScale: Number(root.tokens.hoverScale)
	readonly property real pressedScale: Number(root.tokens.pressedScale)
	readonly property real outlineWidth: Number(root.tokens.outlineWidth)
	readonly property real outlineOpacity: Number(root.tokens.outlineOpacity)
	readonly property bool hardShadow: Boolean(root.tokens.hardShadow)
	readonly property real pressTravel: Number(root.tokens.pressTravel)
	readonly property real hoverLift: Number(root.tokens.hoverLift)
	readonly property bool rippleEnabled: Boolean(root.tokens.rippleEnabled)
	readonly property real hoverTintOpacity: Number(root.tokens.hoverTintOpacity)
	readonly property real pressedTintOpacity: Number(root.tokens.pressedTintOpacity)
	readonly property real toastStartScale: Number(root.tokens.toastStartScale)
	readonly property real toastTravel: Number(root.tokens.toastTravel)
	readonly property real toastRotation: Number(root.tokens.toastRotation)
	readonly property int toastOpen: Number(root.tokens.toastOpen)
	readonly property bool solidSurfaces: Boolean(root.tokens.solidSurfaces)
	readonly property string ornamentStyle: String(root.tokens.ornamentStyle || "none")
	readonly property real ornamentOpacity: Number(root.tokens.ornamentOpacity)
	readonly property real ornamentLineWidth: Number(root.tokens.ornamentLineWidth)
	readonly property real ornamentInset: Number(root.tokens.ornamentInset)
	readonly property real ornamentCornerLength: Number(root.tokens.ornamentCornerLength)
	readonly property real ornamentNotchSize: Number(root.tokens.ornamentNotchSize)
	readonly property bool ornamentDoubleLine: Boolean(root.tokens.ornamentDoubleLine)
	readonly property bool ornamentCenterMarks: Boolean(root.tokens.ornamentCenterMarks)
	readonly property bool ornamentTrackCaps: Boolean(root.tokens.ornamentTrackCaps)
	readonly property real ornamentGlowOpacity: Number(root.tokens.ornamentGlowOpacity)
	readonly property int ornamentPulseDuration: Number(root.tokens.ornamentPulseDuration)
	readonly property bool dialogueNotifications: Boolean(root.tokens.dialogueNotifications)
	readonly property real shadowRenderMargin: root.shadowEnabled
		? Math.ceil(root.shadowBlur * 0.75 + Math.abs(root.shadowOffset) + root.outlineWidth)
		: 0

	function contrastEdge(surfaceColor, opacity) {
		const color = surfaceColor || "transparent";
		const luminance = color.r * 0.2126 + color.g * 0.7152 + color.b * 0.0722;
		const edge = luminance < 0.34 ? Qt.lighter(color, 2.5) : Qt.darker(color, 2.8);
		return Qt.alpha(edge, opacity === undefined ? root.outlineOpacity : opacity);
	}

	function solidColor(surfaceColor) {
		const color = surfaceColor || "transparent";
		return Qt.rgba(color.r, color.g, color.b, color.a > 0.015 ? 1 : 0);
	}

	function easingValue(name) {
		switch (String(name || "")) {
		case "outQuart": return Easing.OutQuart;
		case "outQuint": return Easing.OutQuint;
		case "outExpo": return Easing.OutExpo;
		case "outBack": return Easing.OutBack;
		case "outElastic": return Easing.OutElastic;
		case "inCubic": return Easing.InCubic;
		case "inQuart": return Easing.InQuart;
		default: return Easing.OutCubic;
		}
	}

	function duration(baseDuration) {
		return Math.max(1, Math.round(Number(baseDuration) * root.normal / root.fallbackTokens.normal));
	}

	function themeById(themeId) {
		for (const theme of root.availableThemes) {
			if (String(theme.id || "") === String(themeId || "")) return theme;
		}
		return null;
	}

	function activate(themeId, persist) {
		const theme = root.themeById("atelier");
		if (!theme) return false;
		root.currentThemeId = String(theme.id);
		root.activeTokens = theme.tokens || {};

		return true;
	}

	function selectTheme(themeId) {
		return root.activate(themeId, true);
	}

	function reloadCatalog() {
		catalogProcess.running = false;
		catalogProcess.command = ["python3", root.catalogScriptPath];
		catalogProcess.running = true;
	}

	function parseState(raw) {
		try {
			root.requestedThemeId = String(JSON.parse(String(raw || "{}"))?.theme || "default");
		} catch (parseError) {
			root.requestedThemeId = "default";
		}
		if (root.availableThemes.length > 0) root.activate(root.requestedThemeId, false);
		root.stateLoaded = true;
	}



	property Process catalogProcess: Process {
		stdout: StdioCollector {
			onStreamFinished: {
				try {
					root.availableThemes = JSON.parse(String(text || "[]"));
					root.error = "";
					root.ready = true;
					root.activate(root.requestedThemeId, false);
				} catch (parseError) {
					root.error = String(parseError);
					root.ready = false;
				}
			}
		}
		onExited: function(exitCode) {
			if (exitCode !== 0) {
				root.error = "Could not load UI theme catalog";
				root.ready = false;
			}
		}
	}

	Component.onCompleted: root.reloadCatalog()
}
