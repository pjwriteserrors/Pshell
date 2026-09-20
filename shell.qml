pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Controls.impl as QQCImpl
import QtQuick.Effects
import QtQuick.Layouts
import QtQuick.Shapes
import QtQml
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.Mpris
import Quickshell.Services.Notifications
import Quickshell.Services.SystemTray
import Quickshell.Widgets
import "components"
import "components/ArcInk.js" as Ink

Scope {
	id: root

	property int nextToastId: 0
	property var toasts: []
	property var notificationGroups: []
	property bool clockPopupOpen: false
	property bool clockPopupVisible: false
	property bool weatherPopupOpen: false
	property bool weatherPopupVisible: false
	property bool notifPopupOpen: false
	property bool notifPopupVisible: false
	property bool mediaPopupOpen: false
	property bool mediaPopupVisible: false
	property bool clipboardPopupOpen: false
	property bool clipboardPopupVisible: false
	property bool bluetoothPopupOpen: false
	property bool bluetoothPopupVisible: false
	property bool networkPopupOpen: false
	property bool networkPopupVisible: false
	property bool resourcesPopupOpen: false
	property bool resourcesPopupVisible: false
	property bool powerPopupOpen: false
	property bool powerPopupVisible: false
	property int powerSelectionIndex: 0
	// Name of the style branch this config was loaded from, and whether a
	// switch to another one is in flight.
	readonly property string styleId: {
		try {
			return String(JSON.parse(styleManifest.text()).name || "");
		} catch (error) {
			return "";
		}
	}
	property bool styleSwitching: false

	// Studio: one window for wallpaper and colours, window motion, and the
	// style branch. It replaced four separate pickers that each had their own
	// window, own shortcut and own launcher command.
	property bool studioPopupOpen: false
	property bool studioPopupVisible: false
	// Page to show when Studio opens. Wallpaper and colours is the page that
	// gets used a dozen times a day, so it is the default.
	property string studioPage: "wallpaper"
	property string networkStatusType: "offline"
	property bool launcherPopupOpen: false
	property bool launcherPopupVisible: false
	property bool osdVisible: false
	property string osdKind: ""
	property string osdLabel: ""
	property string osdValueText: ""
	property real osdProgress: 0
	property string osdIconSource: ""
	property string brightnessRequestKind: ""
	property string volumeRequestKind: "volume"
	property bool trayMenuOpen: false
	property bool trayMenuVisible: false
	property var trayMenuHandle: null
	property Item trayMenuTargetItem: null
	// Tissue roles. Every one of them comes out of Bio, which is the only place
	// the Wallust palette is read and the only place contrast is decided. A
	// colour is never picked here by palette slot — "color4" is not a role.
	readonly property color secondaryBoxColor: Arc.leaf2
	readonly property color secondaryBoxStrongColor: Arc.leaf3
	readonly property color secondaryInsetColor: Arc.well
	readonly property color surface: Arc.leaf1
	readonly property color surfaceBorder: Arc.giltDim
	readonly property color onPrimary: Arc.onAether
	readonly property color danger: Arc.bane
	readonly property var primaryBarScreen: {
		for (const screen of Quickshell.screens) {
			if (String(screen.name || "") === "DP-2") return screen;
		}
		return Quickshell.screens.length > 0 ? Quickshell.screens[0] : null;
	}
	readonly property var extraBarScreens: Quickshell.screens.filter(screen => screen !== root.primaryBarScreen)
	// Snapshot of the focused output used by every popup. It is refreshed just
	// before a popup opens so keyboard shortcuts and bar clicks behave alike.
	property var activePopupScreen: root.primaryBarScreen
	property var pendingPopupOpenCallback: null
	property var pendingPopupFallbackScreen: null
	property var currentDate: new Date()
	property var now: new Date()
	property string weatherCity: "Paderborn"
	property string weatherLocation: "Stadtheide"
	property string weatherTemperature: "--"
	property string weatherIcon: "weather-severe-alert-symbolic"
	property string weatherDescription: "Loading weather..."
	property string weatherFeelsLike: "--"
	property string weatherHumidity: "--"
	property string weatherWind: "--"
	property string weatherVisibility: "--"
	property string weatherPrecipitation: "--"
	property string weatherPressure: "--"
	property string weatherUvIndex: "--"
	property string weatherSunrise: "--"
	property string weatherSunset: "--"
	property string weatherMoonPhase: "--"
	property string weatherObservationTime: ""
	// What the oracle says. One sentence, built from the readings rather than
	// from a table of canned phrases, so it changes when the sky does.
	readonly property string oracleLine: {
		const text = String(root.weatherDescription || "").toLowerCase();
		const rain = parseFloat(String(root.weatherPrecipitation || "0"));
		const wind = parseFloat(String(root.weatherWind || "0"));
		const degrees = parseFloat(String(root.weatherTemperature || ""));
		if (text.indexOf("loading") >= 0 || text === "") return "The water has not settled.";
		if (text.indexOf("thunder") >= 0 || text.indexOf("storm") >= 0) return "Something is angry above the clouds.";
		if (rain > 2) return "The sky is emptying itself.";
		if (rain > 0) return "Rain is being considered.";
		if (text.indexOf("snow") >= 0) return "The air is giving up its water as glass.";
		if (text.indexOf("fog") >= 0 || text.indexOf("mist") >= 0) return "The world ends forty paces out.";
		if (wind > 30) return "The wind has an errand of its own.";
		if (Number.isFinite(degrees) && degrees <= 0) return "Everything outside is holding still.";
		if (Number.isFinite(degrees) && degrees >= 27) return "The day is burning slowly.";
		if (text.indexOf("clear") >= 0) return "Nothing at all stands between here and the stars.";
		if (text.indexOf("cloud") >= 0 || text.indexOf("overcast") >= 0) return "The skies are calm, and keeping something back.";
		return "The skies are calm.";
	}
	property real weatherLatitude: Number.NaN
	property real weatherLongitude: Number.NaN
	property string weatherTimezone: "auto"
	property string weatherRequestKind: ""
	readonly property var weekdayNames: [ "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" ]

	function popupScreenByName(outputName) {
		const name = String(outputName || "");
		if (name === "") return null;

		for (const screen of Quickshell.screens) {
			if (String(screen.name || "") === name) return screen;
		}

		return null;
	}

	function popupScreenFallback(preferredScreen) {
		const preferred = root.popupScreenByName(preferredScreen?.name);
		if (preferred) return preferred;

		const lastFocused = root.popupScreenByName(niriState.focusedWorkspace?.output);
		if (lastFocused) return lastFocused;

		const active = root.popupScreenByName(root.activePopupScreen?.name);
		return active || root.primaryBarScreen;
	}

	function finishPopupScreenRequest(rawOutput) {
		if (!root.pendingPopupOpenCallback) return;

		let outputName = "";
		try {
			outputName = String(JSON.parse(String(rawOutput || "{}"))?.name || "");
		} catch (error) {
			outputName = "";
		}

		const callback = root.pendingPopupOpenCallback;
		const fallback = root.pendingPopupFallbackScreen;
		root.pendingPopupOpenCallback = null;
		root.pendingPopupFallbackScreen = null;
		root.activePopupScreen = root.popupScreenByName(outputName) || fallback || root.primaryBarScreen;

		// Let the layer-shell window adopt its new screen before it becomes visible.
		Qt.callLater(callback);
	}

	function openPopupOnFocusedScreen(callback, preferredScreen = null) {
		const fallback = root.popupScreenFallback(preferredScreen);

		// A second request can only happen during the few milliseconds in which the
		// niri query is running. Opening it on the best current snapshot avoids
		// dropping the user action.
		if (focusedOutputProcess.running) {
			root.activePopupScreen = fallback;
			Qt.callLater(callback);
			return;
		}

		root.pendingPopupOpenCallback = callback;
		root.pendingPopupFallbackScreen = fallback;
		focusedOutputProcess.exec([ "niri", "msg", "-j", "focused-output" ]);
	}

	function toastDuration(expireTimeout) {
		if (expireTimeout <= 0) return 5000;
		return expireTimeout < 1000 ? expireTimeout * 1000 : expireTimeout;
	}

	function notificationAppKey(notification) {
		const parts = [];

		if (notification.appName) parts.push(notification.appName);
		if (notification.appIcon) parts.push(notification.appIcon);
		if (notification.desktopEntry) parts.push(notification.desktopEntry);

		if (parts.length === 0) return String(notification.id);
		return parts.join("::");
	}

	function snapshotNotification(notification) {
		return {
			notificationId: notification.id,
			appKey: root.notificationAppKey(notification),
			appName: notification.appName || "Notification",
			summary: notification.summary || notification.appName || "Notification",
			body: notification.body || "",
			urgency: notification.urgency,
			progressValue: notification.hints.value !== undefined
				? Number(notification.hints.value)
				: -1,
			image: notification.image || "",
			appIcon: notification.appIcon || "",
			hasInlineReply: notification.hasInlineReply,
			inlineReplyPlaceholder: notification.inlineReplyPlaceholder || "Reply",
			timestamp: Date.now(),
			active: true
		};
	}

	function formatNotificationTime(timestamp) {
		return Qt.formatDateTime(new Date(timestamp), "HH:mm");
	}

	function addNotificationGroup(notification, snapshot) {
		const groups = root.notificationGroups.slice();
		let existingIndex = -1;

		for (let i = 0; i < groups.length; i += 1) {
			if (groups[i].key === snapshot.appKey) {
				existingIndex = i;
				break;
			}
		}

		let group;
		if (existingIndex >= 0) {
			group = groups[existingIndex];
			group.notifications = [snapshot].concat(group.notifications);
			group.latestSnapshot = snapshot;
			group.latestNotification = notification;
			group.latestNotificationId = snapshot.notificationId;
			group.appName = snapshot.appName;
			group.appIcon = snapshot.appIcon;
			group.image = snapshot.image;
			group.urgency = snapshot.urgency;
			groups.splice(existingIndex, 1);
		} else {
			group = {
				key: snapshot.appKey,
				appName: snapshot.appName,
				appIcon: snapshot.appIcon,
				image: snapshot.image,
				urgency: snapshot.urgency,
				expanded: false,
				latestSnapshot: snapshot,
				latestNotification: notification,
				latestNotificationId: snapshot.notificationId,
				notifications: [snapshot]
			};
		}

		groups.unshift(group);
		root.notificationGroups = groups;
	}

	function registerNotification(notification) {
		const snapshot = root.snapshotNotification(notification);
		root.addNotificationGroup(notification, snapshot);
		root.addToast(notification);
	}

	function addToast(notification) {
		root.nextToastId += 1;
		root.toasts = root.toasts.concat([{
			toastId: root.nextToastId,
			notificationId: notification.id,
			notification: notification,
			duration: root.toastDuration(notification.expireTimeout)
		}]);
	}

	function removeToast(toastId) {
		for (let i = 0; i < root.toasts.length; i += 1) {
			if (root.toasts[i].toastId === toastId) {
				root.toasts = root.toasts.slice(0, i).concat(root.toasts.slice(i + 1));
				return;
			}
		}
	}

	function removeToastByNotificationId(notificationId) {
		let changed = false;
		const kept = [];

		for (const toast of root.toasts) {
			if (toast.notificationId === notificationId) {
				changed = true;
			} else {
				kept.push(toast);
			}
		}

		if (changed) root.toasts = kept;
	}

	function markNotificationClosed(notificationId) {
		const groups = root.notificationGroups.slice();
		let changed = false;

		for (const group of groups) {
			for (const snapshot of group.notifications) {
				if (snapshot.notificationId === notificationId && snapshot.active) {
					snapshot.active = false;
					changed = true;
				}
			}

			if (group.latestNotification && group.latestNotification.id === notificationId) {
				group.latestNotification = null;
				changed = true;
			}
		}

		if (changed) root.notificationGroups = groups;
		root.removeToastByNotificationId(notificationId);
	}

	function setNotificationGroupExpanded(appKey, expanded) {
		const groups = root.notificationGroups.slice();

		for (const group of groups) {
			if (group.key === appKey) {
				group.expanded = expanded;
				root.notificationGroups = groups;
				return;
			}
		}
	}

	function dismissNotificationGroup(appKey) {
		const groups = [];

		for (const group of root.notificationGroups) {
			if (group.key === appKey) {
				if (group.latestNotification) group.latestNotification.dismiss();
				continue;
			}

			groups.push(group);
		}

		root.notificationGroups = groups;
	}

	function notificationUrgencyColor(notification) {
		if (notification.urgency === NotificationUrgency.Critical) return danger;
		if (notification.urgency === NotificationUrgency.Low) return Qt.alpha(border, 0.7);
		return accent;
	}

	function shellEscape(value) {
		return String(value).replace(/'/g, `'\"'\"'`);
	}

	function clamp(value, min, max) {
		return Math.max(min, Math.min(max, value));
	}

	function iconNameSource(name, fallbacks = []) {
		return root.resolveIconSource(name, fallbacks);
	}

	function volumeIconSource(volume, muted) {
		if (muted || volume <= 0.001)
			return root.iconNameSource("audio-volume-muted-symbolic", ["audio-volume-muted", "audio-volume-off"])
				|| "/usr/share/icons/Adwaita/symbolic/status/audio-volume-muted-symbolic.svg";
		if (volume < 0.34)
			return root.iconNameSource("audio-volume-low-symbolic", ["audio-volume-low"])
				|| "/usr/share/icons/Adwaita/symbolic/status/audio-volume-low-symbolic.svg";
		if (volume < 0.67)
			return root.iconNameSource("audio-volume-medium-symbolic", ["audio-volume-medium"])
				|| "/usr/share/icons/Adwaita/symbolic/status/audio-volume-medium-symbolic.svg";
		return root.iconNameSource("audio-volume-high-symbolic", ["audio-volume-high"])
			|| "/usr/share/icons/Adwaita/symbolic/status/audio-volume-high-symbolic.svg";
	}

	function microphoneIconSource(muted) {
		return muted
			? (root.iconNameSource("microphone-disabled-symbolic", ["microphone-sensitivity-muted-symbolic", "audio-input-microphone-muted-symbolic"])
				|| "/usr/share/icons/Adwaita/symbolic/status/microphone-disabled-symbolic.svg")
			: (root.iconNameSource("audio-input-microphone-symbolic", ["microphone-sensitivity-high-symbolic"])
				|| "/usr/share/icons/Adwaita/symbolic/devices/audio-input-microphone-symbolic.svg");
	}

	function brightnessIconSource(progress) {
		if (progress < 0.34)
			return root.iconNameSource("display-brightness-low-symbolic", ["brightness-low-symbolic", "display-brightness-symbolic"])
				|| "/usr/share/icons/Adwaita/symbolic/status/display-brightness-symbolic.svg";
		if (progress < 0.67)
			return root.iconNameSource("display-brightness-medium-symbolic", ["brightness-medium-symbolic", "display-brightness-symbolic"])
				|| "/usr/share/icons/Adwaita/symbolic/status/display-brightness-symbolic.svg";
		return root.iconNameSource("display-brightness-high-symbolic", ["brightness-high-symbolic", "display-brightness-symbolic"])
			|| "/usr/share/icons/Adwaita/symbolic/status/display-brightness-symbolic.svg";
	}

	function showOsd(kind, label, progress, valueText, iconSource) {
		root.osdKind = kind;
		root.osdLabel = label;
		root.osdProgress = root.clamp(progress, 0, 1.5);
		root.osdValueText = valueText;
		root.osdIconSource = iconSource;
		root.osdVisible = true;
		osdHideTimer.restart();
	}

	function showOutputVolumeOsd() {
		root.refreshVolumeOsd("volume");
	}

	function showInputVolumeOsd() {
		root.refreshVolumeOsd("microphone");
	}

	function adjustOutputVolume(delta) {
		Quickshell.execDetached([
			"wpctl",
			"set-volume",
			"@DEFAULT_AUDIO_SINK@",
			delta > 0 ? "5%+" : "5%-"
		]);
		root.scheduleVolumeRefresh("volume");
	}

	function toggleOutputMute() {
		Quickshell.execDetached([
			"wpctl",
			"set-mute",
			"@DEFAULT_AUDIO_SINK@",
			"toggle"
		]);
		root.scheduleVolumeRefresh("volume");
	}

	function toggleInputMute() {
		Quickshell.execDetached([
			"wpctl",
			"set-mute",
			"@DEFAULT_AUDIO_SOURCE@",
			"toggle"
		]);
		root.scheduleVolumeRefresh("microphone");
	}

	function scheduleVolumeRefresh(kind) {
		root.volumeRequestKind = kind;
		volumeRefreshTimer.restart();
	}

	function refreshVolumeOsd(kind) {
		root.volumeRequestKind = kind;
		volumeReadProcess.command = [
			"wpctl",
			"get-volume",
			kind === "microphone" ? "@DEFAULT_AUDIO_SOURCE@" : "@DEFAULT_AUDIO_SINK@"
		];
		volumeReadProcess.running = true;
	}

	function refreshBrightnessOsd(kind = "brightness") {
		root.brightnessRequestKind = kind;
		brightnessReadProcess.running = true;
	}

	function adjustBrightness(deltaDirection) {
		Quickshell.execDetached([
			"brightnessctl",
			"set",
			deltaDirection > 0 ? "5%+" : "5%-"
		]);
		brightnessRefreshTimer.restart();
	}

	function closeOtherPopups(except) {
		if (except !== "clock") {
			clockPopupCloseTimer.stop();
			root.clockPopupOpen = false;
			root.clockPopupVisible = false;
		}

		if (except !== "weather") {
			weatherPopupCloseTimer.stop();
			root.weatherPopupOpen = false;
			root.weatherPopupVisible = false;
		}

		if (except !== "notifications") {
			notifPopupCloseTimer.stop();
			root.notifPopupOpen = false;
			root.notifPopupVisible = false;
		}

		if (except !== "media") {
			mediaPopupCloseTimer.stop();
			root.mediaPopupOpen = false;
			root.mediaPopupVisible = false;
		}

		if (except !== "clipboard") {
			clipboardPopupCloseTimer.stop();
			root.clipboardPopupOpen = false;
			root.clipboardPopupVisible = false;
		}

		if (except !== "bluetooth") {
			bluetoothPopupCloseTimer.stop();
			root.bluetoothPopupOpen = false;
			root.bluetoothPopupVisible = false;
		}

		if (except !== "network") {
			networkPopupCloseTimer.stop();
			root.networkPopupOpen = false;
			root.networkPopupVisible = false;
		}

		if (except !== "resources") {
			resourcesPopupCloseTimer.stop();
			root.resourcesPopupOpen = false;
			root.resourcesPopupVisible = false;
		}

		if (except !== "power") {
			powerPopupCloseTimer.stop();
			root.powerPopupOpen = false;
			root.powerPopupVisible = false;
		}

		if (except !== "studio") {
			studioPopupCloseTimer.stop();
			root.studioPopupOpen = false;
			root.studioPopupVisible = false;
		}

		if (except !== "launcher") {
			launcherPopupCloseTimer.stop();
			root.launcherPopupOpen = false;
			root.launcherPopupVisible = false;
		}
	}

	function openClockPopup(scr = null) {
		root.openPopupOnFocusedScreen(function() {
			root.closeOtherPopups("clock");
			root.clockPopupVisible = true;
			root.clockPopupOpen = true;
		}, scr);
	}

	function closeClockPopup() {
		root.clockPopupOpen = false;
		clockPopupCloseTimer.restart();
	}

	function toggleClockPopup(scr = null) {
		if (root.clockPopupOpen) root.closeClockPopup();
		else root.openClockPopup(scr);
	}

	function openWeatherPopup(scr = null) {
		root.openPopupOnFocusedScreen(function() {
			root.closeOtherPopups("weather");
			root.weatherPopupVisible = true;
			root.weatherPopupOpen = true;
		}, scr);
	}

	function closeWeatherPopup() {
		root.weatherPopupOpen = false;
		weatherPopupCloseTimer.restart();
	}

	function toggleWeatherPopup(scr = null) {
		if (root.weatherPopupOpen) root.closeWeatherPopup();
		else root.openWeatherPopup(scr);
	}

	function openNotifPopup(scr = null) {
		root.openPopupOnFocusedScreen(function() {
			root.closeOtherPopups("notifications");
			root.notifPopupVisible = true;
			root.notifPopupOpen = true;
		}, scr);
	}

	function closeNotifPopup() {
		root.notifPopupOpen = false;
		notifPopupCloseTimer.restart();
	}

	function toggleNotifPopup(scr = null) {
		if (root.notifPopupOpen) root.closeNotifPopup();
		else root.openNotifPopup(scr);
	}

	function dismissAllNotificationGroups() {
		for (const group of root.notificationGroups) {
			if (group.latestNotification) group.latestNotification.dismiss();
		}
		root.notificationGroups = [];
	}

	function openMediaPopup(scr = null) {
		if (!nowPlayingIsland.visible) return;
		root.openPopupOnFocusedScreen(function() {
			root.closeOtherPopups("media");
			root.mediaPopupVisible = true;
			root.mediaPopupOpen = true;
		}, scr);
	}

	function closeMediaPopup() {
		root.mediaPopupOpen = false;
		mediaPopupCloseTimer.restart();
	}

	function toggleMediaPopup(scr = null) {
		if (root.mediaPopupOpen) root.closeMediaPopup();
		else root.openMediaPopup(scr);
	}

	function openResourcesPopup(scr = null) {
		root.openPopupOnFocusedScreen(function() {
			root.closeOtherPopups("resources");
			root.resourcesPopupVisible = true;
			root.resourcesPopupOpen = true;
		}, scr);
	}

	function closeResourcesPopup() {
		root.resourcesPopupOpen = false;
		resourcesPopupCloseTimer.restart();
	}

	function toggleResourcesPopup(scr = null) {
		if (root.resourcesPopupOpen) root.closeResourcesPopup();
		else root.openResourcesPopup(scr);
	}

	function openNetworkPopup(scr = null) {
		root.openPopupOnFocusedScreen(function() {
			root.closeOtherPopups("network");
			root.networkPopupVisible = true;
			root.networkPopupOpen = true;
		}, scr);
	}

	function closeNetworkPopup() {
		root.networkPopupOpen = false;
		networkPopupCloseTimer.restart();
	}

	function toggleNetworkPopup(scr = null) {
		if (root.networkPopupOpen) root.closeNetworkPopup();
		else root.openNetworkPopup(scr);
	}

	function openBluetoothPopup(scr = null) {
		root.openPopupOnFocusedScreen(function() {
			root.closeOtherPopups("bluetooth");
			root.bluetoothPopupVisible = true;
			root.bluetoothPopupOpen = true;
		}, scr);
	}

	function closeBluetoothPopup() {
		root.bluetoothPopupOpen = false;
		bluetoothPopupCloseTimer.restart();
	}

	function toggleBluetoothPopup(scr = null) {
		if (root.bluetoothPopupOpen) root.closeBluetoothPopup();
		else root.openBluetoothPopup(scr);
	}

	function openClipboardPopup(scr = null) {
		root.openPopupOnFocusedScreen(function() {
			root.closeOtherPopups("clipboard");
			root.clipboardPopupVisible = true;
			root.clipboardPopupOpen = true;
			clipboardPopupRefreshTimer.restart();
		}, scr);
	}

	function closeClipboardPopup() {
		root.clipboardPopupOpen = false;
		clipboardPopupCloseTimer.restart();
	}

	function toggleClipboardPopup(scr = null) {
		if (root.clipboardPopupOpen) root.closeClipboardPopup();
		else root.openClipboardPopup(scr);
	}

	function disconnectActiveNetwork() {
		if (!networkPopup.currentInterface || networkPopup.currentType === "offline") return;

		if (networkPopup.currentType === "ethernet") {
			Quickshell.execDetached([
				"sh",
				"-lc",
				`nmcli device set '${networkPopup.currentInterface}' autoconnect no && nmcli device down '${networkPopup.currentInterface}' || nmcli device disconnect '${networkPopup.currentInterface}'`
			]);
		} else {
			Quickshell.execDetached([
				"sh",
				"-lc",
				`nmcli device disconnect '${networkPopup.currentInterface}'`
			]);
		}

		root.networkStatusType = "offline";
		networkPopup.currentType = "offline";
		networkPopup.currentIp = "";
		networkPopup.resetThroughput();
	}

	function openPowerPopup(scr = null) {
		root.openPopupOnFocusedScreen(function() {
			root.closeOtherPopups("power");
			root.powerSelectionIndex = 0;
			root.powerPopupVisible = true;
			root.powerPopupOpen = true;
			Qt.callLater(function() {
				powerModal.forceActiveFocus();
			});
		}, scr);
	}

	function closePowerPopup() {
		root.powerPopupOpen = false;
		powerPopupCloseTimer.restart();
	}

	function togglePowerPopup(scr) {
		if (root.powerPopupOpen) root.closePowerPopup();
		else root.openPowerPopup(scr);
	}

	// Studio's pages, by name. Every style ships all of them — see STUDIO.md.
	function studioPageOrDefault(page) {
		const name = String(page || "");
		return [ "wallpaper", "motion", "dress", "styles", "combinations" ].indexOf(name) >= 0
			? name
			: "wallpaper";
	}

	function openStudio(page = "", scr = null) {
		root.studioPage = root.studioPageOrDefault(page);
		root.openPopupOnFocusedScreen(function() {
			root.closeOtherPopups("studio");
			root.studioPopupVisible = true;
			root.studioPopupOpen = true;
		}, scr);
	}

	function closeStudio() {
		root.studioPopupOpen = false;
		studioPopupCloseTimer.restart();
	}

	// Asking for the page that is already showing closes Studio; asking for a
	// different one switches to it instead of closing and reopening.
	function toggleStudio(page = "", scr = null) {
		const next = root.studioPageOrDefault(page);
		if (root.studioPopupOpen && root.studioPage === next) root.closeStudio();
		else if (root.studioPopupOpen) root.studioPage = next;
		else root.openStudio(next, scr);
	}

	function openLauncherPopup(scr = null) {
		root.openPopupOnFocusedScreen(function() {
			root.closeOtherPopups("launcher");
			root.launcherPopupVisible = true;
			root.launcherPopupOpen = false;
			launcherPopupOpenTimer.restart();
		}, scr);
	}

	function closeLauncherPopup() {
		root.launcherPopupOpen = false;
		launcherPopupCloseTimer.restart();
	}

	function toggleLauncherPopup(scr) {
		if (root.launcherPopupOpen) root.closeLauncherPopup();
		else root.openLauncherPopup(scr);
	}

	function lockSession() {
		quickLock.lock();
	}

	function runPowerAction(kind) {
		root.closePowerPopup();

		switch (kind) {
		case "lock":
			root.lockSession();
			break;
		case "logout":
			Quickshell.execDetached(["sh", "-lc", "loginctl terminate-session \"$XDG_SESSION_ID\""]);
			break;
		case "reboot":
			Quickshell.execDetached(["systemctl", "reboot"]);
			break;
		case "shutdown":
			Quickshell.execDetached(["systemctl", "poweroff"]);
			break;
		}
	}

	function runSelectedPowerAction() {
		switch (root.powerSelectionIndex) {
		case 0:
			root.runPowerAction("lock");
			break;
		case 1:
			root.runPowerAction("logout");
			break;
		case 2:
			root.runPowerAction("reboot");
			break;
		case 3:
			root.runPowerAction("shutdown");
			break;
		}
	}

	function openTrayMenu(handle, targetItem) {
		if (!handle || !targetItem) return;
		root.openPopupOnFocusedScreen(function() {
			// Straight there: hand the chamber its menu, show it, and let it
			// unroll on the next tick. It used to null everything out first and
			// rebuild across two hops, which left a window in which the chamber
			// existed with no handle — long enough for anything arriving in
			// between to tear it down again.
			trayMenuCloseTimer.stop();
			root.trayMenuHandle = handle;
			root.trayMenuTargetItem = targetItem;
			root.trayMenuVisible = true;
			Qt.callLater(function() {
				root.trayMenuOpen = true;
			});
		}, barWindow.screen);
	}

	function closeTrayMenu() {
		trayMenuCloseTimer.stop();
		root.trayMenuOpen = false;
		trayMenuCloseTimer.restart();
	}

	function calendarOffset(date) {
		return (new Date(date.getFullYear(), date.getMonth(), 1).getDay() + 6) % 7;
	}

	function calendarDaysInMonth(date) {
		return new Date(date.getFullYear(), date.getMonth() + 1, 0).getDate();
	}

	function calendarDayNumber(index) {
		const day = index - root.calendarOffset(root.currentDate) + 1;
		const daysInMonth = root.calendarDaysInMonth(root.currentDate);
		return day >= 1 && day <= daysInMonth ? day : 0;
	}

	function isToday(day) {
		return day !== 0
			&& root.currentDate.getDate() === day
			&& root.now.getMonth() === root.currentDate.getMonth()
			&& root.now.getFullYear() === root.currentDate.getFullYear();
	}

	function shiftCalendarMonths(offset) {
		root.currentDate = new Date(
			root.currentDate.getFullYear(),
			root.currentDate.getMonth() + offset,
			1
		);
	}

	function weatherGeocodeUrl() {
		return "https://geocoding-api.open-meteo.com/v1/search?name="
			+ encodeURIComponent(root.weatherCity)
			+ "&count=1&language=en&format=json";
	}

	function weatherForecastUrl() {
		if (!isFinite(root.weatherLatitude) || !isFinite(root.weatherLongitude)) return "";

		return "https://api.open-meteo.com/v1/forecast?latitude="
			+ root.weatherLatitude
			+ "&longitude="
			+ root.weatherLongitude
			+ "&current=temperature_2m,relative_humidity_2m,apparent_temperature,precipitation,pressure_msl,wind_speed_10m,weather_code,is_day"
			+ "&daily=sunrise,sunset"
			+ "&timezone=auto&forecast_days=1";
	}

	function refreshWeather() {
		if (isFinite(root.weatherLatitude) && isFinite(root.weatherLongitude)) {
			root.weatherRequestKind = "forecast";
			weatherProcess.exec([ "curl", "-fsSL", root.weatherForecastUrl() ]);
			return;
		}

		root.weatherRequestKind = "geocode";
		weatherProcess.exec([ "curl", "-fsSL", root.weatherGeocodeUrl() ]);
	}

	function weatherIconName(code, description, isDay = true) {
		const value = Number(code);
		if ([0, 113].includes(value))
			return isDay ? "weather-clear-symbolic" : "weather-clear-night-symbolic";
		if ([1].includes(value))
			return isDay ? "weather-few-clouds-symbolic" : "weather-clear-night-symbolic";
		if ([2].includes(value)) return "weather-few-clouds-symbolic";
		if ([3].includes(value)) return "weather-overcast-symbolic";
		if ([45, 48, 284].includes(value)) return "weather-fog-symbolic";
		if ([51, 53, 55, 56, 57].includes(value)) return "weather-showers-symbolic";
		if ([61, 63, 65, 66, 67, 80, 81, 82].includes(value)) return "weather-showers-symbolic";
		if ([71, 73, 75, 77, 85, 86].includes(value)) return "weather-snow-symbolic";
		if ([95, 96, 99].includes(value)) return "weather-storm-symbolic";
		if ([116].includes(value)) return "weather-few-clouds-symbolic";
		if ([119, 122, 143, 248, 260].includes(value)) return "weather-overcast-symbolic";
		if ([176, 263, 266, 293, 296, 299, 302, 305, 308, 311, 314, 353, 356, 359].includes(value)) return "weather-showers-symbolic";
		if ([179, 182, 185, 227, 230, 317, 320, 323, 326, 329, 332, 335, 338, 350, 368, 371, 374, 377, 392, 395].includes(value)) return "weather-snow-symbolic";
		if ([200, 386, 389].includes(value)) return "weather-storm-symbolic";
		if ([284].includes(value)) return "weather-fog-symbolic";
		if (description && description.toLowerCase().includes("fog")) return "weather-fog-symbolic";
		return "weather-overcast-symbolic";
	}

	function resetWeatherUnavailable() {
		root.weatherLocation = root.weatherCity;
		root.weatherTemperature = "--";
		root.weatherIcon = "weather-severe-alert-symbolic";
		root.weatherDescription = "Weather unavailable";
		root.weatherFeelsLike = "--";
		root.weatherHumidity = "--";
		root.weatherWind = "--";
		root.weatherVisibility = "--";
		root.weatherPrecipitation = "--";
		root.weatherPressure = "--";
		root.weatherUvIndex = "--";
		root.weatherSunrise = "--";
		root.weatherSunset = "--";
		root.weatherMoonPhase = "--";
		root.weatherObservationTime = "";
	}

	function applyWeatherForecastResponse(raw) {
		try {
			const parsed = JSON.parse(raw);
			const current = parsed.current;
			const daily = parsed.daily;
			if (!current) throw new Error("missing current weather");
			const code = Number(current.weather_code);
			const isDay = Number(current.is_day || 0) === 1;
			let description = "Unavailable";

			if (code === 0) description = "Clear sky";
			else if (code === 1) description = "Mainly clear";
			else if (code === 2) description = "Partly cloudy";
			else if (code === 3) description = "Overcast";
			else if ([45, 48].includes(code)) description = "Fog";
			else if ([51, 53, 55, 56, 57].includes(code)) description = "Drizzle";
			else if ([61, 63, 65, 66, 67, 80, 81, 82].includes(code)) description = "Rain";
			else if ([71, 73, 75, 77, 85, 86].includes(code)) description = "Snow";
			else if ([95, 96, 99].includes(code)) description = "Thunderstorm";

			root.weatherTemperature = `${Math.round(Number(current.temperature_2m))}C`;
			root.weatherIcon = root.weatherIconName(code, description, isDay);
			root.weatherDescription = description;
			root.weatherFeelsLike = current.apparent_temperature !== undefined
				? `${Math.round(Number(current.apparent_temperature))}C`
				: "--";
			root.weatherHumidity = current.relative_humidity_2m !== undefined
				? `${Math.round(Number(current.relative_humidity_2m))}%`
				: "--";
			root.weatherWind = current.wind_speed_10m !== undefined
				? `${Math.round(Number(current.wind_speed_10m))} km/h`
				: "--";
			root.weatherVisibility = "--";
			root.weatherPrecipitation = current.precipitation !== undefined
				? `${Number(current.precipitation).toFixed(1)} mm`
				: "--";
			root.weatherPressure = current.pressure_msl !== undefined
				? `${Math.round(Number(current.pressure_msl))} hPa`
				: "--";
			root.weatherUvIndex = "--";
			root.weatherSunrise = daily && daily.sunrise && daily.sunrise[0]
				? Qt.formatDateTime(new Date(daily.sunrise[0]), "HH:mm")
				: "--";
			root.weatherSunset = daily && daily.sunset && daily.sunset[0]
				? Qt.formatDateTime(new Date(daily.sunset[0]), "HH:mm")
				: "--";
			root.weatherMoonPhase = "--";
			root.weatherObservationTime = current.time || "";
		} catch (error) {
			root.resetWeatherUnavailable();
		}
	}

	function applyWeatherGeocodeResponse(raw) {
		try {
			const parsed = JSON.parse(raw);
			const result = parsed.results && parsed.results[0];
			if (!result) throw new Error("missing geocode result");

			root.weatherLatitude = Number(result.latitude);
			root.weatherLongitude = Number(result.longitude);
			root.weatherTimezone = result.timezone || "auto";

			const name = result.name || root.weatherCity;
			const admin = result.admin1 || result.country || "";
			root.weatherLocation = admin !== "" ? `${name}, ${admin}` : name;

			root.weatherRequestKind = "forecast";
			weatherProcess.exec([ "curl", "-fsSL", root.weatherForecastUrl() ]);
		} catch (error) {
			root.resetWeatherUnavailable();
		}
	}

	function handleWeatherProcessOutput(raw) {
		if (root.weatherRequestKind === "geocode") {
			root.applyWeatherGeocodeResponse(raw);
			return;
		}

		root.applyWeatherForecastResponse(raw);
	}

	function submitInlineReply(notification, input) {
		const reply = input.text.trim();
		if (reply === "") return;
		notification.sendInlineReply(reply);
		input.text = "";
	}

	function fallbackIconPath(icon) {
		switch (icon) {
		case "dialog-information-symbolic":
		case "dialog-information":
			return "/usr/share/icons/Adwaita/symbolic/status/dialog-information-symbolic.svg";
		case "preferences-system-time-symbolic":
		case "preferences-system-time":
		case "temperature-symbolic":
			return "/usr/share/icons/Adwaita/symbolic/legacy/preferences-system-time-symbolic.svg";
		case "weather-clear-symbolic":
		case "weather-clear":
			return "/usr/share/icons/Adwaita/symbolic/status/weather-clear-symbolic.svg";
		case "weather-clear-night-symbolic":
		case "weather-clear-night":
			return "/usr/share/icons/Adwaita/symbolic/status/weather-clear-night-symbolic.svg";
		case "weather-few-clouds-symbolic":
		case "weather-few-clouds":
			return "/usr/share/icons/Adwaita/symbolic/status/weather-few-clouds-symbolic.svg";
		case "weather-overcast-symbolic":
		case "weather-overcast":
			return "/usr/share/icons/Adwaita/symbolic/status/weather-overcast-symbolic.svg";
		case "weather-showers-symbolic":
		case "weather-showers":
		case "weather-showers-scattered-symbolic":
			return "/usr/share/icons/Adwaita/symbolic/status/weather-showers-symbolic.svg";
		case "weather-snow-symbolic":
		case "weather-snow":
			return "/usr/share/icons/Adwaita/symbolic/status/weather-snow-symbolic.svg";
		case "weather-storm-symbolic":
		case "weather-storm":
			return "/usr/share/icons/Adwaita/symbolic/status/weather-storm-symbolic.svg";
		case "weather-fog-symbolic":
		case "weather-fog":
			return "/usr/share/icons/Adwaita/symbolic/status/weather-fog-symbolic.svg";
		case "weather-windy-symbolic":
		case "weather-windy":
			return "/usr/share/icons/Adwaita/symbolic/status/weather-windy-symbolic.svg";
		case "weather-severe-alert-symbolic":
		case "weather-severe-alert":
			return "/usr/share/icons/Adwaita/symbolic/status/weather-severe-alert-symbolic.svg";
		default:
			return "";
		}
	}

	function resolveIconSource(icon, fallbacks = []) {
		if (!icon) {
			for (const fallback of fallbacks) {
				const fallbackDirectPath = root.fallbackIconPath(fallback);
				if (fallbackDirectPath !== "") return fallbackDirectPath;

				const fallbackPath = Quickshell.iconPath(fallback, true);
				if (fallbackPath !== "") return fallbackPath;
			}

			return "";
		}

		if (typeof icon !== "string") icon = String(icon);

		if (
			icon.startsWith("/")
			|| icon.startsWith("file:")
			|| icon.startsWith("image:")
			|| icon.startsWith("qrc:")
		) {
			return icon;
		}

		const directFallbackPath = root.fallbackIconPath(icon);
		if (directFallbackPath !== "") return directFallbackPath;

		const iconPath = Quickshell.iconPath(icon, true);
		if (iconPath !== "") return iconPath;

		for (const fallback of fallbacks) {
			const fallbackDirectPath = root.fallbackIconPath(fallback);
			if (fallbackDirectPath !== "") return fallbackDirectPath;

			const fallbackPath = Quickshell.iconPath(fallback, true);
			if (fallbackPath !== "") return fallbackPath;
		}

		return "";
	}

	function trayIconSource(icon) {
		if (!icon) return "";

		if (icon.includes("?path=")) {
			const parts = icon.split("?path=");
			const name = parts[0];
			const path = parts[1];
			return Qt.resolvedUrl(`${path}/${name.slice(name.lastIndexOf("/") + 1)}`);
		}

		return icon;
	}

	// Make sure every output shows the current wallpaper. This runs on every
	// load, including a style reload, so it must not rebuild a runtime that is
	// already fine: --ensure paints only outputs that are missing one and
	// returns in milliseconds when there are none. The full restore at session
	// start is niri's job (see restore_theme_wallpaper.sh in the autostart).
	Process {
		id: ensureWallpaperProcess
		command: [
			"bash",
			`${Quickshell.shellDir}/scripts/apply_wallpaper_runtime.sh`,
			"--ensure"
		]
		running: true
	}

	readonly property color background: Arc.vellum
	readonly property color foreground: Arc.ink
	readonly property color primary: Arc.aether
	readonly property color secondary: Arc.aetherAlt
	readonly property color accent: Arc.aetherAlt
	readonly property color tertiary: Arc.aetherThird
	readonly property color border: Arc.giltFaint

	Process {
		id: weatherProcess
		stdout: StdioCollector {
			onStreamFinished: root.handleWeatherProcessOutput(text)
		}
		onExited: function(exitCode) {
			if (exitCode !== 0 && root.weatherObservationTime === "" && root.weatherTemperature === "--") {
				root.resetWeatherUnavailable();
			}
		}
	}

	NiriState {
		id: niriState
	}

	Process {
		id: focusedOutputProcess

		stdout: StdioCollector {
			onStreamFinished: {
				focusedOutputFallbackTimer.stop();
				root.finishPopupScreenRequest(text);
			}
		}

		onExited: function(exitCode) {
			if (root.pendingPopupOpenCallback) focusedOutputFallbackTimer.restart();
		}
	}

	Timer {
		id: focusedOutputFallbackTimer
		interval: 25
		repeat: false
		onTriggered: root.finishPopupScreenRequest("")
	}

	NotificationServer {
		id: notificationServer
		actionsSupported: true
		bodySupported: true
		bodyMarkupSupported: false
		inlineReplySupported: true
		persistenceSupported: true

			onNotification: function(notification) {
				notification.tracked = true;
				root.registerNotification(notification);
				notification.closed.connect(function() {
				root.markNotificationClosed(notification.id);
			});
		}
	}

	QuickLock {
		id: quickLock

		foreground: root.foreground
		background: root.background
		primary: root.primary
		danger: root.danger
	}

	// Style switching. A style is a Git branch of this repository, and switching
	// used to mean killing Quickshell, checking the branch out and starting it
	// again - several seconds of empty desktop. Quickshell can reload its own
	// config in place instead, which keeps the process, the Wayland connection
	// and the warm QML cache, so the switch is a blink.
	//
	//   state    what is running right now (used to verify a switch landed)
	//   freeze   stop reacting to files while the checkout writes them
	//   reload   re-read the config from disk
	//   thaw     undo freeze, for a switch that was aborted
	IpcHandler {
		target: "styleSession"

		function state(): string {
			return JSON.stringify({
				locked: quickLock.locked,
				style: root.styleId,
				shellDir: Quickshell.shellDir,
				switching: root.styleSwitching
			});
		}

		function freeze(): void {
			root.styleSwitching = true;
			Quickshell.watchFiles = false;
		}

		function thaw(): void {
			root.styleSwitching = false;
		}

		function reload(): void {
			// Never reload from inside the call that is being answered: the
			// handler itself is part of the tree that is about to be torn down.
			styleReloadTimer.restart();
		}
	}

	Timer {
		id: styleReloadTimer
		interval: 1
		repeat: false
		onTriggered: Quickshell.reload(true)
	}

	// Identity of the checked-out style, read once per load. A reload that
	// fails leaves the previous config running, and then this still reports the
	// previous style - which is how the switcher notices and rolls back.
	FileView {
		id: styleManifest
		path: `${Quickshell.shellDir}/.quickshell-style.json`
		blockLoading: true
	}

	IpcHandler {
		target: "launcher"

		function open(): void {
			root.openLauncherPopup();
		}

		function close(): void {
			root.closeLauncherPopup();
		}

		function toggle(): void {
			root.toggleLauncherPopup();
		}
	}

	IpcHandler {
		target: "power"

		function open(): void {
			root.openPowerPopup();
		}

		function close(): void {
			root.closePowerPopup();
		}

		function toggle(): void {
			root.togglePowerPopup();
		}
	}

	IpcHandler {
		target: "lock"

		function lock(): void {
			root.lockSession();
		}

		function isLocked(): bool {
			return quickLock.locked;
		}
	}

	IpcHandler {
		target: "panels"

		function toggleCalendar(): void {
			root.toggleClockPopup();
		}

		function toggleWeather(): void {
			root.toggleWeatherPopup();
		}

		function toggleNotifications(): void {
			root.toggleNotifPopup();
		}

		function toggleMedia(): void {
			root.toggleMediaPopup();
		}

		function toggleBluetooth(): void {
			root.toggleBluetoothPopup();
		}

		function toggleNetwork(): void {
			root.toggleNetworkPopup();
		}

		function toggleResources(): void {
			root.toggleResourcesPopup();
		}
	}

	IpcHandler {
		target: "clipboard"

		function open(): void {
			root.openClipboardPopup();
		}

		function close(): void {
			root.closeClipboardPopup();
		}

		function toggle(): void {
			root.toggleClipboardPopup();
		}
	}

	IpcHandler {
		target: "volume"

		function raise(): void {
			root.adjustOutputVolume(0.05);
		}

		function lower(): void {
			root.adjustOutputVolume(-0.05);
		}

		function muteToggle(): void {
			root.toggleOutputMute();
		}

		function micMuteToggle(): void {
			root.toggleInputMute();
		}
	}

	IpcHandler {
		target: "brightness"

		function raise(): void {
			root.adjustBrightness(1);
		}

		function lower(): void {
			root.adjustBrightness(-1);
		}
	}

	IpcHandler {
		target: "theme"

		// Bio watches the palette file itself and re-reads it on every change;
		// this stays so a style checkout can push the new colours in before the
		// first frame instead of waiting for the file watcher to notice.
		function reload(): void {
			Arc.colorsFile.reload();
		}
	}

	// The shape/motion token set. It has no window of its own any more - the
	// style branch a config was checked out from decides it. The calls stay so
	// scripts can re-read the catalog after a checkout.
	IpcHandler {
		target: "uiTheme"

		function select(themeId: string): void { ThemeEngine.selectTheme(themeId); }
		function current(): string { return ThemeEngine.currentThemeId; }
		function reload(): void { ThemeEngine.reloadCatalog(); }
	}

	// One entry point for every look-and-feel window.
	// `page` is "wallpaper", "motion" or "styles"; anything else means wallpaper.
	IpcHandler {
		target: "studio"

		function open(page: string): void { root.openStudio(page); }
		function close(): void { root.closeStudio(); }
		function toggle(page: string): void { root.toggleStudio(page); }
	}

	Process {
		id: brightnessReadProcess
		command: [
			"sh",
			"-lc",
			"current=$(brightnessctl g 2>/dev/null || echo 0); max=$(brightnessctl m 2>/dev/null || echo 1); printf '%s/%s\\n' \"$current\" \"$max\""
		]
		stdout: StdioCollector {
			onStreamFinished: {
				const match = String(text).trim().match(/^(\d+)\/(\d+)$/);
				if (!match) return;
				const current = Number(match[1]);
				const max = Math.max(1, Number(match[2]));
				const progress = current / max;
				root.showOsd(
					root.brightnessRequestKind || "brightness",
					"Brightness",
					progress,
					`${Math.round(progress * 100)}%`,
					root.brightnessIconSource(progress)
				);
			}
		}
	}

	Process {
		id: volumeReadProcess
		command: [ "wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@" ]
		stdout: StdioCollector {
			onStreamFinished: {
				const raw = String(text || "");
				const match = raw.match(/Volume:\s*([0-9.]+)/);
				const volume = match ? Number(match[1]) : 0;
				const muted = raw.includes("[MUTED]");
				const kind = root.volumeRequestKind || "volume";
				root.showOsd(
					kind,
					kind === "microphone" ? "Microphone" : "Volume",
					muted ? 0 : volume,
					muted ? "Muted" : `${Math.round((muted ? 0 : volume) * 100)}%`,
					kind === "microphone"
						? root.microphoneIconSource(muted)
						: root.volumeIconSource(volume, muted)
				);
			}
		}
	}

	Timer {
		id: brightnessRefreshTimer
		interval: 70
		repeat: false
		onTriggered: root.refreshBrightnessOsd("brightness")
	}

	Timer {
		id: volumeRefreshTimer
		interval: 90
		repeat: false
		onTriggered: root.refreshVolumeOsd(root.volumeRequestKind || "volume")
	}

	Timer {
		id: osdHideTimer
		interval: 1200
		repeat: false
		onTriggered: root.osdVisible = false
	}

	// SOUL RESONANCE.
	//
	// Volume and brightness are not a slider and not a toast in a corner. A
	// crystal is let down from the vertex of the chain, directly under the
	// horologe, and what you are turning is the light inside it. The level is
	// the depth of what has been poured in; the reading is cut on the facet
	// above it.
	//
	// Every change rings it — the crystal is struck and the ring damps out,
	// integrated rather than eased, so turning a knob a long way rings louder
	// than nudging it.
	PanelWindow {
		id: osdWindow
		screen: root.primaryBarScreen

		anchors {
			left: true
			right: true
			top: true
			bottom: true
		}

		exclusiveZone: 0
		visible: root.osdVisible
		color: "transparent"
		WlrLayershell.exclusionMode: ExclusionMode.Ignore
		WlrLayershell.layer: WlrLayer.Overlay

		property real shown: root.osdVisible ? 1 : 0

		Behavior on shown {
			NumberAnimation {
				duration: root.osdVisible ? Arc.unroll : Arc.reroll
				easing.type: Easing.Bezier
				easing.bezierCurve: root.osdVisible ? Arc.curveUnroll : Arc.curveReroll
			}
		}

		// The ring: struck on every change, damped by the stone.
		property real ring: 0
		property real ringVelocity: 0

		Connections {
			target: root
			function onOsdProgressChanged() {
				osdWindow.ringVelocity += 0.34;
				ringClock.running = true;
			}
		}

		Timer {
			id: ringClock
			interval: 16
			repeat: true
			onTriggered: {
				osdWindow.ringVelocity += -osdWindow.ring * 0.34;
				osdWindow.ringVelocity *= 0.86;
				osdWindow.ring += osdWindow.ringVelocity;
				if (Math.abs(osdWindow.ring) < 0.004 && Math.abs(osdWindow.ringVelocity) < 0.004) {
					osdWindow.ring = 0;
					ringClock.running = false;
				}
			}
		}

		// The cord it is let down on, out of the vertex of the chain.
		Rectangle {
			anchors.horizontalCenter: parent.horizontalCenter
			y: Arc.gantryDepth - 6
			width: Arc.ruleThin
			height: Math.max(0, crystal.y - (Arc.gantryDepth - 6))
			color: Qt.alpha(Arc.gilt, 0.4 * osdWindow.shown)
		}

		Item {
			id: crystal

			readonly property real level: Math.max(0, Math.min(1, root.osdProgress))

			width: 120
			height: 188
			x: Math.round((parent.width - width) / 2)
			y: Math.round(Arc.gantryDepth + Arc.s6 + (1 - osdWindow.shown) * -70)
			opacity: Math.min(1, osdWindow.shown * 2.2)

			scale: 1 + osdWindow.ring * 0.05

			ArcHalo {
				anchors.centerIn: parent
				width: parent.width * 2.4
				height: parent.height * 1.8
				color: Arc.aether
				strength: 0.30 + Math.abs(osdWindow.ring) * 0.3
				spread: 0.36
				flicker: true
			}

			// The stone. Cut once, filled every frame the level moves: the
			// facets are static, the light in them is not.
			Canvas {
				id: stone
				anchors.fill: parent
				renderStrategy: Canvas.Cooperative

				readonly property real level: crystal.level
				readonly property real struck: osdWindow.ring

				onLevelChanged: requestPaint()
				onStruckChanged: requestPaint()

				function facets(w, h) {
					// A hexagonal bipyramid seen side-on: shoulder, waist,
					// point. Six sides, because a crystal with four is a
					// diamond and a crystal with eight is a ball.
					const cx = w / 2;
					return [
						{ x: cx, y: h * 0.02 },
						{ x: w * 0.90, y: h * 0.24 },
						{ x: w * 0.90, y: h * 0.70 },
						{ x: cx, y: h * 0.98 },
						{ x: w * 0.10, y: h * 0.70 },
						{ x: w * 0.10, y: h * 0.24 }
					];
				}

				onPaint: {
					const ctx = getContext("2d");
					ctx.reset();
					if (width < 8) return;
					const outline = stone.facets(width, height);
					const shadow = Qt.alpha(Qt.darker(Arc.gilt, 2.3), 0.6);
					const highlight = Qt.alpha(Qt.lighter(Arc.gilt, 1.8), 0.55);

					// the body of the stone
					Ink.polyline(ctx, outline, true);
					const body = ctx.createLinearGradient(0, 0, 0, height);
					body.addColorStop(0, Arc.leaf2);
					body.addColorStop(1, Arc.well);
					ctx.fillStyle = body;
					ctx.fill();

					// what has been poured into it
					const top = height * (0.98 - 0.96 * stone.level);
					ctx.save();
					Ink.polyline(ctx, outline, true);
					ctx.clip();
					const lit = ctx.createLinearGradient(0, top, 0, height);
					lit.addColorStop(0, Qt.alpha(Arc.aether, 0.85));
					lit.addColorStop(1, Qt.alpha(Arc.aether, 0.32));
					ctx.fillStyle = lit;
					// the surface tips when the stone is struck
					const tip = height * 0.035 * stone.struck;
					ctx.beginPath();
					ctx.moveTo(0, top + tip);
					ctx.quadraticCurveTo(width / 2, top - tip * 2.2, width, top + tip);
					ctx.lineTo(width, height);
					ctx.lineTo(0, height);
					ctx.closePath();
					ctx.fill();
					ctx.restore();

					// the cut: the girdle, the two table edges and the point
					Ink.groove(ctx, outline, Arc.rule * 1.4, Arc.gilt, highlight, shadow, true);
					Ink.cut(ctx, [{ x: width * 0.10, y: height * 0.24 }, { x: width * 0.90, y: height * 0.24 }],
						Arc.ruleThin, Qt.alpha(Arc.gilt, 0.5), false);
					Ink.cut(ctx, [{ x: width * 0.10, y: height * 0.70 }, { x: width * 0.90, y: height * 0.70 }],
						Arc.ruleThin, Qt.alpha(Arc.gilt, 0.5), false);
					Ink.cut(ctx, [{ x: width / 2, y: height * 0.02 }, { x: width / 2, y: height * 0.98 }],
						Arc.ruleThin, Qt.alpha(Arc.gilt, 0.28), false);
					Ink.cut(ctx, [{ x: width * 0.10, y: height * 0.24 }, { x: width / 2, y: height * 0.02 }],
						Arc.ruleThin, Qt.alpha(Arc.gilt, 0.3), false);
					Ink.cut(ctx, [{ x: width * 0.90, y: height * 0.24 }, { x: width / 2, y: height * 0.02 }],
						Arc.ruleThin, Qt.alpha(Arc.gilt, 0.3), false);
				}
			}

			// The reading, cut on the table of the stone.
			Column {
				anchors.horizontalCenter: parent.horizontalCenter
				y: parent.height * 0.29
				spacing: -3

				ArcText {
					anchors.horizontalCenter: parent.horizontalCenter
					role: "reading"
					font.pixelSize: 22
					text: root.osdValueText
				}

				ArcText {
					anchors.horizontalCenter: parent.horizontalCenter
					role: "label"
					tone: "muted"
					font.pixelSize: 9
					text: root.osdLabel
				}
			}

			// The mark of whatever is being turned, set at the point.
			Image {
				anchors.horizontalCenter: parent.horizontalCenter
				y: parent.height * 0.76
				width: 17
				height: 17
				source: root.osdIconSource
				fillMode: Image.PreserveAspectFit
				smooth: true
				mipmap: true
				layer.enabled: visible
				layer.effect: MultiEffect {
					colorization: 1
					colorizationColor: Arc.onAether
				}
			}
		}
	}

	// THE CHAIN.
	//
	// There is no bar. A brass chain is strung across the top of the screen,
	// fixed at both corners, sagging to its lowest point in the middle — and
	// every fitting the shell has is seated on that curve, so nothing on it
	// shares a height with anything else. The grimoire's clasp is at the far
	// left, the realms hang off the left limb, the horologe hangs at the lowest
	// point where the eye rests, and everything the machine is carrying runs
	// back up the right limb to the way out.
	//
	// Panels are not attached to this window. They are let down from it: see
	// components/PopupSurface.qml, which reads the same curve.
	PanelWindow {
		id: barWindow
		screen: root.primaryBarScreen

		anchors {
			left: true
			right: true
			top: true
		}

		margins {
			left: 0
			right: 0
			top: 0
		}

		exclusiveZone: Math.round(Arc.gantryDepth)
		implicitHeight: Math.round(Arc.gantryDepth)
		color: "transparent"

		Item {
			id: bar
			anchors.fill: parent

			// Where the chain hangs at a given x, and where a fitting of a
			// given size has to sit to be seated on it.
			function chainAt(centreX) {
				return Arc.chainY(centreX / Math.max(1, bar.width));
			}

			function seatY(centreX, size) {
				return Math.round(bar.chainAt(centreX) - size / 2);
			}

			// The instrument's own shadow on the desktop. Without a plane of
			// its own the engraving would disappear into a bright wallpaper,
			// and raising the line opacity until it did not would be uglier
			// than admitting the instrument casts a shade.
			Rectangle {
				anchors.fill: parent
				gradient: Gradient {
					GradientStop { position: 0.0; color: Qt.alpha(Arc.well, Arc.light ? 0.50 : 0.92) }
					GradientStop { position: 0.62; color: Qt.alpha(Arc.well, Arc.light ? 0.34 : 0.66) }
					GradientStop { position: 1.0; color: "transparent" }
				}
			}

			// The chain itself, and the graduations cut along it. Painted once
			// per resize: this window redraws whenever a clock digit changes
			// and it must not cost anything to keep on screen.
			Canvas {
				id: chain
				anchors.fill: parent
				renderStrategy: Canvas.Cooperative

				Connections {
					target: Arc
					function onGiltChanged() { chain.requestPaint(); }
				}

				onPaint: {
					const ctx = getContext("2d");
					ctx.reset();
					if (width <= 8) return;
					const shadow = Qt.alpha(Qt.darker(Arc.gilt, 2.4), 0.6);
					const highlight = Qt.alpha(Qt.lighter(Arc.gilt, 1.8), 0.5);
					// Two straight runs meeting under the horologe, broken
					// where the dial hangs: the chain goes behind it, and a
					// line drawn across a dial is a line drawn across a dial.
					const gap = Arc.horologe * 0.44;
					Ink.groove(ctx, [
						{ x: 0, y: Arc.gantryRise },
						{ x: width / 2 - gap, y: Arc.chainY(0.5 - gap / width) }
					], Arc.rule * 2.0, Arc.gilt, highlight, shadow, false);
					Ink.groove(ctx, [
						{ x: width / 2 + gap, y: Arc.chainY(0.5 + gap / width) },
						{ x: width, y: Arc.gantryRise }
					], Arc.rule * 2.0, Arc.gilt, highlight, shadow, false);

					// The limb is graduated, because this is an instrument and
					// not a rail. Every fifth mark runs long.
					const spacing = 26;
					const marks = Math.floor(width / spacing);
					for (let index = 0; index <= marks; index++) {
						const x = index * spacing;
						const y = Arc.chainY(x / width);
						const long = index % 5 === 0;
						Ink.cut(ctx, [{ x: x, y: y + 2 }, { x: x, y: y + (long ? 8 : 4) }],
							Arc.ruleThin, Qt.alpha(Arc.gilt, long ? 0.55 : 0.3), false);
					}

					// The two anchor plates the chain is bolted to.
					for (const side of [0, width]) {
						const dir = side === 0 ? 1 : -1;
						Ink.groove(ctx, [
							{ x: side, y: Arc.gantryRise + 16 },
							{ x: side, y: Arc.gantryRise },
							{ x: side + dir * 20, y: Arc.gantryRise }
						], Arc.rule * 1.4, Arc.gilt, highlight, shadow, false);
						Ink.rivet(ctx, side + dir * 7, Arc.gantryRise, 2.4, Arc.gilt, highlight, shadow);
					}


				}
			}

			// ------------------------------------------------------ the left limb
			// What opens things, and what is already open.
			Row {
				id: leftLimb
				anchors.left: parent.left
				anchors.leftMargin: 22
				anchors.top: parent.top
				height: parent.height
				spacing: Arc.s3

				ArcSeat {
					id: launcherNode
					size: 34
					seed: 0
					lit: root.launcherPopupOpen
					y: bar.seatY(leftLimb.x + x + width / 2, height)
					onClicked: root.toggleLauncherPopup()

					// The grimoire, drawn rather than fetched: the one thing
					// on the chain that has no system icon and should not
					// borrow one.
					ArcMark {
						anchors.centerIn: parent
						width: parent.width * 0.60
						height: parent.height * 0.60
						glyph: "book"
						weight: Arc.rule
						lineColor: launcherNode.lit ? Arc.aether : Arc.ink
					}
				}

				NiriTaskbar {
					id: taskbarIsland
					visible: niriState.tasksForOutput(String(barWindow.screen?.name || "")).length > 0
					height: barWindow.height
					niriState: niriState
					outputName: String(barWindow.screen?.name || "")
					originX: leftLimb.x + x
					chainAt: bar.chainAt
					background: Arc.leaf1
					foreground: Arc.ink
					secondaryBoxColor: Arc.leaf2
					secondaryBoxStrongColor: Arc.leaf3
				}
			}

			// -------------------------------------------------- the lowest point
			// The horologe: the hour, held where the chain hangs deepest.
			// Around it the day is engraved on the left and what is playing on
			// the right, so the middle of the chain reads as one instrument.
			Item {
				id: horologe

				width: Arc.horologe
				height: Arc.horologe
				x: Math.round((bar.width - width) / 2)
				y: bar.seatY(bar.width / 2, height)

				readonly property real seconds: root.now.getSeconds() + root.now.getMilliseconds() / 1000

				ArcHalo {
					anchors.centerIn: parent
					width: parent.width * 2.3
					height: parent.height * 2.3
					color: Arc.aether
					strength: 0.26
					spread: 0.34
					flicker: true
				}

				// The face. Cast, filled and engine-turned, so the dial is a
				// thing hanging in front of the wallpaper rather than two rings
				// drawn on top of it. Painted once.
				Canvas {
					id: face
					anchors.fill: parent
					renderStrategy: Canvas.Cooperative

					Connections {
						target: Arc
						function onGiltChanged() { face.requestPaint(); }
						function onLeaf1Changed() { face.requestPaint(); }
					}

					onPaint: {
						const ctx = getContext("2d");
						ctx.reset();
						const cx = width / 2, cy = height / 2;
						const r = Math.min(width, height) / 2 - 1;

						const cast = ctx.createLinearGradient(0, 0, 0, height);
						cast.addColorStop(0, Arc.leaf2);
						cast.addColorStop(1, Arc.well);
						ctx.fillStyle = cast;
						ctx.beginPath();
						ctx.arc(cx, cy, r, 0, Math.PI * 2);
						ctx.fill();

						// Engine turning: the lathe pattern on an instrument's
						// face. It is the difference between brass and a circle.
						Ink.guilloche(ctx, cx, cy, r * 0.74, 22, r * 0.045, 3,
							Arc.ruleThin * 0.7, Qt.alpha(Arc.gilt, 0.14));
					}
				}

				// The limb: the seconds, taken round the outside.
				ArcDial {
					id: secondsLimb
					anchors.fill: parent
					seed: 0
					weight: Arc.rule
					lineColor: Arc.giltDim
					liveColor: Arc.aether
					intensity: Math.max(horologeTouch.live, root.clockPopupOpen ? 0.9 : 0)
					progress: horologe.seconds / 60
				}

				// The minutes, taken round a second limb inside the first.
				ArcDial {
					anchors.centerIn: parent
					width: parent.width - 13
					height: parent.height - 13
					seed: 1
					weight: Arc.ruleThin
					beading: false
					lineColor: Arc.giltGhost
					liveColor: Arc.aetherAlt
					progress: (root.now.getMinutes() + horologe.seconds / 60) / 60
				}

				Column {
					anchors.centerIn: parent
					spacing: -3

					ArcText {
						anchors.horizontalCenter: parent.horizontalCenter
						role: "reading"
						font.pixelSize: 20
						font.letterSpacing: 0.5
						text: Qt.formatDateTime(root.now, "HH:mm")
					}

					Rectangle {
						anchors.horizontalCenter: parent.horizontalCenter
						width: 22
						height: Arc.ruleThin
						color: Arc.giltFaint
					}

					// The moon, because the instrument is telling you which
					// part of the night this is and not only the time.
					Canvas {
						id: moon
						anchors.horizontalCenter: parent.horizontalCenter
						width: 13
						height: 13
						renderStrategy: Canvas.Cooperative

						readonly property real phase: Arc.moonPhase(root.now).fraction

						onPhaseChanged: requestPaint()

						onPaint: {
							const ctx = getContext("2d");
							ctx.reset();
							const r = width / 2 - 1;
							ctx.strokeStyle = Arc.giltDim;
							ctx.lineWidth = Arc.ruleThin;
							ctx.beginPath();
							ctx.arc(width / 2, height / 2, r, 0, Math.PI * 2);
							ctx.stroke();
							// The terminator: the lit limb is a half circle, and
							// the inner edge is an ellipse whose width is the
							// cosine of the phase. Waxing lights the right.
							const waxing = moon.phase < 0.5;
							const sweep = Math.cos(moon.phase * Math.PI * 2);
							ctx.fillStyle = Arc.gilt;
							ctx.beginPath();
							ctx.arc(width / 2, height / 2, r,
								waxing ? -Math.PI / 2 : Math.PI / 2,
								waxing ? Math.PI / 2 : Math.PI * 1.5);
							ctx.closePath();
							ctx.fill();
							ctx.globalCompositeOperation = sweep > 0 ? "destination-out" : "source-over";
							ctx.beginPath();
							ctx.ellipse(width / 2 - Math.abs(sweep) * r, height / 2 - r,
								Math.abs(sweep) * r * 2, r * 2);
							ctx.fill();
							ctx.globalCompositeOperation = "source-over";
						}
					}
				}

				ArcTouch {
					id: horologeTouch
					onClicked: root.toggleClockPopup()
				}
			}

			// The day, engraved on the chain to the left of the horologe, and
			// under it the name this hour goes by.
			Column {
				id: dayBlock
				anchors.right: horologe.left
				anchors.rightMargin: Arc.s4
				y: Math.round(bar.chainAt(dayBlock.x + dayBlock.width / 2) - dayBlock.height / 2)
				spacing: -1

				ArcText {
					anchors.right: parent.right
					role: "label"
					tone: "muted"
					text: Qt.formatDateTime(root.now, "ddd dd MMM")
				}

				ArcText {
					anchors.right: parent.right
					role: "hand"
					tone: "faint"
					font.pixelSize: 13
					text: Arc.hourName(root.now)
				}
			}

			Timer {
				running: true
				repeat: true
				interval: 1000
				onTriggered: root.now = new Date()
			}

			// ----------------------------------------------------- the right limb
			// Laid out from the right edge inwards, so the way out is always
			// the last fitting on the chain and never moves.
			Row {
				id: rightLimb
				anchors.right: parent.right
				anchors.rightMargin: 22
				anchors.top: parent.top
				height: parent.height
				layoutDirection: Qt.RightToLeft
				spacing: Arc.s3

				function seatedY(item) {
					return bar.seatY(rightLimb.x + item.x + item.width / 2, item.height);
				}

				ArcSeat {
					id: powerNode
					seed: 2
					lit: root.powerPopupOpen
					y: bar.seatY(rightLimb.x + x + width / 2, height)
					ringColor: Qt.alpha(Arc.bane, 0.5)
					liveColor: Arc.bane
					iconColor: powerNode.lit ? Arc.bane : Qt.alpha(Arc.bane, 0.85)
					iconSource: Arc.icon("system-shutdown-symbolic")
					onClicked: root.togglePowerPopup()
				}

				Item {
					id: trayRun
					width: trayRow.width
					height: barWindow.height
					visible: trayRepeater.count > 0

					Row {
						id: trayRow
						spacing: Arc.s2

						Repeater {
							id: trayRepeater
							model: ScriptModel {
								values: SystemTray.items.values
							}

							ArcSeat {
								id: trayNode

								required property SystemTrayItem modelData
								required property int index

								size: 26
								seed: trayNode.index + 1
								y: bar.seatY(rightLimb.x + trayRun.x + trayNode.x + width / 2, height)
								acceptedButtons: Qt.LeftButton | Qt.RightButton

								Image {
									anchors.centerIn: parent
									width: 14
									height: 14
									source: root.resolveIconSource(root.trayIconSource(trayNode.modelData?.icon ?? ""))
									fillMode: Image.PreserveAspectFit
									smooth: true
									mipmap: true
								}

								onClicked: event => {
									if (trayNode.modelData.menu) {
										if (
											root.trayMenuOpen
											&& root.trayMenuVisible
											&& root.trayMenuHandle === trayNode.modelData.menu
										) {
											root.closeTrayMenu();
										} else {
											root.openTrayMenu(trayNode.modelData.menu, trayNode);
										}
									} else {
										root.closeTrayMenu();
										if (event.button === Qt.RightButton) trayNode.modelData.secondaryActivate();
										else trayNode.modelData.activate();
									}
								}
							}
						}
					}
				}

				TopBarResourceBars {
					id: resourceBars
					lit: root.resourcesPopupOpen
					y: bar.seatY(rightLimb.x + x + width / 2, height)
					onClicked: root.toggleResourcesPopup()
				}

				ArcSeat {
					id: networkNode
					seed: 0
					lit: root.networkPopupOpen
					y: bar.seatY(rightLimb.x + x + width / 2, height)
					iconSource: root.networkStatusType === "ethernet"
						? Arc.icon("network-wired-symbolic")
						: Arc.icon("network-wireless-signal-excellent-symbolic")
					onClicked: root.toggleNetworkPopup()
				}

				ArcSeat {
					id: bluetoothNode
					seed: 3
					lit: root.bluetoothPopupOpen
					y: bar.seatY(rightLimb.x + x + width / 2, height)
					iconSource: root.resolveIconSource("bluetooth-active-symbolic", ["bluetooth-symbolic"]) || Arc.icon("bluetooth-active-symbolic")
					onClicked: root.toggleBluetoothPopup()
				}

				ArcSeat {
					id: clipboardNode
					seed: 2
					lit: root.clipboardPopupOpen
					y: bar.seatY(rightLimb.x + x + width / 2, height)
					iconSource: root.resolveIconSource("edit-paste-symbolic", ["edit-copy-symbolic"]) || Arc.icon("edit-paste-symbolic")
					onClicked: root.toggleClipboardPopup()
				}

				ArcSeat {
					id: notifNode
					seed: 1
					lit: root.notifPopupOpen
					y: bar.seatY(rightLimb.x + x + width / 2, height)
					badge: root.notificationGroups.length > 0 ? String(root.notificationGroups.length) : ""
					iconSource: root.resolveIconSource("preferences-system-notifications-symbolic", ["dialog-information-symbolic"]) || Arc.icon("preferences-system-notifications-symbolic")
					onClicked: root.toggleNotifPopup()
				}

				// The oracle: the sky's mark with the reading struck beside it,
				// because a temperature nobody can see is not a reading.
				Item {
					id: weatherRun
					width: weatherNode.width + weatherReading.implicitWidth + Arc.s1
					height: barWindow.height

					ArcSeat {
						id: weatherNode
						seed: 3
						size: 28
						lit: root.weatherPopupOpen
						y: bar.seatY(rightLimb.x + weatherRun.x + x + width / 2, height)
						iconSource: root.resolveIconSource("", [
							root.weatherIcon,
							root.weatherIcon.replace("-symbolic", ""),
							"weather-overcast-symbolic"
						])
						iconSize: 14
						onClicked: root.toggleWeatherPopup()
					}

					ArcText {
						id: weatherReading
						anchors.left: weatherNode.right
						anchors.leftMargin: Arc.s1
						y: Math.round(bar.chainAt(rightLimb.x + weatherRun.x + x + width / 2) - height / 2)
						role: "reading"
						font.pixelSize: 14
						text: root.weatherTemperature
					}
				}

				NowPlaying {
					id: nowPlayingIsland
					originX: rightLimb.x + x
					chainAt: bar.chainAt
					foreground: Arc.ink
					secondaryBoxColor: Arc.leaf1
					progressColor: Arc.aether
					onClicked: root.toggleMediaPopup()
				}
			}
		}
	}
	Variants {
		model: root.extraBarScreens

		TopBarReplica {
			required property var modelData

			screenModel: modelData
			foreground: root.foreground
			background: root.background
			secondaryBoxColor: root.surface
			secondaryBoxStrongColor: root.secondaryBoxStrongColor
			secondaryInsetColor: root.secondaryInsetColor
			tertiary: root.accent
			primary: root.primary
			onPrimaryColor: root.onPrimary
			danger: root.danger
			networkStatusType: root.networkStatusType
			niriState: niriState
			onLauncherClicked: root.toggleLauncherPopup(modelData)
			onMediaClicked: root.toggleMediaPopup(modelData)
			onClockClicked: root.toggleClockPopup(modelData)
			onClipboardClicked: root.toggleClipboardPopup(modelData)
			onBluetoothClicked: root.toggleBluetoothPopup(modelData)
			onNetworkClicked: root.toggleNetworkPopup(modelData)
			onResourcesClicked: root.toggleResourcesPopup(modelData)
			onPowerClicked: root.togglePowerPopup(modelData)
		}
	}

	Timer {
		id: launcherPopupOpenTimer
		interval: 16
		repeat: false
		onTriggered: {
			root.launcherPopupOpen = true;
			launcherPopupResetTimer.restart();
		}
	}

	Timer {
		id: launcherPopupResetTimer
		interval: 10
		repeat: false
		onTriggered: {
			if (launcherPopup.visible && launcherSheetLoader.item) launcherSheetLoader.item.reset();
		}
	}

	Timer {
		running: true
		repeat: true
		interval: 300000
		triggeredOnStart: true
		onTriggered: root.refreshWeather()
	}

	Timer {
		id: clockPopupCloseTimer
		interval: Motion.popupClose + 50
		repeat: false
		onTriggered: {
			if (!root.clockPopupOpen) root.clockPopupVisible = false;
		}
	}

	Timer {
		id: weatherPopupCloseTimer
		interval: Motion.popupClose + 50
		repeat: false
		onTriggered: {
			if (!root.weatherPopupOpen) root.weatherPopupVisible = false;
		}
	}

	Timer {
		id: notifPopupCloseTimer
		interval: Motion.popupClose + 50
		repeat: false
		onTriggered: {
			if (!root.notifPopupOpen) root.notifPopupVisible = false;
		}
	}

	Timer {
		id: mediaPopupCloseTimer
		interval: Motion.popupClose + 50
		repeat: false
		onTriggered: {
			if (!root.mediaPopupOpen) root.mediaPopupVisible = false;
		}
	}

	Timer {
		id: clipboardPopupCloseTimer
		interval: Motion.popupClose + 50
		repeat: false
		onTriggered: {
			if (!root.clipboardPopupOpen) root.clipboardPopupVisible = false;
		}
	}

	Timer {
		id: clipboardPopupRefreshTimer
		interval: 10
		repeat: false
		onTriggered: {
			if (clipboardPopup.visible) clipboardPopupContent.refresh();
		}
	}

	Timer {
		id: bluetoothPopupCloseTimer
		interval: Motion.popupClose + 50
		repeat: false
		onTriggered: {
			if (!root.bluetoothPopupOpen) root.bluetoothPopupVisible = false;
		}
	}

	Timer {
		id: networkPopupCloseTimer
		interval: Motion.popupClose + 50
		repeat: false
		onTriggered: {
			if (!root.networkPopupOpen) root.networkPopupVisible = false;
		}
	}

	Timer {
		id: resourcesPopupCloseTimer
		interval: Motion.popupClose + 50
		repeat: false
		onTriggered: {
			if (!root.resourcesPopupOpen) root.resourcesPopupVisible = false;
		}
	}

	Timer {
		id: powerPopupCloseTimer
		interval: Motion.largeClose + 50
		repeat: false
		onTriggered: {
			if (!root.powerPopupOpen) root.powerPopupVisible = false;
		}
	}

	Timer {
		id: studioPopupCloseTimer
		interval: Motion.largeClose + 50
		repeat: false
		onTriggered: {
			if (!root.studioPopupOpen) root.studioPopupVisible = false;
		}
	}

	Timer {
		id: launcherPopupCloseTimer
		interval: Motion.largeClose + 50
		repeat: false
		onTriggered: {
			if (!root.launcherPopupOpen) root.launcherPopupVisible = false;
		}
	}

	Timer {
		id: trayMenuCloseTimer
		interval: Motion.popupClose + 50
		repeat: false
		onTriggered: {
			if (!root.trayMenuOpen) {
				root.trayMenuVisible = false;
				root.trayMenuHandle = null;
				root.trayMenuTargetItem = null;
			}
		}
	}

	PopupSurface {
		id: clipboardPopup
		title: "Palimpsest"
		screen: root.activePopupScreen

		onDismissRequested: root.closeClipboardPopup()
		open: root.clipboardPopupOpen
		visible: root.clipboardPopupVisible
		barItem: bar
		anchorItem: clipboardNode
		surfaceColor: root.surface
		borderColor: root.surfaceBorder
		expandedWidth: 360
		contentPreferredHeight: clipboardColumn.implicitHeight

		onVisibleChanged: {
			if (!visible && root.clipboardPopupVisible) {
				if (root.clipboardPopupOpen) root.closeClipboardPopup();
				else root.clipboardPopupVisible = false;
			}
		}

				Item {
					id: clipboardPopupContent
					anchors.fill: parent

					property var entries: []
					property string searchText: ""
					property int selectedIndex: 0
					readonly property var filteredEntries: {
						const query = searchText.trim().toLowerCase();
						if (query === "") return entries;
						return entries.filter(entry => String(entry.preview || "").toLowerCase().includes(query));
					}

					function imageExtension(preview) {
						const text = String(preview || "").toLowerCase();
						if (text.includes(" png ")) return "png";
						if (text.includes(" jpeg ") || text.includes(" jpg ")) return "jpg";
						if (text.includes(" webp ")) return "webp";
						if (text.includes(" gif ")) return "gif";
						return "";
					}

					function refresh() {
						clipboardListProcess.running = true;
						Qt.callLater(function() {
							selectedIndex = 0;
							clipboardSearch.forceActiveFocus();
						});
					}

					function parseEntries(raw) {
						const lines = String(raw || "").split("\n").filter(line => line.trim() !== "");
						const next = [];
						for (const line of lines) {
							const match = line.match(/^(\d+)\s+(.*)$/);
							if (!match) continue;
							const preview = match[2];
							const extension = imageExtension(preview);
							const isImage = preview.startsWith("[[ binary data") && extension !== "";
							const entry = {
								id: match[1],
								preview: preview,
								raw: line,
								isImage: isImage,
								extension: extension,
								previewPath: isImage ? `/tmp/qs-cliphist-preview-${match[1]}.${extension}` : ""
							};
							next.push(entry);
						}
						entries = next;
						selectedIndex = Math.max(0, Math.min(selectedIndex, filteredEntries.length - 1));
					}

					function clampSelectedIndex() {
						selectedIndex = Math.max(0, Math.min(selectedIndex, filteredEntries.length - 1));
					}

					function moveSelection(delta) {
						if (filteredEntries.length === 0) return;
						selectedIndex = Math.max(0, Math.min(selectedIndex + delta, filteredEntries.length - 1));
						clipboardList.currentIndex = selectedIndex;
						clipboardList.positionViewAtIndex(selectedIndex, ListView.Contain);
					}

					function activateSelection() {
						if (filteredEntries.length === 0) return;
						clampSelectedIndex();
						selectEntry(filteredEntries[selectedIndex]);
					}

					function selectEntry(entry) {
						if (!entry?.raw) return;
						Quickshell.execDetached([
							"sh",
							"-lc",
							`printf '%s\n' '${root.shellEscape(entry.raw)}' | cliphist decode | wl-copy`
						]);
						root.closeClipboardPopup();
					}

					Process {
						id: clipboardListProcess
						command: ["sh", "-lc", "cliphist list"]
						stdout: StdioCollector {
							onStreamFinished: clipboardPopupContent.parseEntries(text)
						}
					}

					Column {
						id: clipboardColumn
						anchors.fill: parent
						spacing: 12

						Item {
							width: parent.width
							height: 20

							ArcText {
								id: clipTitle
								anchors.left: parent.left
								anchors.verticalCenter: parent.verticalCenter
								role: "title"
								font.pixelSize: 15
								text: "Scraps"
							}

							ArcFlourish {
								anchors.left: clipTitle.right
								anchors.right: clipWipeLabel.visible ? clipWipeLabel.left : clipCountLabel.left
								anchors.leftMargin: Arc.s3
								anchors.rightMargin: Arc.s3
								anchors.verticalCenter: parent.verticalCenter
								height: 12
								facing: Qt.LeftToRight
								lineColor: Arc.giltFaint
								visible: width > 24
							}

							ArcText {
								id: clipWipeLabel
								anchors.right: clipCountLabel.left
								anchors.rightMargin: Arc.s3
								anchors.verticalCenter: parent.verticalCenter
								visible: clipboardPopupContent.entries.length > 0
								role: "label"
								tone: clipWipeTouch.containsMouse ? "alert" : "muted"
								text: "Efface"

								ArcTouch {
									id: clipWipeTouch
									anchors.margins: -Arc.s2
									onClicked: {
										Quickshell.execDetached(["sh", "-lc", "cliphist wipe"]);
										clipboardPopupContent.entries = [];
									}
								}
							}

							ArcText {
								id: clipCountLabel
								anchors.right: parent.right
								anchors.verticalCenter: parent.verticalCenter
								role: "label"
								tone: "faint"
								text: clipboardPopupContent.entries.length
							}
						}

						Item {
							width: parent.width
							height: 34

							Rectangle {
								anchors.left: parent.left
								anchors.right: parent.right
								anchors.bottom: parent.bottom
								height: Arc.ruleThin
								color: Arc.giltFaint
							}

							Rectangle {
								anchors.left: parent.left
								anchors.bottom: parent.bottom
								width: clipboardSearch.activeFocus ? parent.width : 0
								height: Arc.rule
								color: Arc.aether

								Behavior on width {
									NumberAnimation { duration: Arc.turn; easing.type: Easing.OutCubic }
								}
							}

							ArcDial {
								id: clipSearchIcon
								anchors.left: parent.left
								anchors.verticalCenter: parent.verticalCenter
								width: 24
								height: 24
								seed: 2
								lineColor: Arc.giltFaint
								intensity: clipboardSearch.activeFocus ? 0.9 : 0

								QQCImpl.IconImage {
									anchors.centerIn: parent
									width: 12
									height: 12
									source: "/usr/share/icons/Adwaita/symbolic/actions/edit-find-symbolic.svg"
									sourceSize: Qt.size(width, height)
									color: clipboardSearch.activeFocus ? Arc.aether : Arc.inkMuted
								}
							}

							TextField {
								id: clipboardSearch
								anchors.fill: parent
								anchors.leftMargin: 34
								anchors.bottomMargin: Arc.s2
								font.family: Arc.book
								font.pixelSize: Arc.sizeBody
								color: Arc.ink
								placeholderText: "Sift the palimpsest"
								placeholderTextColor: Arc.inkFaint
								selectedTextColor: Arc.ink
								selectionColor: Qt.alpha(Arc.aether, 0.3)
								selectByMouse: true
								focus: root.clipboardPopupVisible
								background: Item {}
								onTextChanged: {
									clipboardPopupContent.searchText = text;
									clipboardPopupContent.selectedIndex = 0;
									clipboardList.currentIndex = clipboardPopupContent.filteredEntries.length > 0 ? 0 : -1;
									if (clipboardList.currentIndex >= 0)
										clipboardList.positionViewAtIndex(clipboardList.currentIndex, ListView.Beginning);
								}
								Keys.onDownPressed: {
									clipboardPopupContent.moveSelection(1);
									clipboardList.forceActiveFocus();
								}
								Keys.onUpPressed: {
									clipboardPopupContent.moveSelection(-1);
									clipboardList.forceActiveFocus();
								}
								Keys.onReturnPressed: clipboardPopupContent.activateSelection()
								Keys.onEnterPressed: clipboardPopupContent.activateSelection()
								Keys.onEscapePressed: root.closeClipboardPopup()
							}
						}

						Item {
							width: parent.width
							height: 330

							ArcText {
								role: "body"
								anchors.centerIn: parent
								visible: clipboardPopupContent.filteredEntries.length === 0
								color: Qt.alpha(foreground, 0.5)
								font.pixelSize: 12
								text: clipboardPopupContent.searchText !== "" ? "No matches" : "Clipboard is empty"
							}

							ListView {
								id: clipboardList
								anchors.fill: parent
								clip: true
								spacing: 8
								model: clipboardPopupContent.filteredEntries
								boundsBehavior: Flickable.StopAtBounds
								currentIndex: clipboardPopupContent.filteredEntries.length > 0
									? clipboardPopupContent.selectedIndex
									: -1

								add: Transition {
									NumberAnimation {
										properties: "opacity"
										from: 0
										to: 1
										duration: Motion.normal
										easing.type: ThemeEngine.standardEasing
									}
								}

								displaced: Transition {
									NumberAnimation {
										properties: "y"
										duration: Motion.normal
										easing.type: ThemeEngine.standardEasing
									}
								}

								onCurrentIndexChanged: {
									if (currentIndex >= 0) clipboardPopupContent.selectedIndex = currentIndex;
								}

								Keys.onDownPressed: clipboardPopupContent.moveSelection(1)
								Keys.onUpPressed: clipboardPopupContent.moveSelection(-1)
								Keys.onReturnPressed: clipboardPopupContent.activateSelection()
								Keys.onEnterPressed: clipboardPopupContent.activateSelection()
								Keys.onEscapePressed: root.closeClipboardPopup()

								ScrollBar.vertical: ScrollBar {
									policy: ScrollBar.AsNeeded
								}

								// A scrap of residue: text on the membrane with a vein
								// beside it, or the image itself framed in bone.
								delegate: ArcEntry {
									id: clipEntry
									required property var modelData
									required property int index
									readonly property bool current: clipEntry.index === clipboardPopupContent.selectedIndex

									width: ListView.view.width
									implicitHeight: clipEntry.modelData.isImage ? 104 : 40
									inset: Arc.s3
									selected: clipEntry.current
									onClicked: clipboardPopupContent.selectEntry(clipEntry.modelData)
									onContainsMouseChanged: {
										if (containsMouse) clipboardPopupContent.selectedIndex = clipEntry.index;
									}

									Component.onCompleted: {
										if (!clipEntry.modelData.isImage) return;
										imagePreviewProcess.running = true;
									}

									ArcText {
										visible: clipEntry.modelData.isImage
										anchors.left: parent.left
										anchors.top: parent.top
										anchors.topMargin: Arc.s2
										role: "label"
										tone: "faint"
										text: clipEntry.modelData.extension.toUpperCase()
									}

									Item {
										visible: clipEntry.modelData.isImage && clipEntry.modelData.previewPath !== ""
										anchors.centerIn: parent
										width: 88
										height: 88

										ArcPlate {
											anchors.fill: parent
											variant: "plate"
											beading: false
											weight: Arc.ruleThin
											lineColor: Arc.giltFaint
											liveColor: Arc.aether
											intensity: clipEntry.current ? 1 : 0
										}

										Image {
											id: imagePreview
											anchors.fill: parent
											anchors.margins: 4
											source: ""
											fillMode: Image.PreserveAspectCrop
											smooth: true
											mipmap: true
											cache: false
										}
									}

									Process {
										id: imagePreviewProcess
										command: [
											"sh",
											"-lc",
											`printf '%s\n' '${root.shellEscape(modelData.raw)}' | cliphist decode > '${root.shellEscape(modelData.previewPath)}'`
										]
										onExited: {
											imagePreview.source = `${clipEntry.modelData.previewPath}?t=${Date.now()}`;
										}
									}

									ArcText {
										visible: !clipEntry.modelData.isImage
										anchors.left: parent.left
										anchors.right: deleteButton.left
										anchors.rightMargin: Arc.s3
										anchors.verticalCenter: parent.verticalCenter
										role: "body"
										tone: clipEntry.current ? "default" : "muted"
										maximumLineCount: 1
										text: clipEntry.modelData.preview
									}

									Item {
										id: deleteButton
										anchors.right: parent.right
										anchors.verticalCenter: parent.verticalCenter
										width: 20
										height: 20
										opacity: clipEntry.containsMouse || deleteHover.containsMouse || clipEntry.current ? 1 : 0

										Behavior on opacity {
											NumberAnimation { duration: Arc.tick }
										}

										ArcText {
											anchors.centerIn: parent
											role: "body"
											tone: deleteHover.containsMouse ? "alert" : "faint"
											text: "\u00d7"
										}

										ArcTouch {
											id: deleteHover
											onClicked: {
												Quickshell.execDetached([
													"sh",
													"-lc",
													`printf '%s\n' '${root.shellEscape(clipEntry.modelData.raw)}' | cliphist delete`
												]);
												const next = clipboardPopupContent.entries.filter(e => e.raw !== clipEntry.modelData.raw);
												clipboardPopupContent.entries = next;
												clipboardPopupContent.clampSelectedIndex();
											}
										}
									}
								}
							}
						}
					}
				}
	}

	PopupSurface {
		id: bluetoothPopup
		title: "Bindings"
		screen: root.activePopupScreen

		onDismissRequested: root.closeBluetoothPopup()
		open: root.bluetoothPopupOpen
		visible: root.bluetoothPopupVisible
		barItem: bar
		anchorItem: bluetoothNode
		surfaceColor: root.surface
		borderColor: root.surfaceBorder
		expandedWidth: 300
		contentPreferredHeight: bluetoothPopupColumn.implicitHeight

		property bool powered: false
		property bool scanning: false
		property var devices: []
		property var deviceStatuses: ({})
		property string pendingConnectAddress: ""
		property string pendingConnectOutput: ""

		function parseStatus(raw) {
			const lines = String(raw || "").split("\n");
			let powered = false;

			for (const line of lines) {
				if (line.startsWith("powered=")) {
					powered = line.slice("powered=".length).trim() === "yes";
				}
			}

			bluetoothPopup.powered = powered;
			if (!powered) bluetoothPopup.devices = [];
		}

		function parseDevices(raw) {
			const lines = String(raw || "").split("\n");
			const deviceMap = {};
			for (const device of bluetoothPopup.devices) {
				deviceMap[device.address] = Object.assign({}, device);
			}

			const next = [];
			let current = null;

			for (const line of lines) {
				if (line.startsWith("device=")) {
					if (current) next.push(current);
					current = {
						address: line.slice("device=".length).trim(),
						name: "",
						connected: false,
						paired: false,
						trusted: false,
						battery: ""
					};
					continue;
				}

				if (!current) continue;
				if (line.startsWith("name=")) current.name = line.slice("name=".length).trim();
				else if (line.startsWith("connected=")) current.connected = line.slice("connected=".length).trim() === "yes";
				else if (line.startsWith("paired=")) current.paired = line.slice("paired=".length).trim() === "yes";
				else if (line.startsWith("trusted=")) current.trusted = line.slice("trusted=".length).trim() === "yes";
				else if (line.startsWith("battery=")) current.battery = line.slice("battery=".length).trim();
			}

			if (current) next.push(current);

			for (const device of next) {
				const existing = deviceMap[device.address] || {};
				deviceMap[device.address] = {
					address: device.address,
					name: device.name || existing.name || "",
					connected: device.connected,
					paired: device.paired,
					trusted: device.trusted,
					battery: device.battery || existing.battery || ""
				};
			}

			const filtered = Object.values(deviceMap);

			filtered.sort((left, right) => {
				if (left.connected !== right.connected) return left.connected ? -1 : 1;
				if (left.paired !== right.paired) return left.paired ? -1 : 1;
				return String(left.name || left.address).localeCompare(String(right.name || right.address));
			});

			bluetoothPopup.devices = filtered;

			const nextStatuses = Object.assign({}, bluetoothPopup.deviceStatuses);
			for (const device of filtered) {
				if (device.connected) nextStatuses[device.address] = "Connected";
				else if (bluetoothPopup.pendingConnectAddress === device.address) nextStatuses[device.address] = "Connecting...";
				else if (nextStatuses[device.address] === "Connected") nextStatuses[device.address] = device.paired ? "Paired" : "Available";
				else if (nextStatuses[device.address] !== "Failed") nextStatuses[device.address] = device.paired ? "Paired" : "Available";
			}
			bluetoothPopup.deviceStatuses = nextStatuses;
		}

		function mergeScannedDevices(raw) {
			const lines = String(raw || "").split("\n");
			const deviceMap = {};
			for (const device of bluetoothPopup.devices) {
				deviceMap[device.address] = Object.assign({}, device);
			}

			for (const line of lines) {
				const match = line.match(/Device\s+([0-9A-F:]{17})\s+(.+)$/i);
				if (!match) continue;

				const address = match[1].trim();
				const name = match[2].trim();
				if (name === "" || name === address || /^([0-9A-F]{2}:){5}[0-9A-F]{2}$/i.test(name)) continue;

				const existing = deviceMap[address] || {
					address,
					name: "",
					connected: false,
					paired: false,
					trusted: false,
					battery: ""
				};

				deviceMap[address] = Object.assign({}, existing, { name });
			}

			const merged = Object.values(deviceMap);
			merged.sort((left, right) => {
				if (left.connected !== right.connected) return left.connected ? -1 : 1;
				if (left.paired !== right.paired) return left.paired ? -1 : 1;
				return String(left.name || left.address).localeCompare(String(right.name || right.address));
			});

			bluetoothPopup.devices = merged;
		}

		function refresh() {
			bluetoothStatusProcess.running = true;
			bluetoothDevicesProcess.running = true;
		}

		function connectStatusFromOutput(outputText) {
			const output = String(outputText || "").toLowerCase();
			if (output.includes("br-connection-key-missing")) return "Re-pair required";
			if (output.includes("host is down")) return "Controller off?";
			if (output.includes("authenticationcanceled") || output.includes("authentication canceled")) return "Pairing canceled";
			if (output.includes("alreadyconnected") || output.includes("already connected")) return "Connected";
			if (output.includes("not available")) return "Unavailable";
			return "Failed";
		}

		function togglePower() {
			Quickshell.execDetached([
				"sh",
				"-lc",
				bluetoothPopup.powered
					? "bluetoothctl power off"
					: "bluetoothctl power on && bluetoothctl pairable on"
			]);
			Qt.callLater(function() {
				bluetoothPopup.refresh();
			});
		}

		function startScan() {
			if (bluetoothPopup.scanning) return;
			bluetoothPopup.scanning = true;
			bluetoothPopup.devices = [];
			bluetoothScanProcess.running = true;
			bluetoothPopup.refresh();
		}

		function connectDevice(address) {
			if (!address) return;
			const device = bluetoothPopup.devices.find(item => item.address === address);
			const nextStatuses = Object.assign({}, bluetoothPopup.deviceStatuses);
			const disconnecting = !!device?.connected;
			nextStatuses[address] = disconnecting ? "Disconnecting..." : "Connecting...";
			bluetoothPopup.deviceStatuses = nextStatuses;
			bluetoothPopup.pendingConnectAddress = address;
			bluetoothPopup.pendingConnectOutput = "";
			bluetoothConnectProcess.command = [
				"sh",
				"-lc",
				disconnecting
					? `bluetoothctl disconnect '${address}' 2>&1`
					: (
						device?.paired
							? `bluetoothctl trust '${address}' >/dev/null 2>&1; bluetoothctl connect '${address}' 2>&1`
							: `bluetoothctl pairable on >/dev/null 2>&1; bluetoothctl agent on >/dev/null 2>&1; bluetoothctl default-agent >/dev/null 2>&1; bluetoothctl pair '${address}' 2>&1 && bluetoothctl trust '${address}' 2>&1 && bluetoothctl connect '${address}' 2>&1`
					)
			];
			bluetoothConnectProcess.running = true;
		}

		onVisibleChanged: {
			if (!visible && root.bluetoothPopupVisible) {
				if (root.bluetoothPopupOpen) {
					root.closeBluetoothPopup();
				} else {
					root.bluetoothPopupVisible = false;
				}
			}
		}

		Timer {
			running: root.bluetoothPopupVisible
			repeat: true
			interval: 3000
			triggeredOnStart: true
			onTriggered: bluetoothPopup.refresh()
		}

		Timer {
			id: bluetoothConnectRefreshTimer
			interval: 2000
			repeat: false
			onTriggered: bluetoothPopup.refresh()
		}

		Process {
			id: bluetoothScanProcess
			command: ["sh", "-lc", "bluetoothctl power on >/dev/null 2>&1; bluetoothctl pairable on >/dev/null 2>&1; bluetoothctl --timeout 8 scan on 2>/dev/null"]
			stdout: StdioCollector {
				onStreamFinished: {
					bluetoothPopup.scanning = false;
					bluetoothPopup.mergeScannedDevices(text);
					bluetoothPopup.refresh();
				}
			}
		}

		Process {
			id: bluetoothStatusProcess
			command: ["sh", "-lc", "bluetoothctl show | awk '/Powered:/ {print \"powered=\" tolower($2)}'"]
			stdout: StdioCollector {
				onStreamFinished: bluetoothPopup.parseStatus(text)
			}
		}

		Process {
			id: bluetoothDevicesProcess
			command: [
				"sh",
				"-lc",
				`bluetoothctl devices | while read -r _ address name; do
  [ -n "$address" ] || continue
  printf 'device=%s\n' "$address"
  info="$(bluetoothctl info "$address" 2>/dev/null)"
  alias_name="$(printf '%s\n' "$info" | awk -F': ' '/^\tAlias: / {print $2; exit}')"
  pretty_name="$(printf '%s\n' "$info" | awk -F': ' '/^\tName: / {print $2; exit}')"
  final_name="$alias_name"
  [ -n "$final_name" ] || final_name="$pretty_name"
  [ -n "$final_name" ] || final_name="$name"
  printf 'name=%s\n' "$final_name"
  printf '%s\n' "$info" | awk '
    /Connected:/ {print "connected=" tolower($2)}
    /Paired:/ {print "paired=" tolower($2)}
    /Trusted:/ {print "trusted=" tolower($2)}
    /Battery Percentage:/ {
      value=$0
      if (match(value, /\\(([0-9]+)%?\\)/, percent)) {
        print "battery=" percent[1] "%"
      } else {
        sub(/^.*Battery Percentage:[[:space:]]*/, "", value)
        split(value, parts, " ")
        if (parts[1] != "") print "battery=" parts[1]
      }
    }
  '
done`
			]
			stdout: StdioCollector {
				onStreamFinished: bluetoothPopup.parseDevices(text)
			}
		}

		Process {
			id: bluetoothConnectProcess
			command: ["sh", "-lc", ":"]
			stdout: StdioCollector {
				onStreamFinished: bluetoothPopup.pendingConnectOutput = text
			}
			onExited: exitCode => {
				const address = bluetoothPopup.pendingConnectAddress;
				const outputText = bluetoothPopup.pendingConnectOutput;
				bluetoothPopup.pendingConnectAddress = "";
				bluetoothPopup.pendingConnectOutput = "";
				if (address !== "") {
					const device = bluetoothPopup.devices.find(item => item.address === address);
					const nextStatuses = Object.assign({}, bluetoothPopup.deviceStatuses);
					if (exitCode === 0) nextStatuses[address] = device?.connected ? "Disconnecting..." : "Connecting...";
					else nextStatuses[address] = bluetoothPopup.connectStatusFromOutput(outputText);
					bluetoothPopup.deviceStatuses = nextStatuses;
				}
				bluetoothConnectRefreshTimer.restart();
			}
		}

				Item {
					id: bluetoothPopupContent
					anchors.fill: parent

					Column {
						id: bluetoothPopupColumn
						anchors.fill: parent
						spacing: 12

						Item {
							width: parent.width
							height: 24

							ArcText {
								id: btTitle
								anchors.left: parent.left
								anchors.verticalCenter: parent.verticalCenter
								role: "title"
								font.pixelSize: 15
								text: "The Binding"
							}

							ArcFlourish {
								anchors.left: btTitle.right
								anchors.right: btSwitch.left
								anchors.leftMargin: Arc.s3
								anchors.rightMargin: Arc.s3
								anchors.verticalCenter: parent.verticalCenter
								height: 12
								facing: Qt.LeftToRight
								lineColor: Arc.giltFaint
								visible: width > 24
							}

							ArcLever {
								id: btSwitch
								anchors.right: parent.right
								anchors.verticalCenter: parent.verticalCenter
								checked: bluetoothPopup.powered
								onToggled: bluetoothPopup.togglePower()
							}
						}

						// Sensing: a ring that turns while the adapter is listening,
						// and the verb beside it. No button plate — the ring is
						// the control.
						Item {
							width: parent.width
							height: 30
							visible: bluetoothPopup.powered

							ArcDial {
								id: scanIcon
								anchors.left: parent.left
								anchors.verticalCenter: parent.verticalCenter
								width: 26
								height: 26
								seed: 1
								lineColor: Arc.giltFaint
								intensity: bluetoothPopup.scanning ? 1 : scanTouch.live

								RotationAnimator on rotation {
									running: bluetoothPopup.scanning
									loops: Animation.Infinite
									from: 0
									to: 360
									duration: 2600
								}
							}

							ArcText {
								id: scanLabel
								anchors.left: scanIcon.right
								anchors.leftMargin: Arc.s3
								anchors.verticalCenter: parent.verticalCenter
								role: "label"
								tone: bluetoothPopup.scanning || scanTouch.containsMouse ? "aether" : "muted"
								text: bluetoothPopup.scanning ? "Sensing" : "Sense"
							}

							ArcFlourish {
								anchors.left: scanLabel.right
								anchors.right: parent.right
								anchors.leftMargin: Arc.s3
								anchors.verticalCenter: parent.verticalCenter
								height: 12
								facing: Qt.LeftToRight
								lineColor: bluetoothPopup.scanning ? Qt.alpha(Arc.aether, 0.55) : Arc.giltGhost
								visible: width > 24
							}

							ArcTouch {
								id: scanTouch
								onClicked: bluetoothPopup.startScan()
							}
						}

						Item {
							width: parent.width
							implicitHeight: bluetoothPopup.powered ? 250 : 64

							Column {
								visible: !bluetoothPopup.powered
								anchors.centerIn: parent
								spacing: Arc.s3

								ArcRune {
									anchors.horizontalCenter: parent.horizontalCenter
									width: 46
									height: 46
									seed: 17
									lineColor: Arc.giltGhost
								}

								ArcText {
									anchors.horizontalCenter: parent.horizontalCenter
									role: "label"
									tone: "faint"
									text: "Bindings dormant"
								}
							}

							ListView {
								visible: bluetoothPopup.powered
								anchors.fill: parent
								clip: true
								spacing: 8
								model: bluetoothPopup.devices
								boundsBehavior: Flickable.StopAtBounds

								add: Transition {
									NumberAnimation {
										properties: "opacity"
										from: 0
										to: 1
										duration: Motion.normal
										easing.type: ThemeEngine.standardEasing
									}
								}

								displaced: Transition {
									NumberAnimation {
										properties: "y"
										duration: Motion.normal
										easing.type: ThemeEngine.standardEasing
									}
								}

								ScrollBar.vertical: ScrollBar {
									policy: ScrollBar.AsNeeded
								}

								header: ArcText {
									visible: bluetoothPopup.devices.length === 0
									width: ListView.view ? ListView.view.width : 0
									height: visible ? 30 : 0
									horizontalAlignment: Text.AlignHCenter
									verticalAlignment: Text.AlignVCenter
									role: "label"
									tone: "faint"
									text: "Nothing within reach"
								}

								// A tethered organism: the ring carries its mark and
								// lights when it is attached, the vein says the row is
								// live, and its charge is engraved, not chipped.
								delegate: ArcEntry {
									id: btDevice
									required property var modelData
									readonly property string deviceIcon: {
										const n = String(btDevice.modelData.name || "").toLowerCase();
										if (/bud|head|arctis|wh-|wf-|airpod|speaker|soundcore|jbl/.test(n))
											return "/usr/share/icons/Adwaita/symbolic/devices/audio-headphones-symbolic.svg";
										if (n.includes("mouse"))
											return "/usr/share/icons/Adwaita/symbolic/devices/input-mouse-symbolic.svg";
										if (n.includes("keyboard") || n.includes("keychron"))
											return "/usr/share/icons/Adwaita/symbolic/devices/input-keyboard-symbolic.svg";
										if (/phone|pixel|galaxy|iphone/.test(n))
											return "/usr/share/icons/Adwaita/symbolic/devices/phone-symbolic.svg";
										if (/tv|cast/.test(n))
											return "/usr/share/icons/Adwaita/symbolic/devices/tv-symbolic.svg";
										return "/usr/share/icons/Adwaita/symbolic/status/bluetooth-active-symbolic.svg";
									}

									width: ListView.view.width
									implicitHeight: 46
									inset: Arc.s3
									selected: Boolean(btDevice.modelData.connected)
									onClicked: bluetoothPopup.connectDevice(btDevice.modelData.address)

									ArcDial {
										id: btMark
										anchors.left: parent.left
										anchors.verticalCenter: parent.verticalCenter
										width: 30
										height: 30
										seed: 2
										lineColor: Arc.giltGhost
										intensity: btDevice.modelData.connected ? 1 : btDevice.live

										QQCImpl.IconImage {
											anchors.centerIn: parent
											width: 14
											height: 14
											source: btDevice.deviceIcon
											sourceSize: Qt.size(width, height)
											color: btDevice.modelData.connected ? Arc.aether : Arc.ink
										}
									}

									Column {
										anchors.left: btMark.right
										anchors.leftMargin: Arc.s3
										anchors.right: btBatteryChip.visible ? btBatteryChip.left : parent.right
										anchors.rightMargin: Arc.s3
										anchors.verticalCenter: parent.verticalCenter
										spacing: -1

										ArcText {
											width: parent.width
											role: "bodyStrong"
											tone: btDevice.modelData.connected ? "aether" : "default"
											text: btDevice.modelData.name
										}

										ArcText {
											width: parent.width
											role: "caption"
											tone: "faint"
											text: bluetoothPopup.deviceStatuses[btDevice.modelData.address]
												|| (btDevice.modelData.connected ? "Attached" : (btDevice.modelData.paired ? "Known" : "Adrift"))
										}
									}

									ArcText {
										id: btBatteryChip
										visible: btDevice.modelData.connected && String(btDevice.modelData.battery || "") !== ""
										anchors.right: parent.right
										anchors.verticalCenter: parent.verticalCenter
										role: "reading"
										font.pixelSize: 13
										tone: "muted"
										text: btDevice.modelData.battery
									}
								}
							}
						}
					}
				}
	}

	PopupSurface {
		id: networkPopup
		title: "Ley"
		screen: root.activePopupScreen

		onDismissRequested: root.closeNetworkPopup()
		open: root.networkPopupOpen
		visible: root.networkPopupVisible
		barItem: bar
		anchorItem: networkNode
		surfaceColor: root.surface
		borderColor: root.surfaceBorder
		expandedWidth: 300
		fixedHeight: 470

		property string currentType: "offline"
		property string currentInterface: ""
		property string currentIp: ""
		property real currentUploadSpeed: 0
		property real currentDownloadSpeed: 0
		property real lastRxBytes: 0
		property real lastTxBytes: 0
		property bool throughputSampleReady: false
		// One place for the sampling period: the timer that reads /proc/net/dev
		// and the delta that turns two readings into a speed have to agree.
		readonly property int throughputIntervalMs: 2000
		property var uploadHistory: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
		property var downloadHistory: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
		readonly property real uploadChartMax: networkPopup.historyMax(networkPopup.uploadHistory)
		readonly property real downloadChartMax: networkPopup.historyMax(networkPopup.downloadHistory)

		function clampSpeed(value) {
			return Math.max(0, Number(value) || 0);
		}

		function formatSpeed(bytesPerSecond) {
			const value = networkPopup.clampSpeed(bytesPerSecond);
			if (value >= 1024 * 1024 * 1024) return `${(value / (1024 * 1024 * 1024)).toFixed(1)} GB/s`;
			if (value >= 1024 * 1024) return `${(value / (1024 * 1024)).toFixed(1)} MB/s`;
			if (value >= 1024) return `${(value / 1024).toFixed(1)} KB/s`;
			return `${Math.round(value)} B/s`;
		}

		function historyMax(values) {
			let maxValue = 1;
			for (const value of values || []) maxValue = Math.max(maxValue, Number(value) || 0);
			return maxValue;
		}

		function chartRatio(value, maxValue) {
			const clampedMax = Math.max(1, Number(maxValue) || 1);
			return Math.max(0, Math.min(1, (Number(value) || 0) / clampedMax));
		}

		function pushHistorySample(history, value) {
			const next = history.slice();
			next.push(networkPopup.clampSpeed(value));
			while (next.length > 20) next.shift();
			return next;
		}

		function updateThroughput(raw) {
			if (networkPopup.currentInterface === "") {
				networkPopup.currentUploadSpeed = 0;
				networkPopup.currentDownloadSpeed = 0;
				networkPopup.uploadHistory = networkPopup.pushHistorySample(networkPopup.uploadHistory, 0);
				networkPopup.downloadHistory = networkPopup.pushHistorySample(networkPopup.downloadHistory, 0);
				networkPopup.throughputSampleReady = false;
				return;
			}

			const pattern = new RegExp(`^\\s*${networkPopup.currentInterface}:\\s*(.+)$`, "m");
			const match = String(raw || "").match(pattern);
			if (!match) return;

			const fields = match[1].trim().split(/\s+/);
			if (fields.length < 16) return;

			const rxBytes = Number(fields[0]) || 0;
			const txBytes = Number(fields[8]) || 0;

			if (!networkPopup.throughputSampleReady) {
				networkPopup.lastRxBytes = rxBytes;
				networkPopup.lastTxBytes = txBytes;
				networkPopup.throughputSampleReady = true;
				return;
			}

			const intervalSeconds = networkPopup.throughputIntervalMs / 1000;
			const downloadSpeed = Math.max(0, (rxBytes - networkPopup.lastRxBytes) / intervalSeconds);
			const uploadSpeed = Math.max(0, (txBytes - networkPopup.lastTxBytes) / intervalSeconds);

			networkPopup.lastRxBytes = rxBytes;
			networkPopup.lastTxBytes = txBytes;
			networkPopup.currentDownloadSpeed = downloadSpeed;
			networkPopup.currentUploadSpeed = uploadSpeed;
			networkPopup.uploadHistory = networkPopup.pushHistorySample(networkPopup.uploadHistory, uploadSpeed);
			networkPopup.downloadHistory = networkPopup.pushHistorySample(networkPopup.downloadHistory, downloadSpeed);
		}

		function resetThroughput() {
			networkPopup.currentUploadSpeed = 0;
			networkPopup.currentDownloadSpeed = 0;
			networkPopup.lastRxBytes = 0;
			networkPopup.lastTxBytes = 0;
			networkPopup.throughputSampleReady = false;
			networkPopup.uploadHistory = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
			networkPopup.downloadHistory = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
		}

		function applyStatus(raw) {
			const lines = String(raw || "").split("\n");
			const parsed = {};

			for (const line of lines) {
				const separator = line.indexOf("=");
				if (separator === -1) continue;
				parsed[line.slice(0, separator)] = line.slice(separator + 1);
			}

			const nextType = parsed.type || "offline";
			const nextInterface = parsed.iface || "";
			const interfaceChanged = nextInterface !== networkPopup.currentInterface;

			networkPopup.currentType = nextType;
			root.networkStatusType = networkPopup.currentType;
			networkPopup.currentInterface = nextInterface;
			networkPopup.currentIp = parsed.ip || "";

			if (interfaceChanged || nextType === "offline") networkPopup.resetThroughput();
		}

		onVisibleChanged: {
			if (!visible && root.networkPopupVisible) {
				if (root.networkPopupOpen) {
					root.closeNetworkPopup();
				} else {
					root.networkPopupVisible = false;
				}
			}
		}

		// Which interface carries the connection changes on the order of
		// minutes; the bar icon does not need a process every two seconds. The
		// popup, which shows the interface and its address, refreshes faster
		// while it is actually on screen.
		Timer {
			running: true
			repeat: true
			interval: root.networkPopupVisible ? 2000 : 10000
			triggeredOnStart: true
			onTriggered: networkStatusProcess.running = true
		}

		// Throughput is a live read-out. It is only live while it is visible, and
		// the first sample after reopening is thrown away rather than counted as
		// one interval's worth of everything that happened in between.
		Timer {
			running: root.networkPopupVisible
			repeat: true
			interval: networkPopup.throughputIntervalMs
			triggeredOnStart: true
			onTriggered: netDevFile.reload()
			onRunningChanged: if (!running) networkPopup.resetThroughput()
		}

		Process {
			id: networkStatusProcess
			// sh -c, not sh -lc: a login shell sources the whole profile chain,
			// which is a lot of work for a script that only reads /sys and runs ip.
			command: [
				"sh",
				"-c",
				`for iface in /sys/class/net/*; do
name=$(basename "$iface")
case "$name" in
  lo|docker*|br-*|virbr*|veth*|podman*|zt*|tun*|tap*) continue ;;
esac
state=$(cat "$iface/operstate" 2>/dev/null || printf 'down')
carrier=$(cat "$iface/carrier" 2>/dev/null || printf '0')
if [ -d "$iface/wireless" ]; then
  [ "$state" = "up" ] || [ "$carrier" = "1" ] || continue
  ip=$(ip -4 -o addr show dev "$name" scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}')
  printf 'type=wifi\niface=%s\nip=%s\n' "$name" "$ip"
  exit 0
fi
[ "$carrier" = "1" ] || [ "$state" = "up" ] || continue
ip=$(ip -4 -o addr show dev "$name" scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}')
printf 'type=ethernet\niface=%s\nip=%s\n' "$name" "$ip"
exit 0
done
printf 'type=offline\niface=\nip=\n'`
			]
			stdout: StdioCollector {
				onStreamFinished: networkPopup.applyStatus(text)
			}
		}

		FileView {
			id: netDevFile
			path: "/proc/net/dev"
			onLoaded: networkPopup.updateThroughput(text())
		}

					Item {
						id: networkPopupContent
						anchors.fill: parent

						Item {
							id: networkPopupColumn
							anchors.fill: parent

							// What the machine is attached to, and by what.
							Item {
								id: linkHead
								anchors.left: parent.left
								anchors.right: parent.right
								anchors.top: parent.top
								height: 34

								ArcDial {
									id: linkMark
									anchors.left: parent.left
									anchors.verticalCenter: parent.verticalCenter
									width: 32
									height: 32
									seed: 0
									lineColor: Arc.giltFaint
									intensity: networkPopup.currentType === "offline" ? 0 : 1

									QQCImpl.IconImage {
										anchors.centerIn: parent
										width: 15
										height: 15
										source: networkPopup.currentType === "ethernet"
											? Arc.icon("network-wired-symbolic")
											: Arc.icon("network-wireless-signal-excellent-symbolic")
										sourceSize: Qt.size(width, height)
										color: networkPopup.currentType === "offline" ? Arc.inkMuted : Arc.aether
									}
								}

								Column {
									anchors.left: linkMark.right
									anchors.leftMargin: Arc.s3
									anchors.right: severLabel.visible ? severLabel.left : parent.right
									anchors.rightMargin: Arc.s3
									anchors.verticalCenter: parent.verticalCenter
									spacing: -1

									ArcText {
										width: parent.width
										role: "heading"
										tone: networkPopup.currentType === "offline" ? "muted" : "default"
										text: networkPopup.currentType === "offline"
											? "Severed"
											: (networkPopup.currentType === "ethernet" ? "Corded" : "Airborne")
									}

									ArcText {
										width: parent.width
										role: "caption"
										tone: "faint"
										text: networkPopup.currentInterface !== ""
											? `${networkPopup.currentInterface} · ${networkPopup.currentIp !== "" ? networkPopup.currentIp : "no address"}`
											: "no interface"
									}
								}

								ArcText {
									id: severLabel
									visible: networkPopup.currentType !== "offline"
									anchors.right: parent.right
									anchors.verticalCenter: parent.verticalCenter
									role: "label"
									tone: severTouch.containsMouse ? "alert" : "muted"
									text: "Sever"

									ArcTouch {
										id: severTouch
										anchors.margins: -Arc.s2
										onClicked: root.disconnectActiveNetwork()
									}
								}
							}

						// Throughput, as two pulses given the whole height of the
						// chamber to move in. The trace is the same ribbon the rest
						// of the style is drawn with, so a busy link reads as
						// something alive rather than as a line chart in a box.
						Item {
							id: outflowBlock
							anchors.left: parent.left
							anchors.right: parent.right
							anchors.top: linkHead.bottom
							anchors.topMargin: Arc.s5
							height: (parent.height - linkHead.height - Arc.s5 * 2 - Arc.s5) / 2

							ArcRubric {
								id: outflowHead
								width: parent.width
								title: "Outflow"
								trailing: networkPopup.formatSpeed(networkPopup.currentUploadSpeed)
							}

							ArcTrace {
								id: uploadChart
								anchors.left: parent.left
								anchors.right: parent.right
								anchors.top: outflowHead.bottom
								anchors.topMargin: Arc.s3
								anchors.bottom: parent.bottom
								values: networkPopup.uploadHistory || []
								ceiling: networkPopup.uploadChartMax
								traceColor: Arc.aether

								Connections {
									target: networkPopup
									function onUploadHistoryChanged() { uploadChart.repaint(); }
									function onCurrentUploadSpeedChanged() { uploadChart.repaint(); }
								}
							}
						}

						Item {
							id: intakeBlock
							anchors.left: parent.left
							anchors.right: parent.right
							anchors.top: outflowBlock.bottom
							anchors.topMargin: Arc.s5
							anchors.bottom: parent.bottom

							ArcRubric {
								id: intakeHead
								width: parent.width
								title: "Intake"
								trailing: networkPopup.formatSpeed(networkPopup.currentDownloadSpeed)
							}

							ArcTrace {
								id: downloadChart
								anchors.left: parent.left
								anchors.right: parent.right
								anchors.top: intakeHead.bottom
								anchors.topMargin: Arc.s3
								anchors.bottom: parent.bottom
								values: networkPopup.downloadHistory || []
								ceiling: networkPopup.downloadChartMax
								traceColor: Arc.aetherAlt

								Connections {
									target: networkPopup
									function onDownloadHistoryChanged() { downloadChart.repaint(); }
									function onCurrentDownloadSpeedChanged() { downloadChart.repaint(); }
								}
							}
						}
					}
				}
	}

	PopupSurface {
		id: resourcesPopup
		title: "Humours"
		screen: root.activePopupScreen

		onDismissRequested: root.closeResourcesPopup()
		open: root.resourcesPopupOpen
		visible: root.resourcesPopupVisible
		barItem: bar
		anchorItem: resourceBars
		surfaceColor: root.surface
		borderColor: root.surfaceBorder
		expandedWidth: 420
		contentPreferredHeight: resourcesPopupColumn.implicitHeight

		onVisibleChanged: {
			if (!visible && root.resourcesPopupVisible) {
				if (root.resourcesPopupOpen) {
					root.closeResourcesPopup();
				} else {
					root.resourcesPopupVisible = false;
				}
			}
		}

						Item {
							id: resourcesPopupContent
							anchors.fill: parent

							Column {
								id: resourcesPopupColumn
								anchors.fill: parent
								spacing: Arc.s4

								ArcRubric {
									width: parent.width
									title: "The Rack"
									trailing: resourceBars.cpuText
								}

								// The rack, at the size it deserves. The letters on
								// the chain are these four, spelled out: what the
								// machine is actually carrying, in glass.
								Row {
									anchors.horizontalCenter: parent.horizontalCenter
									spacing: Arc.s6

									ArcMeasure {
										value: resourceBars.cpuUsage
										label: "Mana"
										detail: resourceBars.cpuText
									}

									ArcMeasure {
										value: resourceBars.memoryUsage
										label: "Aether"
										detail: resourceBars.memoryText
										fillColor: Arc.aetherAlt
									}

									ArcMeasure {
										value: resourceBars.storageUsage
										label: "Vault"
										detail: `${resourceBars.disks.length} stores`
										fillColor: Arc.aetherThird
									}

									ArcMeasure {
										visible: resourceBars.mouseBatteryAvailable
										value: resourceBars.mouseBatteryUsage
										label: "Essence"
										detail: resourceBars.mouseBatteryText
										inverted: true
									}
								}

								ArcRubric {
									width: parent.width
									visible: resourceBars.mouseBatteryAvailable
									title: "Essence"
									trailing: resourceBars.mouseBatteryStatus

									ResourceRow {
										width: parent.width
										label: resourceBars.mouseBatteryName
										detail: ""
										usage: resourceBars.mouseBatteryUsage
										valueText: resourceBars.mouseBatteryText
									}
								}

								ArcRubric {
									width: parent.width
									title: "Vaults"
									trailing: `${resourceBars.disks.length}`

									Column {
										width: parent.width
										spacing: Arc.s3

										Repeater {
											model: resourceBars.disks

											delegate: ResourceRow {
												required property var modelData
												width: parent.width
												label: modelData.name
												detail: `${modelData.usedText}/${modelData.totalText}`
												usage: modelData.usage
												valueText: `${modelData.freeText} left`
											}
										}
									}
								}
							}
						}
	}

	// The launcher takes the whole bench. There is no sheet and no card: the
	// desktop is dimmed to a cavity, the spine stays lit down the left, and the
	// work is laid out directly on the dark with bone rules for structure. It
	// arrives the way the chambers do — wiped in from the column.
	PanelWindow {
		id: launcherPopup
		screen: root.activePopupScreen

		anchors {
			left: true
			right: true
			top: true
			bottom: true
		}

		exclusiveZone: 0
		color: "transparent"
		visible: root.launcherPopupVisible
		WlrLayershell.exclusionMode: ExclusionMode.Ignore
		WlrLayershell.layer: WlrLayer.Overlay
		WlrLayershell.keyboardFocus: root.launcherPopupVisible ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

		// The chain is never covered. The grimoire dims the desktop under it
		// and leaves the chain lit and live, so the clasp you opened this with
		// is still there to shut it.
		mask: Region {
			x: 0
			y: Math.round(Arc.gantryDepth)
			width: launcherPopup.width
			height: Math.max(0, launcherPopup.height - Math.round(Arc.gantryDepth))
		}

		property real progress: root.launcherPopupOpen ? 1 : 0

		// Two movements, in order, the same pair every modal in this style
		// makes: the volume is lowered off the chain, and only then is it
		// opened. Reading begins after that, which is what the launcher's own
		// band stagger is for.
		readonly property real lower: Math.max(0, Math.min(1, progress / 0.42))
		readonly property real turned: Math.max(0, Math.min(1, (progress - 0.36) / 0.64))

		Behavior on progress {
			NumberAnimation {
				duration: root.launcherPopupOpen ? Arc.unroll + Arc.turn : Arc.reroll + 70
				easing.type: Easing.Bezier
				easing.bezierCurve: root.launcherPopupOpen ? Arc.curveUnroll : Arc.curveReroll
			}
		}

		Rectangle {
			anchors.left: parent.left
			anchors.right: parent.right
			anchors.top: parent.top
			anchors.bottom: parent.bottom
			anchors.topMargin: Math.round(Arc.gantryDepth)
			color: Arc.well
			opacity: 0.985 * launcherPopup.progress
		}

		MouseArea {
			anchors.fill: parent
			anchors.topMargin: Math.round(Arc.gantryDepth)
			onClicked: root.closeLauncherPopup()
		}

		// THE GRIMOIRE.
		//
		// The launcher is a book, and it behaves like one. It is lowered off
		// the chain on two cords, its boards turn outward about the gutter, and
		// what is underneath them is a two-page spread with a sewn binding down
		// the middle and the cut edges of the page block showing at the sides.
		// Nothing here is a panel with a list in it.
		Item {
			id: book

			readonly property real boardMargin: 9
			readonly property real typeMargin: 30

			width: Math.min(parent.width - Arc.s8 * 2, 1520)
			height: parent.height - Arc.gantryDepth - Arc.s6 * 2
			x: Math.round((parent.width - width) / 2)
			y: Math.round(Arc.gantryDepth + Arc.s6 - (1 - launcherPopup.lower) * 110)
			opacity: Math.min(1, launcherPopup.lower * 2.2)

			// The cords it hangs on while it is coming down.
			Repeater {
				model: 2
				delegate: Rectangle {
					required property int index
					x: index === 0 ? Arc.s8 : book.width - Arc.s8
					y: -(book.y - Arc.gantryDepth + Arc.s2)
					width: Arc.ruleThin
					height: Math.max(0, book.y - Arc.gantryDepth + Arc.s2)
					color: Qt.alpha(Arc.gilt, 0.4 * (1 - launcherPopup.turned))
				}
			}

			ArcHalo {
				anchors.centerIn: parent
				width: parent.width * 1.2
				height: parent.height * 1.3
				color: Arc.aether
				strength: 0.13 * launcherPopup.progress
				spread: 0.46
				flicker: true
			}

			// The page block: the boards around the outside, a tooled brass
			// line on them, and two leaves of vellum inside.
			Rectangle {
				anchors.fill: parent
				color: Arc.leaf3

				Rectangle {
					anchors.fill: parent
					color: "transparent"
					border.width: Arc.rule
					border.color: Arc.giltDim
				}

				Rectangle {
					anchors.fill: parent
					anchors.margins: 4
					color: "transparent"
					border.width: Arc.ruleThin
					border.color: Arc.giltGhost
				}

				Rectangle {
					anchors.fill: parent
					anchors.margins: book.boardMargin
					color: Arc.leaf1

					// The leaves are not flat. A page lifts off the board at
					// its fore-edge and falls away into the binding, and that
					// is the only reason a spread reads as paper.
					Rectangle {
						anchors.fill: parent
						gradient: Gradient {
							orientation: Gradient.Horizontal
							GradientStop { position: 0.00; color: Qt.alpha(Arc.raised, 0.045) }
							GradientStop { position: 0.36; color: "transparent" }
							GradientStop { position: 0.64; color: "transparent" }
							GradientStop { position: 1.00; color: Qt.alpha(Arc.raised, 0.045) }
						}
					}
				}
			}

			Repeater {
				model: 2

				delegate: Item {
					required property int index
					readonly property bool leftEdge: index === 0

					x: leftEdge ? book.boardMargin : book.width - book.boardMargin - width
					y: book.boardMargin + 6
					width: 7
					height: book.height - book.boardMargin * 2 - 12

					Repeater {
						model: 4
						delegate: Rectangle {
							required property int index
							x: index * 2
							width: Arc.ruleThin
							height: parent.height
							color: Qt.alpha(Arc.gilt, 0.16 - index * 0.03)
						}
					}
				}
			}

			// The binding: the gutter shadow, and the thread the sections are
			// sewn on. This is the line the boards turn about.
			Rectangle {
				anchors.horizontalCenter: parent.horizontalCenter
				anchors.top: parent.top
				anchors.bottom: parent.bottom
				anchors.topMargin: book.boardMargin
				anchors.bottomMargin: book.boardMargin
				width: Arc.s8

				gradient: Gradient {
					orientation: Gradient.Horizontal
					GradientStop { position: 0.00; color: "transparent" }
					GradientStop { position: 0.34; color: Qt.alpha(Arc.well, 0.55) }
					GradientStop { position: 0.50; color: Qt.alpha(Arc.well, 0.95) }
					GradientStop { position: 0.66; color: Qt.alpha(Arc.well, 0.55) }
					GradientStop { position: 1.00; color: "transparent" }
				}

				// The sewing: the thread showing through the fold, in pairs,
				// the way a section is actually sewn onto its cords.
				Repeater {
					model: 6

					delegate: Item {
						required property int index
						anchors.horizontalCenter: parent.horizontalCenter
						y: parent.height * (0.07 + index * 0.172)
						width: Arc.ruleThin
						height: 22

						Rectangle {
							width: Arc.ruleThin
							height: 9
							color: Qt.alpha(Arc.gilt, 0.34)
						}

						Rectangle {
							y: 13
							width: Arc.ruleThin
							height: 9
							color: Qt.alpha(Arc.gilt, 0.34)
						}
					}
				}
			}

			Item {
				id: launcherStage

				focus: true

				Keys.onEscapePressed: event => {
					event.accepted = true;
					root.closeLauncherPopup();
				}

				anchors.fill: parent
				anchors.margins: book.boardMargin + book.typeMargin
				opacity: Math.max(0, (launcherPopup.turned - 0.45) / 0.55)

				Loader {
					id: launcherSheetLoader
					anchors.fill: parent
					active: true
					sourceComponent: AppLauncherPopup {
						foreground: root.foreground
						background: root.background
						secondaryBoxColor: root.secondaryBoxColor
						secondaryBoxStrongColor: root.secondaryBoxStrongColor
						secondaryInsetColor: root.secondaryInsetColor
						barColor: root.accent
						danger: root.danger
						gutter: Arc.s6
						onCloseRequested: root.closeLauncherPopup()
						onOpenStudioRequested: page => {
							root.closeLauncherPopup();
							root.openStudio(page);
						}
					}
				}
			}

			// The boards. They are over everything until they have turned out
			// of the way, and they cost nothing once the book is open.
			Repeater {
				model: 2

				delegate: Item {
					id: board

					required property int index
					readonly property bool leftBoard: index === 0

					x: leftBoard ? 0 : book.width / 2
					width: book.width / 2
					height: book.height
					visible: launcherPopup.turned < 0.995 && launcherPopup.progress > 0.004
					z: 20

					transform: Matrix4x4 {
						readonly property real angle: (board.leftBoard ? -1 : 1) * 98 * launcherPopup.turned
						readonly property real pivotX: board.leftBoard ? board.width : 0
						readonly property real pivotY: board.height / 2

						matrix: {
							const d = 2200;
							const rad = angle * Math.PI / 180;
							const c = Math.cos(rad), s = Math.sin(rad);
							const toPivot = Qt.matrix4x4(1, 0, 0, pivotX, 0, 1, 0, pivotY, 0, 0, 1, 0, 0, 0, 0, 1);
							const persp = Qt.matrix4x4(1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, -1 / d, 1);
							const rotate = Qt.matrix4x4(c, 0, s, 0, 0, 1, 0, 0, -s, 0, c, 0, 0, 0, 0, 1);
							const fromPivot = Qt.matrix4x4(1, 0, 0, -pivotX, 0, 1, 0, -pivotY, 0, 0, 1, 0, 0, 0, 0, 1);
							return toPivot.times(persp).times(rotate).times(fromPivot);
						}
					}

					// The board: tooled leather over wood, and the only surface
					// in the style that is neither vellum nor brass.
					Rectangle {
						anchors.fill: parent
						color: Arc.mix(Arc.leaf3, Arc.tan, Arc.light ? 0.16 : 0.10)

						Rectangle {
							anchors.fill: parent
							anchors.margins: 7
							color: "transparent"
							border.width: Arc.rule
							border.color: Arc.gilt
						}

						Rectangle {
							anchors.fill: parent
							anchors.margins: 12
							color: "transparent"
							border.width: Arc.ruleThin
							border.color: Arc.giltDim
						}
					}

					// The grimoire's own mark, stamped on the front board, and
					// the raised bands across the spine on the back of it.
					ArcMark {
						anchors.centerIn: parent
						width: Math.min(parent.width, parent.height) * 0.4
						height: width
						glyph: "book"
						weight: Arc.ruleHeavy * 1.4
						lineColor: Arc.gilt
						visible: !board.leftBoard
						opacity: 1 - launcherPopup.turned
					}

					Column {
						anchors.right: parent.right
						anchors.verticalCenter: parent.verticalCenter
						spacing: 14
						visible: board.leftBoard
						opacity: 1 - launcherPopup.turned

						Repeater {
							model: 5
							delegate: Rectangle {
								width: 30
								height: Arc.ruleHeavy
								color: Arc.giltDim
							}
						}
					}
				}
			}
		}
	}

	PanelWindow {
		id: studioPopup
		screen: root.activePopupScreen

		anchors { left: true; right: true; top: true; bottom: true }
		exclusiveZone: 0
		color: "transparent"
		visible: root.studioPopupVisible
		WlrLayershell.exclusionMode: ExclusionMode.Ignore
		WlrLayershell.layer: WlrLayer.Overlay
		WlrLayershell.keyboardFocus: root.studioPopupVisible ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

		ModalSheet {
			open: root.studioPopupOpen
			scrimOpacity: 1.0
			sheetWidth: Math.min(1400, studioPopup.width - 80)
			sheetHeight: Math.min(1060, studioPopup.height - Arc.s7 * 2)
			onDismissRequested: root.closeStudio()

			Loader {
				anchors.fill: parent
				active: root.studioPopupVisible
				sourceComponent: Studio {
					page: root.studioPage
					foreground: root.foreground
					background: root.background
					secondaryBoxColor: root.secondaryBoxColor
					secondaryBoxStrongColor: root.secondaryBoxStrongColor
					secondaryInsetColor: root.secondaryInsetColor
					barColor: root.accent
					danger: root.danger
					onCloseRequested: root.closeStudio()
				}
			}
		}
	}

	PanelWindow {
		id: powerOverlay
		screen: root.activePopupScreen

		anchors {
			left: true
			right: true
			top: true
			bottom: true
		}

		exclusiveZone: 0
		color: "transparent"
		visible: root.powerPopupVisible
		WlrLayershell.exclusionMode: ExclusionMode.Ignore
		WlrLayershell.layer: WlrLayer.Overlay
		WlrLayershell.keyboardFocus: root.powerPopupVisible ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

		ModalSheet {
			open: root.powerPopupOpen
			scrimOpacity: 1.0
			sheetWidth: 620
			sheetHeight: 620
			onDismissRequested: root.closePowerPopup()

			// RETURN TO THE VOID.
			//
			// Ending a session is not a list of four buttons. A circle is laid
			// out with a station at each of the four quarters, the machine's
			// own name stands at its centre, and an index arm points at
			// whichever station is chosen. Moving the choice turns the arm —
			// the only thing on the screen that moves — and it arrests against
			// the station the way every brass thing in this shell does.
			Item {
				id: powerModal
				anchors.fill: parent
				focus: root.powerPopupVisible

				property string statUser: ""
				property string statKernel: ""
				property string statUptime: ""

				readonly property real radius: Math.min(width, height) * 0.36
				// The four quarters, clockwise from the top.
				readonly property var stations: [
					{ angle: -90, label: "Seal", sub: "Lock the session", action: "lock",
					  icon: "/usr/share/icons/Adwaita/symbolic/status/system-lock-screen-symbolic.svg", grave: false },
					{ angle: 0, label: "Depart", sub: "End the session", action: "logout",
					  icon: "/usr/share/icons/Adwaita/symbolic/actions/system-log-out-symbolic.svg", grave: false },
					{ angle: 90, label: "Rekindle", sub: "Restart the machine", action: "reboot",
					  icon: "/usr/share/icons/Adwaita/symbolic/actions/system-reboot-symbolic.svg", grave: true },
					{ angle: 180, label: "The Void", sub: "Power off", action: "shutdown",
					  icon: "/usr/share/icons/Adwaita/symbolic/actions/system-shutdown-symbolic.svg", grave: true }
				]

				function step(delta) {
					root.powerSelectionIndex = (root.powerSelectionIndex + delta + 4) % 4;
				}

				Keys.onEscapePressed: root.closePowerPopup()
				Keys.onUpPressed: powerModal.step(-1)
				Keys.onDownPressed: powerModal.step(1)
				Keys.onLeftPressed: powerModal.step(-1)
				Keys.onRightPressed: powerModal.step(1)
				Keys.onReturnPressed: root.runSelectedPowerAction()
				Keys.onEnterPressed: root.runSelectedPowerAction()

				Process {
					id: powerStatsProcess
					running: root.powerPopupVisible
					command: [
						"sh",
						"-lc",
						`printf '%s|%s|%s' "$USER@$(cat /etc/hostname 2>/dev/null || uname -n)" "$(uname -r)" "$(uptime -p | sed 's/^up //')"`
					]
					stdout: StdioCollector {
						onStreamFinished: {
							const parts = String(text || "").split("|");
							powerModal.statUser = parts[0] || "";
							powerModal.statKernel = parts[1] || "";
							powerModal.statUptime = parts[2] || "";
						}
					}
				}

				ArcHalo {
					anchors.centerIn: parent
					width: parent.width * 1.3
					height: parent.height * 1.3
					color: Arc.bane
					strength: 0.16
					spread: 0.4
					flicker: true
				}

				// The circle, cut once: the limb, its graduations, and the four
				// quarter marks the stations stand on.
				Canvas {
					id: circle
					anchors.fill: parent
					renderStrategy: Canvas.Cooperative

					Connections {
						target: Arc
						function onGiltChanged() { circle.requestPaint(); }
					}

					onPaint: {
						const ctx = getContext("2d");
						ctx.reset();
						const cx = width / 2, cy = height / 2, r = powerModal.radius;
						if (r < 20) return;
						const shadow = Qt.alpha(Qt.darker(Arc.gilt, 2.4), 0.55);
						const highlight = Qt.alpha(Qt.lighter(Arc.gilt, 1.8), 0.5);

						Ink.groove(ctx, Ink.arcPoints(cx, cy, r, 0, Math.PI * 2, 88),
							Arc.rule * 1.4, Arc.gilt, highlight, shadow, true);
						Ink.cut(ctx, Ink.arcPoints(cx, cy, r - 12, 0, Math.PI * 2, 88),
							Arc.ruleThin, Qt.alpha(Arc.gilt, 0.35), true);
						Ink.graduations(ctx, cx, cy, r - 1, -Math.PI / 2, Math.PI * 1.5,
							72, 4, 10, 18, Arc.ruleThin, Qt.alpha(Arc.gilt, 0.42));

						// The inner ring the name stands in.
						Ink.cut(ctx, Ink.arcPoints(cx, cy, r * 0.42, 0, Math.PI * 2, 60),
							Arc.ruleThin, Qt.alpha(Arc.gilt, 0.25), true);
					}
				}

				// The index arm: it turns to the station that is chosen, and
				// stops against it. This is the whole selection state.
				Item {
					id: arm
					anchors.centerIn: parent
					width: 2
					height: powerModal.radius * 2

					readonly property var station: powerModal.stations[Math.max(0, Math.min(3, root.powerSelectionIndex))]
					rotation: arm.station.angle + 90

					Behavior on rotation {
						RotationAnimation {
							direction: RotationAnimation.Shortest
							duration: Arc.turn + 90
							easing.type: Easing.Bezier
							easing.bezierCurve: Arc.curveDetent
						}
					}

					Rectangle {
						anchors.horizontalCenter: parent.horizontalCenter
						anchors.top: parent.top
						anchors.topMargin: 10
						width: Arc.ruleHeavy
						height: parent.height / 2 - powerModal.radius * 0.42 - 10
						color: arm.station.grave ? Arc.bane : Arc.aether
					}

					Rectangle {
						anchors.horizontalCenter: parent.horizontalCenter
						y: 4
						width: 7
						height: 7
						rotation: 45
						color: arm.station.grave ? Arc.bane : Arc.aether
					}
				}

				// Who is being ended, and how long it has been awake.
				Column {
					anchors.centerIn: parent
					spacing: Arc.s1

					ArcMark {
						anchors.horizontalCenter: parent.horizontalCenter
						width: 40
						height: 40
						glyph: "star"
						lineColor: Arc.giltDim
					}

					ArcText {
						anchors.horizontalCenter: parent.horizontalCenter
						role: "title"
						font.pixelSize: 16
						text: powerModal.statUser
					}

					ArcText {
						anchors.horizontalCenter: parent.horizontalCenter
						role: "hand"
						tone: "muted"
						font.pixelSize: 13
						text: powerModal.statUptime ? `awake ${powerModal.statUptime}` : ""
					}

					ArcText {
						anchors.horizontalCenter: parent.horizontalCenter
						role: "caption"
						tone: "faint"
						text: powerModal.statKernel
					}
				}

				// The four stations.
				Repeater {
					model: powerModal.stations

					delegate: Item {
						id: station

						required property var modelData
						required property int index
						readonly property bool chosen: root.powerSelectionIndex === station.index
						readonly property color toneColor: station.modelData.grave ? Arc.bane : Arc.aether
						readonly property real live: Math.max(stationTouch.live, station.chosen ? 0.9 : 0)
						readonly property real radians: station.modelData.angle * Math.PI / 180

						width: 96
						height: 96
						x: powerModal.width / 2 + Math.cos(station.radians) * powerModal.radius - width / 2
						y: powerModal.height / 2 + Math.sin(station.radians) * powerModal.radius - height / 2

						ArcHalo {
							anchors.centerIn: seatDial
							width: 120
							height: 120
							color: station.toneColor
							strength: 0.34
							spread: 0.34
							flicker: true
							opacity: station.live
							visible: opacity > 0.01

							Behavior on opacity {
								NumberAnimation {
									duration: Arc.turn
									easing.type: Easing.Bezier
									easing.bezierCurve: Arc.curveKindle
								}
							}
						}

						// The station plate, sunk into the limb of the circle so
						// the limb does not run through the mark.
						Rectangle {
							anchors.centerIn: seatDial
							width: 56
							height: 56
							radius: 28
							color: Arc.leaf1
						}

						ArcDial {
							id: seatDial
							anchors.horizontalCenter: parent.horizontalCenter
							anchors.verticalCenter: parent.verticalCenter
							width: 54
							height: 54
							seed: station.index
							weight: Arc.rule
							lineColor: station.modelData.grave ? Qt.alpha(Arc.bane, 0.5) : Arc.giltDim
							liveColor: station.toneColor
							intensity: station.live

							QQCImpl.IconImage {
								anchors.centerIn: parent
								width: 21
								height: 21
								source: station.modelData.icon
								sourceSize: Qt.size(width, height)
								color: station.live > 0.3 ? station.toneColor : Arc.ink

								Behavior on color {
									ColorAnimation { duration: Arc.tick }
								}
							}
						}

						// The name, written outside the circle so the limb stays
						// clean. Which side it sits on follows the quarter.
						Column {
							id: naming
							spacing: -2
							width: 190

							readonly property real outward: 46

							x: station.modelData.angle === 0 ? station.width + 8
								: station.modelData.angle === 180 ? -width - 8
								: (station.width - width) / 2
							y: station.modelData.angle === -90 ? -naming.height - 6
								: station.modelData.angle === 90 ? station.height + 6
								: (station.height - naming.height) / 2

							ArcText {
								width: parent.width
								horizontalAlignment: station.modelData.angle === 180 ? Text.AlignRight
									: station.modelData.angle === 0 ? Text.AlignLeft : Text.AlignHCenter
								role: "display"
								font.pixelSize: 24
								color: station.live > 0.3 ? station.toneColor : Arc.ink
								text: station.modelData.label

								Behavior on color {
									ColorAnimation { duration: Arc.tick }
								}
							}

							ArcText {
								width: parent.width
								horizontalAlignment: station.modelData.angle === 180 ? Text.AlignRight
									: station.modelData.angle === 0 ? Text.AlignLeft : Text.AlignHCenter
								role: "caption"
								tone: "faint"
								text: station.modelData.sub
							}
						}

						ArcTouch {
							id: stationTouch
							anchors.fill: undefined
							anchors.centerIn: seatDial
							width: 60
							height: 60
							onClicked: root.runPowerAction(station.modelData.action)
							onContainsMouseChanged: {
								if (containsMouse) root.powerSelectionIndex = station.index;
							}
						}
					}
				}
			}
		}
	}

	// A quantity, as what is in the glass. Used wherever the reading is a
	// proportion of something the machine holds — never a bar with a percentage
	// written beside it. The liquid overruns and rocks back when the reading
	// jumps, because that is what liquid does.
	component ArcMeasure: Item {
		id: measure

		required property real value
		required property string label
		property string detail: ""
		property color fillColor: Arc.aether
		property bool inverted: false

		readonly property bool strained: measure.inverted ? measure.value < 0.2 : measure.value > 0.88

		width: 78
		height: 176

		ArcHalo {
			anchors.centerIn: glass
			width: 110
			height: 220
			color: measure.strained ? Arc.bane : measure.fillColor
			strength: 0.18
			spread: 0.34
		}

		// The glass: a stoppered phial, cut once.
		Canvas {
			id: glass
			anchors.horizontalCenter: parent.horizontalCenter
			anchors.top: parent.top
			width: 40
			height: 118
			renderStrategy: Canvas.Cooperative

			Connections {
				target: Arc
				function onGiltChanged() { glass.requestPaint(); }
			}

			onPaint: {
				const ctx = getContext("2d");
				ctx.reset();
				const shadow = Qt.alpha(Qt.darker(Arc.gilt, 2.4), 0.5);
				const highlight = Qt.alpha(Qt.lighter(Arc.gilt, 1.8), 0.5);
				const neck = width * 0.30, shoulder = height * 0.16;

				const outline = [
					{ x: width / 2 - neck, y: 4 },
					{ x: width / 2 - neck, y: shoulder },
					{ x: 2, y: shoulder + 12 },
					{ x: 2, y: height - 6 },
					{ x: 8, y: height - 1 },
					{ x: width - 8, y: height - 1 },
					{ x: width - 2, y: height - 6 },
					{ x: width - 2, y: shoulder + 12 },
					{ x: width / 2 + neck, y: shoulder },
					{ x: width / 2 + neck, y: 4 }
				];

				Ink.polyline(ctx, outline, true);
				ctx.fillStyle = Arc.well;
				ctx.fill();
				Ink.groove(ctx, outline, Arc.rule * 1.2, Arc.gilt, highlight, shadow, false);
				// the stopper
				Ink.groove(ctx, [{ x: width / 2 - neck - 3, y: 3 }, { x: width / 2 + neck + 3, y: 3 }],
					Arc.ruleHeavy, Arc.gilt, highlight, shadow, false);
				// the graduations up the side
				for (let mark = 1; mark <= 4; mark++) {
					const y = height - 6 - (height - shoulder - 22) * mark / 5;
					Ink.cut(ctx, [{ x: 4, y: y }, { x: mark === 2 || mark === 4 ? 13 : 9, y: y }],
						Arc.ruleThin, Qt.alpha(Arc.gilt, 0.4), false);
				}
			}
		}

		ArcPhial {
			anchors.left: glass.left
			anchors.right: glass.right
			anchors.bottom: glass.bottom
			anchors.leftMargin: 3
			anchors.rightMargin: 3
			anchors.bottomMargin: 3
			height: glass.height * 0.74
			vertical: true
			value: measure.value
			trackColor: "transparent"
			fillColor: measure.strained ? Arc.bane : measure.fillColor
		}

		ArcText {
			anchors.horizontalCenter: glass.horizontalCenter
			anchors.bottom: glass.bottom
			anchors.bottomMargin: 18
			role: "reading"
			font.pixelSize: 17
			text: `${Math.round(measure.value * 100)}%`
		}

		Column {
			anchors.horizontalCenter: parent.horizontalCenter
			anchors.top: glass.bottom
			anchors.topMargin: Arc.s3
			spacing: -1

			ArcText {
				anchors.horizontalCenter: parent.horizontalCenter
				role: "label"
				color: measure.strained ? Arc.bane : Arc.ink
				text: measure.label
			}

			ArcText {
				anchors.horizontalCenter: parent.horizontalCenter
				role: "caption"
				tone: "faint"
				visible: measure.detail !== ""
				text: measure.detail
			}
		}
	}

	// A named reading with a vein under it: disks, batteries, anything that has
	// a proportion and a couple of numbers worth reading.
	component ResourceRow: Item {
		id: resourceRow

		required property string label
		required property string detail
		required property real usage
		property string icon: ""
		property string valueText: `${Math.round(resourceRow.usage * 100)}%`
		property string subValueText: ""

		readonly property bool strained: resourceRow.usage > 0.88

		width: parent ? parent.width : 276
		implicitHeight: 38

		ArcText {
			id: rowLabel
			anchors.left: parent.left
			anchors.top: parent.top
			role: "heading"
			font.pixelSize: 13
			text: resourceRow.label
		}

		ArcText {
			anchors.left: rowLabel.right
			anchors.leftMargin: Arc.s2
			anchors.baseline: rowLabel.baseline
			role: "caption"
			tone: "faint"
			text: resourceRow.detail
		}

		ArcText {
			anchors.right: parent.right
			anchors.baseline: rowLabel.baseline
			role: "caption"
			tone: resourceRow.strained ? "alert" : "muted"
			text: resourceRow.valueText
		}

		// A channel with something running along it, not a bar: the glass is
		// cut first and the liquid is put in it.
		ArcPlate {
			id: channel
			anchors.left: parent.left
			anchors.right: parent.right
			anchors.top: rowLabel.bottom
			anchors.topMargin: Arc.s2
			height: 10
			variant: "capsule"
			beading: false
			weight: Arc.ruleThin
			inset: 0
			lineColor: Arc.giltFaint
			liveColor: resourceRow.strained ? Arc.bane : Arc.aether
			fillTop: Arc.well
			fillBottom: Arc.well
			intensity: resourceRow.strained ? 0.8 : 0
		}

		ArcPhial {
			anchors.fill: channel
			anchors.margins: 2
			value: resourceRow.usage
			fillColor: resourceRow.strained ? Arc.bane : Arc.aether
			trackColor: "transparent"
		}

		ArcText {
			anchors.right: parent.right
			anchors.bottom: parent.bottom
			role: "caption"
			tone: "faint"
			visible: resourceRow.subValueText !== ""
			text: resourceRow.subValueText
		}
	}

	// One way out of the session. A tile is a chamber with a ring in it; the
	// dangerous two are outlined in necrosis so the hand knows before the eye
	// has read the word.
	PopupSurface {
		id: trayMenuPopup
		title: "Sigil"
		screen: root.activePopupScreen

		onDismissRequested: root.closeTrayMenu()
		open: root.trayMenuOpen
		visible: root.trayMenuVisible
		barItem: bar
		anchorItem: trayRow
		surfaceColor: root.surface
		borderColor: root.surfaceBorder
		expandedWidth: (trayMenuStackLoader.item ? trayMenuStackLoader.item.implicitWidth : 240) + 24
		contentPreferredHeight: trayMenuStackLoader.item ? trayMenuStackLoader.item.implicitHeight : 0

		Loader {
			id: trayMenuStackLoader
			anchors.fill: parent
			active: root.trayMenuVisible && root.trayMenuHandle !== null

			sourceComponent: StackView {
				id: trayMenuStack

				implicitWidth: currentItem ? currentItem.implicitWidth : 0
				implicitHeight: currentItem ? currentItem.implicitHeight : 0
				initialItem: traySubMenuComponent.createObject(null, {
					handle: root.trayMenuHandle,
					isSubMenu: false
				})

				pushEnter: Transition {
					NumberAnimation {
						duration: ThemeEngine.duration(0)
					}
				}
				pushExit: Transition {
					NumberAnimation {
						duration: ThemeEngine.duration(0)
					}
				}
				popEnter: Transition {
					NumberAnimation {
						duration: ThemeEngine.duration(0)
					}
				}
				popExit: Transition {
					NumberAnimation {
						duration: ThemeEngine.duration(0)
					}
				}
			}
		}
	}

	Component {
		id: traySubMenuComponent

		Item {
			id: trayMenuColumn
			required property QsMenuHandle handle
			property bool isSubMenu: false
			property bool shown: false

			implicitWidth: 240
			implicitHeight: menuEntries.implicitHeight + (backLoader.active ? backLoader.implicitHeight + 6 : 0)
			width: implicitWidth
			height: implicitHeight

			opacity: shown ? 1 : 0

			Component.onCompleted: shown = true
			StackView.onActivating: shown = true
			StackView.onDeactivating: shown = false
			StackView.onRemoved: destroy()

			Behavior on opacity {
				Anim {}
			}

			QsMenuOpener {
				id: trayMenuOpener
				menu: trayMenuColumn.handle
			}

			Column {
				id: menuEntries
				width: parent.width
				spacing: 4

				Repeater {
					model: trayMenuOpener.children

						// A menu entry is a row like every other row in this style,
						// and a separator is a thread of bone rather than a grey
						// bar.
						ArcEntry {
							id: menuEntry
							required property QsMenuEntry modelData

							width: trayMenuColumn.implicitWidth
							implicitHeight: menuEntry.modelData.isSeparator ? 1 : 30
							inset: Arc.s3
							interactive: !menuEntry.modelData.isSeparator && menuEntry.modelData.enabled

							// The row is the target. A second touch layer inside
							// it would sit over the row's own and take the hover
							// with it.
							onClicked: {
								if (menuEntry.modelData.hasChildren) {
									trayMenuStackLoader.item.push(traySubMenuComponent.createObject(null, {
										handle: menuEntry.modelData,
										isSubMenu: true
									}));
								} else {
									menuEntry.modelData.triggered();
									root.closeTrayMenu();
								}
							}

							Rectangle {
								anchors.fill: parent
								visible: menuEntry.modelData.isSeparator
								color: Arc.giltGhost
							}

						Row {
							visible: !menuEntry.modelData.isSeparator
							anchors.fill: parent
							spacing: Arc.s3

							Image {
								anchors.verticalCenter: parent.verticalCenter
								width: 15
								height: 15
								visible: menuEntry.modelData.icon !== ""
								source: menuEntry.modelData.icon
								fillMode: Image.PreserveAspectFit
							}

							ArcText {
								role: "body"
								anchors.verticalCenter: parent.verticalCenter
								width: parent.width - x - (menuEntry.modelData.hasChildren ? 18 : 0)
								text: menuEntry.modelData.text
								color: menuEntry.modelData.enabled ? Arc.ink : Arc.inkFaint
								font.pixelSize: 13
								elide: Text.ElideRight
							}

							ArcText {
								role: "heading"
								anchors.verticalCenter: parent.verticalCenter
								visible: menuEntry.modelData.hasChildren
								text: "›"
								color: menuEntry.modelData.enabled ? foreground : Qt.alpha(foreground, 0.45)
								font.pixelSize: 14
							}
						}
					}
				}
			}

			Loader {
				id: backLoader
				active: trayMenuColumn.isSubMenu
				y: menuEntries.implicitHeight + 6

				sourceComponent: ArcEntry {
					width: trayMenuColumn.implicitWidth
					implicitHeight: 30
					inset: Arc.s3
					onClicked: trayMenuStackLoader.item.pop()

					ArcText {
						anchors.centerIn: parent
						role: "label"
						tone: "muted"
						text: "Back"
					}
				}
			}
		}
	}

	PopupSurface {
		id: mediaPopup
		title: "Consort"
		screen: root.activePopupScreen

		onDismissRequested: root.closeMediaPopup()
		open: root.mediaPopupOpen
		visible: root.mediaPopupVisible
		barItem: bar
		anchorItem: nowPlayingIsland
		surfaceColor: root.surface
		borderColor: root.surfaceBorder
		expandedWidth: 520
		contentPreferredHeight: mediaPopupContent.implicitHeight

		onVisibleChanged: {
			if (!visible && root.mediaPopupVisible) {
				if (root.mediaPopupOpen) {
					root.closeMediaPopup();
				} else {
					root.mediaPopupVisible = false;
				}
			}
		}

		MediaPopupContent {
			id: mediaPopupContent
			anchors.fill: parent
			activePlayer: nowPlayingIsland.currentPlayer
			players: nowPlayingIsland.uniquePlayers
			foreground: root.foreground
			secondaryBoxColor: root.secondaryBoxColor
			secondaryInsetColor: root.secondaryInsetColor
			accent: root.accent
			primary: root.primary
			onPrimaryColor: root.onPrimary
			popupActive: root.mediaPopupVisible
			onSelectPlayer: player => nowPlayingIsland.setCurrentPlayer(player)
		}
	}

	PopupSurface {
		id: clockPopup
		title: "Ephemeris"
		screen: root.activePopupScreen

		onDismissRequested: root.closeClockPopup()
		open: root.clockPopupOpen
		visible: root.clockPopupVisible
		barItem: bar
		anchorItem: horologe
		surfaceColor: root.surface
		borderColor: root.surfaceBorder
		expandedWidth: 380
		contentPreferredHeight: calendarContent.implicitHeight

		onVisibleChanged: {
			if (!visible && root.clockPopupVisible) {
				if (root.clockPopupOpen) root.closeClockPopup();
				else root.clockPopupVisible = false;
			}
		}

		Column {
			id: calendarContent
			anchors.fill: parent
			spacing: Arc.s4

			// Today, stated once and large. The spine already carries the time,
			// so the chamber carries the date.
			Column {
				width: parent.width
				spacing: -2

				ArcText {
					anchors.horizontalCenter: parent.horizontalCenter
					role: "display"
					text: Qt.formatDateTime(root.now, "d MMMM")
				}

				ArcText {
					anchors.horizontalCenter: parent.horizontalCenter
					role: "label"
					tone: "aether"
					text: Qt.formatDateTime(root.now, "dddd")
				}
			}

			Item {
				width: parent.width
				height: 30

				ArcSeat {
					anchors.left: parent.left
					anchors.verticalCenter: parent.verticalCenter
					size: 26
					seed: 1
					onClicked: root.shiftCalendarMonths(-1)

					ArcText {
						anchors.centerIn: parent
						role: "heading"
						text: "‹"
					}
				}

				ArcText {
					anchors.centerIn: parent
					role: "title"
					font.pixelSize: 16
					text: Qt.formatDateTime(root.currentDate, "MMMM yyyy")
				}

				ArcSeat {
					anchors.right: parent.right
					anchors.verticalCenter: parent.verticalCenter
					size: 26
					seed: 3
					onClicked: root.shiftCalendarMonths(1)

					ArcText {
						anchors.centerIn: parent
						role: "heading"
						text: "›"
					}
				}
			}

			Grid {
				columns: 7
				columnSpacing: 2
				rowSpacing: 2
				anchors.horizontalCenter: parent.horizontalCenter

				Repeater {
					model: root.weekdayNames

					delegate: Item {
						required property string modelData
						width: 44
						height: 22

						ArcText {
							anchors.centerIn: parent
							role: "label"
							tone: "faint"
							text: modelData
						}
					}
				}

				// No cells. A calendar drawn as a grid of boxes is a spreadsheet;
				// here the days are just numbers on the membrane and only the
				// one you are on, or the one under the pointer, grows a ring.
				Repeater {
					model: 42

					delegate: Item {
						id: dayCell
						required property int index
						readonly property int day: root.calendarDayNumber(index)
						readonly property bool today: root.isToday(day)
						readonly property bool present: dayCell.day !== 0

						width: 44
						height: 32

						ArcHalo {
							anchors.centerIn: parent
							width: 44
							height: 44
							color: Arc.aether
							strength: 0.30
							spread: 0.30
							visible: dayCell.today
						}

						ArcDial {
							anchors.centerIn: parent
							width: 30
							height: 30
							seed: dayCell.index % 4
							visible: dayCell.present
							lineColor: "transparent"
							liveColor: Arc.aether
							intensity: dayCell.today ? 1 : dayTouch.live
						}

						ArcText {
							anchors.centerIn: parent
							role: dayCell.today ? "heading" : "body"
							tone: dayCell.today ? "aether" : "muted"
							font.pixelSize: 12
							visible: dayCell.present
							text: dayCell.present ? dayCell.day : ""
						}

						ArcTouch {
							id: dayTouch
							enabled: dayCell.present
							cursorShape: Qt.ArrowCursor
						}
					}
				}
			}
		}
	}

	PopupSurface {
		id: weatherPopup
		title: "Oracle"
		screen: root.activePopupScreen

		onDismissRequested: root.closeWeatherPopup()
		open: root.weatherPopupOpen
		visible: root.weatherPopupVisible
		barItem: bar
		anchorItem: weatherRun
		surfaceColor: root.surface
		borderColor: root.surfaceBorder
		expandedWidth: 330
		contentPreferredHeight: weatherContent.implicitHeight

		onVisibleChanged: {
			if (!visible && root.weatherPopupVisible) {
				if (root.weatherPopupOpen) root.closeWeatherPopup();
				else root.weatherPopupVisible = false;
			}
		}

		Column {
			id: weatherContent
			anchors.fill: parent
			spacing: Arc.s4

			// THE ORACLE.
			//
			// Not a weather widget. A basin of dark water with the sky's own
			// mark floating in it, the reading cut across it, and under that
			// the line the oracle gives you — one sentence, in the hand,
			// because a number is a fact and a sentence is an answer.
			Item {
				width: parent.width
				height: 128

				ArcHalo {
					anchors.centerIn: basin
					width: 200
					height: 200
					color: Arc.aether
					strength: 0.22
					spread: 0.36
					flicker: true
				}

				// The basin: a disc of still water, ruled with the horizon and
				// the meridian, the way a scrying bowl is marked.
				Canvas {
					id: basin
					anchors.left: parent.left
					anchors.verticalCenter: parent.verticalCenter
					width: 104
					height: 104
					renderStrategy: Canvas.Cooperative

					Connections {
						target: Arc
						function onGiltChanged() { basin.requestPaint(); }
					}

					onPaint: {
						const ctx = getContext("2d");
						ctx.reset();
						const cx = width / 2, cy = height / 2;
						const r = width / 2 - 2;
						const shadow = Qt.alpha(Qt.darker(Arc.gilt, 2.4), 0.55);
						const highlight = Qt.alpha(Qt.lighter(Arc.gilt, 1.8), 0.5);

						const water = ctx.createLinearGradient(0, 0, 0, height);
						water.addColorStop(0, Arc.leaf2);
						water.addColorStop(1, Arc.well);
						ctx.fillStyle = water;
						ctx.beginPath();
						ctx.arc(cx, cy, r, 0, Math.PI * 2);
						ctx.fill();

						Ink.groove(ctx, Ink.arcPoints(cx, cy, r, 0, Math.PI * 2, 56),
							Arc.rule * 1.3, Arc.gilt, highlight, shadow, true);
						Ink.cut(ctx, [{ x: cx - r * 0.86, y: cy }, { x: cx + r * 0.86, y: cy }],
							Arc.ruleThin, Qt.alpha(Arc.gilt, 0.26), false);
						Ink.cut(ctx, [{ x: cx, y: cy - r * 0.86 }, { x: cx, y: cy + r * 0.86 }],
							Arc.ruleThin, Qt.alpha(Arc.gilt, 0.18), false);
						Ink.graduations(ctx, cx, cy, r - 3, -Math.PI / 2, Math.PI * 1.5,
							32, 3, 6, 8, Arc.ruleThin, Qt.alpha(Arc.gilt, 0.35));
					}
				}

				// The sky's mark, floating on the water. It drifts, slowly,
				// which is the only idle motion in this panel.
				QQCImpl.IconImage {
					id: skyMark
					anchors.centerIn: basin
					width: 40
					height: 40
					source: root.resolveIconSource("", [
						root.weatherIcon,
						root.weatherIcon.replace("-symbolic", ""),
						"weather-overcast-symbolic"
					])
					sourceSize: Qt.size(width, height)
					color: Arc.aether

					SequentialAnimation on anchors.verticalCenterOffset {
						running: root.weatherPopupVisible
						loops: Animation.Infinite
						NumberAnimation { to: -3; duration: 3400; easing.type: Easing.InOutSine }
						NumberAnimation { to: 3; duration: 3400; easing.type: Easing.InOutSine }
					}
				}

				Column {
					anchors.left: basin.right
					anchors.leftMargin: Arc.s5
					anchors.right: parent.right
					anchors.verticalCenter: parent.verticalCenter
					spacing: -2

					ArcText {
						width: parent.width
						role: "display"
						font.pixelSize: 40
						text: root.weatherTemperature
					}

					ArcText {
						width: parent.width
						role: "label"
						tone: "muted"
						text: root.weatherDescription
					}

					ArcText {
						width: parent.width
						role: "label"
						tone: "faint"
						text: root.weatherLocation
					}
				}
			}

			// What the oracle actually says.
			ArcText {
				width: parent.width
				role: "hand"
				tone: "aether"
				font.pixelSize: 17
				wrapMode: Text.WordWrap
				text: root.oracleLine
			}

			ArcFlourish {
				width: parent.width
				height: 12
				facing: Qt.LeftToRight
				lineColor: Arc.giltFaint
			}

			// The readings, ruled in two columns the way a table in a book is.
			Grid {
				width: parent.width
				columns: 2
				columnSpacing: Arc.s5
				rowSpacing: Arc.s1

				Repeater {
					model: [
						{ label: "Feels like", value: root.weatherFeelsLike },
						{ label: "Humidity", value: root.weatherHumidity },
						{ label: "Wind", value: root.weatherWind },
						{ label: "Rain", value: root.weatherPrecipitation },
						{ label: "Pressure", value: root.weatherPressure },
						{ label: "Sampled", value: root.weatherObservationTime !== "" ? Qt.formatDateTime(new Date(root.weatherObservationTime), "HH:mm") : "--" }
					]

					delegate: Item {
						required property var modelData
						width: (weatherContent.width - Arc.s5) / 2
						height: 30

						ArcText {
							id: readingName
							anchors.left: parent.left
							anchors.verticalCenter: parent.verticalCenter
							role: "label"
							tone: "faint"
							text: modelData.label
						}

						// Leader dots: what carries the eye from a name to its
						// value in a printed table.
						Rectangle {
							anchors.left: readingName.right
							anchors.right: readingValue.left
							anchors.leftMargin: Arc.s2
							anchors.rightMargin: Arc.s2
							anchors.verticalCenter: parent.verticalCenter
							anchors.verticalCenterOffset: 3
							height: Arc.ruleThin
							color: Arc.giltGhost
							visible: width > 8
						}

						ArcText {
							id: readingValue
							anchors.right: parent.right
							anchors.verticalCenter: parent.verticalCenter
							role: "bodyStrong"
							text: modelData.value
						}
					}
				}
			}

			// The horizon: the run of the sun across it, and the moon's face
			// for the night at the end of it.
			Item {
				width: parent.width
				height: 44

				ArcText {
					id: sunriseLabel
					anchors.left: parent.left
					anchors.top: parent.top
					role: "reading"
					font.pixelSize: 15
					text: root.weatherSunrise
				}

				ArcText {
					id: sunsetLabel
					anchors.right: parent.right
					anchors.top: parent.top
					role: "reading"
					font.pixelSize: 15
					text: root.weatherSunset
				}

				// The sun's arc, with a mark where it stands now.
				Canvas {
					id: horizon
					anchors.left: sunriseLabel.right
					anchors.right: sunsetLabel.left
					anchors.leftMargin: Arc.s3
					anchors.rightMargin: Arc.s3
					anchors.top: parent.top
					height: 22
					renderStrategy: Canvas.Cooperative

					readonly property real through: {
						const rise = String(root.weatherSunrise || "");
						const set = String(root.weatherSunset || "");
						if (!/^\d{1,2}:\d{2}$/.test(rise) || !/^\d{1,2}:\d{2}$/.test(set)) return -1;
						const minutes = value => Number(value.split(":")[0]) * 60 + Number(value.split(":")[1]);
						const now = root.now.getHours() * 60 + root.now.getMinutes();
						const span = minutes(set) - minutes(rise);
						if (span <= 0) return -1;
						return Math.max(0, Math.min(1, (now - minutes(rise)) / span));
					}

					onThroughChanged: requestPaint()

					onPaint: {
						const ctx = getContext("2d");
						ctx.reset();
						if (width < 20) return;
						const path = [];
						for (let index = 0; index <= 24; index++) {
							const t = index / 24;
							path.push({ x: t * width, y: height - Math.sin(t * Math.PI) * (height - 4) });
						}
						Ink.cut(ctx, path, Arc.ruleThin, Qt.alpha(Arc.gilt, 0.42), false);
						Ink.cut(ctx, [{ x: 0, y: height }, { x: width, y: height }],
							Arc.ruleThin, Qt.alpha(Arc.gilt, 0.22), false);
						if (horizon.through < 0) return;
						const at = path[Math.round(horizon.through * 24)];
						ctx.fillStyle = Arc.aether;
						ctx.beginPath();
						ctx.ellipse(at.x - 3.5, at.y - 3.5, 7, 7);
						ctx.fill();
					}
				}

				ArcText {
					anchors.horizontalCenter: horizon.horizontalCenter
					anchors.top: horizon.bottom
					anchors.topMargin: 1
					role: "label"
					tone: "faint"
					font.pixelSize: 9
					text: Arc.moonPhase(root.now).name
				}
			}
		}
	}

	PopupSurface {
		id: notifPopup
		title: "Ravens"
		screen: root.activePopupScreen

		onDismissRequested: root.closeNotifPopup()
		open: root.notifPopupOpen
		visible: root.notifPopupVisible
		barItem: bar
		anchorItem: notifNode
		surfaceColor: root.surface
		borderColor: root.surfaceBorder
		expandedWidth: 420
		fixedHeight: 540

		onVisibleChanged: {
			if (!visible && root.notifPopupVisible) {
				if (root.notifPopupOpen) root.closeNotifPopup();
				else root.notifPopupVisible = false;
			}
		}

		ColumnLayout {
			anchors.fill: parent
			spacing: 12

			Item {
				Layout.fillWidth: true
				Layout.preferredHeight: 20

				ArcText {
					id: notifTitle
					anchors.left: parent.left
					anchors.verticalCenter: parent.verticalCenter
					role: "title"
					font.pixelSize: 16
					text: "Signals"
				}

				ArcFlourish {
					anchors.left: notifTitle.right
					anchors.right: purgeLabel.visible ? purgeLabel.left : parent.right
					anchors.leftMargin: Arc.s3
					anchors.rightMargin: Arc.s3
					anchors.verticalCenter: parent.verticalCenter
					height: 12
					facing: Qt.LeftToRight
					lineColor: Arc.giltFaint
					visible: width > 24
				}

				ArcText {
					id: purgeLabel
					anchors.right: parent.right
					anchors.verticalCenter: parent.verticalCenter
					visible: root.notificationGroups.length > 0
					role: "label"
					tone: purgeTouch.containsMouse ? "alert" : "muted"
					text: `Purge ${root.notificationGroups.length}`

					ArcTouch {
						id: purgeTouch
						anchors.margins: -Arc.s2
						onClicked: root.dismissAllNotificationGroups()
					}
				}
			}

			Item {
				Layout.fillWidth: true
				Layout.fillHeight: true
				visible: notificationList.count === 0

				Column {
					anchors.centerIn: parent
					spacing: Arc.s3

					// An empty page is a page. The bird that is not here is
					// drawn anyway, faintly, and told what it is waiting for.
					ArcMark {
						anchors.horizontalCenter: parent.horizontalCenter
						width: 54
						height: 54
						glyph: "raven"
						lineColor: Arc.giltGhost
					}

					ArcText {
						anchors.horizontalCenter: parent.horizontalCenter
						role: "label"
						tone: "faint"
						text: "No birds"
					}

					ArcText {
						anchors.horizontalCenter: parent.horizontalCenter
						role: "hand"
						tone: "faint"
						font.pixelSize: 14
						text: "Nothing has been sent for you"
					}
				}
			}

			ListView {
				id: notificationList
				Layout.fillWidth: true
				Layout.fillHeight: true
				visible: count > 0
				clip: true
				spacing: 10
				topMargin: ThemeEngine.shadowRenderMargin
				bottomMargin: ThemeEngine.shadowRenderMargin
				model: root.notificationGroups

						delegate: Item {
							id: notificationCard

							required property var modelData
							readonly property var latestEntry: modelData.latestSnapshot
							readonly property var liveNotification: modelData.latestNotification
							readonly property color urgencyColor: root.notificationUrgencyColor({
								urgency: latestEntry ? latestEntry.urgency : -1
							})
							readonly property string iconSource: latestEntry && latestEntry.image !== ""
								? latestEntry.image
								: root.resolveIconSource(latestEntry ? latestEntry.appIcon : "", [
									"dialog-information-symbolic",
									"dialog-information"
								])
							property bool dismissing: false

							width: notificationList.width
							height: cardBody.implicitHeight + Arc.s5 * 2
							// Dismissing pulls the record out sideways; nothing
							// in this style fades away where it stands.
							x: dismissing ? -width - 24 : 0
							opacity: dismissing ? 0 : 1

							Behavior on x {
								NumberAnimation { duration: Arc.recoil; easing.type: Easing.InCubic }
							}

							Behavior on opacity {
								NumberAnimation { duration: Arc.recoil }
							}

							Timer {
								id: notificationDismissTimer
								interval: 240
								repeat: false
								onTriggered: root.dismissNotificationGroup(notificationCard.modelData.key)
							}

							ArcLeaf {
								anchors.fill: parent
								variant: "plate"
								lineColor: Qt.alpha(notificationCard.urgencyColor, 0.45)
								liveColor: notificationCard.urgencyColor
								washTop: Qt.alpha(notificationCard.urgencyColor, 0.10)
								washBottom: Arc.leaf1
								haloStrength: 0.10
								padding: Arc.s5

								Column {
									id: cardBody
									anchors.fill: parent
									spacing: Arc.s3

									// Which organism sent this, and when.
									Item {
										width: parent.width
										height: 14

										Rectangle {
											id: urgencyBead
											anchors.left: parent.left
											anchors.verticalCenter: parent.verticalCenter
											width: Arc.stud * 2
											height: Arc.stud * 2
											radius: width / 2
											color: notificationCard.urgencyColor
										}

										ArcText {
											id: sourceLabel
											anchors.left: urgencyBead.right
											anchors.leftMargin: Arc.s2
											anchors.verticalCenter: parent.verticalCenter
											role: "label"
											color: notificationCard.urgencyColor
											text: notificationCard.modelData.appName || "System"
										}

										ArcText {
											id: stampLabel
											anchors.right: dismissTarget.left
											anchors.rightMargin: Arc.s2
											anchors.verticalCenter: parent.verticalCenter
											role: "caption"
											tone: "faint"
											text: notificationCard.latestEntry
												? `${root.formatNotificationTime(notificationCard.latestEntry.timestamp)}${notificationCard.latestEntry.active ? "" : " · closed"}`
												: ""
										}

										Item {
											id: dismissTarget
											anchors.right: parent.right
											anchors.verticalCenter: parent.verticalCenter
											width: 16
											height: 16

											ArcText {
												anchors.centerIn: parent
												role: "body"
												tone: dismissTouch.containsMouse ? "alert" : "faint"
												text: "×"
											}

											ArcTouch {
												id: dismissTouch
												onClicked: {
													if (notificationCard.dismissing) return;
													notificationCard.dismissing = true;
													notificationDismissTimer.start();
												}
											}
										}
									}

									// What it says, with whatever it came with.
									Row {
										width: parent.width
										spacing: Arc.s3

										Column {
											width: parent.width - (specimenImage.visible ? specimenImage.width + Arc.s3 : 0)
											spacing: Arc.s1

											ArcText {
												width: parent.width
												role: "heading"
												wrapMode: Text.WordWrap
												maximumLineCount: 2
												text: notificationCard.latestEntry
													? notificationCard.latestEntry.summary
													: (notificationCard.modelData.appName || "Notification")
											}

											ArcText {
												width: parent.width
												visible: notificationCard.latestEntry && notificationCard.latestEntry.body !== ""
												role: "body"
												tone: "muted"
												wrapMode: Text.WordWrap
												elide: Text.ElideNone
												text: notificationCard.latestEntry ? notificationCard.latestEntry.body : ""
											}
										}

										Item {
											id: specimenImage
											width: 50
											height: 50
											visible: notificationCard.iconSource !== ""

											ArcPlate {
												anchors.fill: parent
												variant: "plate"
												beading: false
												weight: Arc.ruleThin
												lineColor: Arc.giltFaint
												liveColor: notificationCard.urgencyColor
												fillTop: Arc.well
												fillBottom: Arc.well
											}

											Image {
												anchors.fill: parent
												anchors.margins: notificationCard.latestEntry && notificationCard.latestEntry.image !== "" ? 3 : 13
												source: notificationCard.iconSource
												fillMode: notificationCard.latestEntry && notificationCard.latestEntry.image !== ""
													? Image.PreserveAspectCrop
													: Image.PreserveAspectFit
												smooth: true
												mipmap: true
											}
										}
									}

									ArcPhial {
										width: parent.width
										visible: notificationCard.latestEntry
											&& notificationCard.latestEntry.progressValue >= 0
											&& notificationCard.latestEntry.progressValue <= 100
										height: 8
										fillColor: notificationCard.urgencyColor
										value: Math.max(0, Math.min(notificationCard.latestEntry ? notificationCard.latestEntry.progressValue : 0, 100)) / 100
									}

									Flow {
										width: parent.width
										visible: notificationCard.liveNotification && notificationCard.liveNotification.actions.length > 0
										spacing: Arc.s2

										Repeater {
											model: notificationCard.liveNotification ? notificationCard.liveNotification.actions : []

											delegate: ArcButton {
												required property var modelData

												implicitHeight: 28
												text: modelData.text
												onClicked: modelData.invoke()
											}
										}
									}

									Row {
										width: parent.width
										visible: notificationCard.liveNotification && notificationCard.liveNotification.hasInlineReply
										spacing: Arc.s3

										ArcQuill {
											id: inlineReply
											width: parent.width - sendButton.width - Arc.s3
											placeholder: notificationCard.liveNotification
												? (notificationCard.liveNotification.inlineReplyPlaceholder || "Reply")
												: "Reply"
											onAccepted: root.submitInlineReply(notificationCard.liveNotification, inlineReply.inputItem)
										}

										ArcButton {
											id: sendButton
											anchors.verticalCenter: parent.verticalCenter
											text: "Send"
											tone: "aether"
											onClicked: root.submitInlineReply(notificationCard.liveNotification, inlineReply.inputItem)
										}
									}

									// Older entries from the same source, folded away.
									Item {
										width: parent.width
										height: 20
										visible: notificationCard.modelData.notifications.length > 1

										ArcText {
											id: foldLabel
											anchors.left: parent.left
											anchors.verticalCenter: parent.verticalCenter
											role: "label"
											tone: foldTouch.containsMouse ? "aether" : "faint"
											text: notificationCard.modelData.expanded
												? `Fold ${notificationCard.modelData.notifications.length - 1} older`
												: `Unfold ${notificationCard.modelData.notifications.length - 1} older`
										}

										ArcFlourish {
											anchors.left: foldLabel.right
											anchors.right: parent.right
											anchors.leftMargin: Arc.s3
											anchors.verticalCenter: parent.verticalCenter
											height: 10
											facing: Qt.LeftToRight
											lineColor: foldTouch.containsMouse ? Qt.alpha(Arc.aether, 0.6) : Arc.giltGhost
											visible: width > 24
										}

										ArcTouch {
											id: foldTouch
											onClicked: root.setNotificationGroupExpanded(
												notificationCard.modelData.key, !notificationCard.modelData.expanded)
										}
									}

									Item {
										width: parent.width
										height: olderSection.height
										clip: true
										visible: notificationCard.modelData.notifications.length > 1

										Item {
											id: olderSection
											width: parent.width
											height: notificationCard.modelData.expanded ? olderColumn.implicitHeight : 0
											clip: true

											Behavior on height {
												NumberAnimation {
													duration: notificationCard.modelData.expanded ? Arc.draw : Arc.recoil
													easing.type: notificationCard.modelData.expanded ? Easing.OutBack : Easing.InCubic
													easing.overshoot: notificationCard.modelData.expanded ? 1.05 : 0
												}
											}

											Column {
												id: olderColumn
												width: parent.width
												spacing: Arc.s2

												Repeater {
													model: notificationCard.modelData.notifications.slice(1)

													delegate: Item {
														id: olderEntry

														required property var modelData

														width: olderColumn.width
														implicitHeight: olderText.implicitHeight + Arc.s3 * 2

														Rectangle {
															anchors.left: parent.left
															anchors.top: parent.top
															anchors.bottom: parent.bottom
															anchors.topMargin: Arc.s2
															anchors.bottomMargin: Arc.s2
															width: Arc.ruleThin
															color: Arc.giltGhost
														}

														Column {
															id: olderText
															anchors.left: parent.left
															anchors.right: parent.right
															anchors.leftMargin: Arc.s3
															anchors.verticalCenter: parent.verticalCenter
															spacing: 0

															ArcText {
																width: parent.width
																role: "bodyStrong"
																tone: "muted"
																text: olderEntry.modelData.summary
															}

															ArcText {
																width: parent.width
																visible: olderEntry.modelData.body !== ""
																role: "caption"
																tone: "faint"
																wrapMode: Text.WordWrap
																maximumLineCount: 2
																text: olderEntry.modelData.body
															}

															ArcText {
																role: "caption"
																tone: "faint"
																text: root.formatNotificationTime(olderEntry.modelData.timestamp)
															}
														}
													}
												}
											}
										}
									}
								}
							}
						}
			}
		}
	}

	// THE RAVEN.
	//
	// A notification does not fade up in the corner of the screen. A bird comes
	// in off the top of the screen, beating, settles on the chain under the
	// seat that took the message, and the note unrolls out of its claws — the
	// same let-down every panel in this shell uses, at a smaller size, because
	// the shell only knows one way of putting something in front of you.
	// Dismissing rolls the note back up and the bird goes the way it came.
	Instantiator {
		model: root.toasts

		delegate: PopupWindow {
			id: toastWindow
			required property int index
			required property var modelData

			readonly property int toastId: modelData.toastId
			readonly property int duration: modelData.duration
			readonly property var notification: modelData.notification
			readonly property color urgencyColor: root.notificationUrgencyColor(notification)
			readonly property real progressValue: notification.hints.value !== undefined
				? Number(notification.hints.value)
				: -1
			readonly property string iconSource: notification.image !== ""
				? notification.image
				: root.resolveIconSource(notification.appIcon, [
					"dialog-information-symbolic",
					"dialog-information"
				])
			property bool dismissing: false
			property real revealProgress: 0

			// Two movements, in order: the bird arrives, and only then does the
			// note come down. Never one fade for both.
			readonly property real flight: Math.max(0, Math.min(1, revealProgress / 0.40))
			readonly property real letDown: Math.max(0, Math.min(1, (revealProgress - 0.28) / 0.72))
			readonly property real perch: 34

			visible: true
			color: "transparent"

			// A message lands under the seat that took it, and the ones behind
			// it queue downwards from there — never in a corner of the screen
			// the chain has nothing to do with.
			anchor {
				window: barWindow
				edges: Edges.Right | Edges.Bottom
				gravity: Edges.Right | Edges.Bottom
				adjustment: PopupAdjustment.SlideX | PopupAdjustment.SlideY

				onAnchoring: {
					const mark = notifNode.mapToItem(null, notifNode.width / 2, 0);
					const centre = mark ? mark.x : barWindow.width - 220;
					anchor.rect.x = Math.round(centre - toastWindow.implicitWidth / 2);
					anchor.rect.width = 0;
					anchor.rect.y = Math.round(
						Arc.chainY(centre / Math.max(1, barWindow.width)) + Arc.seat / 2)
						+ index * (toastWindow.implicitHeight + 10);
					anchor.rect.height = 0;
				}
			}

			implicitWidth: 380
			implicitHeight: toastWindow.perch + toastCard.implicitHeight + 6

			NumberAnimation on revealProgress {
				from: 0
				to: 1
				duration: Arc.unroll + Arc.turn
				easing.type: Easing.Bezier
				easing.bezierCurve: Arc.curveUnroll
			}

			// The bird. It comes in from off the top right, beating, and stops
			// dead when it has something to stand on.
			Item {
				id: raven

				property real beat: 0

				width: 30
				height: 26
				x: toastWindow.implicitWidth - 62 + (1 - toastWindow.flight) * 150
				y: 2 - (1 - toastWindow.flight) * 64
				opacity: toastWindow.dismissing ? 0 : Math.min(1, toastWindow.flight * 3)
				rotation: (1 - toastWindow.flight) * -22

				Behavior on opacity {
					NumberAnimation { duration: Arc.recoil }
				}

				SequentialAnimation on beat {
					running: toastWindow.flight < 1 && !toastWindow.dismissing
					loops: Animation.Infinite
					NumberAnimation { to: 1; duration: 90; easing.type: Easing.OutQuad }
					NumberAnimation { to: 0; duration: 130; easing.type: Easing.InQuad }
				}

				// Wing-beats are a vertical squash on a silhouette. Nothing
				// more elaborate survives being 26 pixels tall anyway.
				transform: Scale {
					origin.x: raven.width / 2
					origin.y: raven.height
					yScale: toastWindow.flight < 1 ? 0.55 + raven.beat * 0.7 : 1
				}

				ArcHalo {
					anchors.centerIn: parent
					width: 80
					height: 80
					color: toastWindow.urgencyColor
					strength: 0.28
					spread: 0.34
					flicker: true
				}

				ArcMark {
					anchors.fill: parent
					glyph: "raven"
					lineColor: toastWindow.urgencyColor
				}
			}

			// The cord the note hangs on out of the bird's claws.
			Rectangle {
				x: toastWindow.implicitWidth - 48
				y: 24
				width: Arc.ruleThin
				height: (toastWindow.perch - 24) * Math.min(1, toastWindow.letDown * 4)
				color: Qt.alpha(toastWindow.urgencyColor, 0.6)
				visible: !toastWindow.dismissing
			}

			// The roller the note is wound on.
			Rectangle {
				x: 0
				y: toastWindow.perch - 3
				width: toastWindow.implicitWidth * Math.min(1, toastWindow.letDown * 4)
				height: 3
				color: Arc.gilt
				opacity: toastWindow.dismissing ? 0 : 1

				Behavior on opacity {
					NumberAnimation { duration: Arc.recoil }
				}
			}

			// The note itself, revealed from the top as the dowel travels. It
			// is never scaled and it never fades in.
			Item {
				id: noteWindow

				x: 0
				y: toastWindow.perch
				width: toastWindow.implicitWidth
				height: toastCard.implicitHeight * (toastWindow.dismissing ? 0 : toastWindow.letDown)
				clip: true

				Behavior on height {
					NumberAnimation {
						duration: Arc.reroll
						easing.type: Easing.Bezier
						easing.bezierCurve: Arc.curveReroll
					}
				}

				Rectangle {
					anchors.left: parent.left
					anchors.right: parent.right
					anchors.bottom: parent.bottom
					height: 12
					z: 5
					visible: toastWindow.letDown < 0.99 && toastWindow.letDown > 0.02

					gradient: Gradient {
						GradientStop { position: 0.0; color: "transparent" }
						GradientStop { position: 0.6; color: Qt.alpha(Arc.well, 0.7) }
						GradientStop { position: 1.0; color: Qt.alpha(Arc.gilt, 0.2) }
					}
				}

			ArcLeaf {
				id: toastCard

				implicitWidth: toastWindow.implicitWidth
				implicitHeight: toastContent.implicitHeight + Arc.s5 * 2
				width: implicitWidth
				height: implicitHeight
				x: 0
				y: 0
				variant: "plate"
				lineColor: Qt.alpha(toastWindow.urgencyColor, 0.55)
				liveColor: toastWindow.urgencyColor
				washTop: Qt.alpha(toastWindow.urgencyColor, 0.12)
				washBottom: Arc.washDeep
				haloStrength: 0.22
				intensity: 0.55
				padding: Arc.s5

				Timer {
					id: toastDismissTimer
					interval: 240
					repeat: false
					onTriggered: toastWindow.notification.dismiss()
				}
				Column {
					id: toastContent
					anchors.fill: parent
					spacing: Arc.s3

					Item {
						width: parent.width
						height: 14

						Rectangle {
							id: toastBead
							anchors.left: parent.left
							anchors.verticalCenter: parent.verticalCenter
							width: Arc.stud * 2
							height: Arc.stud * 2
							radius: width / 2
							color: toastWindow.urgencyColor
						}

						ArcText {
							anchors.left: toastBead.right
							anchors.leftMargin: Arc.s2
							anchors.verticalCenter: parent.verticalCenter
							role: "label"
							color: toastWindow.urgencyColor
							text: toastWindow.notification.appName || "System"
						}

						Item {
							id: toastDismiss
							anchors.right: parent.right
							anchors.verticalCenter: parent.verticalCenter
							width: 16
							height: 16

							ArcText {
								anchors.centerIn: parent
								role: "body"
								tone: toastDismissTouch.containsMouse ? "alert" : "faint"
								text: "×"
							}

							ArcTouch {
								id: toastDismissTouch
								onClicked: {
									if (toastWindow.dismissing) return;
									toastWindow.dismissing = true;
									toastDismissTimer.start();
								}
							}
						}
					}

					Row {
						width: parent.width
						spacing: Arc.s3

						Column {
							width: parent.width - (toastImage.visible ? toastImage.width + Arc.s3 : 0)
							spacing: Arc.s1

							ArcText {
								width: parent.width
								role: "heading"
								wrapMode: Text.WordWrap
								maximumLineCount: 2
								text: toastWindow.notification.summary || (toastWindow.notification.appName || "Notification")
							}

							ArcText {
								width: parent.width
								visible: toastWindow.notification.body !== ""
								role: "body"
								tone: "muted"
								wrapMode: Text.WordWrap
								elide: Text.ElideRight
								maximumLineCount: 4
								text: toastWindow.notification.body
							}
						}

						Item {
							id: toastImage
							width: 50
							height: 50
							visible: toastWindow.iconSource !== ""

							ArcPlate {
								anchors.fill: parent
								variant: "plate"
								beading: false
								weight: Arc.ruleThin
								lineColor: Arc.giltFaint
								liveColor: toastWindow.urgencyColor
								fillTop: Arc.well
								fillBottom: Arc.well
							}

							Image {
								anchors.fill: parent
								anchors.margins: toastWindow.notification.image !== "" ? 3 : 13
								source: toastWindow.iconSource
								fillMode: toastWindow.notification.image !== ""
									? Image.PreserveAspectCrop
									: Image.PreserveAspectFit
								smooth: true
								mipmap: true
							}
						}
					}

					ArcPhial {
						width: parent.width
						visible: toastWindow.progressValue >= 0 && toastWindow.progressValue <= 100
						height: 8
						fillColor: toastWindow.urgencyColor
						value: Math.max(0, Math.min(toastWindow.progressValue, 100)) / 100
					}

					Flow {
						width: parent.width
						visible: toastWindow.notification && toastWindow.notification.actions.length > 0
						spacing: Arc.s2

						Repeater {
							model: toastWindow.notification ? toastWindow.notification.actions : []

							delegate: ArcButton {
								required property var modelData

								implicitHeight: 28
								text: modelData.text
								onClicked: modelData.invoke()
							}
						}
					}

					Row {
						width: parent.width
						visible: toastWindow.notification && toastWindow.notification.hasInlineReply
						spacing: Arc.s3

						ArcQuill {
							id: toastInlineReply
							width: parent.width - toastSend.width - Arc.s3
							placeholder: toastWindow.notification
								? (toastWindow.notification.inlineReplyPlaceholder || "Reply")
								: "Reply"
							onAccepted: root.submitInlineReply(toastWindow.notification, toastInlineReply.inputItem)
						}

						ArcButton {
							id: toastSend
							anchors.verticalCenter: parent.verticalCenter
							text: "Send"
							tone: "aether"
							onClicked: root.submitInlineReply(toastWindow.notification, toastInlineReply.inputItem)
						}
					}
				}
			}

				Timer {
					running: true
					repeat: false
					interval: duration
					onTriggered: root.removeToast(toastId)
				}
			}
			}
		}

}
