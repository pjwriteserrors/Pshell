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

	function stateFile(name) {
		return `${root.state}/${name}`;
	}

	Process {
		running: true
		command: ["mkdir", "-p", root.state]
	}
}
