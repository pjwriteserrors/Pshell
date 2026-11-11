pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services
import qs.core.views.settings.btadapter

// The Bluetooth adapter (core/services/BtAdapter.qml), made on the Intel
// AX201: the radio and its links, what the controller can be set to through
// the kernel (mgmt, HCI, debugfs), what bluetoothd reads from its files, the
// driver's power and parameters, and what the chip says about itself.
SettingsPage {
	id: root

	title: "Bluetooth adapter"
	description: ""

	signal open(string page)

	readonly property bool has: BtAdapter.present
	readonly property bool rooted: BtAdapter.hasRoot
	readonly property var ad: BtAdapter.adapter ?? ({})
	readonly property var st: BtAdapter.staticInfo ?? ({})
	readonly property var sys: BtAdapter.sysconfig

	onActiveChanged: BtAdapter.watching = root.active
	Component.onDestruction: BtAdapter.watching = false

	// ── small pieces ───────────────────────────────────────────────────────
	component Info: RowLayout {
		id: info

		property string label: ""
		property string value: ""

		Layout.fillWidth: true
		Layout.leftMargin: 12
		visible: info.value !== ""
		spacing: 18

		StyledText {
			Layout.preferredWidth: 150
			text: info.label
			tone: Theme.textMuted
		}

		StyledText {
			Layout.fillWidth: true
			text: info.value
			wrapMode: Text.Wrap
		}
	}

	component Choice: RowLayout {
		id: choice

		property string icon: ""
		property string title: ""
		property var options: []
		property string current: ""
		signal picked(string value)

		Layout.fillWidth: true
		Layout.leftMargin: 12
		spacing: 12

		Glyph {
			visible: choice.icon !== ""
			icon: choice.icon
			color: Theme.textMuted
		}

		StyledText {
			Layout.fillWidth: true
			text: choice.title
			elide: Text.ElideRight
		}

		Segmented {
			Layout.preferredWidth: Math.min(420, 92 * choice.options.length)
			options: choice.options
			current: choice.current
			onSelected: value => choice.picked(value)
		}
	}

	component Group: SectionLabel {
		Layout.topMargin: 10
		Layout.leftMargin: 12
	}

	component Chips: Flow {
		id: chips

		property var options: [] // [{ value, label, on, enabled }]
		signal clicked(var value)

		Layout.fillWidth: true
		Layout.leftMargin: 12
		spacing: 6

		Repeater {
			model: chips.options

			Chip {
				required property var modelData

				text: modelData.label
				selected: modelData.on === true
				enabled: modelData.enabled !== false
				opacity: enabled ? 1 : 0.5
				onClicked: chips.clicked(modelData.value)
			}
		}
	}

	// a value of BlueZ's files: bool, choice or number, with its default
	component ConfRow: ColumnLayout {
		id: row

		property string file: "main.conf"
		property string section: "General"
		property string key: ""
		property string title: ""
		property string icon: "cog_outline"
		property string kind: "bool"     // bool | int01 | choice | int
		property var options: []
		property var fallback: null
		property real from: 0
		property real to: 100
		property real step: 1
		property string unit: ""
		property var format: null
		property bool live: false
		readonly property var stored: (BtAdapter.conf[row.file] ?? {})[`${row.section}.${row.key}`]
		readonly property var value: row.stored === undefined ? row.fallback : row.stored
		readonly property bool changed: row.stored !== undefined

		Layout.fillWidth: true
		spacing: 0

		function put(v) {
			BtAdapter.setConf(row.file, row.section, row.key, v === row.fallback ? null : v, row.live);
		}

		FlagRow {
			Layout.fillWidth: true
			visible: row.kind === "bool" || row.kind === "int01"
			icon: row.icon
			title: row.title
			modified: row.changed
			checked: row.kind === "int01" ? String(row.value) === "1" : String(row.value) === "true"
			onToggled: on => row.put(row.kind === "int01" ? (on ? "1" : "0") : (on ? "true" : "false"))
			onReset: BtAdapter.setConf(row.file, row.section, row.key, null, row.live)
		}

		Choice {
			visible: row.kind === "choice"
			icon: row.icon
			title: row.title
			options: row.options
			current: String(row.value)
			onPicked: v => row.put(v)
		}

		ValueSlider {
			id: slider0

			Layout.fillWidth: true
			visible: row.kind === "int"
			icon: row.icon
			label: row.title
			from: row.from
			to: row.to
			step: row.step
			value: Number(row.value)
			format: row.format ?? (v => `${Math.round(v)}${row.unit}`)
			onMoved: v => later.restart()

			Timer {
				id: later

				interval: 700
				onTriggered: row.put(String(Math.round(slider0.value)))
			}
		}
	}

	// one value of the default system configuration (mgmt), in time units
	component Timing: ValueSlider {
		id: timing

		property string key: ""
		property real unit: 0.625       // ms per controller unit
		property int lo: 0
		property int hi: 0xFFFF
		property int fallback: 0
		property bool log: true
		readonly property real raw: BtAdapter.sysconfig[timing.key] ?? timing.fallback

		function toPos(v) {
			if (!timing.log) return v;
			return Math.log(Math.max(timing.lo, v) / timing.lo) / Math.log(timing.hi / timing.lo) * 1000;
		}
		function fromPos(p) {
			if (!timing.log) return Math.round(p);
			return Math.round(timing.lo * Math.pow(timing.hi / timing.lo, p / 1000));
		}
		function ms(v) {
			const t = v * timing.unit;
			if (t >= 1000) return `${(t / 1000).toFixed(t >= 10000 ? 1 : 2)} s`;
			return `${t >= 100 ? Math.round(t) : t.toFixed(t < 10 ? 2 : 1)} ms`;
		}

		Layout.fillWidth: true
		visible: BtAdapter.sysconfig[timing.key] !== undefined
		enabled: root.rooted
		opacity: root.rooted ? 1 : 0.55
		from: timing.log ? 0 : timing.lo
		to: timing.log ? 1000 : timing.hi
		step: 1
		value: timing.raw === 0 ? timing.from : timing.toPos(timing.raw)
		format: p => timing.raw === 0 && !timing.dragging ? "Controller's" : timing.ms(timing.fromPos(p))
		onMoved: p => pending.restart()

		Timer {
			id: pending

			interval: 600
			onTriggered: BtAdapter.setTiming(timing.key, timing.fromPos(timing.value))
		}
	}

	// ── the adapter ────────────────────────────────────────────────────────
	SettingCard {
		anchor: "btadapter-device"
		title: !BtAdapter.scanned ? "Looking for the adapter …" : (root.has ? (root.ad.Alias || "Bluetooth adapter") : "No adapter")
		subtitle: root.has ? [st.version?.manufacturer ? `${st.version.manufacturer} AX201` : "Intel AX201", BtAdapter.info?.version ? `Bluetooth ${({ 9: "5.0", 10: "5.1", 11: "5.2", 12: "5.3", 13: "5.4" })[BtAdapter.info.version] ?? BtAdapter.info.version}` : "", BtAdapter.info?.address ?? root.ad.Address ?? ""].filter(s => s).join(" · ") : ""
		icon: !root.has || BtAdapter.blocked ? "bluetooth_off" : (BtAdapter.links.length ? "bluetooth_connect" : "bluetooth")

		trailing: Toggle {
			visible: root.has
			checked: BtAdapter.powered
			onToggled: on => BtAdapter.setAdapter("Powered", on)
		}

		RowLayout {
			Layout.fillWidth: true
			Layout.leftMargin: 12
			visible: BtAdapter.scanned && BtAdapter.helper !== "ready"
			spacing: 12

			Glyph {
				icon: "shield_key"
				color: Theme.warning
			}

			StyledText {
				Layout.fillWidth: true
				text: BtAdapter.helper === "outdated" ? "Root helper is out of date" : (BtAdapter.helper === "denied" ? "Root helper was not allowed" : "Root helper not installed")
				wrapMode: Text.Wrap
			}

			TextButton {
				variant: "filled"
				icon: "shield_key"
				text: BtAdapter.helper === "outdated" ? "Update" : "Install"
				onActivated: BtAdapter.installHelper("install")
			}
		}

		RowLayout {
			Layout.fillWidth: true
			Layout.leftMargin: 12
			visible: root.has
			spacing: 12

			Glyph {
				icon: "pencil_outline"
				color: Theme.textMuted
			}

			Field {
				id: nameField

				Layout.fillWidth: true
				placeholder: "Name"
				Component.onCompleted: text = root.ad.Alias ?? ""
				onAccepted: if (text.trim()) BtAdapter.setAdapter("Alias", text.trim())

				Connections {
					target: root

					function onAdChanged() {
						if (!nameField.focused) nameField.text = root.ad.Alias ?? "";
					}
				}
			}
		}

		FlagRow {
			visible: root.has
			icon: "eye"
			title: "Visible to others"
			checked: !!root.ad.Discoverable
			onToggled: on => BtAdapter.setAdapter("Discoverable", on)
		}

		ValueSlider {
			Layout.fillWidth: true
			visible: root.has
			icon: "timer_outline"
			label: "Visible for"
			from: 0
			to: 600
			step: 30
			value: root.ad.DiscoverableTimeout ?? 180
			format: v => v < 1 ? "Always" : `${Math.round(v / 60 * 10) / 10} min`
			onMoved: v => BtAdapter.setAdapter("DiscoverableTimeout", Math.round(v))
		}

		FlagRow {
			visible: root.has
			icon: "link_variant"
			title: "Pairable"
			checked: !!root.ad.Pairable
			onToggled: on => BtAdapter.setAdapter("Pairable", on)
		}

		ValueSlider {
			Layout.fillWidth: true
			visible: root.has
			icon: "timer_outline"
			label: "Pairable for"
			from: 0
			to: 600
			step: 30
			value: root.ad.PairableTimeout ?? 0
			format: v => v < 1 ? "Always" : `${Math.round(v / 60 * 10) / 10} min`
			onMoved: v => BtAdapter.setAdapter("PairableTimeout", Math.round(v))
		}

		FlagRow {
			visible: root.has && root.ad.Connectable !== undefined
			icon: "lan_connect"
			title: "Accept connections"
			checked: !!root.ad.Connectable
			onToggled: on => BtAdapter.setAdapter("Connectable", on)
		}

		FlagRow {
			visible: root.has
			icon: "power"
			title: "Radio switched off (rfkill)"
			subtitle: BtAdapter.state.rfkill?.hard ? "Hardware switch" : ""
			checked: BtAdapter.blocked
			onToggled: on => BtAdapter.setBlocked(on)
		}

		StyledText {
			Layout.fillWidth: true
			Layout.leftMargin: 12
			visible: BtAdapter.error !== ""
			text: BtAdapter.error
			tone: Theme.danger
			wrapMode: Text.WordWrap
		}
	}

	// ── links ──────────────────────────────────────────────────────────────
	SettingCard {
		anchor: "btadapter-links"
		visible: root.has
		title: "Connections"
		subtitle: BtAdapter.dev ? `${BtAdapter.links.length} open · received ${Format.bytes(BtAdapter.dev.stats.bytesRx)} · sent ${Format.bytes(BtAdapter.dev.stats.bytesTx)}${BtAdapter.dev.stats.errRx + BtAdapter.dev.stats.errTx ? ` · ${BtAdapter.dev.stats.errRx + BtAdapter.dev.stats.errTx} errors` : ""}` : ""
		icon: "bluetooth_transfer"

		Repeater {
			model: BtAdapter.links

			ColumnLayout {
				id: link

				required property var modelData
				readonly property var device: BtAdapter.devices.find(d => d.address === link.modelData.address) ?? null
				readonly property var radio: link.modelData.radio ?? {}

				Layout.fillWidth: true
				Layout.leftMargin: 12
				spacing: 6

				RowLayout {
					Layout.fillWidth: true
					spacing: 10

					Glyph {
						icon: Bluetooth.deviceIcon(link.device?.name ?? "", link.device?.icon ?? "")
						color: Theme.primary
					}

					ColumnLayout {
						Layout.fillWidth: true
						spacing: 1

						StyledText {
							text: link.device?.name || link.modelData.address
							font.weight: Font.DemiBold
						}

						StyledText {
							Layout.fillWidth: true
							text: [link.modelData.link === "LE" ? "LE" : "Classic", link.radio.role ?? (link.modelData.central ? "central" : "peripheral"),
								link.radio.phy ? `PHY ${link.radio.phy.tx}/${link.radio.phy.rx}` : "",
								link.modelData.encrypted ? `encrypted${link.radio.keySize ? ` (${link.radio.keySize * 8} bit)` : ""}` : "not encrypted",
								link.radio.supervisionTimeout ? `drops after ${Math.round(link.radio.supervisionTimeout * 0.625)} ms` : "",
								link.radio.linkPolicy ? link.radio.linkPolicy.join(", ") : ""].filter(s => s).join(" · ")
							tone: Theme.textMuted
							wrapMode: Text.Wrap
						}
					}

					StyledText {
						text: [link.modelData.rssi !== null && link.modelData.rssi !== undefined ? `${link.modelData.rssi} dBm` : "",
							link.radio.quality !== undefined ? `${Math.round(link.radio.quality / 2.55)} %` : "",
							link.modelData.tx !== null && link.modelData.tx !== undefined ? `TX ${link.modelData.tx}/${link.modelData.txMax} dBm` : ""].filter(s => s).join("  ")
						tabular: true
						tone: Theme.textMuted
					}

					TextButton {
						visible: link.device !== null
						variant: "ghost"
						icon: "lan_disconnect"
						text: "Disconnect"
						onActivated: BtAdapter.disconnect(link.device.path)
					}
				}

				ChannelMap {
					Layout.fillWidth: true
					visible: !!link.radio.afh
					used: link.radio.afh?.map ?? ""
					avoid: BtAdapter.kept.afh?.avoid ?? []
					wifi: BtAdapter.wifi
				}
			}
		}

		StyledText {
			Layout.leftMargin: 12
			visible: BtAdapter.links.length === 0
			text: root.rooted ? "Nothing connected" : ""
			tone: Theme.textMuted
		}

		Group {
			visible: BtAdapter.devices.length > 0
			text: "Paired"
		}

		Repeater {
			model: BtAdapter.devices

			RowLayout {
				id: paired

				required property var modelData
				readonly property var flags: BtAdapter.rootState.deviceFlags?.[paired.modelData.address] ?? null

				Layout.fillWidth: true
				Layout.leftMargin: 12
				spacing: 10

				Glyph {
					icon: Bluetooth.deviceIcon(paired.modelData.name, paired.modelData.icon)
					color: paired.modelData.connected ? Theme.primary : Theme.textMuted
				}

				ColumnLayout {
					Layout.fillWidth: true
					spacing: 1

					StyledText {
						Layout.fillWidth: true
						text: paired.modelData.name || paired.modelData.address
						elide: Text.ElideRight
					}

					StyledText {
						Layout.fillWidth: true
						text: [paired.modelData.address, paired.modelData.addressType === "random" ? "random address" : "",
							paired.modelData.legacyPairing ? "legacy pairing" : "", paired.flags?.current?.includes("device-privacy") ? "device privacy" : ""].filter(s => s).join(" · ")
						tone: Theme.textSubtle
						font.pixelSize: Theme.size.small
						elide: Text.ElideRight
					}
				}

				Chip {
					visible: paired.modelData.wakeAllowed !== null
					icon: "power_sleep"
					text: "Wakes the PC"
					selected: paired.modelData.wakeAllowed === true
					onClicked: BtAdapter.setDevice(paired.modelData.path, "WakeAllowed", !paired.modelData.wakeAllowed)
				}

				Chip {
					icon: "check"
					text: "Trusted"
					selected: paired.modelData.trusted
					onClicked: BtAdapter.setDevice(paired.modelData.path, "Trusted", !paired.modelData.trusted)
				}

				Chip {
					icon: "close"
					text: "Blocked"
					selected: paired.modelData.blocked
					accent: Theme.danger
					onClicked: BtAdapter.setDevice(paired.modelData.path, "Blocked", !paired.modelData.blocked)
				}
			}
		}
	}

	// ── the radio ──────────────────────────────────────────────────────────
	SettingCard {
		anchor: "btadapter-radio"
		visible: root.has
		title: "Radio"
		icon: "antenna"
		enabled: root.rooted
		opacity: root.rooted ? 1 : 0.55

		Group {
			text: "Packets and PHYs"
		}

		Chips {
			id: phyChips

			readonly property var labels: ({ BR1M1SLOT: "BR 1-slot", BR1M3SLOT: "BR 3-slot", BR1M5SLOT: "BR 5-slot", EDR2M1SLOT: "EDR 2M 1-slot", EDR2M3SLOT: "EDR 2M 3-slot", EDR2M5SLOT: "EDR 2M 5-slot", EDR3M1SLOT: "EDR 3M 1-slot", EDR3M3SLOT: "EDR 3M 3-slot", EDR3M5SLOT: "EDR 3M 5-slot", LE1MTX: "LE 1M send", LE1MRX: "LE 1M receive", LE2MTX: "LE 2M send", LE2MRX: "LE 2M receive", LECODEDTX: "LE Coded send", LECODEDRX: "LE Coded receive" })

			options: (BtAdapter.phy?.supported ?? []).map(p => ({ value: p, label: phyChips.labels[p] ?? p, on: BtAdapter.phy.selected.includes(p), enabled: BtAdapter.phy.configurable.includes(p) }))
			onClicked: p => {
				const sel = BtAdapter.phy.selected.slice();
				const i = sel.indexOf(p);
				if (i >= 0) sel.splice(i, 1);
				else sel.push(p);
				BtAdapter.setPhy(sel);
			}
		}

		Group {
			text: "Channels"
		}

		ChannelMap {
			id: hostMap

			Layout.fillWidth: true
			Layout.leftMargin: 12
			Layout.rightMargin: 12
			editable: true
			avoid: BtAdapter.kept.afh?.avoid ?? []
			wifi: BtAdapter.wifi
			onChanged: set => root.applyAvoid(set)
		}

		RowLayout {
			Layout.fillWidth: true
			Layout.leftMargin: 12
			spacing: 8

			StyledText {
				Layout.fillWidth: true
				text: BtAdapter.wifi ? `Wi-Fi on channel ${BtAdapter.wifi.channel} (${BtAdapter.wifi.freq} MHz, ${BtAdapter.wifi.width} MHz wide)` : "No Wi-Fi in 2.4 GHz"
				tone: Theme.textMuted
			}

			TextButton {
				visible: BtAdapter.wifi !== null
				variant: "ghost"
				icon: "wifi"
				text: "Keep off the Wi-Fi"
				onActivated: {
					const half = (BtAdapter.wifi.width || 20) / 2 + 1;
					const set = [];
					for (let k = 0; k < 79; k++) {
						const f = 2402 + k;
						if (f >= BtAdapter.wifi.freq - half && f <= BtAdapter.wifi.freq + half) set.push(k);
					}
					root.applyAvoid(set);
				}
			}

			TextButton {
				visible: (BtAdapter.kept.afh?.avoid ?? []).length > 0
				variant: "ghost"
				icon: "restart"
				text: "All channels"
				onActivated: root.applyAvoid([])
			}
		}

		FlagRow {
			icon: "radar"
			title: "Channel assessment by the controller"
			checked: BtAdapter.kept.afh?.assessment ?? (root.st.baseband?.afhAssessment ?? true)
			onToggled: on => BtAdapter.setAfh({ assessment: on })
		}

		FlagRow {
			icon: "wifi"
			title: "Wi-Fi coexistence"
			subtitle: BtAdapter.modprobe["iwlwifi.bt_coex_active"] !== undefined && BtAdapter.modprobe["iwlwifi.bt_coex_active"] !== BtAdapter.params["iwlwifi.bt_coex_active"] ? "From the next start" : ""
			checked: BtAdapter.modprobe["iwlwifi.bt_coex_active"] ?? BtAdapter.params["iwlwifi.bt_coex_active"] ?? true
			onToggled: on => BtAdapter.setModule("iwlwifi.bt_coex_active", on ? null : false)
		}

		Group {
			text: "Link policy"
		}

		Chips {
			id: policyChips

			readonly property var policy: BtAdapter.kept.link?.policy ?? BtAdapter.dev?.linkPolicy ?? []
			// only what the controller can do (LMP features; the AX201 has no hold or park)
			readonly property var can: root.st.features?.page0 ?? []
			options: [["role-switch", "Role switch", "Role switch"], ["hold", "Hold", "Hold mode"], ["sniff", "Sniff", "Sniff mode"], ["park", "Park", "Park state"]]
				.filter(p => policyChips.can.length === 0 || policyChips.can.includes(p[2]))
				.map(p => ({ value: p[0], label: p[1], on: policyChips.policy.includes(p[0]) }))
			onClicked: v => BtAdapter.setLink({ policy: policyChips.policy.includes(v) ? policyChips.policy.filter(x => x !== v) : policyChips.policy.concat([v]) })
		}

		FlagRow {
			icon: "swap_horizontal_variant"
			title: "Take the central role when others connect"
			checked: (BtAdapter.dev?.linkMode ?? []).includes("central")
			onToggled: on => BtAdapter.setLink({ central: on })
		}
	}

	function applyAvoid(set) {
		const classic = [];
		for (let b = 0; b < 10; b++) {
			let byte = 0;
			for (let i = 0; i < 8; i++) {
				const k = b * 8 + i;
				if (k < 79 && !set.includes(k)) byte |= 1 << i;
			}
			classic.push(byte);
		}
		// LE data channels: 0–10 at 2404–2424 MHz, 11–36 at 2428–2478 MHz
		const le = [0, 0, 0, 0, 0];
		for (let c = 0; c < 37; c++) {
			const f = c <= 10 ? 2404 + 2 * c : 2428 + 2 * (c - 11);
			const bad = set.includes(f - 2402) || set.includes(f - 2403) || set.includes(f - 2401);
			if (!bad) le[Math.floor(c / 8)] |= 1 << (c % 8);
		}
		const hex = bytes => bytes.map(b => b.toString(16).padStart(2, "0")).join("");
		const free = 79 - set.length;
		if (free < 20) {
			BtAdapter.error = "At least 20 channels have to stay free";
			return;
		}
		BtAdapter.setAfh({ classic: hex(classic), le: hex(le), avoid: set.length ? set : null });
	}

	// ── modes ──────────────────────────────────────────────────────────────
	SettingCard {
		anchor: "btadapter-modes"
		visible: root.has
		title: "Modes"
		icon: "tune"
		enabled: root.rooted
		opacity: root.rooted ? 1 : 0.55

		Choice {
			icon: "bluetooth"
			title: "Transport"
			options: [{ value: "dual", label: "Both" }, { value: "bredr", label: "Classic" }, { value: "le", label: "LE" }]
			current: BtAdapter.has("br/edr") && BtAdapter.has("le") ? "dual" : (BtAdapter.has("le") ? "le" : "bredr")
			onPicked: v => {
				if (v !== "le") BtAdapter.ask("setting", { name: "br/edr", value: 1 }, "setting-br/edr");
				if (v !== "bredr") BtAdapter.ask("setting", { name: "le", value: 1 }, "setting-le");
				if (v === "le") BtAdapter.ask("setting", { name: "br/edr", value: 0 }, "setting-br/edr");
				if (v === "bredr") BtAdapter.ask("setting", { name: "le", value: 0 }, "setting-le");
				BtAdapter.setConf("main.conf", "General", "ControllerMode", v === "dual" ? null : v, true);
			}
		}

		FlagRow {
			icon: "lan_connect"
			title: "Fast connectable"
			checked: BtAdapter.has("fast-connectable")
			onToggled: on => {
				BtAdapter.ask("setting", { name: "fast-connectable", value: on ? 1 : 0 }, "setting-fast-connectable");
				BtAdapter.setConf("main.conf", "General", "FastConnectable", on ? "true" : null, true);
			}
		}

		Choice {
			icon: "lock"
			title: "Secure Connections"
			options: [{ value: "off", label: "Off" }, { value: "on", label: "On" }, { value: "only", label: "Only" }]
			current: BtAdapter.mainConf["General.SecureConnections"] ?? (BtAdapter.debugfs.sc_only_mode === "Y" ? "only" : (BtAdapter.has("secure-conn") ? "on" : "off"))
			onPicked: v => {
				BtAdapter.ask("setting", { name: "secure-conn", value: ({ off: 0, on: 1, only: 2 })[v] }, "setting-secure-conn");
				BtAdapter.setConf("main.conf", "General", "SecureConnections", v === "on" ? null : v, true);
			}
		}

		FlagRow {
			icon: "key_outline"
			title: "Secure Simple Pairing"
			checked: BtAdapter.has("ssp")
			onToggled: on => BtAdapter.setSetting("ssp", on ? 1 : 0)
		}

		FlagRow {
			icon: "shield_key"
			title: "Link-level security (mode 3)"
			checked: BtAdapter.has("link-security")
			onToggled: on => BtAdapter.setSetting("link-security", on ? 1 : 0)
		}

		FlagRow {
			icon: "microphone"
			title: "Wide band speech"
			checked: BtAdapter.has("wide-band-speech")
			onToggled: on => BtAdapter.setSetting("wide-band-speech", on ? 1 : 0)
		}

		Choice {
			icon: "eye_off"
			title: "Privacy"
			options: [{ value: "off", label: "Off" }, { value: "network", label: "Network" }, { value: "device", label: "Device" }, { value: "limited-network", label: "Lim. net." }, { value: "limited-device", label: "Lim. dev." }]
			current: BtAdapter.mainConf["General.Privacy"] ?? "off"
			onPicked: v => BtAdapter.setConf("main.conf", "General", "Privacy", v === "off" ? null : v, false)
		}

		ValueSlider {
			id: slider1

			Layout.fillWidth: true
			icon: "timer_outline"
			label: "New random address every"
			from: 60
			to: 3600
			step: 60
			value: BtAdapter.debugfs.rpa_timeout ?? 900
			format: v => `${Math.round(v / 60)} min`
			onMoved: v => rpaLater.restart()

			Timer {
				id: rpaLater

				interval: 700
				onTriggered: BtAdapter.setDebug("rpa_timeout", Math.round(slider1.value))
			}
		}

		Choice {
			icon: "bug_outline"
			title: "Debug keys"
			options: [{ value: "0", label: "Off" }, { value: "1", label: "Keep" }, { value: "2", label: "Use" }]
			current: BtAdapter.debugfs.ssp_debug_mode === "Y" ? "2" : (BtAdapter.has("debug-keys") ? "1" : "0")
			onPicked: v => {
				BtAdapter.setSetting("debug-keys", Number(v));
				BtAdapter.setConf("main.conf", "General", "DebugKeys", v === "0" ? null : "true", true);
			}
		}
	}

	// ── identity ───────────────────────────────────────────────────────────
	SettingCard {
		anchor: "btadapter-identity"
		visible: root.has
		title: "Identity"
		icon: "card_account_details_outline"
		enabled: root.rooted
		opacity: root.rooted ? 1 : 0.55

		RowLayout {
			Layout.fillWidth: true
			Layout.leftMargin: 12
			spacing: 10

			StyledText {
				Layout.preferredWidth: 150
				text: "Address"
			}

			Field {
				id: publicField

				Layout.fillWidth: true
				placeholder: BtAdapter.factoryAddress
				Component.onCompleted: text = BtAdapter.info?.address ?? ""
				onAccepted: if (/^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$/.test(text.trim())) BtAdapter.setAddress("public", text.trim())
			}

			TextButton {
				visible: !!BtAdapter.factoryAddress && (BtAdapter.info?.address ?? "") !== BtAdapter.factoryAddress
				variant: "ghost"
				icon: "restart"
				text: "Factory"
				onActivated: {
					publicField.text = BtAdapter.factoryAddress;
					BtAdapter.setAddress("public", BtAdapter.factoryAddress);
				}
			}

			Spinner {
				visible: BtAdapter.isBusy("address-public")
				Layout.preferredWidth: 20
				Layout.preferredHeight: 20
			}
		}

		RowLayout {
			Layout.fillWidth: true
			Layout.leftMargin: 12
			spacing: 10

			StyledText {
				Layout.preferredWidth: 150
				text: "LE static address"
			}

			Field {
				id: staticField

				Layout.fillWidth: true
				placeholder: "None"
				Component.onCompleted: text = (BtAdapter.debugfs.static_address ?? "") === "00:00:00:00:00:00" ? "" : (BtAdapter.debugfs.static_address ?? "")
				onAccepted: BtAdapter.setAddress("static", text.trim() || "00:00:00:00:00:00")
			}

			TextButton {
				variant: "ghost"
				icon: "sync"
				text: "New"
				onActivated: {
					const b = [];
					for (let i = 0; i < 6; i++) b.push(Math.floor(Math.random() * 256));
					b[0] |= 0xC0;
					staticField.text = b.map(x => x.toString(16).padStart(2, "0").toUpperCase()).join(":");
					BtAdapter.setAddress("static", staticField.text);
				}
			}
		}

		Group {
			text: "Device class"
		}

		Chips {
			id: majorChips

			readonly property int cls: parseInt(BtAdapter.info?.class ?? "0", 16) || 0
			readonly property int major: (majorChips.cls >> 8) & 0x1F
			options: [[1, "Computer"], [2, "Phone"], [3, "Network"], [4, "Audio/Video"], [5, "Peripheral"], [6, "Imaging"], [7, "Wearable"], [8, "Toy"], [9, "Health"], [0, "Miscellaneous"], [31, "Uncategorized"]].map(m => ({ value: m[0], label: m[1], on: majorChips.major === m[0] }))
			onClicked: v => BtAdapter.ask("class", { major: v, minor: 0 }, "class")
		}

		Chips {
			id: minorChips

			readonly property int cls: parseInt(BtAdapter.info?.class ?? "0", 16) || 0
			readonly property int minor: (minorChips.cls >> 2) & 0x3F
			visible: ((minorChips.cls >> 8) & 0x1F) === 1
			options: [[0, "Unspecified"], [1, "Desktop"], [2, "Server"], [3, "Laptop"], [4, "Handheld"], [5, "Palm"], [6, "Wearable"], [7, "Tablet"]].map(m => ({ value: m[0], label: m[1], on: minorChips.minor === m[0] }))
			onClicked: v => BtAdapter.ask("class", { major: 1, minor: v }, "class")
		}

		Group {
			text: "LE appearance"
		}

		Chips {
			id: appearanceChips

			readonly property int current: BtAdapter.kept.appearance ?? 0
			options: [[0, "Unknown"], [0x0080, "Computer"], [0x0081, "Desktop"], [0x0083, "Laptop"], [0x0087, "Tablet"], [0x0040, "Phone"], [0x00C0, "Watch"], [0x0200, "Tag"], [0x03C1, "Keyboard"], [0x03C2, "Mouse"], [0x03C4, "Gamepad"]].map(m => ({ value: m[0], label: m[1], on: appearanceChips.current === m[0] }))
			onClicked: v => BtAdapter.setAppearance(v)
		}

		Group {
			text: "Device ID (DID profile)"
		}

		RowLayout {
			Layout.fillWidth: true
			Layout.leftMargin: 12
			spacing: 8

			id: didRow

			readonly property var parts: String(BtAdapter.mainConf["General.DeviceID"] ?? "usb:1d6b:0246:0557").split(":")

			Segmented {
				id: didSource

				Layout.preferredWidth: 240
				options: [{ value: "usb", label: "USB" }, { value: "bluetooth", label: "Bluetooth" }, { value: "false", label: "Off" }]
				current: didRow.parts[0]
				onSelected: v => root.setDeviceId(v)
			}

			Field {
				id: didVendor

				Layout.preferredWidth: 110
				visible: didSource.current !== "false"
				placeholder: "Vendor"
				text: didRow.parts[1] ?? ""
				onAccepted: root.setDeviceId(didSource.current)
			}

			Field {
				id: didProduct

				Layout.preferredWidth: 110
				visible: didSource.current !== "false"
				placeholder: "Product"
				text: didRow.parts[2] ?? ""
				onAccepted: root.setDeviceId(didSource.current)
			}

			Field {
				id: didVersion

				Layout.preferredWidth: 110
				visible: didSource.current !== "false"
				placeholder: "Version"
				text: didRow.parts[3] ?? ""
				onAccepted: root.setDeviceId(didSource.current)
			}

			Item {
				Layout.fillWidth: true
			}
		}
	}

	function setDeviceId(source) {
		if (source === "false") {
			BtAdapter.ask("device-id", { source: "off" }, "device-id");
			return;
		}
		BtAdapter.ask("device-id", { source, vendor: parseInt(didVendor.text, 16) || 0, product: parseInt(didProduct.text, 16) || 0, version: parseInt(didVersion.text, 16) || 0 }, "device-id");
	}

	// ── advertising ────────────────────────────────────────────────────────
	SettingCard {
		id: advCard

		readonly property var adv: BtAdapter.kept.advertising ?? ({})

		anchor: "btadapter-advertising"
		visible: root.has
		title: "Advertising"
		subtitle: BtAdapter.advertising ? "On air" : ""
		icon: "broadcast"

		trailing: Toggle {
			checked: advCard.adv.on === true
			onToggled: on => BtAdapter.setAdvertising({ on })
		}

		Choice {
			icon: "access_point"
			title: "Sends"
			options: [{ value: "name", label: "Name" }, { value: "ibeacon", label: "iBeacon" }, { value: "eddystone", label: "Eddystone" }, { value: "custom", label: "Custom" }]
			current: advCard.adv.kind ?? "name"
			onPicked: v => BtAdapter.setAdvertising({ kind: v })
		}

		RowLayout {
			Layout.fillWidth: true
			Layout.leftMargin: 12
			spacing: 8

			StyledText {
				Layout.preferredWidth: 150
				text: "Name"
			}

			Field {
				Layout.fillWidth: true
				placeholder: root.ad.Alias ?? ""
				text: advCard.adv.localName ?? ""
				onAccepted: BtAdapter.setAdvertising({ localName: text.trim() || null })
			}
		}

		RowLayout {
			Layout.fillWidth: true
			Layout.leftMargin: 12
			visible: (advCard.adv.kind ?? "name") === "ibeacon"
			spacing: 8

			StyledText {
				Layout.preferredWidth: 150
				text: "UUID · major · minor"
			}

			Field {
				id: beaconUuid

				Layout.fillWidth: true
				placeholder: "UUID"
				text: advCard.adv.ibeacon?.uuid ?? ""
				onAccepted: root.saveBeacon()
			}

			Field {
				id: beaconMajor

				Layout.preferredWidth: 80
				placeholder: "0"
				text: String(advCard.adv.ibeacon?.major ?? "")
				onAccepted: root.saveBeacon()
			}

			Field {
				id: beaconMinor

				Layout.preferredWidth: 80
				placeholder: "0"
				text: String(advCard.adv.ibeacon?.minor ?? "")
				onAccepted: root.saveBeacon()
			}

			TextButton {
				variant: "ghost"
				icon: "sync"
				text: "New"
				onActivated: {
					beaconUuid.text = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, c => ((c === "x" ? Math.random() * 16 : Math.random() * 4 + 8) | 0).toString(16));
					root.saveBeacon();
				}
			}
		}

		RowLayout {
			Layout.fillWidth: true
			Layout.leftMargin: 12
			visible: advCard.adv.kind === "eddystone"
			spacing: 8

			StyledText {
				Layout.preferredWidth: 150
				text: "URL"
			}

			Field {
				Layout.fillWidth: true
				placeholder: "https://…"
				text: advCard.adv.url ?? ""
				onAccepted: BtAdapter.setAdvertising({ url: text.trim() })
			}
		}

		RowLayout {
			Layout.fillWidth: true
			Layout.leftMargin: 12
			visible: advCard.adv.kind === "custom"
			spacing: 8

			StyledText {
				Layout.preferredWidth: 150
				text: "Company · data"
			}

			Field {
				id: customId

				Layout.preferredWidth: 90
				placeholder: "ffff"
				text: advCard.adv.manufacturer ? Number(advCard.adv.manufacturer.id).toString(16) : ""
				onAccepted: BtAdapter.setAdvertising({ manufacturer: { id: parseInt(customId.text, 16) || 0xFFFF, data: customData.text.trim() } })
			}

			Field {
				id: customData

				Layout.fillWidth: true
				placeholder: "hex"
				text: advCard.adv.manufacturer?.data ?? ""
				onAccepted: BtAdapter.setAdvertising({ manufacturer: { id: parseInt(customId.text, 16) || 0xFFFF, data: customData.text.trim() } })
			}
		}

		ValueSlider {
			id: slider2

			Layout.fillWidth: true
			icon: "antenna"
			label: "Transmit power"
			from: BtAdapter.mgmt.caps?.leTxPower?.[0] ?? root.st.le?.txPower?.[0] ?? -34
			to: BtAdapter.mgmt.caps?.leTxPower?.[1] ?? root.st.le?.txPower?.[1] ?? 7
			step: 1
			value: advCard.adv.txPower ?? to
			format: v => `${Math.round(v)} dBm`
			onMoved: v => txLater.restart()

			Timer {
				id: txLater

				interval: 700
				onTriggered: BtAdapter.setAdvertising({ txPower: Math.round(slider2.value) })
			}
		}

		ValueSlider {
			id: slider3

			Layout.fillWidth: true
			icon: "timer_outline"
			label: "Every"
			from: 20
			to: 2000
			step: 10
			value: advCard.adv.interval?.[0] ?? 100
			format: v => `${Math.round(v)} ms`
			onMoved: v => ivLater.restart()

			Timer {
				id: ivLater

				interval: 700
				onTriggered: BtAdapter.setAdvertising({ interval: [Math.round(slider3.value), Math.round(slider3.value) + 10] })
			}
		}

		FlagRow {
			icon: "lan_connect"
			title: "Connectable"
			checked: advCard.adv.connectable === true
			onToggled: on => BtAdapter.setAdvertising({ connectable: on })
		}

		FlagRow {
			icon: "eye"
			title: "Discoverable"
			checked: advCard.adv.discoverable !== false
			onToggled: on => BtAdapter.setAdvertising({ discoverable: on })
		}

		Choice {
			icon: "wave"
			title: "Secondary channel"
			options: [{ value: "", label: "Legacy" }, { value: "1M", label: "1M" }, { value: "2M", label: "2M" }]
			current: advCard.adv.secondary ?? ""
			onPicked: v => BtAdapter.setAdvertising({ secondary: v || null })
		}
	}

	function saveBeacon() {
		BtAdapter.setAdvertising({ ibeacon: { uuid: beaconUuid.text.trim(), major: parseInt(beaconMajor.text) || 0, minor: parseInt(beaconMinor.text) || 0, power: -59 } });
	}

	// ── timing ─────────────────────────────────────────────────────────────
	SettingCard {
		anchor: "btadapter-timing"
		visible: root.has
		title: "Timing"
		icon: "timer_outline"
		enabled: root.rooted
		opacity: root.rooted ? 1 : 0.55

		Group {
			text: "Classic"
		}

		Choice {
			title: "Page scan"
			options: [{ value: "0", label: "Standard" }, { value: "1", label: "Interlaced" }]
			current: String(root.sys.PageScanType ?? 0)
			onPicked: v => BtAdapter.setTiming("PageScanType", Number(v))
		}

		Timing {
			key: "PageScanInterval"; label: "Page scan every"; lo: 0x12; hi: 0x1000; icon: "radar"
		}
		Timing {
			key: "PageScanWindow"; label: "Page scan listens"; lo: 0x11; hi: 0x1000; icon: "radar"
		}

		Choice {
			title: "Inquiry scan"
			options: [{ value: "0", label: "Standard" }, { value: "1", label: "Interlaced" }]
			current: String(root.sys.InquiryScanType ?? 0)
			onPicked: v => BtAdapter.setTiming("InquiryScanType", Number(v))
		}

		Timing {
			key: "InquiryScanInterval"; label: "Inquiry scan every"; lo: 0x12; hi: 0x1000; icon: "eye"
		}
		Timing {
			key: "InquiryScanWindow"; label: "Inquiry scan listens"; lo: 0x11; hi: 0x1000; icon: "eye"
		}
		Timing {
			key: "PageTimeout"; label: "Page timeout"; lo: 0x16; hi: 0xFFFF; icon: "timer_outline"
		}
		Timing {
			key: "LinkSupervisionTimeout"; label: "Link supervision"; lo: 0x0190; hi: 0xFFFF; icon: "timer_outline"
		}
		Timing {
			key: "MinSniffInterval"; label: "Sniff from"; lo: 0x02; hi: 0xFFFE; icon: "power_sleep"
		}
		Timing {
			key: "MaxSniffInterval"; label: "Sniff up to"; lo: 0x02; hi: 0xFFFE; icon: "power_sleep"
		}
		Timing {
			key: "IdleTimeout"; label: "Sniff after idle"; unit: 1; lo: 500; hi: 3600000; icon: "power_sleep"
		}

		Group {
			text: "LE scanning"
		}

		Repeater {
			model: [["Discovery", "Discovery"], ["Connect", "Connecting"], ["AutoConnect", "Reconnecting"], ["Suspend", "While asleep"], ["AdvMonitor", "Watching"]]

			ColumnLayout {
				id: scanPair

				required property var modelData

				Layout.fillWidth: true
				spacing: 0

				Timing {
					key: `ScanInterval${scanPair.modelData[0]}`; label: `${scanPair.modelData[1]}: every`; lo: 4; hi: 0x4000; icon: "radar"
				}
				Timing {
					key: `ScanWindow${scanPair.modelData[0]}`; label: `${scanPair.modelData[1]}: listens`; lo: 4; hi: 0x4000; icon: "radar"
				}
			}
		}

		Group {
			text: "LE connections"
		}

		Timing {
			key: "MinConnectionInterval"; label: "Interval from"; unit: 1.25; lo: 6; hi: 3200; icon: "swap_horizontal_variant"
		}
		Timing {
			key: "MaxConnectionInterval"; label: "Interval up to"; unit: 1.25; lo: 6; hi: 3200; icon: "swap_horizontal_variant"
		}

		ValueSlider {
			id: slider4

			Layout.fillWidth: true
			icon: "swap_horizontal_variant"
			label: "Latency (skipped events)"
			from: 0
			to: 499
			step: 1
			value: root.sys.ConnectionLatency ?? 0
			format: v => `${Math.round(v)}`
			onMoved: v => latLater.restart()

			Timer {
				id: latLater

				interval: 600
				onTriggered: BtAdapter.setTiming("ConnectionLatency", Math.round(slider4.value))
			}
		}

		Timing {
			key: "ConnectionSupervisionTimeout"; label: "Supervision"; unit: 10; lo: 10; hi: 3200; icon: "timer_outline"
		}
		Timing {
			key: "Autoconnecttimeout"; label: "Gives up connecting after"; unit: 1; lo: 100; hi: 0xFFFF; icon: "timer_outline"
		}

		Group {
			text: "LE advertising"
		}

		Timing {
			key: "MinAdvertisementInterval"; label: "Every, from"; lo: 0x20; hi: 0x4000; icon: "broadcast"
		}
		Timing {
			key: "MaxAdvertisementInterval"; label: "Every, up to"; lo: 0x20; hi: 0x4000; icon: "broadcast"
		}
		Timing {
			key: "MultiAdvertisementRotationInterval"; label: "Next set after"; unit: 1000; lo: 1; hi: 60; log: false; icon: "sync"
		}

		Group {
			text: "Advertisement monitor"
		}

		Timing {
			key: "AdvMonAllowlistScanDuration"; label: "Filtered scan"; unit: 1; lo: 10; hi: 10000; icon: "radar"
		}
		Timing {
			key: "AdvMonNoFilterScanDuration"; label: "Open scan"; unit: 1; lo: 10; hi: 10000; icon: "radar"
		}

		FlagRow {
			icon: "swap_horizontal_variant"
			title: "Interleave both"
			checked: (root.sys.EnableAdvMonInterleaveScan ?? 0) === 1
			onToggled: on => BtAdapter.setTiming("EnableAdvMonInterleaveScan", on ? 1 : 0)
		}
	}

	// ── security ───────────────────────────────────────────────────────────
	SettingCard {
		anchor: "btadapter-security"
		visible: root.has
		title: "Security"
		icon: "shield_key"
		enabled: root.rooted
		opacity: root.rooted ? 1 : 0.55

		ValueSlider {
			Layout.fillWidth: true
			icon: "key_outline"
			label: "Shortest key"
			from: 7
			to: 16
			step: 1
			value: BtAdapter.debugfs.min_key_size ?? 7
			format: v => `${Math.round(v) * 8} bit`
			onMoved: v => BtAdapter.setDebug("min_key_size", Math.round(v))
		}

		ValueSlider {
			Layout.fillWidth: true
			icon: "key_outline"
			label: "Longest key"
			from: 7
			to: 16
			step: 1
			value: BtAdapter.debugfs.max_key_size ?? 16
			format: v => `${Math.round(v) * 8} bit`
			onMoved: v => BtAdapter.setDebug("max_key_size", Math.round(v))
		}

		ValueSlider {
			Layout.fillWidth: true
			icon: "lock"
			label: "Shortest encryption key"
			from: 1
			to: 16
			step: 1
			value: BtAdapter.debugfs.min_encrypt_key_size ?? 7
			format: v => `${Math.round(v) * 8} bit`
			onMoved: v => BtAdapter.setDebug("min_encrypt_key_size", Math.round(v))
		}

		ValueSlider {
			id: slider5

			Layout.fillWidth: true
			icon: "timer_outline"
			label: "Checks encryption every"
			from: 100
			to: 6000
			step: 100
			value: BtAdapter.debugfs.auth_payload_timeout ?? 3000
			format: v => `${(v / 100).toFixed(0)} s`
			onMoved: v => apLater.restart()

			Timer {
				id: apLater

				interval: 700
				onTriggered: BtAdapter.setDebug("auth_payload_timeout", Math.round(slider5.value))
			}
		}

		FlagRow {
			icon: "shield_key"
			title: "Pair without MITM protection"
			checked: BtAdapter.debugfs.force_no_mitm === true
			onToggled: on => BtAdapter.setDebug("force_no_mitm", on)
		}

		ConfRow {
			key: "JustWorksRepairing"; title: "Re-pairing without a code"; kind: "choice"; fallback: "never"; icon: "link_variant"
			options: [{ value: "never", label: "Never" }, { value: "confirm", label: "Ask" }, { value: "always", label: "Always" }]
		}
		ConfRow {
			key: "AlwaysPairable"; title: "Pairable without an agent"; fallback: "false"; icon: "link_variant"
		}
		ConfRow {
			section: "GATT"; key: "KeySize"; title: "Key size for secured characteristics"; kind: "int"; from: 0; to: 16; fallback: "0"; icon: "key_outline"
			format: v => Math.round(v) < 7 ? "Any" : `${Math.round(v) * 8} bit`
		}
		ConfRow {
			file: "input.conf"; key: "ClassicBondedOnly"; title: "Input devices only when bonded"; fallback: "true"; icon: "keyboard"
		}
		ConfRow {
			file: "input.conf"; key: "LEAutoSecurity"; title: "Raise LE security when needed"; fallback: "true"; icon: "lock"
		}
		ConfRow {
			file: "network.conf"; key: "DisableSecurity"; title: "Network without link encryption"; fallback: "false"; icon: "lan_connect"
		}
		ConfRow {
			section: "LE"; key: "CentralAddressResolution"; title: "Resolve private addresses as central"; kind: "int01"; fallback: "1"; icon: "identifier"
		}

		Info {
			label: "Blocked keys"
			value: BtAdapter.debugfs.blocked_keys ? `${BtAdapter.debugfs.blocked_keys} known-weak keys refused` : ""
		}
	}

	// ── experimental ───────────────────────────────────────────────────────
	SettingCard {
		id: expCard

		anchor: "btadapter-experimental"
		visible: root.has
		title: "Experimental"
		icon: "flask_outline"
		enabled: root.rooted
		opacity: root.rooted ? 1 : 0.55

		readonly property var names: ({ "central-peripheral": "Central and peripheral at once", "quality-report": "Quality reports", "iso-socket": "Isochronous channels (LE Audio)", "mesh": "Mesh", "ll-privacy": "LL privacy", "codec-offload": "Codec offload", "debug": "Kernel debug" })

		Repeater {
			model: BtAdapter.exp.filter(e => e.id !== "iso-socket")

			FlagRow {
				required property var modelData

				icon: "flask_outline"
				title: expCard.names?.[modelData.id] ?? modelData.id
				checked: modelData.on
				onToggled: on => BtAdapter.setExp(modelData.uuid, on, false)
			}
		}

		Repeater {
			model: BtAdapter.expGlobal

			FlagRow {
				required property var modelData

				icon: "flask_outline"
				title: `${expCard.names?.[modelData.id] ?? modelData.id}, for every adapter`
				checked: modelData.on
				onToggled: on => BtAdapter.setExp(modelData.uuid, on, true)
			}
		}

		ConfRow {
			key: "Experimental"; title: "Experimental D-Bus interfaces of bluetoothd"; fallback: "false"; icon: "flask_outline"
		}
		ConfRow {
			key: "Testing"; title: "Testing D-Bus interfaces of bluetoothd"; fallback: "false"; icon: "bug_outline"
		}

		Info {
			label: "Quality reports"
			value: BtAdapter.quality.length ? `${BtAdapter.quality.length} · last ${BtAdapter.quality[BtAdapter.quality.length - 1].data.slice(0, 48)}…` : ""
		}
	}

	// ── bluetoothd ─────────────────────────────────────────────────────────
	SettingCard {
		anchor: "btadapter-bluez"
		visible: root.has
		title: "bluetoothd"
		icon: "cog_outline"
		enabled: root.rooted
		opacity: root.rooted ? 1 : 0.55

		trailing: TextButton {
			variant: BtAdapter.restartPending.length ? "filled" : "ghost"
			icon: "restart"
			text: BtAdapter.restartPending.length ? `Restart (${BtAdapter.restartPending.length})` : "Restart"
			busy: BtAdapter.isBusy("restart")
			confirm: BtAdapter.links.length > 0
			onActivated: BtAdapter.restartBluetooth()
		}

		Group {
			text: "General"
		}

		ConfRow {
			key: "AutoEnable"; section: "Policy"; title: "Switch on when found"; fallback: "true"; icon: "power"
		}
		ConfRow {
			key: "NameResolving"; title: "Look up names after a scan"; fallback: "true"; icon: "information_outline"
		}
		ConfRow {
			key: "ReverseServiceDiscovery"; title: "Ask new devices for their services"; fallback: "true"; icon: "information_outline"
		}
		ConfRow {
			key: "RefreshDiscovery"; title: "Refresh services when a profile connects"; fallback: "true"; icon: "sync"
		}
		ConfRow {
			key: "FilterDiscoverable"; title: "Only list discoverable devices"; fallback: "true"; icon: "eye"
		}
		ConfRow {
			key: "MultiProfile"; title: "Multiple profiles"; kind: "choice"; fallback: "off"; icon: "devices"
			options: [{ value: "off", label: "Off" }, { value: "single", label: "One device" }, { value: "multiple", label: "Several" }]
		}
		ConfRow {
			key: "TemporaryTimeout"; title: "Forgets unpaired devices after"; kind: "int"; from: 0; to: 600; step: 10; fallback: "30"; icon: "timer_outline"
			format: v => Math.round(v) === 0 ? "Never" : `${Math.round(v)} s`
		}
		ConfRow {
			key: "RemoteNameRequestRetryDelay"; title: "Asks a name again after"; kind: "int"; from: 0; to: 3600; step: 30; fallback: "300"; icon: "timer_outline"
			format: v => `${Math.round(v / 60 * 10) / 10} min`
		}
		ConfRow {
			key: "MaxControllers"; title: "Adapters at most"; kind: "int"; from: 0; to: 8; fallback: "0"; icon: "bluetooth"
			format: v => Math.round(v) === 0 ? "Any" : `${Math.round(v)}`
		}

		Group {
			text: "Reconnecting"
		}

		ConfRow {
			section: "Policy"; key: "ReconnectAttempts"; title: "Tries after a lost link"; kind: "int"; from: 0; to: 20; fallback: "7"; icon: "restart"
			format: v => Math.round(v) === 0 ? "Off" : `${Math.round(v)}`
		}

		RowLayout {
			Layout.fillWidth: true
			Layout.leftMargin: 12
			spacing: 10

			StyledText {
				Layout.preferredWidth: 150
				text: "Waits between (s)"
			}

			Field {
				Layout.fillWidth: true
				placeholder: "1,2,4,8,16,32,64"
				text: BtAdapter.mainConf["Policy.ReconnectIntervals"] ?? ""
				onAccepted: if (/^(\d+,)*\d*$/.test(text.trim())) BtAdapter.setConf("main.conf", "Policy", "ReconnectIntervals", text.trim() || null, false)
			}
		}

		ConfRow {
			section: "Policy"; key: "ResumeDelay"; title: "Reconnects audio after waking"; kind: "int"; from: 0; to: 30; fallback: "2"; icon: "power_sleep"
			format: v => `${Math.round(v)} s`
		}

		Group {
			text: "GATT"
		}

		ConfRow {
			section: "GATT"; key: "Cache"; title: "Attribute cache"; kind: "choice"; fallback: "always"; icon: "database_outline"
			options: [{ value: "always", label: "Always" }, { value: "yes", label: "Paired" }, { value: "no", label: "Never" }]
		}
		ConfRow {
			section: "GATT"; key: "Client"; title: "GATT client"; fallback: "true"; icon: "lan_connect"
		}
		ConfRow {
			section: "GATT"; key: "ExchangeMTU"; title: "MTU"; kind: "int"; from: 23; to: 517; fallback: "517"; icon: "swap_horizontal_variant"
			format: v => `${Math.round(v)} bytes`
		}
		ConfRow {
			section: "GATT"; key: "Channels"; title: "ATT channels"; kind: "int"; from: 1; to: 6; fallback: "1"; icon: "swap_horizontal_variant"
			format: v => Math.round(v) === 1 ? "1 (no EATT)" : `${Math.round(v)} (EATT)`
		}
		ConfRow {
			section: "GATT"; key: "ExportClaimedServices"; title: "Services claimed by plugins"; kind: "choice"; fallback: "read-only"; icon: "lock_open_variant"
			options: [{ value: "no", label: "Hidden" }, { value: "read-only", label: "Read" }, { value: "read-write", label: "Read, write" }]
		}
		ConfRow {
			section: "GATT"; key: "Security"; title: "ATT security"; kind: "choice"; fallback: "auto"; icon: "shield_key"
			options: [{ value: "auto", label: "Auto" }, { value: "low", label: "Low" }, { value: "medium", label: "Medium" }, { value: "high", label: "High" }, { value: "fips", label: "FIPS" }]
		}

		Group {
			text: "Audio and input"
		}

		ConfRow {
			section: "AVDTP"; key: "SessionMode"; title: "AVDTP signalling"; kind: "choice"; fallback: "basic"; icon: "volume_high"
			options: [{ value: "basic", label: "Basic" }, { value: "ertm", label: "ERTM" }]
		}
		ConfRow {
			section: "AVDTP"; key: "StreamMode"; title: "AVDTP stream"; kind: "choice"; fallback: "basic"; icon: "volume_high"
			options: [{ value: "basic", label: "Basic" }, { value: "streaming", label: "Streaming" }]
		}
		ConfRow {
			section: "AVRCP"; key: "VolumeWithoutTarget"; title: "Absolute volume without remote target"; fallback: "false"; icon: "volume_high"
		}
		ConfRow {
			section: "AVRCP"; key: "VolumeCategory"; title: "Absolute volume only for category 2"; fallback: "true"; icon: "volume_high"
		}
		ConfRow {
			file: "input.conf"; key: "UserspaceHID"; title: "HID in"; kind: "choice"; fallback: "true"; icon: "keyboard"
			options: [{ value: "true", label: "Userspace" }, { value: "persist", label: "Kept" }, { value: "false", label: "Kernel" }]
		}
		ConfRow {
			file: "input.conf"; key: "IdleTimeout"; title: "Input devices disconnect after"; kind: "int"; from: 0; to: 120; fallback: "0"; icon: "timer_outline"
			format: v => Math.round(v) === 0 ? "Never" : `${Math.round(v)} min`
		}
		ConfRow {
			section: "AdvMon"; key: "RSSISamplingPeriod"; title: "Monitor reports every"; kind: "int"; from: 0; to: 255; fallback: "255"; icon: "radar"
			format: v => Math.round(v) === 0 ? "Each" : (Math.round(v) === 255 ? "Once" : `${Math.round(v) * 100} ms`)
		}
	}

	// ── power and driver ───────────────────────────────────────────────────
	SettingCard {
		anchor: "btadapter-power"
		visible: root.has
		title: "Power and driver"
		subtitle: BtAdapter.usb ? `${BtAdapter.usb.runtimeStatus === "suspended" ? "Asleep" : "Awake"} · asleep ${Math.round(BtAdapter.usb.suspendedTime / Math.max(1, BtAdapter.usb.suspendedTime + BtAdapter.usb.activeTime) * 100)} % of the time` : ""
		icon: "power_sleep"
		enabled: root.rooted
		opacity: root.rooted ? 1 : 0.55

		FlagRow {
			icon: "power_sleep"
			title: "Sleeps when idle"
			checked: BtAdapter.usb?.control === "auto"
			onToggled: on => BtAdapter.setUsbPower({ control: on ? "auto" : "on" })
		}

		ValueSlider {
			id: slider6

			Layout.fillWidth: true
			visible: BtAdapter.usb?.control === "auto"
			icon: "timer_outline"
			label: "After"
			from: 0
			to: 10000
			step: 500
			value: BtAdapter.usb?.autosuspendDelay ?? 2000
			format: v => `${(v / 1000).toFixed(1)} s`
			onMoved: v => usbLater.restart()

			Timer {
				id: usbLater

				interval: 700
				onTriggered: BtAdapter.setUsbPower({ delay: Math.round(slider6.value) })
			}
		}

		FlagRow {
			icon: "power"
			title: "Bluetooth devices wake the PC"
			checked: BtAdapter.usb?.wakeup === "enabled"
			onToggled: on => BtAdapter.setUsbPower({ wakeup: on })
		}

		Group {
			text: "Kernel"
		}

		Repeater {
			model: [["btusb.enable_autosuspend", "USB autosuspend at start"], ["btusb.reset", "Reset at start"], ["btusb.force_scofix", "Force SCO buffer fix"], ["btusb.disable_scofix", "No SCO buffer fix"], ["bluetooth.disable_ertm", "No enhanced retransmission (ERTM)"], ["bluetooth.disable_esco", "No eSCO (headset voice)"], ["bluetooth.enable_ecred", "Enhanced credit flow control"]]

			FlagRow {
				required property var modelData
				readonly property var kept: BtAdapter.modprobe[modelData[0]]
				readonly property var now: BtAdapter.params[modelData[0]]

				icon: "chip"
				title: modelData[1]
				subtitle: kept !== undefined && kept !== now ? "From the next start" : ""
				modified: kept !== undefined
				checked: kept ?? now ?? false
				onToggled: on => BtAdapter.setModule(modelData[0], on)
				onReset: BtAdapter.setModule(modelData[0], null)
			}
		}

		RowLayout {
			Layout.fillWidth: true
			Layout.topMargin: 6

			Item {
				Layout.fillWidth: true
			}

			TextButton {
				variant: "danger"
				icon: "restart"
				text: "Reset the adapter"
				confirm: true
				busy: BtAdapter.isBusy("reset")
				onActivated: BtAdapter.ask("reset-adapter", {}, "reset")
			}
		}
	}

	// ── debug ──────────────────────────────────────────────────────────────
	SettingCard {
		anchor: "btadapter-debug"
		visible: root.has
		title: "Debug"
		icon: "bug_outline"
		enabled: root.rooted
		opacity: root.rooted ? 1 : 0.55

		Chips {
			id: advMapChips

			readonly property int map: BtAdapter.debugfs.adv_channel_map ?? 7
			options: [[1, "Advertises on 37"], [2, "38"], [4, "39"]].map(c => ({ value: c[0], label: c[1], on: (advMapChips.map & c[0]) !== 0 }))
			onClicked: v => {
				const next = advMapChips.map ^ v;
				if (next) BtAdapter.setDebug("adv_channel_map", next);
			}
		}

		ValueSlider {
			Layout.fillWidth: true
			icon: "timer_outline"
			label: "Accepts pairing after"
			from: 0
			to: 10000
			step: 250
			value: BtAdapter.debugfs.auto_accept_delay ?? 0
			format: v => Math.round(v) === 0 ? "At once" : `${(v / 1000).toFixed(2)} s`
			onMoved: v => BtAdapter.setDebug("auto_accept_delay", Math.round(v))
		}

		ValueSlider {
			Layout.fillWidth: true
			icon: "timer_outline"
			label: "Interleaved discovery"
			from: 0
			to: 20000
			step: 500
			value: BtAdapter.debugfs.discov_interleaved_timeout ?? 5120
			format: v => `${(v / 1000).toFixed(1)} s`
			onMoved: v => BtAdapter.setDebug("discov_interleaved_timeout", Math.round(v))
		}

		ValueSlider {
			Layout.fillWidth: true
			icon: "sync"
			label: "Signal readings cached"
			from: 100
			to: 10000
			step: 100
			value: BtAdapter.debugfs.conn_info_max_age ?? 3000
			format: v => `${(BtAdapter.debugfs.conn_info_min_age ?? 1000) / 1000}–${(v / 1000).toFixed(1)} s`
			onMoved: v => BtAdapter.setDebug("conn_info_max_age", Math.max(Math.round(v), BtAdapter.debugfs.conn_info_min_age ?? 1000))
		}

		Repeater {
			model: [["force_static_address", "Use the static address"], ["force_poll_sync", "Poll synchronously"], ["quirk_simultaneous_discovery", "Simultaneous discovery"], ["quirk_strict_duplicate_filter", "Strict duplicate filter"], ["vendor_diag", "Intel diagnostics"], ["dut_mode", "Device under test mode"]]

			FlagRow {
				required property var modelData

				icon: modelData[0] === "dut_mode" ? "alert_outline" : "bug_outline"
				title: modelData[1]
				checked: BtAdapter.debugfs[modelData[0]] === true
				onToggled: on => BtAdapter.setDebug(modelData[0], on)
			}
		}
	}

	// ── what the chip says ─────────────────────────────────────────────────
	SettingCard {
		id: aboutCard

		anchor: "btadapter-about"
		visible: root.has
		title: "About the adapter"
		icon: "chip"

		readonly property var fw: BtAdapter.firmware
		readonly property var ver: root.st.version ?? {}
		readonly property var intel: root.st.intel ?? {}
		readonly property var le: root.st.le ?? {}
		readonly property var buf: root.st.buffers ?? {}

		Info { label: "Chip"; value: aboutCard.intel.hwPlatform !== undefined ? `Intel platform ${aboutCard.intel.hwPlatform}, variant ${aboutCard.intel.hwVariant}, revision ${aboutCard.intel.hwRevision}` : "Intel AX201" }
		Info { label: "Firmware"; value: [aboutCard.fw.firmwareRevision, aboutCard.fw.firmwareVersion ? `version ${aboutCard.fw.firmwareVersion}` : "", aboutCard.fw.firmwareFile].filter(s => s).join(" · ") }
		Info { label: "Bootloader"; value: aboutCard.fw.bootloader ?? "" }
		Info { label: "Locks"; value: aboutCard.fw.secureBoot ? `secure boot ${aboutCard.fw.secureBoot}, OTP ${aboutCard.fw.otpLock}, API ${aboutCard.fw.apiLock}, debug ${aboutCard.fw.debugLock}` : "" }
		Info { label: "Radio parameters"; value: aboutCard.fw.ddc ?? "" }
		Info { label: "Started in"; value: aboutCard.fw.loadTime ? `${(Number(aboutCard.fw.loadTime) / 1e6).toFixed(2)} s firmware, ${(Number(aboutCard.fw.bootTime) / 1000).toFixed(1)} ms boot` : "" }
		Info { label: "Version"; value: aboutCard.ver.hci ? `HCI ${aboutCard.ver.hci} (rev. ${aboutCard.ver.hciRevision}), LMP ${aboutCard.ver.lmp} (subversion ${aboutCard.ver.lmpSubversion}), ${aboutCard.ver.manufacturer}` : "" }
		Info { label: "Buffers"; value: aboutCard.buf.aclLength ? `ACL ${aboutCard.buf.aclPackets} × ${aboutCard.buf.aclLength} B, SCO ${aboutCard.buf.scoPackets} × ${aboutCard.buf.scoLength} B${aboutCard.buf.leLength ? `, LE ${aboutCard.buf.lePackets} × ${aboutCard.buf.leLength} B` : ""}` : "" }
		Info { label: "LE"; value: aboutCard.le.advSets ? `${aboutCard.le.advSets} advertising sets, accept list ${aboutCard.le.acceptList}, resolving list ${aboutCard.le.resolvingList}, packets up to ${aboutCard.le.maxData?.txOctets} B` : "" }
		Info { label: "Transmit power"; value: aboutCard.le.txPower ? `${aboutCard.le.txPower[0]} to ${aboutCard.le.txPower[1]} dBm (LE), inquiry ${root.st.baseband?.inquiryTxPower} dBm` : "" }
		Info { label: "Codecs"; value: root.st.codecs?.standard ? root.st.codecs.standard.concat(root.st.codecs.vendor ?? []).join(", ") : "" }
		Info { label: "Offload"; value: aboutCard.intel.offload ? `use cases 0x${aboutCard.intel.offload.slice(0, 2)}${parseInt(aboutCard.intel.offload.slice(0, 2), 16) & 0x03 ? " (voice for headsets)" : ""}` : "" }
		Info { label: "Telemetry"; value: aboutCard.intel.telemetry !== undefined ? (aboutCard.intel.telemetry ? "Supported (quality reports)" : "No") : "" }
		Info { label: "Monitor"; value: BtAdapter.mgmt.monitor && !BtAdapter.mgmt.monitor.error ? `${BtAdapter.mgmt.monitor.maxHandles} monitors, ${BtAdapter.mgmt.monitor.maxPatterns} patterns${BtAdapter.mgmt.monitor.supported.length ? " in the controller" : ""}` : "" }
		Info { label: "Security"; value: BtAdapter.mgmt.caps?.maxKeySizeBredr ? `keys up to ${BtAdapter.mgmt.caps.maxKeySizeBredr * 8} bit${(BtAdapter.mgmt.caps.flags ?? []).length ? ", " + BtAdapter.mgmt.caps.flags.join(", ") : ""}` : "" }
		Info { label: "USB"; value: BtAdapter.usb ? `${BtAdapter.usb.id} · port ${BtAdapter.usb.port}${BtAdapter.usb.builtIn ? " · built in" : ""} · ${BtAdapter.usb.speed} Mb/s · ${BtAdapter.usb.driver}` : "" }

		Group {
			visible: !!root.st.features
			text: "Can do"
		}

		Flow {
			Layout.fillWidth: true
			Layout.leftMargin: 12
			spacing: 6
			visible: !!root.st.features

			Repeater {
				model: root.st.features ? [].concat(root.st.features.page0 ?? [], root.st.features.page2 ?? [], root.st.features.le ?? []) : []

				Chip {
					required property var modelData

					text: modelData
					enabled: false
				}
			}
		}
	}
}
