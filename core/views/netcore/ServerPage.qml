pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services
import qs.core.views.settings

// Pshell settings › Server (docs/core.md "Shell"): pshell-core on netcore.
// The services with their state and memory (restart, stop, start – asked
// first), the Pi's health with a 24 h history and the memory guard, the
// devices of every service with what each may do, the sessions, the
// security log, the users and core's settings (the critical ones ask
// first). Everything goes through Netcore → the NAS daemon (op `core`);
// what this device may not do (no core `admin`) is only shown.
SettingsPage {
	id: root

	title: "Server"
	description: "netcore: the services on the Pi, its health, and who may sign in where."

	headerTrailing: [
		TextButton {
			text: "Open the portal"
			icon: "open_in_new"
			onActivated: Netcore.openPortal("/")
		}
	]

	property bool watching: false

	onActiveChanged: {
		if (root.active && !root.watching) {
			root.watching = true;
			Netcore.watchers += 1;
			Netcore.loadAll();
		} else if (!root.active && root.watching) {
			root.watching = false;
			Netcore.watchers = Math.max(0, Netcore.watchers - 1);
		}
	}
	Component.onDestruction: if (root.watching) Netcore.watchers = Math.max(0, Netcore.watchers - 1)

	// core came (back) while the page shows: everything once more
	Connections {
		target: Netcore

		function onOnlineChanged() {
			if (root.watching && Netcore.online) Netcore.loadAll();
		}
	}

	readonly property bool ready: Netcore.online && Netcore.loaded

	// what a device may get per service: core's caps, and every core-auth service's
	readonly property var choices: {
		const found = { core: ["read", "admin"] };
		for (const service of Netcore.services) {
			if (service.auth !== "core") continue;
			found[service.name] = (service.caps ?? []).slice();
		}
		for (const device of Netcore.devices) {
			for (const name of Object.keys(device.scopes ?? {})) {
				const caps = found[name] ?? [];
				for (const cap of device.scopes[name] ?? []) if (!caps.includes(cap)) caps.push(cap);
				found[name] = caps;
			}
		}
		return found;
	}

	// ── the history ──────────────────────────────────────────────────────
	property string metric: "memory"
	// the Pi's kernel has no PSI: the guard then goes by major page faults per second
	readonly property bool noPsi: Netcore.health?.psi_some10 === null || Netcore.health?.psi_some10 === undefined
	readonly property var metrics: ({
		memory: { label: "Memory used", unit: "", of: s => Math.max(0, Number(s.mem_total) - Number(s.mem_available)), text: v => Format.bytes(v) },
		temp: { label: "Temperature", unit: " °C", of: s => Number(s.temp) || 0, text: v => `${v.toFixed(1)} °C` },
		load: { label: "Load", unit: "", of: s => Number(s.load1) || 0, text: v => v.toFixed(2) },
		pressure: root.noPsi
			? { label: "Page faults", unit: " /s", of: s => Number(s.faults) || 0, text: v => `${v.toFixed(v < 10 ? 1 : 0)} /s` }
			: { label: "Memory pressure", unit: " %", of: s => Number(s.psi_some10) || 0, text: v => `${v.toFixed(1)} %` }
	})
	readonly property var series: {
		const of = root.metrics[root.metric].of;
		const samples = Netcore.history;
		if (samples.length === 0) return [];
		// at most 144 points (one per 10 min over 24 h): the averages of their spans
		const buckets = Math.min(144, samples.length);
		const out = [];
		for (let i = 0; i < buckets; i += 1) {
			const from = Math.floor(i * samples.length / buckets);
			const to = Math.max(from + 1, Math.floor((i + 1) * samples.length / buckets));
			let sum = 0;
			for (let j = from; j < to; j += 1) sum += of(samples[j]);
			out.push(sum / (to - from));
		}
		return out;
	}
	readonly property real seriesMax: root.series.reduce((top, v) => Math.max(top, v), 0)
	readonly property real seriesMin: root.series.length > 0 ? root.series.reduce((low, v) => Math.min(low, v), Infinity) : 0

	// ── pieces ───────────────────────────────────────────────────────────
	component Note: StyledText {
		Layout.fillWidth: true
		Layout.leftMargin: 12
		Layout.rightMargin: 12
		tone: Theme.textMuted
		font.pixelSize: Theme.size.small
		wrapMode: Text.Wrap
	}

	component Head: StyledText {
		Layout.fillWidth: true
		Layout.leftMargin: 12
		Layout.topMargin: 8
		tone: Theme.textMuted
		font.pixelSize: Theme.size.small
		font.weight: Font.Bold
	}

	// a number of core's settings, sent a moment after the slider stops
	component Amount: ValueSlider {
		id: amount

		required property string key
		property real fallback: 0
		property real pending: 0

		Layout.fillWidth: true
		Layout.leftMargin: 12
		Layout.rightMargin: 12
		enabled: Netcore.admin
		value: Number(Netcore.setting(amount.key, amount.fallback))
		onMoved: v => {
			amount.pending = v;
			send.restart();
		}

		Timer {
			id: send

			interval: 500
			onTriggered: Netcore.setSetting(amount.key, amount.pending, false)
		}
	}

	// a switch of core that asks before it changes either way
	component Critical: ColumnLayout {
		id: critical

		required property string key
		property string title: ""
		property string subtitle: ""
		property string icon: "shield_alert_outline"
		property string onText: ""
		property string offText: ""
		property bool fallback: false
		property int asking: -1
		property bool busy: false
		readonly property bool checked: !!Netcore.setting(critical.key, critical.fallback)

		Layout.fillWidth: true
		spacing: 4

		FlagRow {
			Layout.fillWidth: true
			enabled: Netcore.admin
			title: critical.title
			subtitle: critical.subtitle
			icon: critical.icon
			checked: critical.asking === -1 ? critical.checked : critical.asking === 1
			onToggled: on => critical.asking = on ? 1 : 0
		}

		Ask {
			Layout.leftMargin: 12
			Layout.rightMargin: 12
			open: critical.asking !== -1
			busy: critical.busy
			title: `${critical.asking === 1 ? "Switch on" : "Switch off"} “${critical.title}”?`
			detail: critical.asking === 1 ? critical.onText : critical.offText
			confirmText: critical.asking === 1 ? "Switch on" : "Switch off"
			onAccepted: {
				critical.busy = true;
				Netcore.setSetting(critical.key, critical.asking === 1, true, () => {
					critical.busy = false;
					critical.asking = -1;
				});
			}
			onCancelled: critical.asking = -1
		}
	}

	// ── core itself ──────────────────────────────────────────────────────
	SettingCard {
		anchor: "server-core"
		title: !Netcore.active ? "Waiting for the NAS daemon" : (!Netcore.loaded ? "Asking core …" : (Netcore.reachable ? "pshell-core" : "Core is not reachable"))
		subtitle: {
			if (!Netcore.active) return Nas.configured ? "Core is asked through scripts/nas/nas.py" : "The NAS is not set up: Pshell settings › NAS";
			if (!Netcore.loaded) return "Through the NAS daemon";
			if (!Netcore.reachable) return Netcore.error !== "" ? Netcore.error : `Nobody answers at ${Netcore.portalUrl}`;
			const me = Netcore.me?.user ? `signed in as ${Netcore.who}` : (Netcore.who !== "" ? `as the device ${Netcore.who}${Netcore.admin ? " (admin)" : " (read only)"}` : "");
			return [Netcore.url, me, Netcore.linked ? "live" : "asked now and then"].filter(s => s).join(" · ");
		}
		icon: Netcore.reachable ? "server" : "lan_disconnect"

		trailing: [
			Rectangle {
				visible: Netcore.reachable && Netcore.level !== ""
				implicitWidth: levelRow.implicitWidth + 20
				implicitHeight: 28
				radius: 14
				color: Qt.alpha(Netcore.levelColor(Netcore.level), 0.14)

				Behavior on color {
					ColorAnim {
						duration: Motion.long
					}
				}

				Row {
					id: levelRow

					anchors.centerIn: parent
					spacing: 6

					Rectangle {
						anchors.verticalCenter: parent.verticalCenter
						width: 8
						height: 8
						radius: 4
						color: Netcore.levelColor(Netcore.level)

						SequentialAnimation on opacity {
							running: !Netcore.guardOk
							loops: Animation.Infinite
							alwaysRunToEnd: true

							NumberAnimation {
								to: 0.35
								duration: 1100
								easing.type: Easing.InOutSine
							}
							NumberAnimation {
								to: 1
								duration: 1100
								easing.type: Easing.InOutSine
							}
						}
					}

					StyledText {
						text: `Memory ${Netcore.levelText(Netcore.level).toLowerCase()}`
						tone: Netcore.levelColor(Netcore.level)
						font.pixelSize: Theme.size.label
						font.weight: Font.DemiBold
					}
				}
			}
		]

		Note {
			visible: Netcore.active && Netcore.loaded && !Netcore.reachable
			text: "Core runs on netcore at port 8097, beside the NAS (docs/core.md). The NAS page keeps working without it; devices and sign-ins are then the NAS's own."
		}

		Note {
			visible: Netcore.reachable && !Netcore.admin
			text: "This PC's device may only read core. Changes need a device with core admin, or the portal."
		}

		RowLayout {
			Layout.fillWidth: true
			Layout.leftMargin: 12
			Layout.rightMargin: 12
			spacing: 8
			visible: Netcore.active

			Spinner {
				visible: Netcore.active && !Netcore.loaded
				Layout.preferredWidth: 16
				Layout.preferredHeight: 16
			}

			Item {
				Layout.fillWidth: true
			}

			TextButton {
				text: "Ask again"
				icon: "refresh"
				variant: "ghost"
				onActivated: Netcore.loadAll()
			}
		}
	}

	// ── services ─────────────────────────────────────────────────────────
	SettingCard {
		anchor: "server-services"
		visible: root.ready
		title: "Services"
		subtitle: {
			const count = Netcore.services.length;
			const up = Netcore.services.filter(s => s.state === "up").length;
			return `${up} of ${count} up${Netcore.down.length > 0 ? ` · ${Netcore.down.map(s => s.title ?? s.name).join(", ")} down` : ""}`;
		}
		icon: "apps"

		GridLayout {
			Layout.fillWidth: true
			columns: width > 720 ? 3 : 2
			columnSpacing: 10
			rowSpacing: 10

			Repeater {
				model: Netcore.services

				delegate: ServiceTile {
					required property var modelData
					required property int index

					Layout.alignment: Qt.AlignTop
					Layout.preferredWidth: 10
					service: modelData
					index: index
				}
			}
		}

		Note {
			visible: Netcore.services.length === 0
			text: "Core lists no services."
		}
	}

	// ── the Pi ───────────────────────────────────────────────────────────
	SettingCard {
		anchor: "server-health"
		visible: root.ready
		title: "The Pi"
		subtitle: {
			const h = Netcore.health ?? {};
			const parts = [];
			if (h.uptime) parts.push(`up ${Format.duration(h.uptime)}`);
			if (h.load1 !== undefined) parts.push(`load ${Number(h.load1).toFixed(2)} ${Number(h.load5 ?? 0).toFixed(2)} ${Number(h.load15 ?? 0).toFixed(2)}`);
			if (Number(h.swap_used) > 0) parts.push(`${Format.bytes(h.swap_used)} swap`);
			if (h.at) parts.push(`sampled ${Netcore.ago(h.at)}`);
			return parts.join(" · ");
		}
		icon: "chip"

		RowLayout {
			Layout.fillWidth: true
			spacing: 4

			Gauge {
				label: "Memory"
				icon: "memory"
				value: Netcore.memFill >= 0 ? `${Math.round(Netcore.memFill * 100)} %` : "–"
				detail: Netcore.memTotal > 0 ? `${Format.bytes(Netcore.memAvailable)} free of ${Format.bytes(Netcore.memTotal)}` : ""
				fill: Netcore.memFill
				warnAt: Netcore.memTotal > 0 ? 1 - Number(Netcore.setting("tight_mb", 900)) * 1048576 / Netcore.memTotal : 0.85
				dangerAt: Netcore.memTotal > 0 ? 1 - Number(Netcore.setting("critical_mb", 450)) * 1048576 / Netcore.memTotal : 0.93
				selected: root.metric === "memory"
				onClicked: root.metric = "memory"
			}

			Gauge {
				label: "Temperature"
				icon: "thermometer"
				value: Netcore.temp > 0 ? `${Math.round(Netcore.temp)}°` : "–"
				detail: Netcore.throttled.length > 0 ? Netcore.throttled.join(", ") : "throttles at 80 °C"
				fill: Netcore.temp > 0 ? Math.min(1, Netcore.temp / 85) : -1
				warnAt: 70 / 85
				dangerAt: 78 / 85
				selected: root.metric === "temp"
				onClicked: root.metric = "temp"
			}

			Gauge {
				label: "Load"
				icon: "gauge"
				value: Netcore.health?.load1 !== undefined ? Netcore.load1.toFixed(2) : "–"
				detail: Netcore.health?.cpu !== undefined ? `${Math.round(Number(Netcore.health.cpu))} % CPU · 4 cores` : "4 cores"
				fill: Netcore.health?.load1 !== undefined ? Math.min(1, Netcore.load1 / 4) : -1
				warnAt: 0.75
				dangerAt: 1
				selected: root.metric === "load"
				onClicked: root.metric = "load"
			}

			Gauge {
				label: "Disk"
				icon: "harddisk"
				value: Netcore.diskFill >= 0 ? `${Math.round(Netcore.diskFill * 100)} %` : "–"
				detail: Netcore.diskTotal > 0 ? `${Format.bytes(Netcore.diskTotal - Netcore.diskUsed)} free` : ""
				fill: Netcore.diskFill
				warnAt: 0.85
				dangerAt: 0.95
				interactive: false
			}
		}

		// 24 h of the picked number
		ColumnLayout {
			Layout.fillWidth: true
			Layout.leftMargin: 12
			Layout.rightMargin: 12
			spacing: 6

			RowLayout {
				Layout.fillWidth: true
				spacing: 10

				StyledText {
					Layout.fillWidth: true
					text: `${root.metrics[root.metric].label} · 24 h`
					font.weight: Font.DemiBold
				}

				StyledText {
					visible: root.series.length > 1
					text: `${root.metrics[root.metric].text(root.seriesMin)} – ${root.metrics[root.metric].text(root.seriesMax)}`
					tone: Theme.textMuted
					font.pixelSize: Theme.size.small
					tabular: true
				}

				Segmented {
					implicitWidth: 300
					options: [{ value: "memory", label: "Memory" }, { value: "temp", label: "Heat" }, { value: "load", label: "Load" }, { value: "pressure", label: "Pressure" }]
					current: root.metric
					onSelected: value => root.metric = value
				}
			}

			Item {
				Layout.fillWidth: true
				implicitHeight: 96

				Sparkline {
					id: chart

					anchors.fill: parent
					values: root.series
					maximum: root.metric === "memory" ? Netcore.memTotal : (root.metric === "temp" ? 85 : 0)
					color: root.metric === "temp" ? Theme.warning : (root.metric === "pressure" ? Theme.danger : Theme.primary)
					opacity: Netcore.historyLoaded ? 1 : 0

					Behavior on opacity {
						Anim {
							duration: Motion.long
						}
					}
				}

				// the guard's limits on the memory chart
				Rectangle {
					visible: root.metric === "memory" && Netcore.memTotal > 0 && chart.opacity > 0
					x: 0
					width: parent.width
					height: 1
					y: parent.height - parent.height * Math.min(1, (Netcore.memTotal - Number(Netcore.setting("tight_mb", 900)) * 1048576) / Math.max(1, chart.scale_))
					color: Qt.alpha(Theme.warning, 0.5)
				}

				StyledText {
					anchors.centerIn: parent
					visible: !Netcore.historyLoaded || root.series.length < 2
					text: Netcore.historyLoaded ? "No history yet" : "Reading the history …"
					tone: Theme.textSubtle
					font.pixelSize: Theme.size.small
				}
			}

			RowLayout {
				Layout.fillWidth: true

				StyledText {
					text: "24 h ago"
					tone: Theme.textSubtle
					font.pixelSize: Theme.size.tiny
				}

				Item {
					Layout.fillWidth: true
				}

				StyledText {
					text: "12 h"
					tone: Theme.textSubtle
					font.pixelSize: Theme.size.tiny
				}

				Item {
					Layout.fillWidth: true
				}

				StyledText {
					text: "now"
					tone: Theme.textSubtle
					font.pixelSize: Theme.size.tiny
				}
			}
		}

		// the guard
		Head {
			text: "Memory guard"
		}

		RowLayout {
			Layout.fillWidth: true
			Layout.leftMargin: 12
			Layout.rightMargin: 12
			spacing: 12

			Rectangle {
				Layout.preferredWidth: 10
				Layout.preferredHeight: 10
				radius: 5
				color: Netcore.levelColor(Netcore.level)

				Behavior on color {
					ColorAnim {
						duration: Motion.long
					}
				}
			}

			ColumnLayout {
				Layout.fillWidth: true
				spacing: 1

				StyledText {
					Layout.fillWidth: true
					text: `${Netcore.levelText(Netcore.level)}${Netcore.guard?.since ? ` since ${Netcore.ago(Netcore.guard.since)}` : ""}`
					font.weight: Font.DemiBold
				}

				StyledText {
					Layout.fillWidth: true
					text: root.noPsi
						? `Tight below ${Netcore.setting("tight_mb", 900)} MB free or above ${Netcore.setting("tight_faults", 50)} page faults/s: the NAS pauses its Pi work. Critical below ${Netcore.setting("critical_mb", 450)} MB or above ${Netcore.setting("critical_faults", 250)}/s${Netcore.setting("guard_stop", true) ? ": containers that may be stopped are stopped" : ""}.`
						: `Tight below ${Netcore.setting("tight_mb", 900)} MB free or ${Netcore.setting("tight_psi", 20)} % pressure: the NAS pauses its Pi work. Critical below ${Netcore.setting("critical_mb", 450)} MB or ${Netcore.setting("critical_psi", 10)} % full pressure${Netcore.setting("guard_stop", true) ? ": containers that may be stopped are stopped" : ""}.`
					tone: Theme.textMuted
					font.pixelSize: Theme.size.small
					wrapMode: Text.Wrap
				}
			}
		}

		Repeater {
			model: (Netcore.guard?.actions ?? []).slice(-6).reverse()

			delegate: RowLayout {
				id: action

				required property var modelData

				Layout.fillWidth: true
				Layout.leftMargin: 34
				Layout.rightMargin: 12
				spacing: 10

				Glyph {
					icon: /stop/i.test(String(action.modelData.what)) ? "stop" : (/ok|go on|resume/i.test(String(action.modelData.what)) ? "play" : "pause")
					size: 14
					color: Theme.textMuted
				}

				StyledText {
					Layout.fillWidth: true
					text: String(action.modelData.what ?? "")
					font.pixelSize: Theme.size.small
					elide: Text.ElideRight
				}

				StyledText {
					text: Netcore.ago(action.modelData.at)
					tone: Theme.textSubtle
					font.pixelSize: Theme.size.small
				}
			}
		}

		Note {
			visible: (Netcore.guard?.actions ?? []).length === 0
			text: "The guard has not had to do anything."
		}

		Note {
			visible: (Netcore.guard?.stopped ?? []).length > 0
			text: `Stopped by the guard: ${(Netcore.guard?.stopped ?? []).map(c => typeof c === "object" ? (c.name ?? c.container ?? "") : String(c)).join(", ")} – they stay stopped until started under Services.`
			tone: Theme.warning
		}
	}

	// ── devices ──────────────────────────────────────────────────────────
	SettingCard {
		anchor: "server-devices"
		visible: root.ready
		title: "Devices"
		subtitle: Netcore.devicesLoaded ? `${Netcore.devices.length} with a token · ${Netcore.devices.filter(d => d.online).length} online · the chips are what each may do` : "Reading …"
		icon: "devices"

		Repeater {
			model: Netcore.devices

			delegate: DeviceRow {
				required property var modelData
				required property int index

				device: modelData
				index: index
				choices: root.choices
			}
		}

		Note {
			text: "New devices: the NAS page makes laptop and phone tokens (they get core read too); anything else in the portal."
		}
	}

	// ── sessions ─────────────────────────────────────────────────────────
	SettingCard {
		anchor: "server-sessions"
		visible: root.ready
		title: "Sessions"
		subtitle: Netcore.sessions.length === 0 ? "Nobody is signed in with a browser" : `${Netcore.sessions.length} signed in with a browser`
		icon: "account_multiple"

		trailing: [
			TextButton {
				visible: Netcore.sessions.length > 1 && Netcore.admin
				text: "End the others"
				icon: "logout"
				variant: "ghost"
				confirm: true
				confirmText: "End them?"
				onActivated: Netcore.endOtherSessions()
			}
		]

		Repeater {
			model: Netcore.sessions

			delegate: ListItem {
				id: session

				required property var modelData

				Layout.fillWidth: true
				icon: /android|iphone|mobile/i.test(String(session.modelData.agent ?? "")) ? "cellphone" : "web"
				title: `${session.modelData.user ?? session.modelData.name ?? "?"}${session.modelData.agent ? ` · ${session.modelData.agent}` : ""}`
				subtitle: [session.modelData.current ? "this session" : "", session.modelData.ip ?? "", session.modelData.last_seen ? `active ${Netcore.ago(session.modelData.last_seen)}` : "", session.modelData.created ? `since ${Format.day(Nas.seconds(session.modelData.created))}` : ""].filter(s => s).join(" · ")

				TextButton {
					visible: !session.modelData.current
					text: "End"
					icon: "logout"
					variant: "ghost"
					confirm: true
					confirmText: "End it?"
					onActivated: Netcore.endSession(session.modelData.id)
				}
			}
		}
	}

	// ── the security log ─────────────────────────────────────────────────
	SettingCard {
		anchor: "server-log"
		visible: root.ready
		title: "Security log"
		subtitle: "Sign-ins, devices, containers and the guard – kept 90 days"
		icon: "shield_lock_outline"

		Segmented {
			Layout.fillWidth: true
			Layout.leftMargin: 12
			Layout.rightMargin: 12
			options: [
				{ value: "", label: "All" },
				{ value: "login,login_failed,locked,logout,confirm", label: "Sign-ins" },
				{ value: "device_added,device_revoked,token_rotated,password_changed,totp_on,totp_off,user_added,user_removed", label: "Devices & users" },
				{ value: "container_action,service_down,service_up,pressure", label: "Services & guard" }
			]
			current: Netcore.logKind
			onSelected: value => {
				Netcore.logKind = value;
				Netcore.loadLog();
			}
		}

		Repeater {
			model: Netcore.log

			delegate: LogRow {}
		}

		Note {
			visible: Netcore.logLoaded && Netcore.log.length === 0
			text: "Nothing logged."
		}

		RowLayout {
			Layout.fillWidth: true
			visible: Netcore.log.length >= Netcore.logLimit

			Item {
				Layout.fillWidth: true
			}

			TextButton {
				text: "More"
				icon: "chevron_down"
				variant: "ghost"
				onActivated: {
					Netcore.logLimit += 60;
					Netcore.loadLog();
				}
			}
		}
	}

	component LogRow: RowLayout {
		id: entry

		required property var modelData
		required property int index
		readonly property string kind: String(entry.modelData.kind ?? "")
		// detail is text, or an object for some kinds ({id, name} of a device …)
		readonly property string detail: {
			let d = entry.modelData.detail;
			if (d === undefined || d === null) return "";
			if (typeof d === "string" && d.startsWith("{")) {
				try {
					d = JSON.parse(d);
				} catch (error) {}
			}
			if (typeof d !== "object") return String(d);
			const named = d.name ?? d.service ?? d.user ?? d.container ?? "";
			const extra = [d.action, d.kind, d.level, d.fields ? `(${[].concat(d.fields).join(", ")})` : "", d.status >= 400 ? `failed ${d.status}` : ""].filter(v => v !== undefined && v !== null && v !== "").join(" ");
			return [named, extra].filter(v => v !== "").join(" · ") || Object.keys(d).map(k => `${k} ${typeof d[k] === "object" ? JSON.stringify(d[k]) : d[k]}`).join(", ");
		}
		readonly property bool bad: ["login_failed", "locked", "service_down", "pressure", "device_revoked"].includes(entry.kind)
		property real enter: 0

		Layout.fillWidth: true
		Layout.leftMargin: 12
		Layout.rightMargin: 12
		spacing: 12
		opacity: entry.enter

		NumberAnimation on enter {
			running: true
			from: 0
			to: 1
			duration: Motion.long + Math.min(entry.index, 15) * 25
			easing.type: Easing.BezierSpline
			easing.bezierCurve: Motion.decel
		}

		Rectangle {
			Layout.preferredWidth: 30
			Layout.preferredHeight: 30
			radius: 15
			color: entry.bad ? Qt.alpha(Theme.danger, 0.12) : Theme.layer2

			Glyph {
				anchors.centerIn: parent
				size: 15
				color: entry.bad ? Theme.danger : Theme.textMuted
				icon: ({
					login: "login", logout: "logout", login_failed: "lock_outline", locked: "lock", device_added: "devices", device_revoked: "cellphone_off",
					token_rotated: "key_variant", password_changed: "key_variant", totp_on: "shield_key_outline", totp_off: "shield_outline", user_added: "account_plus",
					user_removed: "account_outline", device_changed: "devices", user_changed: "account_outline", settings_changed: "cog_outline", service_changed: "server", confirm: "shield_check_outline", container_action: "restart", pressure: "memory", service_down: "close_circle_outline", service_up: "check_circle_outline"
				})[entry.kind] ?? "information_outline"
			}
		}

		ColumnLayout {
			Layout.fillWidth: true
			spacing: 0

			StyledText {
				Layout.fillWidth: true
				text: {
					const who = String(entry.modelData.who ?? "");
					const detail = entry.detail;
					switch (entry.kind) {
					case "login": return `${who} signed in`;
					case "logout": return `${who} signed out`;
					case "login_failed": return `Wrong password${who ? ` for ${who}` : ""}`;
					case "locked": return `${who || "A name"} locked for 15 min`;
					case "device_added": return `Device added${detail ? `: ${detail}` : ""}`;
					case "device_revoked": return `Device revoked${detail ? `: ${detail}` : ""}`;
					case "token_rotated": return `New token${detail ? ` for ${detail}` : ""}`;
					case "password_changed": return `${who} changed the password`;
					case "totp_on": return `${who} switched on two-factor`;
					case "totp_off": return `${who} switched off two-factor`;
					case "user_added": return `User added${detail ? `: ${detail}` : ""}`;
					case "user_removed": return `User removed${detail ? `: ${detail}` : ""}`;
					case "confirm": return `${who} confirmed the password`;
					case "container_action": return detail || "A container action";
					case "pressure": return `Memory ${detail || "pressure"}`;
					case "service_down": return `${detail || "A service"} went down`;
					case "service_up": return `${detail || "A service"} is back`;
					case "device_changed": return `Device changed${detail ? `: ${detail}` : ""}`;
					case "user_changed": return `User changed${detail ? `: ${detail}` : ""}`;
					case "settings_changed": return `Settings changed${detail ? `: ${detail}` : ""}`;
					case "service_changed": return `Service changed${detail ? `: ${detail}` : ""}`;
					default: return [entry.kind, detail].filter(s => s).join(": ");
					}
				}
				font.pixelSize: Theme.size.body
				elide: Text.ElideRight
			}

			StyledText {
				Layout.fillWidth: true
				text: [entry.modelData.ip ?? "", ["device_added", "device_revoked", "container_action", "service_down", "service_up", "user_added", "user_removed", "token_rotated", "pressure", "device_changed", "user_changed", "settings_changed", "service_changed"].includes(entry.kind) ? "" : entry.detail, ["container_action", "device_added", "device_revoked"].includes(entry.kind) ? String(entry.modelData.who ?? "") : ""].filter(s => s).join(" · ")
				visible: text !== ""
				tone: Theme.textMuted
				font.pixelSize: Theme.size.small
				elide: Text.ElideRight
			}
		}

		StyledText {
			text: Netcore.ago(entry.modelData.at)
			tone: Theme.textSubtle
			font.pixelSize: Theme.size.small
		}
	}

	// ── users ────────────────────────────────────────────────────────────
	SettingCard {
		anchor: "server-users"
		visible: root.ready
		title: "Users"
		subtitle: "Who signs in with a password – in the portal, the NAS web and every service on core"
		icon: "account"

		Repeater {
			model: Netcore.users

			delegate: ColumnLayout {
				id: user

				required property var modelData
				property bool asking: false
				property bool busy: false
				readonly property string name: String(user.modelData.name ?? "")
				readonly property bool isAdmin: user.modelData.role === "admin"

				Layout.fillWidth: true
				spacing: 4

				ListItem {
					Layout.fillWidth: true
					icon: user.isAdmin ? "shield_account_outline" : "account_outline"
					title: user.name
					subtitle: [user.isAdmin ? "admin" : "user", user.modelData.totp ? "two-factor on" : "no two-factor", user.modelData.created ? `since ${Format.day(Nas.seconds(user.modelData.created))}` : ""].join(" · ")

					TextButton {
						visible: Netcore.admin
						text: user.isAdmin ? "Make user" : "Make admin"
						variant: "ghost"
						onActivated: Netcore.setRole(user.name, user.isAdmin ? "user" : "admin")
					}

					IconButton {
						visible: Netcore.admin
						implicitWidth: 30
						implicitHeight: 30
						icon: "delete_outline"
						variant: "danger"
						onClicked: user.asking = true
					}
				}

				Ask {
					open: user.asking
					busy: user.busy
					icon: "delete_outline"
					title: `Remove ${user.name}?`
					detail: user.isAdmin && Netcore.users.filter(u => u.role === "admin").length <= 1 ? "The last admin – core will not allow it." : "They cannot sign in anywhere anymore; their sessions end."
					confirmText: "Remove"
					onAccepted: {
						user.busy = true;
						Netcore.removeUser(user.name, () => {
							user.busy = false;
							user.asking = false;
						});
					}
					onCancelled: user.asking = false
				}
			}
		}

		RowLayout {
			Layout.fillWidth: true
			Layout.leftMargin: 12
			Layout.rightMargin: 12
			spacing: 8
			visible: Netcore.admin

			Field {
				id: userName

				Layout.preferredWidth: 150
				placeholder: "Name"
				icon: "account_plus"
			}

			Field {
				id: userPassword

				Layout.fillWidth: true
				placeholder: "Password"
				password: true
			}

			Segmented {
				id: userRole

				implicitWidth: 150
				options: [{ value: "user", label: "User" }, { value: "admin", label: "Admin" }]
				current: "user"
				onSelected: value => userRole.current = value
			}

			TextButton {
				text: "Add"
				icon: "account_plus"
				variant: "filled"
				enabled: userName.text.trim() !== "" && userPassword.text.length >= 8
				onActivated: Netcore.addUser(userName.text.trim(), userPassword.text, userRole.current, (data, error) => {
					if (error) return;
					userName.text = "";
					userPassword.text = "";
				})
			}
		}

		Note {
			visible: Netcore.admin
			text: "Passwords need 8 characters. Two-factor is set up by each user in the portal (Security)."
		}
	}

	// ── settings ─────────────────────────────────────────────────────────
	SettingCard {
		anchor: "server-settings"
		visible: root.ready && Netcore.settingsLoaded
		title: "Core settings"
		subtitle: "The same as the portal's; the guard's limits apply at once"
		icon: "cog_outline"

		Head {
			text: "Sign-in"
		}

		Amount {
			key: "session_days"
			fallback: 30
			label: "Stay signed in"
			icon: "key_variant"
			from: 1
			to: 90
			step: 1
			unit: " days"
		}

		Critical {
			key: "totp_required"
			title: "Two-factor for everyone"
			subtitle: "Users without it are asked to set it up after signing in"
			icon: "shield_key_outline"
			onText: "Everyone without two-factor is sent to set it up before anything else works."
			offText: "Passwords alone are enough again for users without two-factor."
		}

		FlagRow {
			Layout.fillWidth: true
			enabled: Netcore.admin
			title: "Tell about new addresses"
			subtitle: "A sign-in from an address not seen before is logged and shown here"
			icon: "login"
			checked: Netcore.setting("alerts.login_new_ip", true) !== false
			onToggled: on => Netcore.setSetting("alerts.login_new_ip", on, false)
		}

		Amount {
			key: "alerts.failed"
			fallback: 3
			label: "Alert after wrong passwords"
			icon: "lock_outline"
			from: 1
			to: 10
			step: 1
			unit: " in 10 min"
		}

		Head {
			text: "Memory guard"
		}

		Amount {
			key: "tight_mb"
			fallback: 900
			label: "Tight below"
			icon: "memory"
			from: 300
			to: 3000
			step: 50
			unit: " MB free"
		}

		Amount {
			key: "critical_mb"
			fallback: 450
			label: "Critical below"
			icon: "memory"
			from: 150
			to: 1500
			step: 50
			unit: " MB free"
		}

		Amount {
			key: "tight_faults"
			visible: root.noPsi
			fallback: 50
			label: "Tight above"
			icon: "gauge"
			from: 10
			to: 500
			step: 10
			unit: " page faults/s"
		}

		Amount {
			key: "critical_faults"
			visible: root.noPsi
			fallback: 250
			label: "Critical above"
			icon: "gauge"
			from: 50
			to: 2000
			step: 50
			unit: " page faults/s"
		}

		Amount {
			key: "tight_psi"
			visible: !root.noPsi
			fallback: 20
			label: "Tight above"
			icon: "gauge"
			from: 5
			to: 80
			step: 1
			unit: " % pressure"
		}

		Amount {
			key: "critical_psi"
			visible: !root.noPsi
			fallback: 10
			label: "Critical above"
			icon: "gauge"
			from: 2
			to: 60
			step: 1
			unit: " % full pressure"
		}

		Critical {
			key: "guard_stop"
			fallback: true
			title: "Stop containers when critical"
			subtitle: "Only those marked “may be stopped” (the NAS's Ollama); never Pi-hole, WireGuard or core"
			icon: "stop"
			onText: "At critical the guard stops those containers; they stay stopped until started by hand."
			offText: "At critical nothing is stopped anymore – the Pi can run out of memory as on 16 November."
		}

		Head {
			text: "History"
		}

		Amount {
			key: "history_days"
			fallback: 7
			label: "Keep health samples"
			icon: "chart_areaspline"
			from: 1
			to: 30
			step: 1
			unit: " days"
		}
	}
}
