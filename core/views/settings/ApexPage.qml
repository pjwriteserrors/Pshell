pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell.Io
import qs.style.theme
import qs.style.widgets
import qs.core.services
import qs.core.views.settings.mouse
import qs.core.views.settings.apex

// The SteelSeries Apex Pro TKL Gen 3 (core/services/Apex.qml): how deep each
// key fires and lets go, its 2-in-1 action, what every key does, the five
// configs it keeps, its OLED and its light. The drawing is the keyboard, live.
SettingsPage {
	id: root

	title: "Apex Pro TKL Gen 3"
	description: ""
	recording: picker.recording

	signal open(string page)

	// the keys picked in the drawing; none: every Hall key
	property var picks: []
	property string app: ""

	onActiveChanged: {
		Apex.watching = root.active;
		if (root.active) Apex.refresh();
	}
	Component.onDestruction: Apex.watching = false

	readonly property bool has: Apex.online
	readonly property var dev: Apex.device
	readonly property var hall: root.picks.length === 0 ? Apex.analog : root.picks.filter(h => Apex.analog.includes(h))
	readonly property int one: root.picks.length === 1 ? root.picks[0] : 0
	readonly property var first: Apex.keyState[root.hall[0]] ?? null
	readonly property bool oneHall: root.one !== 0 && Apex.analog.includes(root.one)

	function same(key) {
		const values = root.hall.map(h => Apex.keyState[h]?.[key]);
		return values.every(v => v === values[0]);
	}

	function mm(level) {
		return `${(level / 10).toFixed(1)} mm`;
	}

	function pick(hid, add) {
		if (!add) {
			root.picks = root.picks.length === 1 && root.picks[0] === hid ? [] : [hid];
			return;
		}
		const picks = root.picks.slice();
		const at = picks.indexOf(hid);
		if (at >= 0) picks.splice(at, 1);
		else picks.push(hid);
		root.picks = picks;
	}

	// keys bound to something else than their print, on any layer
	readonly property var changed: {
		const out = {};
		const b = Apex.bindings;
		for (const hid of Apex.bindable) {
			const own = b[0]?.[hid];
			if (own && !(own[0] === 0x51 && own[1] === hid && !own[2])) out[hid] = true;
			const fn = b[1]?.[hid];
			if (fn && !(fn[0] === 0x51 && !fn[1]) && fn[0] !== 0) out[hid] = true;
			const deep = b[2]?.[hid];
			if (deep && deep[0] !== 0) out[hid] = true;
		}
		return out;
	}

	readonly property var groups: [
		{ label: "WASD", keys: [26, 4, 22, 7] },
		{ label: "Letters", keys: [4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29] },
		{ label: "Numbers", keys: [30, 31, 32, 33, 34, 35, 36, 37, 38, 39] },
		{ label: "Modifiers", keys: [224, 225, 226, 227, 228, 229, 230, 231] }
	]

	// ── the keyboard, live ─────────────────────────────────────────────────
	SettingCard {
		anchor: "apex-keys"
		title: !Apex.scanned ? "Looking for the keyboard …" : (root.has ? (root.dev.configs?.[Apex.slot]?.name || `Config ${Apex.slot + 1}`) : "Not connected")
		subtitle: root.dev.saving ? "Saving on the keyboard …" : ""
		icon: root.has ? "keyboard" : "keyboard_off"

		trailing: RowLayout {
			spacing: 6
			visible: root.has

			Repeater {
				model: root.dev.configs ?? []

				delegate: Chip {
					required property var modelData

					text: String(modelData.slot + 1)
					selected: modelData.slot === Apex.slot
					onClicked: Apex.switchSlot(modelData.slot)
				}
			}
		}

		ApexFigure {
			Layout.fillWidth: true
			Layout.preferredHeight: Math.min(300, width * 6.85 / 18.6)
			opacity: root.has ? 1 : 0.45
			keyState: Apex.keyState
			selected: root.picks
			changed: root.changed
			keys: Apex.keys
			codes: Apex.hidToEvdev
			analog: Apex.analog
			screen: Apex.screen !== "" ? Apex.screen : (root.dev.stored ?? "")
			brightness: (root.dev.brightness ?? 10) / 10
			onPicked: (hid, add) => root.pick(hid, add)

			Behavior on opacity {
				Anim {
					duration: Motion.long
				}
			}
		}

		Flow {
			Layout.fillWidth: true
			spacing: 8
			visible: root.has

			Chip {
				text: "All keys"
				icon: "select_all"
				selected: root.picks.length === 0
				onClicked: root.picks = []
			}

			Repeater {
				model: root.groups

				delegate: Chip {
					required property var modelData

					text: modelData.label
					selected: JSON.stringify(root.picks) === JSON.stringify(modelData.keys)
					onClicked: root.picks = modelData.keys
				}
			}
		}

		StyledText {
			Layout.fillWidth: true
			visible: Apex.error !== ""
			text: Apex.error
			tone: Theme.danger
		}
	}

	// ── actuation ──────────────────────────────────────────────────────────
	SettingCard {
		anchor: "apex-actuation"
		visible: root.has && root.hall.length > 0
		title: "Actuation"
		subtitle: root.picks.length === 0 ? "All keys" : root.picks.map(h => Apex.hidName(h)).join(" · ")
		icon: "arrow_collapse_down"

		ValueSlider {
			from: 1
			to: 40
			step: 1
			icon: "arrow_collapse_down"
			label: root.same("act") ? "Fires at" : "Fires at (mixed)"
			format: v => root.mm(v)
			value: root.first?.act ?? 20
			onMoved: v => Apex.setKeys(root.hall, { act: Math.round(v) })
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 12

			StyledText {
				Layout.fillWidth: true
				text: "Rapid Trigger"
				font.weight: Font.Medium
			}

			Segmented {
				Layout.preferredWidth: 420
				options: [
					{ value: "off", label: "Off" },
					{ value: "rapid", label: "On", icon: "flash" },
					{ value: "protect", label: "Protection" },
					{ value: "both", label: "Both" }
				]
				current: root.same("release") ? (root.first?.release ?? "off") : ""
				onSelected: value => Apex.setKeys(root.hall, { release: value })
			}
		}

		ValueSlider {
			visible: ["rapid", "both"].includes(root.first?.release ?? "")
			from: 1
			to: 40
			step: 1
			icon: "flash"
			label: "Sensitivity"
			format: v => root.mm(v)
			value: root.first?.sens ?? 2
			onMoved: v => Apex.setKeys(root.hall, { sens: Math.round(v) })
		}

		ValueSlider {
			visible: ["protect", "both"].includes(root.first?.release ?? "")
			from: 1
			to: 40
			step: 1
			icon: "shield_check"
			label: "Protection depth"
			format: v => root.mm(v)
			value: root.first?.protect ?? 20
			onMoved: v => {
				protectDepth.depth = Math.round(v);
				protectDepth.restart();
			}

			Timer {
				id: protectDepth

				property int depth: 20

				interval: 600
				onTriggered: Apex.setKeys(root.hall, { protect: protectDepth.depth })
			}
		}

		ValueSlider {
			visible: ["protect", "both"].includes(root.first?.release ?? "")
			from: 50
			to: 2000
			step: 50
			icon: "timer_outline"
			label: "Protection time"
			format: v => `${Math.round(v)} ms`
			value: root.dev.protectMs ?? 500
			onMoved: v => {
				protectTime.ms = Math.round(v);
				protectTime.restart();
			}

			Timer {
				id: protectTime

				property int ms: 500

				interval: 600
				onTriggered: Apex.send({ op: "protectMs", ms: protectTime.ms })
			}
		}
	}

	// ── 2-in-1 ─────────────────────────────────────────────────────────────
	SettingCard {
		anchor: "apex-dual"
		visible: root.has && root.oneHall
		title: "2-in-1 action"
		subtitle: Apex.hidName(root.one)
		icon: "layers_outline"

		RowLayout {
			Layout.fillWidth: true
			spacing: 12

			StyledText {
				Layout.fillWidth: true
				text: "Second point"
				font.weight: Font.Medium
			}

			Toggle {
				checked: (Apex.keyState[root.one]?.second ?? 0) > 0
				onToggled: on => Apex.setKeys([root.one], { second: on ? Math.min(40, (Apex.keyState[root.one]?.act ?? 20) + 10) : 0 })
			}
		}

		ValueSlider {
			visible: (Apex.keyState[root.one]?.second ?? 0) > 0
			from: Math.min(39, (Apex.keyState[root.one]?.act ?? 1) + 1)
			to: 40
			step: 1
			icon: "arrow_collapse_down"
			label: "Fires at"
			format: v => root.mm(v)
			value: Apex.keyState[root.one]?.second ?? 30
			onMoved: v => Apex.setKeys([root.one], { second: Math.round(v) })
		}

		BindRow {
			visible: (Apex.keyState[root.one]?.second ?? 0) > 0
			app: ""
			control: `k${root.one}.2`
			trigger: "press"
			onPick: (control, trigger) => picker.show(control, trigger, "")
			label: "Pressed deeper"
			icon: "arrow_collapse_down"
		}
	}

	// ── what the keys do ───────────────────────────────────────────────────
	SettingCard {
		anchor: "apex-bindings"
		visible: root.has
		title: root.one ? Apex.hidName(root.one) : "Keys"
		icon: "keyboard_variant"

		StyledText {
			Layout.fillWidth: true
			Layout.leftMargin: 12
			visible: !root.one
			text: "Pick one key in the drawing."
			tone: Theme.textMuted
		}

		Flow {
			Layout.fillWidth: true
			spacing: 8
			visible: !!root.one

			Repeater {
				model: [""].concat(Apex.apps)

				delegate: Chip {
					required property string modelData

					text: modelData === "" ? "Everywhere" : modelData
					icon: modelData === "" ? "earth" : "application_outline"
					selected: root.app === modelData
					acceptedButtons: Qt.LeftButton | Qt.RightButton
					onClicked: root.app = modelData
					onRightClicked: if (modelData !== "") {
						if (root.app === modelData) root.app = "";
						Apex.removeApp(modelData);
					}
				}
			}

			Chip {
				visible: Apex.focusApp !== "" && !Apex.apps.includes(Apex.focusApp)
				text: Apex.focusApp
				icon: "plus"
				onClicked: {
					Apex.addApp(Apex.focusApp);
					root.app = Apex.focusApp;
				}
			}
		}

		Repeater {
			model: root.one ? [
				{ control: `k${root.one}.0`, trigger: "press", label: "Press", icon: "gesture_tap" },
				{ control: `k${root.one}.0`, trigger: "double", label: "Double press", icon: "gesture_double_tap" },
				{ control: `k${root.one}.0`, trigger: "hold", label: "Hold", icon: "gesture_tap_hold" },
				{ control: `k${root.one}.1`, trigger: "press", label: "With SteelSeries key", icon: "keyboard_settings" }
			] : []

			delegate: BindRow {
				required property var modelData

				app: root.app
				control: modelData.control
				trigger: modelData.trigger
				onPick: (control, trigger) => picker.show(control, trigger, root.app)
				label: modelData.label
				icon: modelData.icon
			}
		}

		FlagRow {
			icon: "lightbulb_on"
			title: "Light the SteelSeries layer"
			checked: root.dev.highlight === true
			onToggled: on => Apex.send({ op: "highlight", on })
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 12

			StyledText {
				Layout.fillWidth: true
				Layout.leftMargin: 12
				text: `SteelSeries key: ${Apex.hidName(root.dev.fnKey ?? 240)}`
				font.weight: Font.Medium
			}

			TextButton {
				visible: !!root.one && root.one !== (root.dev.fnKey ?? 240)
				variant: "ghost"
				text: `Use ${Apex.hidName(root.one)}`
				confirm: true
				onActivated: Apex.send({ op: "fnKey", hid: root.one })
			}

			TextButton {
				visible: (root.dev.fnKey ?? 240) !== 240
				variant: "ghost"
				icon: "undo"
				text: "SteelSeries"
				onActivated: Apex.send({ op: "fnKey", hid: 240 })
			}
		}

		ActionPicker {
			id: picker

			store: Apex
			onChosen: (action, extra) => Apex.assign(picker.control, picker.trigger, picker.app, action, extra)
			onCleared: Apex.assign(picker.control, picker.trigger, picker.app, null)
		}
	}

	component BindRow: Clickable {
		id: row

		property string app: ""
		property string control: ""
		property string trigger: "press"
		property string label: ""
		property string icon: ""
		readonly property var rule: Apex.ruleFor(row.control, row.trigger, row.app)
		readonly property var shown: Apex.describe(Apex.effective(row.control, row.trigger, row.app)?.action ?? (row.trigger === "press" ? null : { kind: "none" }), row.control)
		readonly property int usage: Apex.hostOf(Apex.split(row.control)[1], Apex.split(row.control)[0])
		property bool lit: false

		Layout.fillWidth: true
		implicitHeight: 52
		radius: Theme.radius.large
		color: row.lit ? Theme.primaryContainer : Theme.layer2
		signal pick(string control, string trigger)

		onClicked: row.pick(row.control, row.trigger)

		Behavior on color {
			ColorAnim {}
		}

		Connections {
			target: Apex

			function onFired(rule, control, trigger) {
				if (row.usage && control === `h${row.usage}` && trigger === Apex.triggerOf[row.trigger]) {
					row.lit = true;
					unlight.restart();
				}
			}
		}

		Timer {
			id: unlight

			interval: 600
			onTriggered: row.lit = false
		}

		RowLayout {
			anchors.fill: parent
			anchors.leftMargin: 16
			anchors.rightMargin: 12
			spacing: 12

			Glyph {
				icon: row.icon
				size: 18
				color: Theme.textMuted
			}

			StyledText {
				Layout.preferredWidth: 170
				text: row.label
				font.weight: Font.Medium
			}

			Glyph {
				visible: row.shown.icon !== ""
				icon: row.shown.icon
				size: 16
				color: row.rule ? Theme.primary : Theme.textSubtle
			}

			StyledText {
				Layout.fillWidth: true
				text: row.shown.label + (!row.rule && row.app !== "" && Apex.effective(row.control, row.trigger, row.app) ? " · everywhere" : "")
				tone: row.rule ? Theme.text : Theme.textSubtle
				elide: Text.ElideRight
			}

			Glyph {
				visible: row.usage !== 0
				icon: "console"
				size: 14
				color: Theme.textFaint
			}

			IconButton {
				visible: !!row.rule
				implicitWidth: 30
				implicitHeight: 30
				icon: "close"
				variant: "ghost"
				onClicked: Apex.assign(row.control, row.trigger, row.app, null)
			}

			Glyph {
				icon: "chevron_right"
				size: 16
				color: Theme.textFaint
			}
		}
	}

	// ── rapid tap ──────────────────────────────────────────────────────────
	SettingCard {
		anchor: "apex-rapidtap"
		visible: root.has && root.dev.rapidTap?.supported === true
		title: "Rapid Tap"
		icon: "swap_horizontal"

		trailing: Toggle {
			checked: root.dev.rapidTap?.on === true
			onToggled: on => Apex.send({ op: "rapidTap", on, pairs: root.dev.rapidTap?.pairs ?? [] })
		}

		Repeater {
			model: root.dev.rapidTap?.pairs ?? []

			delegate: RowLayout {
				id: pair

				required property var modelData
				required property int index

				Layout.fillWidth: true
				spacing: 10

				StyledText {
					Layout.preferredWidth: 140
					Layout.leftMargin: 12
					text: `${Apex.hidName(pair.modelData.a)} ⇄ ${Apex.hidName(pair.modelData.b)}`
					font.weight: Font.Medium
				}

				Segmented {
					Layout.fillWidth: true
					options: [
						{ value: "0", label: "Last pressed" },
						{ value: "1", label: Apex.hidName(pair.modelData.a) },
						{ value: "2", label: Apex.hidName(pair.modelData.b) },
						{ value: "3", label: "Neither" }
					]
					current: String(pair.modelData.mode)
					onSelected: value => {
						const pairs = (root.dev.rapidTap?.pairs ?? []).slice();
						pairs[pair.index] = Object.assign({}, pairs[pair.index], { mode: Number(value) });
						Apex.send({ op: "rapidTap", on: root.dev.rapidTap?.on === true, pairs });
					}
				}

				IconButton {
					icon: "close"
					variant: "ghost"
					onClicked: {
						const pairs = (root.dev.rapidTap?.pairs ?? []).filter((_, i) => i !== pair.index);
						Apex.send({ op: "rapidTap", on: root.dev.rapidTap?.on === true, pairs });
					}
				}
			}
		}

		TextButton {
			Layout.alignment: Qt.AlignRight
			visible: root.picks.length === 2 && root.picks.every(h => Apex.analog.includes(h)) && (root.dev.rapidTap?.pairs ?? []).length < 10
			icon: "plus"
			text: `${Apex.hidName(root.picks[0] ?? 0)} ⇄ ${Apex.hidName(root.picks[1] ?? 0)}`
			onActivated: Apex.send({ op: "rapidTap", on: true, pairs: (root.dev.rapidTap?.pairs ?? []).concat([{ a: root.picks[0], b: root.picks[1], mode: 0 }]) })
		}
	}

	// ── the OLED ───────────────────────────────────────────────────────────
	SettingCard {
		anchor: "apex-oled"
		visible: root.has
		title: "Display"
		icon: "monitor"

		OledView {
			Layout.alignment: Qt.AlignHCenter
			Layout.preferredWidth: 384
			Layout.preferredHeight: 120
			frame: Apex.screen !== "" ? Apex.screen : (root.dev.stored ?? "")
		}

		Segmented {
			Layout.fillWidth: true
			options: [
				{ value: "own", label: "Its own", icon: "keyboard" },
				{ value: "clock", label: "Clock", icon: "clock_outline" },
				{ value: "media", label: "Playing", icon: "music" },
				{ value: "system", label: "System", icon: "speedometer" },
				{ value: "text", label: "Text", icon: "format_text" },
				{ value: "picture", label: "Picture", icon: "image_outline" }
			]
			current: Apex.option("oled", "own")
			onSelected: value => Apex.setOption("oled", value)
		}

		FlagRow {
			visible: Apex.option("oled", "own") === "clock"
			icon: "timer_outline"
			title: "Seconds"
			checked: Apex.option("oledSeconds", false) === true
			onToggled: on => Apex.setOption("oledSeconds", on)
		}

		FlagRow {
			visible: Apex.option("oled", "own") === "clock"
			icon: "calendar"
			title: "Date"
			checked: Apex.option("oledDate", true) === true
			onToggled: on => Apex.setOption("oledDate", on)
		}

		AreaField {
			id: oledText

			Layout.fillWidth: true
			Layout.preferredHeight: 80
			visible: Apex.option("oled", "own") === "text"
			text: Apex.option("oledText", "")
			onTextChanged: textPush.restart()

			Timer {
				id: textPush

				interval: 400
				onTriggered: if (oledText.text !== Apex.option("oledText", "")) Apex.setOption("oledText", oledText.text)
			}
		}

		RowLayout {
			Layout.fillWidth: true
			visible: Apex.option("oled", "own") === "picture" || Apex.option("oled", "own") === "own"
			spacing: 10

			StyledText {
				Layout.fillWidth: true
				Layout.leftMargin: 12
				text: Apex.option("oledPicture", "").split("/").pop() || "No picture"
				tone: Apex.option("oledPicture", "") ? Theme.text : Theme.textMuted
				elide: Text.ElideMiddle
			}

			TextButton {
				variant: "ghost"
				icon: "image_outline"
				text: "Choose"
				onActivated: chooser.running = true
			}

			TextButton {
				variant: "ghost"
				icon: "swap_vertical"
				text: Apex.option("oledInvert", false) ? "Inverted" : "Invert"
				onActivated: Apex.setOption("oledInvert", !Apex.option("oledInvert", false))
			}

			TextButton {
				enabled: Apex.option("oledPicture", "") !== ""
				icon: "content_save_outline"
				text: "Keep on the keyboard"
				onActivated: Apex.storePicture(Apex.option("oledPicture", ""), Apex.option("oledInvert", false))
			}

			TextButton {
				visible: Apex.option("oled", "own") === "own"
				variant: "ghost"
				icon: "undo"
				text: "SteelSeries"
				confirm: true
				onActivated: Apex.clearStored()
			}
		}

		Process {
			id: chooser

			command: ["python3", `${Paths.scripts}/pick_files.py`, "--single", "--filter", "Pictures|*.png *.jpg *.jpeg *.gif *.bmp *.webp *.svg", "Picture for the keyboard"]
			stdout: StdioCollector {
				onStreamFinished: {
					const path = this.text.trim().split("\n")[0];
					if (path) Apex.setOption("oledPicture", path);
				}
			}
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 12

			StyledText {
				Layout.fillWidth: true
				Layout.leftMargin: 12
				text: "Notifications"
				font.weight: Font.Medium
			}

			Segmented {
				Layout.preferredWidth: 320
				options: [
					{ value: "off", label: "Never" },
					{ value: "critical", label: "Urgent" },
					{ value: "all", label: "All" }
				]
				current: Apex.option("oledNotify", "off")
				onSelected: value => Apex.setOption("oledNotify", value)
			}
		}
	}

	// ── light ──────────────────────────────────────────────────────────────
	SettingCard {
		anchor: "apex-light"
		visible: root.has
		title: "Light"
		icon: "lightbulb_on"

		trailing: TextButton {
			visible: Lighting.enabled
			variant: "ghost"
			icon: "palette_outline"
			text: "Colours"
			onActivated: root.open("lighting")
		}

		ValueSlider {
			from: 0
			to: 10
			step: 1
			icon: "brightness_6"
			label: "Brightness"
			value: root.dev.brightness ?? 10
			onMoved: v => Apex.setBrightness(Math.round(v))
		}
	}

	// ── configs ────────────────────────────────────────────────────────────
	SettingCard {
		anchor: "apex-configs"
		visible: root.has
		title: "Configs"
		icon: "account_switch_outline"

		Repeater {
			model: root.dev.configs ?? []

			delegate: RowLayout {
				id: config

				required property var modelData
				readonly property bool here: config.modelData.slot === Apex.slot

				Layout.fillWidth: true
				spacing: 10

				StyledText {
					Layout.preferredWidth: 24
					Layout.leftMargin: 12
					text: config.modelData.slot + 1
					font.weight: Font.Bold
					tone: config.here ? Theme.primary : Theme.textMuted
				}

				Field {
					Layout.fillWidth: true
					text: config.modelData.name
					enabled: config.modelData.read
					clearable: false
					onAccepted: if (text.trim() && text !== config.modelData.name) Apex.rename(config.modelData.slot, text.trim())
				}

				TextButton {
					visible: !config.here
					variant: "ghost"
					icon: "play"
					text: "Load"
					onActivated: Apex.switchSlot(config.modelData.slot)
				}

				TextButton {
					visible: !config.here
					variant: "ghost"
					icon: "content_copy"
					text: `Copy ${Apex.slot + 1} here`
					confirm: true
					onActivated: Apex.copySlot(Apex.slot, config.modelData.slot)
				}

				TextButton {
					visible: (root.dev.backups ?? []).includes(config.modelData.slot)
					variant: "ghost"
					icon: "undo"
					text: "Put back"
					confirm: true
					onActivated: Apex.restoreSlot(config.modelData.slot)
				}
			}
		}
	}

	// ── the device ─────────────────────────────────────────────────────────
	SettingCard {
		anchor: "apex-device"
		visible: root.has
		title: "This keyboard"
		subtitle: [`Firmware ${Apex.info.firmware ?? "?"}`, ({ iso: "ISO", ansi: "ANSI", jis: "JIS" })[Apex.info.layout] ?? "", root.dev.winLock === true ? "Windows key locked" : ""].filter(s => s).join(" · ")
		icon: "information_outline"

		RowLayout {
			Layout.fillWidth: true

			Item {
				Layout.fillWidth: true
			}

			TextButton {
				variant: "ghost"
				icon: "refresh"
				text: "Read again"
				onActivated: Apex.refresh()
			}
		}
	}
}
