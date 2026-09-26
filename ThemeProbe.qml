import QtQuick
import Quickshell
import qs.style.theme

// Prints the colour roles of this tree's Theme for the palette in
// $XDG_CACHE_HOME/wal/colors.json. Used by scripts/check_style.py to see how
// closely a style follows the wallpaper. Run: quickshell -p ./ThemeProbe.qml
Scope {
	Timer {
		running: true
		interval: 20

		onTriggered: {
			// every colour the Theme exposes, main's roles and a style's own
			const roles = {};
			for (const name in Theme) {
				const value = Theme[name];
				if (value !== null && typeof value === "object" && value.hsvHue !== undefined && typeof value !== "function")
					roles[name] = String(value);
			}
			console.log(`THEME_PROBE ${JSON.stringify(roles)}`);
			Qt.quit();
		}
	}
}
