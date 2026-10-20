pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Where the shell keeps things. Runtime state never lives in the repository.
Singleton {
	id: root

	readonly property string home: Quickshell.env("HOME")
	readonly property string shell: Quickshell.shellDir
	readonly property string scripts: `${root.shell}/scripts`
	readonly property string assets: `${root.shell}/assets`
	readonly property string configHome: Quickshell.env("XDG_CONFIG_HOME") || `${root.home}/.config`
	readonly property string state: `${Quickshell.env("XDG_STATE_HOME") || root.home + "/.local/state"}/pshell`
	readonly property string cache: `${Quickshell.env("XDG_CACHE_HOME") || root.home + "/.cache"}/pshell`
	// the theme pipeline's state: the wallpaper, its frame, the palette's history
	readonly property string themeState: Quickshell.env("THEME_STATE_DIR") || `${Quickshell.env("XDG_STATE_HOME") || root.home + "/.local/state"}/quickshell-theme`
	// what is installed per machine and never enters the repository (sound packs)
	readonly property string data: `${Quickshell.env("XDG_DATA_HOME") || root.home + "/.local/share"}/pshell`

	// sockets; PSHELL_RUNTIME_DIR moves them for a shell beside the real one
	readonly property string runtime: Quickshell.env("PSHELL_RUNTIME_DIR") || `${Quickshell.env("XDG_RUNTIME_DIR") || "/tmp"}/pshell`

	function stateFile(name) {
		return `${root.state}/${name}`;
	}

	Process {
		running: true
		command: ["mkdir", "-p", root.state, root.runtime]
	}
}
