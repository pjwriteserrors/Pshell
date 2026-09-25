pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Resolves app / tray / notification icons. Prefers Papirus (indexed once
// at start-up, including .desktop aliases) and falls back to the icon theme.
Singleton {
	id: root

	property var map: ({})

	function setMap(raw) {
		try {
			root.map = JSON.parse(String(raw || "{}"));
		} catch (error) {
			root.map = ({});
		}
	}

	function papirus(icon) {
		if (!icon) return "";
		const raw = String(icon);
		if (raw.startsWith("/") || raw.startsWith("file:") || raw.startsWith("image:") || raw.startsWith("qrc:")) return "";
		const lower = raw.toLowerCase();
		const noDesktop = lower.endsWith(".desktop") ? lower.slice(0, -8) : lower;
		const noExtension = noDesktop.replace(/\.(png|svg|xpm)$/i, "");
		return root.map[lower] || root.map[noDesktop] || root.map[noExtension] || root.map[`${noExtension}.desktop`] || "";
	}

	function app(icon, fallbacks = []) {
		const hit = root.papirus(icon);
		if (hit !== "") return hit;
		for (const fallback of fallbacks) {
			const fallbackHit = root.papirus(fallback);
			if (fallbackHit !== "") return fallbackHit;
		}
		return root.resolveIconSource(icon, fallbacks);
	}

	// window / task icons by app id
	function forAppId(appId) {
		if (!appId) return Quickshell.iconPath("application-x-executable", true);
		const hit = root.papirus(appId);
		if (hit !== "") return hit;
		const direct = Quickshell.iconPath(appId, true);
		if (direct !== "") return direct;
		const normalized = appId.replace(/\.(png|svg|xpm)$/i, "");
		if (normalized !== appId) {
			const normalizedDirect = Quickshell.iconPath(normalized, true);
			if (normalizedDirect !== "") return normalizedDirect;
		}
		const desktopName = appId.endsWith(".desktop") ? appId : `${appId}.desktop`;
		const desktopIcon = Quickshell.iconPath(desktopName, true);
		if (desktopIcon !== "") return desktopIcon;
		return Quickshell.iconPath("application-x-executable", true);
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
		case "preferences-system-notifications-symbolic":
		case "preferences-system-notifications":
			return "/usr/share/icons/Adwaita/symbolic/legacy/preferences-system-notifications-symbolic.svg";
		case "preferences-desktop-wallpaper-symbolic":
		case "preferences-desktop-wallpaper":
			return "/usr/share/icons/Adwaita/symbolic/legacy/preferences-desktop-wallpaper-symbolic.svg";
		case "view-app-grid-symbolic":
		case "view-app-grid":
			return "/usr/share/icons/Adwaita/symbolic/actions/view-app-grid-symbolic.svg";
		case "edit-paste-symbolic":
		case "edit-paste":
			return "/usr/share/icons/Adwaita/symbolic/actions/edit-paste-symbolic.svg";
		case "network-server-symbolic":
		case "network-server":
			return "/usr/share/icons/Adwaita/symbolic/places/network-server-symbolic.svg";
		case "bluetooth-active-symbolic":
		case "bluetooth-active":
			return "/usr/share/icons/Adwaita/symbolic/status/bluetooth-active-symbolic.svg";
		case "network-wired-symbolic":
		case "network-wired":
			return "/usr/share/icons/Adwaita/symbolic/devices/network-wired-symbolic.svg";
		case "network-wireless-signal-excellent-symbolic":
		case "network-wireless-signal-excellent":
			return "/usr/share/icons/Adwaita/symbolic/status/network-wireless-signal-excellent-symbolic.svg";
		case "input-mouse-symbolic":
		case "input-mouse":
			return "/usr/share/icons/Adwaita/symbolic/devices/input-mouse-symbolic.svg";
		case "system-shutdown-symbolic":
		case "system-shutdown":
			return "/usr/share/icons/Adwaita/symbolic/actions/system-shutdown-symbolic.svg";
		case "audio-volume-high-symbolic":
		case "audio-volume-high":
			return "/usr/share/icons/Adwaita/symbolic/status/audio-volume-high-symbolic.svg";
		case "audio-input-microphone-symbolic":
		case "microphone-sensitivity-high-symbolic":
		case "microphone-sensitivity-high":
			return "/usr/share/icons/Adwaita/symbolic/devices/audio-input-microphone-symbolic.svg";
		case "microphone-disabled-symbolic":
		case "microphone-sensitivity-muted-symbolic":
		case "microphone-sensitivity-muted":
			return "/usr/share/icons/Adwaita/symbolic/status/microphone-disabled-symbolic.svg";
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

	Process {
		id: mapProcess
		running: true
		command: ["sh", "-lc", `
python3 - <<'PY'
import json
import os
import shlex
from pathlib import Path

roots = [Path("/usr/share/icons/Papirus"), Path.home() / ".local/share/icons/Papirus"]
sizes = ["48x48", "64x64", "32x32", "24x24", "22x22", "16x16", "scalable"]
contexts = ["apps", "devices", "status", "panel", "symbolic/status", "symbolic/devices"]
icons = {}

def add_alias(name, path):
    if not name or not path:
        return
    key = name.strip().lower()
    if not key:
        return
    icons.setdefault(key, str(path))
    if key.endswith((".png", ".svg", ".xpm")):
        key = Path(key).stem.lower()
        icons.setdefault(key, str(path))
    icons.setdefault(f"{key}.desktop", str(path))

for root in roots:
    for size in sizes:
        for context in contexts:
            icon_dir = root / size / context
            if not icon_dir.is_dir():
                continue
            for path in sorted(icon_dir.iterdir()):
                if path.suffix.lower() not in (".svg", ".png", ".xpm"):
                    continue
                add_alias(path.stem, path)

for path in sorted(Path("/usr/share/icons").glob("*.png")):
    add_alias(path.name, path)

for app_root in (Path("/usr/share/applications"), Path.home() / ".local/share/applications"):
    if not app_root.is_dir():
        continue
    for desktop in sorted(app_root.glob("*.desktop")):
        data = {}
        try:
            for line in desktop.read_text(errors="ignore").splitlines():
                if "=" not in line or line.startswith("[") or line.startswith("#"):
                    continue
                key, value = line.split("=", 1)
                if key in ("Icon", "StartupWMClass", "Exec", "Name"):
                    data.setdefault(key, value.strip())
        except OSError:
            continue
        icon = data.get("Icon", "")
        resolved = None
        icon_key = icon.lower()
        if icon_key in icons:
            resolved = icons[icon_key]
        elif Path(icon_key).stem.lower() in icons:
            resolved = icons[Path(icon_key).stem.lower()]
        elif icon.endswith((".png", ".svg", ".xpm")):
            for candidate in (Path("/usr/share/icons") / icon, Path.home() / ".local/share/icons" / icon):
                if candidate.is_file():
                    resolved = str(candidate)
                    break
        if not resolved:
            continue
        add_alias(desktop.name, resolved)
        add_alias(desktop.stem, resolved)
        add_alias(data.get("StartupWMClass", ""), resolved)
        if data.get("Name"):
            add_alias(data["Name"], resolved)
        if data.get("Exec"):
            try:
                command = shlex.split(data["Exec"])[0]
                add_alias(Path(command).name, resolved)
            except (ValueError, IndexError):
                pass

print(json.dumps(icons, separators=(",", ":")))
PY
`]
		stdout: StdioCollector {
			onStreamFinished: root.setMap(text)
		}
	}
}
