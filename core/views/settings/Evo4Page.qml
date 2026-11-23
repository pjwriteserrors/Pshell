pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// The Audient EVO4 (core/services/Evo4.qml): the two inputs (gain, 48V,
// mute, stereo link), the output (volume, mute, link), the loopback mix
// and the device. Gain, volume and output mute are the knobs' (ALSA); the
// rest goes in a session that takes the card away for half a second.
SettingsPage {
	id: root

	title: "Audient EVO4"
	description: ""

	onActiveChanged: {
		Evo4.watching = root.active;
		if (root.active) Evo4.refresh();
	}
	Component.onDestruction: Evo4.watching = false

	readonly property bool has: Evo4.online && !Evo4.stuck
	readonly property var dev: Evo4.device
	readonly property var knobs: Evo4.knobs
	readonly property bool live: root.has && root.knobs.gain !== undefined
	// the loopback sliders: −60 dB and below is off
	readonly property real floor: -60

	function db(v) {
		if (v === null || v === undefined) return "";
		return `${v > 0 ? "+" : ""}${Number(v).toFixed(1)} dB`;
	}

	// ── the device ─────────────────────────────────────────────────────────
	SettingCard {
		anchor: "evo4-device"
		title: !Evo4.scanned ? "Looking for the EVO4 …" : (Evo4.online ? "Audient EVO4" : "Not connected")
		subtitle: !Evo4.online ? "" : [
			Evo4.busy ? "Writing …" : "",
			root.dev.streaming ? "In use" : "",
			Evo4.hw?.rate ? `${Evo4.hw.rate / 1000} kHz` : "",
			Evo4.hw && Evo4.hw.clockValid === false ? "Clock not locked" : ""
		].filter(s => s).join(" · ")
		icon: Evo4.online ? "tune_vertical" : "usb"

		trailing: TextButton {
			visible: root.has
			variant: "ghost"
			icon: "refresh"
			text: "Read"
			enabled: !Evo4.busy
			onActivated: Evo4.read()
		}

		StyledText {
			Layout.fillWidth: true
			visible: Evo4.stuck
			text: "The EVO4 stopped answering: unplug it and plug it in again"
			tone: Theme.danger
			wrapMode: Text.Wrap
		}

		StyledText {
			Layout.fillWidth: true
			visible: Evo4.error !== "" && !Evo4.stuck
			text: Evo4.error
			tone: Theme.danger
			wrapMode: Text.Wrap
		}

		StyledText {
			Layout.fillWidth: true
			visible: Evo4.online && root.dev.access === false
			text: `No access to ${root.dev.port ?? "the device"}: see docs/evo4.md`
			tone: Theme.danger
			wrapMode: Text.Wrap
		}
	}

	// ── the inputs ─────────────────────────────────────────────────────────
	SettingCard {
		anchor: "evo4-inputs"
		visible: root.has
		title: "Inputs"
		icon: "microphone"

		Repeater {
			model: 2

			ColumnLayout {
				id: input

				required property int index

				Layout.fillWidth: true
				spacing: 2

				SectionLabel {
					text: input.index === 0 ? "Input 1 · Mic / Line / Instrument" : "Input 2 · Mic / Line"
				}

				ValueSlider {
					visible: root.live
					from: -8
					to: 50
					step: 0.5
					icon: "tune"
					label: "Gain"
					format: v => root.db(v)
					value: root.knobs.gain?.[input.index] ?? 0
					onMoved: v => Evo4.setGain(input.index, v)
				}

				FlagRow {
					icon: "flash"
					title: "48V phantom power"
					checked: Evo4.value("phantom", input.index) === true
					onToggled: on => Evo4.set("phantom", on, input.index)
				}

				FlagRow {
					icon: "microphone_off"
					title: "Mute"
					checked: Evo4.value("mute", input.index) === true
					onToggled: on => Evo4.set("mute", on, input.index)
				}
			}
		}

		FlagRow {
			icon: "link_variant"
			title: "Stereo pair"
			checked: Evo4.value("inputLink") === true
			onToggled: on => Evo4.set("inputLink", on)
		}
	}

	// ── the output ─────────────────────────────────────────────────────────
	SettingCard {
		anchor: "evo4-output"
		visible: root.has
		title: "Output"
		icon: "headphones"

		ValueSlider {
			visible: root.live
			from: -96
			to: 0
			step: 0.5
			icon: root.knobs.outMute ? "volume_off" : "volume_high"
			label: "Volume"
			format: v => root.db(v)
			value: Math.max(-96, root.knobs.volume ?? -96)
			onMoved: v => Evo4.setVolume(v)
		}

		FlagRow {
			visible: root.live && root.knobs.outMute !== undefined && root.knobs.outMute !== null
			icon: "volume_off"
			title: "Mute"
			checked: root.knobs.outMute === true
			onToggled: on => Evo4.setOutMute(on)
		}

		FlagRow {
			icon: "link_variant"
			title: "Stereo link"
			checked: Evo4.value("outputLink") === true
			onToggled: on => Evo4.set("outputLink", on)
		}
	}

	// ── the loopback mix ───────────────────────────────────────────────────
	SettingCard {
		anchor: "evo4-loopback"
		visible: root.has
		title: "Loopback"
		subtitle: "Recorded on inputs 3 and 4"
		icon: "repeat"
		modified: JSON.stringify(Evo4.value("loopback") ?? []) !== JSON.stringify([0, null, null, null, null, null, null, null, null, null, null, null])
		onReset: {
			const plain = [0, null, null, null, null, null, null, null, null, null, null, null];
			for (let k = 0; k < 12; k++) Evo4.set("loopback", plain[k], k);
		}

		Repeater {
			model: Evo4.sources

			RowLayout {
				id: source

				required property var modelData
				required property int index

				Layout.fillWidth: true
				spacing: 8

				StyledText {
					Layout.preferredWidth: 150
					Layout.leftMargin: 12
					text: source.modelData.label
					elide: Text.ElideRight
				}

				Repeater {
					model: 2

					ValueSlider {
						id: point

						required property int index

						Layout.fillWidth: true
						from: root.floor
						to: 0
						step: 0.5
						label: point.index === 0 ? "L" : "R"
						format: v => v <= root.floor ? "Off" : root.db(v)
						value: Evo4.mix(source.index, point.index) ?? root.floor
						onMoved: v => Evo4.setMix(source.index, point.index, v <= root.floor ? null : v)
					}
				}
			}
		}
	}

	// ── this one ───────────────────────────────────────────────────────────
	SettingCard {
		anchor: "evo4-about"
		visible: Evo4.online
		title: "This EVO4"
		subtitle: [`Firmware ${root.dev.firmware ?? "?"}`, root.dev.speed ? `USB ${root.dev.speed} Mb/s` : "", root.dev.port ? `Port ${root.dev.port}` : "",
			root.dev.card !== null && root.dev.card !== undefined ? `ALSA card ${root.dev.card}` : ""].filter(s => s).join(" · ")
		icon: "information_outline"
	}
}
