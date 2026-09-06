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

	function navigatePanel(name) {
        const openers = {
            launcher: root.openLauncherPopup, calendar: root.openClockPopup,
            weather: root.openWeatherPopup, notifications: root.openNotifPopup,
            media: root.openMediaPopup, resources: root.openResourcesPopup,
            network: root.openNetworkPopup, bluetooth: root.openBluetoothPopup,
            clipboard: root.openClipboardPopup, power: root.openPowerPopup,
            wallpaper: root.openThemePickerPopup, interface: root.openUiThemePickerPopup,
            animations: root.openAnimationPickerPopup,
            styles: root.openUiThemePickerPopup,
            collection: function() { root.studioPage = "collection"; root.openStylePresetPopup(); },
            presets: root.openThemePickerPopup
        };
        if (openers[name]) openers[name]();
    }

    property string studioPage: "wallpaper"
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
	property bool themePickerPopupOpen: false
	property bool themePickerPopupVisible: false
	property bool uiThemePickerPopupOpen: false
	property bool uiThemePickerPopupVisible: false
	property bool animationPickerPopupOpen: false
	property bool animationPickerPopupVisible: false
	property bool stylePresetPopupOpen: false
	property bool stylePresetPopupVisible: false
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
	// theme color roles (derived from the selected pywal theme below)
	readonly property color secondaryBoxColor: Atelier.surface
	readonly property color secondaryBoxStrongColor: Qt.tint(Atelier.canvas, Qt.alpha(primary, 0.16))
	readonly property color secondaryInsetColor: Atelier.surface
	readonly property color surface: Atelier.canvas
	readonly property color surfaceBorder: Atelier.rule
	readonly property color onPrimary: Atelier.onAccent
	readonly property color danger: Atelier.danger
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

		if (except !== "themePicker") {
			themePickerPopupCloseTimer.stop();
			root.themePickerPopupOpen = false;
			root.themePickerPopupVisible = false;
		}

		if (except !== "uiThemePicker") {
			uiThemePickerPopupCloseTimer.stop();
			root.uiThemePickerPopupOpen = false;
			root.uiThemePickerPopupVisible = false;
		}

		if (except !== "animationPicker") {
			animationPickerPopupCloseTimer.stop();
			root.animationPickerPopupOpen = false;
			root.animationPickerPopupVisible = false;
		}

		if (except !== "stylePreset") {
			stylePresetPopupCloseTimer.stop();
			root.stylePresetPopupOpen = false;
			root.stylePresetPopupVisible = false;
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
        root.pendingPowerAction = "";
		root.powerPopupOpen = false;
		powerPopupCloseTimer.restart();
	}

	function togglePowerPopup(scr) {
		if (root.powerPopupOpen) root.closePowerPopup();
		else root.openPowerPopup(scr);
	}

	function openThemePickerPopup(scr = null) { root.studioPage = "wallpaper"; root.openStylePresetPopup(scr); }

	function closeThemePickerPopup() { root.closeStylePresetPopup(); }

	function toggleThemePickerPopup(scr = null) {
        if(root.stylePresetPopupOpen && root.studioPage === "wallpaper") root.closeStylePresetPopup();
        else root.openThemePickerPopup(scr);
    }

	function openUiThemePickerPopup(scr = null) { root.studioPage = "styles"; root.openStylePresetPopup(scr); }

	function closeUiThemePickerPopup() { root.closeStylePresetPopup(); }

	function toggleUiThemePickerPopup(scr = null) {
        if(root.stylePresetPopupOpen && root.studioPage === "styles") root.closeStylePresetPopup();
        else root.openUiThemePickerPopup(scr);
    }

	function openAnimationPickerPopup(scr = null) { root.studioPage = "motion"; root.openStylePresetPopup(scr); }

	function closeAnimationPickerPopup() { root.closeStylePresetPopup(); }

	function toggleAnimationPickerPopup(scr = null) {
        if(root.stylePresetPopupOpen && root.studioPage === "motion") root.closeStylePresetPopup();
        else root.openAnimationPickerPopup(scr);
    }

	function openStylePresetPopup(scr = null) {
		root.openPopupOnFocusedScreen(function() {
			root.closeOtherPopups("stylePreset");
			root.stylePresetPopupVisible = true;
			root.stylePresetPopupOpen = true;
		}, scr);
	}

	function closeStylePresetPopup() {
		root.stylePresetPopupOpen = false;
		stylePresetPopupCloseTimer.restart();
	}

	function toggleStylePresetPopup(scr = null) {
		if (root.stylePresetPopupOpen) root.closeStylePresetPopup();
		else root.openStylePresetPopup(scr);
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

	property string pendingPowerAction: ""

	function runPowerAction(kind) {
        if (kind !== "lock" && root.pendingPowerAction !== kind) { root.pendingPowerAction = kind; return; }
        root.pendingPowerAction = "";
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

	FileView {
		id: walFile
		path: "/home/lu/.cache/wal/colors.json"
		blockLoading: true
	}

	// Recreate the wallpaper process from the last Theme Changer selection.
	// Colours are already persisted in ~/.cache/wal; only the image/video
	// runtime needs to be started again when the desktop session comes up.
	Process {
		id: restoreThemeWallpaperProcess
		command: [
			"bash",
			`${Quickshell.shellDir}/scripts/restore_theme_wallpaper.sh`
		]
		running: true
	}

	readonly property var wal: JSON.parse(walFile.text())
	readonly property color background: Atelier.canvas
	readonly property color foreground: Atelier.text
	readonly property color primary: Atelier.accent
	readonly property color secondary: Atelier.sage
	readonly property color accent: Atelier.accent
	readonly property color tertiary: Atelier.gold
	readonly property color border: Atelier.rule

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

	IpcHandler { target: "styleSession"; function state(): string { return JSON.stringify({locked: quickLock.locked}); } }

	// Non-destructive review entry points: open surfaces without invoking actions.
	IpcHandler {
		target: "designReview"
		function open(name: string): void {
			const openers = {
				launcher: root.openLauncherPopup, calendar: root.openClockPopup,
				weather: root.openWeatherPopup, notifications: root.openNotifPopup,
				media: root.openMediaPopup, resources: root.openResourcesPopup,
				network: root.openNetworkPopup, bluetooth: root.openBluetoothPopup,
				clipboard: root.openClipboardPopup, power: root.openPowerPopup,
				wallpaper: root.openThemePickerPopup, interface: root.openUiThemePickerPopup,
				animations: root.openAnimationPickerPopup,
				styles: root.openUiThemePickerPopup,
				collection: function() { root.studioPage = "collection"; root.openStylePresetPopup(); },
				presets: root.openThemePickerPopup
			};
			if (openers[name]) openers[name]();
		}
		function close(): void { root.closeOtherPopups(""); }
		function osd(): void {
			root.showOsd("volume", "Volume", 0.42, "42%", root.iconNameSource("audio-volume-high-symbolic", []));
		}
		function state(): string {
			return JSON.stringify({locked: quickLock.locked, theme: ThemeEngine.currentThemeId, themeError: ThemeEngine.error,
				screen: root.activePopupScreen?.name, screens: Quickshell.screens.map(s => ({name:s.name,width:s.width,height:s.height})),
				background: String(root.background), foreground: String(root.foreground),
				network: root.networkStatusType, notificationGroups: root.notificationGroups.length});
		}
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

		function reload(): void {
			walFile.reload();
		}
	}

	IpcHandler {
		target: "themeTask"

		function show(status: string, title: string, detail: string): void {
			root.addThemeTaskPopup(status, title, detail);
		}
	}

	IpcHandler {
		target: "uiTheme"

		function open(): void { root.openUiThemePickerPopup(); }
		function close(): void { root.closeUiThemePickerPopup(); }
		function toggle(): void { root.toggleUiThemePickerPopup(); }
		function select(themeId: string): void { ThemeEngine.selectTheme(themeId); }
		// Complete presets apply Niri once Wallust has generated their new colors.
		function selectShell(themeId: string): void { ThemeEngine.activate(themeId, true); }
		function current(): string { return ThemeEngine.currentThemeId; }
		function reload(): void { ThemeEngine.reloadCatalog(); }
	}

	IpcHandler {
		target: "animationPicker"

		function open(): void {
			root.openAnimationPickerPopup();
		}

		function close(): void {
			root.closeAnimationPickerPopup();
		}

		function toggle(): void {
			root.toggleAnimationPickerPopup();
		}
	}

	IpcHandler {
		target: "stylePreset"

		function open(): void { root.openStylePresetPopup(); }
		function close(): void { root.closeStylePresetPopup(); }
		function toggle(): void { root.toggleStylePresetPopup(); }
	}

	IpcHandler {
		target: "studio"

		function open(page: string): void {
			root.studioPage = page && page !== "" ? page : "wallpaper";
			root.openStylePresetPopup();
		}

		function close(): void { root.closeStylePresetPopup(); }

		function toggle(page: string): void {
			const next = page && page !== "" ? page : "wallpaper";
			if (root.stylePresetPopupOpen && root.studioPage === next) root.closeStylePresetPopup();
			else {
				root.studioPage = next;
				root.openStylePresetPopup();
			}
		}
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

	PanelWindow {
		id: osdWindow
		screen: root.primaryBarScreen

		anchors { left: true; bottom: true }
        margins { left: 112; bottom: 28 }
        implicitWidth: 280
        implicitHeight: 76

		exclusiveZone: 0
		visible: root.osdVisible
		color: "transparent"
		WlrLayershell.exclusionMode: ExclusionMode.Ignore
		WlrLayershell.layer: WlrLayer.Overlay

		ThemedRectangle {
			id: osdCard
			width: 280
			height: 76
			x: 0
			y: 0
			radius: 38
			color: root.surface
			border.width: 1
			border.color: root.surfaceBorder
			opacity: root.osdVisible ? 1 : 0
			scale: root.osdVisible ? 1 : 0.96

			Behavior on opacity {
				Anim {
					duration: Motion.fast
				}
			}

			Behavior on scale {
				NumberAnimation {
					duration: Motion.normal
					easing.type: ThemeEngine.emphasizedEasing
					easing.overshoot: Motion.smallOvershoot
				}
			}

			RowLayout {
				anchors.fill: parent
				anchors.margins: 12
				spacing: 10

				ThemedRectangle {
					Layout.preferredWidth: 38
					Layout.preferredHeight: 38
										radius: ThemeEngine.radiusMedium
										color: root.secondaryBoxColor
										themeStyle: "raised"

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
							colorizationColor: root.foreground
						}
					}
				}

				ColumnLayout {
					Layout.fillWidth: true
					spacing: 6

					RowLayout {
						Layout.fillWidth: true
						spacing: 8

						AtelierText {
							Layout.fillWidth: true
							color: root.foreground
							font.pixelSize: 14
							font.weight: Font.Medium
							text: root.osdLabel
							elide: Text.ElideRight
						}

						AtelierText {
							color: Qt.alpha(root.foreground, 0.7)
							font.pixelSize: 12
							text: root.osdValueText
												}

											}

											ThemedRectangle {
						Layout.fillWidth: true
						implicitHeight: 8
						radius: ThemeEngine.radiusSmall
						color: root.secondaryInsetColor
						border.width: 0
						border.color: "transparent"

						ThemedRectangle {
							width: parent.width * Math.min(1, Math.max(0, root.osdProgress))
							height: parent.height
							radius: parent.radius
							color: root.accent

							Behavior on width {
								Anim {
									duration: Motion.fast
								}
							}
						}
					}
				}
			}
		}
	}

	PanelWindow {
		id: barWindow
        visible: false
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

		exclusiveZone: bar.y + bar.implicitHeight
		implicitHeight: bar.y + bar.implicitHeight + ThemeEngine.shadowRenderMargin
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
			anchors.leftMargin: 12
			anchors.rightMargin: 12
			anchors.topMargin: 0
			height: implicitHeight
			implicitHeight: 44
			clip: false
            Rectangle {
                anchors.fill: parent
                anchors.leftMargin: -12
                anchors.rightMargin: -12
                color: Atelier.ink
                z: -1
                Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Atelier.rule }
            }

			Row {
				id: leftModules
				anchors.left: parent.left
				anchors.leftMargin: 0
				anchors.verticalCenter: parent.verticalCenter
				spacing: 10

				ThemedRectangle {
					id: launcherButton
					width: 38
					height: bar.height
					radius: ThemeEngine.radiusMedium
					color: root.primary

					HoverLayer {
						id: launcherInteraction
						tint: root.onPrimary
						onClicked: root.toggleLauncherPopup()
					}

					QQCImpl.IconImage {
						anchors.centerIn: parent
						width: 16
						height: 16
						source: "/usr/share/icons/Adwaita/symbolic/actions/view-app-grid-symbolic.svg"
						sourceSize: Qt.size(width, height)
						color: root.onPrimary
					}
				}

				ThemedRectangle {
					id: trayIsland
					visible: trayRepeater.count > 0
					width: trayRow.implicitWidth + 20
					height: bar.height
					radius: ThemeEngine.radiusMedium
					color: "transparent"
					border.width: 0
					border.color: "transparent"

					Row {
						id: trayRow
						anchors.centerIn: parent
						spacing: 6

						Repeater {
							id: trayRepeater
							model: ScriptModel {
								values: SystemTray.items.values
							}

							Item {
								id: trayIconItem

								required property SystemTrayItem modelData

								width: 18
								height: 18

								Image {
									anchors.fill: parent
									source: root.resolveIconSource(root.trayIconSource(trayIconItem.modelData.icon))
									fillMode: Image.PreserveAspectFit
									smooth: true
									mipmap: true
								}

								HoverLayer {
									tint: root.foreground
									cornerRadius: 5
									acceptedButtons: Qt.LeftButton | Qt.RightButton

									onClicked: event => {
										if (trayIconItem.modelData.menu) {
											if (
												root.trayMenuOpen
												&& root.trayMenuVisible
												&& root.trayMenuHandle === trayIconItem.modelData.menu
											) {
												root.closeTrayMenu();
											} else {
												root.openTrayMenu(trayIconItem.modelData.menu, trayIconItem);
											}
										} else {
											root.closeTrayMenu();
											if (event.button === Qt.RightButton) trayIconItem.modelData.secondaryActivate();
											else trayIconItem.modelData.activate();
										}
									}
								}
							}
						}
					}
				}

				NiriTaskbar {
					id: taskbarIsland
					visible: niriState.tasksForOutput(String(barWindow.screen?.name || "")).length > 0
					height: bar.height
					niriState: niriState
					outputName: String(barWindow.screen?.name || "")
					background: root.surface
					foreground: root.foreground
					secondaryBoxColor: root.secondaryBoxColor
					secondaryBoxStrongColor: root.secondaryBoxStrongColor
				}

				NowPlaying {
					id: nowPlayingIsland
					height: bar.height
					foreground: root.foreground
					secondaryBoxColor: root.surface
					progressColor: root.accent
					onClicked: root.toggleMediaPopup()
				}

				TypingCatcher {
					id: typingCatcherIsland
					height: bar.height
					foreground: root.foreground
					surface: root.surface
					maxWords: 3
					paused: quickLock.locked
				}
			}

			ThemedRectangle {
				id: clockIsland
				width: Math.max(clock.width + 32, 132)
				height: parent.height
				anchors.centerIn: parent
				radius: ThemeEngine.radiusMedium
				color: "transparent"
				border.width: 0
				border.color: "transparent"

				HoverLayer {
					id: clockInteraction
					tint: root.foreground
					onClicked: root.toggleClockPopup()
				}
			}

			AtelierText {
				id: clock
				anchors.centerIn: parent
				color: foreground
				font.pixelSize: 18
				font.weight: Font.Medium
				text: Qt.formatDateTime(new Date(), "HH:mm")
			}

			Timer {
				running: true
				repeat: true
				interval: 1000

				onTriggered: {
					const now = new Date();
					root.now = now;
					clock.text = Qt.formatDateTime(now, "HH:mm");
				}
			}

			ThemedRectangle {
				id: weatherIsland
				width: weatherIslandRow.implicitWidth + 24
				height: bar.height
				anchors.right: bellIsland.left
				anchors.rightMargin: 8
				anchors.verticalCenter: parent.verticalCenter
				radius: ThemeEngine.radiusMedium
				color: "transparent"

				Row {
					id: weatherIslandRow
					anchors.centerIn: parent
					spacing: 6

					QQCImpl.IconImage {
						anchors.verticalCenter: parent.verticalCenter
						width: 15
						height: 15
						source: root.resolveIconSource("", [
							root.weatherIcon,
							root.weatherIcon.replace("-symbolic", ""),
							"weather-overcast-symbolic"
						])
						visible: source !== ""
						sourceSize: Qt.size(width, height)
						color: root.foreground
					}

					AtelierText {
						anchors.verticalCenter: parent.verticalCenter
						color: root.foreground
						font.pixelSize: 12
						font.weight: Font.Medium
						text: root.weatherTemperature
					}
				}

				HoverLayer {
					id: weatherInteraction
					tint: root.foreground
					onClicked: root.toggleWeatherPopup()
				}
			}

			ThemedRectangle {
				id: bellIsland
				width: 34
				height: bar.height
				anchors.right: clipboardButton.left
				anchors.rightMargin: 8
				anchors.verticalCenter: parent.verticalCenter
				radius: ThemeEngine.radiusMedium
				color: "transparent"

				QQCImpl.IconImage {
					anchors.centerIn: parent
					width: 15
					height: 15
					source: root.resolveIconSource("preferences-system-notifications-symbolic", ["dialog-information-symbolic"])
					sourceSize: Qt.size(width, height)
					color: root.foreground
				}

				ThemedRectangle {
					visible: root.notificationGroups.length > 0
					width: Math.max(15, badgeLabel.implicitWidth + 8)
					height: 15
					radius: height / 2
					anchors.top: parent.top
					anchors.right: parent.right
					anchors.topMargin: -2
					anchors.rightMargin: -2
					color: root.accent
					scale: root.notificationGroups.length > 0 ? 1 : 0

					Behavior on scale {
						SpatialAnim {}
					}

					AtelierText {
						id: badgeLabel
						anchors.centerIn: parent
						color: root.background
						font.pixelSize: 9
						font.weight: Font.DemiBold
						text: root.notificationGroups.length
					}
				}

				HoverLayer {
					id: bellInteraction
					tint: root.foreground
					onClicked: root.toggleNotifPopup()
				}
			}

			TopBarNetworkButton {
				id: clipboardButton
				anchors.right: bluetoothButton.left
				anchors.rightMargin: 8
				anchors.verticalCenter: parent.verticalCenter
				foreground: root.foreground
				secondaryBoxColor: root.surface
				iconSource: "/usr/share/icons/Adwaita/symbolic/actions/edit-paste-symbolic.svg"
				onClicked: root.toggleClipboardPopup()
			}

			TopBarNetworkButton {
				id: bluetoothButton
				anchors.right: networkButton.left
				anchors.rightMargin: 8
				anchors.verticalCenter: parent.verticalCenter
				foreground: root.foreground
				secondaryBoxColor: root.surface
				iconSource: "/usr/share/icons/Adwaita/symbolic/status/bluetooth-active-symbolic.svg"
				onClicked: root.toggleBluetoothPopup()
			}

			TopBarNetworkButton {
				id: networkButton
				anchors.right: resourceBars.left
				anchors.rightMargin: 8
				anchors.verticalCenter: parent.verticalCenter
				foreground: root.foreground
				secondaryBoxColor: root.surface
				iconSource: root.networkStatusType === "ethernet"
					? "/usr/share/icons/Adwaita/symbolic/devices/network-wired-symbolic.svg"
					: "/usr/share/icons/Adwaita/symbolic/status/network-wireless-signal-excellent-symbolic.svg"
				onClicked: root.toggleNetworkPopup()
			}

			TopBarResourceBars {
				id: resourceBars
				anchors.right: powerButton.left
				anchors.rightMargin: 8
				anchors.verticalCenter: parent.verticalCenter
				height: parent.height
				foreground: root.foreground
				secondaryBoxColor: root.surface
				secondaryInsetColor: root.secondaryInsetColor
				barColor: root.accent
				cpuIcon: "/usr/share/icons/hicolor/scalable/actions/xsi-cpu-symbolic.svg"
				memoryIcon: "/usr/share/icons/hicolor/scalable/actions/xsi-applications-electronics-symbolic.svg"
				storageIcon: root.resolveIconSource("drive-harddisk-symbolic", ["drive-harddisk-system-symbolic", "xsi-drive-harddisk-symbolic"])
				mouseIcon: "/usr/share/icons/Adwaita/symbolic/devices/input-mouse-symbolic.svg"
				onClicked: root.toggleResourcesPopup()
			}

			ThemedRectangle {
				id: powerButton
				width: 34
				height: parent.height
				anchors.right: parent.right
				anchors.rightMargin: 0
				anchors.verticalCenter: parent.verticalCenter
				radius: ThemeEngine.radiusMedium
				color: Qt.tint(root.surface, Qt.alpha(root.danger, 0.25))

				HoverLayer {
					id: powerInteraction
					tint: root.danger
					onClicked: root.togglePowerPopup()
				}

				QQCImpl.IconImage {
					anchors.centerIn: parent
					width: 16
					height: 16
					source: "/usr/share/icons/Adwaita/symbolic/actions/system-shutdown-symbolic.svg"
					sourceSize: Qt.size(width, height)
					color: root.danger
				}
			}
		}
	}

	Variants {
        model: Quickshell.screens
        DesktopRail {
            required property var modelData
            monitor: modelData
            host: root
            niri: niriState
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
		id: themePickerPopupCloseTimer
		interval: Motion.largeClose + 50
		repeat: false
		onTriggered: {
			if (!root.themePickerPopupOpen) root.themePickerPopupVisible = false;
		}
	}

	Timer {
		id: uiThemePickerPopupCloseTimer
		interval: Motion.largeClose + 50
		repeat: false
		onTriggered: {
			if (!root.uiThemePickerPopupOpen) root.uiThemePickerPopupVisible = false;
		}
	}

	Timer {
		id: animationPickerPopupCloseTimer
		interval: Motion.largeClose + 50
		repeat: false
		onTriggered: {
			if (!root.animationPickerPopupOpen) root.animationPickerPopupVisible = false;
		}
	}

	Timer {
		id: stylePresetPopupCloseTimer
		interval: Motion.largeClose + 50
		repeat: false
		onTriggered: {
			if (!root.stylePresetPopupOpen) root.stylePresetPopupVisible = false;
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
        controller: root
        chapter: "05"
        title: "Collected"
        subtitle: "Fragments worth keeping close."
		screen: root.activePopupScreen

		onDismissRequested: root.closeClipboardPopup()
		open: root.clipboardPopupOpen
		visible: root.clipboardPopupVisible
		barItem: bar
		anchorWindow: barWindow
		anchorMode: "right"
		surfaceColor: root.surface
		borderColor: root.surfaceBorder
		expandedWidth: 520
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

								AtelierText {
									anchors.verticalCenter: parent.verticalCenter
									color: foreground
									font.pixelSize: 22
                                display: true
									font.weight: Font.Normal
									text: "Clipboard"
								}

								ThemedRectangle {
									anchors.verticalCenter: parent.verticalCenter
									width: Math.max(22, clipCountLabel.implicitWidth + 12)
									height: 19
									radius: 18
									color: Qt.alpha(root.primary, 0.3)

									AtelierText {
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

								AtelierText {
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

							AtelierText {
								anchors.centerIn: parent
								visible: clipboardPopupContent.filteredEntries.length === 0
								color: Qt.alpha(foreground, 0.5)
								font.pixelSize: 12
								text: clipboardPopupContent.searchText !== "" ? "No matches" : "Clipboard is empty"
							}

							GridView {
								id: clipboardList
								anchors.fill: parent
								clip: true
								cellWidth: width / 2
                                cellHeight: 158
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

									width: clipboardList.cellWidth - 10
									height: 148
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

										AtelierText {
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

									AtelierText {
										visible: !clipEntry.modelData.isImage
										anchors.left: parent.left
										anchors.leftMargin: 14
										anchors.right: deleteButton.left
										anchors.rightMargin: 8
										anchors.verticalCenter: parent.verticalCenter
										color: foreground
										font.pixelSize: 11
										elide: Text.ElideRight
										maximumLineCount: 5
                                        wrapMode: Text.WordWrap
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

										AtelierText {
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
        controller: root
        chapter: "06"
        title: "Wireless"
        subtitle: "Your devices, in conversation."
        destinations: [{name:"network",label:"Network"},{name:"bluetooth",label:"Bluetooth"},{name:"resources",label:"System"}]
		screen: root.activePopupScreen

		onDismissRequested: root.closeBluetoothPopup()
		open: root.bluetoothPopupOpen
		visible: root.bluetoothPopupVisible
		barItem: bar
		anchorWindow: barWindow
		anchorMode: "right"
		surfaceColor: root.surface
		borderColor: root.surfaceBorder
		expandedWidth: 380
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

					ConnectionPanel { id: bluetoothPopupColumn; width: parent.width; backend: bluetoothPopup; wireless: true }
				}
	}

	PopupSurface {
		id: networkPopup
        controller: root
        chapter: "07"
        title: "Connected"
        subtitle: "A view of the flow."
        motif: "signal"
        destinations: [{name:"network",label:"Network"},{name:"bluetooth",label:"Bluetooth"},{name:"resources",label:"System"}]
		screen: root.activePopupScreen

		onDismissRequested: root.closeNetworkPopup()
		open: root.networkPopupOpen
		visible: root.networkPopupVisible
		barItem: bar
		anchorWindow: barWindow
		anchorMode: "right"
		surfaceColor: root.surface
		borderColor: root.surfaceBorder
		expandedWidth: 380
		contentPreferredHeight: networkPopupColumn.implicitHeight

		property string currentType: "offline"
		property string currentInterface: ""
		property string currentIp: ""
		property real currentUploadSpeed: 0
		property real currentDownloadSpeed: 0
		property real lastRxBytes: 0
		property real lastTxBytes: 0
		property bool throughputSampleReady: false
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

			const intervalSeconds = 2;
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

		Timer {
			running: true
			repeat: true
			interval: 2000
			triggeredOnStart: true
			onTriggered: {
				networkStatusProcess.running = true;
				netDevFile.reload();
			}
		}

		Process {
			id: networkStatusProcess
			command: [
				"sh",
				"-lc",
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

					ConnectionPanel { id: networkPopupColumn; width: parent.width; backend: networkPopup; onDisconnectRequested: root.disconnectActiveNetwork() }
				}
	}

	PopupSurface {
		id: resourcesPopup
        controller: root
        chapter: "08"
        title: "Vitals"
        subtitle: "The pulse of your machine."
        motif: "signal"
		screen: root.activePopupScreen

		onDismissRequested: root.closeResourcesPopup()
		open: root.resourcesPopupOpen
		visible: root.resourcesPopupVisible
		barItem: bar
		anchorWindow: barWindow
		anchorMode: "right"
		surfaceColor: root.surface
		borderColor: root.surfaceBorder
		expandedWidth: 380
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
							spacing: 14

							AtelierText {
								color: foreground
								font.pixelSize: 22
                                display: true
								font.weight: Font.Normal
								text: "System"
							}

							Row {
								anchors.horizontalCenter: parent.horizontalCenter
								spacing: 18

								ResourceMetric {
									value: resourceBars.cpuUsage
									label: "CPU"
									detail: resourceBars.cpuText
									gaugeColor: root.primary
								}

								ResourceMetric {
									value: resourceBars.memoryUsage
									label: "RAM"
									detail: resourceBars.memoryText
									gaugeColor: root.secondary
								}
							}

							ThemedRectangle {
								visible: resourceBars.mouseBatteryAvailable
								width: parent.width
								height: 46
								radius: ThemeEngine.radiusMedium
								color: root.secondaryBoxColor

								Row {
									anchors.left: parent.left
									anchors.leftMargin: 12
									anchors.verticalCenter: parent.verticalCenter
									spacing: 10

									QQCImpl.IconImage {
										anchors.verticalCenter: parent.verticalCenter
										width: 16
										height: 16
										source: resourceBars.mouseIcon
										sourceSize: Qt.size(width, height)
										color: root.foreground
									}

									Column {
										anchors.verticalCenter: parent.verticalCenter
										spacing: 1

										AtelierText {
											color: foreground
											font.pixelSize: 12
											font.weight: Font.Medium
											text: "Mouse"
										}

										AtelierText {
											visible: text !== ""
											color: Qt.alpha(foreground, 0.5)
											font.pixelSize: 9
											text: resourceBars.mouseBatteryStatus
										}
									}
								}

								AtelierText {
									anchors.right: parent.right
									anchors.rightMargin: 14
									anchors.verticalCenter: parent.verticalCenter
									color: foreground
									font.pixelSize: 13
									font.weight: Font.DemiBold
									text: resourceBars.mouseBatteryText
								}

								ThemedRectangle {
									anchors.bottom: parent.bottom
									anchors.left: parent.left
									anchors.right: parent.right
									anchors.margins: 6
									height: 4
									radius: ThemeEngine.radiusTiny
									color: root.secondaryInsetColor

									ThemedRectangle {
										width: parent.width * resourceBars.mouseBatteryUsage
										height: parent.height
										radius: parent.radius
										color: root.accent

										Behavior on width {
											Anim {}
										}
									}
								}
							}

							ThemedRectangle {
								width: parent.width
								implicitHeight: diskBoxContent.implicitHeight + 24
								radius: ThemeEngine.radiusMedium
								color: root.secondaryBoxColor

								Column {
									id: diskBoxContent
									anchors.fill: parent
									anchors.margins: 12
									spacing: 10

									AtelierText {
										color: foreground
										font.pixelSize: 12
										font.weight: Font.DemiBold
										text: "Disks"
									}

									Repeater {
										model: resourceBars.disks

										delegate: ResourceRow {
											required property var modelData
											width: diskBoxContent.width
											label: modelData.name
											detail: `${modelData.usedText}/${modelData.totalText}`
											usage: modelData.usage
											icon: resourceBars.storageIcon
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
            title: "Discover"
            caption: "Applications, ideas and everything in between."
            studio: false
            controller: root
			mode: "center"
			scrimOpacity: 0.64
			sheetWidth: Math.min(1080, parent.width - 152)
			sheetHeight: Math.min(600, parent.height - 180)
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
						onOpenThemePickerRequested: {
							root.closeLauncherPopup();
							root.openThemePickerPopup();
						}
						onOpenUiThemePickerRequested: {
							root.closeLauncherPopup();
							root.openUiThemePickerPopup();
						}
						onOpenAnimationPickerRequested: {
							root.closeLauncherPopup();
							root.openAnimationPickerPopup();
						}
						onOpenStylePresetRequested: {
							root.closeLauncherPopup();
							root.openStylePresetPopup();
						}
					}
				}
			}
		}
	}

	PanelWindow {
		id: stylePresetPopup
		screen: root.activePopupScreen

		anchors { left: true; right: true; top: true; bottom: true }
		exclusiveZone: 0
		color: "transparent"
		visible: root.stylePresetPopupVisible
		WlrLayershell.exclusionMode: ExclusionMode.Ignore
		WlrLayershell.layer: WlrLayer.Overlay
		WlrLayershell.keyboardFocus: root.stylePresetPopupVisible ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

		ModalSheet {
			open: root.stylePresetPopupOpen
            title: "Studio"
            caption: ""
            studio: false
            controller: root
			scrimOpacity: 0.34
			shadowSurfaceColor: root.secondaryInsetColor
			sheetWidth: Math.min(1320, parent.width - 48)
			sheetHeight: Math.min(840, parent.height - 80)
			onDismissRequested: root.closeStylePresetPopup()

			Loader {
				anchors.fill: parent
				active: root.stylePresetPopupVisible
				sourceComponent: Studio {
                        page: root.studioPage
                        onPageChanged: root.studioPage = page
					onCloseRequested: root.closeStylePresetPopup()
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
            title: "Until next time"
            caption: "Take a pause, or begin again."
            studio: false
            controller: root
			scrimOpacity: 0.28
			shadowSurfaceColor: root.surface
			sheetWidth: Math.min(560, parent.width - 48)
			sheetHeight: Math.min(306, parent.height - 180)
			onDismissRequested: root.closePowerPopup()

			ThemedRectangle {
				id: powerModal
				anchors.fill: parent
				radius: ThemeEngine.radiusMedium
				color: root.surface
				border.width: 0
				border.color: root.surfaceBorder
				focus: root.powerPopupVisible

				property string statUser: ""
				property string statKernel: ""
				property string statUptime: ""

				Keys.onEscapePressed: root.closePowerPopup()
				Keys.onLeftPressed: root.powerSelectionIndex = Math.max(0, root.powerSelectionIndex - 1)
				Keys.onRightPressed: root.powerSelectionIndex = Math.min(3, root.powerSelectionIndex + 1)
				Keys.onUpPressed: root.powerSelectionIndex = Math.max(0, root.powerSelectionIndex - 1)
				Keys.onDownPressed: root.powerSelectionIndex = Math.min(3, root.powerSelectionIndex + 1)
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

                Column {
                    anchors.fill: parent; anchors.margins: 16; spacing: 22
                    AtelierText { width: parent.width; text: powerModal.statUser; display: true; font.pixelSize: 24; elide: Text.ElideMiddle }
                    AtelierText { text: "UPTIME  /  " + powerModal.statUptime; font.family: Atelier.mono; font.pixelSize: 10; color: Atelier.muted }
                    Row {
                        width: parent.width; spacing: 12
                        Repeater {
                            model: [{name:"Lock",action:"lock",icon:"system-lock-screen",category:"status"},{name:"Sign out",action:"logout",icon:"system-log-out",category:"actions"},{name:"Restart",action:"reboot",icon:"system-reboot",category:"actions"},{name:"Power off",action:"shutdown",icon:"system-shutdown",category:"actions"}]
                            delegate: Item {
                                required property var modelData
                                required property int index
                                width: (powerModal.width - 68) / 4; height: 120
                                Rectangle {
                                    anchors.horizontalCenter: parent.horizontalCenter; width: 72; height: 72; radius: 36
                                    color: root.powerSelectionIndex === parent.index ? Atelier.ink : Atelier.surface
                                    QQCImpl.IconImage { anchors.centerIn: parent; width: 26; height: 26; source: "/usr/share/icons/Adwaita/symbolic/" + parent.parent.modelData.category + "/" + parent.parent.modelData.icon + "-symbolic.svg"; color: root.powerSelectionIndex === parent.parent.index ? Atelier.gold : Atelier.ink }
                                }
                                AtelierText { y: 88; width: parent.width; horizontalAlignment: Text.AlignHCenter; text: parent.modelData.name; font.pixelSize: 12 }
                                MouseArea { anchors.fill: parent; hoverEnabled: true; onEntered: root.powerSelectionIndex = parent.index; onClicked: root.runPowerAction(parent.modelData.action) }
                            }
                        }
                    }
                    AtelierText { width: parent.width; text: root.pendingPowerAction ? "Press again to confirm " + root.pendingPowerAction + ". Esc cancels." : "A moment to pause. Your workspace will be here."; color: root.pendingPowerAction ? Atelier.accent : Atelier.muted; font.pixelSize: 12; wrapMode: Text.WordWrap }
                }

			}
		}
	}

	component ResourceMetric: Item {
        id: metric
        required property real value
        required property string label
        property string detail: ""
        property color gaugeColor: root.primary
        width: 145
        height: 124
        AtelierText { text: metric.label; font.family: Atelier.mono; font.pixelSize: 11; color: Atelier.muted }
        AtelierText { y: 22; text: Math.round(metric.value * 100) + "%"; display: true; font.pixelSize: 38 }
        AtelierText { y: 78; text: metric.detail; font.pixelSize: 11; color: Atelier.muted; width: parent.width; elide: Text.ElideRight }
        Rectangle {
            anchors.bottom: parent.bottom; width: parent.width; height: 2; color: Atelier.rule
            Rectangle {
                width: parent.width * Math.max(0, Math.min(1, metric.value))
                height: 2; color: metric.gaugeColor
                Behavior on width { NumberAnimation { duration: 180 } }
            }
        }
    }

	component ResourceRow: Item {
		id: resourceRow

		required property string label
		required property string detail
		required property real usage
		required property string icon
		property string valueText: `${Math.round(resourceRow.usage * 100)}%`
		property string subValueText: ""

		width: parent ? parent.width : 276
		implicitHeight: 44

		QQCImpl.IconImage {
			id: resourceRowIcon
			x: 0
			y: 1
			width: 16
			height: 16
			source: resourceRow.icon
			sourceSize: Qt.size(width, height)
			color: root.foreground
		}

		AtelierText {
			x: 26
			y: 0
			color: foreground
			font.pixelSize: 12
			font.weight: Font.Medium
			text: resourceRow.label
		}

		AtelierText {
			x: 54
			y: 1
			color: Qt.alpha(foreground, 0.6)
			font.pixelSize: 10
			font.weight: Font.Normal
			text: resourceRow.detail
			visible: text !== ""
			width: parent.width - 100
			elide: Text.ElideRight
		}

		AtelierText {
			anchors.right: parent.right
			y: 0
			color: foreground
			font.pixelSize: 12
			font.weight: Font.Medium
			text: resourceRow.valueText
		}

		AtelierText {
			anchors.right: parent.right
			y: 13
			color: Qt.alpha(foreground, 0.42)
			font.pixelSize: 9
			font.weight: Font.Medium
			text: resourceRow.subValueText
			visible: text !== ""
		}

		ThemedRectangle {
			x: 26
			themeStyle: "inset"
			y: 20
			width: parent.width - 26
			height: 8
			radius: ThemeEngine.radiusSmall
			color: root.secondaryInsetColor
			clip: true

			ThemedRectangle {
				themeStyle: "flat"
				width: parent.width * resourceRow.usage
				height: parent.height
				radius: parent.radius
				color: root.accent

				Behavior on width {
					Anim {}
				}
			}
		}
	}

	component PowerActionButton: ThemedRectangle {
		id: powerActionButton

		signal clicked

		required property string label
		required property string iconSource
		required property int selectionIndex
		required property bool selected
		property string sublabel: ""
		property bool dangerous: false

		radius: ThemeEngine.radiusMedium
		color: (powerActionButton.selected || powerMouse.containsMouse)
			? Qt.alpha(root.accent, 0.06)
			: "transparent"
		border.width: 0
		border.color: Qt.alpha(root.accent, 0.6)
		Rectangle { width: parent.width; height: 1; color: Atelier.rule }
		Rectangle { width: 2; height: 24; anchors.verticalCenter: parent.verticalCenter; color: Atelier.accent; visible: powerActionButton.selected }

		Behavior on color {
			CAnim {}
		}

		HoverLayer {
			id: powerMouse
			tint: root.foreground
			showHover: false
			onEntered: root.powerSelectionIndex = powerActionButton.selectionIndex
			onClicked: powerActionButton.clicked()
		}

		Row {
			anchors.left: parent.left
			anchors.leftMargin: 12
			anchors.verticalCenter: parent.verticalCenter
			spacing: 10

			ThemedRectangle {
				width: 36
				height: 36
				radius: ThemeEngine.radiusMedium
				anchors.verticalCenter: parent.verticalCenter
				color: powerActionButton.dangerous
					? Qt.alpha(root.danger, 0.2)
					: Qt.alpha(root.primary, 0.22)

				QQCImpl.IconImage {
					anchors.centerIn: parent
					width: 17
					height: 17
					source: powerActionButton.iconSource
					sourceSize: Qt.size(width, height)
					color: powerActionButton.dangerous ? root.danger : root.foreground
				}
			}

			Column {
				anchors.verticalCenter: parent.verticalCenter
				spacing: 1

				AtelierText {
					color: foreground
					font.pixelSize: 13
					font.weight: Font.DemiBold
					text: powerActionButton.label
				}

				AtelierText {
					color: Qt.alpha(foreground, 0.55)
					font.pixelSize: 10
					text: powerActionButton.sublabel
				}
			}
		}
	}

	PopupSurface {
		id: trayMenuPopup
        controller: root
        chapter: "09"
        title: "Accessories"
        subtitle: "Small tools, close at hand."
		screen: root.activePopupScreen

		onDismissRequested: root.closeTrayMenu()
		open: root.trayMenuOpen
		visible: root.trayMenuVisible
		barItem: bar
		anchorWindow: barWindow
		anchorMode: "item"
		anchorItem: trayIsland
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

							AtelierText {
								anchors.verticalCenter: parent.verticalCenter
								width: parent.width - x - (menuEntry.modelData.hasChildren ? 18 : 0)
								text: menuEntry.modelData.text
								color: menuEntry.modelData.enabled ? foreground : Qt.alpha(foreground, 0.45)
								font.pixelSize: 13
								elide: Text.ElideRight
							}

							AtelierText {
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

					AtelierText {
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
        controller: root
        chapter: "04"
        title: "Listening"
        subtitle: "An interlude for whatever moves you."
        motif: "signal"
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
        controller: root
        chapter: "01"
        title: "Daybook"
        subtitle: "Time, dates and room to plan."
		screen: root.activePopupScreen

		onDismissRequested: root.closeClockPopup()
		open: root.clockPopupOpen
		visible: root.clockPopupVisible
		barItem: bar
		anchorMode: "item"
		anchorItem: clockIsland
		surfaceColor: root.surface
		borderColor: root.surfaceBorder
		expandedWidth: 420
		contentPreferredHeight: calendarContent.implicitHeight

		onVisibleChanged: {
			if (!visible && root.clockPopupVisible) {
				if (root.clockPopupOpen) root.closeClockPopup();
				else root.clockPopupVisible = false;
			}
		}

		CalendarPanel {
            id: calendarContent
            anchors.fill: parent
            selectedDate: root.currentDate
            today: root.now
            onShiftMonth: delta => root.shiftCalendarMonths(delta)
        }
	}

	PopupSurface {
		id: weatherPopup
        controller: root
        chapter: "02"
        title: "Atmosphere"
        subtitle: "A window onto the world outside."
		screen: root.activePopupScreen

		onDismissRequested: root.closeWeatherPopup()
		open: root.weatherPopupOpen
		visible: root.weatherPopupVisible
		barItem: bar
		anchorMode: "item"
		anchorItem: weatherIsland
		surfaceColor: root.surface
		borderColor: root.surfaceBorder
		expandedWidth: 380
		contentPreferredHeight: weatherContent.implicitHeight

		onVisibleChanged: {
			if (!visible && root.weatherPopupVisible) {
				if (root.weatherPopupOpen) root.closeWeatherPopup();
				else root.weatherPopupVisible = false;
			}
		}

		WeatherPanel {
            id: weatherContent
            anchors.fill: parent
            temperature: root.weatherTemperature
            description: root.weatherDescription
            location: root.weatherLocation
            iconSource: root.resolveIconSource(root.weatherIcon, ["weather-overcast-symbolic"])
            sunrise: root.weatherSunrise
            sunset: root.weatherSunset
            readings: [
                {label: "Feels like", value: root.weatherFeelsLike},
                {label: "Humidity", value: root.weatherHumidity},
                {label: "Wind", value: root.weatherWind},
                {label: "Rain", value: root.weatherPrecipitation},
                {label: "Pressure", value: root.weatherPressure},
                {label: "Observed", value: root.weatherObservationTime !== "" ? Qt.formatDateTime(new Date(root.weatherObservationTime), "HH:mm") : "—"}
            ]
        }
	}

	PopupSurface {
		id: notifPopup
        controller: root
        chapter: "03"
        title: "Activity"
        subtitle: "What arrived while you were away."
		screen: root.activePopupScreen

		onDismissRequested: root.closeNotifPopup()
		open: root.notifPopupOpen
		visible: root.notifPopupVisible
		barItem: bar
		anchorMode: "item"
		anchorItem: bellIsland
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

		ActivityPanel { anchors.fill: parent; host: root }
	}

	Instantiator {
        model: root.toasts
        delegate: ToastSurface { host: root }
    }

}
