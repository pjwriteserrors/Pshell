pragma Singleton

import QtQuick
import Quickshell

// One mouse and keyboard for two PCs (docs/mobile.md, "Mouse across PCs"):
// the edges of this PC's screens that lead to a paired PC. The phone daemon
// reads and grabs the devices and replays them over there; this service
// keeps the settings, lays the strips (KvmEdge.qml) and says where the
// mouse is.
Singleton {
	id: root

	readonly property bool enabled: Pcs.enabled && Plugins.on("pc-mouse")
	readonly property var state: root.enabled ? Phone.kvm : ({ edges: [], strips: [], mode: "local" })
	// [{ output, side, pc }]
	readonly property var edges: root.state.edges ?? []
	readonly property int hold: Number(root.state.hold) || 400
	readonly property bool keyboard: root.state.keyboard !== false
	// "local", "away" (this PC's mouse is on another) or "guest" (another's is here)
	readonly property string mode: String(root.state.mode || "local")
	readonly property string partner: String(root.state.name || "")
	// "output|side|back" for each strip: strings, so the windows stay while nothing changes
	readonly property var strips: (root.state.strips ?? []).map(strip => `${strip.output}|${strip.side}|${strip.back ? 1 : 0}`)

	function edgeAt(output, side) {
		return root.edges.find(edge => edge.output === output && edge.side === side) ?? null;
	}

	function save(changes) {
		Phone.call("kvm", "set", changes, (data, error) => Pcs.report(error));
	}

	// none → each paired PC in turn → none
	function cycle(output, side) {
		const ids = Pcs.devices.map(device => device.id);
		const current = root.edgeAt(output, side);
		const at = current ? ids.indexOf(current.pc) : -1;
		const next = at + 1 < ids.length ? ids[at + 1] : "";
		const rest = root.edges.filter(edge => !(edge.output === output && edge.side === side));
		root.save({ edges: next === "" ? rest : rest.concat([{ output: output, side: side, pc: next }]) });
	}

	function setHold(ms) {
		root.save({ hold: Math.round(ms) });
	}

	function setKeyboard(on) {
		root.save({ keyboard: !!on });
	}

	// the pointer on a strip (KvmEdge.qml); pos along it, 0..1
	function edge(output, side, pos, inside) {
		Phone.call("kvm", "edge", { output: output, side: side, pos: pos, inside: inside });
	}

	function home() {
		Phone.call("kvm", "home", {}, (data, error) => Pcs.report(error));
	}

	Connections {
		target: Phone
		enabled: root.enabled

		function onEvent(topic, name, data, device) {
			if (topic !== "kvm") return;
			if (name === "away") {
				Sounds.play("open");
				Notifs.pushInternal("done", `Mouse on ${data.name}`, data.keyboard ? "The keyboard types there too · Ctrl+Alt+Esc brings both back" : "Ctrl+Alt+Esc brings it back", { icon: "mouse", duration: 3000 });
			} else if (name === "home") {
				Sounds.play("close");
				if (data.reason === "lost") Notifs.pushInternal("error", "Mouse back", `The link to ${data.name} is gone`, { icon: "mouse" });
			} else if (name === "failed") {
				Notifs.pushInternal("error", `The mouse stays here`, `${data.name}: ${data.message}`, { icon: "mouse" });
			}
		}
	}
}
