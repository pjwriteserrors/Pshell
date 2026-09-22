pragma ComponentBehavior: Bound

import QtQuick
import QtQml
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.Notifications
import "components"

// Filament.
//
// The structural idea: one lit thread along the top of every screen (the
// bar, WireBar.qml). Everything else either sits on it as a bead, hangs
// from it as a lantern (Lantern.qml, one per popup), or is hung from it in
// a wash over the desktop (Veil.qml: the launcher, Studio, the power thread).
// Light travels along the thread between surfaces: a spark leaves the thing
// that changed and lands on the thing it affects.
//
// This file owns the state, the windows and the wiring. The insides of
// every surface live in their own files.
Scope {
	id: root

	// ------------------------------------------------------------- screens
	readonly property var primaryBarScreen: {
		for (const screen of Quickshell.screens)
			if (String(screen.name || "") === "DP-2") return screen;
		return Quickshell.screens.length > 0 ? Quickshell.screens[0] : null;
	}
	property var activePopupScreen: primaryBarScreen
	property var pendingPopupOpenCallback: null
	property var pendingPopupFallbackScreen: null
	property var bars: ({})

	function barFor(screen) {
		return root.bars[String(screen?.name || "")] || null;
	}

	function primaryBar() {
		return root.barFor(root.primaryBarScreen);
	}

	function beadX(name) {
		const bar = root.barFor(root.activePopupScreen);
		return bar ? bar.beadX(name) : -1;
	}

	// ------------------------------------------------------------- surfaces
	// One lantern at a time hangs from the thread; the modals have their own
	// slot. `open` drives the choreography, `visible` keeps the window mapped
	// until the fold has finished.
	property string lanternOpen: ""
	property string lanternVisible: ""
	property string modalOpen: ""
	property string modalVisible: ""
	property string studioPage: "wallpaper"
	property var trayMenuHandle: null
	property real trayMenuX: -1
	// Where the open surface hangs from, measured when it opens: a bead's
	// position is only known once the bar has laid itself out.
	property real lanternAnchorX: -1
	property real modalAnchorX: -1

	readonly property var lanternBeads: ({
		calendar: "clock", weather: "weather", notifications: "notifications", media: "media",
		clipboard: "clipboard", bluetooth: "bluetooth", network: "network", resources: "resources"
	})

	function openLantern(name, preferredScreen = null) {
		root.openPopupOnFocusedScreen(() => {
			root.closeModal();
			lanternHideTimer.stop();
			root.lanternAnchorX = name === "tray" ? root.trayMenuX : root.beadX(root.lanternBeads[name] || "");
			root.lanternVisible = name;
			root.lanternOpen = "";
			Qt.callLater(() => { root.lanternOpen = name; });
		}, preferredScreen);
	}

	function closeLantern() {
		if (root.lanternOpen === "" && root.lanternVisible === "") return;
		root.lanternOpen = "";
		lanternHideTimer.restart();
	}

	function toggleLantern(name, preferredScreen = null) {
		if (root.lanternOpen === name) root.closeLantern();
		else root.openLantern(name, preferredScreen);
	}

	function openModal(name, preferredScreen = null) {
		root.openPopupOnFocusedScreen(() => {
			root.closeLantern();
			modalHideTimer.stop();
			root.modalAnchorX = name === "launcher" ? root.beadX("launcher") : -1;
			root.modalVisible = name;
			root.modalOpen = "";
			Qt.callLater(() => {
				root.modalOpen = name;
				if (name === "launcher") launcherResetTimer.restart();
				if (name === "power") Qt.callLater(() => powerThread.item?.forceActiveFocus());
			});
		}, preferredScreen);
	}

	function closeModal() {
		if (root.modalOpen === "" && root.modalVisible === "") return;
		root.modalOpen = "";
		modalHideTimer.restart();
	}

	function toggleModal(name, preferredScreen = null) {
		if (root.modalOpen === name) root.closeModal();
		else root.openModal(name, preferredScreen);
	}

	Timer {
		id: lanternHideTimer
		interval: Filament.fold + 120
		onTriggered: if (root.lanternOpen === "") { root.lanternVisible = ""; root.trayMenuHandle = null; }
	}

	Timer {
		id: modalHideTimer
		interval: Filament.fold + 140
		onTriggered: if (root.modalOpen === "") root.modalVisible = ""
	}

	Timer {
		id: launcherResetTimer
		interval: 10
		onTriggered: if (root.modalVisible === "launcher") launcherLoader.item?.reset()
	}

	// Studio
	function studioPageOrDefault(page) {
		const known = ["wallpaper", "motion", "dress", "styles", "combinations"];
		return known.includes(String(page)) ? String(page) : "wallpaper";
	}

	function openStudio(page = "", scr = null) {
		root.studioPage = root.studioPageOrDefault(page);
		root.openModal("studio", scr);
	}

	function closeStudio() { if (root.modalOpen === "studio") root.closeModal(); }

	function toggleStudio(page = "", scr = null) {
		const next = root.studioPageOrDefault(page);
		if (root.modalOpen === "studio") {
			if (root.studioPage === next) root.closeModal();
			else root.studioPage = next;
			return;
		}
		root.openStudio(next, scr);
	}

	// Tray menus hang from the tray bead that owns them.
	function openTrayMenu(item, x) {
		if (root.lanternOpen === "tray" && root.trayMenuHandle === item.menu) {
			root.closeLantern();
			return;
		}
		root.trayMenuHandle = null;
		root.trayMenuX = x;
		Qt.callLater(() => {
			root.trayMenuHandle = item.menu;
			root.openLantern("tray");
		});
	}

	// ------------------------------------------------- the focused screen
	function popupScreenByName(outputName) {
		const name = String(outputName || "");
		if (name === "") return null;
		for (const screen of Quickshell.screens)
			if (String(screen.name || "") === name) return screen;
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
		// A second request can only land during the few milliseconds the niri
		// query runs; opening on the best snapshot keeps the action.
		if (focusedOutputProcess.running) {
			root.activePopupScreen = fallback;
			Qt.callLater(callback);
			return;
		}
		root.pendingPopupOpenCallback = callback;
		root.pendingPopupFallbackScreen = fallback;
		focusedOutputProcess.exec([ "niri", "msg", "-j", "focused-output" ]);
	}

	Process {
		id: focusedOutputProcess
		stdout: StdioCollector {
			onStreamFinished: {
				focusedOutputFallbackTimer.stop();
				root.finishPopupScreenRequest(text);
			}
		}
		onExited: focusedOutputFallbackTimer.restart()
	}

	Timer {
		id: focusedOutputFallbackTimer
		interval: 25
		onTriggered: root.finishPopupScreenRequest("")
	}

	// ------------------------------------------------------------ the style
	readonly property string styleId: {
		try {
			return String(JSON.parse(styleManifest.text()).name || "");
		} catch (error) {
			return "";
		}
	}
	property bool styleSwitching: false

	// Identity of the checked-out style, read once per load. A reload that
	// fails leaves the previous config running, and then this still reports
	// the previous style - which is how the switcher notices and rolls back.
	FileView {
		id: styleManifest
		path: `${Quickshell.shellDir}/.quickshell-style.json`
		blockLoading: true
	}

	Timer {
		id: styleReloadTimer
		interval: 1
		onTriggered: Quickshell.reload(true)
	}

	// Paints only outputs missing a wallpaper; full restore is niri's job.
	Process {
		command: ["bash", `${Quickshell.shellDir}/scripts/apply_wallpaper_runtime.sh`, "--ensure"]
		running: true
	}

	// ------------------------------------------------------------ services
	NiriState { id: niriState }
	MediaState { id: media }
	ResourceMonitor { id: resources }

	QuickLock {
		id: quickLock
	}

	// ------------------------------------------------------------- network
	property string networkStatusType: "offline"
	property string networkInterface: ""
	property string networkIp: ""

	function applyNetworkStatus(raw) {
		let type = "offline", iface = "", ip = "";
		for (const line of String(raw || "").split("\n")) {
			const eq = line.indexOf("=");
			if (eq <= 0) continue;
			const key = line.slice(0, eq).trim();
			const value = line.slice(eq + 1).trim();
			if (key === "type") type = value;
			else if (key === "iface") iface = value;
			else if (key === "ip") ip = value;
		}
		if (!["wifi", "ethernet", "offline"].includes(type)) type = "offline";
		root.networkStatusType = type;
		root.networkInterface = type === "offline" ? "" : iface;
		root.networkIp = type === "offline" ? "" : ip;
	}

	function disconnectActiveNetwork() {
		const iface = root.networkInterface.replace(/[^A-Za-z0-9._-]/g, "");
		if (iface === "" || root.networkStatusType === "offline") return;
		if (root.networkStatusType === "ethernet")
			Quickshell.execDetached(["sh", "-lc", `nmcli device set '${iface}' autoconnect no && nmcli device down '${iface}' || nmcli device disconnect '${iface}'`]);
		else
			Quickshell.execDetached(["sh", "-lc", `nmcli device disconnect '${iface}'`]);
		root.applyNetworkStatus("type=offline");
	}

	Timer {
		interval: root.lanternVisible === "network" ? 2000 : 10000
		running: true
		repeat: true
		triggeredOnStart: true
		onTriggered: if (!networkStatusProcess.running) networkStatusProcess.running = true
	}

	// `sh -c`, not `sh -lc`: this runs every few seconds and only reads /sys.
	Process {
		id: networkStatusProcess
		command: ["sh", "-c", `
for dir in /sys/class/net/*; do
  name=$(basename "$dir")
  case "$name" in lo|docker*|br-*|virbr*|veth*|podman*|zt*|tun*|tap*) continue;; esac
  state=$(cat "$dir/operstate" 2>/dev/null || echo down)
  carrier=$(cat "$dir/carrier" 2>/dev/null || echo 0)
  if [ -d "$dir/wireless" ]; then
    if [ "$state" = up ] || [ "$carrier" = 1 ]; then
      ip=$(ip -4 -o addr show dev "$name" scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}')
      printf 'type=wifi\\niface=%s\\nip=%s\\n' "$name" "$ip"; exit 0
    fi
  elif [ "$carrier" = 1 ] || [ "$state" = up ]; then
    ip=$(ip -4 -o addr show dev "$name" scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}')
    printf 'type=ethernet\\niface=%s\\nip=%s\\n' "$name" "$ip"; exit 0
  fi
done
printf 'type=offline\\n'
`]
		stdout: StdioCollector { onStreamFinished: root.applyNetworkStatus(text) }
	}

	// ------------------------------------------------------------- weather
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
	property real weatherLatitude: NaN
	property real weatherLongitude: NaN
	property string weatherTimezone: "auto"
	property string weatherRequestKind: ""
	readonly property bool weatherReady: weatherTemperature !== "--"

	function weatherGeocodeUrl() {
		return "https://geocoding-api.open-meteo.com/v1/search?name="
			+ encodeURIComponent(root.weatherCity) + "&count=1&language=en&format=json";
	}

	function weatherForecastUrl() {
		if (!isFinite(root.weatherLatitude) || !isFinite(root.weatherLongitude)) return "";
		return "https://api.open-meteo.com/v1/forecast?latitude=" + root.weatherLatitude
			+ "&longitude=" + root.weatherLongitude
			+ "&current=temperature_2m,relative_humidity_2m,apparent_temperature,precipitation,pressure_msl,wind_speed_10m,weather_code,is_day"
			+ "&daily=sunrise,sunset&timezone=auto&forecast_days=1";
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
		if ([0, 113].includes(value)) return isDay ? "weather-clear-symbolic" : "weather-clear-night-symbolic";
		if ([1].includes(value)) return isDay ? "weather-few-clouds-symbolic" : "weather-clear-night-symbolic";
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
		if (description && description.toLowerCase().includes("fog")) return "weather-fog-symbolic";
		return "weather-overcast-symbolic";
	}

	function resetWeatherUnavailable() {
		root.weatherLocation = root.weatherCity;
		root.weatherTemperature = "--";
		root.weatherIcon = "weather-severe-alert-symbolic";
		root.weatherDescription = "Weather unavailable";
		root.weatherFeelsLike = "--"; root.weatherHumidity = "--"; root.weatherWind = "--";
		root.weatherVisibility = "--"; root.weatherPrecipitation = "--"; root.weatherPressure = "--";
		root.weatherUvIndex = "--"; root.weatherSunrise = "--"; root.weatherSunset = "--";
		root.weatherMoonPhase = "--"; root.weatherObservationTime = "";
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
			root.weatherFeelsLike = current.apparent_temperature !== undefined ? `${Math.round(Number(current.apparent_temperature))}C` : "--";
			root.weatherHumidity = current.relative_humidity_2m !== undefined ? `${Math.round(Number(current.relative_humidity_2m))}%` : "--";
			root.weatherWind = current.wind_speed_10m !== undefined ? `${Math.round(Number(current.wind_speed_10m))} km/h` : "--";
			root.weatherVisibility = "--";
			root.weatherPrecipitation = current.precipitation !== undefined ? `${Number(current.precipitation).toFixed(1)} mm` : "--";
			root.weatherPressure = current.pressure_msl !== undefined ? `${Math.round(Number(current.pressure_msl))} hPa` : "--";
			root.weatherUvIndex = "--";
			root.weatherSunrise = daily && daily.sunrise && daily.sunrise[0] ? Qt.formatDateTime(new Date(daily.sunrise[0]), "HH:mm") : "--";
			root.weatherSunset = daily && daily.sunset && daily.sunset[0] ? Qt.formatDateTime(new Date(daily.sunset[0]), "HH:mm") : "--";
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

	Process {
		id: weatherProcess
		stdout: StdioCollector {
			onStreamFinished: {
				if (root.weatherRequestKind === "geocode") root.applyWeatherGeocodeResponse(text);
				else root.applyWeatherForecastResponse(text);
			}
		}
		onExited: (code, status) => {
			if (code !== 0 && root.weatherTemperature === "--") root.resetWeatherUnavailable();
		}
	}

	Timer {
		interval: 300000
		running: true
		repeat: true
		triggeredOnStart: true
		onTriggered: root.refreshWeather()
	}

	// ------------------------------------------------------- notifications
	property int nextToastId: 0
	property var toasts: []
	property var notificationGroups: []
	property bool doNotDisturb: false

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
			progressValue: notification.hints.value !== undefined ? Number(notification.hints.value) : -1,
			image: notification.image || "",
			appIcon: notification.appIcon || "",
			hasInlineReply: notification.hasInlineReply,
			inlineReplyPlaceholder: notification.inlineReplyPlaceholder || "Reply",
			timestamp: Date.now(),
			active: true
		};
	}

	function addNotificationGroup(notification, snapshot) {
		const groups = root.notificationGroups.slice();
		let existingIndex = -1;
		for (let i = 0; i < groups.length; i += 1) {
			if (groups[i].key === snapshot.appKey) { existingIndex = i; break; }
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
				key: snapshot.appKey, appName: snapshot.appName, appIcon: snapshot.appIcon,
				image: snapshot.image, urgency: snapshot.urgency, expanded: false,
				latestSnapshot: snapshot, latestNotification: notification,
				latestNotificationId: snapshot.notificationId, notifications: [snapshot]
			};
		}
		groups.unshift(group);
		root.notificationGroups = groups;
	}

	function registerNotification(notification) {
		const snapshot = root.snapshotNotification(notification);
		root.addNotificationGroup(notification, snapshot);
		// Light arrives before the words: a spark runs in from the right edge
		// to the bell, and the toast unfolds when it lands. Critical ones and
		// a muted bell skip the theatre.
		const bar = root.primaryBar();
		if (root.doNotDisturb && notification.urgency !== NotificationUrgency.Critical) {
			bar?.flash("notifications");
			return;
		}
		if (bar) {
			const bellX = bar.beadX("notifications");
			bar.sendSpark(bar.width - 2, bellX, () => { bar.flash("notifications"); root.addToast(notification); });
		} else {
			root.addToast(notification);
		}
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
		const kept = root.toasts.filter(toast => toast.notificationId !== notificationId);
		if (kept.length !== root.toasts.length) root.toasts = kept;
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

	function dismissAllNotificationGroups() {
		for (const group of root.notificationGroups)
			if (group.latestNotification) group.latestNotification.dismiss();
		root.notificationGroups = [];
	}

	function submitInlineReply(notification, text) {
		const reply = String(text || "").trim();
		if (reply === "" || !notification) return;
		notification.sendInlineReply(reply);
	}

	NotificationServer {
		id: notificationServer
		actionsSupported: true
		bodySupported: true
		bodyMarkupSupported: false
		inlineReplySupported: true
		persistenceSupported: true
		onNotification: notification => {
			notification.tracked = true;
			root.registerNotification(notification);
			notification.closed.connect(() => root.markNotificationClosed(notification.id));
		}
	}

	// ------------------------------------------------- volume / brightness
	property string volumeRequestKind: "volume"

	function volumeIconName(volume, muted) {
		if (muted || volume <= 0.001) return "audio-volume-muted-symbolic";
		if (volume < 0.34) return "audio-volume-low-symbolic";
		if (volume < 0.67) return "audio-volume-medium-symbolic";
		return "audio-volume-high-symbolic";
	}

	function showOsd(kind, iconName, progress, label) {
		const bar = root.primaryBar();
		if (!bar) return;
		bar.showMeter(kind, iconName, progress, label);
	}

	function adjustOutputVolume(delta) {
		Quickshell.execDetached(["wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", delta > 0 ? "5%+" : "5%-"]);
		root.volumeRequestKind = "volume";
		volumeRefreshTimer.restart();
	}

	function toggleOutputMute() {
		Quickshell.execDetached(["wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "toggle"]);
		root.volumeRequestKind = "volume";
		volumeRefreshTimer.restart();
	}

	function toggleInputMute() {
		Quickshell.execDetached(["wpctl", "set-mute", "@DEFAULT_AUDIO_SOURCE@", "toggle"]);
		root.volumeRequestKind = "microphone";
		volumeRefreshTimer.restart();
	}

	function adjustBrightness(delta) {
		Quickshell.execDetached(["brightnessctl", "set", delta > 0 ? "5%+" : "5%-"]);
		brightnessRefreshTimer.restart();
	}

	Timer {
		id: volumeRefreshTimer
		interval: 90
		onTriggered: volumeReadProcess.exec(["wpctl", "get-volume", root.volumeRequestKind === "microphone" ? "@DEFAULT_AUDIO_SOURCE@" : "@DEFAULT_AUDIO_SINK@"])
	}

	Timer {
		id: brightnessRefreshTimer
		interval: 70
		onTriggered: brightnessReadProcess.running = true
	}

	Process {
		id: volumeReadProcess
		stdout: StdioCollector {
			onStreamFinished: {
				const match = text.match(/Volume:\s*([0-9.]+)/);
				const volume = match ? Number(match[1]) : 0;
				const muted = text.includes("[MUTED]");
				if (root.volumeRequestKind === "microphone") {
					root.showOsd("microphone", muted ? "microphone-sensitivity-muted-symbolic" : "microphone-sensitivity-high-symbolic",
						muted ? 0 : volume, muted ? "muted" : `${Math.round(volume * 100)}%`);
				} else {
					root.showOsd("volume", root.volumeIconName(volume, muted), muted ? 0 : volume, muted ? "muted" : `${Math.round(volume * 100)}%`);
				}
			}
		}
	}

	Process {
		id: brightnessReadProcess
		command: ["sh", "-lc", "current=$(brightnessctl g 2>/dev/null || echo 0); max=$(brightnessctl m 2>/dev/null || echo 1); printf '%s/%s\\n' \"$current\" \"$max\""]
		stdout: StdioCollector {
			onStreamFinished: {
				const match = text.trim().match(/^(\d+)\/(\d+)$/);
				if (!match) return;
				const progress = Number(match[2]) > 0 ? Number(match[1]) / Number(match[2]) : 0;
				root.showOsd("brightness", "display-brightness-symbolic", progress, `${Math.round(progress * 100)}%`);
			}
		}
	}

	// ---------------------------------------------------------------- power
	function runPowerAction(action) {
		root.closeModal();
		switch (action) {
		case "lock": quickLock.lock(); break;
		case "logout": Quickshell.execDetached(["sh", "-lc", "loginctl terminate-session \"$XDG_SESSION_ID\""]); break;
		case "reboot": Quickshell.execDetached(["systemctl", "reboot"]); break;
		case "shutdown": Quickshell.execDetached(["systemctl", "poweroff"]); break;
		}
	}

	function lockSession() {
		quickLock.lock();
	}

	// ------------------------------------------------------------------ IPC
	IpcHandler {
		target: "styleSession"
		function state(): string {
			return JSON.stringify({ locked: quickLock.locked, style: root.styleId, shellDir: Quickshell.shellDir, switching: root.styleSwitching });
		}
		function freeze(): void { root.styleSwitching = true; Quickshell.watchFiles = false; }
		function thaw(): void { root.styleSwitching = false; }
		// Never reload from inside the call being answered: the handler is
		// part of the tree about to be torn down.
		function reload(): void { styleReloadTimer.restart(); }
	}

	IpcHandler {
		target: "launcher"
		function open(): void { root.openModal("launcher"); }
		function close(): void { if (root.modalOpen === "launcher") root.closeModal(); }
		function toggle(): void { root.toggleModal("launcher"); }
	}

	IpcHandler {
		target: "power"
		function open(): void { root.openModal("power"); }
		function close(): void { if (root.modalOpen === "power") root.closeModal(); }
		function toggle(): void { root.toggleModal("power"); }
	}

	IpcHandler {
		target: "lock"
		function lock(): void { root.lockSession(); }
		function isLocked(): bool { return quickLock.locked; }
	}

	IpcHandler {
		target: "panels"
		function toggleCalendar(): void { root.toggleLantern("calendar"); }
		function toggleWeather(): void { root.toggleLantern("weather"); }
		function toggleNotifications(): void { root.toggleLantern("notifications"); }
		function toggleMedia(): void { root.toggleLantern("media"); }
		function toggleBluetooth(): void { root.toggleLantern("bluetooth"); }
		function toggleNetwork(): void { root.toggleLantern("network"); }
		function toggleResources(): void { root.toggleLantern("resources"); }
	}

	IpcHandler {
		target: "clipboard"
		function open(): void { root.openLantern("clipboard"); }
		function close(): void { if (root.lanternOpen === "clipboard") root.closeLantern(); }
		function toggle(): void { root.toggleLantern("clipboard"); }
	}

	IpcHandler {
		target: "volume"
		function raise(): void { root.adjustOutputVolume(0.05); }
		function lower(): void { root.adjustOutputVolume(-0.05); }
		function muteToggle(): void { root.toggleOutputMute(); }
		function micMuteToggle(): void { root.toggleInputMute(); }
	}

	IpcHandler {
		target: "brightness"
		function raise(): void { root.adjustBrightness(1); }
		function lower(): void { root.adjustBrightness(-1); }
	}

	// A palette change: the thread re-reads its light and a pulse runs its
	// whole length on every screen.
	IpcHandler {
		target: "theme"
		function reload(): void {
			Filament.reload();
			for (const name of Object.keys(root.bars)) root.bars[name]?.sweep();
		}
	}

	IpcHandler {
		target: "uiTheme"
		function select(themeId: string): void { ThemeEngine.selectTheme(themeId); }
		function current(): string { return ThemeEngine.currentThemeId; }
		function reload(): void { ThemeEngine.reloadCatalog(); }
	}

	// The thread itself, for scripts and keybinds: send a spark from one
	// bead to another, bloom a bead, or run a pulse along every bar.
	IpcHandler {
		target: "wire"
		function spark(from: string, to: string): void {
			const bar = root.barFor(root.activePopupScreen) || root.primaryBar();
			if (!bar) return;
			const fromX = from === "left" ? 2 : from === "right" ? bar.width - 2 : bar.beadX(from);
			const toX = to === "left" ? 2 : to === "right" ? bar.width - 2 : bar.beadX(to);
			if (fromX < 0 || toX < 0) return;
			bar.sendSpark(fromX, toX, () => { if (to === "clock") bar.lightClock(); else bar.flash(to); });
		}
		function flash(name: string): void { root.primaryBar()?.flash(name); }
		function sweep(): void { for (const name of Object.keys(root.bars)) root.bars[name]?.sweep(); }
	}

	IpcHandler {
		target: "studio"
		function open(page: string): void { root.openStudio(page); }
		function close(): void { root.closeStudio(); }
		function toggle(page: string): void { root.toggleStudio(page); }
	}

	// ----------------------------------------------------------------- bars
	Variants {
		model: Quickshell.screens

		WireBar {
			id: bar
			required property var modelData
			screenModel: modelData
			niriState: niriState
			media: media
			resources: resources
			notificationCount: root.notificationGroups.length
			networkStatusType: root.networkStatusType
			weatherIcon: root.weatherIcon
			weatherTemperature: root.weatherTemperature
			weatherReady: root.weatherReady
			activeLantern: root.activePopupScreen === modelData ? root.lanternOpen : ""
			activeModal: root.activePopupScreen === modelData ? root.modalOpen : ""
			primary: modelData === root.primaryBarScreen
			doNotDisturb: root.doNotDisturb

			Component.onCompleted: {
				const map = Object.assign({}, root.bars);
				map[String(modelData.name || "")] = bar;
				root.bars = map;
			}

			onActivate: (name, mouse) => {
				if (name === "launcher" || name === "power") root.toggleModal(name, modelData);
				else root.toggleLantern(name, modelData);
			}

			onTrayActivate: (item, mouse, x) => {
				if (item.menu) {
					root.activePopupScreen = modelData;
					root.openTrayMenu(item, x);
					return;
				}
				root.closeLantern();
				if (mouse.button === Qt.RightButton) item.secondaryActivate();
				else item.activate();
			}
		}
	}

	// ------------------------------------------------------------- lanterns
	Lantern {
		id: calendarLantern
		screen: root.activePopupScreen
		visible: root.lanternVisible === "calendar"
		open: root.lanternOpen === "calendar"
		anchorX: root.lanternAnchorX
		lanternWidth: 340
		contentHeight: calendar.implicitHeight
		onDismissRequested: root.closeLantern()
		CalendarLantern { id: calendar; width: parent.width; reveal: calendarLantern.reveal }
	}

	Lantern {
		id: weatherLantern
		screen: root.activePopupScreen
		visible: root.lanternVisible === "weather"
		open: root.lanternOpen === "weather"
		anchorX: root.lanternAnchorX
		lanternWidth: 340
		contentHeight: weather.implicitHeight
		onDismissRequested: root.closeLantern()
		WeatherLantern {
			id: weather
			width: parent.width
			reveal: weatherLantern.reveal
			location: root.weatherLocation
			temperature: root.weatherTemperature
			icon: root.weatherIcon
			description: root.weatherDescription
			feelsLike: root.weatherFeelsLike
			humidity: root.weatherHumidity
			wind: root.weatherWind
			precipitation: root.weatherPrecipitation
			pressure: root.weatherPressure
			sunrise: root.weatherSunrise
			sunset: root.weatherSunset
			observationTime: root.weatherObservationTime
			onRefreshRequested: root.refreshWeather()
		}
	}

	Lantern {
		id: notificationLantern
		screen: root.activePopupScreen
		visible: root.lanternVisible === "notifications"
		open: root.lanternOpen === "notifications"
		anchorX: root.lanternAnchorX
		lanternWidth: 400
		fixedHeight: 520
		onDismissRequested: root.closeLantern()
		NotificationLantern {
			anchors.fill: parent
			reveal: notificationLantern.reveal
			groups: root.notificationGroups
			doNotDisturb: root.doNotDisturb
			onDismissGroup: key => root.dismissNotificationGroup(key)
			onDismissAll: root.dismissAllNotificationGroups()
			onSetExpanded: (key, expanded) => root.setNotificationGroupExpanded(key, expanded)
			onReply: (notification, text) => root.submitInlineReply(notification, text)
			onToggleDoNotDisturb: root.doNotDisturb = !root.doNotDisturb
		}
	}

	Lantern {
		id: mediaLantern
		screen: root.activePopupScreen
		visible: root.lanternVisible === "media"
		open: root.lanternOpen === "media"
		anchorX: root.lanternAnchorX
		lanternWidth: 460
		contentHeight: mediaContent.implicitHeight
		onDismissRequested: root.closeLantern()
		MediaPopupContent {
			id: mediaContent
			width: parent.width
			reveal: mediaLantern.reveal
			media: media
			popupActive: root.lanternVisible === "media"
			onSparkToClock: {
				// Play sends a spark up the stem and along the thread to the clock.
				const bar = root.barFor(root.activePopupScreen);
				if (bar) bar.sendSpark(bar.beadX("media"), bar.beadX("clock"), () => bar.lightClock());
			}
		}
	}

	Lantern {
		id: clipboardLantern
		screen: root.activePopupScreen
		visible: root.lanternVisible === "clipboard"
		open: root.lanternOpen === "clipboard"
		anchorX: root.lanternAnchorX
		lanternWidth: 380
		fixedHeight: 470
		onDismissRequested: root.closeLantern()
		ClipboardLantern {
			anchors.fill: parent
			reveal: clipboardLantern.reveal
			active: root.lanternVisible === "clipboard"
			onCloseRequested: root.closeLantern()
			onCopied: root.barFor(root.activePopupScreen)?.flash("clipboard")
		}
	}

	Lantern {
		id: bluetoothLantern
		screen: root.activePopupScreen
		visible: root.lanternVisible === "bluetooth"
		open: root.lanternOpen === "bluetooth"
		anchorX: root.lanternAnchorX
		lanternWidth: 340
		contentHeight: bluetooth.implicitHeight
		onDismissRequested: root.closeLantern()
		BluetoothLantern {
			id: bluetooth
			width: parent.width
			reveal: bluetoothLantern.reveal
			active: root.lanternVisible === "bluetooth"
			onConnected: root.barFor(root.activePopupScreen)?.flash("bluetooth")
		}
	}

	Lantern {
		id: networkLantern
		screen: root.activePopupScreen
		visible: root.lanternVisible === "network"
		open: root.lanternOpen === "network"
		anchorX: root.lanternAnchorX
		lanternWidth: 340
		contentHeight: network.implicitHeight
		onDismissRequested: root.closeLantern()
		NetworkLantern {
			id: network
			width: parent.width
			reveal: networkLantern.reveal
			active: root.lanternVisible === "network"
			statusType: root.networkStatusType
			interfaceName: root.networkInterface
			ip: root.networkIp
			onDisconnectRequested: root.disconnectActiveNetwork()
		}
	}

	Lantern {
		id: resourcesLantern
		screen: root.activePopupScreen
		visible: root.lanternVisible === "resources"
		open: root.lanternOpen === "resources"
		anchorX: root.lanternAnchorX
		lanternWidth: 340
		contentHeight: resourcesContent.implicitHeight
		onDismissRequested: root.closeLantern()
		ResourcesLantern {
			id: resourcesContent
			width: parent.width
			reveal: resourcesLantern.reveal
			monitor: resources
		}
	}

	Lantern {
		id: trayLantern
		screen: root.activePopupScreen
		visible: root.lanternVisible === "tray"
		open: root.lanternOpen === "tray"
		anchorX: root.lanternAnchorX
		lanternWidth: Math.max(220, trayMenu.implicitWidth + 16)
		contentHeight: trayMenu.implicitHeight
		margin: 8
		onDismissRequested: root.closeLantern()
		TrayMenuLantern {
			id: trayMenu
			width: parent.width
			reveal: trayLantern.reveal
			handle: root.trayMenuHandle
			onCloseRequested: root.closeLantern()
		}
	}

	// ---------------------------------------------------------------- veils
	Veil {
		id: launcherVeil
		screen: root.activePopupScreen
		visible: root.modalVisible === "launcher"
		open: root.modalOpen === "launcher"
		mode: "hang"
		hangX: root.modalAnchorX
		sheetWidth: Math.min(820, width - 80)
		sheetHeight: Math.min(560, height - 120)
		washOpacity: 0.7
		onDismissRequested: root.closeModal()

		Loader {
			id: launcherLoader
			anchors.fill: parent
			active: true
			sourceComponent: AppLauncherPopup {
				reveal: launcherVeil.reveal
				foreground: Filament.fg
				background: Filament.bg
				secondaryBoxColor: Filament.secondaryBoxColor
				secondaryBoxStrongColor: Filament.secondaryBoxStrongColor
				secondaryInsetColor: Filament.secondaryInsetColor
				barColor: Filament.charge
				danger: Filament.alert
				onCloseRequested: root.closeModal()
				onOpenStudioRequested: page => { root.closeModal(); root.openStudio(page); }
				onLaunchRequested: {
					const bar = root.barFor(root.activePopupScreen);
					if (bar) bar.sendSpark(bar.beadX("launcher"), bar.beadX("clock"), () => bar.lightClock());
				}
			}
		}
	}

	Veil {
		id: studioVeil
		screen: root.activePopupScreen
		visible: root.modalVisible === "studio"
		open: root.modalOpen === "studio"
		mode: "hang"
		sheetWidth: Math.min(1320, width - 80)
		sheetHeight: Math.min(860, height - 100)
		onDismissRequested: root.closeStudio()

		Loader {
			id: studioLoader
			anchors.fill: parent
			active: root.modalVisible === "studio"
			// Studio assigns its own page on Ctrl+Tab, which breaks a binding;
			// push the page from here whenever the shell changes it.
			Connections {
				target: root
				function onStudioPageChanged() { if (studioLoader.item) studioLoader.item.page = root.studioPage; }
			}
			sourceComponent: Studio {
				page: root.studioPage
				reveal: studioVeil.reveal
				foreground: Filament.fg
				background: Filament.bg
				secondaryBoxColor: Filament.secondaryBoxColor
				secondaryBoxStrongColor: Filament.secondaryBoxStrongColor
				secondaryInsetColor: Filament.secondaryInsetColor
				barColor: Filament.charge
				danger: Filament.alert
				onCloseRequested: root.closeStudio()
			}
		}
	}

	Veil {
		id: powerVeil
		screen: root.activePopupScreen
		visible: root.modalVisible === "power"
		open: root.modalOpen === "power"
		mode: "float"
		sheetWidth: Math.min(720, width - 80)
		sheetHeight: 250
		onDismissRequested: root.closeModal()

		Loader {
			id: powerThread
			anchors.fill: parent
			active: root.modalVisible === "power"
			sourceComponent: PowerThread {
				reveal: powerVeil.reveal
				onAction: name => root.runPowerAction(name)
				onCloseRequested: root.closeModal()
			}
		}
	}

	// --------------------------------------------------------------- toasts
	// Each toast is its own window hung under the bell on the primary bar.
	Instantiator {
		model: root.toasts

		PopupWindow {
			id: toastWindow
			required property var modelData
			required property int index
			readonly property var primary: root.primaryBar()
			readonly property real bellX: primary ? primary.beadX("notifications") : 0
			readonly property real slotX: Math.max(8, Math.min(bellX - 190, (primary ? primary.width : 400) - 388))

			anchor.window: primary
			anchor.rect: Qt.rect(slotX, Filament.barHeight + index * (toastContent.implicitHeight + 8), 380, 1)
			anchor.edges: Edges.Top | Edges.Left
			anchor.gravity: Edges.Bottom | Edges.Right
			anchor.adjustment: PopupAdjustment.SlideX
			visible: primary !== null
			color: "transparent"
			implicitWidth: 380
			implicitHeight: toastContent.implicitHeight + 4

			ToastLantern {
				id: toastContent
				width: 380
				first: toastWindow.index === 0
				stemX: toastWindow.bellX - toastWindow.slotX
				notification: toastWindow.modelData.notification
				duration: toastWindow.modelData.duration
				onExpired: root.removeToast(toastWindow.modelData.toastId)
				onDismissed: toastWindow.modelData.notification.dismiss()
				onReply: text => root.submitInlineReply(toastWindow.modelData.notification, text)
			}
		}
	}
}
