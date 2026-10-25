pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// How the Pshell cursor theme looks, for the cursors the shell draws itself
// (a pointer cannot be given a shape of its own on Wayland, only one of the
// standard ones): the colours and sizes scripts/cursor_theme.py drew the
// theme with (palette.json) and stills of its base cursors. Until the theme
// is built, the Theme's own colours.
Singleton {
	id: root

	readonly property string dir: `${Quickshell.env("XDG_DATA_HOME") || Quickshell.env("HOME") + "/.local/share"}/icons/Pshell`

	property var data: ({})

	readonly property color core: root.data.core ?? Theme.bg
	readonly property color outline: root.data.outline ?? Theme.fg
	readonly property color accent: root.data.accent ?? Theme.primary
	readonly property color danger: root.data.danger ?? Theme.danger
	// px per design unit; 24 units make the cursor's nominal size
	readonly property real unit: root.data.unit ?? 1.3
	readonly property real outlineWidth: (root.data.outlineWidth ?? 1.4) * root.unit
	// the corner radius, after niri's windows
	readonly property real round: (root.data.round ?? 1.2) * root.unit
	// where a badge sits from the pointer's tip
	readonly property point badgeAt: Qt.point((root.data.badge?.[0] ?? 13.6) * root.unit, (root.data.badge?.[1] ?? 16.6) * root.unit)
	readonly property real canvas: (root.data.canvas ?? 30) * root.unit
	readonly property bool ready: root.data.stills !== undefined

	// a still of a base cursor ("arrow", "hand", "cross") and its hotspot in px
	function still(name) {
		const s = root.data.stills?.[name];
		return s ? `file://${root.dir}/${s.file}?${root.stamp}` : "";
	}
	function hotspot(name) {
		const s = root.data.stills?.[name];
		return s ? Qt.point(s.hotspot[0] * root.unit, s.hotspot[1] * root.unit) : Qt.point(0, 0);
	}

	// the stills are rewritten in place: a new address loads them anew
	property int stamp: 0

	FileView {
		path: `${root.dir}/palette.json`
		watchChanges: true
		printErrors: false
		onFileChanged: reload()
		onLoaded: {
			try {
				root.data = JSON.parse(text());
				root.stamp++;
			} catch (error) {}
		}
	}
}
