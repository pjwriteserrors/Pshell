pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services
import qs.core.views.settings.mouse
import qs.core.views.settings.headset

// The Sennheiser PC 8.2 USB (core/services/Headset.qml): volume and balance,
// the microphone, sidetone, what its two buttons do and its audio profile.
// The drawing is the headset, live.
SettingsPage {
	id: root

	title: "PC 8.2 USB"
	description: ""
	recording: picker.recording

	signal open(string page)

	property string control: "up"
	property string app: ""

	onActiveChanged: {
		Headset.watching = root.active;
		if (root.active) Headset.refresh();
	}
	Component.onDestruction: Headset.watching = false

	readonly property bool has: Headset.online
	readonly property var dev: Headset.device

	function db(v) {
		return v === null || v === undefined ? "" : `${v > 0 ? "+" : ""}${Math.round(v * 10) / 10} dB`;
	}

	// ── the headset, live ──────────────────────────────────────────────────
	SettingCard {
		anchor: "headset-device"
		title: !Headset.scanned ? "Looking for the headset …" : (root.has ? (root.dev.name ?? "PC 8.2 USB") : "Not connected")
		subtitle: root.has ? [Headset.isOutput ? "Output" : "", Headset.isInput ? "Input" : "", Headset.cableMuted ? "Muted on the cable" : ""].filter(s => s).join(" · ") : ""
		icon: root.has ? "headset" : "headset_off"

		trailing: TextButton {
			visible: root.has && (!Headset.isOutput || !Headset.isInput) && (!!Headset.sink || !!Headset.source)
			variant: "ghost"
			icon: "headset"
			text: "Use"
			onActivated: {
				Headset.useAsOutput();
				Headset.useAsInput();
			}
		}

		HeadsetFigure {
			Layout.fillWidth: true
			Layout.preferredHeight: Math.min(270, width * 270 / 420)
			online: root.has
			leftLevel: Headset.volumes.length > 1 ? Headset.volumes[0] : Headset.volume
			rightLevel: Headset.volumes.length > 1 ? Headset.volumes[1] : Headset.volume
			muted: Headset.muted
			level: Headset.level
			micMuted: Headset.micMuted
			cableMuted: Headset.cableMuted
			sidetone: Headset.sidetoneOn
			keys: Headset.keys
			selected: root.control
			onPicked: control => root.control = control
		}

		RowLayout {
			Layout.fillWidth: true
			visible: root.has && !Headset.access
			spacing: 12

			StyledText {
				Layout.fillWidth: true
				Layout.leftMargin: 12
				text: "No access to the buttons"
				tone: Theme.textMuted
			}

			TextButton {
				variant: "ghost"
				icon: "key"
				text: "Allow"
				onActivated: Headset.allowAccess()
			}
		}

		StyledText {
			Layout.fillWidth: true
			visible: Headset.error !== ""
			text: Headset.error
			tone: Theme.danger
		}
	}

	// ── what you hear ──────────────────────────────────────────────────────
	SettingCard {
		anchor: "headset-sound"
		visible: root.has && !!Headset.sink
		title: "Sound"
		icon: "headphones"
		modified: Math.abs(Headset.balance) > 0.005
		onReset: Headset.setBalance(0)

		ValueSlider {
			from: 0
			to: 100
			step: 1
			icon: Headset.muted ? "volume_off" : "volume_high"
			label: "Volume"
			format: v => `${Math.round(v)} %`
			value: Headset.volume * 100
			onMoved: v => Headset.setVolume(v / 100)
		}

		ValueSlider {
			from: -100
			to: 100
			step: 1
			icon: "scale_balance"
			label: "Balance"
			format: v => Math.round(v) === 0 ? "Centre" : (v < 0 ? `L ${Math.round(-v)}` : `R ${Math.round(v)}`)
			value: Headset.balance * 100
			onMoved: v => Headset.setBalance(Math.abs(v) < 3 ? 0 : v / 100)
		}

		FlagRow {
			icon: "volume_off"
			title: "Mute"
			checked: Headset.muted
			onToggled: on => Headset.setMuted(on)
		}
	}

	// ── the microphone ─────────────────────────────────────────────────────
	SettingCard {
		anchor: "headset-mic"
		visible: root.has && !!Headset.source
		title: "Microphone"
		subtitle: Headset.cableMuted ? "Muted on the cable" : ""
		icon: Headset.micMuted || Headset.cableMuted ? "microphone_off" : "microphone"

		// the level, as the headset sends it
		Item {
			Layout.fillWidth: true
			Layout.leftMargin: 12
			Layout.rightMargin: 12
			implicitHeight: 10

			Rectangle {
				anchors.fill: parent
				radius: height / 2
				color: Theme.layer2
			}

			Rectangle {
				height: parent.height
				radius: height / 2
				width: parent.width * Math.max(0, Math.min(1, (Headset.level + 70) / 70))
				color: Headset.cableMuted || Headset.micMuted ? Theme.danger : Theme.primary

				Behavior on width {
					Anim {
						duration: 80
					}
				}
			}

			Rectangle {
				x: parent.width * Math.max(0, Math.min(1, (Headset.peak + 70) / 70)) - 1
				width: 2
				height: parent.height
				color: Theme.text
				opacity: 0.5
			}
		}

		ValueSlider {
			from: 0
			to: 100
			step: 1
			icon: "microphone"
			label: "Gain"
			format: v => `${Math.round(v)} %`
			value: Headset.micVolume * 100
			onMoved: v => Headset.setMicVolume(v / 100)
		}

		FlagRow {
			icon: "microphone_off"
			title: "Mute"
			checked: Headset.micMuted
			onToggled: on => Headset.setMicMuted(on)
		}

		FlagRow {
			icon: "microphone_off"
			title: "Show when muted on the cable"
			checked: Headset.option("cableNotice", true)
			onToggled: on => Headset.setOption("cableNotice", on)
		}
	}

	// ── sidetone ───────────────────────────────────────────────────────────
	SettingCard {
		anchor: "headset-sidetone"
		visible: root.has
		title: "Sidetone"
		icon: "account_voice"
		modified: Headset.sidetone !== Headset.own.sidetone || Headset.sidetoneOn !== Headset.own.sidetoneOn
		onReset: Headset.resetSidetone()

		trailing: Toggle {
			checked: Headset.sidetoneOn
			onToggled: on => Headset.setSidetoneOn(on)
		}

		ValueSlider {
			enabled: Headset.sidetoneOn
			opacity: Headset.sidetoneOn ? 1 : 0.5
			from: (Headset.scales.sidetone ?? [0, 30])[0]
			to: (Headset.scales.sidetone ?? [0, 30])[1]
			step: 1
			icon: "account_voice"
			label: "Level"
			format: v => root.db(Headset.sidetoneDb(Math.round(v)))
			value: Headset.sidetone
			onMoved: v => sidetoneLater.go(Math.round(v))

			Timer {
				id: sidetoneLater

				property int level: 18

				function go(level) {
					sidetoneLater.level = level;
					if (!sidetoneLater.running) sidetoneLater.start();
				}

				interval: 40
				onTriggered: Headset.setSidetone(sidetoneLater.level)
			}
		}
	}

	// ── the buttons ────────────────────────────────────────────────────────
	SettingCard {
		anchor: "headset-buttons"
		visible: root.has
		title: Headset.controlNames[root.control] ?? "Buttons"
		icon: "gesture_tap"

		trailing: Segmented {
			Layout.preferredWidth: 200
			options: [{ value: "up", label: "+" }, { value: "down", label: "−" }]
			current: root.control
			onSelected: value => root.control = value
		}

		Flow {
			Layout.fillWidth: true
			spacing: 8

			Repeater {
				model: [""].concat(Headset.apps)

				delegate: Chip {
					required property string modelData

					text: modelData === "" ? "Everywhere" : modelData
					icon: modelData === "" ? "earth" : "application_outline"
					selected: root.app === modelData
					acceptedButtons: Qt.LeftButton | Qt.RightButton
					onClicked: root.app = modelData
					onRightClicked: if (modelData !== "") {
						if (root.app === modelData) root.app = "";
						Headset.removeApp(modelData);
					}
				}
			}

			Chip {
				visible: Headset.focusApp !== "" && !Headset.apps.includes(Headset.focusApp)
				text: Headset.focusApp
				icon: "plus"
				onClicked: {
					Headset.addApp(Headset.focusApp);
					root.app = Headset.focusApp;
				}
			}
		}

		Repeater {
			model: [
				{ trigger: "press", label: "Press", icon: "gesture_tap" },
				{ trigger: "double", label: "Double press", icon: "gesture_double_tap" },
				{ trigger: "hold", label: "Hold", icon: "gesture_tap_hold" }
			]

			delegate: BindRow {
				required property var modelData

				app: root.app
				control: root.control
				trigger: modelData.trigger
				label: modelData.label
				icon: modelData.icon
				onPick: (control, trigger) => picker.show(control, trigger, root.app)
			}
		}

		ActionPicker {
			id: picker

			store: Headset
			onChosen: (action, extra) => Headset.assign(picker.control, picker.trigger, picker.app, action, extra)
			onCleared: Headset.assign(picker.control, picker.trigger, picker.app, null)
		}
	}

	component BindRow: Clickable {
		id: row

		property string app: ""
		property string control: ""
		property string trigger: "press"
		property string label: ""
		property string icon: ""
		readonly property var rule: Headset.ruleFor(row.control, row.trigger, row.app)
		readonly property var shown: Headset.describe(Headset.effective(row.control, row.trigger, row.app)?.action ?? (row.trigger === "press" ? null : { kind: "none" }), row.control)
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
			target: Headset

			function onFired(rule, control, trigger) {
				if (control === row.control && trigger === Headset.triggerOf[row.trigger]) {
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
				text: row.shown.label + (!row.rule && row.app !== "" && Headset.effective(row.control, row.trigger, row.app) ? " · everywhere" : "")
				tone: row.rule ? Theme.text : Theme.textSubtle
				elide: Text.ElideRight
			}

			IconButton {
				visible: !!row.rule
				implicitWidth: 30
				implicitHeight: 30
				icon: "close"
				variant: "ghost"
				onClicked: Headset.assign(row.control, row.trigger, row.app, null)
			}

			Glyph {
				icon: "chevron_right"
				size: 16
				color: Theme.textFaint
			}
		}
	}

	// ── the audio profile ──────────────────────────────────────────────────
	SettingCard {
		anchor: "headset-profile"
		visible: root.has && Headset.profiles.length > 0
		title: "Profile"
		icon: "tune_vertical"

		Segmented {
			Layout.fillWidth: true
			options: Headset.profiles.map(p => ({
				value: p.name,
				label: ({ "off": "Off", "output:analog-stereo+input:analog-stereo": "Sound + mic", "output:analog-stereo": "Sound", "input:analog-stereo": "Mic", "pro-audio": "Pro Audio" })[p.name] ?? p.label
			}))
			current: Headset.profile
			onSelected: value => Headset.setProfile(value)
		}
	}

	// ── the device ─────────────────────────────────────────────────────────
	SettingCard {
		anchor: "headset-info"
		visible: root.has
		title: "This headset"
		subtitle: [`Firmware ${root.dev.firmware ?? "?"}`, root.dev.serial ?? "", root.dev.speed === "12" ? "USB full speed" : (root.dev.speed ? `USB ${root.dev.speed} Mb/s` : "")].filter(s => s).join(" · ")
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
				onActivated: Headset.refresh()
			}
		}
	}
}
