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
	readonly property color secondaryBoxColor: Arc.veil2
	readonly property color secondaryBoxStrongColor: Arc.veil3
	readonly property color secondaryInsetColor: Arc.depth
	readonly property color surface: Arc.veil1
	readonly property color surfaceBorder: Arc.goldDim
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

	readonly property color background: Arc.abyss
	readonly property color foreground: Arc.ink
	readonly property color primary: Arc.aether
	readonly property color secondary: Arc.aetherAlt
	readonly property color accent: Arc.aetherAlt
	readonly property color tertiary: Arc.aetherThird
	readonly property color border: Arc.goldFaint

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

	// The machine's readings. It draws nothing: the arcane core on the horizon
	// and the humours panel both take their numbers from here, so the readings
	// are gathered once for the whole shell.
	TopBarResourceBars {
		id: resourceBars
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
	// Turning the volume or the brightness does not put a bar on the screen. A
	// crystal is called up out of the floor of the sanctum, a little above the
	// horizon and dead centre, and what you are turning is the light standing
	// inside it. Every change strikes the stone: it rings, and the ring is
	// integrated and damps out, so a long turn rings harder than a nudge.
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
				duration: root.osdVisible ? Arc.conjure : Arc.dispel
				easing.type: Easing.Bezier
				easing.bezierCurve: root.osdVisible ? Arc.curveRise : Arc.curveSink
			}
		}

		readonly property real inscribed: Math.max(0, Math.min(1, shown / 0.34))
		readonly property real condensed: Math.max(0, Math.min(1, (shown - 0.24) / 0.5))

		property real ring: 0
		property real ringVelocity: 0

		Connections {
			target: root
			function onOsdProgressChanged() {
				osdWindow.ringVelocity += 0.36;
				ringClock.running = true;
				if (osdWindow.visible) osdMotes.burst(osdMotes.width / 2, osdMotes.height / 2, 10);
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

		Item {
			id: rig

			width: 220
			height: 250
			x: Math.round((parent.width - width) / 2)
			y: Math.round(parent.height - Arc.horizon - Arc.s7 - height)

			// The ring it stands in.
			Canvas {
				id: floorRing
				anchors.horizontalCenter: parent.horizontalCenter
				y: parent.height - 30
				width: 200
				height: 46
				renderStrategy: Canvas.Cooperative

				readonly property real through: osdWindow.inscribed

				onThroughChanged: requestPaint()

				onPaint: {
					const ctx = getContext("2d");
					ctx.reset();
					if (floorRing.through <= 0.002) return;
					ctx.save();
					ctx.translate(width / 2, height / 2);
					ctx.scale(1, height / width);
					Ink.ring(ctx, 0, 0, width / 2 - 3, 2.2, Arc.aether, floorRing.through);
					Ink.runeRing(ctx, 0, 0, width / 2 - 20, 7, 61, 15, Arc.ruleThin,
						Qt.alpha(Arc.gold, 0.2), Arc.aether, Math.round(7 * floorRing.through));
					ctx.restore();
				}
			}

			ArcHalo {
				anchors.centerIn: crystal
				width: 300
				height: 340
				color: Arc.aether
				strength: (0.20 + Math.abs(osdWindow.ring) * 0.4) * osdWindow.shown
				spread: 0.38
				flicker: true
			}

			ArcMotes {
				id: osdMotes
				anchors.fill: parent
				color: Arc.aether
				span: 3.2
				visible: osdWindow.shown > 0.05
			}

			Item {
				id: crystal

				readonly property real level: Math.max(0, Math.min(1, root.osdProgress))

				width: 128
				height: 196
				x: Math.round((parent.width - width) / 2)
				y: Math.round((parent.height - 30 - height) * 0.5)
				opacity: Math.min(1, osdWindow.condensed * 1.5)
				scale: (0.86 + 0.14 * osdWindow.condensed) * (1 + osdWindow.ring * 0.05)

				Canvas {
					id: stone
					anchors.fill: parent
					renderStrategy: Canvas.Cooperative

					readonly property real level: crystal.level
					readonly property real struck: osdWindow.ring

					onLevelChanged: requestPaint()
					onStruckChanged: requestPaint()

					function facets(w, h) {
						const cx = w / 2;
						return [
							{ x: cx, y: h * 0.02 },
							{ x: w * 0.90, y: h * 0.26 },
							{ x: w * 0.90, y: h * 0.70 },
							{ x: cx, y: h * 0.98 },
							{ x: w * 0.10, y: h * 0.70 },
							{ x: w * 0.10, y: h * 0.26 }
						];
					}

					onPaint: {
						const ctx = getContext("2d");
						ctx.reset();
						if (width < 8) return;
						const outline = stone.facets(width, height);

						Ink.polyline(ctx, outline, true);
						const body = ctx.createLinearGradient(0, 0, 0, height);
						body.addColorStop(0, Qt.alpha(Arc.abyss, 0.75));
						body.addColorStop(1, Qt.alpha(Arc.depth, 0.85));
						ctx.fillStyle = body;
						ctx.fill();

						const top = height * (0.98 - 0.96 * stone.level);
						ctx.save();
						Ink.polyline(ctx, outline, true);
						ctx.clip();
						const lit = ctx.createLinearGradient(0, top, 0, height);
						lit.addColorStop(0, Qt.alpha(Arc.aether, 0.9));
						lit.addColorStop(1, Qt.alpha(Arc.aether, 0.28));
						ctx.fillStyle = lit;
						const tip = height * 0.035 * stone.struck;
						ctx.beginPath();
						ctx.moveTo(0, top + tip);
						ctx.quadraticCurveTo(width / 2, top - tip * 2.2, width, top + tip);
						ctx.lineTo(width, height);
						ctx.lineTo(0, height);
						ctx.closePath();
						ctx.fill();
						ctx.restore();

						// the cut: the girdle and the two long edges, nothing else
						Ink.cut(ctx, outline, 1.6, Qt.alpha(Arc.gold, 0.75), true);
						Ink.cut(ctx, [{ x: width * 0.10, y: height * 0.26 }, { x: width * 0.90, y: height * 0.26 }],
							Arc.ruleThin, Qt.alpha(Arc.gold, 0.4), false);
						Ink.cut(ctx, [{ x: width * 0.10, y: height * 0.70 }, { x: width * 0.90, y: height * 0.70 }],
							Arc.ruleThin, Qt.alpha(Arc.gold, 0.4), false);
						Ink.cut(ctx, [{ x: width / 2, y: height * 0.02 }, { x: width / 2, y: height * 0.98 }],
							Arc.ruleThin, Qt.alpha(Arc.gold, 0.22), false);
					}
				}

				Column {
					anchors.horizontalCenter: parent.horizontalCenter
					y: parent.height * 0.33
					spacing: -4

					ArcText {
						anchors.horizontalCenter: parent.horizontalCenter
						role: "display"
						font.pixelSize: 26
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

				Image {
					anchors.horizontalCenter: parent.horizontalCenter
					y: parent.height * 0.76
					width: 18
					height: 18
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
	}

	// THE HORIZON.
	//
	// There is no bar. The shell reserves a band at the foot of the screen and
	// puts one permanent object in it: the chronomancer, a great rune circle
	// half sunk below the edge like a moon that has not finished rising. The
	// hour stands inside its cap; the runes around its limb are cut from the
	// name the hour goes by, so they change as the night turns, and on the hour
	// a wave of light runs once round the whole circle.
	//
	// Everything else in the band is placed *around* that object with air
	// between — the realms to the west of it, the arcane core to the east, and
	// the rest of the shell's marks scattered on a rising line past that.
	// Nothing is in a row, nothing is in a box, and nothing has a container
	// drawn round it. The band itself is not a plate: it is the void getting
	// deeper towards the bottom of the screen.
	//
	// Panels are not attached to this window. They are called up out of it:
	// see components/PopupSurface.qml, which inscribes its ring on this floor.
	PanelWindow {
		id: barWindow
		screen: root.primaryBarScreen

		anchors {
			left: true
			right: true
			bottom: true
		}

		margins {
			left: 0
			right: 0
			bottom: 0
		}

		exclusiveZone: Math.round(Arc.horizon)
		implicitHeight: Math.round(Arc.horizon)
		color: "transparent"

		Item {
			id: bar
			anchors.fill: parent

			readonly property real chronoCentreY: bar.height + Arc.chronoSunk
			readonly property real chronoTop: bar.chronoCentreY - Arc.chronoRadius

			// The void deepening towards the foot of the screen. Not a plate,
			// not a line: the only thing that keeps fine light legible over a
			// pale wallpaper is more depth under it.
			Rectangle {
				anchors.fill: parent
				gradient: Gradient {
					GradientStop { position: 0.0; color: "transparent" }
					GradientStop { position: 0.35; color: Qt.alpha(Arc.abyss, Arc.light ? 0.40 : 0.62) }
					GradientStop { position: 1.0; color: Qt.alpha(Arc.abyss, Arc.light ? 0.80 : 0.96) }
				}
			}

			// ------------------------------------------------ the chronomancer
			//
			// The great circle, nearly all of it under the edge of the screen.
			// Every ring on it runs only across the part of itself that is
			// above the horizon, so they all finish on the same line and the
			// whole thing reads as something rising. The runes crown the
			// outside and are cut from the name this hour goes by; the seconds
			// travel the limb under them, the minutes the one under that, and
			// the hour stands in the space they leave.
			Item {
				id: chrono

				readonly property real reach: Arc.chronoRadius + 14

				width: chrono.reach * 2
				height: chrono.reach * 2
				x: Math.round((bar.width - width) / 2)
				y: Math.round(bar.chronoCentreY - chrono.reach)

				readonly property real seconds: root.now.getSeconds() + root.now.getMilliseconds() / 1000
				readonly property int hour: root.now.getHours()

				property real hourWave: 0

				onHourChanged: hourWaveAnim.restart()

				NumberAnimation {
					id: hourWaveAnim
					target: chrono
					property: "hourWave"
					from: 0
					to: 1
					duration: 2200
					easing.type: Easing.Bezier
					easing.bezierCurve: Arc.curveInk
				}

				ArcHalo {
					anchors.horizontalCenter: parent.horizontalCenter
					y: chrono.reach - Arc.chronoRadius - 20
					width: 300
					height: 170
					color: Arc.aether
					strength: 0.18
					spread: 0.34
					flicker: true
				}

				// The fixed part: the crown of runes and the graduated limb.
				// Repainted once an hour, not once a second.
				Canvas {
					id: limb
					anchors.fill: parent
					renderStrategy: Canvas.Cooperative

					readonly property int hour: chrono.hour

					onHourChanged: requestPaint()

					Connections {
						target: Arc
						function onGoldChanged() { limb.requestPaint(); }
					}

					onPaint: {
						const ctx = getContext("2d");
						ctx.reset();
						const cx = width / 2, cy = height / 2, r = Arc.chronoRadius;

						Ink.runeArc(ctx, cx, cy, r + 6,
							Arc.chronoFromAt(r + 6), Arc.chronoToAt(r + 6),
							9, 101 + limb.hour * 17, 12, Arc.ruleThin,
							Qt.alpha(Arc.gold, 0.32), Arc.aether, 0);
						Ink.gradsArc(ctx, cx, cy, r + 1,
							Arc.chronoFromAt(r + 1), Arc.chronoToAt(r + 1),
							30, 3, 7, 5, Arc.ruleThin, Qt.alpha(Arc.gold, 0.30));
						Ink.arcRun(ctx, cx, cy, r - 1,
							Arc.chronoFromAt(r - 1), Arc.chronoToAt(r - 1),
							1.2, Qt.alpha(Arc.gold, 0.30), 1);
						Ink.arcRun(ctx, cx, cy, r - 10,
							Arc.chronoFromAt(r - 10), Arc.chronoToAt(r - 10),
							1.0, Qt.alpha(Arc.gold, 0.16), 1);
					}
				}

				// The readings, each travelling its own limb west to east.
				Canvas {
					id: hands
					anchors.fill: parent
					renderStrategy: Canvas.Cooperative

					readonly property real seconds: chrono.seconds
					readonly property real minutes: root.now.getMinutes() + chrono.seconds / 60
					readonly property real wave: chrono.hourWave

					onSecondsChanged: requestPaint()
					onWaveChanged: requestPaint()

					onPaint: {
						const ctx = getContext("2d");
						ctx.reset();
						const cx = width / 2, cy = height / 2, r = Arc.chronoRadius;
						const s = hands.seconds / 60;

						const secondsR = r - 1;
						const sFrom = Arc.chronoFromAt(secondsR), sTo = Arc.chronoToAt(secondsR);
						Ink.arcRun(ctx, cx, cy, secondsR, sFrom, sTo, 1.8, Qt.alpha(Arc.aether, 0.85), s);
						const tip = sFrom + (sTo - sFrom) * s;
						Ink.mote(ctx, cx + Math.cos(tip) * secondsR, cy + Math.sin(tip) * secondsR, 3.0, Arc.aether);

						const minutesR = r - 10;
						Ink.arcRun(ctx, cx, cy, minutesR,
							Arc.chronoFromAt(minutesR), Arc.chronoToAt(minutesR),
							2.0, Qt.alpha(Arc.aetherAlt, 0.7), hands.minutes / 60);

						Ink.runeArc(ctx, cx, cy, r + 6,
							Arc.chronoFromAt(r + 6), Arc.chronoToAt(r + 6),
							9, 101 + root.now.getHours() * 17, 12, Arc.ruleThin * 1.3,
							Qt.alpha(Arc.gold, 0), Arc.aether,
							Math.floor(hands.minutes / 60 * 9) + 1);

						// the light that runs the limb when the hour turns
						if (hands.wave > 0.001 && hands.wave < 0.999) {
							ctx.save();
							ctx.globalAlpha = Math.sin(hands.wave * Math.PI);
							const waveR = r + 4;
							const from = Arc.chronoFromAt(waveR)
								+ (Arc.chronoToAt(waveR) - Arc.chronoFromAt(waveR)) * hands.wave;
							Ink.arcRun(ctx, cx, cy, waveR, from,
								from + (Arc.chronoToAt(waveR) - Arc.chronoFromAt(waveR)) * 0.12,
								4, Arc.aether, 1);
							ctx.restore();
						}
					}
				}

				// The hour, on one line in the space the limbs leave. The date
				// is not out here: the ephemeris has it, and out here it would
				// only be costing height.
				Row {
					id: reading
					anchors.horizontalCenter: parent.horizontalCenter
					y: Math.round(chrono.reach - Arc.chronoRadius + Arc.chronoSunk - 24)
					spacing: Arc.s2

					Canvas {
						id: moon
						anchors.verticalCenter: parent.verticalCenter
						width: 13
						height: 13
						renderStrategy: Canvas.Cooperative

						readonly property real phase: Arc.moonPhase(root.now).fraction

						onPhaseChanged: requestPaint()

						onPaint: {
							const ctx = getContext("2d");
							ctx.reset();
							const r = width / 2 - 1;
							ctx.strokeStyle = Arc.goldDim;
							ctx.lineWidth = Arc.ruleThin;
							ctx.beginPath();
							ctx.arc(width / 2, height / 2, r, 0, Math.PI * 2);
							ctx.stroke();
							const waxing = moon.phase < 0.5;
							const sweep = Math.cos(moon.phase * Math.PI * 2);
							ctx.fillStyle = Arc.gold;
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

					ArcText {
						anchors.verticalCenter: parent.verticalCenter
						role: "display"
						font.pixelSize: 25
						font.letterSpacing: 1.5
						text: Qt.formatDateTime(root.now, "HH:mm")
					}

					ArcText {
						anchors.verticalCenter: parent.verticalCenter
						role: "hand"
						tone: "aether"
						font.pixelSize: 14
						text: Arc.hourName(root.now)
					}
				}

				ArcTouch {
					id: chronoTouch
					anchors.fill: undefined
					anchors.horizontalCenter: parent.horizontalCenter
					y: chrono.reach - Arc.chronoRadius
					width: 280
					height: Arc.horizon - (chrono.reach - Arc.chronoRadius)
					onClicked: root.toggleClockPopup()
				}
			}

			// Fireflies above the circle. The only thing on the screen that
			// moves while nothing is happening, and deliberately too slow and
			// too faint to pull the eye off work.
			ArcMotes {
				anchors.horizontalCenter: parent.horizontalCenter
				anchors.bottom: parent.bottom
				width: Arc.chronoRadius * 2.0
				height: Arc.horizon
				color: Arc.aether
				drifting: true
				density: 4
				drift: -6
				span: 2.6
			}

			Timer {
				running: true
				repeat: true
				interval: 1000
				onTriggered: root.now = new Date()
			}

			// -------------------------------------------------- the west side
			// What opens the codex, and the realms.
			ArcSeat {
				id: launcherNode
				x: Arc.s5
				y: Math.round(Arc.horizon * 0.40)
				size: 30
				seed: 0
				label: "Codex"
				lit: root.launcherPopupOpen
				onClicked: root.toggleLauncherPopup()

				ArcMark {
					anchors.centerIn: parent
					width: parent.width * 0.68
					height: parent.height * 0.68
					glyph: "book"
					weight: Arc.rule
					lineColor: launcherNode.live > 0.25 ? Arc.aether : Arc.ink
				}
			}

			RealmMap {
				id: realms
				anchors.left: launcherNode.right
				anchors.leftMargin: Arc.s4
				anchors.bottom: parent.bottom
				width: Math.max(0, bar.width / 2 - Arc.chronoRadius * 1.02 - x - Arc.s4)
				height: Arc.horizon
				niriState: niriState
				outputName: String(barWindow.screen?.name || "")
			}

			// -------------------------------------------------- the east side
			// What the machine is carrying, and then the rest of the sanctum
			// scattered on a line rising away from the circle.
			ArcCore {
				id: core
				x: Math.round(bar.width / 2 + Arc.chronoRadius * 1.00)
				anchors.bottom: parent.bottom
				height: Arc.horizon
				lit: root.resourcesPopupOpen
				resources: resourceBars
				onClicked: root.toggleResourcesPopup()
			}

			// The constellation. Each mark sits at its own height on a line
			// climbing away from the horizon, because a row of marks at one
			// height is a toolbar however it is drawn.
			Item {
				id: constellation

				anchors.left: core.right
				anchors.leftMargin: Arc.s5
				anchors.right: trayRow.visible ? trayRow.left : powerNode.left
				anchors.rightMargin: Arc.s5
				anchors.bottom: parent.bottom
				height: Arc.horizon

				// how far along, and how high, each mark sits
				readonly property var stations: [
					{ at: 0.00, up: 0.34 },
					{ at: 0.20, up: 0.62 },
					{ at: 0.40, up: 0.38 },
					{ at: 0.60, up: 0.66 },
					{ at: 0.80, up: 0.40 },
					{ at: 1.00, up: 0.64 }
				]

				function placeX(index, w) {
					return Math.round(constellation.stations[index].at * (constellation.width - 44) + (22 - w / 2));
				}

				function placeY(index, h) {
					return Math.round(Arc.horizon - constellation.stations[index].up * Arc.horizon - h / 2);
				}

				// The line the constellation is strung on: faint, and only
				// there so the marks read as one group rather than as litter.
				Canvas {
					id: strand
					anchors.fill: parent
					renderStrategy: Canvas.Cooperative

					Connections {
						target: Arc
						function onGoldChanged() { strand.requestPaint(); }
					}

					onPaint: {
						const ctx = getContext("2d");
						ctx.reset();
						if (width < 40) return;
						const points = [];
						for (const station of constellation.stations)
							points.push({
								x: station.at * (width - 44) + 22,
								y: Arc.horizon - station.up * Arc.horizon
							});
						for (let index = 0; index + 1 < points.length; index++)
							Ink.leyCurve(ctx, points[index].x, points[index].y,
								points[index + 1].x, points[index + 1].y,
								index % 2 === 0 ? 6 : -6, Arc.ruleThin,
								Qt.alpha(Arc.gold, 0.14));
					}
				}

				NowPlaying {
					id: nowPlayingIsland
					x: constellation.placeX(0, width)
					y: constellation.placeY(0, height)
					progressColor: Arc.aether
					onClicked: root.toggleMediaPopup()
				}

				ArcSeat {
					id: weatherNode
					x: constellation.placeX(1, width)
					y: constellation.placeY(1, height)
					size: 26
					seed: 3
					label: root.weatherTemperature
					lit: root.weatherPopupOpen
					onClicked: root.toggleWeatherPopup()

					ArcMark {
						anchors.centerIn: parent
						width: parent.width * 0.78
						height: parent.height * 0.78
						glyph: "eye"
						weight: Arc.ruleThin
						lineColor: weatherNode.live > 0.25 ? Arc.aether : Arc.ink
					}
				}

				ArcSeat {
					id: notifNode
					x: constellation.placeX(2, width)
					y: constellation.placeY(2, height)
					size: 26
					seed: 1
					label: "Ravens"
					lit: root.notifPopupOpen
					badge: root.notificationGroups.length > 0 ? String(root.notificationGroups.length) : ""
					onClicked: root.toggleNotifPopup()

					ArcMark {
						anchors.centerIn: parent
						width: parent.width * 0.8
						height: parent.height * 0.8
						glyph: "raven"
						lineColor: notifNode.live > 0.25 ? Arc.aether : Arc.ink
					}
				}

				ArcSeat {
					id: clipboardNode
					x: constellation.placeX(3, width)
					y: constellation.placeY(3, height)
					size: 24
					seed: 2
					label: "Palimpsest"
					lit: root.clipboardPopupOpen
					iconSource: root.resolveIconSource("edit-paste-symbolic", ["edit-copy-symbolic"]) || Arc.icon("edit-paste-symbolic")
					onClicked: root.toggleClipboardPopup()
				}

				ArcSeat {
					id: bluetoothNode
					x: constellation.placeX(4, width)
					y: constellation.placeY(4, height)
					size: 24
					seed: 3
					label: "Bindings"
					lit: root.bluetoothPopupOpen
					iconSource: root.resolveIconSource("bluetooth-active-symbolic", ["bluetooth-symbolic"]) || Arc.icon("bluetooth-active-symbolic")
					onClicked: root.toggleBluetoothPopup()
				}

				ArcSeat {
					id: networkNode
					x: constellation.placeX(5, width)
					y: constellation.placeY(5, height)
					size: 24
					seed: 0
					label: "Ley"
					lit: root.networkPopupOpen
					iconSource: root.networkStatusType === "ethernet"
						? Arc.icon("network-wired-symbolic")
						: Arc.icon("network-wireless-signal-excellent-symbolic")
					onClicked: root.toggleNetworkPopup()
				}
			}

			// The familiars the system has sent: bound marks, set below the
			// constellation so they never move the rest of it about.
			Row {
				id: trayRow
				anchors.right: powerNode.left
				anchors.rightMargin: Arc.s5
				anchors.verticalCenter: parent.verticalCenter
				anchors.verticalCenterOffset: 4
				spacing: Arc.s2
				visible: trayRepeater.count > 0

				Repeater {
					id: trayRepeater
					model: ScriptModel {
						values: SystemTray.items.values
					}

					ArcSeat {
						id: trayNode

						required property SystemTrayItem modelData
						required property int index

						size: 20
						seed: trayNode.index + 1
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

			// The way out, alone in the far corner with air round it.
			ArcSeat {
				id: powerNode
				x: bar.width - Arc.s5 - width
				y: Math.round(Arc.horizon * 0.40)
				size: 28
				seed: 2
				label: "The Void"
				lit: root.powerPopupOpen
				liveColor: Arc.bane
				onClicked: root.togglePowerPopup()

				ArcMark {
					anchors.centerIn: parent
					width: parent.width * 0.7
					height: parent.height * 0.7
					glyph: "gate"
					weight: Arc.rule
					lineColor: powerNode.live > 0.25 ? Arc.bane : Qt.alpha(Arc.bane, 0.8)
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
		// A height of its own, not one taken from the column inside it: the
		// list fills whatever the head and the search line leave, so asking the
		// column how tall it wants to be would be asking it to answer with the
		// number it is waiting for.
		fixedHeight: 560

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
							id: clipHead
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
								lineColor: Arc.goldFaint
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
							height: clipboardColumn.height - clipHead.height
								- clipSpeak.height - clipboardColumn.spacing * 2

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
											lineColor: Arc.goldFaint
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

						Item {
							id: clipSpeak
							width: parent.width
							height: 34

							Rectangle {
								anchors.left: parent.left
								anchors.right: parent.right
								anchors.bottom: parent.bottom
								height: Arc.ruleThin
								color: Arc.goldFaint
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
								lineColor: Arc.goldFaint
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

						// THE BINDINGS.
						//
						// The adapter is a core, and everything it has ever been
						// bound to is a familiar in orbit around it. A familiar
						// that is here and answering is tied to the core by a
						// lit ley; one that is merely known sits dark on the
						// ring. So the state of the whole binding is one shape
						// you take in at a glance, and the list underneath is
						// only there for the names and the verbs.
						Item {
							id: bindingRing
							width: parent.width
							height: 150

							readonly property var known: bluetoothPopup.devices || []

							ArcHalo {
								anchors.centerIn: parent
								width: 200
								height: 200
								color: Arc.aether
								strength: bluetoothPopup.powered ? 0.22 : 0.04
								spread: 0.32
								flicker: true
							}

							Canvas {
								id: bindings
								anchors.fill: parent
								renderStrategy: Canvas.Cooperative

								readonly property int count: bindingRing.known.length
								readonly property bool powered: bluetoothPopup.powered
								property real phase: 0

								NumberAnimation on phase {
									running: bindings.powered
									loops: Animation.Infinite
									from: 0
									to: 1
									duration: 3400
								}

								onCountChanged: requestPaint()
								onPoweredChanged: requestPaint()
								onPhaseChanged: requestPaint()

								onPaint: {
									const ctx = getContext("2d");
									ctx.reset();
									if (width < 60) return;
									const cx = width / 2, cy = height / 2;
									const orbit = Math.min(width, height) / 2 - 22;

									Ink.ring(ctx, cx, cy, orbit, Arc.ruleThin,
										Qt.alpha(Arc.gold, bindings.powered ? 0.16 : 0.07), 1);
									Ink.mote(ctx, cx, cy, 7, bindings.powered ? Arc.aether : Arc.goldDim);
									Ink.ring(ctx, cx, cy, 14, Arc.ruleThin,
										Qt.alpha(bindings.powered ? Arc.aether : Arc.gold, 0.4), 1);

									const total = Math.max(1, bindings.count);
									for (let index = 0; index < bindings.count; index++) {
										const device = bindingRing.known[index];
										const angle = -Math.PI / 2 + Math.PI * 2 * index / total;
										const x = cx + Math.cos(angle) * orbit;
										const y = cy + Math.sin(angle) * orbit;
										if (device && device.connected) {
											Ink.ley(ctx, cx, cy, x, y, Arc.ruleThin,
												Qt.alpha(Arc.aether, 0.45), null, -1);
											// something running down the tie
											const t = (bindings.phase + index / total) % 1;
											Ink.mote(ctx, cx + Math.cos(angle) * orbit * t,
												cy + Math.sin(angle) * orbit * t, 2.4, Arc.aether);
											Ink.mote(ctx, x, y, 5.5, Arc.aether);
										} else {
											Ink.ring(ctx, x, y, 5, Arc.ruleThin,
												Qt.alpha(Arc.gold, 0.5), 1);
										}
									}
								}
							}

							ArcText {
								anchors.horizontalCenter: parent.horizontalCenter
								anchors.top: parent.top
								role: "hand"
								tone: bluetoothPopup.powered ? "muted" : "faint"
								font.pixelSize: 14
								text: bluetoothPopup.powered
									? (bindingRing.known.length === 0 ? "nothing is bound" : "")
									: "the binding is cold"
							}

							ArcLever {
								id: btSwitch
								anchors.horizontalCenter: parent.horizontalCenter
								anchors.bottom: parent.bottom
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
								lineColor: Arc.goldFaint
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
								lineColor: bluetoothPopup.scanning ? Qt.alpha(Arc.aether, 0.55) : Arc.goldGhost
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
									lineColor: Arc.goldGhost
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
										lineColor: Arc.goldGhost
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

						// THE LEY.
						//
						// A connection is a line with something running along
						// it, so that is what is drawn: this machine at the
						// foot, the world at the head, and the ley between them
						// with lights travelling it — up for what is being
						// sent, down for what is arriving, and each one moving
						// at the rate it is actually moving at. An idle link is
						// a still line. A busy one is a stream.
						Item {
							id: networkPopupColumn
							anchors.fill: parent

							readonly property bool offline: networkPopup.currentType === "offline"

							// The world.
							Item {
								id: worldNode
								anchors.horizontalCenter: parent.horizontalCenter
								anchors.top: parent.top
								width: 64
								height: 64

								ArcHalo {
									anchors.centerIn: parent
									width: 130
									height: 130
									color: Arc.aether
									strength: networkPopupColumn.offline ? 0 : 0.26
									spread: 0.32
									flicker: true
								}

								ArcDial {
									anchors.fill: parent
									lineColor: Qt.alpha(Arc.gold, 0.3)
									liveColor: Arc.aether
									weight: Arc.ruleThin
									seed: 2
									intensity: networkPopupColumn.offline ? 0 : 0.7
								}

								ArcMark {
									anchors.centerIn: parent
									width: 26
									height: 26
									glyph: "star"
									weight: Arc.ruleThin
									lineColor: networkPopupColumn.offline ? Arc.goldDim : Arc.aether
								}
							}

							ArcText {
								anchors.horizontalCenter: worldNode.horizontalCenter
								anchors.top: worldNode.bottom
								anchors.topMargin: 2
								role: "label"
								tone: networkPopupColumn.offline ? "faint" : "muted"
								text: networkPopupColumn.offline ? "Severed" : "The World"
							}

							// The ley itself, with the traffic running on it.
							Canvas {
								id: leyRun
								anchors.horizontalCenter: parent.horizontalCenter
								anchors.top: worldNode.bottom
								anchors.bottom: hereNode.top
								anchors.topMargin: 24
								anchors.bottomMargin: 6
								width: 180
								renderStrategy: Canvas.Cooperative

								// Two lights per direction, walking the line.
								property real phase: 0

								NumberAnimation on phase {
									running: !networkPopupColumn.offline
									loops: Animation.Infinite
									from: 0
									to: 1
									duration: 2600
								}

								readonly property real up: Math.min(1, networkPopup.currentUploadSpeed / 262144)
								readonly property real down: Math.min(1, networkPopup.currentDownloadSpeed / 1048576)

								onPhaseChanged: requestPaint()

								onPaint: {
									const ctx = getContext("2d");
									ctx.reset();
									if (height < 20) return;
									const left = width * 0.34, right = width * 0.66;
									Ink.ley(ctx, left, 0, left, height, Arc.ruleThin, Arc.goldGhost, null, -1);
									Ink.ley(ctx, right, 0, right, height, Arc.ruleThin, Arc.goldGhost, null, -1);

									// what is being sent: lights climbing the
									// left line, spaced by how much there is
									const sending = Math.max(1, Math.round(1 + leyRun.up * 5));
									for (let index = 0; index < sending; index++) {
										const t = (leyRun.phase * (0.4 + leyRun.up) + index / sending) % 1;
										Ink.mote(ctx, left, height * (1 - t), 2.4 + leyRun.up * 2, Arc.aetherAlt);
									}

									// what is arriving: lights falling the right
									const arriving = Math.max(1, Math.round(1 + leyRun.down * 7));
									for (let index = 0; index < arriving; index++) {
										const t = (leyRun.phase * (0.4 + leyRun.down * 1.6) + index / arriving) % 1;
										Ink.mote(ctx, right, height * t, 2.4 + leyRun.down * 2.4, Arc.aether);
									}
								}
							}

							ArcText {
								anchors.right: leyRun.left
								anchors.rightMargin: Arc.s2
								anchors.verticalCenter: leyRun.verticalCenter
								anchors.verticalCenterOffset: -16
								horizontalAlignment: Text.AlignRight
								role: "label"
								tone: "faint"
								text: "Sent"
							}

							ArcText {
								anchors.right: leyRun.left
								anchors.rightMargin: Arc.s2
								anchors.verticalCenter: leyRun.verticalCenter
								anchors.verticalCenterOffset: 4
								horizontalAlignment: Text.AlignRight
								role: "bodyStrong"
								text: networkPopup.formatSpeed(networkPopup.currentUploadSpeed)
							}

							ArcText {
								anchors.left: leyRun.right
								anchors.leftMargin: Arc.s2
								anchors.verticalCenter: leyRun.verticalCenter
								anchors.verticalCenterOffset: -16
								role: "label"
								tone: "faint"
								text: "Drawn"
							}

							ArcText {
								anchors.left: leyRun.right
								anchors.leftMargin: Arc.s2
								anchors.verticalCenter: leyRun.verticalCenter
								anchors.verticalCenterOffset: 4
								role: "bodyStrong"
								text: networkPopup.formatSpeed(networkPopup.currentDownloadSpeed)
							}

							// This machine.
							Item {
								id: hereNode
								anchors.horizontalCenter: parent.horizontalCenter
								anchors.bottom: hereName.top
								anchors.bottomMargin: Arc.s2
								width: 52
								height: 52

								ArcDial {
									anchors.fill: parent
									lineColor: Qt.alpha(Arc.gold, 0.3)
									liveColor: Arc.aether
									weight: Arc.ruleThin
									seed: 1
									beading: false
									intensity: networkPopupColumn.offline ? 0 : 0.5
								}

								QQCImpl.IconImage {
									anchors.centerIn: parent
									width: 18
									height: 18
									source: networkPopup.currentType === "ethernet"
										? Arc.icon("network-wired-symbolic")
										: Arc.icon("network-wireless-signal-excellent-symbolic")
									sourceSize: Qt.size(width, height)
									color: networkPopupColumn.offline ? Arc.inkFaint : Arc.aether
								}
							}

							Column {
								id: hereName
								anchors.horizontalCenter: parent.horizontalCenter
								anchors.bottom: severVerb.top
								anchors.bottomMargin: Arc.s4
								spacing: -2

								ArcText {
									anchors.horizontalCenter: parent.horizontalCenter
									role: "display"
									font.pixelSize: 19
									text: networkPopupColumn.offline ? "Unbound"
										: (networkPopup.currentType === "ethernet" ? "Corded" : "Adrift")
								}

								ArcText {
									anchors.horizontalCenter: parent.horizontalCenter
									role: "caption"
									tone: "faint"
									text: networkPopup.currentInterface === "" ? "" : networkPopup.currentInterface
								}

								ArcText {
									anchors.horizontalCenter: parent.horizontalCenter
									role: "mono"
									tone: "muted"
									font.pixelSize: 11
									text: networkPopup.currentIp
								}
							}

							ArcButton {
								id: severVerb
								anchors.horizontalCenter: parent.horizontalCenter
								anchors.bottom: parent.bottom
								text: "Sever"
								tone: "alert"
								enabled: !networkPopupColumn.offline
								onClicked: root.disconnectActiveNetwork()
							}
						}
				}
	}

	PopupSurface {
		id: resourcesPopup
		title: "The Arcane Core"
		screen: root.activePopupScreen

		onDismissRequested: root.closeResourcesPopup()
		open: root.resourcesPopupOpen
		visible: root.resourcesPopupVisible
		barItem: bar
		anchorItem: core
		surfaceColor: root.surface
		borderColor: root.surfaceBorder
		expandedWidth: 460
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

		// The core, opened.
		//
		// The same object that sits on the horizon, at a size where it can be
		// read: four bodies held off a burning core on four spokes, each one
		// drawn *in* towards the core as its own reading rises. So a machine at
		// rest is a wide, calm, dim thing and a machine under load is a tight,
		// bright, crowded one, and you know which before you have read a
		// single number.
		Column {
			id: resourcesPopupColumn
			anchors.fill: parent
			spacing: Arc.s5

			Item {
				width: parent.width
				height: 230

				readonly property real strain: Math.max(resourceBars.cpuUsage, resourceBars.memoryUsage)
				readonly property bool burning: strain > 0.86
				readonly property real cx: width / 2
				readonly property real cy: height / 2

				readonly property var bodies: [
					{ name: "Mana", reading: resourceBars.cpuUsage, note: resourceBars.cpuText, angle: -90 },
					{ name: "Aether", reading: resourceBars.memoryUsage, note: resourceBars.memoryText, angle: 0 },
					{ name: "Vault", reading: resourceBars.storageUsage, note: `${resourceBars.disks.length} held`, angle: 90 },
					{ name: "Essence", reading: resourceBars.mouseBatteryAvailable ? resourceBars.mouseBatteryUsage : 0,
					  note: resourceBars.mouseBatteryAvailable ? resourceBars.mouseBatteryText : "none", angle: 180 }
				]

				ArcHalo {
					anchors.centerIn: parent
					width: 280
					height: 280
					color: parent.burning ? Arc.bane : Arc.aether
					strength: 0.14 + parent.strain * 0.30
					spread: 0.34
					flicker: true
				}

				Canvas {
					id: orrery
					anchors.fill: parent
					renderStrategy: Canvas.Cooperative

					readonly property real mana: resourceBars.cpuUsage
					readonly property real aether: resourceBars.memoryUsage
					readonly property real vault: resourceBars.storageUsage
					readonly property real essence: resourceBars.mouseBatteryUsage

					onManaChanged: requestPaint()
					onAetherChanged: requestPaint()
					onVaultChanged: requestPaint()
					onEssenceChanged: requestPaint()

					Connections {
						target: Arc
						function onGoldChanged() { orrery.requestPaint(); }
					}

					onPaint: {
						const ctx = getContext("2d");
						ctx.reset();
						if (width < 60) return;
						const cx = width / 2, cy = height / 2;
						const strain = Math.max(orrery.mana, orrery.aether);
						const hot = strain > 0.86;
						const live = hot ? Arc.bane : Arc.aether;
						const orbit = 84;

						Ink.ring(ctx, cx, cy, orbit, Arc.ruleThin, Qt.alpha(Arc.gold, 0.14), 1);
						Ink.ring(ctx, cx, cy, orbit * 0.5, Arc.ruleThin, Qt.alpha(Arc.gold, 0.08), 1);

						Ink.mote(ctx, cx, cy, 8 + strain * 8, live);
						Ink.ring(ctx, cx, cy, 18 + strain * 6, Arc.ruleThin,
							Qt.alpha(live, 0.28 + strain * 0.5), 1);

						const readings = [orrery.mana, orrery.aether, orrery.vault, orrery.essence];
						const tints = [live, hot ? Arc.bane : Arc.aetherAlt, Arc.aetherThird, Arc.gold];
						for (let index = 0; index < 4; index++) {
							const angle = -Math.PI / 2 + index * Math.PI / 2;
							const at = orbit * (1 - readings[index] * 0.52);
							const x = cx + Math.cos(angle) * at, y = cy + Math.sin(angle) * at;
							// the spoke, marked to the full orbit so the gap is
							// legible as the distance it has been drawn in
							Ink.ley(ctx, cx + Math.cos(angle) * 22, cy + Math.sin(angle) * 22,
								cx + Math.cos(angle) * orbit, cy + Math.sin(angle) * orbit,
								Arc.ruleThin, Qt.alpha(Arc.gold, 0.13), null, -1);
							Ink.ley(ctx, cx + Math.cos(angle) * 22, cy + Math.sin(angle) * 22,
								x, y, Arc.ruleThin * 1.4, Qt.alpha(tints[index], 0.5), null, -1);
							Ink.mote(ctx, x, y, 4 + readings[index] * 6, tints[index]);
						}
					}
				}

				// The names, written at the far end of each spoke.
				Repeater {
					model: parent.bodies

					delegate: Column {
						id: bodyName

						required property var modelData
						required property int index

						readonly property real radians: modelData.angle * Math.PI / 180
						readonly property real outward: 108

						width: 116
						spacing: -2

						x: Math.round(parent.cx + Math.cos(bodyName.radians) * bodyName.outward - width / 2)
						y: Math.round(parent.cy + Math.sin(bodyName.radians) * bodyName.outward - height / 2)

						ArcText {
							width: parent.width
							horizontalAlignment: Text.AlignHCenter
							role: "label"
							tone: bodyName.modelData.reading > 0.86 ? "alert" : "aether"
							text: bodyName.modelData.name
						}

						ArcText {
							width: parent.width
							horizontalAlignment: Text.AlignHCenter
							role: "display"
							font.pixelSize: 20
							text: `${Math.round(bodyName.modelData.reading * 100)}%`
						}

						ArcText {
							width: parent.width
							horizontalAlignment: Text.AlignHCenter
							role: "caption"
							tone: "faint"
							text: bodyName.modelData.note
						}
					}
				}

				// Motes thrown off the core while it is working hard.
				ArcMotes {
					anchors.centerIn: parent
					width: 180
					height: 180
					color: parent.burning ? Arc.bane : Arc.aether
					drifting: parent.strain > 0.5
					density: Math.round(parent.strain * 22)
					drift: -20
					span: 2.6
				}
			}

			ArcRubric {
				width: parent.width
				title: "The Vaults"
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

			// Life essence: the pointer's charge, in the flask the reference
			// asks for. It only exists when there is a pointer with a charge.
			ArcRubric {
				width: parent.width
				visible: resourceBars.mouseBatteryAvailable
				title: "Life Essence"
				trailing: resourceBars.mouseBatteryStatus

				Row {
					width: parent.width
					spacing: Arc.s4

					Item {
						width: 46
						height: 86

						Canvas {
							id: flask
							anchors.fill: parent
							renderStrategy: Canvas.Cooperative

							Connections {
								target: Arc
								function onGoldChanged() { flask.requestPaint(); }
							}

							onPaint: {
								const ctx = getContext("2d");
								ctx.reset();
								const neck = width * 0.22, shoulder = height * 0.22;
								Ink.cut(ctx, [
									{ x: width / 2 - neck, y: 6 },
									{ x: width / 2 - neck, y: shoulder },
									{ x: 3, y: shoulder + 14 },
									{ x: 3, y: height - 8 },
									{ x: 10, y: height - 2 },
									{ x: width - 10, y: height - 2 },
									{ x: width - 3, y: height - 8 },
									{ x: width - 3, y: shoulder + 14 },
									{ x: width / 2 + neck, y: shoulder },
									{ x: width / 2 + neck, y: 6 }
								], Arc.rule, Qt.alpha(Arc.gold, 0.6), false);
								Ink.cut(ctx, [{ x: width / 2 - neck - 4, y: 5 }, { x: width / 2 + neck + 4, y: 5 }],
									Arc.ruleHeavy, Arc.gold, false);
							}
						}

						ArcPhial {
							anchors.left: parent.left
							anchors.right: parent.right
							anchors.bottom: parent.bottom
							anchors.leftMargin: 5
							anchors.rightMargin: 5
							anchors.bottomMargin: 4
							height: parent.height * 0.62
							vertical: true
							value: resourceBars.mouseBatteryUsage
							trackColor: "transparent"
							fillColor: resourceBars.mouseBatteryUsage < 0.2 ? Arc.bane : Arc.ward
						}

						// While it is filling, the essence gives off motes.
						ArcMotes {
							anchors.fill: parent
							color: Arc.ward
							drifting: String(resourceBars.mouseBatteryStatus).toLowerCase().indexOf("charg") >= 0
							density: 8
							drift: -24
							span: 2.2
						}
					}

					Column {
						anchors.verticalCenter: parent.verticalCenter
						spacing: -2

						ArcText {
							role: "display"
							font.pixelSize: 24
							text: resourceBars.mouseBatteryText
						}

						ArcText {
							role: "body"
							tone: "muted"
							text: resourceBars.mouseBatteryName
						}
					}
				}
			}
		}
	}

	// THE ARCANE CODEX.
	//
	// The launcher is the book the reference draws: one tall narrow volume
	// standing in the middle of the sanctum, not a spread and not a card. It is
	// called up exactly the way every other panel is — a ring inscribes itself
	// on the floor beneath it, motes gather off the ring, and the page
	// condenses upward out of them. There are no covers and nothing opens on a
	// hinge, so there is nothing to get the wrong way round.
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

		// The horizon is never covered: the sigil you opened this with is still
		// there to close it, and the chronomancer keeps the hour.
		mask: Region {
			x: 0
			y: 0
			width: launcherPopup.width
			height: Math.max(0, launcherPopup.height - Math.round(Arc.horizon))
		}

		property real progress: root.launcherPopupOpen ? 1 : 0

		readonly property real inscribed: Math.max(0, Math.min(1, progress / 0.34))
		readonly property real condensed: Math.max(0, Math.min(1, (progress - 0.26) / 0.48))

		// The night the summoning happens in. Not a curtain across the screen:
		// a vignette centred on the wheel, all but opaque where the wheel
		// stands and gone by the edges, so the desktop is still there and the
		// thing you are looking at is the only lit object in the room.
		// Painted once, and only its opacity moves. Binding the strength to
		// the conjuring would repaint a screen-sized canvas on every frame of
		// the opening, and binding anything in it to the search would repaint
		// it on every keystroke — which is exactly how the desktop ended up
		// blinking through the wheel.
		ArcHalo {
			anchors.centerIn: codex
			width: Math.max(launcherPopup.width, launcherPopup.height) * 1.1
			height: width
			color: Arc.abyss
			strength: 1.0
			spread: 0.46
			core: 0.46
			falloff: 1.8
			opacity: launcherPopup.condensed
			visible: launcherPopup.progress > 0.02
			z: -1
		}

		Behavior on progress {
			NumberAnimation {
				duration: root.launcherPopupOpen ? Arc.conjure + 140 : Arc.dispel + 60
				easing.type: Easing.Bezier
				easing.bezierCurve: root.launcherPopupOpen ? Arc.curveRise : Arc.curveSink
			}
		}

		onVisibleChanged: if (visible) gatherTimer.restart()

		Timer {
			id: gatherTimer
			interval: Math.round(Arc.conjure * 0.26)
			onTriggered: if (root.launcherPopupOpen) codexMotes.burst(codexMotes.width / 2, codexMotes.height - 10, 30)
		}

		// Nothing is dimmed. The codex is conjured *in* the room rather than
		// over a curtain drawn across it, so the desktop stays where it was and
		// the book is simply a lit thing standing in front of it. What keeps it
		// readable is its own glass and the pool of dark the conjuring brings
		// with it, not a scrim over everything else.
		MouseArea {
			anchors.fill: parent
			anchors.bottomMargin: Math.round(Arc.horizon)
			onClicked: root.closeLauncherPopup()
		}

		Item {
			id: codex

			// A folio when there is a discourse in it, an octavo when there is
			// a page to read, and no page at all when the wheel is turning —
			// the wheel is its own object and putting glass behind it would be
			// putting a circle in a box.
			readonly property bool folio: {
				const sheet = launcherSheetLoader.item;
				return !!sheet && (sheet.inChatMode || sheet.inOllamaMode || sheet.inFileMode);
			}
			readonly property bool ceremonial: {
				const sheet = launcherSheetLoader.item;
				return !!sheet && sheet.ceremonial;
			}

			width: Math.min(parent.width - Arc.s8 * 2,
				codex.ceremonial ? 900 : codex.folio ? 980 : 560)
			height: Math.min(parent.height - Arc.horizon - Arc.s6 * 2,
				codex.ceremonial ? 940 : 760)
			x: Math.round((parent.width - width) / 2)
			y: Math.round((parent.height - Arc.horizon - height) / 2)

			Behavior on width {
				NumberAnimation { duration: Arc.turn; easing.type: Easing.Bezier; easing.bezierCurve: Arc.curveSnap }
			}

			// The ring on the floor. Under a page it is what the page was
			// conjured out of; under the wheel the wheel's own limb says that
			// already, so it stays small and out of the way.
			Canvas {
				id: codexCircle
				anchors.horizontalCenter: parent.horizontalCenter
				y: parent.height - 18
				width: codex.ceremonial ? codex.width * 0.5 : codex.width * 1.1
				height: width * 0.22
				renderStrategy: Canvas.Cooperative

				readonly property real through: launcherPopup.inscribed

				onThroughChanged: requestPaint()

				onPaint: {
					const ctx = getContext("2d");
					ctx.reset();
					if (width < 40 || codexCircle.through <= 0.002) return;
					ctx.save();
					ctx.translate(width / 2, height / 2);
					ctx.scale(1, height / width);
					Ink.ring(ctx, 0, 0, width / 2 - 4, 2.4, Arc.aether, codexCircle.through);
					Ink.graduations(ctx, 0, 0, width / 2 - 7, 72, 6, 14, 6,
						Arc.ruleThin, Qt.alpha(Arc.aether, 0.45), codexCircle.through);
					Ink.runeRing(ctx, 0, 0, width / 2 - 30, 12, 41, 18, Arc.ruleThin,
						Qt.alpha(Arc.gold, 0.2), Arc.aether,
						Math.round(12 * codexCircle.through));
					ctx.restore();
				}
			}

			// The dark the book brings with it. Without a scrim this is the
			// only thing separating a translucent page from whatever happens
			// to be behind it, so it is generous — but it falls off inside the
			// codex's own width and never reads as a curtain.
			ArcHalo {
				anchors.centerIn: codexCircle
				width: codexCircle.width * 1.4
				height: codexCircle.height * 6
				color: Arc.aether
				strength: 0.30 * launcherPopup.inscribed
				spread: 0.42
				flicker: true
			}

			ArcMotes {
				id: codexMotes
				anchors.fill: parent
				color: Arc.aether
				span: 3.6
				visible: launcherPopup.progress > 0.04 && launcherPopup.progress < 0.97
			}

			// The page, condensing upward out of the ring.
			Item {
				id: aperture
				anchors.left: parent.left
				anchors.right: parent.right
				anchors.bottom: parent.bottom
				anchors.bottomMargin: 14
				height: Math.max(0, (parent.height - 14) * launcherPopup.condensed)
				clip: true
				opacity: Math.min(1, launcherPopup.condensed * 1.5)

				ArcLeaf {
					id: page
					anchors.left: parent.left
					anchors.right: parent.right
					anchors.bottom: parent.bottom
					height: codex.height - 14
					variant: "chamber"
					crest: !codex.ceremonial
					washTop: codex.ceremonial ? "transparent" : Arc.haze
					washBottom: codex.ceremonial ? "transparent" : Arc.hazeDeep
					beading: !codex.ceremonial
					haloStrength: codex.ceremonial ? 0 : 0.16 * launcherPopup.condensed
					padding: codex.ceremonial ? Arc.s4 : Arc.s6

					Item {
						id: launcherStage

						focus: true

						Keys.onEscapePressed: event => {
							event.accepted = true;
							root.closeLauncherPopup();
						}

						anchors.fill: parent

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
								onCloseRequested: root.closeLauncherPopup()
								onOpenStudioRequested: page => {
									root.closeLauncherPopup();
									root.openStudio(page);
								}
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

				readonly property real radius: Math.min(width, height) * 0.33
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
						function onGoldChanged() { circle.requestPaint(); }
					}

					onPaint: {
						const ctx = getContext("2d");
						ctx.reset();
						const cx = width / 2, cy = height / 2, r = powerModal.radius;
						if (r < 20) return;

						// The limb the stations stand on, graduated, with the
						// ring the machine's own name is written inside.
						Ink.ring(ctx, cx, cy, r, Arc.rule * 1.3, Qt.alpha(Arc.gold, 0.5), 1);
						Ink.ring(ctx, cx, cy, r - 12, Arc.ruleThin, Qt.alpha(Arc.gold, 0.26), 1);
						Ink.graduations(ctx, cx, cy, r - 1, 72, 4, 10, 18,
							Arc.ruleThin, Qt.alpha(Arc.gold, 0.42), 1);
						Ink.ring(ctx, cx, cy, r * 0.42, Arc.ruleThin, Qt.alpha(Arc.gold, 0.2), 1);
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
							easing.bezierCurve: Arc.curveSnap
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
						lineColor: Arc.goldDim
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
							color: Arc.veil1
						}

						ArcDial {
							id: seatDial
							anchors.horizontalCenter: parent.horizontalCenter
							anchors.verticalCenter: parent.verticalCenter
							width: 54
							height: 54
							seed: station.index
							weight: Arc.rule
							lineColor: station.modelData.grave ? Qt.alpha(Arc.bane, 0.5) : Arc.goldDim
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
						// The name is always set under its station, except the one
						// at the top of the circle which is set above it. Set
						// outside the circle to left and right, the names would
						// run off the edge of the conjuring.
						Column {
							id: naming
							spacing: -2
							width: 168

							x: Math.round((station.width - width) / 2)
							y: station.modelData.angle === -90
								? -naming.height - 8
								: station.height + 8

							ArcText {
								width: parent.width
								horizontalAlignment: Text.AlignHCenter
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
								horizontalAlignment: Text.AlignHCenter
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

	// A named reading: what it is on the left, what it says on the right, and a
	// ley under it with a single light standing at the value. A filled bar
	// would be a different style's idea of a quantity; here a quantity is where
	// the light has got to.
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
		implicitHeight: 40

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

		Canvas {
			id: line
			anchors.left: parent.left
			anchors.right: parent.right
			anchors.top: rowLabel.bottom
			anchors.topMargin: Arc.s2
			height: 12
			renderStrategy: Canvas.Cooperative

			readonly property real at: Math.max(0, Math.min(1, resourceRow.usage))

			onAtChanged: requestPaint()

			Connections {
				target: Arc
				function onGoldChanged() { line.requestPaint(); }
			}

			onPaint: {
				const ctx = getContext("2d");
				ctx.reset();
				if (width < 10) return;
				const y = height / 2;
				const tint = resourceRow.strained ? Arc.bane : Arc.aether;
				Ink.ley(ctx, 0, y, width, y, Arc.ruleThin, Arc.goldGhost, null, -1);
				Ink.ley(ctx, 0, y, width * line.at, y, Arc.ruleThin * 1.6,
					Qt.alpha(tint, 0.55), null, -1);
				Ink.mote(ctx, width * line.at, y, 3.2, tint);
			}
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
								color: Arc.goldGhost
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
		anchorItem: chrono
		surfaceColor: root.surface
		borderColor: root.surfaceBorder
		expandedWidth: 420
		fixedHeight: 470

		onVisibleChanged: {
			if (!visible && root.clockPopupVisible) {
				if (root.clockPopupOpen) root.closeClockPopup();
				else root.clockPopupVisible = false;
			}
		}

		// THE WHEEL OF THE MONTH.
		//
		// There is no grid here. A month is a turn of a wheel, so the days are
		// set round the rim in order and today is where the index arm is
		// pointing. Weekends are dimmer; the day under the pointer lights. The
		// middle of the wheel holds what the month actually is — its name, the
		// moon as it stands tonight, and the name this hour goes by.
		//
		// Reading a date off it is not slower than reading a grid, because the
		// only date anybody looks for is today, and today is the lit one with
		// an arm pointing at it.
		Item {
			id: calendarContent
			anchors.fill: parent

			readonly property var shown: root.currentDate
			readonly property int days: root.calendarDaysInMonth(calendarContent.shown)
			// Which weekday the first of the month falls on, 0 = Monday.
			readonly property int firstWeekday: root.calendarOffset(calendarContent.shown)
			readonly property bool thisMonth: calendarContent.shown.getMonth() === root.now.getMonth()
				&& calendarContent.shown.getFullYear() === root.now.getFullYear()
			readonly property int today: root.now.getDate()

			property int hoveredDay: 0

			function angleOf(day) {
				return -Math.PI / 2 + Math.PI * 2 * (day - 1) / calendarContent.days;
			}

			function isWeekend(day) {
				const weekday = (calendarContent.firstWeekday + day - 1) % 7;
				return weekday >= 5;
			}

			// The limb the days are written on, painted once per month.
			Canvas {
				id: wheel
				anchors.centerIn: parent
				anchors.verticalCenterOffset: -6
				width: Math.min(parent.width, parent.height - 40)
				height: width
				renderStrategy: Canvas.Cooperative

				readonly property int days: calendarContent.days
				readonly property int first: calendarContent.firstWeekday

				onDaysChanged: requestPaint()
				onFirstChanged: requestPaint()

				Connections {
					target: Arc
					function onGoldChanged() { wheel.requestPaint(); }
				}

				onPaint: {
					const ctx = getContext("2d");
					ctx.reset();
					if (width < 60) return;
					const cx = width / 2, cy = height / 2, r = width / 2 - 4;
					Ink.ring(ctx, cx, cy, r, Arc.ruleThin, Qt.alpha(Arc.gold, 0.26), 1);
					Ink.ring(ctx, cx, cy, r - 30, Arc.ruleThin, Qt.alpha(Arc.gold, 0.12), 1);
					Ink.graduations(ctx, cx, cy, r - 1, wheel.days, 4, 10, 7,
						Arc.ruleThin, Qt.alpha(Arc.gold, 0.30), 1);
					// the four quarters of the wheel, marked heavier
					Ink.graduations(ctx, cx, cy, r - 30, 4, 7, 7, 1,
						Arc.ruleThin, Qt.alpha(Arc.gold, 0.22), 1);
				}
			}

			// The index arm, pointing at today. It turns to the day when the
			// month is turned back to this one and simply is not drawn when you
			// are looking at another month.
			Item {
				id: indexArm
				anchors.centerIn: wheel
				width: 2
				height: wheel.height - 8
				visible: calendarContent.thisMonth
				rotation: (calendarContent.angleOf(calendarContent.today) + Math.PI / 2) * 180 / Math.PI

				Behavior on rotation {
					RotationAnimation {
						direction: RotationAnimation.Shortest
						duration: Arc.draw
						easing.type: Easing.Bezier
						easing.bezierCurve: Arc.curveSnap
					}
				}

				Rectangle {
					anchors.horizontalCenter: parent.horizontalCenter
					anchors.top: parent.top
					anchors.topMargin: 14
					width: Arc.ruleThin
					height: parent.height / 2 - 52
					color: Qt.alpha(Arc.aether, 0.55)
				}
			}

			// The days.
			Repeater {
				model: calendarContent.days

				delegate: Item {
					id: dayMark

					required property int index
					readonly property int day: dayMark.index + 1
					readonly property bool isToday: calendarContent.thisMonth && dayMark.day === calendarContent.today
					readonly property bool hovered: calendarContent.hoveredDay === dayMark.day
					readonly property real radians: calendarContent.angleOf(dayMark.day)

					width: 26
					height: 26
					x: Math.round(wheel.x + wheel.width / 2 + Math.cos(dayMark.radians) * (wheel.width / 2 - 17) - width / 2)
					y: Math.round(wheel.y + wheel.height / 2 + Math.sin(dayMark.radians) * (wheel.height / 2 - 17) - height / 2)

					ArcHalo {
						anchors.centerIn: parent
						width: 52
						height: 52
						color: Arc.aether
						strength: 0.42
						spread: 0.3
						flicker: true
						visible: dayMark.isToday
					}

					ArcText {
						anchors.centerIn: parent
						role: dayMark.isToday ? "display" : "body"
						font.pixelSize: dayMark.isToday ? 16 : 12
						font.letterSpacing: 0
						tone: dayMark.isToday ? "aether"
							: dayMark.hovered ? "default"
							: calendarContent.isWeekend(dayMark.day) ? "faint" : "muted"
						text: dayMark.day
					}

					ArcTouch {
						hoverEnabled: true
						cursorShape: Qt.ArrowCursor
						onContainsMouseChanged: calendarContent.hoveredDay = containsMouse ? dayMark.day : 0
					}
				}
			}

			// The middle of the wheel: what month this is, the moon as it
			// stands, and the name of the hour.
			Column {
				anchors.centerIn: wheel
				spacing: 1

				ArcText {
					anchors.horizontalCenter: parent.horizontalCenter
					role: "display"
					font.pixelSize: 26
					text: Qt.formatDateTime(calendarContent.shown, "MMMM")
				}

				ArcText {
					anchors.horizontalCenter: parent.horizontalCenter
					role: "label"
					tone: "muted"
					text: Qt.formatDateTime(calendarContent.shown, "yyyy")
				}

				Item { width: 1; height: Arc.s3 }

				Canvas {
					id: bigMoon
					anchors.horizontalCenter: parent.horizontalCenter
					width: 30
					height: 30
					renderStrategy: Canvas.Cooperative

					readonly property real phase: Arc.moonPhase(root.now).fraction

					onPhaseChanged: requestPaint()

					onPaint: {
						const ctx = getContext("2d");
						ctx.reset();
						const r = width / 2 - 1;
						ctx.strokeStyle = Arc.goldDim;
						ctx.lineWidth = Arc.ruleThin;
						ctx.beginPath();
						ctx.arc(width / 2, height / 2, r, 0, Math.PI * 2);
						ctx.stroke();
						const waxing = bigMoon.phase < 0.5;
						const sweep = Math.cos(bigMoon.phase * Math.PI * 2);
						ctx.fillStyle = Arc.gold;
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

				ArcText {
					anchors.horizontalCenter: parent.horizontalCenter
					role: "hand"
					tone: "muted"
					font.pixelSize: 13
					text: Arc.moonPhase(root.now).name
				}

				ArcText {
					anchors.horizontalCenter: parent.horizontalCenter
					role: "hand"
					tone: "aether"
					font.pixelSize: 14
					text: Arc.hourName(root.now)
					visible: calendarContent.thisMonth
				}
			}

			// Turning the wheel. Two runes, one either side, and nothing that
			// looks like a button.
			ArcSeat {
				anchors.left: parent.left
				anchors.bottom: parent.bottom
				size: 26
				seed: 1
				label: "Back"
				onClicked: root.shiftCalendarMonths(-1)

				ArcRune {
					anchors.centerIn: parent
					width: 11
					height: 16
					seed: 2
					weight: Arc.ruleThin
					lineColor: Arc.ink
				}
			}

			ArcText {
				anchors.horizontalCenter: parent.horizontalCenter
				anchors.bottom: parent.bottom
				anchors.bottomMargin: 4
				role: "label"
				tone: "faint"
				text: calendarContent.thisMonth ? "" : Qt.formatDateTime(root.now, "d MMMM") + " is today"
			}

			ArcSeat {
				anchors.right: parent.right
				anchors.bottom: parent.bottom
				size: 26
				seed: 3
				label: "On"
				onClicked: root.shiftCalendarMonths(1)

				ArcRune {
					anchors.centerIn: parent
					width: 11
					height: 16
					seed: 8
					weight: Arc.ruleThin
					lineColor: Arc.ink
				}
			}
		}
	}

	PopupSurface {
		id: weatherPopup
		title: "The Oracle"
		screen: root.activePopupScreen

		onDismissRequested: root.closeWeatherPopup()
		open: root.weatherPopupOpen
		visible: root.weatherPopupVisible
		barItem: bar
		anchorItem: weatherNode
		surfaceColor: root.surface
		borderColor: root.surfaceBorder
		expandedWidth: 340
		contentPreferredHeight: oracleColumn.implicitHeight

		onVisibleChanged: {
			if (!visible && root.weatherPopupVisible) {
				if (root.weatherPopupOpen) root.closeWeatherPopup();
				else root.weatherPopupVisible = false;
			}
		}

		readonly property bool raining: parseFloat(String(root.weatherPrecipitation || "0")) > 0
			|| String(root.weatherDescription || "").toLowerCase().indexOf("rain") >= 0
		readonly property bool storming: String(root.weatherDescription || "").toLowerCase().indexOf("thunder") >= 0
			|| String(root.weatherDescription || "").toLowerCase().indexOf("storm") >= 0

		// THE ORACLE.
		//
		// A scrying pane, read from the top down and centred, because that is
		// what somebody consulting an oracle is doing: the sky first, then the
		// bare fact, then the answer in its own hand, and the particulars
		// underneath for anyone who does not believe it.
		//
		// The sky is not an icon in a ring. It is drawn: the moon or the sun
		// where it actually stands tonight, the stars behind it, and cloud
		// across it if there is cloud. And what the weather *is* happens to the
		// pane itself — rain runs down the glass, a storm lights the whole
		// panel for an instant, and on a clear day the light in it warms.
		Item {
			id: weatherContent
			anchors.fill: parent

			// Rain on the glass. Only there when it is raining, and it falls in
			// front of everything including the writing, because it is on the
			// outside of the pane.
			ArcMotes {
				anchors.fill: parent
				anchors.margins: -20
				z: 20
				color: Arc.aetherAlt
				drifting: weatherPopup.raining
				density: parseFloat(String(root.weatherPrecipitation || "0")) > 1 ? 46 : 18
				drift: 190
				span: 2.0
				visible: weatherPopup.raining
			}

			// The flash. A storm lights the pane from outside, once, at random.
			Rectangle {
				id: lightning
				anchors.fill: parent
				anchors.margins: -20
				z: 19
				color: Arc.aetherAlt
				opacity: 0

				SequentialAnimation {
					id: strike
					NumberAnimation { target: lightning; property: "opacity"; to: 0.30; duration: 45 }
					NumberAnimation { target: lightning; property: "opacity"; to: 0.02; duration: 70 }
					NumberAnimation { target: lightning; property: "opacity"; to: 0.22; duration: 40 }
					NumberAnimation { target: lightning; property: "opacity"; to: 0; duration: 380; easing.type: Easing.OutCubic }
				}

				Timer {
					running: weatherPopup.storming && weatherPopup.visible
					repeat: true
					interval: 2600 + Math.random() * 5200
					onTriggered: {
						strike.restart();
						interval = 2600 + Math.random() * 5200;
					}
				}
			}

			Column {
				id: oracleColumn
				anchors.left: parent.left
				anchors.right: parent.right
				anchors.top: parent.top
				spacing: Arc.s3

				// The sky itself, drawn rather than fetched.
				Canvas {
					id: sky
					anchors.horizontalCenter: parent.horizontalCenter
					width: 150
					height: 116
					renderStrategy: Canvas.Cooperative

					readonly property string condition: String(root.weatherDescription || "").toLowerCase()
					readonly property bool day: {
						const rise = String(root.weatherSunrise || ""), set = String(root.weatherSunset || "");
						if (!/^\d{1,2}:\d{2}$/.test(rise) || !/^\d{1,2}:\d{2}$/.test(set)) return true;
						const minutes = value => Number(value.split(":")[0]) * 60 + Number(value.split(":")[1]);
						const now = root.now.getHours() * 60 + root.now.getMinutes();
						return now >= minutes(rise) && now <= minutes(set);
					}
					readonly property real phase: Arc.moonPhase(root.now).fraction

					onConditionChanged: requestPaint()
					onDayChanged: requestPaint()

					onPaint: {
						const ctx = getContext("2d");
						ctx.reset();
						const cx = width / 2, cy = height * 0.42;
						const clouded = sky.condition.indexOf("cloud") >= 0
							|| sky.condition.indexOf("overcast") >= 0
							|| sky.condition.indexOf("rain") >= 0
							|| sky.condition.indexOf("thunder") >= 0;

						// the field of stars behind it, always there
						let state = 20250920;
						const random = function () {
							state = (state * 48271) % 2147483647;
							return (state - 1) / 2147483646;
						};
						for (let index = 0; index < 26; index++) {
							const x = random() * width, y = random() * height * 0.8;
							Ink.mote(ctx, x, y, 0.5 + random() * 0.9,
								Qt.alpha(Arc.gold, 0.16 + random() * 0.4));
						}

						if (sky.day) {
							// the sun: a disc with a ring of rays
							Ink.ring(ctx, cx, cy, 20, 2.0, Arc.ember, 1);
							for (let ray = 0; ray < 12; ray++) {
								const angle = ray * Math.PI / 6;
								Ink.ley(ctx, cx + Math.cos(angle) * 26, cy + Math.sin(angle) * 26,
									cx + Math.cos(angle) * 33, cy + Math.sin(angle) * 33,
									Arc.ruleThin * 1.4, Qt.alpha(Arc.ember, 0.7), null, -1);
							}
						} else {
							// the moon, at the phase it actually stands at
							const r = 21;
							const waxing = sky.phase < 0.5;
							const sweep = Math.cos(sky.phase * Math.PI * 2);
							ctx.fillStyle = Arc.gold;
							ctx.beginPath();
							ctx.arc(cx, cy, r, waxing ? -Math.PI / 2 : Math.PI / 2,
								waxing ? Math.PI / 2 : Math.PI * 1.5);
							ctx.closePath();
							ctx.fill();
							ctx.globalCompositeOperation = sweep > 0 ? "destination-out" : "source-over";
							ctx.beginPath();
							ctx.ellipse(cx - Math.abs(sweep) * r, cy - r, Math.abs(sweep) * r * 2, r * 2);
							ctx.fill();
							ctx.globalCompositeOperation = "source-over";
							Ink.ring(ctx, cx, cy, r, Arc.ruleThin, Qt.alpha(Arc.gold, 0.4), 1);
						}

						if (!clouded) return;
						// cloud across it: three arcs of one bank
						ctx.fillStyle = Qt.alpha(Arc.inkFaint, 0.55);
						for (const puff of [{ x: -26, y: 16, r: 15 }, { x: -4, y: 9, r: 21 },
							{ x: 22, y: 16, r: 16 }, { x: 2, y: 22, r: 18 }]) {
							ctx.beginPath();
							ctx.ellipse(cx + puff.x - puff.r, cy + puff.y - puff.r, puff.r * 2, puff.r * 2);
							ctx.fill();
						}
					}
				}

				// The bare fact.
				Row {
					anchors.horizontalCenter: parent.horizontalCenter
					spacing: Arc.s3

					ArcText {
						anchors.verticalCenter: parent.verticalCenter
						role: "display"
						font.pixelSize: 34
						text: root.weatherTemperature
					}

					Rectangle {
						anchors.verticalCenter: parent.verticalCenter
						width: 4
						height: 4
						radius: 2
						color: Arc.goldDim
					}

					ArcText {
						anchors.verticalCenter: parent.verticalCenter
						role: "display"
						font.pixelSize: 22
						tone: "muted"
						text: root.weatherCity
					}
				}

				// The answer, in the oracle's own hand.
				ArcText {
					width: parent.width
					horizontalAlignment: Text.AlignHCenter
					role: "hand"
					tone: "aether"
					font.pixelSize: 18
					wrapMode: Text.WordWrap
					text: `“${root.oracleLine}”`
				}

			// The particulars, for anyone who does not take the oracle's word
				// for it. Name on the left, reading on the right, a ley between.
					Column {
						width: parent.width
						spacing: Arc.s1

					Repeater {
						model: [
							{ label: "Wind", value: root.weatherWind },
							{ label: "Aether", value: root.weatherDescription },
							{ label: "Humour", value: root.weatherHumidity },
							{ label: "Fall", value: root.weatherPrecipitation },
							{ label: "Weight", value: root.weatherPressure },
							{ label: "Seen", value: root.weatherObservationTime !== "" ? Qt.formatDateTime(new Date(root.weatherObservationTime), "HH:mm") : "--" }
						]

						delegate: Item {
							required property var modelData
							width: parent.width
							height: 24

							ArcText {
								id: readingName
								anchors.left: parent.left
								anchors.verticalCenter: parent.verticalCenter
								role: "label"
								tone: "faint"
								text: modelData.label
							}

							Rectangle {
								anchors.left: readingName.right
								anchors.right: readingValue.left
								anchors.leftMargin: Arc.s3
								anchors.rightMargin: Arc.s3
								anchors.verticalCenter: parent.verticalCenter
								height: Arc.ruleThin
								color: Arc.goldGhost
								visible: width > 8
							}

							ArcText {
								id: readingValue
								anchors.right: parent.right
								anchors.verticalCenter: parent.verticalCenter
								width: Math.min(implicitWidth, parent.width * 0.5)
								horizontalAlignment: Text.AlignRight
								role: "bodyStrong"
								text: modelData.value
							}
						}
					}
				}

					// The sun's passage, and where in it we are.
					Item {
						id: sunRun
						width: parent.width
						height: 44

					ArcText {
						id: riseLabel
						anchors.left: parent.left
						anchors.bottom: parent.bottom
						role: "label"
						tone: "faint"
						text: root.weatherSunrise
					}

					ArcText {
						id: setLabel
						anchors.right: parent.right
						anchors.bottom: parent.bottom
						role: "label"
						tone: "faint"
						text: root.weatherSunset
					}

					Canvas {
						id: passage
						anchors.left: riseLabel.right
						anchors.right: setLabel.left
						anchors.leftMargin: Arc.s3
						anchors.rightMargin: Arc.s3
						anchors.bottom: parent.bottom
						anchors.bottomMargin: 2
						height: 30
						renderStrategy: Canvas.Cooperative

						readonly property real through: {
							const rise = String(root.weatherSunrise || ""), set = String(root.weatherSunset || "");
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
							if (width < 24) return;
							const path = [];
							for (let index = 0; index <= 28; index++) {
								const t = index / 28;
								path.push({ x: t * width, y: height - Math.sin(t * Math.PI) * (height - 5) });
							}
							Ink.cut(ctx, path, Arc.ruleThin, Qt.alpha(Arc.gold, 0.34), false);
							if (passage.through < 0) return;
							const at = path[Math.round(passage.through * 28)];
							Ink.mote(ctx, at.x, at.y, 3.4, Arc.ember);
						}
					}
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

			// THE PERCH.
			//
			// The notes that have come in are not a stack of cards. They hang
			// from a perch across the head of the panel, each on its own cord,
			// with the bird that brought them sitting at the end of it — so the
			// panel reads as a rookery rather than as an inbox.
			Item {
				Layout.fillWidth: true
				Layout.preferredHeight: 38

				Rectangle {
					id: perchLine
					anchors.left: parent.left
					anchors.right: parent.right
					anchors.bottom: parent.bottom
					height: Arc.ruleThin
					color: Qt.alpha(Arc.gold, 0.45)
				}

				ArcMark {
					id: perchedRaven
					anchors.right: parent.right
					anchors.rightMargin: Arc.s4
					anchors.bottom: perchLine.top
					width: 30
					height: 26
					glyph: "raven"
					lineColor: root.notificationGroups.length > 0 ? Arc.aether : Arc.goldDim
				}

				ArcHalo {
					anchors.centerIn: perchedRaven
					width: 80
					height: 80
					color: Arc.aether
					strength: 0.26
					spread: 0.32
					flicker: true
					visible: root.notificationGroups.length > 0
				}

				ArcText {
					id: notifTitle
					anchors.left: parent.left
					anchors.bottom: perchLine.top
					anchors.bottomMargin: 3
					role: "hand"
					tone: "muted"
					font.pixelSize: 15
					text: root.notificationGroups.length === 0
						? "no birds today"
						: root.notificationGroups.length === 1
							? "one bird came"
							: `${root.notificationGroups.length} birds came`
				}

				ArcText {
					id: purgeLabel
					anchors.right: perchedRaven.left
					anchors.rightMargin: Arc.s4
					anchors.bottom: perchLine.top
					anchors.bottomMargin: 4
					visible: root.notificationGroups.length > 0
					role: "label"
					tone: purgeTouch.containsMouse ? "alert" : "faint"
					text: "Let them go"

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
						lineColor: Arc.goldGhost
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
								washBottom: Arc.veil1
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
											width: Arc.mote * 2
											height: Arc.mote * 2
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
												lineColor: Arc.goldFaint
												liveColor: notificationCard.urgencyColor
												fillTop: Arc.depth
												fillBottom: Arc.depth
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
											lineColor: foldTouch.containsMouse ? Qt.alpha(Arc.aether, 0.6) : Arc.goldGhost
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
															color: Arc.goldGhost
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

	// THE MESSENGER RAVENS.
	//
	// A notification is not a card that fades up in a corner. A bird comes in
	// across the screen, beating, and settles on a perch above the horizon
	// beside the sigil that took the message; the note it carried is then
	// conjured under it, rising out of the perch the way everything in this
	// sanctum rises. Dismissing it lets the note fall back and the bird goes
	// the way it came.
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

			// Two movements, in order: the bird arrives, and only then is the
			// note conjured. Never one fade for both.
			readonly property real flight: Math.max(0, Math.min(1, revealProgress / 0.42))
			readonly property real risen: Math.max(0, Math.min(1, (revealProgress - 0.30) / 0.70))
			readonly property real perch: 40
			readonly property real approach: 120

			visible: true
			color: "transparent"

			// A message lands beside the sigil that took it, above the horizon,
			// and the ones behind it queue upward from there.
			anchor {
				window: barWindow
				edges: Edges.Right | Edges.Top
				gravity: Edges.Right | Edges.Top
				adjustment: PopupAdjustment.SlideX | PopupAdjustment.SlideY

				onAnchoring: {
					const mark = notifNode.mapToItem(null, notifNode.width / 2, 0);
					const centre = mark ? mark.x : barWindow.width - 260;
					anchor.rect.x = Math.round(centre - toastWindow.implicitWidth + 80);
					anchor.rect.width = 0;
					anchor.rect.y = -Math.round(Arc.s3)
						- index * (toastWindow.implicitHeight + 10);
					anchor.rect.height = 0;
				}
			}

			implicitWidth: 400 + toastWindow.approach
			implicitHeight: toastWindow.perch + toastCard.implicitHeight + 8

			NumberAnimation on revealProgress {
				from: 0
				to: 1
				duration: Arc.conjure
				easing.type: Easing.Bezier
				easing.bezierCurve: Arc.curveRise
			}

			// The perch the bird lands on.
			Rectangle {
				x: 56
				y: toastWindow.perch
				width: (toastWindow.implicitWidth - 56) * Math.min(1, toastWindow.flight * 1.4)
				height: Arc.ruleThin
				color: Qt.alpha(toastWindow.urgencyColor, 0.5)
				visible: !toastWindow.dismissing
			}

			// The bird. It comes in across the screen, beating, and stops dead
			// when it has something to stand on.
			Item {
				id: raven

				property real beat: 0

				width: 34
				height: 30
				x: toastWindow.implicitWidth - 86 + (1 - toastWindow.flight) * toastWindow.approach * 1.8
				y: toastWindow.perch - height + 2 - (1 - toastWindow.flight) * 46
				opacity: toastWindow.dismissing ? 0 : Math.min(1, toastWindow.flight * 3)
				rotation: (1 - toastWindow.flight) * -20

				Behavior on opacity {
					NumberAnimation { duration: Arc.recoil }
				}

				SequentialAnimation on beat {
					running: toastWindow.flight < 1 && !toastWindow.dismissing
					loops: Animation.Infinite
					NumberAnimation { to: 1; duration: 90; easing.type: Easing.OutQuad }
					NumberAnimation { to: 0; duration: 130; easing.type: Easing.InQuad }
				}

				transform: Scale {
					origin.x: raven.width / 2
					origin.y: raven.height
					yScale: toastWindow.flight < 1 ? 0.5 + raven.beat * 0.75 : 1
				}

				ArcHalo {
					anchors.centerIn: parent
					width: 90
					height: 90
					color: toastWindow.urgencyColor
					strength: 0.3
					spread: 0.34
					flicker: true
				}

				ArcMark {
					anchors.fill: parent
					glyph: "raven"
					lineColor: toastWindow.urgencyColor
				}
			}

			// The note, conjured out of the perch. Clipped from the top so it
			// is revealed upward, the same as every panel in the shell.
			Item {
				id: noteWindow

				x: toastWindow.approach
				y: toastWindow.perch + 4
				width: 400
				height: toastCard.implicitHeight
				clip: true
				opacity: toastWindow.dismissing ? 0 : Math.min(1, toastWindow.risen * 1.5)

				Behavior on opacity {
					NumberAnimation { duration: Arc.dispel }
				}

			ArcLeaf {
				id: toastCard

				implicitWidth: 400
				implicitHeight: toastContent.implicitHeight + Arc.s5 * 2
				width: implicitWidth
				height: implicitHeight
				x: 0
				y: Math.round(-(1 - toastWindow.risen) * 24)
				variant: "plate"
				crest: false
				lineColor: Qt.alpha(toastWindow.urgencyColor, 0.7)
				liveColor: toastWindow.urgencyColor
				washTop: Qt.alpha(Arc.veil2, 1)
				washBottom: Arc.hazeDeep
				haloStrength: 0.20
				intensity: 0.5
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
							width: Arc.mote * 2
							height: Arc.mote * 2
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
								lineColor: Arc.goldFaint
								liveColor: toastWindow.urgencyColor
								fillTop: Arc.depth
								fillBottom: Arc.depth
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
