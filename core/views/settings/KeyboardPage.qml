pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services
import qs.core.views.settings.mouse
import qs.core.views.settings.keyboard

// The Logitech keyboard (core/services/Keyboard.qml): what its special keys
// do – also per app –, its backlight, Fn keys, locked keys, platform,
// Easy-Switch and battery. The drawing is the keyboard, live.
SettingsPage {
	id: root

	title: Keyboard.device ? Keyboard.device.name : "Keyboard"
	description: ""
	recording: picker.recording

	property string control: "emoji"
	property string app: ""

	onActiveChanged: {
		Keyboard.watching = root.active;
		if (root.active) Keyboard.refresh();
	}
	Component.onDestruction: Keyboard.watching = false

	readonly property var st: Keyboard.state
	readonly property bool has: Keyboard.online
	readonly property var light: root.st.backlight ?? null
	readonly property var meta: Keyboard.keyInfo(root.control)
	readonly property bool solaarOwned: Keyboard.solaar && Keyboard.solaarKeys.includes(root.control)
	readonly property var triggers: [
		{ id: "click", label: "Press", icon: "gesture_tap" },
		{ id: "double", label: "Double press", icon: "gesture_double_tap" },
		{ id: "hold", label: "Hold", icon: "gesture_tap_hold" }
	]

	function fmtSeconds(s) {
		s = Math.round(s);
		return s >= 60 ? `${Math.round(s / 6) / 10} min` : `${s} s`;
	}

	// ── the keyboard, live ─────────────────────────────────────────────────
	SettingCard {
		anchor: "keyboard-keys"
		visible: !!Keyboard.device
		title: root.meta?.label ?? "Keys"
		subtitle: !Keyboard.online ? "Asleep – press a key to wake it" : ""
		icon: root.meta?.icon ?? "keyboard"

		trailing: RowLayout {
			spacing: 10

			Glyph {
				icon: (root.st.battery?.status ?? "").startsWith("charging") ? "battery_charging" : "battery"
				size: 16
				color: (root.st.battery?.percent ?? 100) <= 10 ? Theme.danger : Theme.textMuted
			}

			StyledText {
				text: root.st.battery ? `${root.st.battery.percent} %` : "–"
				tabular: true
				font.weight: Font.DemiBold
			}
		}

		KeyboardFigure {
			Layout.fillWidth: true
			Layout.preferredHeight: Math.min(260, width * 6.6 / 23)
			opacity: root.has ? 1 : 0.45
			controls: root.st.controls ?? []
			keyList: Keyboard.keyList
			selected: root.control
			pressed: Keyboard.pressed
			keys: Keyboard.keys
			light: !root.light || !root.light.on ? 0 : (root.light.mode === "auto" ? 0.5 : root.light.level / Math.max(1, root.light.levels - 1))
			flash: Keyboard.glow < 0 || !root.light ? -1 : Keyboard.glow / Math.max(1, root.light.levels - 1)
			owned: Keyboard.solaar ? Keyboard.solaarKeys : []
			assigned: Keyboard.rules.map(r => r.control)
			onPicked: control => root.control = control

			Behavior on opacity {
				Anim {
					duration: Motion.long
				}
			}
		}

		// where: everywhere or an app
		Flow {
			Layout.fillWidth: true
			spacing: 8

			Repeater {
				model: [""].concat(Keyboard.apps)

				delegate: Chip {
					required property string modelData

					text: modelData === "" ? "Everywhere" : modelData
					icon: modelData === "" ? "earth" : "application_outline"
					selected: root.app === modelData
					acceptedButtons: Qt.LeftButton | Qt.RightButton
					onClicked: root.app = modelData
					onRightClicked: if (modelData !== "") {
						if (root.app === modelData) root.app = "";
						Keyboard.removeApp(modelData);
					}
				}
			}

			Chip {
				visible: Keyboard.focusApp !== "" && !Keyboard.apps.includes(Keyboard.focusApp)
				text: Keyboard.focusApp
				icon: "plus"
				onClicked: {
					Keyboard.addApp(Keyboard.focusApp);
					root.app = Keyboard.focusApp;
				}
			}
		}

		// Solaar answers this key
		RowLayout {
			Layout.fillWidth: true
			visible: root.solaarOwned
			spacing: 10

			Glyph {
				icon: "swap_horizontal"
				size: 18
				color: Theme.warning
			}

			StyledText {
				Layout.fillWidth: true
				text: "Solaar"
				tone: Theme.textMuted
			}

			TextButton {
				variant: "filled"
				icon: "swap_horizontal"
				text: "Take over from Solaar"
				onActivated: Keyboard.takeOver()
			}
		}

		// what each way of pressing does
		Repeater {
			model: root.solaarOwned ? [] : root.triggers

			delegate: Clickable {
				id: row

				required property var modelData
				readonly property var rule: Keyboard.ruleFor(root.control, row.modelData.id, root.app)
				readonly property var shown: Keyboard.describe(Keyboard.effective(root.control, row.modelData.id, root.app)?.action ?? (row.modelData.id === "click" ? null : { kind: "none" }), root.control)
				property bool lit: false

				Layout.fillWidth: true
				implicitHeight: 52
				radius: Theme.radius.large
				color: row.lit ? Theme.primaryContainer : Theme.layer2
				onClicked: picker.show(root.control, row.modelData.id, root.app)

				Behavior on color {
					ColorAnim {}
				}

				Connections {
					target: Keyboard

					function onFired(rule, control, trigger) {
						if (control === root.control && trigger === row.modelData.id) {
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
						icon: row.modelData.icon
						size: 18
						color: Theme.textMuted
					}

					StyledText {
						Layout.preferredWidth: 130
						text: row.modelData.label
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
						text: row.shown.label + (!row.rule && root.app !== "" && Keyboard.effective(root.control, row.modelData.id, root.app) ? " · everywhere" : "")
						tone: row.rule ? Theme.text : Theme.textSubtle
						elide: Text.ElideRight
					}

					IconButton {
						visible: !!row.rule
						implicitWidth: 30
						implicitHeight: 30
						icon: "close"
						variant: "ghost"
						onClicked: Keyboard.removeRule(row.rule.id)
					}

					Glyph {
						icon: "chevron_right"
						size: 16
						color: Theme.textFaint
					}
				}
			}
		}

		ActionPicker {
			id: picker

			store: Keyboard
			onChosen: (action, extra) => Keyboard.assign(picker.control, picker.trigger, picker.app, action, extra)
			onCleared: Keyboard.assign(picker.control, picker.trigger, picker.app, null)
		}
	}

	// ── nothing to show ────────────────────────────────────────────────────
	SettingCard {
		anchor: "keyboard-none"
		visible: !Keyboard.device
		title: Keyboard.scanned ? "No Logitech keyboard found" : "Looking for the keyboard …"
		icon: "keyboard_off"
	}

	// ── Solaar ─────────────────────────────────────────────────────────────
	SettingCard {
		id: solaarCard

		property string result: ""

		anchor: "keyboard-solaar"
		visible: solaarCard.result !== ""
		title: "The shell has the keys now"
		subtitle: solaarCard.result
		icon: "check_circle"

		Connections {
			target: Keyboard

			function onImported(rules, skipped, restarted) {
				solaarCard.result = `${rules} ${rules === 1 ? "rule" : "rules"} came along${skipped > 0 ? `, ${skipped} not` : ""}${restarted ? ". Solaar runs on for the rest" : ""}.`;
			}
		}
	}

	// ── light ──────────────────────────────────────────────────────────────
	SettingCard {
		anchor: "keyboard-light"
		visible: root.has && !!root.light
		title: "Backlight"
		icon: "lightbulb_on"

		RowLayout {
			Layout.fillWidth: true
			spacing: 12

			StyledText {
				Layout.fillWidth: true
				text: "Mode"
				font.weight: Font.Medium
			}

			Segmented {
				Layout.preferredWidth: 320
				options: [
					{ value: "off", label: "Off", icon: "lightbulb_outline" },
					{ value: "auto", label: "Auto", icon: "brightness_auto" },
					{ value: "manual", label: "Fixed", icon: "lightbulb_on" }
				]
				current: !root.light?.on ? "off" : root.light.mode
				onSelected: value => Keyboard.setMany(value === "off" ? { on: false } : { on: true, mode: value })
			}
		}

		ValueSlider {
			visible: root.light?.on === true && root.light?.mode === "manual"
			from: 0
			to: Math.max(1, (root.light?.levels ?? 8) - 1)
			step: 1
			icon: "brightness_6"
			label: "Brightness"
			value: root.light?.level ?? 0
			onMoved: v => Keyboard.setMany({ on: true, mode: "manual", level: Math.round(v) })
		}

		ValueSlider {
			visible: root.light?.on === true
			from: 5
			to: 300
			step: 5
			icon: "hand_back_left_off_outline"
			label: "Hands away"
			format: v => root.fmtSeconds(v)
			value: root.light?.away ?? 15
			onMoved: v => Keyboard.set("away", Math.round(v))
		}

		ValueSlider {
			visible: root.light?.on === true
			from: 5
			to: 600
			step: 5
			icon: "hand_back_left_outline"
			label: "Hands near"
			format: v => root.fmtSeconds(v)
			value: root.light?.near ?? 30
			onMoved: v => Keyboard.set("near", Math.round(v))
		}

		ValueSlider {
			visible: root.light?.on === true
			from: 5
			to: 3600
			step: 5
			icon: "power_plug"
			label: "On the cable"
			format: v => root.fmtSeconds(v)
			value: root.light?.powered ?? 300
			onMoved: v => Keyboard.set("powered", Math.round(v))
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 12

			StyledText {
				Layout.fillWidth: true
				text: "Flash on notifications"
				font.weight: Font.Medium
			}

			Segmented {
				Layout.preferredWidth: 320
				options: [
					{ value: "off", label: "Never" },
					{ value: "critical", label: "Urgent" },
					{ value: "all", label: "All" }
				]
				current: Keyboard.option("flash", "off")
				onSelected: value => Keyboard.setOption("flash", value)
			}
		}

		RowLayout {
			Layout.fillWidth: true
			visible: Keyboard.option("flash", "off") !== "off"
			spacing: 12

			StyledText {
				Layout.fillWidth: true
				text: "Pattern"
				font.weight: Font.Medium
			}

			Segmented {
				Layout.preferredWidth: 360
				options: [
					{ value: "pulse", label: "Pulse" },
					{ value: "blink", label: "Blink" },
					{ value: "glow", label: "Glow" },
					{ value: "once", label: "Once" }
				]
				current: Keyboard.option("flashPattern", "pulse")
				onSelected: value => {
					Keyboard.setOption("flashPattern", value);
					Keyboard.flash(value);
				}
			}
		}
	}

	// ── keys ───────────────────────────────────────────────────────────────
	SettingCard {
		anchor: "keyboard-fn"
		visible: root.has && (root.st.fnSwap !== undefined || !!root.st.disabled || !!root.st.platform)
		title: "Keys"
		icon: "keyboard_f1"

		FlagRow {
			visible: root.st.fnSwap !== undefined
			icon: "keyboard_f1"
			title: "F1–F12 without Fn"
			checked: root.st.fnSwap === false
			onToggled: on => Keyboard.set("fnSwap", !on)
		}

		RowLayout {
			Layout.fillWidth: true
			visible: !!root.st.disabled
			spacing: 12

			StyledText {
				Layout.fillWidth: true
				text: "Switched off"
				font.weight: Font.Medium
			}

			Repeater {
				model: root.st.disabled?.capable ?? []

				delegate: Chip {
					required property string modelData

					text: ({ capslock: "Caps Lock", numlock: "Num Lock", scrolllock: "Scroll Lock", insert: "Insert", super: "Super" })[modelData] ?? modelData
					selected: (root.st.disabled?.off ?? []).includes(modelData)
					onClicked: {
						const off = (root.st.disabled?.off ?? []).slice();
						const at = off.indexOf(modelData);
						if (at >= 0) off.splice(at, 1);
						else off.push(modelData);
						Keyboard.patch(Keyboard.device.id, { disabled: Object.assign({}, root.st.disabled, { off }) });
						Keyboard.set("disabled", off);
					}
				}
			}
		}

		RowLayout {
			Layout.fillWidth: true
			visible: root.st.platform?.settable === true
			spacing: 12

			StyledText {
				Layout.fillWidth: true
				text: "Layout for"
				font.weight: Font.Medium
			}

			Segmented {
				Layout.preferredWidth: 380
				options: (root.st.platform?.choices ?? []).map(c => ({ value: String(c.index), label: ({ linux: "Linux", macos: "macOS", ios: "iOS", chrome: "ChromeOS", windows: "Windows", android: "Android" })[c.os[0]] ?? c.os[0] }))
				current: String(root.st.platform?.current ?? 0)
				onSelected: value => {
					Keyboard.patch(Keyboard.device.id, { platform: Object.assign({}, root.st.platform, { current: Number(value) }) });
					Keyboard.set("platform", Number(value));
				}
			}
		}

		RowLayout {
			Layout.fillWidth: true
			visible: !!root.st.locks
			spacing: 8

			Repeater {
				model: [["capslock", "Caps Lock"], ["numlock", "Num Lock"]]

				delegate: Chip {
					required property var modelData

					text: modelData[1]
					icon: root.st.locks?.[modelData[0]] ? "lock" : "lock_open_variant_outline"
					selected: root.st.locks?.[modelData[0]] === true
					enabled: false
				}
			}
		}
	}

	// ── easy-switch ────────────────────────────────────────────────────────
	SettingCard {
		anchor: "keyboard-hosts"
		visible: root.has && !!root.st.hosts
		title: "Easy-Switch"
		icon: "monitor_multiple"

		RowLayout {
			Layout.fillWidth: true
			spacing: 10

			Repeater {
				model: root.st.hosts?.hosts ?? []

				delegate: Clickable {
					id: hostTile

					required property var modelData
					readonly property bool here: (root.st.hosts?.current ?? -1) === hostTile.modelData.index
					property bool armed: false

					Layout.fillWidth: true
					implicitHeight: 84
					radius: Theme.radius.large
					color: hostTile.here ? Theme.primaryContainer : (hostTile.armed ? Theme.dangerContainer : Theme.layer2)
					border.width: hostTile.here ? 1.5 : 0
					border.color: Theme.primary
					interactive: !hostTile.here && hostTile.modelData.paired
					onClicked: {
						if (!hostTile.armed) {
							hostTile.armed = true;
							disarm.restart();
							return;
						}
						Keyboard.switchHost(hostTile.modelData.index);
						hostTile.armed = false;
					}

					Timer {
						id: disarm

						interval: 3000
						onTriggered: hostTile.armed = false
					}

					ColumnLayout {
						anchors.centerIn: parent
						spacing: 4

						StyledText {
							Layout.alignment: Qt.AlignHCenter
							text: hostTile.modelData.index + 1
							font.weight: Font.Bold
							tone: hostTile.here ? Theme.primary : Theme.text
						}

						StyledText {
							Layout.alignment: Qt.AlignHCenter
							text: hostTile.armed ? "Again to switch" : (hostTile.modelData.name || (hostTile.modelData.paired ? "Paired" : "Free"))
							tone: hostTile.armed ? Theme.danger : Theme.textSubtle
							font.pixelSize: Theme.size.small
						}
					}
				}
			}
		}
	}

	// ── battery ────────────────────────────────────────────────────────────
	SettingCard {
		anchor: "keyboard-battery"
		visible: root.has && !!root.st.battery
		title: "Battery"
		subtitle: `${root.st.battery?.percent ?? 0} % · ${root.st.battery?.status ?? ""}`
		icon: (root.st.battery?.status ?? "").startsWith("charging") ? "battery_charging" : "battery"

		BatteryChart {
			Layout.fillWidth: true
			Layout.preferredHeight: 120
			log: Keyboard.batteryLog
		}
	}

	// ── the device ─────────────────────────────────────────────────────────
	SettingCard {
		anchor: "keyboard-device"
		visible: !!Keyboard.device
		title: "This keyboard"
		subtitle: Keyboard.device ? `${Keyboard.device.serial} · ${(Keyboard.device.firmware ?? []).join(", ")}` : ""
		icon: "information_outline"

		Flow {
			Layout.fillWidth: true
			spacing: 4

			Repeater {
				model: Keyboard.device?.features ?? []

				delegate: Rectangle {
					required property string modelData

					width: featureText.implicitWidth + 12
					height: 22
					radius: 6
					color: Theme.layer2

					StyledText {
						id: featureText

						anchors.centerIn: parent
						text: modelData
						tone: Theme.textSubtle
						font.family: Theme.monoFamily
						font.pixelSize: Theme.size.tiny
					}
				}
			}
		}

		RowLayout {
			Layout.fillWidth: true

			Item {
				Layout.fillWidth: true
			}

			TextButton {
				variant: "ghost"
				icon: "flash"
				text: "Flash"
				enabled: !!root.light
				onActivated: Keyboard.flash()
			}

			TextButton {
				variant: "ghost"
				icon: "refresh"
				text: "Read again"
				onActivated: Keyboard.refresh()
			}
		}
	}
}
