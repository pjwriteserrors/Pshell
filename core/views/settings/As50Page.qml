pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services
import qs.core.views.settings.mouse
import qs.core.views.settings.as50

// The Avantree AS50 (core/services/As50.qml): connection, battery, its own
// volume, the codec and latency, the microphone, what its buttons do, its
// sound mode (set on the headset only) and what it offers over Bluetooth.
// The drawing is the headset, live.
SettingsPage {
	id: root

	title: "Avantree AS50"
	description: ""
	recording: picker.recording

	signal open(string page)

	property string control: "play"
	property string app: ""
	// the last volume step made on the headset, for the drawing: +1 / −1
	property int nudge: 0

	onActiveChanged: {
		As50.watching = root.active;
		if (root.active) As50.refresh();
	}
	Component.onDestruction: As50.watching = false

	readonly property bool has: As50.online
	readonly property var dev: As50.device
	readonly property var tr: As50.transport ?? ({})

	property var lastRaw: null

	Connections {
		target: As50

		function onRawChanged() {
			if (root.lastRaw !== null && As50.raw !== null && As50.raw !== root.lastRaw) {
				root.nudge = As50.raw > root.lastRaw ? 1 : -1;
				unnudge.restart();
			}
			root.lastRaw = As50.raw;
		}
	}

	Timer {
		id: unnudge

		interval: 350
		onTriggered: root.nudge = 0
	}

	function codecLine(t) {
		if (!t || !t.codec) return "";
		const parts = [t.codec];
		if (t.rate) parts.push(`${t.rate / 1000} kHz`);
		if (t.channels) parts.push(t.channels === 1 ? "mono" : (t.mode || "stereo"));
		if (t.codec === "AAC" && t.bitrate) parts.push(`${t.vbr ? "VBR up to " : ""}${Math.round(t.bitrate / 1000)} kb/s`);
		if (t.codec === "SBC" && t.bitpool) parts.push(`bitpool ${t.bitpool[0]}–${t.bitpool[1]}`);
		if (t.duplex) parts.push(`mic ${t.micRate / 1000} kHz`);
		return parts.join(" · ");
	}

	// ── the headset, live ──────────────────────────────────────────────────
	SettingCard {
		anchor: "as50-device"
		title: !As50.scanned ? "Looking for the headset …" : (root.has ? As50.name : (As50.present ? `${As50.name} · not connected` : "Not paired"))
		subtitle: root.has ? [As50.battery !== null ? `Battery ${As50.battery} %` : "", root.tr.codec ?? "", As50.isOutput ? "Output" : "", As50.isInput ? "Input" : ""].filter(s => s).join(" · ")
			: (As50.present ? (As50.connecting ? "Connecting …" : "Switch it on – it connects by itself, or connect it here") : "Pair it in the Bluetooth panel: hold ⏯ for 5 s until the lamp flashes red and blue")
		icon: root.has ? "headphones" : "headphones_off"

		trailing: RowLayout {
			spacing: 6

			TextButton {
				visible: root.has && !As50.isOutput && !!As50.sink
				variant: "ghost"
				icon: "headphones"
				text: "Use"
				onActivated: {
					As50.useAsOutput();
					if (As50.source) As50.useAsInput();
				}
			}

			TextButton {
				visible: As50.present
				variant: root.has ? "ghost" : "tonal"
				icon: root.has ? "bluetooth_off" : "bluetooth_connect"
				text: root.has ? "Disconnect" : (As50.connecting ? "Connecting …" : "Connect")
				enabled: !As50.connecting
				onActivated: root.has ? As50.disconnect() : As50.connect()
			}
		}

		As50Figure {
			Layout.fillWidth: true
			Layout.preferredHeight: Math.min(270, width * 270 / 440)
			online: root.has
			volume: As50.raw !== null ? As50.raw / 127 : As50.volume
			muted: As50.muted
			level: As50.level
			micOn: As50.micOn
			micMuted: As50.micMuted
			battery: As50.battery
			keys: As50.keys
			nudge: root.nudge
			selected: root.control
			onPicked: control => root.control = control
		}

		StyledText {
			Layout.fillWidth: true
			visible: As50.error !== ""
			text: As50.error
			tone: Theme.danger
			wrapMode: Text.Wrap
		}

		StyledText {
			Layout.fillWidth: true
			visible: As50.scanned && root.dev.dbus === false
			text: "python-dbus is missing: the page cannot reach BlueZ"
			tone: Theme.danger
		}
	}

	// ── what you hear ──────────────────────────────────────────────────────
	SettingCard {
		anchor: "as50-sound"
		visible: root.has && !!As50.sink
		title: "Sound"
		subtitle: As50.raw !== null ? `On the headset: step ${Math.round(As50.raw / 127 * 16)} of 16 · ${As50.raw} / 127` : ""
		icon: "headphones"

		ValueSlider {
			from: 0
			to: 100
			step: 1
			icon: As50.muted ? "volume_off" : "volume_high"
			label: "Volume"
			format: v => `${Math.round(v)} %`
			value: As50.volume * 100
			onMoved: v => As50.setVolume(v / 100)
		}

		FlagRow {
			icon: "volume_off"
			title: "Mute"
			checked: As50.muted
			onToggled: on => As50.setMuted(on)
		}

		FlagRow {
			icon: "gesture_tap"
			title: "Show volume changes made on the headset"
			subtitle: "Its + and − set its own volume, the shell follows"
			checked: As50.option("volumeOsd", true)
			onToggled: on => As50.setOption("volumeOsd", on)
		}
	}

	// ── the codec ──────────────────────────────────────────────────────────
	SettingCard {
		anchor: "as50-codec"
		visible: root.has && As50.audioProfiles.length > 0
		title: "Codec"
		subtitle: root.codecLine(root.tr)
		icon: "tune_vertical"
		modified: As50.option("music", "") !== "" && As50.option("music", "") !== "a2dp-sink"
		onReset: As50.setMusic("a2dp-sink")

		Segmented {
			Layout.fillWidth: true
			options: As50.codecs.filter(c => As50.audioProfiles.some(p => p.name === c.profile)).map(c => ({ value: c.profile, label: c.label }))
			current: As50.micOn ? As50.musicProfile : As50.profile
			onSelected: value => As50.setMusic(value)
		}

		StyledText {
			Layout.fillWidth: true
			Layout.leftMargin: 12
			text: (As50.codecs.find(c => c.profile === (As50.micOn ? As50.musicProfile : As50.profile))?.detail ?? "")
				+ (As50.micOn ? " – used again once the microphone is off" : "") + ". Kept and set again each time it connects."
			tone: Theme.textMuted
			wrapMode: Text.Wrap
		}

		ValueSlider {
			from: 0
			to: 400
			step: 10
			icon: "timer_outline"
			label: "Lip sync"
			format: v => Math.round(v) === 0 ? "Off" : `+${Math.round(v)} ms`
			value: As50.latencyOf(As50.profile === "headset-head-unit" ? "headset-hf-output" : "headset-output")
			onMoved: v => latencyLater.go(As50.profile === "headset-head-unit" ? "headset-hf-output" : "headset-output", Math.round(v))

			Timer {
				id: latencyLater

				property string port: ""
				property int ms: 0

				function go(port, ms) {
					latencyLater.port = port;
					latencyLater.ms = ms;
					latencyLater.restart();
				}

				interval: 250
				onTriggered: As50.setLatency(latencyLater.port, latencyLater.ms)
			}
		}

		StyledText {
			Layout.fillWidth: true
			Layout.leftMargin: 12
			text: "Extra delay video players are told about, so picture and sound match. The headset reports none of its own."
			tone: Theme.textSubtle
			wrapMode: Text.Wrap
		}
	}

	// ── the microphone ─────────────────────────────────────────────────────
	SettingCard {
		anchor: "as50-mic"
		visible: root.has
		title: "Microphone"
		subtitle: As50.micOn ? (As50.profile === "headset-head-unit" ? "Call mode · 8 kHz" : "FastStream back channel · 16 kHz") : "Off – music only"
		icon: As50.micOn && !As50.micMuted ? "microphone" : "microphone_off"

		Segmented {
			Layout.fillWidth: true
			options: As50.micModes.filter(m => m.profile === "" || As50.audioProfiles.some(p => p.name === m.profile)).map(m => ({ value: m.profile, label: m.label }))
			current: As50.micOn ? As50.profile : ""
			onSelected: value => As50.setMic(value)
		}

		StyledText {
			Layout.fillWidth: true
			Layout.leftMargin: 12
			text: As50.micModes.find(m => m.profile === (As50.micOn ? As50.profile : ""))?.detail ?? ""
			tone: Theme.textMuted
			wrapMode: Text.Wrap
		}

		// the level, as the headset sends it
		Item {
			Layout.fillWidth: true
			Layout.leftMargin: 12
			Layout.rightMargin: 12
			visible: As50.micOn && !!As50.source
			implicitHeight: 10

			Rectangle {
				anchors.fill: parent
				radius: height / 2
				color: Theme.layer2
			}

			Rectangle {
				height: parent.height
				radius: height / 2
				width: parent.width * Math.max(0, Math.min(1, (As50.level + 70) / 70))
				color: As50.micMuted ? Theme.danger : Theme.primary

				Behavior on width {
					Anim {
						duration: 80
					}
				}
			}

			Rectangle {
				x: parent.width * Math.max(0, Math.min(1, (As50.peak + 70) / 70)) - 1
				width: 2
				height: parent.height
				color: Theme.text
				opacity: 0.5
			}
		}

		StyledText {
			Layout.fillWidth: true
			Layout.leftMargin: 12
			visible: As50.micOn && As50.silent && !As50.micMuted
			text: "Silence: the headset's noise suppression sends nothing while nobody speaks"
			tone: Theme.textSubtle
			wrapMode: Text.Wrap
		}

		ValueSlider {
			visible: As50.micOn && !!As50.source
			from: 0
			to: 100
			step: 1
			icon: "microphone"
			label: "Gain"
			format: v => `${Math.round(v)} %`
			value: As50.micVolume * 100
			onMoved: v => As50.setMicVolume(v / 100)
		}

		FlagRow {
			visible: As50.micOn && !!As50.source
			icon: "microphone_off"
			title: "Mute"
			checked: As50.micMuted
			onToggled: on => As50.setMicMuted(on)
		}

		RowLayout {
			Layout.fillWidth: true
			Layout.leftMargin: 12
			spacing: 12

			StyledText {
				Layout.fillWidth: true
				text: "“Microphone on / off” on a button uses"
				tone: Theme.textMuted
			}

			Segmented {
				Layout.preferredWidth: 240
				options: [{ value: "a2dp-sink-faststream_duplex", label: "Mic + music" }, { value: "headset-head-unit", label: "Call" }]
				current: As50.option("micMode", "a2dp-sink-faststream_duplex")
				onSelected: value => As50.setOption("micMode", value)
			}
		}

		FlagRow {
			visible: As50.autoswitch !== null
			icon: "swap_horizontal_variant"
			title: "Call mode while an app records"
			subtitle: "WirePlumber's own switch – for every Bluetooth headset"
			checked: As50.autoswitch === true
			onToggled: on => As50.setAutoswitch(on)
		}
	}

	// ── the buttons ────────────────────────────────────────────────────────
	SettingCard {
		anchor: "as50-buttons"
		visible: As50.present
		title: As50.controlNames[root.control] ?? "Buttons"
		icon: "gesture_tap"

		trailing: Segmented {
			Layout.preferredWidth: 260
			options: [{ value: "play", label: "⏯" }, { value: "next", label: "+ held" }, { value: "previous", label: "− held" }, { value: "redial", label: "⏯ ×2" }]
			current: root.control
			onSelected: value => root.control = value
		}

		Flow {
			Layout.fillWidth: true
			spacing: 8

			Repeater {
				model: [""].concat(As50.apps)

				delegate: Chip {
					required property string modelData

					text: modelData === "" ? "Everywhere" : modelData
					icon: modelData === "" ? "earth" : "application_outline"
					selected: root.app === modelData
					acceptedButtons: Qt.LeftButton | Qt.RightButton
					onClicked: root.app = modelData
					onRightClicked: if (modelData !== "") {
						if (root.app === modelData) root.app = "";
						As50.removeApp(modelData);
					}
				}
			}

			Chip {
				visible: As50.focusApp !== "" && !As50.apps.includes(As50.focusApp)
				text: As50.focusApp
				icon: "plus"
				onClicked: {
					As50.addApp(As50.focusApp);
					root.app = As50.focusApp;
				}
			}
		}

		BindRow {
			app: root.app
			control: root.control
			label: "Does"
			icon: root.control === "redial" ? "gesture_double_tap" : (root.control === "play" ? "gesture_tap" : "gesture_tap_hold")
			onPick: control => picker.show(control, "click", root.app)
		}

		StyledText {
			Layout.fillWidth: true
			Layout.leftMargin: 12
			visible: root.control === "redial" && !As50.option("tap", false)
			text: "The headset sends this as a redial request (AT+BLDN) over HFP, which PipeWire answers itself. To hear it, turn on reading WirePlumber's log below."
			tone: Theme.textMuted
			wrapMode: Text.Wrap
		}

		ActionPicker {
			id: picker

			store: As50
			onChosen: (action, extra) => As50.assign(picker.control, "click", picker.app, action, extra)
			onCleared: As50.assign(picker.control, "click", picker.app, null)
		}

		FlagRow {
			icon: "gesture_tap"
			title: "Buttons through the shell"
			subtitle: As50.option("buttons", true) ? "⏯, + and − held control the playing app" : "Its keys go to the focused window as media keys"
			checked: As50.option("buttons", true)
			onToggled: on => As50.setOption("buttons", on)
		}

		FlagRow {
			icon: "text_search"
			title: "Hear ⏯ pressed twice"
			subtitle: "Raises WirePlumber's log level for its Bluetooth calls part only, while the headset is connected; also tells the battery and whether it sits on the dock"
			checked: As50.option("tap", false)
			onToggled: on => As50.setOption("tap", on)
		}

		Repeater {
			model: As50.option("tap", false) ? As50.hfpLines : []

			delegate: StyledText {
				required property var modelData

				Layout.fillWidth: true
				Layout.leftMargin: 12
				text: modelData.line
				font.family: Theme.monoFamily
				tone: Theme.textSubtle
			}
		}

		StyledText {
			Layout.fillWidth: true
			Layout.leftMargin: 12
			text: "On the headset itself: + / − pressed – its volume, 16 steps · ⏯ held 5 s – pairing mode · ⏯ once after switching on – reconnect"
			tone: Theme.textSubtle
			wrapMode: Text.Wrap
		}
	}

	component BindRow: Clickable {
		id: row

		property string app: ""
		property string control: ""
		property string label: ""
		property string icon: ""
		readonly property var rule: As50.ruleFor(row.control, "click", row.app)
		readonly property var shown: As50.describe(As50.effective(row.control, "click", row.app)?.action ?? null, row.control)
		property bool lit: false

		Layout.fillWidth: true
		implicitHeight: 52
		radius: Theme.radius.large
		color: row.lit ? Theme.primaryContainer : Theme.layer2
		signal pick(string control)

		onClicked: row.pick(row.control)

		Behavior on color {
			ColorAnim {}
		}

		Connections {
			target: As50

			function onFired(rule, control, trigger) {
				if (control === row.control) {
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
				Layout.preferredWidth: 90
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
				text: row.shown.label + (!row.rule && row.app !== "" && As50.effective(row.control, "click", row.app) ? " · everywhere" : "")
				tone: row.rule ? Theme.text : Theme.textSubtle
				elide: Text.ElideRight
			}

			IconButton {
				visible: !!row.rule
				implicitWidth: 30
				implicitHeight: 30
				icon: "close"
				variant: "ghost"
				onClicked: As50.assign(row.control, "click", row.app, null)
			}

			Glyph {
				icon: "chevron_right"
				size: 16
				color: Theme.textFaint
			}
		}
	}

	// ── the sound mode, set on the headset only ───────────────────────────
	SettingCard {
		anchor: "as50-eq"
		visible: As50.present
		title: "Sound mode"
		subtitle: "Set on the headset – it tells no one over Bluetooth"
		icon: "equalizer"

		Segmented {
			Layout.fillWidth: true
			options: [{ value: "voice", label: "Clear voice" }, { value: "balanced", label: "Balanced" }]
			current: As50.option("eq", "voice")
			onSelected: value => As50.setOption("eq", value)
		}

		StyledText {
			Layout.fillWidth: true
			Layout.leftMargin: 12
			text: "Hold ⏯ and + together until it says “Balanced Mode” (again for clear voice), then pick the same here so it is noted. The headset keeps it when switched off; a reset brings clear voice back. Headsets older than batch T24D2 have only clear voice."
			tone: Theme.textMuted
			wrapMode: Text.Wrap
		}
	}

	// ── the connection ─────────────────────────────────────────────────────
	SettingCard {
		anchor: "as50-connection"
		visible: As50.present
		title: "Connection"
		subtitle: [root.dev.address ?? "", root.dev.units > 1 ? `${root.dev.units} paired` : ""].filter(s => s).join(" · ")
		icon: "bluetooth"

		RowLayout {
			Layout.fillWidth: true
			Layout.leftMargin: 12
			spacing: 12

			StyledText {
				text: "Name"
				tone: Theme.textMuted
			}

			Field {
				id: alias

				Layout.fillWidth: true
				text: root.dev.alias ?? ""
				placeholder: root.dev.name ?? "Avantree AS50"
				icon: "pencil"
				clearable: false
				onAccepted: As50.rename(alias.text || (root.dev.name ?? ""))
			}
		}

		FlagRow {
			icon: "link_variant"
			title: "Connects by itself"
			subtitle: "Trusted: it may connect whenever it is switched on"
			checked: root.dev.trusted === true
			onToggled: on => As50.setTrusted(on)
		}

		FlagRow {
			icon: "bluetooth_connect"
			title: "Take it over when it is on"
			subtitle: "Calls it every 30 s while it is not connected – from the Ensemble transmitter or a phone too"
			checked: As50.option("takeOver", false)
			onToggled: on => As50.setOption("takeOver", on)
		}

		FlagRow {
			icon: "headphones"
			title: "Use it for sound when it connects"
			checked: As50.option("output", false)
			onToggled: on => As50.setOption("output", on)
		}

		FlagRow {
			icon: "pause"
			title: "Pause when it goes away"
			subtitle: "For every pair of headphones (Media)"
			checked: Media.pauseOnHeadphones
			onToggled: on => Media.setRule("headphones", on)
		}

		ValueSlider {
			from: 0
			to: 50
			step: 10
			icon: "battery_alert"
			label: "Battery warning"
			format: v => Math.round(v) === 0 ? "Off" : `at ${Math.round(v)} %`
			value: As50.option("lowBattery", 20)
			onMoved: v => As50.setOption("lowBattery", Math.round(v))
		}

		StyledText {
			Layout.fillWidth: true
			Layout.leftMargin: 12
			visible: root.dev.hfp?.docked !== undefined
			text: root.dev.hfp?.docked ? "On the dock" : "Not on the dock"
			tone: Theme.textMuted
		}
	}

	// ── the device ─────────────────────────────────────────────────────────
	SettingCard {
		anchor: "as50-info"
		visible: As50.present
		title: "This headset"
		subtitle: [root.dev.address ?? "", root.dev.class ? `class 0x${Number(root.dev.class).toString(16)}` : "", "Bluetooth Classic only, no app channel"].filter(s => s).join(" · ")
		icon: "information_outline"

		Repeater {
			model: (root.dev.sdp ?? []).map(r => {
				const names = r.uuids.filter(u => !/^0x/.test(u)).join(", ");
				const versions = Object.entries(r.versions ?? {}).map(([k, v]) => `${k} ${v}`).join(", ");
				const where = r.channel !== undefined ? `RFCOMM ${r.channel}` : (r.psm !== undefined ? `PSM ${r.psm}` : "");
				return { names, detail: [versions, where, r.features !== null && r.features !== undefined ? `features 0x${Number(r.features).toString(16)}` : ""].filter(s => s).join(" · ") };
			})

			delegate: RowLayout {
				required property var modelData

				Layout.fillWidth: true
				Layout.leftMargin: 12
				spacing: 12

				StyledText {
					Layout.preferredWidth: 220
					text: modelData.names
					elide: Text.ElideRight
				}

				StyledText {
					Layout.fillWidth: true
					text: modelData.detail
					tone: Theme.textMuted
					elide: Text.ElideRight
				}
			}
		}

		StyledText {
			Layout.fillWidth: true
			Layout.leftMargin: 12
			visible: (root.dev.endpoints ?? []).length > 0
			text: "Codecs: " + (root.dev.endpoints ?? []).map(e => e.codec + (e.duplex ? " (both ways)" : "") + (e.bitrate ? ` ${Math.round(e.bitrate / 1000)} kb/s` : "")).join(", ")
			tone: Theme.textMuted
			wrapMode: Text.Wrap
		}

		RowLayout {
			Layout.fillWidth: true

			Item {
				Layout.fillWidth: true
			}

			TextButton {
				variant: "ghost"
				icon: "refresh"
				text: "Read again"
				enabled: root.has
				onActivated: As50.refresh()
			}
		}
	}
}
