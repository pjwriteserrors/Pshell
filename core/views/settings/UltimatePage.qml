pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services
import qs.core.views.settings.ultimate

// The 8BitDo Ultimate 2 Wireless (core/services/Ultimate.qml): its three
// profiles – what every button does, sticks, triggers, vibration, motion,
// the light rings and macros. The pad keeps them itself; the profile it
// uses is picked with its star button.
SettingsPage {
	id: root

	title: "Ultimate 2 Wireless"
	description: ""

	signal open(string page)

	onActiveChanged: {
		Ultimate.watching = root.active;
		if (root.active) Ultimate.refresh();
	}
	Component.onDestruction: Ultimate.watching = false

	readonly property bool has: Ultimate.linked
	readonly property var dev: Ultimate.device
	// the profile being edited: the one in use, else the first one
	property int edit: Ultimate.slot < 3 ? Ultimate.slot : 0
	readonly property var p: Ultimate.profiles[root.edit] ?? ({})
	property string picked: "a"

	Connections {
		target: Ultimate

		function onSlotChanged() {
			if (Ultimate.slot < 3) root.edit = Ultimate.slot;
		}
	}

	function set(key, value) {
		Ultimate.set(root.edit, key, value);
	}

	function feature(name, on) {
		root.set("features", { [name]: on });
	}

	function profileName(slot) {
		if (slot >= 3) return "Standard";
		const profile = Ultimate.profiles[slot];
		return profile?.on ? (profile.name || `Profile ${slot + 1}`) : `Profile ${slot + 1}`;
	}

	component Line: RowLayout {
		id: row

		property string text: ""
		property string hint: ""
		default property alias trailing: holder.data

		Layout.fillWidth: true
		spacing: 12

		ColumnLayout {
			Layout.fillWidth: true
			spacing: 0

			StyledText {
				Layout.fillWidth: true
				text: row.text
				font.weight: Font.Medium
			}

			StyledText {
				Layout.fillWidth: true
				visible: row.hint !== ""
				text: row.hint
				tone: Theme.textMuted
				font.pixelSize: Theme.size.small
				wrapMode: Text.Wrap
			}
		}

		RowLayout {
			id: holder

			spacing: 8
		}
	}

	component Flag: Line {
		id: flag

		required property string name

		Toggle {
			checked: root.p.features?.[flag.name] === true
			onToggled: on => root.feature(flag.name, on)
		}
	}

	// ── the pad, live ──────────────────────────────────────────────────────
	SettingCard {
		anchor: "ultimate-pad"
		title: !Ultimate.scanned ? "Looking for the controller …" : (!Ultimate.online ? "Not connected" : (!root.has ? "The controller is off" : `In use: ${root.profileName(Ultimate.slot)}`))
		subtitle: !Ultimate.online ? "Plug in its dongle or cable" : (!root.has ? "Switch it on – the dongle is here" : [Ultimate.pad ? `${Ultimate.pad.battery} %` : "", "Star button on the pad: next profile"].filter(s => s).join(" · "))
		icon: "gamepad_variant"

		RowLayout {
			visible: root.has
			Layout.fillWidth: true
			spacing: 8

			StyledText {
				text: "Editing"
				tone: Theme.textMuted
			}

			Repeater {
				model: [0, 1, 2]

				delegate: Chip {
					required property int modelData

					text: root.profileName(modelData) + (Ultimate.slot === modelData ? " ●" : "")
					icon: Ultimate.profiles[modelData]?.on ? "account" : "plus"
					selected: root.edit === modelData
					onClicked: root.edit = modelData
				}
			}

			Item {
				Layout.fillWidth: true
			}
		}

		StyledText {
			visible: root.has && Ultimate.slot !== root.edit
			Layout.fillWidth: true
			text: Ultimate.slot >= 3 ? "The pad runs its standard setup now: the changes wait in this profile until the star button picks it." : `The pad uses ${root.profileName(Ultimate.slot)} now: these changes show once the star button picks ${root.profileName(root.edit)}.`
			tone: Theme.warning
			wrapMode: Text.Wrap
		}

		StyledText {
			visible: root.has && root.p.on === false
			Layout.fillWidth: true
			text: "This profile is not made yet: the first change makes it, with the pad's usual setup."
			tone: Theme.textMuted
			wrapMode: Text.Wrap
		}

		PadFigure {
			visible: Ultimate.online
			Layout.alignment: Qt.AlignHCenter
			held: Ultimate.held
			axes: Ultimate.axes
			picked: root.picked
			ring: root.p.dynamic?.color ?? Theme.primary
			onPick: id => root.picked = id
		}

		StyledText {
			visible: Ultimate.error !== ""
			Layout.fillWidth: true
			text: Ultimate.error
			tone: Theme.danger
			wrapMode: Text.Wrap
		}
	}

	// ── buttons ────────────────────────────────────────────────────────────
	SettingCard {
		anchor: "ultimate-buttons"
		visible: root.has
		title: "Buttons"
		subtitle: "What each button does in this profile. The paddles and L4/R4 have no code of their own: they press what they are given here."
		icon: "gamepad_variant"

		GridLayout {
			Layout.fillWidth: true
			columns: 2
			columnSpacing: 16
			rowSpacing: 6

			Repeater {
				model: Ultimate.buttons

				delegate: RowLayout {
					id: btn

					required property var modelData
					readonly property string fn: root.p.map?.[btn.modelData.id] ?? btn.modelData.id
					readonly property bool own: btn.fn === btn.modelData.id || (["pl", "pr", "l4", "r4"].includes(btn.modelData.id) && btn.fn === "none")

					Layout.fillWidth: true
					spacing: 8

					StyledText {
						Layout.preferredWidth: 56
						text: btn.modelData.label
						font.weight: root.picked === btn.modelData.id ? Font.Bold : Font.Medium
						tone: root.picked === btn.modelData.id ? Theme.primary : Theme.text
					}

					TextButton {
						id: fnButton

						Layout.fillWidth: true
						variant: btn.own ? "ghost" : "tonal"
						icon: "chevron_down"
						text: Ultimate.functionLabel(btn.fn)
						enabled: btn.modelData.id !== "home"
						onActivated: {
							root.picked = btn.modelData.id;
							fnList.open();
						}

						PickList {
							id: fnList

							current: btn.fn
							entries: Ultimate.functions
							onPicked: value => root.set("map", { [btn.modelData.id]: String(value) })
						}
					}
				}
			}
		}

		RowLayout {
			Layout.fillWidth: true

			StyledText {
				Layout.fillWidth: true
				text: "Home stays Home (the pad needs it)."
				tone: Theme.textSubtle
				font.pixelSize: Theme.size.small
			}

			TextButton {
				variant: "ghost"
				icon: "undo"
				text: "As printed"
				confirm: true
				onActivated: {
					const map = {};
					for (const b of Ultimate.buttons) map[b.id] = ["pl", "pr", "l4", "r4"].includes(b.id) ? "none" : b.id;
					root.set("map", map);
				}
			}
		}
	}

	// ── sticks ─────────────────────────────────────────────────────────────
	SettingCard {
		anchor: "ultimate-sticks"
		visible: root.has
		title: "Sticks"
		subtitle: "Move a stick to see it; drag the red ring (dead zone) or the outer ring (fully out)."
		icon: "gamepad_variant"

		RowLayout {
			Layout.alignment: Qt.AlignHCenter
			spacing: 32

			Repeater {
				model: [
					{ label: "Left", at: 0, x: "lx", y: "ly", key: "l3" },
					{ label: "Right", at: 2, x: "rx", y: "ry", key: "r3" }
				]

				delegate: StickView {
					required property var modelData

					label: modelData.label
					ax: (Ultimate.axes[modelData.x] ?? 0) / 32768
					ay: (Ultimate.axes[modelData.y] ?? 0) / 32768
					pressed: Ultimate.held.includes(modelData.key)
					dead: root.p.sticks?.[modelData.at] ?? 0
					full: root.p.sticks?.[modelData.at + 1] ?? 128
					onMoved: (dead, full) => {
						const s = (root.p.sticks ?? [0, 128, 0, 128]).slice();
						s[modelData.at] = dead;
						s[modelData.at + 1] = full;
						root.set("sticks", s);
					}
				}
			}
		}

		Repeater {
			model: [
				{ label: "Left stick", at: 0, icon: "arrow_left_bold" },
				{ label: "Right stick", at: 2, icon: "arrow_right_bold" }
			]

			delegate: ColumnLayout {
				id: stick

				required property var modelData

				Layout.fillWidth: true
				spacing: 4

				ValueSlider {
					from: 0
					to: 60
					step: 1
					icon: stick.modelData.icon
					label: `${stick.modelData.label}: dead zone`
					format: v => `${Math.round(v / 128 * 100)} %`
					value: root.p.sticks?.[stick.modelData.at] ?? 0
					onMoved: v => {
						const s = (root.p.sticks ?? [0, 128, 0, 128]).slice();
						s[stick.modelData.at] = Math.round(v);
						root.set("sticks", s);
					}
				}

				ValueSlider {
					from: 64
					to: 128
					step: 1
					icon: "arrow_expand_all"
					label: `${stick.modelData.label}: full at`
					format: v => `${Math.round(v / 128 * 100)} %`
					value: root.p.sticks?.[stick.modelData.at + 1] ?? 128
					onMoved: v => {
						const s = (root.p.sticks ?? [0, 128, 0, 128]).slice();
						s[stick.modelData.at + 1] = Math.round(v);
						root.set("sticks", s);
					}
				}
			}
		}

		Flag { name: "invertLX"; text: "Left stick: left and right the other way" }
		Flag { name: "invertLY"; text: "Left stick: up and down the other way" }
		Flag { name: "invertRX"; text: "Right stick: left and right the other way" }
		Flag { name: "invertRY"; text: "Right stick: up and down the other way" }
		Flag { name: "swapSticks"; text: "Swap the sticks" }
		Flag { name: "swapDpad"; text: "Swap the left stick and the d-pad" }
	}

	// ── triggers ───────────────────────────────────────────────────────────
	SettingCard {
		anchor: "ultimate-triggers"
		visible: root.has
		title: "Triggers"
		subtitle: "Where a trigger starts to count and where it is fully down (Hall sensors). Pull one to see it; drag its marks."
		icon: "arrow_collapse_down"

		RowLayout {
			Layout.alignment: Qt.AlignHCenter
			spacing: 48

			Repeater {
				model: [
					{ label: "LT", at: 0, axis: "lt" },
					{ label: "RT", at: 2, axis: "rt" }
				]

				delegate: TriggerView {
					required property var modelData

					label: modelData.label
					value: Ultimate.axes[modelData.axis] ?? 0
					start: root.p.triggers?.[modelData.at] ?? 0
					full: root.p.triggers?.[modelData.at + 1] ?? 255
					onMoved: (start, full) => {
						const t = (root.p.triggers ?? [0, 255, 0, 255]).slice();
						t[modelData.at] = start;
						t[modelData.at + 1] = full;
						root.set("triggers", t);
					}
				}
			}
		}

		Repeater {
			model: [
				{ label: "LT", at: 0 },
				{ label: "RT", at: 2 }
			]

			delegate: ColumnLayout {
				id: trig

				required property var modelData

				Layout.fillWidth: true
				spacing: 4

				ValueSlider {
					from: 0
					to: 200
					step: 1
					icon: "arrow_right_thin"
					label: `${trig.modelData.label}: starts at`
					format: v => `${Math.round(v / 255 * 100)} %`
					value: root.p.triggers?.[trig.modelData.at] ?? 0
					onMoved: v => {
						const t = (root.p.triggers ?? [0, 255, 0, 255]).slice();
						t[trig.modelData.at] = Math.min(Math.round(v), t[trig.modelData.at + 1] - 10);
						root.set("triggers", t);
					}
				}

				ValueSlider {
					from: 60
					to: 255
					step: 1
					icon: "arrow_collapse_down"
					label: `${trig.modelData.label}: full at`
					format: v => `${Math.round(v / 255 * 100)} %`
					value: root.p.triggers?.[trig.modelData.at + 1] ?? 255
					onMoved: v => {
						const t = (root.p.triggers ?? [0, 255, 0, 255]).slice();
						t[trig.modelData.at + 1] = Math.max(Math.round(v), t[trig.modelData.at] + 10);
						root.set("triggers", t);
					}
				}
			}
		}

		Flag { name: "swapTriggers"; text: "Swap the triggers" }
	}

	// ── vibration ──────────────────────────────────────────────────────────
	SettingCard {
		anchor: "ultimate-rumble"
		visible: root.has
		title: "Vibration"
		icon: "vibrate"

		Repeater {
			model: [
				{ label: "Left motor", at: 0, icon: "arrow_left_bold" },
				{ label: "Right motor", at: 1, icon: "arrow_right_bold" }
			]

			delegate: RowLayout {
				id: motor

				required property var modelData

				Layout.fillWidth: true
				spacing: 8

				ValueSlider {
					Layout.fillWidth: true
					from: 0
					to: 5
					step: 1
					icon: motor.modelData.icon
					label: motor.modelData.label
					format: v => v === 0 ? "Off" : `${Math.round(v)} of 5`
					value: Math.round((root.p.rumble?.[motor.modelData.at] ?? 1) * 5)
					onMoved: v => {
						const r = (root.p.rumble ?? [1, 1]).slice();
						r[motor.modelData.at] = Math.round(v) / 5;
						root.set("rumble", r);
					}
				}

				IconButton {
					implicitWidth: 32
					implicitHeight: 32
					icon: "play"
					variant: "ghost"
					onClicked: Ultimate.rumble(motor.modelData.at === 0 ? Math.round((root.p.rumble?.[0] ?? 1) * 255) : 0, motor.modelData.at === 1 ? Math.round((root.p.rumble?.[1] ?? 1) * 255) : 0, 500)
				}
			}
		}
	}

	// ── motion ─────────────────────────────────────────────────────────────
	SettingCard {
		id: motion

		anchor: "ultimate-motion"
		visible: root.has
		title: "Motion"
		subtitle: "The six-axis sensor moves a stick: aim by tilting the pad."
		icon: "rotate_3d_variant"

		readonly property var g: root.p.gyro ?? ({})

		function put(values) {
			root.set("gyro", Object.assign({}, motion.g, values));
		}

		Line {
			text: "Moves"

			Segmented {
				Layout.preferredWidth: 320
				options: [
					{ value: "0", label: "Nothing" },
					{ value: "1", label: "Right stick" },
					{ value: "2", label: "Left stick" }
				]
				current: motion.g.on ? String(motion.g.mapping ?? 0) : "0"
				onSelected: value => motion.put({ on: value !== "0", mapping: Number(value) })
			}
		}

		Line {
			visible: motion.g.on === true
			text: "While"
			hint: "A button that turns motion on – or always"

			TextButton {
				variant: "tonal"
				icon: "chevron_down"
				text: (motion.g.key ?? "none") === "none" ? "Always" : Ultimate.functionLabel(motion.g.key)
				onActivated: gyroKey.open()

				PickList {
					id: gyroKey

					current: motion.g.key ?? "none"
					entries: [{ value: "none", label: "Always" }].concat(Ultimate.functions.filter(f => f.value !== "none" && !f.value.includes("-")))
					onPicked: value => motion.put({ key: String(value), trigger: String(value) === "none" ? 0 : Math.max(1, motion.g.trigger ?? 1) })
				}
			}

			Segmented {
				visible: (motion.g.key ?? "none") !== "none"
				Layout.preferredWidth: 220
				options: [
					{ value: "1", label: "Held" },
					{ value: "2", label: "Toggled" }
				]
				current: String(Math.max(1, motion.g.trigger ?? 1))
				onSelected: value => motion.put({ trigger: Number(value) })
			}
		}

		ValueSlider {
			visible: motion.g.on === true
			from: 1
			to: 10
			step: 1
			icon: "speedometer"
			label: "Sensitivity"
			value: motion.g.sensitivity ?? 5
			onMoved: v => motion.put({ sensitivity: Math.round(v) })
		}

		ValueSlider {
			visible: motion.g.on === true
			from: 0
			to: 100
			step: 1
			icon: "target"
			label: "Dead zone made up"
			format: v => `${Math.round(v)} %`
			value: motion.g.dead ?? 40
			onMoved: v => motion.put({ dead: Math.round(v) })
		}
	}

	// ── light ──────────────────────────────────────────────────────────────
	SettingCard {
		id: light

		anchor: "ultimate-light"
		visible: root.has
		title: "Light rings"
		subtitle: "Off holds only while one of the three profiles is in use: the standard setup lights anyway. The pad has no brightness of its own: the colours are written dimmer. A colour picked here lets go of the wallpaper."
		icon: "lightbulb_on"

		readonly property string theme: Ultimate.device.theme ?? "off"
		readonly property bool wallpaper: Ultimate.device.light?.wallpaper === true

		Segmented {
			Layout.fillWidth: true
			options: [
				{ value: "dynamic", label: "Dynamic" },
				{ value: "hotwheel", label: "Hotwheel" },
				{ value: "custom", label: "Own colours" },
				{ value: "off", label: "Off" }
			]
			current: light.theme
			onSelected: value => Ultimate.setTheme(value)
		}

		Line {
			text: "Colours"
			hint: light.wallpaper ? "The wallpaper's accents, made pure for the LEDs – they follow a new wallpaper (every profile)" : "Picked here, per profile"

			Segmented {
				Layout.preferredWidth: 260
				options: [
					{ value: "wallpaper", label: "Wallpaper", icon: "image_outline" },
					{ value: "own", label: "Own" }
				]
				current: light.wallpaper ? "wallpaper" : "own"
				onSelected: value => Ultimate.setLight({ wallpaper: value === "wallpaper" })
			}
		}

		ValueSlider {
			from: 5
			to: 100
			step: 5
			icon: "brightness_6"
			label: "Brightness"
			format: v => `${Math.round(v)} %`
			value: Math.round((Ultimate.device.light?.brightness ?? 1) * 100)
			onMoved: v => {
				brightness.level = Math.round(v) / 100;
				brightness.restart();
			}

			Timer {
				id: brightness

				property real level: 1

				interval: 400
				onTriggered: Ultimate.setLight({ brightness: brightness.level })
			}
		}

		RowLayout {
			visible: light.theme === "dynamic"
			spacing: 18

			ColorWell {
				label: "Colour"
				alpha: false
				value: root.p.dynamic?.color ?? "#260032"
				onPicked: css => root.set("dynamic", { color: css, background: root.p.dynamic?.background ?? "#084e50" })
			}

			ColorWell {
				label: "Behind"
				alpha: false
				value: root.p.dynamic?.background ?? "#084e50"
				onPicked: css => root.set("dynamic", { color: root.p.dynamic?.color ?? "#260032", background: css })
			}
		}

		ColumnLayout {
			visible: light.theme === "hotwheel"
			Layout.fillWidth: true

			RowLayout {
				spacing: 18

				ColorWell {
					label: "Colour"
					alpha: false
					value: root.p.hotwheel?.color ?? "#cc6200"
					onPicked: css => root.set("hotwheel", Object.assign({}, root.p.hotwheel, { color: css }))
				}

				ColorWell {
					label: "Behind"
					alpha: false
					value: root.p.hotwheel?.background ?? "#cc0000"
					onPicked: css => root.set("hotwheel", Object.assign({}, root.p.hotwheel, { background: css }))
				}
			}

			ValueSlider {
				from: 1
				to: 15
				step: 1
				icon: "speedometer"
				label: "Speed"
				value: root.p.hotwheel?.speed ?? 7
				onMoved: v => root.set("hotwheel", Object.assign({}, root.p.hotwheel, { speed: Math.round(v) }))
			}
		}

		ColumnLayout {
			visible: light.theme === "custom"
			Layout.fillWidth: true
			spacing: 8

			RowLayout {
				spacing: 12

				ColorWell {
					label: "Every light"
					alpha: false
					value: root.p.custom?.[0] ?? "#7e3200"
					onPicked: css => root.set("custom", Array(24).fill(css))
				}
			}

			Repeater {
				model: [
					{ label: "Left ring", from: 0 },
					{ label: "Right ring", from: 12 }
				]

				delegate: RowLayout {
					id: ringRow

					required property var modelData

					spacing: 4

					StyledText {
						Layout.preferredWidth: 80
						text: ringRow.modelData.label
						tone: Theme.textMuted
					}

					Repeater {
						model: 12

						delegate: ColorWell {
							id: well

							required property int index

							size: 22
							showHex: false
							alpha: false
							value: root.p.custom?.[ringRow.modelData.from + well.index] ?? "#000000"
							onPicked: css => {
								const c = (root.p.custom ?? Array(24).fill("#000000")).slice();
								c[ringRow.modelData.from + well.index] = css;
								root.set("custom", c);
							}
						}
					}
				}
			}
		}
	}

	// ── macros ─────────────────────────────────────────────────────────────
	SettingCard {
		anchor: "ultimate-macros"
		visible: root.has
		title: "Macros"
		subtitle: "Four per profile, kept in the pad. Record one by playing it on the controller."
		icon: "record_rec"

		Repeater {
			model: root.p.macros ?? []

			delegate: ColumnLayout {
				id: mac

				required property var modelData
				required property int index
				readonly property bool live: Ultimate.macroState === "recording" && macroWatch.mine
				readonly property var steps: Ultimate.steps[`${root.edit}/${mac.index}`] ?? null
				property bool open: false

				Layout.fillWidth: true
				spacing: 6

				QtObject {
					id: macroWatch

					property bool mine: false
				}

				Connections {
					target: Ultimate

					function onMacroStateChanged() {
						if (Ultimate.macroState === "idle") macroWatch.mine = false;
					}
				}

				RowLayout {
					Layout.fillWidth: true
					spacing: 8

					StyledText {
						Layout.preferredWidth: 20
						text: mac.index + 1
						font.weight: Font.Bold
						tone: mac.modelData.steps > 0 ? Theme.primary : Theme.textMuted
					}

					Field {
						Layout.preferredWidth: 160
						text: mac.modelData.name ?? ""
						placeholder: `Macro ${mac.index + 1}`
						clearable: false
						onAccepted: Ultimate.setMacro(root.edit, mac.index, { name: text.trim() })
					}

					TextButton {
						variant: mac.modelData.key === "none" ? "ghost" : "tonal"
						icon: "chevron_down"
						text: mac.modelData.key === "none" ? "No button" : `On ${Ultimate.functionLabel(mac.modelData.key)}`
						onActivated: macroKey.open()

						PickList {
							id: macroKey

							current: mac.modelData.key
							entries: [{ value: "none", label: "No button" }].concat(Ultimate.buttons.filter(b => b.id !== "home").map(b => ({ value: b.id, label: b.label })))
							onPicked: value => Ultimate.setMacro(root.edit, mac.index, { key: String(value) })
						}
					}

					StyledText {
						Layout.fillWidth: true
						text: mac.live ? `${Ultimate.macroSteps} steps …` : (mac.modelData.steps > 0 ? `${mac.modelData.steps} steps` : "Empty")
						tone: Theme.textMuted
					}

					TextButton {
						variant: mac.live ? "filled" : "ghost"
						icon: mac.live ? "stop" : "record_rec"
						text: mac.live ? "Stop" : "Record"
						enabled: mac.live || Ultimate.macroState === "idle"
						onActivated: {
							if (mac.live) {
								Ultimate.stopRecording();
							} else {
								macroWatch.mine = true;
								Ultimate.record(root.edit, mac.index);
							}
						}
					}

					IconButton {
						implicitWidth: 30
						implicitHeight: 30
						visible: mac.modelData.steps > 0
						icon: mac.open ? "chevron_up" : "chevron_down"
						variant: "ghost"
						onClicked: {
							mac.open = !mac.open;
							if (mac.open) Ultimate.readSteps(root.edit, mac.index);
						}
					}
				}

				RowLayout {
					visible: mac.modelData.steps > 0 || mac.modelData.key !== "none"
					Layout.fillWidth: true
					Layout.leftMargin: 28
					spacing: 8

					Segmented {
						Layout.preferredWidth: 300
						options: [
							{ value: "once", label: "Once" },
							{ value: "times", label: "Times" },
							{ value: "held", label: "While held" }
						]
						current: mac.modelData.cycles === 4294967295 ? "held" : (mac.modelData.cycles > 1 ? "times" : "once")
						onSelected: value => Ultimate.setMacro(root.edit, mac.index, { cycles: value === "held" ? 4294967295 : (value === "times" ? 3 : 1) })
					}

					ValueSlider {
						visible: mac.modelData.cycles > 1 && mac.modelData.cycles !== 4294967295
						Layout.fillWidth: true
						from: 2
						to: 50
						step: 1
						label: "Times"
						value: mac.modelData.cycles
						onMoved: v => Ultimate.setMacro(root.edit, mac.index, { cycles: Math.round(v) })
					}

					ValueSlider {
						visible: mac.modelData.cycles !== 1
						Layout.fillWidth: true
						from: 0
						to: 2000
						step: 10
						label: "Pause between"
						format: v => `${Math.round(v)} ms`
						value: mac.modelData.interval ?? 0
						onMoved: v => Ultimate.setMacro(root.edit, mac.index, { interval: Math.round(v) })
					}
				}

				Flow {
					visible: mac.open && mac.steps !== null
					Layout.fillWidth: true
					Layout.leftMargin: 28
					spacing: 4

					Repeater {
						model: mac.steps ?? []

						delegate: Chip {
							required property var modelData

							text: {
								const k = modelData[1];
								const names = [["a", 0x2000], ["b", 0x1000], ["x", 0x10], ["y", 0x20], ["lb", 0x400], ["rb", 0x800], ["lt", 0x4000], ["rt", 0x8000], ["l3", 2], ["r3", 4], ["select", 8], ["start", 1], ["up", 0x200], ["down", 0x100], ["left", 0x80], ["right", 0x40]];
								const held = names.filter(n => k & n[1]).map(n => Ultimate.buttonLabel(n[0]));
								if (modelData[3] !== 0x7f7f) held.push("LS");
								if (modelData[4] !== 0x7f7f) held.push("RS");
								return `${held.join("+") || "—"} ${modelData[0]} ms`;
							}
						}
					}
				}
			}
		}

		StyledText {
			visible: Ultimate.macroState === "recording"
			Layout.fillWidth: true
			text: "Recording: the pad's presses go to the macro, not to games. Stop here when done (at most a minute, 199 changes)."
			tone: Theme.warning
			wrapMode: Text.Wrap
		}
	}

	// ── profiles ───────────────────────────────────────────────────────────
	SettingCard {
		anchor: "ultimate-profiles"
		visible: root.has
		title: "Profiles"
		subtitle: "The star button on the pad goes through the profiles made here and the standard setup."
		icon: "account_switch_outline"

		Repeater {
			model: Ultimate.profiles

			delegate: RowLayout {
				id: prof

				required property var modelData

				Layout.fillWidth: true
				spacing: 10

				StyledText {
					Layout.preferredWidth: 24
					Layout.leftMargin: 12
					text: prof.modelData.slot + 1
					font.weight: Font.Bold
					tone: Ultimate.slot === prof.modelData.slot ? Theme.primary : Theme.textMuted
				}

				Field {
					Layout.fillWidth: true
					text: prof.modelData.name ?? ""
					placeholder: `Profile ${prof.modelData.slot + 1}`
					enabled: prof.modelData.on === true
					clearable: false
					onAccepted: if (text.trim() && text.trim() !== prof.modelData.name) Ultimate.set(prof.modelData.slot, "name", text.trim().slice(0, 16))
				}

				TextButton {
					visible: prof.modelData.on && prof.modelData.slot !== root.edit && (Ultimate.profiles[root.edit]?.on ?? false)
					variant: "ghost"
					icon: "content_copy"
					text: `Copy ${root.profileName(root.edit)} here`
					confirm: true
					onActivated: Ultimate.copy(root.edit, prof.modelData.slot)
				}

				Toggle {
					checked: prof.modelData.on === true
					onToggled: on => Ultimate.setProfile(prof.modelData.slot, on)
				}
			}
		}
	}

	// ── the device ─────────────────────────────────────────────────────────
	SettingCard {
		anchor: "ultimate-device"
		visible: Ultimate.online
		title: "This controller"
		subtitle: [
			Ultimate.pad ? `Controller firmware ${(Ultimate.pad.firmware / 100).toFixed(2)}` : "",
			Ultimate.info.dongle ? `dongle ${((Ultimate.info.firmware ?? 0) / 100).toFixed(2)}` : `firmware ${((Ultimate.info.firmware ?? 0) / 100).toFixed(2)}`,
			({ 2: "Wukong edition", 3: "Lilac edition" })[Ultimate.pad?.edition] ?? "",
			({ xinput: "XInput", switch: "Switch", android: "Android", mac: "macOS" })[root.dev.mode] ?? ""
		].filter(s => s).join(" · ")
		icon: "information_outline"

		RowLayout {
			Layout.fillWidth: true

			StyledText {
				Layout.fillWidth: true
				text: Ultimate.pad ? `Battery ${Ultimate.pad.battery} %` : ""
				tone: (Ultimate.pad?.battery ?? 100) <= 15 ? Theme.warning : Theme.textMuted
			}

			TextButton {
				visible: root.dev.backup === true && root.has
				variant: "ghost"
				icon: "undo"
				text: "Put back as first seen"
				confirm: true
				onActivated: Ultimate.restore()
			}

			TextButton {
				variant: "ghost"
				icon: "refresh"
				text: "Read again"
				onActivated: Ultimate.refresh()
			}
		}
	}
}
