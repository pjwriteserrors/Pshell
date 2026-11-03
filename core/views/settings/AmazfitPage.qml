pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services
import qs.core.views.settings.mouse
import qs.core.views.settings.amazfit
import Quickshell

// An Amazfit watch on Zepp OS (core/services/Amazfit.qml): the watch, live;
// its Zepp OS link (the auth key); what its keys do; every setting it reports
// (by group, the ones nobody named yet too); alarms, faces, apps, menus,
// notifications and canned replies, reminders, the calendar, world clocks,
// vibrations, the body it measures, and what it offers over Bluetooth.
SettingsPage {
	id: root

	title: "Amazfit watch"
	description: ""
	recording: picker.recording

	signal open(string page)

	property string control: "play"
	property string app: ""

	onActiveChanged: {
		Amazfit.watching = root.active;
		if (root.active) Amazfit.refresh();
	}
	Component.onDestruction: Amazfit.watching = false

	readonly property bool has: Amazfit.online
	readonly property bool zepp: Amazfit.zeppReady
	readonly property var dev: Amazfit.device
	readonly property var zs: Amazfit.zepp
	readonly property var caps: root.zs.caps ?? ({})

	function hhmm(h, m) {
		return `${String(h).padStart(2, "0")}:${String(m).padStart(2, "0")}`;
	}

	readonly property var days: ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"]

	// ── the watch, live ────────────────────────────────────────────────────
	SettingCard {
		anchor: "amazfit-device"
		title: !Amazfit.scanned ? "Looking for the watch …" : (root.has ? Amazfit.name : (Amazfit.present ? `${Amazfit.name} · not connected` : "No Amazfit watch paired"))
		subtitle: root.has ? [Amazfit.battery !== null ? `Battery ${Amazfit.battery} %${Amazfit.charging ? " · charging" : ""}` : "", Amazfit.info.software ? `Zepp OS firmware ${Amazfit.info.software}` : "", root.zepp ? "Zepp OS link up" : (Amazfit.keySet ? "" : "Plain Bluetooth – set the auth key below for the rest")].filter(s => s).join(" · ")
			: (Amazfit.present ? (Amazfit.connecting ? "Connecting …" : "Asleep, away or on another PC – it comes back by itself") : "Pair it with this PC once (the Bluetooth panel); the phone keeps its own link")
		icon: root.has ? "watch" : "watch_vibrate"

		trailing: RowLayout {
			spacing: 6

			TextButton {
				visible: root.zepp
				variant: "ghost"
				icon: "watch_vibrate"
				text: "Find"
				onActivated: Amazfit.ownOp("findwatch")
			}

			TextButton {
				visible: Amazfit.present
				variant: root.has ? "ghost" : "tonal"
				icon: root.has ? "bluetooth_off" : "bluetooth_connect"
				text: root.has ? "Disconnect" : (Amazfit.connecting ? "Connecting …" : "Connect")
				enabled: !Amazfit.connecting
				onActivated: root.has ? Amazfit.disconnect() : Amazfit.connect()
			}
		}

		AmazfitFigure {
			Layout.fillWidth: true
			Layout.preferredHeight: 300
			online: root.has
			battery: Amazfit.battery
			charging: Amazfit.charging
			hr: Date.now() - Amazfit.hrAt < 15000 ? Amazfit.hr : 0
			time: Amazfit.clock?.text?.slice(11, 16) ?? ""
			keys: Amazfit.keys
			zepp: Amazfit.zeppState
		}

		StyledText {
			Layout.fillWidth: true
			visible: Amazfit.error !== ""
			text: Amazfit.error
			tone: Theme.danger
			wrapMode: Text.Wrap
		}

		GridLayout {
			Layout.fillWidth: true
			Layout.leftMargin: 12
			visible: root.has
			columns: 4
			columnSpacing: 16
			rowSpacing: 4

			Repeater {
				model: [
					["Clock", Amazfit.clock ? `${Amazfit.clock.text.slice(11)} · ${Amazfit.clock.drift >= 0 ? "+" : ""}${Amazfit.clock.drift} s` : "—"],
					["Heart rate", Date.now() - Amazfit.hrAt < 15000 && Amazfit.hr ? `${Amazfit.hr} bpm` : "not shared"],
					["Steps", root.zs.steps !== null && root.zs.steps !== undefined ? `${root.zs.steps}` : "—"],
					["Last charge", root.zs.battery?.lastCharge ? `${root.zs.battery.lastCharge.slice(0, 16)} · ${root.zs.battery.lastLevel} %` : "—"]
				]

				delegate: ColumnLayout {
					required property var modelData

					spacing: 0

					StyledText {
						text: modelData[0]
						tone: Theme.textSubtle
						font.pixelSize: Theme.size.small
					}

					StyledText {
						text: modelData[1]
					}
				}
			}
		}

		RowLayout {
			Layout.fillWidth: true
			visible: root.has
			spacing: 6

			TextButton {
				variant: "ghost"
				icon: "clock_check_outline"
				text: "Set its time"
				onActivated: Amazfit.syncTime()
			}

			TextButton {
				variant: "ghost"
				icon: "heart_pulse"
				text: root.zepp ? "Measure heart rate" : "Heart rate"
				enabled: root.zepp
				onActivated: Amazfit.liveHr(true)
			}

			Item {
				Layout.fillWidth: true
			}

			TextButton {
				variant: "ghost"
				icon: "refresh"
				text: "Read again"
				onActivated: Amazfit.refresh()
			}
		}
	}

	// ── Zepp OS ────────────────────────────────────────────────────────────
	SettingCard {
		anchor: "amazfit-zepp"
		title: "Zepp OS link"
		subtitle: ({
				ready: "Authenticated – every setting below is the watch's own",
				nokey: "No auth key yet: only battery, clock, heart rate and keys",
				handshake: "Authenticating …",
				wrongkey: "The watch refused the key – it is not the one it was paired with",
				failed: `Failed: ${Amazfit.device.zepp?.detail ?? ""}`,
				absent: "This watch offers no Zepp OS channel",
				idle: root.has ? "Starting …" : "Comes up when the watch is connected"
			})[Amazfit.zeppState] ?? Amazfit.zeppState
		icon: root.zepp ? "lock_check" : "lock_outline"

		RowLayout {
			Layout.fillWidth: true
			Layout.leftMargin: 12
			spacing: 12

			StyledText {
				text: "Auth key"
				tone: Theme.textMuted
			}

			Field {
				id: keyField

				Layout.fillWidth: true
				text: Amazfit.option("key", "")
				placeholder: "32 hex digits, e.g. 0x8a5f…"
				password: true
				icon: "key"
				clearable: false
				onAccepted: Amazfit.setKey(keyField.text)
			}

			TextButton {
				variant: "tonal"
				text: "Use"
				enabled: /^(0x)?[0-9a-fA-F]{32}$/.test(keyField.text.trim())
				onActivated: Amazfit.setKey(keyField.text)
			}
		}

		StyledText {
			Layout.fillWidth: true
			Layout.leftMargin: 12
			text: "The key the watch was paired with: Gadgetbridge shows it in the watch's settings (Auth key) – the one it was given when you paired it there, or the one fetched from Zepp's servers (huafetcher). It stays in amazfit.json (only you can read it) and never leaves this PC. The phone's own link keeps working: this is a second session on the PC's own connection."
			tone: Theme.textSubtle
			wrapMode: Text.Wrap
		}
	}

	// ── what its keys do ───────────────────────────────────────────────────
	SettingCard {
		anchor: "amazfit-keys"
		visible: root.has
		title: "Keys"
		subtitle: "The music remote and the camera shutter send media keys; Zepp OS's music app sends its own buttons"
		icon: "gesture_tap"

		Flow {
			Layout.fillWidth: true
			spacing: 6

			Repeater {
				model: Amazfit.controls

				delegate: Chip {
					required property var modelData

					text: modelData.label
					icon: modelData.icon
					selected: root.control === modelData.id || Amazfit.keys[modelData.id] === true
					onClicked: root.control = modelData.id
				}
			}
		}

		Flow {
			Layout.fillWidth: true
			spacing: 6

			Chip {
				text: "Everywhere"
				selected: root.app === ""
				onClicked: root.app = ""
			}

			Repeater {
				model: Amazfit.apps

				delegate: Chip {
					required property string modelData

					text: modelData
					selected: root.app === modelData
					onClicked: root.app = modelData
				}
			}

			Chip {
				visible: Amazfit.focusApp !== "" && !Amazfit.apps.includes(Amazfit.focusApp)
				text: Amazfit.focusApp
				icon: "plus"
				onClicked: {
					Amazfit.addApp(Amazfit.focusApp);
					root.app = Amazfit.focusApp;
				}
			}
		}

		BindRow {
			app: root.app
			control: root.control
			onPick: control => picker.show(control, "click", root.app)
		}

		StyledText {
			Layout.fillWidth: true
			Layout.leftMargin: 12
			text: Amazfit.controls.find(c => c.id === root.control)?.detail ?? ""
			tone: Theme.textSubtle
		}

		ActionPicker {
			id: picker

			store: Amazfit
			onChosen: (action, extra) => Amazfit.assign(picker.control, "click", picker.app, action, extra)
			onCleared: Amazfit.assign(picker.control, "click", picker.app, null)
		}

		FlagRow {
			icon: "gesture_tap"
			title: "Keys through the shell"
			subtitle: Amazfit.option("buttons", true) ? (root.dev.grabbed ? "Taken from the apps; the shell runs them" : "The shell runs them") : "They reach the focused window as media keys"
			checked: Amazfit.option("buttons", true)
			onToggled: on => Amazfit.setOption("buttons", on)
		}

		RowLayout {
			Layout.fillWidth: true
			Layout.leftMargin: 12
			spacing: 8

			StyledText {
				Layout.fillWidth: true
				text: root.dev.hiddenReport ? `Report 1 (not in the report map): ${Amazfit.hidden || "nothing sent yet"}` : ""
				tone: Theme.textSubtle
				font.family: Theme.monoFamily
				elide: Text.ElideRight
			}

			TextButton {
				variant: "ghost"
				icon: "play"
				text: "Try the key"
				onActivated: Amazfit.press(root.control)
			}
		}
	}

	component BindRow: Clickable {
		id: bind

		property string app: ""
		property string control: ""
		readonly property var rule: Amazfit.ruleFor(bind.control, "click", bind.app)
		readonly property var shown: Amazfit.describe(Amazfit.effective(bind.control, "click", bind.app)?.action ?? null, bind.control)
		property bool lit: false

		Layout.fillWidth: true
		implicitHeight: 52
		radius: Theme.radius.large
		color: bind.lit ? Theme.primaryContainer : Theme.layer2
		signal pick(string control)

		onClicked: bind.pick(bind.control)

		Behavior on color {
			ColorAnim {}
		}

		Connections {
			target: Amazfit

			function onFired(rule, control, trigger) {
				if (control === bind.control) {
					bind.lit = true;
					unlight.restart();
				}
			}
		}

		Timer {
			id: unlight

			interval: 600
			onTriggered: bind.lit = false
		}

		RowLayout {
			anchors.fill: parent
			anchors.leftMargin: 16
			anchors.rightMargin: 12
			spacing: 12

			Glyph {
				icon: Amazfit.controls.find(c => c.id === bind.control)?.icon ?? "gesture_tap"
				size: 18
				color: Theme.textMuted
			}

			StyledText {
				Layout.preferredWidth: 90
				text: "Does"
				font.weight: Font.Medium
			}

			Glyph {
				visible: bind.shown.icon !== ""
				icon: bind.shown.icon
				size: 16
				color: bind.rule ? Theme.primary : Theme.textSubtle
			}

			StyledText {
				Layout.fillWidth: true
				text: bind.shown.label
				tone: bind.rule ? Theme.text : Theme.textSubtle
				elide: Text.ElideRight
			}

			IconButton {
				visible: !!bind.rule
				implicitWidth: 30
				implicitHeight: 30
				icon: "close"
				variant: "ghost"
				onClicked: Amazfit.assign(bind.control, "click", bind.app, null)
			}

			Glyph {
				icon: "chevron_right"
				size: 16
				color: Theme.textFaint
			}
		}
	}

	// ── every setting the watch reports, by group ─────────────────────────
	Repeater {
		model: root.zepp ? Object.keys(root.zs.config ?? {}).sort((a, b) => (root.zs.config[a].id ?? 0) - (root.zs.config[b].id ?? 0)) : []

		delegate: SettingCard {
			id: groupCard

			required property string modelData
			readonly property var group: root.zs.config[groupCard.modelData]
			readonly property var entries: Object.values(groupCard.group?.args ?? {}).sort((a, b) => (a.key ? 0 : 1) - (b.key ? 0 : 1) || a.code - b.code)

			anchor: `amazfit-${groupCard.modelData}`
			title: Amazfit.catalog.groups[groupCard.modelData]?.label ?? `Group 0x${groupCard.modelData}`
			subtitle: `${groupCard.entries.length} settings${groupCard.entries.some(e => !e.key) ? ` · ${groupCard.entries.filter(e => !e.key).length} nobody has named yet` : ""} · version ${groupCard.group?.version ?? "?"}`
			icon: ({ display: "monitor", sound: "volume_high", lockscreen: "lock", wearing: "watch", voice: "microphone", language: "translate", health: "heart_pulse", workout: "run", system: "cog", bluetooth: "bluetooth", agps: "crosshairs_gps" })[groupCard.modelData] ?? "tune"

			Repeater {
				model: groupCard.entries

				delegate: SettingRow {
					required property var modelData

					group: groupCard.modelData
					entry: modelData
				}
			}
		}
	}

	// ── what it measured ───────────────────────────────────────────────────
	SettingCard {
		anchor: "amazfit-health"
		visible: root.zepp
		title: "Health data"
		subtitle: Amazfit.fetching ? "Fetching from the watch …" : (Amazfit.healthAt ? `Fetched ${new Date(Amazfit.healthAt).toLocaleTimeString(Qt.locale(), "HH:mm")} – kept on the watch too, so the phone gets it as well` : "Steps, heart, sleep stages, stress, blood oxygen, temperature, breathing, HRV, PAI – after it connects and every 30 min")
		icon: "heart_pulse"

		FlagRow {
			icon: "sync"
			title: "Fetch from the watch"
			subtitle: "The data stays on the watch (the phone app or Gadgetbridge still gets it)"
			checked: Amazfit.option("health", true)
			onToggled: on => Amazfit.setOption("health", on)
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 6

			TextButton {
				variant: "tonal"
				icon: "download"
				text: "Fetch now"
				enabled: !Amazfit.fetching
				onActivated: Amazfit.fetchHealth()
			}

			TextButton {
				variant: "ghost"
				icon: "chart_line"
				text: "Open the overview"
				onActivated: Quickshell.execDetached(["qs", "ipc", "-p", Quickshell.shellDir, "call", "watch", "open"])
			}
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 6

			Field {
				id: gbPath

				Layout.fillWidth: true
				placeholder: "Gadgetbridge database export (Gadgetbridge → Settings → Export database), e.g. ~/Downloads/Gadgetbridge.db"
				icon: "database_import"
			}

			TextButton {
				variant: "tonal"
				text: "Import"
				enabled: gbPath.text.trim() !== ""
				onActivated: Amazfit.importGadgetbridge(gbPath.text.trim())
			}
		}

		StyledText {
			Layout.fillWidth: true
			Layout.leftMargin: 12
			text: Amazfit.imported || "The watch hands out only what Gadgetbridge has not fetched yet (Gadgetbridge clears it): the history before that is in Gadgetbridge's database – import its export once."
			tone: Theme.textSubtle
			wrapMode: Text.Wrap
		}
	}

	// ── what a hidden setting is ───────────────────────────────────────────
	SettingCard {
		anchor: "amazfit-hidden"
		visible: root.zepp
		title: "Hidden settings"
		subtitle: "The watch has settings nobody has named. Tell them apart: remember the watch's settings, change one thing in the watch's own menu, then ask what changed."
		icon: "eye_off_outline"

		RowLayout {
			Layout.fillWidth: true
			spacing: 6

			TextButton {
				variant: "tonal"
				icon: "camera_outline"
				text: Amazfit.comparing === "waiting" ? "Reading …" : "1 · Remember now"
				enabled: Amazfit.comparing !== "waiting"
				onActivated: Amazfit.remember()
			}

			StyledText {
				Layout.fillWidth: true
				text: Amazfit.comparing === "ready" ? "2 · Now change one setting on the watch …" : (Amazfit.comparing === "done" ? `${Amazfit.changes.length} changed` : "")
				tone: Theme.textMuted
			}

			TextButton {
				variant: "tonal"
				icon: "compare_horizontal"
				text: "3 · What changed?"
				enabled: Amazfit.comparing === "ready" || Amazfit.comparing === "done"
				onActivated: Amazfit.compare()
			}
		}

		Repeater {
			model: Amazfit.changes

			delegate: RowLayout {
				id: change

				required property var modelData

				Layout.fillWidth: true
				Layout.leftMargin: 12
				spacing: 10

				StyledText {
					Layout.preferredWidth: 220
					text: `${Amazfit.catalog.groups[change.modelData.group]?.label ?? change.modelData.group} · 0x${Number(change.modelData.code).toString(16).padStart(2, "0")}`
					font.weight: Font.Medium
				}

				StyledText {
					Layout.preferredWidth: 200
					text: `${JSON.stringify(change.modelData.old)} → ${JSON.stringify(change.modelData.new)}`
					font.family: Theme.monoFamily
					tone: Theme.textMuted
					elide: Text.ElideRight
				}

				Field {
					id: givenName

					Layout.fillWidth: true
					visible: !change.modelData.key || Amazfit.argOf(change.modelData.group, change.modelData.code)?.guess === true
					text: Amazfit.option("names", {})[change.modelData.id] ?? ""
					placeholder: "What is it on the watch? (name it)"
					onAccepted: Amazfit.setName(change.modelData.id, givenName.text)
				}

				StyledText {
					Layout.fillWidth: true
					visible: !givenName.visible
					text: Amazfit.argOf(change.modelData.group, change.modelData.code)?.label ?? ""
				}
			}
		}
	}

	// ── alarms ─────────────────────────────────────────────────────────────
	SettingCard {
		anchor: "amazfit-alarms"
		visible: root.zepp
		title: "Alarms"
		subtitle: `${(root.zs.alarms ?? []).filter(a => a.enabled).length} on · smart ones wake you at the best moment: in light sleep, up to 10–50 min before the time`
		icon: "alarm"

		Repeater {
			model: root.zs.alarms ?? []

			delegate: RowLayout {
				id: alarm

				required property var modelData

				Layout.fillWidth: true
				Layout.leftMargin: 12
				spacing: 10

				Field {
					id: alarmTime

					Layout.preferredWidth: 90
					text: root.hhmm(alarm.modelData.hour, alarm.modelData.minute)
					clearable: false
					onAccepted: {
						const m = /^(\d{1,2}):(\d{2})$/.exec(alarmTime.text.trim());
						if (m) Amazfit.call("set_alarm", { position: alarm.modelData.position, hour: Number(m[1]), minute: Number(m[2]), repeat: alarm.modelData.repeat, enabled: alarm.modelData.enabled, smart: alarm.modelData.smart, window: alarm.modelData.window ?? 0 });
					}
				}

				Repeater {
					model: 7

					delegate: Chip {
						required property int index

						text: root.days[index]
						selected: (alarm.modelData.repeat & (1 << index)) !== 0
						onClicked: Amazfit.call("set_alarm", { position: alarm.modelData.position, hour: alarm.modelData.hour, minute: alarm.modelData.minute, repeat: alarm.modelData.repeat ^ (1 << index), enabled: alarm.modelData.enabled, smart: alarm.modelData.smart, window: alarm.modelData.window ?? 0 })
					}
				}

				// smart wake: in light sleep up to this many minutes early; a tap goes on to the next window
				Chip {
					readonly property var windows: [0, 10, 20, 30, 40, 50]
					text: alarm.modelData.smart ? `Smart · ${alarm.modelData.window} min` : "Smart"
					icon: "sleep"
					selected: alarm.modelData.smart
					onClicked: {
						const next = windows[(windows.indexOf(alarm.modelData.smart ? alarm.modelData.window : 0) + 1) % windows.length];
						Amazfit.call("set_alarm", { position: alarm.modelData.position, hour: alarm.modelData.hour, minute: alarm.modelData.minute, repeat: alarm.modelData.repeat, enabled: alarm.modelData.enabled, smart: next > 0, window: next });
					}
				}

				Item {
					Layout.fillWidth: true
				}

				Toggle {
					checked: alarm.modelData.enabled
					onToggled: on => Amazfit.call("set_alarm", { position: alarm.modelData.position, hour: alarm.modelData.hour, minute: alarm.modelData.minute, repeat: alarm.modelData.repeat, enabled: on, smart: alarm.modelData.smart, window: alarm.modelData.window ?? 0 })
				}

				IconButton {
					implicitWidth: 30
					implicitHeight: 30
					icon: "delete_outline"
					variant: "ghost"
					onClicked: Amazfit.call("delete_alarm", { position: alarm.modelData.position })
				}
			}
		}

		TextButton {
			variant: "tonal"
			icon: "plus"
			text: "Add an alarm"
			enabled: (root.zs.alarms ?? []).length < 10
			onActivated: {
				const used = (root.zs.alarms ?? []).map(a => a.position);
				let pos = 0;
				while (used.includes(pos)) pos++;
				Amazfit.call("set_alarm", { position: pos, hour: 7, minute: 0, repeat: 0x1f, enabled: true, smart: false });
			}
		}
	}

	// ── faces and apps ─────────────────────────────────────────────────────
	SettingCard {
		anchor: "amazfit-faces"
		visible: root.zepp
		title: "Watch faces"
		subtitle: `${(root.zs.faces ?? []).length} on the watch`
		icon: "watch"

		Flow {
			Layout.fillWidth: true
			spacing: 6

			Repeater {
				model: root.zs.faces ?? []

				delegate: Chip {
					required property var modelData

					text: modelData.name || modelData.id
					icon: root.zs.face === modelData.id ? "check" : "watch"
					selected: root.zs.face === modelData.id
					onClicked: Amazfit.call("set_face", { hexid: modelData.id })
				}
			}
		}

		StyledText {
			Layout.fillWidth: true
			Layout.leftMargin: 12
			text: "Faces without a name are installed ones (the shell's own face among them). Installing new faces and apps goes through Gadgetbridge or watch/ (zeus)."
			tone: Theme.textSubtle
			wrapMode: Text.Wrap
		}
	}

	SettingCard {
		anchor: "amazfit-apps"
		visible: root.zepp
		title: "Apps"
		subtitle: `${(root.zs.apps ?? []).length} installed${root.caps.apiLevel ? ` · API level ${root.caps.apiLevel}` : ""}`
		icon: "apps"

		Repeater {
			model: root.zs.apps ?? []

			delegate: RowLayout {
				required property var modelData

				Layout.fillWidth: true
				Layout.leftMargin: 12

				StyledText {
					Layout.preferredWidth: 120
					text: modelData.id
					font.family: Theme.monoFamily
				}

				StyledText {
					Layout.fillWidth: true
					text: `version ${modelData.version}`
					tone: Theme.textMuted
				}

				TextButton {
					variant: "ghost"
					icon: "delete_outline"
					text: "Remove"
					confirm: true
					confirmText: "Remove from the watch?"
					onActivated: Amazfit.call("delete_app", { hexid: modelData.id })
				}
			}
		}
	}

	// ── menus: the app list, shortcuts, the control centre ────────────────
	Repeater {
		model: root.zepp ? [["menu", 1, "Apps menu", "view_grid"], ["shortcuts", 2, "Shortcut cards", "gesture_swipe_left"], ["control", 3, "Control centre", "toggle_switch"]].filter(m => (root.zs.menus ?? {})[m[0]]) : []

		delegate: SettingCard {
			id: menuCard

			required property var modelData
			readonly property var items: (root.zs.menus ?? {})[menuCard.modelData[0]] ?? []
			readonly property var enabledItems: menuCard.items.filter(i => i.section !== 3).sort((a, b) => a.section - b.section || a.position - b.position)
			readonly property var disabledItems: menuCard.items.filter(i => i.section === 3)

			function save(enabled, disabled) {
				Amazfit.call("set_menu", { kind: menuCard.modelData[1], enabled: enabled.map(i => i.id), disabled: disabled.map(i => i.id) });
			}

			anchor: `amazfit-${menuCard.modelData[0]}`
			title: menuCard.modelData[2]
			subtitle: `${menuCard.enabledItems.length} shown · ${menuCard.disabledItems.length} hidden`
			icon: menuCard.modelData[3]

			Repeater {
				model: menuCard.enabledItems

				delegate: RowLayout {
					required property var modelData
					required property int index

					Layout.fillWidth: true
					Layout.leftMargin: 12
					spacing: 6

					StyledText {
						Layout.fillWidth: true
						text: Amazfit.itemName(menuCard.modelData[0], modelData.id)
					}

					IconButton {
						implicitWidth: 28
						implicitHeight: 28
						icon: "arrow_up"
						enabled: index > 0
						onClicked: {
							const e = menuCard.enabledItems.slice();
							[e[index - 1], e[index]] = [e[index], e[index - 1]];
							menuCard.save(e, menuCard.disabledItems);
						}
					}

					IconButton {
						implicitWidth: 28
						implicitHeight: 28
						icon: "arrow_down"
						enabled: index < menuCard.enabledItems.length - 1
						onClicked: {
							const e = menuCard.enabledItems.slice();
							[e[index + 1], e[index]] = [e[index], e[index + 1]];
							menuCard.save(e, menuCard.disabledItems);
						}
					}

					IconButton {
						implicitWidth: 28
						implicitHeight: 28
						icon: "eye_off_outline"
						onClicked: {
							const e = menuCard.enabledItems.slice();
							const [gone] = e.splice(index, 1);
							menuCard.save(e, menuCard.disabledItems.concat([gone]));
						}
					}
				}
			}

			Flow {
				Layout.fillWidth: true
				spacing: 6

				Repeater {
					model: menuCard.disabledItems

					delegate: Chip {
						required property var modelData
						required property int index

						text: Amazfit.itemName(menuCard.modelData[0], modelData.id)
						icon: "plus"
						onClicked: {
							const d = menuCard.disabledItems.slice();
							const [back] = d.splice(index, 1);
							menuCard.save(menuCard.enabledItems.concat([back]), d);
						}
					}
				}
			}
		}
	}

	// ── notifications, replies, music, weather ─────────────────────────────
	SettingCard {
		anchor: "amazfit-notifications"
		visible: root.has
		title: "From the PC"
		subtitle: root.zepp ? "What the watch shows and does for this PC" : "Needs the Zepp OS link"
		icon: "bell_ring_outline"

		FlagRow {
			icon: "bell_outline"
			title: "Notifications on the watch"
			subtitle: "Dismissed on the watch, dismissed here; a reply goes back to apps that take one"
			checked: Amazfit.option("notify", true)
			onToggled: on => Amazfit.setOption("notify", on)
		}

		FlagRow {
			icon: "bell_off_outline"
			title: "Not while Do not disturb is on"
			checked: Amazfit.option("notifyDnd", true)
			onToggled: on => Amazfit.setOption("notifyDnd", on)
		}

		FlagRow {
			icon: "sync"
			title: "Do not disturb, both ways"
			subtitle: "The watch's silent mode follows the PC's, and the other way round"
			checked: Amazfit.option("dndSync", false)
			onToggled: on => Amazfit.setOption("dndSync", on)
		}

		FlagRow {
			icon: "music"
			title: "What plays, on the watch's music app"
			subtitle: root.zs.musicOpen ? "The music app is open now" : "Title, artist, position and volume while it is open"
			checked: Amazfit.option("music", true)
			onToggled: on => Amazfit.setOption("music", on)
		}

		FlagRow {
			icon: "weather_partly_cloudy"
			title: "Weather for the watch"
			subtitle: isFinite(Weather.latitude) ? `${Weather.location || Weather.city} – the shell's place, from open-meteo` : "Set a city in the shell's weather first"
			checked: Amazfit.option("weatherOn", true)
			onToggled: on => Amazfit.setOption("weatherOn", on)
		}

		FlagRow {
			icon: "cellphone_sound"
			title: "Ring when the watch looks for the PC"
			checked: Amazfit.option("findSound", true)
			onToggled: on => Amazfit.setOption("findSound", on)
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 6

			TextButton {
				variant: "tonal"
				icon: "bell_ring"
				text: "Send a test"
				enabled: root.zepp
				onActivated: Amazfit.send({ op: "notify", id: 4711, title: "Pshell", body: "A test from the PC", app: "dev.pshell", source: "Pshell" })
			}

			TextButton {
				variant: "ghost"
				icon: "message_alert_outline"
				text: "Plain Bluetooth alert"
				enabled: root.has
				onActivated: Amazfit.send({ op: "alert", category: 0, text: "Pshell" })
			}
		}
	}

	SettingCard {
		anchor: "amazfit-canned"
		visible: root.zepp
		title: "Quick replies"
		subtitle: "Up to 16, for answering on the watch"
		icon: "message_reply_text_outline"

		Repeater {
			model: (root.zs.canned ?? []).length ? root.zs.canned.map(c => c.text) : Amazfit.option("canned", [])

			delegate: RowLayout {
				required property string modelData
				required property int index

				Layout.fillWidth: true
				Layout.leftMargin: 12

				Field {
					id: reply

					Layout.fillWidth: true
					text: modelData
					clearable: false
					onAccepted: {
						const list = ((root.zs.canned ?? []).length ? root.zs.canned.map(c => c.text) : Amazfit.option("canned", [])).slice();
						list[index] = reply.text;
						Amazfit.setOption("canned", list);
						Amazfit.call("set_canned", { texts: list });
					}
				}

				IconButton {
					implicitWidth: 30
					implicitHeight: 30
					icon: "delete_outline"
					onClicked: {
						const list = ((root.zs.canned ?? []).length ? root.zs.canned.map(c => c.text) : Amazfit.option("canned", [])).slice();
						list.splice(index, 1);
						Amazfit.setOption("canned", list);
						Amazfit.call("set_canned", { texts: list });
					}
				}
			}
		}

		Field {
			id: newReply

			Layout.fillWidth: true
			placeholder: "A new reply …"
			icon: "plus"
			onAccepted: {
				if (!newReply.text.trim()) return;
				const list = ((root.zs.canned ?? []).length ? root.zs.canned.map(c => c.text) : Amazfit.option("canned", [])).concat([newReply.text.trim()]).slice(0, 16);
				Amazfit.setOption("canned", list);
				Amazfit.call("set_canned", { texts: list });
				newReply.text = "";
			}
		}
	}

	// ── reminders and the calendar ─────────────────────────────────────────
	SettingCard {
		anchor: "amazfit-reminders"
		visible: root.zepp && root.caps.reminders !== undefined
		title: "Reminders"
		subtitle: `${(root.zs.reminders ?? []).length} of ${root.caps.reminders ?? 0}`
		icon: "bell_alert_outline"

		Repeater {
			model: root.zs.reminders ?? []

			delegate: RowLayout {
				required property var modelData

				Layout.fillWidth: true
				Layout.leftMargin: 12

				StyledText {
					Layout.preferredWidth: 140
					text: new Date(modelData.time * 1000).toLocaleString(Qt.locale(), "ddd d MMM HH:mm")
					tone: Theme.textMuted
				}

				StyledText {
					Layout.fillWidth: true
					text: modelData.text
					elide: Text.ElideRight
				}

				StyledText {
					text: modelData.flags & 0x2000 ? "yearly" : modelData.flags & 0x1000 ? "monthly" : (modelData.flags & 0x0fe0) === 0x0fe0 ? "daily" : modelData.flags & 0x0fe0 ? "weekly" : "once"
					tone: Theme.textSubtle
				}

				IconButton {
					implicitWidth: 30
					implicitHeight: 30
					icon: "delete_outline"
					onClicked: Amazfit.call("delete_reminder", { position: modelData.position })
				}
			}
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 6

			Field {
				id: remText

				Layout.fillWidth: true
				placeholder: "Remind me to …"
			}

			Field {
				id: remWhen

				Layout.preferredWidth: 170
				placeholder: "YYYY-MM-DD HH:MM"
			}

			TextButton {
				variant: "tonal"
				icon: "plus"
				text: "Add"
				enabled: remText.text.trim() !== "" && /^\d{4}-\d{2}-\d{2} \d{1,2}:\d{2}$/.test(remWhen.text.trim())
				onActivated: {
					const when = Date.parse(remWhen.text.trim().replace(" ", "T")) / 1000;
					const used = (root.zs.reminders ?? []).map(r => r.position);
					let pos = 0;
					while (used.includes(pos)) pos++;
					Amazfit.call("set_reminder", { position: pos, flags: 0x0001 | 0x0008, when, text: remText.text.trim(), update: false });
					remText.text = "";
				}
			}
		}
	}

	SettingCard {
		anchor: "amazfit-calendar"
		visible: root.zepp && root.caps.calendar !== undefined
		title: "Calendar on the watch"
		subtitle: `${(root.zs.calendar ?? []).length} events`
		icon: "calendar"

		Repeater {
			model: root.zs.calendar ?? []

			delegate: RowLayout {
				required property var modelData

				Layout.fillWidth: true
				Layout.leftMargin: 12

				StyledText {
					Layout.preferredWidth: 140
					text: new Date(modelData.start * 1000).toLocaleString(Qt.locale(), modelData.allDay ? "ddd d MMM" : "ddd d MMM HH:mm")
					tone: Theme.textMuted
				}

				StyledText {
					Layout.fillWidth: true
					text: modelData.title + (modelData.location ? ` · ${modelData.location}` : "")
					elide: Text.ElideRight
				}

				IconButton {
					implicitWidth: 30
					implicitHeight: 30
					icon: "delete_outline"
					onClicked: Amazfit.call("delete_event", { eid: modelData.id })
				}
			}
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 6

			Field {
				id: evTitle

				Layout.fillWidth: true
				placeholder: "An event …"
			}

			Field {
				id: evWhen

				Layout.preferredWidth: 170
				placeholder: "YYYY-MM-DD HH:MM"
			}

			TextButton {
				variant: "tonal"
				icon: "plus"
				text: "Add"
				enabled: evTitle.text.trim() !== "" && /^\d{4}-\d{2}-\d{2} \d{1,2}:\d{2}$/.test(evWhen.text.trim())
				onActivated: {
					const start = Date.parse(evWhen.text.trim().replace(" ", "T")) / 1000;
					Amazfit.call("add_event", { eid: Math.floor(Date.now() / 1000) & 0x7fffffff, title: evTitle.text.trim(), description: "", start, end: start + 3600, reminder: start - 900 });
					evTitle.text = "";
				}
			}
		}
	}

	// ── world clocks ───────────────────────────────────────────────────────
	SettingCard {
		anchor: "amazfit-clocks"
		visible: root.zepp
		title: "World clocks"
		subtitle: "Time zone names as in /usr/share/zoneinfo (Europe/Lisbon, America/New_York …)"
		icon: "earth"

		Repeater {
			model: Amazfit.option("worldClocks", [])

			delegate: RowLayout {
				required property var modelData
				required property int index

				Layout.fillWidth: true
				Layout.leftMargin: 12

				StyledText {
					Layout.preferredWidth: 60
					text: modelData.code
					font.weight: Font.Medium
				}

				StyledText {
					Layout.fillWidth: true
					text: `${modelData.label} · ${modelData.zone}`
					tone: Theme.textMuted
				}

				IconButton {
					implicitWidth: 30
					implicitHeight: 30
					icon: "delete_outline"
					onClicked: {
						const list = Amazfit.option("worldClocks", []).slice();
						list.splice(index, 1);
						Amazfit.setOption("worldClocks", list);
						Amazfit.call("set_world_clocks", { clocks: list });
					}
				}
			}
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 6

			Field {
				id: zone

				Layout.fillWidth: true
				placeholder: "Area/City"
				icon: "earth"
			}

			TextButton {
				variant: "tonal"
				icon: "plus"
				text: "Add"
				enabled: /^[A-Za-z_]+\/[A-Za-z_\/-]+$/.test(zone.text.trim())
				onActivated: {
					const name = zone.text.trim();
					const city = name.split("/").pop().replace(/_/g, " ");
					const list = Amazfit.option("worldClocks", []).concat([{ zone: name, label: city, code: city.slice(0, 3).toUpperCase() }]);
					Amazfit.setOption("worldClocks", list);
					Amazfit.call("set_world_clocks", { clocks: list });
					zone.text = "";
				}
			}
		}
	}

	// ── vibrations ─────────────────────────────────────────────────────────
	SettingCard {
		anchor: "amazfit-vibration"
		visible: root.zepp
		title: "Vibration patterns"
		subtitle: "Per kind of alert: the watch's own, or a pattern of on/off times in ms"
		icon: "vibrate"

		Repeater {
			model: Object.entries(Amazfit.catalog.vibrations ?? {})

			delegate: RowLayout {
				id: vib

				required property var modelData
				readonly property var pattern: (Amazfit.option("vibrations", {}))[vib.modelData[0]] ?? null

				Layout.fillWidth: true
				Layout.leftMargin: 12
				spacing: 6

				StyledText {
					Layout.preferredWidth: 160
					text: vib.modelData[0].replace(/_/g, " ").replace(/^./, c => c.toUpperCase())
				}

				Segmented {
					Layout.fillWidth: true
					options: [{ value: "", label: "Own" }, { value: "short", label: "Short" }, { value: "double", label: "Double" }, { value: "long", label: "Long" }, { value: "pulse", label: "Pulse" }]
					current: vib.pattern?.name ?? ""
					onSelected: value => {
						const presets = { short: [200, 0], double: [150, 150, 150, 0], long: [800, 0], pulse: [100, 100, 100, 100, 100, 100, 400, 0] };
						const all = Object.assign({}, Amazfit.option("vibrations", {}));
						if (value) all[vib.modelData[0]] = { name: value, onOff: presets[value] };
						else delete all[vib.modelData[0]];
						Amazfit.setOption("vibrations", all);
						Amazfit.call("vibration", { kind: vib.modelData[1], pattern: value ? presets[value] : null, test: false });
					}
				}

				IconButton {
					implicitWidth: 30
					implicitHeight: 30
					icon: "play"
					onClicked: Amazfit.call("vibration", { kind: vib.modelData[1], pattern: vib.pattern?.onOff ?? [300, 0], test: true })
				}
			}
		}
	}

	// ── you, for the measurements ──────────────────────────────────────────
	SettingCard {
		anchor: "amazfit-user"
		visible: root.zepp
		title: "About you"
		subtitle: "What calories, distance and sleep are worked out from"
		icon: "account"

		GridLayout {
			Layout.fillWidth: true
			Layout.leftMargin: 12
			columns: 4
			columnSpacing: 10

			Repeater {
				model: [["name", "Name", "Pshell"], ["year", "Born (year)", "1990"], ["height", "Height (cm)", "175"], ["weight", "Weight (kg)", "70"]]

				delegate: Field {
					required property var modelData

					Layout.fillWidth: true
					placeholder: modelData[1]
					text: String((Amazfit.option("user", {}))[modelData[0]] ?? "")
					clearable: false
					onAccepted: {
						const user = Object.assign({ gender: 2, month: 1, day: 1 }, Amazfit.option("user", {}));
						user[modelData[0]] = modelData[0] === "name" ? text : Number(text);
						Amazfit.setOption("user", user);
						if (user.year && user.height && user.weight) Amazfit.call("user_info", { name: user.name || "Pshell", year: user.year, month: user.month, day: user.day, gender: user.gender, height: user.height, weight: user.weight });
					}
				}
			}
		}

		Segmented {
			Layout.fillWidth: true
			options: [{ value: "0", label: "Male" }, { value: "1", label: "Female" }, { value: "2", label: "Other" }]
			current: String((Amazfit.option("user", {})).gender ?? 2)
			onSelected: value => {
				const user = Object.assign({ month: 1, day: 1 }, Amazfit.option("user", {}), { gender: Number(value) });
				Amazfit.setOption("user", user);
				if (user.year && user.height && user.weight) Amazfit.call("user_info", { name: user.name || "Pshell", year: user.year, month: user.month, day: user.day, gender: user.gender, height: user.height, weight: user.weight });
			}
		}
	}

	// ── the connection ─────────────────────────────────────────────────────
	SettingCard {
		anchor: "amazfit-connection"
		visible: Amazfit.present
		title: "Connection"
		subtitle: [root.dev.address ?? "", root.dev.bonded ? "bonded" : "", root.dev.trusted ? "trusted" : ""].filter(s => s).join(" · ")
		icon: "bluetooth"

		FlagRow {
			icon: "bluetooth_connect"
			title: "Connect when it is near"
			subtitle: "Asks BlueZ every 90 s while it is away; costs the watch nothing while it is connected"
			checked: Amazfit.option("autoConnect", true)
			onToggled: on => Amazfit.setOption("autoConnect", on)
		}

		FlagRow {
			icon: "clock_check_outline"
			title: "Set its clock from the PC"
			subtitle: "Each time it connects, when it is off by 3 s or more"
			checked: Amazfit.option("syncTime", true)
			onToggled: on => Amazfit.setOption("syncTime", on)
		}

		FlagRow {
			icon: "heart_pulse"
			title: "Heart rate all the time"
			subtitle: "Listens to the heart rate service also while this page is closed (the watch must share it)"
			checked: Amazfit.option("liveHr", false)
			onToggled: on => Amazfit.setOption("liveHr", on)
		}

		ValueSlider {
			from: 0
			to: 40
			step: 5
			icon: "battery_alert"
			label: "Battery warning"
			format: v => Math.round(v) === 0 ? "Off" : `at ${Math.round(v)} %`
			value: Amazfit.option("lowBattery", 15)
			onMoved: v => Amazfit.setOption("lowBattery", Math.round(v))
		}
	}

	// ── what it is ─────────────────────────────────────────────────────────
	SettingCard {
		anchor: "amazfit-info"
		visible: Amazfit.present
		title: "This watch"
		subtitle: [Amazfit.info.serial ? `serial ${Amazfit.info.serial}` : "", Amazfit.info.hardware ? `hardware ${Amazfit.info.hardware}` : "", Amazfit.info.pnp ? `${Amazfit.info.pnp.vendor}:${Amazfit.info.pnp.product} v${Amazfit.info.pnp.version}` : ""].filter(s => s).join(" · ")
		icon: "information_outline"

		Flow {
			Layout.fillWidth: true
			spacing: 6

			Repeater {
				model: root.zs.services ?? []

				delegate: Chip {
					required property var modelData

					text: (modelData.name || `0x${Number(modelData.endpoint).toString(16).padStart(4, "0")}`) + (modelData.encrypted ? " 🔒" : "")
				}
			}
		}

		StyledText {
			Layout.fillWidth: true
			Layout.leftMargin: 12
			text: "Over plain Bluetooth: battery, device information, current time, heart rate, Alert Notification, HID (report 2: eight media keys; report 1: eight bytes the report map leaves out). Firmware updates (service 1530), aGPS, voice memos, maps, Wi-Fi, FTP, app installs and the activity download are left to Gadgetbridge – the shell's face syncs the health data (>watch)."
			tone: Theme.textSubtle
			wrapMode: Text.Wrap
		}
	}
}
