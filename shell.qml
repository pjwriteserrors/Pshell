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
	readonly property color secondaryBoxColor: Bio.tissue2
	readonly property color secondaryBoxStrongColor: Bio.tissue3
	readonly property color secondaryInsetColor: Bio.cavity
	readonly property color surface: Bio.tissue1
	readonly property color surfaceBorder: Bio.boneDim
	readonly property color onPrimary: Bio.onOrgan
	readonly property color danger: Bio.necrosis
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

	function studioPageOrDefault(page) {
		const name = String(page || "");
		return [ "wallpaper", "motion", "styles" ].indexOf(name) >= 0 ? name : "wallpaper";
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
			trayMenuCloseTimer.stop();
			root.trayMenuOpen = false;
			root.trayMenuVisible = false;
			root.trayMenuHandle = null;
			root.trayMenuTargetItem = null;

			Qt.callLater(function() {
				root.trayMenuHandle = handle;
				root.trayMenuTargetItem = targetItem;
				root.trayMenuVisible = true;

				Qt.callLater(function() {
					root.trayMenuOpen = true;
				});
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

	readonly property color background: Bio.carapace
	readonly property color foreground: Bio.text
	readonly property color primary: Bio.organ
	readonly property color secondary: Bio.organAlt
	readonly property color accent: Bio.organAlt
	readonly property color tertiary: Bio.organThird
	readonly property color border: Bio.boneFaint

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
			Bio.colorsFile.reload();
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

	// The reflex: what the desktop does when a key changes the volume or the
	// brightness. It surfaces low and centred, over the work rather than over
	// the spine, and it is a reading — a ring that fills — not a slider.
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

		BioSurface {
			id: osdCard
			width: 296
			height: 92
			x: Math.round((parent.width - width) / 2)
			y: Math.round(parent.height - height - 140)
			washTop: Bio.membrane
			washBottom: Bio.membraneDeep
			haloStrength: 0.34
			intensity: 0.75
			opacity: root.osdVisible ? 1 : 0

			transform: Scale {
				origin.x: osdCard.width / 2
				origin.y: osdCard.height / 2
				xScale: root.osdVisible ? 1 : 0.94
				yScale: root.osdVisible ? 1 : 0.7

				Behavior on yScale {
					NumberAnimation { duration: Bio.grow; easing.type: Easing.OutBack; easing.overshoot: 1.2 }
				}
				Behavior on xScale {
					NumberAnimation { duration: Bio.grow; easing.type: Easing.OutCubic }
				}
			}

			Behavior on opacity {
				NumberAnimation { duration: Bio.twitch }
			}

			BioRing {
				id: osdRing
				anchors.left: parent.left
				anchors.verticalCenter: parent.verticalCenter
				width: 46
				height: 46
				seed: 2
				intensity: 0.5
				progress: Math.min(1, Math.max(0, root.osdProgress))

				Image {
					anchors.centerIn: parent
					width: 18
					height: 18
					source: root.osdIconSource
					fillMode: Image.PreserveAspectFit
					smooth: true
					mipmap: true
					layer.enabled: visible
					layer.effect: MultiEffect {
						colorization: 1
						colorizationColor: Bio.organ
					}
				}
			}

			Column {
				anchors.left: osdRing.right
				anchors.leftMargin: Bio.s4
				anchors.right: parent.right
				anchors.verticalCenter: parent.verticalCenter
				spacing: Bio.s2

				BioText {
					width: parent.width
					role: "label"
					tone: "muted"
					text: root.osdLabel
				}

				BioText {
					role: "reading"
					tone: "default"
					text: root.osdValueText
				}
			}
		}
	}

	// The spine.
	//
	// Not a bar: nothing is docked in a strip of chrome. The organs sit loose on
	// the wallpaper at the top of the screen, a tendon runs from each cluster to
	// the specimen plate in the middle, and the plate hangs a little below the
	// line everything else is aligned to. The plate is the only thing with a
	// membrane behind it — everything else is a ring with a hole in the middle.
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

		// Only the line the organs sit on is reserved; the specimen plate hangs
		// into the workspace below it, over whatever is there.
		exclusiveZone: Math.round(bar.y + Bio.spine)
		implicitHeight: Math.round(bar.y + bar.height)
		color: "transparent"
		mask: Region {
			x: bar.x
			y: bar.y
			width: bar.width
			height: bar.height
		}

		Item {
			id: bar
			anchors.left: parent.left
			anchors.right: parent.right
			anchors.top: parent.top
			anchors.leftMargin: Bio.s5
			anchors.rightMargin: Bio.s5
			anchors.topMargin: Bio.s2
			height: Bio.spine + specimenPlate.overhang

			// Everything but the specimen plate is centred on this line.
			readonly property real line: Bio.spine / 2

			// The carapace edge: the screen's own rim darkening under the spine.
			// Without it the bone lines vanish wherever the wallpaper is pale,
			// and the organs have nothing to sit against.
			Rectangle {
				anchors.left: parent.left
				anchors.right: parent.right
				anchors.top: parent.top
				anchors.topMargin: -bar.anchors.topMargin
				anchors.leftMargin: -Bio.s5
				anchors.rightMargin: -Bio.s5
				height: Bio.spine + Bio.s5
				gradient: Gradient {
					GradientStop { position: 0.0; color: Qt.alpha(Bio.cavity, 0.92) }
					GradientStop { position: 0.62; color: Qt.alpha(Bio.cavity, 0.66) }
					GradientStop { position: 1.0; color: "transparent" }
				}
			}

			Row {
				id: leftCluster
				anchors.left: parent.left
				y: bar.line - height / 2
				spacing: Bio.s3

				BioNode {
					id: launcherNode
					anchors.verticalCenter: parent.verticalCenter
					seed: 0
					lit: root.launcherPopupOpen
					onClicked: root.toggleLauncherPopup()

					BioSigil {
						anchors.centerIn: parent
						width: parent.width * 0.64
						height: parent.height * 0.64
						seed: 7
						detail: 0.6
						weight: Bio.ribThin
						lineColor: launcherNode.lit ? Bio.organ : Bio.text
					}
				}

				Row {
					id: trayRow
					anchors.verticalCenter: parent.verticalCenter
					spacing: Bio.s2
					visible: trayRepeater.count > 0

					Repeater {
						id: trayRepeater
						model: ScriptModel {
							values: SystemTray.items.values
						}

						BioNode {
							id: trayNode

							required property SystemTrayItem modelData
							required property int index

							anchors.verticalCenter: parent?.verticalCenter ?? undefined
							size: 26
							seed: trayNode.index + 1
							acceptedButtons: Qt.LeftButton | Qt.RightButton

							Image {
								anchors.centerIn: parent
								width: 14
								height: 14
								source: root.resolveIconSource(root.trayIconSource(trayNode.modelData.icon))
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

				NiriTaskbar {
					id: taskbarIsland
					anchors.verticalCenter: parent.verticalCenter
					visible: niriState.tasksForOutput(String(barWindow.screen?.name || "")).length > 0
					height: Bio.spine
					niriState: niriState
					outputName: String(barWindow.screen?.name || "")
					background: Bio.tissue1
					foreground: Bio.text
					secondaryBoxColor: Bio.tissue2
					secondaryBoxStrongColor: Bio.tissue3
				}

				NowPlaying {
					id: nowPlayingIsland
					anchors.verticalCenter: parent.verticalCenter
					height: Bio.spine
					foreground: Bio.text
					secondaryBoxColor: Bio.tissue1
					progressColor: Bio.organ
					onClicked: root.toggleMediaPopup()
				}
			}

			// The tendons. They run from each cluster to the plate and are the
			// reason the spine reads as one organism instead of two toolbars
			// with a clock between them.
			BioTendon {
				anchors.left: leftCluster.right
				anchors.right: specimenPlate.left
				anchors.leftMargin: Bio.s4
				anchors.rightMargin: Bio.s3
				y: bar.line - height / 2
				height: 16
				facing: Qt.LeftToRight
				sag: 2
				weight: Bio.rib * 1.15
				lineColor: Bio.boneDim
				visible: width > 40
			}

			BioTendon {
				anchors.left: specimenPlate.right
				anchors.right: rightCluster.left
				anchors.leftMargin: Bio.s3
				anchors.rightMargin: Bio.s4
				y: bar.line - height / 2
				height: 16
				facing: Qt.RightToLeft
				sag: 2
				weight: Bio.rib * 1.15
				lineColor: Bio.boneDim
				visible: width > 40
			}

			// The specimen plate: the one chamber on the spine. It hangs below
			// the line so the middle of the screen has a shape, and it carries
			// the time and the date.
			BioSurface {
				id: specimenPlate

				readonly property real overhang: 18

				anchors.horizontalCenter: parent.horizontalCenter
				y: 0
				width: Math.max(168, specimenColumn.implicitWidth + 64)
				height: Bio.spine + overhang
				washTop: Bio.membrane
				washBottom: Bio.membraneDeep
				haloStrength: 0.18
				intensity: Math.max(plateTouch.live, root.clockPopupOpen ? 0.5 : 0)
				padding: 0

				Column {
					id: specimenColumn
					anchors.centerIn: parent
					spacing: -2

					BioText {
						anchors.horizontalCenter: parent.horizontalCenter
						role: "specimen"
						font.pixelSize: 24
						text: Qt.formatDateTime(root.now, "HH:mm")
					}

					BioText {
						anchors.horizontalCenter: parent.horizontalCenter
						role: "label"
						tone: "muted"
						font.pixelSize: 9
						text: Qt.formatDateTime(root.now, "ddd dd MMM")
					}
				}

				BioTouch {
					id: plateTouch
					onClicked: root.toggleClockPopup()
				}
			}

			Timer {
				running: true
				repeat: true
				interval: 1000
				onTriggered: root.now = new Date()
			}

			Row {
				id: rightCluster
				anchors.right: parent.right
				y: bar.line - height / 2
				spacing: Bio.s3

				Row {
					anchors.verticalCenter: parent.verticalCenter
					spacing: Bio.s2

					BioNode {
						id: weatherNode
						anchors.verticalCenter: parent.verticalCenter
						size: 26
						seed: 3
						lit: root.weatherPopupOpen
						iconSource: root.resolveIconSource("", [
							root.weatherIcon,
							root.weatherIcon.replace("-symbolic", ""),
							"weather-overcast-symbolic"
						])
						iconSize: 13
						onClicked: root.toggleWeatherPopup()
					}

					BioText {
						anchors.verticalCenter: parent.verticalCenter
						role: "reading"
						font.pixelSize: 14
						text: root.weatherTemperature
					}
				}

				BioNode {
					id: notifNode
					anchors.verticalCenter: parent.verticalCenter
					seed: 1
					lit: root.notifPopupOpen
					badge: root.notificationGroups.length > 0 ? String(root.notificationGroups.length) : ""
					iconSource: root.resolveIconSource("preferences-system-notifications-symbolic", ["dialog-information-symbolic"])
					onClicked: root.toggleNotifPopup()
				}

				BioNode {
					id: clipboardNode
					anchors.verticalCenter: parent.verticalCenter
					seed: 2
					lit: root.clipboardPopupOpen
					iconSource: root.resolveIconSource("edit-paste-symbolic", ["edit-copy-symbolic"])
					onClicked: root.toggleClipboardPopup()
				}

				BioNode {
					id: bluetoothNode
					anchors.verticalCenter: parent.verticalCenter
					seed: 3
					lit: root.bluetoothPopupOpen
					iconSource: root.resolveIconSource("bluetooth-active-symbolic", ["bluetooth-symbolic"])
					onClicked: root.toggleBluetoothPopup()
				}

				BioNode {
					id: networkNode
					anchors.verticalCenter: parent.verticalCenter
					seed: 0
					lit: root.networkPopupOpen
					iconSource: root.networkStatusType === "ethernet"
						? Bio.icon("network-wired-symbolic")
						: Bio.icon("network-wireless-signal-excellent-symbolic")
					onClicked: root.toggleNetworkPopup()
				}

				TopBarResourceBars {
					id: resourceBars
					anchors.verticalCenter: parent.verticalCenter
					height: Bio.spine
					lit: root.resourcesPopupOpen
					onClicked: root.toggleResourcesPopup()
				}

				BioNode {
					id: powerNode
					anchors.verticalCenter: parent.verticalCenter
					seed: 2
					lit: root.powerPopupOpen
					ringColor: Qt.alpha(Bio.necrosis, 0.45)
					liveColor: Bio.necrosis
					iconColor: powerNode.lit ? Bio.necrosis : Qt.alpha(Bio.necrosis, 0.85)
					iconSource: Bio.icon("system-shutdown-symbolic")
					onClicked: root.togglePowerPopup()
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
		screen: root.activePopupScreen

		onDismissRequested: root.closeClipboardPopup()
		open: root.clipboardPopupOpen
		visible: root.clipboardPopupVisible
		barItem: bar
		anchorWindow: barWindow
		anchorMode: "right"
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
							height: 28

							Row {
								anchors.left: parent.left
								anchors.verticalCenter: parent.verticalCenter
								spacing: 8

								BioText {
									role: "heading"
									anchors.verticalCenter: parent.verticalCenter
									color: foreground
									font.pixelSize: 15
									font.weight: Font.DemiBold
									text: "Clipboard"
								}

								ThemedRectangle {
									anchors.verticalCenter: parent.verticalCenter
									width: Math.max(22, clipCountLabel.implicitWidth + 12)
									height: 19
									radius: ThemeEngine.radiusMedium
									color: Qt.alpha(root.primary, 0.3)

									BioText {
										role: "label"
										id: clipCountLabel
										anchors.centerIn: parent
										color: foreground
										font.pixelSize: 10
										font.weight: Font.DemiBold
										text: clipboardPopupContent.entries.length
									}
								}
							}

							ThemedRectangle {
								anchors.right: parent.right
								anchors.verticalCenter: parent.verticalCenter
								visible: clipboardPopupContent.entries.length > 0
								width: clipWipeLabel.implicitWidth + 22
								height: 25
								radius: ThemeEngine.radiusMedium
								color: root.secondaryBoxColor

								BioText {
									role: "label"
									id: clipWipeLabel
									anchors.centerIn: parent
									color: foreground
									font.pixelSize: 10
									font.weight: Font.Medium
									text: "Clear all"
								}

								HoverLayer {
									tint: root.danger
									onClicked: {
										Quickshell.execDetached(["sh", "-lc", "cliphist wipe"]);
										clipboardPopupContent.entries = [];
									}
								}
							}
						}

						ThemedRectangle {
							width: parent.width
							height: 38
							themeStyle: "inset"
							radius: ThemeEngine.radiusMedium
							color: root.secondaryBoxColor
							border.width: clipboardSearch.activeFocus ? 1 : 0
							border.color: Qt.alpha(root.primary, 0.6)

							QQCImpl.IconImage {
								id: clipSearchIcon
								anchors.left: parent.left
								anchors.leftMargin: 14
								anchors.verticalCenter: parent.verticalCenter
								width: 14
								height: 14
								source: "/usr/share/icons/Adwaita/symbolic/actions/edit-find-symbolic.svg"
								sourceSize: Qt.size(width, height)
								color: Qt.alpha(root.foreground, 0.55)
							}

							TextField {
								id: clipboardSearch
								anchors.fill: parent
								anchors.leftMargin: 36
								anchors.rightMargin: 14
								color: foreground
								placeholderText: "Search clipboard"
								placeholderTextColor: Qt.alpha(foreground, 0.45)
								selectedTextColor: foreground
								selectionColor: root.accent
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

							BioText {
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

								delegate: ThemedRectangle {
									id: clipEntry
									required property var modelData
									required property int index
									readonly property bool selected: index === clipboardPopupContent.selectedIndex

									width: ListView.view.width
									height: modelData.isImage ? 110 : 46
									radius: ThemeEngine.radiusMedium
									color: selected ? Qt.alpha(root.primary, 0.26) : root.secondaryBoxColor
									border.width: selected ? 1 : 0
									border.color: Qt.alpha(root.primary, 0.55)

									Behavior on color {
										CAnim {}
									}

									Component.onCompleted: {
										if (!modelData.isImage) return;
										imagePreviewProcess.running = true;
									}

									HoverLayer {
										id: clipEntryHover
										tint: root.foreground
										showHover: false
										onEntered: clipboardPopupContent.selectedIndex = index
										onClicked: clipboardPopupContent.selectEntry(clipEntry.modelData)
									}

									ThemedRectangle {
										visible: clipEntry.modelData.isImage
										anchors.left: parent.left
										anchors.top: parent.top
										anchors.margins: 8
										width: 30
										height: 16
										radius: ThemeEngine.radiusLarge
										color: Qt.alpha(root.secondary, 0.35)

										BioText {
											role: "label"
											anchors.centerIn: parent
											color: foreground
											font.pixelSize: 8
											font.weight: Font.DemiBold
											text: clipEntry.modelData.extension.toUpperCase()
										}
									}

									Image {
										id: imagePreview
										visible: clipEntry.modelData.isImage && clipEntry.modelData.previewPath !== ""
										anchors.centerIn: parent
										width: 90
										height: 90
										source: ""
										fillMode: Image.PreserveAspectCrop
										smooth: true
										mipmap: true
										cache: false
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

									BioText {
										role: "caption"
										visible: !clipEntry.modelData.isImage
										anchors.left: parent.left
										anchors.leftMargin: 14
										anchors.right: deleteButton.left
										anchors.rightMargin: 8
										anchors.verticalCenter: parent.verticalCenter
										color: foreground
										font.pixelSize: 11
										elide: Text.ElideRight
										maximumLineCount: 1
										text: clipEntry.modelData.preview
									}

									ThemedRectangle {
										id: deleteButton
										anchors.right: parent.right
										anchors.rightMargin: 8
										anchors.verticalCenter: parent.verticalCenter
										width: 24
										height: 24
										radius: ThemeEngine.radiusMedium
										color: Qt.alpha(root.danger, deleteHover.containsMouse ? 0.4 : 0.16)
										opacity: clipEntryHover.containsMouse || deleteHover.containsMouse || clipEntry.selected ? 1 : 0

										Behavior on opacity {
											Anim {
												duration: Motion.fast
											}
										}

										Behavior on color {
											CAnim {}
										}

										BioText {
											role: "caption"
											anchors.centerIn: parent
											color: foreground
											font.pixelSize: 11
											font.weight: Font.DemiBold
											text: "\u00d7"
										}

										HoverLayer {
											id: deleteHover
											tint: root.danger
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
		screen: root.activePopupScreen

		onDismissRequested: root.closeBluetoothPopup()
		open: root.bluetoothPopupOpen
		visible: root.bluetoothPopupVisible
		barItem: bar
		anchorWindow: barWindow
		anchorMode: "right"
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
							height: 30

							BioText {
								role: "heading"
								anchors.left: parent.left
								anchors.verticalCenter: parent.verticalCenter
								color: foreground
								font.pixelSize: 15
								font.weight: Font.DemiBold
								text: "Bluetooth"
							}

							ThemedRectangle {
								id: btSwitch
								themeStyle: "inset"
								anchors.right: parent.right
								anchors.verticalCenter: parent.verticalCenter
								width: 44
								height: 24
								radius: height / 2
								color: bluetoothPopup.powered ? root.primary : root.secondaryInsetColor

								Behavior on color {
									CAnim {
										duration: Motion.normal
									}
								}

								ThemedRectangle {
									themeStyle: "raised"
									width: 18
									height: 18
									radius: height / 2
									anchors.verticalCenter: parent.verticalCenter
									x: bluetoothPopup.powered ? parent.width - width - 3 : 3
									color: bluetoothPopup.powered ? root.onPrimary : Qt.alpha(root.foreground, 0.7)

									Behavior on x {
										SpatialAnim {}
									}

									Behavior on color {
										CAnim {
											duration: Motion.normal
										}
									}
								}

								HoverLayer {
									tint: root.foreground
									showHover: false
									onClicked: bluetoothPopup.togglePower()
								}
							}
						}

						ThemedRectangle {
							width: parent.width
							height: 32
							radius: ThemeEngine.radiusMedium
							color: bluetoothPopup.scanning ? Qt.alpha(root.primary, 0.3) : root.secondaryBoxColor
							visible: bluetoothPopup.powered

							Behavior on color {
								CAnim {}
							}

							Row {
								anchors.centerIn: parent
								spacing: 8

								QQCImpl.IconImage {
									id: scanIcon
									anchors.verticalCenter: parent.verticalCenter
									width: 13
									height: 13
									source: "/usr/share/icons/Adwaita/symbolic/actions/view-refresh-symbolic.svg"
									sourceSize: Qt.size(width, height)
									color: root.foreground

									RotationAnimator on rotation {
										running: bluetoothPopup.scanning
										loops: Animation.Infinite
										from: 0
										to: 360
										duration: ThemeEngine.duration(1100)
									}
								}

								BioText {
									role: "body"
									anchors.verticalCenter: parent.verticalCenter
									color: foreground
									font.pixelSize: 12
									font.weight: Font.Medium
									text: bluetoothPopup.scanning ? "Scanning for devices..." : "Scan for devices"
								}
							}

							HoverLayer {
								tint: root.primary
								onClicked: bluetoothPopup.startScan()
							}
						}

						Item {
							width: parent.width
							implicitHeight: bluetoothPopup.powered ? 250 : 64

							Column {
								visible: !bluetoothPopup.powered
								anchors.centerIn: parent
								spacing: 6

								QQCImpl.IconImage {
									anchors.horizontalCenter: parent.horizontalCenter
									width: 26
									height: 26
									source: "/usr/share/icons/Adwaita/symbolic/status/bluetooth-disabled-symbolic.svg"
									sourceSize: Qt.size(width, height)
									color: Qt.alpha(root.foreground, 0.35)
								}

								BioText {
									role: "body"
									anchors.horizontalCenter: parent.horizontalCenter
									color: Qt.alpha(foreground, 0.5)
									font.pixelSize: 12
									text: "Bluetooth is off"
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

								header: Text {
									visible: bluetoothPopup.devices.length === 0
									width: ListView.view ? ListView.view.width : 0
									height: visible ? 30 : 0
									horizontalAlignment: Text.AlignHCenter
									verticalAlignment: Text.AlignVCenter
									color: Qt.alpha(foreground, 0.5)
									font.pixelSize: 11
									text: "No devices found yet"
								}

								delegate: ThemedRectangle {
									id: btDevice
									required property var modelData
									readonly property string deviceIcon: {
										const n = String(modelData.name || "").toLowerCase();
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
									height: 52
									radius: ThemeEngine.radiusMedium
									color: modelData.connected ? Qt.alpha(root.primary, 0.26) : root.secondaryBoxColor
									border.width: modelData.connected ? 1 : 0
									border.color: Qt.alpha(root.primary, 0.55)

									Behavior on color {
										CAnim {}
									}

									HoverLayer {
										tint: root.foreground
										onClicked: bluetoothPopup.connectDevice(btDevice.modelData.address)
									}

									Row {
										anchors.left: parent.left
										anchors.leftMargin: 10
										anchors.right: btBatteryChip.visible ? btBatteryChip.left : parent.right
										anchors.rightMargin: 10
										anchors.verticalCenter: parent.verticalCenter
										spacing: 10

										ThemedRectangle {
											width: 32
											height: 32
											radius: ThemeEngine.radiusMedium
											anchors.verticalCenter: parent.verticalCenter
											color: btDevice.modelData.connected ? Qt.alpha(root.primary, 0.45) : root.secondaryInsetColor

											QQCImpl.IconImage {
												anchors.centerIn: parent
												width: 15
												height: 15
												source: btDevice.deviceIcon
												sourceSize: Qt.size(width, height)
												color: root.foreground
											}
										}

										Column {
											anchors.verticalCenter: parent.verticalCenter
											spacing: 2
											width: parent.width - 42

											BioText {
												role: "body"
												width: parent.width
												color: foreground
												font.pixelSize: 12
												font.weight: Font.Medium
												elide: Text.ElideRight
												text: btDevice.modelData.name
											}

											BioText {
												role: "label"
												width: parent.width
												color: Qt.alpha(foreground, 0.58)
												font.pixelSize: 10
												elide: Text.ElideRight
												text: bluetoothPopup.deviceStatuses[btDevice.modelData.address]
													|| (btDevice.modelData.connected ? "Connected" : (btDevice.modelData.paired ? "Paired" : "Available"))
											}
										}
									}

									ThemedRectangle {
										id: btBatteryChip
										visible: btDevice.modelData.connected && String(btDevice.modelData.battery || "") !== ""
										anchors.right: parent.right
										anchors.rightMargin: 10
										anchors.verticalCenter: parent.verticalCenter
										width: batteryText.implicitWidth + 14
										height: 20
										radius: ThemeEngine.radiusMedium
										color: Qt.alpha(root.secondary, 0.3)

										BioText {
											role: "label"
											id: batteryText
											anchors.centerIn: parent
											color: foreground
											font.pixelSize: 10
											font.weight: Font.DemiBold
											text: btDevice.modelData.battery
										}
									}
								}
							}
						}
					}
				}
	}

	PopupSurface {
		id: networkPopup
		screen: root.activePopupScreen

		onDismissRequested: root.closeNetworkPopup()
		open: root.networkPopupOpen
		visible: root.networkPopupVisible
		barItem: bar
		anchorWindow: barWindow
		anchorMode: "right"
		surfaceColor: root.surface
		borderColor: root.surfaceBorder
		expandedWidth: 300
		contentPreferredHeight: networkPopupColumn.implicitHeight

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

					Column {
						id: networkPopupColumn
						anchors.fill: parent
						spacing: 12

						Item {
							width: parent.width
							height: 34

							Row {
								anchors.left: parent.left
								anchors.verticalCenter: parent.verticalCenter
								spacing: 10

								ThemedRectangle {
									width: 32
									height: 32
									radius: ThemeEngine.radiusMedium
									anchors.verticalCenter: parent.verticalCenter
									color: networkPopup.currentType === "offline" ? root.secondaryInsetColor : Qt.alpha(root.primary, 0.4)

									Behavior on color {
										CAnim {}
									}

									QQCImpl.IconImage {
										anchors.centerIn: parent
										width: 15
										height: 15
										source: networkPopup.currentType === "ethernet"
											? "/usr/share/icons/Adwaita/symbolic/devices/network-wired-symbolic.svg"
											: "/usr/share/icons/Adwaita/symbolic/status/network-wireless-signal-excellent-symbolic.svg"
										sourceSize: Qt.size(width, height)
										color: root.foreground
									}
								}

								Column {
									anchors.verticalCenter: parent.verticalCenter
									spacing: 1

									BioText {
										role: "bodyStrong"
										color: foreground
										font.pixelSize: 13
										font.weight: Font.DemiBold
										text: networkPopup.currentType === "offline"
											? "Offline"
											: (networkPopup.currentType === "ethernet" ? "Ethernet" : "Wi-Fi")
									}

									BioText {
										role: "label"
										color: Qt.alpha(foreground, 0.55)
										font.pixelSize: 10
										text: networkPopup.currentInterface !== ""
											? `${networkPopup.currentInterface}  \u00b7  ${networkPopup.currentIp !== "" ? networkPopup.currentIp : "no IP"}`
											: "no interface"
									}
								}
							}

							ThemedRectangle {
								visible: networkPopup.currentType !== "offline"
								anchors.right: parent.right
								anchors.verticalCenter: parent.verticalCenter
								width: disconnectLabel.implicitWidth + 22
								height: 25
								radius: ThemeEngine.radiusMedium
								color: Qt.alpha(root.danger, 0.16)

								BioText {
									role: "label"
									id: disconnectLabel
									anchors.centerIn: parent
									color: foreground
									font.pixelSize: 10
									font.weight: Font.Medium
									text: "Disconnect"
								}

								HoverLayer {
									tint: root.danger
									onClicked: root.disconnectActiveNetwork()
								}
							}
						}

						ThemedRectangle {
							width: parent.width
							implicitHeight: networkInfoColumn.implicitHeight + 20
							radius: ThemeEngine.radiusMedium
							color: root.secondaryBoxColor

							Column {
								id: networkInfoColumn
								anchors.fill: parent
								anchors.margins: 10
								spacing: 8

								Item {
									width: parent.width
									height: 22

									BioText {
										role: "body"
										anchors.left: parent.left
										anchors.verticalCenter: parent.verticalCenter
										color: foreground
										font.pixelSize: 12
										font.weight: Font.Medium
										text: "Upload"
									}

									BioText {
										role: "body"
										anchors.right: parent.right
										anchors.verticalCenter: parent.verticalCenter
										color: foreground
										font.pixelSize: 12
										font.weight: Font.Medium
										text: networkPopup.formatSpeed(networkPopup.currentUploadSpeed)
									}
								}

								ThemedRectangle {
									width: parent.width
									height: 96
									radius: ThemeEngine.radiusMedium
									color: root.secondaryInsetColor

									Canvas {
										id: uploadChart
										anchors.fill: parent
										anchors.margins: 8
										anchors.bottomMargin: 8
										antialiasing: true
										onWidthChanged: requestPaint()
										onHeightChanged: requestPaint()
										Connections {
											target: networkPopup
											function onUploadHistoryChanged() {
												uploadChart.requestPaint();
											}
											function onCurrentUploadSpeedChanged() {
												uploadChart.requestPaint();
											}
										}

										onPaint: {
											const ctx = getContext("2d");
											ctx.reset();

											const values = networkPopup.uploadHistory || [];
											if (values.length < 2) return;

											const width = uploadChart.width;
											const height = uploadChart.height;
											const step = values.length > 1 ? width / (values.length - 1) : width;

											ctx.strokeStyle = root.accent;
											ctx.lineWidth = 2;
											ctx.lineJoin = "round";
											ctx.lineCap = "round";
											ctx.beginPath();

											for (let i = 0; i < values.length; i += 1) {
												const x = i * step;
												const y = height - Math.max(0, Math.min(height, height * networkPopup.chartRatio(values[i], networkPopup.uploadChartMax)));
												if (i === 0) ctx.moveTo(x, y);
												else ctx.lineTo(x, y);
											}

											ctx.stroke();

											ctx.fillStyle = root.accent;
											ctx.beginPath();
											ctx.moveTo(0, height);
											for (let i = 0; i < values.length; i += 1) {
												const x = i * step;
												const y = height - Math.max(0, Math.min(height, height * networkPopup.chartRatio(values[i], networkPopup.uploadChartMax)));
												ctx.lineTo(x, y);
											}
											ctx.lineTo(width, height);
											ctx.closePath();
											ctx.fill();

											ctx.fillStyle = root.accent;
											for (let i = 0; i < values.length; i += 1) {
												const x = i * step;
												const y = height - Math.max(0, Math.min(height, height * networkPopup.chartRatio(values[i], networkPopup.uploadChartMax)));
												ctx.beginPath();
												ctx.arc(x, y, 2.6, 0, Math.PI * 2);
												ctx.fill();
											}
										}
									}
								}

								Item {
									width: parent.width
									height: 16

									BioText {
										role: "body"
										anchors.left: parent.left
										anchors.verticalCenter: parent.verticalCenter
										color: foreground
										font.pixelSize: 12
										font.weight: Font.Medium
										text: "Download"
									}

									BioText {
										role: "body"
										anchors.right: parent.right
										anchors.verticalCenter: parent.verticalCenter
										color: foreground
										font.pixelSize: 12
										font.weight: Font.Medium
										text: networkPopup.formatSpeed(networkPopup.currentDownloadSpeed)
									}
								}

								ThemedRectangle {
									width: parent.width
									height: 96
									radius: ThemeEngine.radiusMedium
									color: root.secondaryInsetColor

									Canvas {
										id: downloadChart
										anchors.fill: parent
										anchors.margins: 8
										anchors.bottomMargin: 8
										antialiasing: true
										onWidthChanged: requestPaint()
										onHeightChanged: requestPaint()
										Connections {
											target: networkPopup
											function onDownloadHistoryChanged() {
												downloadChart.requestPaint();
											}
											function onCurrentDownloadSpeedChanged() {
												downloadChart.requestPaint();
											}
										}

										onPaint: {
											const ctx = getContext("2d");
											ctx.reset();

											const values = networkPopup.downloadHistory || [];
											if (values.length < 2) return;

											const width = downloadChart.width;
											const height = downloadChart.height;
											const step = values.length > 1 ? width / (values.length - 1) : width;

											ctx.strokeStyle = root.accent;
											ctx.lineWidth = 2;
											ctx.lineJoin = "round";
											ctx.lineCap = "round";
											ctx.beginPath();

											for (let i = 0; i < values.length; i += 1) {
												const x = i * step;
												const y = height - Math.max(0, Math.min(height, height * networkPopup.chartRatio(values[i], networkPopup.downloadChartMax)));
												if (i === 0) ctx.moveTo(x, y);
												else ctx.lineTo(x, y);
											}

											ctx.stroke();

											ctx.fillStyle = root.accent;
											ctx.beginPath();
											ctx.moveTo(0, height);
											for (let i = 0; i < values.length; i += 1) {
												const x = i * step;
												const y = height - Math.max(0, Math.min(height, height * networkPopup.chartRatio(values[i], networkPopup.downloadChartMax)));
												ctx.lineTo(x, y);
											}
											ctx.lineTo(width, height);
											ctx.closePath();
											ctx.fill();

											ctx.fillStyle = root.accent;
											for (let i = 0; i < values.length; i += 1) {
												const x = i * step;
												const y = height - Math.max(0, Math.min(height, height * networkPopup.chartRatio(values[i], networkPopup.downloadChartMax)));
												ctx.beginPath();
												ctx.arc(x, y, 2.6, 0, Math.PI * 2);
												ctx.fill();
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
		id: resourcesPopup
		screen: root.activePopupScreen

		onDismissRequested: root.closeResourcesPopup()
		open: root.resourcesPopupOpen
		visible: root.resourcesPopupVisible
		barItem: bar
		anchorWindow: barWindow
		anchorMode: "right"
		surfaceColor: root.surface
		borderColor: root.surfaceBorder
		expandedWidth: 300
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
								spacing: Bio.s4

								BioSection {
									width: parent.width
									title: "Vitals"
									trailing: resourceBars.cpuText
								}

								Row {
									anchors.horizontalCenter: parent.horizontalCenter
									spacing: Bio.s5

									ArcGauge {
										value: resourceBars.cpuUsage
										label: "Cortex"
										detail: resourceBars.cpuText
										gaugeColor: resourceBars.cpuUsage > 0.88 ? Bio.necrosis : Bio.organ
									}

									ArcGauge {
										value: resourceBars.memoryUsage
										label: "Reserve"
										detail: resourceBars.memoryText
										gaugeColor: resourceBars.memoryUsage > 0.88 ? Bio.necrosis : Bio.organAlt
									}
								}

								BioSection {
									width: parent.width
									visible: resourceBars.mouseBatteryAvailable
									title: "Limb"
									trailing: resourceBars.mouseBatteryStatus

									ResourceRow {
										width: parent.width
										label: resourceBars.mouseBatteryName
										detail: ""
										usage: resourceBars.mouseBatteryUsage
										valueText: resourceBars.mouseBatteryText
									}
								}

								BioSection {
									width: parent.width
									title: "Stores"
									trailing: `${resourceBars.disks.length}`

									Column {
										width: parent.width
										spacing: Bio.s3

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

		ModalSheet {
			open: root.launcherPopupOpen
			mode: "bottom"
			scrimOpacity: 0.18
			sheetWidth: 720
			sheetHeight: 480
			bottomMargin: 14
			shadowSurfaceColor: root.surface
			onDismissRequested: root.closeLauncherPopup()

			ThemedRectangle {
				anchors.fill: parent
				radius: ThemeEngine.radiusMedium
				color: root.surface
				border.width: 1
				border.color: root.surfaceBorder
				clip: true

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
			scrimOpacity: 0.34
			shadowSurfaceColor: root.secondaryInsetColor
			sheetWidth: Math.min(1320, studioPopup.width - 80)
			sheetHeight: Math.min(860, studioPopup.height - 80)
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
			scrimOpacity: 0.72
			sheetWidth: 620
			sheetHeight: 300
			onDismissRequested: root.closePowerPopup()

			BioSurface {
				id: powerModal
				anchors.fill: parent
				washTop: Bio.membrane
				washBottom: Bio.membraneDeep
				lineColor: Qt.alpha(Bio.necrosis, 0.42)
				liveColor: Bio.necrosis
				haloStrength: 0.30
				intensity: 0.5
				focus: root.powerPopupVisible

				property string statUser: ""
				property string statKernel: ""
				property string statUptime: ""

				Keys.onEscapePressed: root.closePowerPopup()
				Keys.onLeftPressed: root.powerSelectionIndex = Math.max(0, root.powerSelectionIndex - 1)
				Keys.onRightPressed: root.powerSelectionIndex = Math.min(3, root.powerSelectionIndex + 1)
				Keys.onUpPressed: root.powerSelectionIndex = Math.max(0, root.powerSelectionIndex - 2)
				Keys.onDownPressed: root.powerSelectionIndex = Math.min(3, root.powerSelectionIndex + 2)
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

				// Who is being ended, and how long it has been alive.
				Column {
					id: hostColumn
					anchors.left: parent.left
					anchors.verticalCenter: parent.verticalCenter
					width: 176
					spacing: Bio.s3

					BioSigil {
						anchors.horizontalCenter: parent.horizontalCenter
						width: 72
						height: 72
						seed: 5
						lineColor: Bio.boneDim
					}

					BioText {
						anchors.horizontalCenter: parent.horizontalCenter
						role: "title"
						font.pixelSize: 17
						text: powerModal.statUser
					}

					Column {
						anchors.horizontalCenter: parent.horizontalCenter
						spacing: 0

						BioText {
							anchors.horizontalCenter: parent.horizontalCenter
							role: "label"
							tone: "faint"
							text: "Alive"
						}

						BioText {
							anchors.horizontalCenter: parent.horizontalCenter
							role: "caption"
							tone: "muted"
							text: powerModal.statUptime
						}

						BioText {
							anchors.horizontalCenter: parent.horizontalCenter
							role: "label"
							tone: "faint"
							text: "Strain"
						}

						BioText {
							anchors.horizontalCenter: parent.horizontalCenter
							role: "caption"
							tone: "muted"
							text: powerModal.statKernel
						}
					}
				}

				Grid {
					columns: 2
					columnSpacing: Bio.s3
					rowSpacing: Bio.s3
					anchors.left: hostColumn.right
					anchors.leftMargin: Bio.s6
					anchors.right: parent.right
					anchors.verticalCenter: parent.verticalCenter

					readonly property real tileWidth: (width - Bio.s3) / 2
					readonly property real tileHeight: (powerModal.height - 68) / 2

					PowerActionButton {
						width: parent.tileWidth
						height: parent.tileHeight
						label: "Seal"
						sublabel: "Lock the session"
						iconSource: "/usr/share/icons/Adwaita/symbolic/status/system-lock-screen-symbolic.svg"
						selectionIndex: 0
						selected: root.powerSelectionIndex === 0
						onClicked: root.runPowerAction("lock")
					}

					PowerActionButton {
						width: parent.tileWidth
						height: parent.tileHeight
						label: "Shed"
						sublabel: "End the session"
						iconSource: "/usr/share/icons/Adwaita/symbolic/actions/system-log-out-symbolic.svg"
						selectionIndex: 1
						selected: root.powerSelectionIndex === 1
						onClicked: root.runPowerAction("logout")
					}

					PowerActionButton {
						width: parent.tileWidth
						height: parent.tileHeight
						label: "Regrow"
						sublabel: "Restart the machine"
						iconSource: "/usr/share/icons/Adwaita/symbolic/actions/system-reboot-symbolic.svg"
						selectionIndex: 2
						selected: root.powerSelectionIndex === 2
						dangerous: true
						onClicked: root.runPowerAction("reboot")
					}

					PowerActionButton {
						width: parent.tileWidth
						height: parent.tileHeight
						label: "Terminate"
						sublabel: "Power off"
						iconSource: "/usr/share/icons/Adwaita/symbolic/actions/system-shutdown-symbolic.svg"
						selectionIndex: 3
						selected: root.powerSelectionIndex === 3
						dangerous: true
						onClicked: root.runPowerAction("shutdown")
					}
				}
			}
		}
	}

	// A load, as an organ: a ring that fills, the number engraved inside it and
	// the name of the thing under it. Used wherever a proportion is the reading
	// — never a bar with a percentage written next to it.
	component ArcGauge: Item {
		id: gauge

		required property real value
		required property string label
		property string detail: ""
		property color gaugeColor: Bio.organ

		width: 108
		height: 108

		BioGlow {
			anchors.centerIn: ring
			width: ring.width * 1.8
			height: ring.height * 1.8
			color: gauge.gaugeColor
			strength: 0.20
			spread: 0.36
		}

		BioRing {
			id: ring
			anchors.horizontalCenter: parent.horizontalCenter
			anchors.top: parent.top
			width: 78
			height: 78
			seed: 1
			weight: Bio.ribHeavy
			lineColor: Bio.boneFaint
			liveColor: gauge.gaugeColor
			progress: Math.max(0, Math.min(1, gauge.value))
		}

		BioText {
			anchors.centerIn: ring
			role: "reading"
			font.pixelSize: 22
			text: `${Math.round(gauge.value * 100)}%`
		}

		Column {
			anchors.horizontalCenter: parent.horizontalCenter
			anchors.top: ring.bottom
			anchors.topMargin: Bio.s2
			spacing: 0

			BioText {
				anchors.horizontalCenter: parent.horizontalCenter
				role: "label"
				color: gauge.gaugeColor
				text: gauge.label
			}

			BioText {
				anchors.horizontalCenter: parent.horizontalCenter
				role: "caption"
				tone: "faint"
				visible: gauge.detail !== ""
				text: gauge.detail
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

		BioText {
			id: rowLabel
			anchors.left: parent.left
			anchors.top: parent.top
			role: "heading"
			font.pixelSize: 13
			text: resourceRow.label
		}

		BioText {
			anchors.left: rowLabel.right
			anchors.leftMargin: Bio.s2
			anchors.baseline: rowLabel.baseline
			role: "caption"
			tone: "faint"
			text: resourceRow.detail
		}

		BioText {
			anchors.right: parent.right
			anchors.baseline: rowLabel.baseline
			role: "caption"
			tone: resourceRow.strained ? "alert" : "muted"
			text: resourceRow.valueText
		}

		BioMeter {
			anchors.left: parent.left
			anchors.right: parent.right
			anchors.top: rowLabel.bottom
			anchors.topMargin: Bio.s2
			height: 8
			value: resourceRow.usage
			fillColor: resourceRow.strained ? Bio.necrosis : Bio.organ
			trackColor: Bio.boneGhost
		}

		BioText {
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
	component PowerActionButton: Item {
		id: powerActionButton

		signal clicked

		required property string label
		required property string iconSource
		required property int selectionIndex
		required property bool selected
		property string sublabel: ""
		property bool dangerous: false

		readonly property color toneColor: powerActionButton.dangerous ? Bio.necrosis : Bio.organ
		readonly property real live: Math.max(powerMouse.live, powerActionButton.selected ? 0.85 : 0)

		BioSurface {
			anchors.fill: parent
			variant: "plate"
			lineColor: powerActionButton.dangerous ? Qt.alpha(Bio.necrosis, 0.38) : Bio.boneFaint
			liveColor: powerActionButton.toneColor
			washTop: Qt.alpha(powerActionButton.toneColor, 0.07)
			washBottom: Bio.tissue1
			haloStrength: 0.18 * powerActionButton.live
			intensity: powerActionButton.live
			padding: Bio.s4

			Row {
				anchors.verticalCenter: parent.verticalCenter
				anchors.left: parent.left
				anchors.right: parent.right
				spacing: Bio.s3

				BioRing {
					anchors.verticalCenter: parent.verticalCenter
					width: 34
					height: 34
					seed: powerActionButton.selectionIndex
					lineColor: Bio.boneFaint
					liveColor: powerActionButton.toneColor
					intensity: powerActionButton.live

					QQCImpl.IconImage {
						anchors.centerIn: parent
						width: 16
						height: 16
						source: powerActionButton.iconSource
						sourceSize: Qt.size(width, height)
						color: powerActionButton.live > 0.3 ? powerActionButton.toneColor : Bio.text
					}
				}

				Column {
					anchors.verticalCenter: parent.verticalCenter
					spacing: -1

					BioText {
						role: "heading"
						color: powerActionButton.live > 0.3 ? powerActionButton.toneColor : Bio.text
						text: powerActionButton.label
					}

					BioText {
						role: "caption"
						tone: "faint"
						visible: powerActionButton.sublabel !== ""
						text: powerActionButton.sublabel
					}
				}
			}
		}

		BioTouch {
			id: powerMouse
			onClicked: powerActionButton.clicked()
			onContainsMouseChanged: {
				if (containsMouse) root.powerSelectionIndex = powerActionButton.selectionIndex;
			}
		}
	}

	PopupSurface {
		id: trayMenuPopup
		screen: root.activePopupScreen

		onDismissRequested: root.closeTrayMenu()
		open: root.trayMenuOpen
		visible: root.trayMenuVisible
		barItem: bar
		anchorWindow: barWindow
		anchorMode: "item"
		anchorItem: trayRow
		surfaceColor: root.surface
		borderColor: root.surfaceBorder
		expandedWidth: (trayMenuStackLoader.item ? trayMenuStackLoader.item.implicitWidth : 240) + 24
		contentPreferredHeight: trayMenuStackLoader.item ? trayMenuStackLoader.item.implicitHeight : 0

		onVisibleChanged: {
			if (!visible && root.trayMenuVisible) {
				trayMenuCloseTimer.stop();

				if (root.trayMenuOpen) {
					root.trayMenuVisible = true;
					root.closeTrayMenu();
				} else {
					root.trayMenuVisible = false;
					root.trayMenuHandle = null;
					root.trayMenuTargetItem = null;
				}
			}
		}

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

						ThemedRectangle {
							id: menuEntry
							required property QsMenuEntry modelData

							width: trayMenuColumn.implicitWidth
							implicitHeight: modelData.isSeparator ? 1 : 32
							radius: ThemeEngine.radiusMedium
							color: modelData.isSeparator
								? root.secondaryBoxStrongColor
								: (entryMouseArea.containsMouse && entryMouseArea.enabled ? root.secondaryBoxColor : "transparent")

							HoverLayer {
								id: entryMouseArea
								tint: root.foreground
								showHover: false
								enabled: !menuEntry.modelData.isSeparator && menuEntry.modelData.enabled
								cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor

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
						}

						Row {
							visible: !menuEntry.modelData.isSeparator
							anchors.fill: parent
							anchors.leftMargin: 10
							anchors.rightMargin: 10
							spacing: 8

							Image {
								anchors.verticalCenter: parent.verticalCenter
								width: 16
								height: 16
								visible: menuEntry.modelData.icon !== ""
								source: menuEntry.modelData.icon
								fillMode: Image.PreserveAspectFit
							}

							BioText {
								role: "body"
								anchors.verticalCenter: parent.verticalCenter
								width: parent.width - x - (menuEntry.modelData.hasChildren ? 18 : 0)
								text: menuEntry.modelData.text
								color: menuEntry.modelData.enabled ? foreground : Qt.alpha(foreground, 0.45)
								font.pixelSize: 13
								elide: Text.ElideRight
							}

							BioText {
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

				sourceComponent: ThemedRectangle {
					width: trayMenuColumn.implicitWidth
					height: 32
					radius: ThemeEngine.radiusMedium
					color: root.secondaryBoxColor
					border.width: 0
					border.color: "transparent"

					HoverLayer {
						tint: root.foreground
						onClicked: trayMenuStackLoader.item.pop()
					}

					BioText {
						role: "body"
						anchors.centerIn: parent
						text: "Back"
						color: foreground
						font.pixelSize: 13
						font.weight: Font.Medium
					}
				}
			}
		}
	}

	PopupSurface {
		id: mediaPopup
		screen: root.activePopupScreen

		onDismissRequested: root.closeMediaPopup()
		open: root.mediaPopupOpen
		visible: root.mediaPopupVisible
		barItem: bar
		anchorWindow: barWindow
		anchorMode: "item"
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
		screen: root.activePopupScreen

		onDismissRequested: root.closeClockPopup()
		open: root.clockPopupOpen
		visible: root.clockPopupVisible
		barItem: bar
		anchorMode: "item"
		anchorItem: specimenPlate
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
			spacing: Bio.s4

			// Today, stated once and large. The spine already carries the time,
			// so the chamber carries the date.
			Column {
				width: parent.width
				spacing: -2

				BioText {
					anchors.horizontalCenter: parent.horizontalCenter
					role: "specimen"
					text: Qt.formatDateTime(root.now, "d MMMM")
				}

				BioText {
					anchors.horizontalCenter: parent.horizontalCenter
					role: "label"
					tone: "organ"
					text: Qt.formatDateTime(root.now, "dddd")
				}
			}

			Item {
				width: parent.width
				height: 30

				BioNode {
					anchors.left: parent.left
					anchors.verticalCenter: parent.verticalCenter
					size: 26
					seed: 1
					onClicked: root.shiftCalendarMonths(-1)

					BioText {
						anchors.centerIn: parent
						role: "heading"
						text: "‹"
					}
				}

				BioText {
					anchors.centerIn: parent
					role: "title"
					font.pixelSize: 16
					text: Qt.formatDateTime(root.currentDate, "MMMM yyyy")
				}

				BioNode {
					anchors.right: parent.right
					anchors.verticalCenter: parent.verticalCenter
					size: 26
					seed: 3
					onClicked: root.shiftCalendarMonths(1)

					BioText {
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

						BioText {
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

						BioGlow {
							anchors.centerIn: parent
							width: 44
							height: 44
							color: Bio.organ
							strength: 0.30
							spread: 0.30
							visible: dayCell.today
						}

						BioRing {
							anchors.centerIn: parent
							width: 30
							height: 30
							seed: dayCell.index % 4
							visible: dayCell.present
							lineColor: "transparent"
							liveColor: Bio.organ
							intensity: dayCell.today ? 1 : dayTouch.live
						}

						BioText {
							anchors.centerIn: parent
							role: dayCell.today ? "heading" : "body"
							tone: dayCell.today ? "organ" : "muted"
							font.pixelSize: 12
							visible: dayCell.present
							text: dayCell.present ? dayCell.day : ""
						}

						BioTouch {
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
		screen: root.activePopupScreen

		onDismissRequested: root.closeWeatherPopup()
		open: root.weatherPopupOpen
		visible: root.weatherPopupVisible
		barItem: bar
		anchorMode: "item"
		anchorItem: weatherNode
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
			spacing: Bio.s4

			// The reading first, at the size of a thing you glance at, with the
			// sky's own sigil beside it rather than a boxed-in icon.
			Row {
				width: parent.width
				spacing: Bio.s4

				BioRing {
					id: skyRing
					anchors.verticalCenter: parent.verticalCenter
					width: 58
					height: 58
					seed: 2
					weight: Bio.ribHeavy
					intensity: 0.55
					lineColor: Bio.boneFaint

					QQCImpl.IconImage {
						anchors.centerIn: parent
						width: 26
						height: 26
						source: root.resolveIconSource("", [
							root.weatherIcon,
							root.weatherIcon.replace("-symbolic", ""),
							"weather-overcast-symbolic"
						])
						sourceSize: Qt.size(width, height)
						color: Bio.organ
					}
				}

				Column {
					anchors.verticalCenter: parent.verticalCenter
					spacing: -1

					BioText {
						role: "specimen"
						text: root.weatherTemperature
					}

					BioText {
						role: "body"
						tone: "muted"
						text: root.weatherDescription
					}

					BioText {
						role: "label"
						tone: "faint"
						text: root.weatherLocation
					}
				}
			}

			BioSection {
				width: parent.width
				title: "Atmosphere"

				Grid {
					columns: 2
					columnSpacing: Bio.s5
					rowSpacing: Bio.s3
					width: parent.width

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
							width: (weatherContent.width - Bio.s5) / 2
							height: 34

							Rectangle {
								anchors.left: parent.left
								anchors.verticalCenter: parent.verticalCenter
								width: Bio.ribThin
								height: parent.height * 0.62
								color: Bio.boneGhost
							}

							Column {
								anchors.left: parent.left
								anchors.leftMargin: Bio.s3
								anchors.verticalCenter: parent.verticalCenter
								spacing: -1

								BioText {
									role: "label"
									tone: "faint"
									text: modelData.label
								}

								BioText {
									role: "bodyStrong"
									text: modelData.value
								}
							}
						}
					}
				}
			}

			// Sunrise and sunset as the two ends of one run of light.
			Item {
				width: parent.width
				height: 34

				BioText {
					id: sunriseLabel
					anchors.left: parent.left
					anchors.verticalCenter: parent.verticalCenter
					role: "reading"
					font.pixelSize: 15
					text: root.weatherSunrise
				}

				BioText {
					id: sunsetLabel
					anchors.right: parent.right
					anchors.verticalCenter: parent.verticalCenter
					role: "reading"
					font.pixelSize: 15
					text: root.weatherSunset
				}

				BioTendon {
					anchors.left: sunriseLabel.right
					anchors.right: sunsetLabel.left
					anchors.leftMargin: Bio.s3
					anchors.rightMargin: Bio.s3
					anchors.verticalCenter: parent.verticalCenter
					height: 14
					lineColor: Bio.boneFaint
					facing: Qt.LeftToRight
				}

				BioText {
					anchors.horizontalCenter: parent.horizontalCenter
					anchors.top: parent.verticalCenter
					anchors.topMargin: Bio.s1
					role: "label"
					tone: "faint"
					text: "Light"
				}
			}
		}
	}

	PopupSurface {
		id: notifPopup
		screen: root.activePopupScreen

		onDismissRequested: root.closeNotifPopup()
		open: root.notifPopupOpen
		visible: root.notifPopupVisible
		barItem: bar
		anchorMode: "item"
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

				BioText {
					id: notifTitle
					anchors.left: parent.left
					anchors.verticalCenter: parent.verticalCenter
					role: "title"
					font.pixelSize: 16
					text: "Signals"
				}

				BioTendon {
					anchors.left: notifTitle.right
					anchors.right: purgeLabel.visible ? purgeLabel.left : parent.right
					anchors.leftMargin: Bio.s3
					anchors.rightMargin: Bio.s3
					anchors.verticalCenter: parent.verticalCenter
					height: 12
					facing: Qt.LeftToRight
					lineColor: Bio.boneFaint
					visible: width > 24
				}

				BioText {
					id: purgeLabel
					anchors.right: parent.right
					anchors.verticalCenter: parent.verticalCenter
					visible: root.notificationGroups.length > 0
					role: "label"
					tone: purgeTouch.containsMouse ? "alert" : "muted"
					text: `Purge ${root.notificationGroups.length}`

					BioTouch {
						id: purgeTouch
						anchors.margins: -Bio.s2
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
					spacing: Bio.s3

					BioSigil {
						anchors.horizontalCenter: parent.horizontalCenter
						width: 56
						height: 56
						seed: 21
						lineColor: Bio.boneGhost
					}

					BioText {
						anchors.horizontalCenter: parent.horizontalCenter
						role: "label"
						tone: "faint"
						text: "Nothing stirring"
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
							height: cardBody.implicitHeight + Bio.s5 * 2
							// Dismissing pulls the record out sideways; nothing
							// in this style fades away where it stands.
							x: dismissing ? -width - 24 : 0
							opacity: dismissing ? 0 : 1

							Behavior on x {
								NumberAnimation { duration: Bio.relax; easing.type: Easing.InCubic }
							}

							Behavior on opacity {
								NumberAnimation { duration: Bio.relax }
							}

							Timer {
								id: notificationDismissTimer
								interval: 240
								repeat: false
								onTriggered: root.dismissNotificationGroup(notificationCard.modelData.key)
							}

							BioSurface {
								anchors.fill: parent
								variant: "plate"
								lineColor: Qt.alpha(notificationCard.urgencyColor, 0.45)
								liveColor: notificationCard.urgencyColor
								washTop: Qt.alpha(notificationCard.urgencyColor, 0.10)
								washBottom: Bio.tissue1
								haloStrength: 0.10
								padding: Bio.s5

								Column {
									id: cardBody
									anchors.fill: parent
									spacing: Bio.s3

									// Which organism sent this, and when.
									Item {
										width: parent.width
										height: 14

										Rectangle {
											id: urgencyBead
											anchors.left: parent.left
											anchors.verticalCenter: parent.verticalCenter
											width: Bio.nodule * 2
											height: Bio.nodule * 2
											radius: width / 2
											color: notificationCard.urgencyColor
										}

										BioText {
											id: sourceLabel
											anchors.left: urgencyBead.right
											anchors.leftMargin: Bio.s2
											anchors.verticalCenter: parent.verticalCenter
											role: "label"
											color: notificationCard.urgencyColor
											text: notificationCard.modelData.appName || "System"
										}

										BioText {
											id: stampLabel
											anchors.right: dismissTarget.left
											anchors.rightMargin: Bio.s2
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

											BioText {
												anchors.centerIn: parent
												role: "body"
												tone: dismissTouch.containsMouse ? "alert" : "faint"
												text: "×"
											}

											BioTouch {
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
										spacing: Bio.s3

										Column {
											width: parent.width - (specimenImage.visible ? specimenImage.width + Bio.s3 : 0)
											spacing: Bio.s1

											BioText {
												width: parent.width
												role: "heading"
												wrapMode: Text.WordWrap
												maximumLineCount: 2
												text: notificationCard.latestEntry
													? notificationCard.latestEntry.summary
													: (notificationCard.modelData.appName || "Notification")
											}

											BioText {
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

											BioFrame {
												anchors.fill: parent
												variant: "plate"
												beading: false
												weight: Bio.ribThin
												lineColor: Bio.boneFaint
												liveColor: notificationCard.urgencyColor
												fillTop: Bio.cavity
												fillBottom: Bio.cavity
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

									BioMeter {
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
										spacing: Bio.s2

										Repeater {
											model: notificationCard.liveNotification ? notificationCard.liveNotification.actions : []

											delegate: BioButton {
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
										spacing: Bio.s3

										BioField {
											id: inlineReply
											width: parent.width - sendButton.width - Bio.s3
											placeholder: notificationCard.liveNotification
												? (notificationCard.liveNotification.inlineReplyPlaceholder || "Reply")
												: "Reply"
											onAccepted: root.submitInlineReply(notificationCard.liveNotification, inlineReply.inputItem)
										}

										BioButton {
											id: sendButton
											anchors.verticalCenter: parent.verticalCenter
											text: "Send"
											tone: "organ"
											onClicked: root.submitInlineReply(notificationCard.liveNotification, inlineReply.inputItem)
										}
									}

									// Older entries from the same source, folded away.
									Item {
										width: parent.width
										height: 20
										visible: notificationCard.modelData.notifications.length > 1

										BioText {
											id: foldLabel
											anchors.left: parent.left
											anchors.verticalCenter: parent.verticalCenter
											role: "label"
											tone: foldTouch.containsMouse ? "organ" : "faint"
											text: notificationCard.modelData.expanded
												? `Fold ${notificationCard.modelData.notifications.length - 1} older`
												: `Unfold ${notificationCard.modelData.notifications.length - 1} older`
										}

										BioTendon {
											anchors.left: foldLabel.right
											anchors.right: parent.right
											anchors.leftMargin: Bio.s3
											anchors.verticalCenter: parent.verticalCenter
											height: 10
											facing: Qt.LeftToRight
											lineColor: foldTouch.containsMouse ? Qt.alpha(Bio.organ, 0.6) : Bio.boneGhost
											visible: width > 24
										}

										BioTouch {
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
													duration: notificationCard.modelData.expanded ? Bio.swell : Bio.relax
													easing.type: notificationCard.modelData.expanded ? Easing.OutBack : Easing.InCubic
													easing.overshoot: notificationCard.modelData.expanded ? 1.05 : 0
												}
											}

											Column {
												id: olderColumn
												width: parent.width
												spacing: Bio.s2

												Repeater {
													model: notificationCard.modelData.notifications.slice(1)

													delegate: Item {
														id: olderEntry

														required property var modelData

														width: olderColumn.width
														implicitHeight: olderText.implicitHeight + Bio.s3 * 2

														Rectangle {
															anchors.left: parent.left
															anchors.top: parent.top
															anchors.bottom: parent.bottom
															anchors.topMargin: Bio.s2
															anchors.bottomMargin: Bio.s2
															width: Bio.ribThin
															color: Bio.boneGhost
														}

														Column {
															id: olderText
															anchors.left: parent.left
															anchors.right: parent.right
															anchors.leftMargin: Bio.s3
															anchors.verticalCenter: parent.verticalCenter
															spacing: 0

															BioText {
																width: parent.width
																role: "bodyStrong"
																tone: "muted"
																text: olderEntry.modelData.summary
															}

															BioText {
																width: parent.width
																visible: olderEntry.modelData.body !== ""
																role: "caption"
																tone: "faint"
																wrapMode: Text.WordWrap
																maximumLineCount: 2
																text: olderEntry.modelData.body
															}

															BioText {
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

			visible: true
			color: "transparent"

			anchor {
				window: barWindow
				edges: Edges.Bottom
				gravity: Edges.Bottom
				adjustment: PopupAdjustment.SlideX | PopupAdjustment.SlideY

				onAnchoring: {
					anchor.rect.x = 0;
					anchor.rect.y = 0;
					anchor.rect.width = barWindow.width;
					anchor.rect.height = bar.height + 12 + index * (toastWindow.implicitHeight + 12);
				}
			}

			implicitWidth: toastCard.implicitWidth + 40
			implicitHeight: toastCard.implicitHeight

			NumberAnimation on revealProgress {
				from: 0
				to: 1
				duration: Bio.swell
				easing.type: Easing.OutBack
				easing.overshoot: 1.1
			}

			BioSurface {
				id: toastCard

				implicitWidth: 380
				implicitHeight: toastContent.implicitHeight + Bio.s5 * 2
				width: implicitWidth
				height: implicitHeight
				// It arrives from off the right edge, the way something crawls
				// in, and leaves the same way.
				x: toastWindow.dismissing
					? implicitWidth + 24
					: (1 - toastWindow.revealProgress) * 40
				y: 0
				opacity: toastWindow.dismissing ? 0 : Math.min(1, toastWindow.revealProgress * 2)
				variant: "plate"
				lineColor: Qt.alpha(toastWindow.urgencyColor, 0.55)
				liveColor: toastWindow.urgencyColor
				washTop: Qt.alpha(toastWindow.urgencyColor, 0.12)
				washBottom: Bio.membraneDeep
				haloStrength: 0.22
				intensity: 0.55
				padding: Bio.s5

				Behavior on x {
					NumberAnimation { duration: Bio.relax; easing.type: Easing.InCubic }
				}

				Behavior on opacity {
					NumberAnimation { duration: Bio.relax }
				}

				Timer {
					id: toastDismissTimer
					interval: 240
					repeat: false
					onTriggered: toastWindow.notification.dismiss()
				}

				Column {
					id: toastContent
					anchors.fill: parent
					spacing: Bio.s3

					Item {
						width: parent.width
						height: 14

						Rectangle {
							id: toastBead
							anchors.left: parent.left
							anchors.verticalCenter: parent.verticalCenter
							width: Bio.nodule * 2
							height: Bio.nodule * 2
							radius: width / 2
							color: toastWindow.urgencyColor
						}

						BioText {
							anchors.left: toastBead.right
							anchors.leftMargin: Bio.s2
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

							BioText {
								anchors.centerIn: parent
								role: "body"
								tone: toastDismissTouch.containsMouse ? "alert" : "faint"
								text: "×"
							}

							BioTouch {
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
						spacing: Bio.s3

						Column {
							width: parent.width - (toastImage.visible ? toastImage.width + Bio.s3 : 0)
							spacing: Bio.s1

							BioText {
								width: parent.width
								role: "heading"
								wrapMode: Text.WordWrap
								maximumLineCount: 2
								text: toastWindow.notification.summary || (toastWindow.notification.appName || "Notification")
							}

							BioText {
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

							BioFrame {
								anchors.fill: parent
								variant: "plate"
								beading: false
								weight: Bio.ribThin
								lineColor: Bio.boneFaint
								liveColor: toastWindow.urgencyColor
								fillTop: Bio.cavity
								fillBottom: Bio.cavity
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

					BioMeter {
						width: parent.width
						visible: toastWindow.progressValue >= 0 && toastWindow.progressValue <= 100
						height: 8
						fillColor: toastWindow.urgencyColor
						value: Math.max(0, Math.min(toastWindow.progressValue, 100)) / 100
					}

					Flow {
						width: parent.width
						visible: toastWindow.notification && toastWindow.notification.actions.length > 0
						spacing: Bio.s2

						Repeater {
							model: toastWindow.notification ? toastWindow.notification.actions : []

							delegate: BioButton {
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
						spacing: Bio.s3

						BioField {
							id: toastInlineReply
							width: parent.width - toastSend.width - Bio.s3
							placeholder: toastWindow.notification
								? (toastWindow.notification.inlineReplyPlaceholder || "Reply")
								: "Reply"
							onAccepted: root.submitInlineReply(toastWindow.notification, toastInlineReply.inputItem)
						}

						BioButton {
							id: toastSend
							anchors.verticalCenter: parent.verticalCenter
							text: "Send"
							tone: "organ"
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
