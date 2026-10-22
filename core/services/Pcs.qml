pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The other PCs with Pshell this one is paired with (docs/mobile.md, "Other
// PCs"): the phone daemon holds a link to each, this service asks it to send
// files, folders, links and text over, and says what arrived. A PC that
// shares its files (pc-fs, switched on over there) can be walked through in
// the file manager.
Singleton {
	id: root

	readonly property bool enabled: Phone.enabled && Plugins.on("pc-link")
	// [{ id, name, connected, incoming, address, files, nearby, error, paired, seen }]
	readonly property var devices: root.enabled ? (Phone.pcs.devices ?? []) : []
	// PCs with Pshell on the LAN that are not paired: [{ id, name, addresses, port }]
	readonly property var nearby: root.enabled ? (Phone.pcs.nearby ?? []) : []
	// [{ transfer, id, direction, count, size, done, files, name }]
	readonly property var transfers: root.enabled ? (Phone.pcs.transfers ?? []) : []
	readonly property var reachable: root.devices.filter(device => device.connected)
	readonly property string cache: `${Paths.cache}/pc-files`

	function byId(id) {
		return root.devices.find(device => device.id === id) ?? null;
	}

	// a connected one by its name or the start of its id; "" is the first
	function find(pc) {
		const value = String(pc || "").toLowerCase();
		return root.reachable.find(device => value === "" || device.name.toLowerCase() === value || device.id.startsWith(value)) ?? null;
	}

	function nameOf(id) {
		return root.byId(id)?.name ?? "the other PC";
	}

	function report(error) {
		if (error) Notifs.pushInternal("error", "Other PC", error.code === "unreachable" ? String(error.message || "Not connected") : String(error.message || error.code), { icon: "laptop" });
	}

	// ── pairing ────────────────────────────────────────────────────────────
	// target: { nearby: id } | { address: "host[:port]" } | { link: "pshell://pair?…" }
	function pair(code, target, done) {
		Phone.call("pcs", "pair", Object.assign({ code: String(code || "") }, target || {}), (data, error) => {
			if (!error) {
				Sounds.play("taskDone");
				Notifs.pushInternal("done", `Paired with ${data?.name ?? "the PC"}`, "Files, links and text can go over now", { icon: "laptop" });
			}
			if (done) done(data, error);
		}, { timeout: 40 });
	}

	function remove(id) {
		Phone.call("pcs", "remove", { id: id }, (data, error) => root.report(error));
	}

	// ── sending ────────────────────────────────────────────────────────────
	// files and folders go into the other PC's downloads folder, or into a
	// folder of its shared ones (into, relative to it)
	function sendFiles(id, paths, into) {
		const clean = paths.map(path => decodeURIComponent(String(path).replace(/^file:\/\//, ""))).filter(path => path !== "");
		if (clean.length === 0) return;
		const args = { id: id, paths: clean };
		if (into !== undefined && into !== null) args.into = String(into);
		Phone.call("pcs", "send", args, (data, error) => {
			if (error) return root.report(error);
			Notifs.pushInternal("running", `To ${root.nameOf(id)}`, data.count === 1 ? `${root.baseName(clean[0])} · ${Format.bytes(data.size)}` : `${data.count} files · ${Format.bytes(data.size)}`, { icon: "laptop", duration: 4000 });
		}, { timeout: 30 });
	}

	function sendText(id, text) {
		const value = String(text || "").trim();
		if (value === "") return;
		Phone.call("pcs", "text", { id: id, text: value }, (data, error) => {
			if (error) return root.report(error);
			Notifs.pushInternal("done", data?.opened ? `Opened on ${root.nameOf(id)}` : `In the clipboard of ${root.nameOf(id)}`, value.length > 80 ? value.slice(0, 80) + "…" : value, { icon: "laptop" });
		}, { timeout: 20 });
	}

	// the PC's clipboard, over to the other one
	function sendClipboard(id) {
		clipboardReader.target = id;
		clipboardReader.running = true;
	}

	Process {
		id: clipboardReader

		property string target: ""

		command: ["wl-paste", "--no-newline", "--type", "text"]
		stdout: StdioCollector {
			onStreamFinished: root.sendText(clipboardReader.target, text)
		}
	}

	function cancel(transfer) {
		Phone.call("pcs", "cancel", { transfer: transfer });
	}

	// ── its shared folder ──────────────────────────────────────────────────
	// done(entries, error, info): entries look like the file manager's, with
	// path "pc:<id>/<path there>"
	function browse(id, path, done) {
		Phone.call("pcs", "list", { id: id, path: String(path || "") }, (data, error) => {
			if (error) {
				const code = String(error.code || "");
				done([], code === "plugin-off" ? `${root.nameOf(id)} does not share its files: switch on “Files for other PCs” there (Settings → Plugins → Phone)`
					: code === "unreachable" ? `${root.nameOf(id)} is not connected` : String(error.message || code), {});
				return;
			}
			const base = String(data?.path ?? "");
			done((data?.entries ?? []).map(item => root.entryOf(id, base, item)), "", { root: String(data?.root ?? "") });
		}, { timeout: 25 });
	}

	function entryOf(id, base, item) {
		const relative = base === "" ? String(item.name) : `${base}/${item.name}`;
		return {
			name: String(item.name),
			path: `pc:${id}/${relative}`,
			pcId: id,
			pcPath: relative,
			dir: !!item.dir,
			link: false,
			broken: false,
			size: Number(item.size) || 0,
			mtime: Math.floor((Number(item.modified) || 0) / 1000),
			mime: item.dir ? "inode/directory" : "",
			hidden: String(item.name).startsWith("."),
			exec: false,
			thumb: "",
			canThumb: false,
			text: false,
			sniff: false,
			key: String(item.name).toLowerCase()
		};
	}

	// "pc:<id>/<path>" → { id, path }
	function split(path) {
		const match = String(path).match(/^pc:([0-9a-f]+)\/?(.*)$/);
		return match ? { id: match[1], path: match[2] } : null;
	}

	// fetches files and folders of its shared folder into a folder here;
	// done(paths) with what arrived on top (files, folders)
	property var fetches: ({})

	function fetch(id, paths, folder, done) {
		Phone.call("pcs", "fetch", { id: id, paths: paths, folder: folder }, (data, error) => {
			if (error) return root.report(error);
			if (done) root.fetches[data.transfer] = done;
		}, { timeout: 70 });
	}

	// opens a file of the other PC here: it comes into the cache first
	function open(id, path) {
		const folder = `${root.cache}/${Date.now()}`;
		root.fetch(id, [path], folder, paths => {
			if (paths.length > 0) Qt.openUrlExternally(`file://${paths[0]}`);
		});
	}

	// ── what the daemon says ───────────────────────────────────────────────
	function baseName(path) {
		return String(path).replace(/\/$/, "").replace(/^.*\//, "");
	}

	function folderOf(path) {
		return String(path).replace(/\/[^/]*$/, "") || "/";
	}

	Connections {
		target: Phone
		enabled: root.enabled

		function onEvent(topic, name, data, device) {
			if (topic !== "pcs") return;
			switch (name) {
			case "received": {
				const paths = (data.paths ?? []).map(path => String(path));
				if (paths.length === 0) break;
				const one = paths.length === 1 ? paths[0] : "";
				const image = /\.(png|jpe?g|webp|gif)$/i.test(one);
				Sounds.play("taskDone");
				Notifs.pushInternal(data.stopped ? "error" : "done",
					one !== "" ? root.baseName(one) : `${data.files} files`,
					`${data.stopped ? "Stopped on its way, from" : "From"} ${data.name} · ${Format.bytes(data.size)}`, {
					icon: "laptop",
					image: image ? one : "",
					duration: 9000,
					actions: [
						one !== "" ? { label: "Open", icon: "open_in_new", run: () => Qt.openUrlExternally(`file://${one}`) } : null,
						{ label: "Folder", icon: "folder_outline", run: () => Qt.openUrlExternally(`file://${one !== "" ? root.folderOf(one) : String(data.folder)}`) }
					].filter(action => action !== null)
				});
				break;
			}
			case "sent":
				Notifs.pushInternal(data.stopped ? "error" : "done", data.stopped ? `Stopped: ${data.files} of ${data.count} sent` : (data.count === 1 ? "Sent" : `${data.count} files sent`), `To ${data.name}`, { icon: "laptop" });
				break;
			case "failed":
				Notifs.pushInternal("error", `Not all came over (${data.files} of ${data.count})`, `${data.name}: ${data.message}`, { icon: "laptop", duration: 9000 });
				break;
			case "fetched": {
				const done = root.fetches[data.transfer];
				delete root.fetches[data.transfer];
				const paths = (data.paths ?? []).map(path => String(path));
				if (done) done(paths);
				else if (paths.length > 0) Notifs.pushInternal("done", paths.length === 1 ? root.baseName(paths[0]) : `${data.files} files`, `From ${data.name}`, {
					icon: "laptop",
					actions: [{ label: "Folder", icon: "folder_outline", run: () => Qt.openUrlExternally(`file://${data.folder}`) }]
				});
				break;
			}
			case "copied":
				Notifs.pushInternal("done", `Clipboard from ${data.name}`, String(data.text || ""), { icon: "content_paste" });
				break;
			case "incoming":
				if (Number(data.size) > 50 * 1024 * 1024)
					Notifs.pushInternal("running", `From ${data.name}`, `${data.count === 1 ? "A file" : `${data.count} files`} · ${Format.bytes(data.size)} on the way`, { icon: "laptop" });
				break;
			}
		}
	}
}
