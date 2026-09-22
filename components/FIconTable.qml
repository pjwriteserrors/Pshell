pragma Singleton

import QtQuick
import Quickshell

// Where a symbolic icon comes from. The icon theme first, then the Adwaita
// files by absolute path, so the bar never shows a blank where a weather or
// audio glyph should be.
QtObject {
	function adwaita(icon) {
		switch (icon) {
		case "dialog-information-symbolic":
		case "dialog-information":
			return "/usr/share/icons/Adwaita/symbolic/status/dialog-information-symbolic.svg";
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
		case "audio-volume-muted-symbolic":
			return "/usr/share/icons/Adwaita/symbolic/status/audio-volume-muted-symbolic.svg";
		case "audio-volume-low-symbolic":
			return "/usr/share/icons/Adwaita/symbolic/status/audio-volume-low-symbolic.svg";
		case "audio-volume-medium-symbolic":
			return "/usr/share/icons/Adwaita/symbolic/status/audio-volume-medium-symbolic.svg";
		case "audio-volume-high-symbolic":
			return "/usr/share/icons/Adwaita/symbolic/status/audio-volume-high-symbolic.svg";
		case "microphone-sensitivity-muted-symbolic":
			return "/usr/share/icons/Adwaita/symbolic/status/microphone-sensitivity-muted-symbolic.svg";
		case "microphone-sensitivity-high-symbolic":
			return "/usr/share/icons/Adwaita/symbolic/status/microphone-sensitivity-high-symbolic.svg";
		case "display-brightness-symbolic":
			return "/usr/share/icons/Adwaita/symbolic/status/display-brightness-symbolic.svg";
		case "network-wired-symbolic":
			return "/usr/share/icons/Adwaita/symbolic/devices/network-wired-symbolic.svg";
		case "network-wireless-signal-excellent-symbolic":
			return "/usr/share/icons/Adwaita/symbolic/status/network-wireless-signal-excellent-symbolic.svg";
		case "network-wireless-offline-symbolic":
			return "/usr/share/icons/Adwaita/symbolic/status/network-wireless-offline-symbolic.svg";
		case "bluetooth-active-symbolic":
			return "/usr/share/icons/Adwaita/symbolic/status/bluetooth-active-symbolic.svg";
		case "bluetooth-disabled-symbolic":
			return "/usr/share/icons/Adwaita/symbolic/status/bluetooth-disabled-symbolic.svg";
		case "edit-paste-symbolic":
			return "/usr/share/icons/Adwaita/symbolic/actions/edit-paste-symbolic.svg";
		case "edit-delete-symbolic":
			return "/usr/share/icons/Adwaita/symbolic/actions/edit-delete-symbolic.svg";
		case "system-shutdown-symbolic":
			return "/usr/share/icons/Adwaita/symbolic/actions/system-shutdown-symbolic.svg";
		case "system-reboot-symbolic":
			return "/usr/share/icons/Adwaita/symbolic/actions/system-reboot-symbolic.svg";
		case "system-log-out-symbolic":
			return "/usr/share/icons/Adwaita/symbolic/actions/system-log-out-symbolic.svg";
		case "system-lock-screen-symbolic":
			return "/usr/share/icons/Adwaita/symbolic/status/system-lock-screen-symbolic.svg";
		case "system-search-symbolic":
			return "/usr/share/icons/Adwaita/symbolic/actions/system-search-symbolic.svg";
		case "view-app-grid-symbolic":
			return "/usr/share/icons/Adwaita/symbolic/actions/view-app-grid-symbolic.svg";
		case "preferences-system-notifications-symbolic":
			return "/usr/share/icons/Adwaita/symbolic/legacy/preferences-system-notifications-symbolic.svg";
		case "media-playback-start-symbolic":
			return "/usr/share/icons/Adwaita/symbolic/actions/media-playback-start-symbolic.svg";
		case "media-playback-pause-symbolic":
			return "/usr/share/icons/Adwaita/symbolic/actions/media-playback-pause-symbolic.svg";
		case "media-skip-forward-symbolic":
			return "/usr/share/icons/Adwaita/symbolic/actions/media-skip-forward-symbolic.svg";
		case "media-skip-backward-symbolic":
			return "/usr/share/icons/Adwaita/symbolic/actions/media-skip-backward-symbolic.svg";
		case "audio-x-generic-symbolic":
			return "/usr/share/icons/Adwaita/symbolic/mimetypes/audio-x-generic-symbolic.svg";
		case "input-mouse-symbolic":
			return "/usr/share/icons/Adwaita/symbolic/devices/input-mouse-symbolic.svg";
		case "drive-harddisk-symbolic":
			return "/usr/share/icons/Adwaita/symbolic/devices/drive-harddisk-symbolic.svg";
		case "folder-symbolic":
			return "/usr/share/icons/Adwaita/symbolic/places/folder-symbolic.svg";
		case "text-x-generic-symbolic":
			return "/usr/share/icons/Adwaita/symbolic/mimetypes/text-x-generic-symbolic.svg";
		case "accessories-calculator-symbolic":
			return "/usr/share/icons/Adwaita/symbolic/legacy/accessories-calculator-symbolic.svg";
		case "user-trash-symbolic":
			return "/usr/share/icons/Adwaita/symbolic/places/user-trash-symbolic.svg";
		case "window-close-symbolic":
			return "/usr/share/icons/Adwaita/symbolic/ui/window-close-symbolic.svg";
		case "go-up-symbolic":
			return "/usr/share/icons/Adwaita/symbolic/actions/go-up-symbolic.svg";
		case "go-previous-symbolic":
			return "/usr/share/icons/Adwaita/symbolic/actions/go-previous-symbolic.svg";
		case "go-next-symbolic":
			return "/usr/share/icons/Adwaita/symbolic/actions/go-next-symbolic.svg";
		case "mail-send-symbolic":
			return "/usr/share/icons/Adwaita/symbolic/actions/mail-send-symbolic.svg";
		case "mail-attachment-symbolic":
			return "/usr/share/icons/Adwaita/symbolic/status/mail-attachment-symbolic.svg";
		case "view-refresh-symbolic":
			return "/usr/share/icons/Adwaita/symbolic/actions/view-refresh-symbolic.svg";
		case "document-edit-symbolic":
			return "/usr/share/icons/Adwaita/symbolic/actions/document-edit-symbolic.svg";
		case "preferences-desktop-wallpaper-symbolic":
			return "/usr/share/icons/Adwaita/symbolic/legacy/preferences-desktop-wallpaper-symbolic.svg";
		case "application-x-executable-symbolic":
			return "/usr/share/icons/Adwaita/symbolic/mimetypes/application-x-executable-symbolic.svg";
		default:
			return "";
		}
	}

	function resolve(icon, fallbacks) {
		const list = fallbacks || [];
		const tryName = name => {
			if (!name) return "";
			const direct = adwaita(name);
			if (direct !== "") return direct;
			return Quickshell.iconPath(name, true) || "";
		};

		if (icon) {
			const value = String(icon);
			if (value.startsWith("/") || value.startsWith("file:") || value.startsWith("image:") || value.startsWith("qrc:"))
				return value;
			const found = tryName(value);
			if (found !== "") return found;
		}

		for (const fallback of list) {
			const found = tryName(fallback);
			if (found !== "") return found;
		}
		return "";
	}

	// Tray icons arrive as "name?path=dir".
	function tray(icon) {
		if (!icon) return "";
		const value = String(icon);
		if (value.includes("?path=")) {
			const parts = value.split("?path=");
			const name = parts[0];
			return Qt.resolvedUrl(`${parts[1]}/${name.slice(name.lastIndexOf("/") + 1)}`);
		}
		return value;
	}
}
