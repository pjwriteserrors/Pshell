pragma Singleton

import QtQuick
import Quickshell
import qs.style.theme

// pshell-core on netcore (docs/core.md "Shell"): the login, the devices and
// tokens of every service, the services and their state, the Pi's health
// and the memory guard. Everything goes through the NAS daemon (Nas.qml):
// op `corestate` for the state, op `core` for any call of core's API as
// this PC's device, and core's events relayed as `core:<type>`
// (Nas.coreEvent). Nothing here talks to the network itself.
//
// Plugin `netcore`; it only does something while the NAS plugin is on and
// its daemon answers. Notifications: a sign-in from a new address, failed
// sign-ins and locked names, services going down and coming back, memory
// pressure (with what the guard stopped), devices added and revoked.
Singleton {
	id: root

	readonly property bool enabled: Plugins.on("netcore") && Plugins.on("nas")
	// the daemon runs and the NAS is set up: core can be asked
	readonly property bool active: root.enabled && Nas.connected && Nas.configured

	// ── the state (corestate, kept fresh by the events) ────────────────────
	property bool reachable: false
	// core's event stream is up (the state follows it live)
	property bool linked: false
	property bool loaded: false
	property string url: ""
	property string error: ""
	// { user, device, confirmed_until, session }
	property var me: null
	// { level, since, actions: [{ at, what }] }
	property var guard: ({})
	// the newest sample (docs/core.md "Health and the memory guard")
	property var health: ({})
	// [{ name, title, icon, port, state, http, container, url, critical, … }]
	property var services: []

	// ── what the Server page reads, loaded while it shows ────────────────
	property var history: []
	property bool historyLoaded: false
	property var devices: []
	property bool devicesLoaded: false
	property var sessions: []
	property var log: []
	property bool logLoaded: false
	property var users: []
	property var settings: ({})
	property bool settingsLoaded: false
	// how many views show core's details: they are refreshed more often then
	property int watchers: 0

	// ── derived ────────────────────────────────────────────────────────────
	readonly property bool online: root.active && root.reachable
	readonly property string level: String(root.guard?.level ?? "")
	readonly property bool guardOk: root.level === "" || root.level === "ok"
	readonly property bool admin: root.me?.user?.role === "admin" || (root.me?.device?.scopes?.core ?? root.me?.device?.core_caps ?? []).includes("admin")
	readonly property string who: root.me?.user?.name ?? root.me?.device?.name ?? ""
	readonly property real memTotal: Number(root.health?.mem_total) || 0
	readonly property real memAvailable: Number(root.health?.mem_available) || 0
	readonly property real memUsed: Math.max(0, root.memTotal - root.memAvailable)
	readonly property real memFill: root.memTotal > 0 ? root.memUsed / root.memTotal : -1
	readonly property real temp: Number(root.health?.temp) || 0
	readonly property real load1: Number(root.health?.load1) || 0
	readonly property real diskUsed: Number(root.health?.disk?.used) || 0
	readonly property real diskTotal: Number(root.health?.disk?.total) || 0
	readonly property real diskFill: root.diskTotal > 0 ? root.diskUsed / root.diskTotal : -1
	readonly property var down: root.services.filter(service => service.state === "down")
	readonly property var throttled: {
		const value = root.health?.throttled;
		// the firmware's bit field (get_throttled): what holds now
		if (typeof value === "number") return [[0, "under-voltage"], [1, "frequency capped"], [2, "throttled"], [3, "soft temperature limit"]].filter(([bit]) => value & (1 << bit)).map(([, text]) => text);
		if (!value || typeof value !== "object") return [];
		return Object.keys(value).filter(key => value[key] === true).map(key => key.replace(/_/g, " "));
	}
	// "Memory tight", "2 services down", "52 °C · 2.6 GB free"
	readonly property string summary: {
		if (!root.enabled) return "";
		if (!root.active) return Nas.summary;
		if (!root.loaded) return "Asking …";
		if (!root.reachable) return "Core not reachable";
		if (root.level === "critical") return "Memory critical";
		if (root.level === "tight") return "Memory tight";
		if (root.down.length > 0) return `${root.down.length} ${root.down.length === 1 ? "service" : "services"} down`;
		return [root.temp > 0 ? `${Math.round(root.temp)} °C` : "", root.memTotal > 0 ? `${Format.bytes(root.memAvailable)} free` : ""].filter(s => s).join(" · ") || "All well";
	}
	readonly property string portalUrl: {
		if (root.url !== "") return root.url;
		const match = /^(\w+:\/\/[^\/:]+|\w+:\/\/\[[^\]]+\])/.exec(Nas.webUrl());
		return match ? `${match[1]}:8097` : "http://192.168.178.22:8097";
	}

	function levelColor(level) {
		switch (String(level)) {
		case "critical": return Theme.danger;
		case "tight": return Theme.warning;
		case "ok": return Theme.success;
		default: return Theme.textSubtle;
		}
	}

	function levelText(level) {
		switch (String(level)) {
		case "critical": return "Critical";
		case "tight": return "Tight";
		case "ok": return "Fine";
		default: return "Unknown";
		}
	}

	function stateColor(state) {
		switch (String(state)) {
		case "up": return Theme.success;
		case "degraded": return Theme.warning;
		case "down": return Theme.danger;
		case "stopped": return Theme.textSubtle;
		default: return Theme.textFaint;
		}
	}

	function stateText(state) {
		switch (String(state)) {
		case "up": return "Up";
		case "degraded": return "Degraded";
		case "down": return "Down";
		case "stopped": return "Stopped";
		default: return "Unknown";
		}
	}

	// core's service icons are the portal's; the closest of the shell's
	function iconOf(service) {
		const name = String(service?.icon ?? "");
		const map = { shield: "shield_outline", globe: "web", database: "database_outline", folder: "folder_outline", home: "home_outline", calendar: "calendar_month", vpn: "vpn" };
		return map[name] ?? (name !== "" && Icons.glyphs[name] !== undefined ? name : "server");
	}

	function kindIcon(kind) {
		return ({ phone: "cellphone", laptop: "laptop", pc: "monitor" })[String(kind)] ?? "devices";
	}

	function serviceNamed(name) {
		return root.services.find(service => service.name === name) ?? null;
	}

	function ago(value) {
		return Nas.ago(value);
	}

	// a health sample with its memory in bytes: core sends MB (docs/core.md
	// "Additions … server"), the views count bytes like the rest of the shell
	function sample(value) {
		let s = value && typeof value === "object" ? value : {};
		if (s.sample && typeof s.sample === "object") s = s.sample;
		const out = Object.assign({}, s);
		const total = Number(s.mem_total) || 0;
		if (total > 0 && total < 1e7) {
			for (const key of ["mem_total", "mem_available", "mem_available_min", "swap_used"])
				if (s[key] !== undefined && s[key] !== null) out[key] = Number(s[key]) * 1048576;
			if (s.containers && typeof s.containers === "object") {
				const containers = {};
				for (const name of Object.keys(s.containers)) containers[name] = Number(s.containers[name]) * 1048576;
				out.containers = containers;
			}
		}
		return out;
	}

	// ── talking to core through the daemon ─────────────────────────────────
	function list(data, key) {
		if (Array.isArray(data)) return data;
		if (data && Array.isArray(data[key])) return data[key];
		if (data && typeof data === "object" && key === "services") {
			const found = data.services && typeof data.services === "object" ? data.services : data;
			return Object.keys(found).filter(name => found[name] && typeof found[name] === "object").map(name => Object.assign({ name: name }, found[name]));
		}
		return [];
	}

	function errorOf(data, status) {
		if (status === 0) return String(data?.error || "Core did not answer");
		const text = String(data?.error || `HTTP ${status}`);
		if (data?.code === "confirm") return `${text} – core wants the password again; sign in to the portal once`;
		return text;
	}

	// done(data, error, status): data null on an error; `confirmed` says the
	// shell asked the user (X-Pshell-Confirmed, docs/core.md "Identity")
	function call(method, path, body, done, confirmed) {
		const args = { method: String(method || "GET"), path: String(path) };
		if (body !== undefined && body !== null) args.body = body;
		if (confirmed) args.confirmed = true;
		Nas.call("core", args, (data, error) => {
			if (error) {
				if (done) done(null, error, -1);
				return;
			}
			const status = Number(data?.status) || 0;
			if (status === 0 && root.reachable && !root.linked) root.reachable = false;
			const ok = status >= 200 && status < 300;
			if (done) done(ok ? (data?.data ?? {}) : null, ok ? "" : root.errorOf(data?.data, status), status);
		});
	}

	// an error as a toast; a change done as a quiet one
	function report(error, doneText, icon) {
		if (error) Notifs.pushInternal("error", "netcore", error, { icon: "server", app: "netcore" });
		else if (doneText) Notifs.pushInternal("done", doneText, "netcore", { icon: icon || "server", app: "netcore" });
	}

	function refresh(fresh) {
		if (!root.active) return;
		Nas.call("corestate", fresh ? { fresh: true } : {}, (data, error) => {
			if (error) {
				root.error = error;
				root.loaded = true;
				return;
			}
			root.take(data);
		});
	}

	function take(state) {
		if (!state || typeof state !== "object") return;
		root.reachable = !!state.reachable;
		root.linked = !!state.linked;
		root.url = String(state.url ?? "");
		root.error = String(state.error ?? "");
		root.me = state.me ?? null;
		if (state.guard && typeof state.guard === "object") root.guard = state.guard;
		if (state.health && typeof state.health === "object") root.health = root.sample(state.health);
		if (state.services) root.services = root.list(state.services, "services");
		root.loaded = true;
	}

	// ── loading what the page shows ────────────────────────────────────────
	function loadAll() {
		root.refresh(true);
		root.loadHistory();
		root.loadDevices();
		root.loadSessions();
		root.loadLog();
		root.loadUsers();
		root.loadSettings();
		root.loadGuard();
	}

	function loadGuard() {
		root.call("GET", "/api/guard", null, data => {
			if (data) root.guard = data.guard && typeof data.guard === "object" ? data.guard : data;
		});
	}

	function loadHistory() {
		root.call("GET", "/api/health/history?hours=24", null, data => {
			if (!data) return;
			root.history = root.list(data, "samples").map(s => root.sample(s));
			root.historyLoaded = true;
		});
	}

	function loadDevices() {
		root.call("GET", "/api/devices", null, data => {
			if (!data) return;
			root.devices = root.list(data, "devices");
			root.devicesLoaded = true;
		});
	}

	function loadSessions() {
		root.call("GET", "/api/sessions", null, data => {
			if (data) root.sessions = root.list(data, "sessions");
		});
	}

	property string logKind: ""
	property int logLimit: 40

	function loadLog() {
		const query = [`limit=${root.logLimit}`, root.logKind !== "" ? `kind=${encodeURIComponent(root.logKind)}` : ""].filter(s => s).join("&");
		root.call("GET", `/api/log?${query}`, null, data => {
			if (!data) return;
			root.log = Array.isArray(data) ? data : (data.entries ?? data.log ?? []);
			root.logLoaded = true;
		});
	}

	function loadUsers() {
		root.call("GET", "/api/users", null, data => {
			if (data) root.users = root.list(data, "users");
		});
	}

	function loadSettings() {
		root.call("GET", "/api/settings", null, data => {
			if (!data) return;
			root.settings = data.settings && typeof data.settings === "object" ? data.settings : data;
			root.settingsLoaded = true;
		});
	}

	function setting(key, fallback) {
		const value = root.settings[key];
		return value === undefined || value === null ? fallback : value;
	}

	// ── actions ────────────────────────────────────────────────────────────
	function setSetting(key, value, confirmed, done) {
		const before = root.settings[key];
		const next = Object.assign({}, root.settings);
		next[key] = value;
		root.settings = next;
		const body = {};
		body[key] = value;
		root.call("PATCH", "/api/settings", body, (data, error) => {
			if (error) {
				const back = Object.assign({}, root.settings);
				back[key] = before;
				root.settings = back;
				root.report(`Not changed: ${error}`);
			} else if (data && typeof data === "object" && Object.keys(data).length > 1) {
				root.settings = data.settings && typeof data.settings === "object" ? data.settings : data;
			}
			if (done) done(data, error);
		}, confirmed);
	}

	// restart | stop | start | pause | unpause – asked first by the page
	function serviceAction(name, action, done) {
		const service = root.serviceNamed(name);
		const body = { action: String(action) };
		if (service?.critical) body.really = true;
		root.call("POST", `/api/services/${encodeURIComponent(name)}/action`, body, (data, error) => {
			root.report(error, error ? "" : `${service?.title ?? name}: ${({ restart: "restarting", stop: "stopped", start: "starting", pause: "paused", unpause: "going on" })[action] ?? action}`, root.iconOf(service));
			settle.restart();
			if (done) done(data, error);
		}, true);
	}

	// after an action: the state core sees a moment later
	Timer {
		id: settle

		interval: 2500
		onTriggered: root.refresh(true)
	}

	function renameDevice(id, name, done) {
		root.call("PATCH", `/api/devices/${encodeURIComponent(id)}`, { name: String(name) }, (data, error) => {
			root.report(error, "");
			root.loadDevices();
			if (done) done(data, error);
		});
	}

	function setScopes(id, scopes, done) {
		const device = root.devices.find(d => d.id === id);
		if (device) root.devices = root.devices.map(d => d.id === id ? Object.assign({}, d, { scopes: scopes }) : d);
		root.call("PATCH", `/api/devices/${encodeURIComponent(id)}`, { scopes: scopes }, (data, error) => {
			if (error) {
				root.report(`Scopes not changed: ${error}`);
				root.loadDevices();
			}
			if (done) done(data, error);
		});
	}

	// done(token) once with the new token, "" on an error
	function rotateDevice(id, done) {
		root.call("POST", `/api/devices/${encodeURIComponent(id)}/rotate`, {}, (data, error) => {
			root.report(error, "");
			root.loadDevices();
			if (done) done(error ? "" : String(data?.token ?? ""), error);
		}, true);
	}

	function revokeDevice(id, done) {
		root.call("DELETE", `/api/devices/${encodeURIComponent(id)}`, null, (data, error) => {
			root.report(error, "");
			root.loadDevices();
			if (done) done(data, error);
		}, true);
	}

	function endSession(id, done) {
		root.call("DELETE", `/api/sessions/${encodeURIComponent(id)}`, null, (data, error) => {
			root.report(error, "");
			root.loadSessions();
			if (done) done(data, error);
		});
	}

	function endOtherSessions(done) {
		root.call("POST", "/api/sessions/others/end", {}, (data, error) => {
			root.report(error, error ? "" : "Other sessions ended", "logout");
			root.loadSessions();
			if (done) done(data, error);
		});
	}

	function addUser(name, password, role, done) {
		root.call("POST", "/api/users", { name: String(name), password: String(password), role: String(role) }, (data, error) => {
			root.report(error, error ? "" : `${name} can sign in now`, "account");
			root.loadUsers();
			if (done) done(data, error);
		});
	}

	function setRole(name, role, done) {
		root.call("PATCH", `/api/users/${encodeURIComponent(name)}`, { role: String(role) }, (data, error) => {
			root.report(error, "");
			root.loadUsers();
			if (done) done(data, error);
		});
	}

	function removeUser(name, done) {
		root.call("DELETE", `/api/users/${encodeURIComponent(name)}`, null, (data, error) => {
			root.report(error, error ? "" : `${name} removed`, "account");
			root.loadUsers();
			if (done) done(data, error);
		}, true);
	}

	function openPortal(path) {
		Quickshell.execDetached(["xdg-open", root.portalUrl + (path || "/")]);
	}

	function openService(service) {
		const url = String(service?.url ?? "");
		if (url !== "") Quickshell.execDetached(["xdg-open", url]);
	}

	function openSettings() {
		NiriSettings.page = "server";
		Popups.withFocusedScreen(screen => Popups.openModal("niri", screen));
	}

	// ── events ─────────────────────────────────────────────────────────────
	Connections {
		target: Nas
		enabled: root.enabled

		function onCoreEvent(message) {
			root.event(message);
		}
	}

	function event(message) {
		const type = String(message.type ?? String(message.event).slice(5));
		switch (type) {
		case "hello":
			root.reachable = true;
			root.linked = true;
			root.take(Object.assign({ reachable: true, linked: true, url: root.url, error: "", me: root.me }, message));
			break;
		case "link":
			root.linked = !!message.linked;
			if (message.url) root.url = String(message.url);
			if (!message.linked) relook.restart();
			break;
		case "health":
			if (message.sample && typeof message.sample === "object") {
				const sample = root.sample(message.sample);
				root.health = sample;
				root.reachable = true;
				if (root.historyLoaded) {
					const cut = Date.now() / 1000 - 24 * 3600;
					root.history = root.history.filter(sample => Nas.seconds(sample.at) >= cut).concat([sample]);
				}
			}
			break;
		case "service":
			root.serviceChanged(message);
			break;
		case "pressure":
			root.pressure(message);
			break;
		case "login":
			root.loginSeen(message);
			break;
		case "login_failed":
			root.failed(message);
			break;
		case "locked":
			root.notify(`locked-${message.name}-${message.ip}`, "Sign-in locked", `${message.name || "Someone"} from ${message.ip || "somewhere"}: too many wrong passwords, locked for 15 min`, "shield_alert_outline", 2);
			root.logLater();
			break;
		case "device":
			root.deviceChanged(message);
			break;
		}
	}

	// the stream broke: is core still there?
	Timer {
		id: relook

		interval: 3000
		onTriggered: root.refresh(true)
	}

	// the log follows what happened, a moment later
	function logLater() {
		if (root.logLoaded) logLook.restart();
	}

	Timer {
		id: logLook

		interval: 1500
		onTriggered: root.loadLog()
	}

	function serviceChanged(message) {
		const name = String(message.name ?? "");
		const was = String(message.was ?? root.serviceNamed(name)?.state ?? "");
		const state = String(message.state ?? "");
		root.services = root.services.map(service => service.name === name ? Object.assign({}, service, { state: state }) : service);
		const service = root.serviceNamed(name);
		const title = service?.title ?? name;
		if (state === "down" && was !== "down")
			root.notify(`service-${name}`, `${title} is down`, service?.critical ? "It does not answer – the home network depends on it" : "It does not answer its health check", root.iconOf(service), service?.critical ? 2 : 1);
		else if (state === "up" && was === "down")
			root.notify(`service-${name}`, `${title} is back`, "It answers again", root.iconOf(service), 1);
		settle.restart();
		root.logLater();
	}

	function pressure(message) {
		const level = String(message.level ?? "");
		const was = String(message.was ?? root.level);
		root.guard = Object.assign({}, root.guard, { level: level, since: message.at ?? Date.now() / 1000 });
		const free = Number(message.available_mb) || 0;
		if (level === "tight" && was !== "critical")
			root.notify("pressure", "The Pi's memory is tight", `${free > 0 ? `${free} MB free. ` : ""}The NAS pauses its background work until it is fine again.`, "memory", 1);
		else if (level === "critical" && Array.isArray(message.stopped) && message.stopped.length > 0) {
			root.notify("pressure", "The Pi's memory is critical", `${free > 0 ? `${free} MB free. ` : ""}The guard stopped ${message.stopped.join(", ")} – started again by hand (Server page).`, "memory", 2);
		} else if (level === "critical") {
			root.notify("pressure", "The Pi's memory is critical", `${free > 0 ? `${free} MB free. ` : ""}The guard stops what it may stop.`, "memory", 2);
			// what the guard did shows a moment later
			stopped.since = Number(message.at) || Date.now() / 1000;
			stopped.restart();
		}
		root.logLater();
	}

	Timer {
		id: stopped

		property real since: 0
		interval: 4000
		onTriggered: root.call("GET", "/api/guard", null, data => {
			if (!data) return;
			root.guard = data;
			const actions = (data.actions ?? []).filter(action => Nas.seconds(action.at) >= stopped.since - 5).map(action => String(action.what));
			if (actions.length > 0) root.notify("pressure", "The Pi's memory is critical", `The guard: ${actions.join("; ")}. Stopped containers stay stopped until started here.`, "memory", 2);
		})
	}

	// a sign-in: only told when core says the address is new
	function loginSeen(message) {
		const fresh = message.new === true || message.new_ip === true || message.first === true || String(message.address ?? "") === "new";
		if (fresh)
			root.notify(`login-${message.who}-${message.ip}`, `${message.who || "Someone"} signed in from a new address`, `${message.ip || ""}${message.agent ? ` · ${message.agent}` : ""}`, "login", 1);
		if (root.sessions.length > 0) root.loadSessions();
		root.logLater();
	}

	// failed sign-ins: one toast per name and address in ten minutes
	property var failures: ({})

	function failed(message) {
		const key = `${message.name}|${message.ip}`;
		const now = Date.now();
		const seen = root.failures[key];
		const next = Object.assign({}, root.failures);
		next[key] = { count: (seen && now - seen.first < 600000 ? seen.count : 0) + 1, first: seen && now - seen.first < 600000 ? seen.first : now, told: seen?.told ?? 0 };
		root.failures = next;
		if (now - next[key].told > 600000) {
			next[key].told = now;
			root.notify(`failed-${key}`, "A wrong password", `${message.name || "Someone"} from ${message.ip || "somewhere"}`, "shield_alert_outline", 1);
		}
		root.logLater();
	}

	function deviceChanged(message) {
		const device = message.device ?? {};
		const name = String(device.name ?? device.id ?? "A device");
		if (message.action === "added") root.notify(`device-${device.id}`, `${name} was added`, `${device.kind ? `${device.kind} · ` : ""}${Object.keys(device.scopes ?? {}).join(", ")}`, root.kindIcon(device.kind), 1);
		else if (message.action === "revoked") root.notify(`device-${device.id}`, `${name} was revoked`, "Its token does not work anymore", root.kindIcon(device.kind), 1);
		if (root.devicesLoaded) root.loadDevices();
		root.logLater();
	}

	// once per key while the text stays the same
	property var told: ({})

	function notify(key, title, body, icon, urgency) {
		const text = `${title}|${body}`;
		if (root.told[key] === text && key !== "pressure") return;
		root.told[key] = text;
		// toasts take icon-theme names, not the shell's glyphs
		const themed = ({ memory: "dialog-warning", shield_alert_outline: "dialog-password", login: "system-users", cellphone: "phone", laptop: "computer-laptop", monitor: "computer" })[icon] ?? "network-server";
		Notifs.post({
			app: "netcore",
			icon: themed,
			summary: title,
			body: body,
			urgency: urgency ?? 1,
			actions: [{ text: "Open", identifier: "default", invoke: () => root.openSettings() }]
		});
	}

	// ── keeping it fresh ───────────────────────────────────────────────────
	onActiveChanged: if (root.active) root.refresh(true)
	Component.onCompleted: if (root.active) root.refresh(true)

	Connections {
		target: Nas
		enabled: root.enabled

		function onOnlineChanged() {
			if (Nas.online) wake.restart();
		}
	}

	Timer {
		id: wake

		interval: 1500
		onTriggered: root.refresh(true)
	}

	// without the stream: a look now and then (more often while something shows the details)
	Timer {
		running: root.active
		repeat: true
		interval: root.watchers > 0 ? 15000 : (root.linked ? 120000 : 60000)
		onTriggered: root.refresh(root.watchers > 0)
	}

	// the history gets its minute averages from core now and then
	Timer {
		running: root.active && root.watchers > 0
		repeat: true
		interval: 300000
		onTriggered: root.loadHistory()
	}
}
