pragma ComponentBehavior: Bound

import QtQuick
import Qt.labs.qmlmodels
import qs.style.theme
import qs.core.services
import qs.style.widgets

// One zone of the bar (left, centre, right): the items BarLayout puts here,
// in its order. Items with a text that can shrink (now playing, notes, the
// timer's project) have a `fixedWidth` and want `textWant` more; the zone
// reports both and shares the room the bar hands back among them.
Row {
	id: zone

	required property var bar
	property var ids: []
	// extra width the bar can spare for the texts of this zone
	property real room: 1e6

	readonly property var shown: {
		const out = [];
		for (let i = 0; i < zone.children.length; i += 1) {
			const child = zone.children[i];
			// a text that shrinks keeps its item: its width follows the room, which follows this
			if (child.visible && !(child instanceof Repeater) && (child.textWant !== undefined || child.width > 0.5)) out.push(child);
		}
		return out;
	}
	// width with every text at its narrowest
	readonly property real fixedWidth: zone.shown.reduce((sum, child) => sum + (child.fixedWidth ?? child.width), 0) + zone.spacing * Math.max(0, zone.shown.length - 1)
	readonly property real textWant: zone.shown.reduce((sum, child) => sum + (child.textWant ?? 0), 0)

	// the share of the room for one item, by what it wants
	function roomFor(item) {
		const want = item?.textWant ?? 0;
		if (zone.textWant <= 0) return zone.room;
		return zone.room * want / zone.textWant;
	}

	spacing: 2

	component Quick: BarIcon {
		required property string modelData
		readonly property var entry: BarLayout.byId[modelData] ?? ({})

		bar: zone.bar
		icon: entry.icon ?? "help"
		tooltip: entry.name ?? ""
	}

	Repeater {
		model: zone.ids

		delegate: DelegateChooser {
			role: "modelData"

			DelegateChoice {
				roleValue: "launcher"

				LauncherButton {
					bar: zone.bar
				}
			}

			DelegateChoice {
				roleValue: "workspaces"

				Workspaces {
					bar: zone.bar
				}
			}

			DelegateChoice {
				roleValue: "tray"

				TrayButton {
					bar: zone.bar
				}
			}

			DelegateChoice {
				roleValue: "taskbar"

				Taskbar {
					bar: zone.bar
				}
			}

			DelegateChoice {
				roleValue: "media"

				MediaChip {
					id: media

					bar: zone.bar
					room: zone.roomFor(media)
				}
			}

			DelegateChoice {
				roleValue: "clock"

				ClockButton {
					bar: zone.bar
				}
			}

			DelegateChoice {
				roleValue: "weather"

				WeatherButton {
					bar: zone.bar
				}
			}

			DelegateChoice {
				roleValue: "timer"

				TimerChip {
					id: timer

					bar: zone.bar
					room: zone.roomFor(timer)
				}
			}

			DelegateChoice {
				roleValue: "activity"

				ActivityChips {
					bar: zone.bar
				}
			}

			DelegateChoice {
				roleValue: "notes"

				NotesStrip {
					id: notes

					bar: zone.bar
					room: zone.roomFor(notes)
				}
			}

			DelegateChoice {
				roleValue: "clipboard"

				BarIcon {
					bar: zone.bar
					panelId: "clipboard"
					icon: "clipboard_text_multiple_outline"
					tooltip: "Clipboard history"
					onClicked: toggle()
				}
			}

			DelegateChoice {
				roleValue: "games"

				BarIcon {
					bar: zone.bar
					panelId: "gamebar"
					icon: "gamepad_variant"
					tooltip: Games.running.length > 0 ? "Games · playing" : "Games · right-click for the library"
					iconColor: Games.running.length > 0 ? Theme.success : (active ? Theme.primary : Theme.text)
					onClicked: toggle()
					onRightClicked: Popups.toggleModal("games", zone.bar.screen)
				}
			}

			DelegateChoice {
				roleValue: "ssh"

				BarIcon {
					bar: zone.bar
					panelId: "ssh"
					icon: "server_network"
					tooltip: "SSH logins"
					onClicked: toggle()
				}
			}

			DelegateChoice {
				roleValue: "messages"

				MessagesButton {
					bar: zone.bar
				}
			}

			DelegateChoice {
				roleValue: "status"

				StatusCluster {
					bar: zone.bar
				}
			}

			DelegateChoice {
				roleValue: "notifications"

				BellButton {
					bar: zone.bar
				}
			}

			DelegateChoice {
				roleValue: "power"

				BarIcon {
					bar: zone.bar
					icon: "power"
					tooltip: "Session"
					iconColor: hovered ? Theme.danger : Theme.textMuted
					onClicked: Popups.toggleModal("power", zone.bar.screen)
				}
			}

			// ── one-click buttons ─────────────────────────────────────────
			DelegateChoice {
				roleValue: "screenshot"

				Quick {
					onClicked: Screenshot.region()
				}
			}

			DelegateChoice {
				roleValue: "color-picker"

				Quick {
					onClicked: Screenshot.picker()
				}
			}

			DelegateChoice {
				roleValue: "ocr"

				Quick {
					onClicked: Screenshot.ocr()
				}
			}

			DelegateChoice {
				roleValue: "files"

				Quick {
					onClicked: Files.toggle()
				}
			}

			DelegateChoice {
				roleValue: "game-library"

				Quick {
					onClicked: Popups.toggleModal("games", zone.bar.screen)
				}
			}

			DelegateChoice {
				roleValue: "game-mode"

				Quick {
					tooltip: GameMode.active ? `Game mode${GameMode.title !== "" ? ` · ${GameMode.title}` : ""} · click: ${GameMode.force === "auto" ? "keep off" : "follow the games"}` : "Game mode · click to force it on"
					iconColor: GameMode.active ? Theme.success : (GameMode.force === "off" ? Theme.textSubtle : Theme.text)
					onClicked: GameMode.setForce(GameMode.active ? (GameMode.force === "on" ? "auto" : "off") : (GameMode.force === "off" ? "auto" : "on"))
				}
			}

			DelegateChoice {
				roleValue: "keep-awake"

				Quick {
					iconColor: KeepAwake.active ? Theme.warning : Theme.text
					onClicked: KeepAwake.toggle()
				}
			}

			DelegateChoice {
				roleValue: "dnd"

				Quick {
					icon: Notifs.dnd ? "bell_off_outline" : "bell_outline"
					iconColor: Notifs.dnd ? Theme.primary : Theme.text
					onClicked: Notifs.toggleDnd()
				}
			}

			DelegateChoice {
				roleValue: "overview"

				Quick {
					panelId: "overview"
					onClicked: toggle()
				}
			}

			DelegateChoice {
				roleValue: "updates"

				Quick {
					panelId: "updates"
					onClicked: toggle()
				}
			}

			DelegateChoice {
				roleValue: "breaks"

				Quick {
					panelId: "breaks"
					onClicked: toggle()
				}
			}

			DelegateChoice {
				roleValue: "screentime"

				Quick {
					panelId: "screentime"
					onClicked: toggle()
				}
			}

			DelegateChoice {
				roleValue: "tracking"

				Quick {
					panelId: "tracking"
					onClicked: toggle()
				}
			}

			DelegateChoice {
				roleValue: "todos"

				Quick {
					onClicked: Popups.open("launcher", zone.bar.screen, "", ">todo ")
				}
			}

			DelegateChoice {
				roleValue: "translate"

				Quick {
					onClicked: Popups.open("launcher", zone.bar.screen, "", ">t ")
				}
			}

			DelegateChoice {
				roleValue: "torrents"

				Quick {
					onClicked: Torrents.toggle()
				}
			}

			DelegateChoice {
				roleValue: "printer"

				Quick {
					panelId: "printer"
					onClicked: toggle()
				}
			}

			DelegateChoice {
				roleValue: "watch"

				Quick {
					panelId: "watch"
					onClicked: toggle()
				}
			}

			DelegateChoice {
				roleValue: "identities"

				Quick {
					onClicked: Identities.toggle()
				}
			}

			DelegateChoice {
				roleValue: "vm"

				Quick {
					onClicked: Popups.toggleModal("vm", zone.bar.screen)
				}
			}

			DelegateChoice {
				roleValue: "studio"

				Quick {
					onClicked: Popups.openStudio("", zone.bar.screen)
				}
			}

			DelegateChoice {
				roleValue: "settings"

				Quick {
					onClicked: Popups.toggleModal("niri", zone.bar.screen)
				}
			}

			DelegateChoice {
				roleValue: "lock"

				Quick {
					onClicked: Session.lock()
				}
			}
		}
	}
}
