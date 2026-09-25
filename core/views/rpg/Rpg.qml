import QtQuick
import Quickshell
import Quickshell.Io
import qs.style.theme
import qs.core.services

// Productivity RPG: the engine, its own window (not in the bar, no
// notifications) and its IPC target.
Scope {
	RpgEngine {
		id: game

		statePath: Paths.stateFile("rpg-state.json")
		monitorPath: `${Paths.scripts}/rpg-input-monitor.py`
	}

	RpgWindow {
		id: window

		game: game
		foreground: Theme.fg
		background: Theme.bg
		accent: Theme.primary
		secondaryBoxColor: Theme.layer2
		secondaryBoxStrongColor: Theme.layer3
		secondaryInsetColor: Theme.layer1
	}

	Connections {
		target: Popups
		function onRpgWindowRequested() {
			window.openWindow();
		}
	}

	IpcHandler {
		target: "rpg"

		// the game no longer has a bar popup: every entry point opens its window
		function open(): void {
			window.openWindow();
		}
		function window(): void {
			window.openWindow();
		}
		function windowTab(index: int): void {
			window.showTab(index);
		}
		function windowClose(): void {
			window.closeWindow();
		}
		function close(): void {
			window.closeWindow();
		}
		function toggle(): void {
			if (window.visible) window.closeWindow();
			else window.openWindow();
		}
		function tab(index: int): void {
			window.showTab(index);
		}
		function start(): void {
			game.startExpedition();
		}
		function stop(): void {
			game.stopExpedition();
		}
	}
}
