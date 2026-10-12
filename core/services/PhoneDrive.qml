pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The phone in the file manager: its camera, screenshots, WhatsApp media,
// downloads, videos, music and documents as places, read through the phone
// app (phone-files). Pictures of them come small over the link and are kept
// in the cache; a file that is opened or imported is sent up by the phone
// into a folder the PC names with a ticket of the phone daemon.
Singleton {
	id: root

	readonly property bool enabled: Plugins.on("filemanager") && Plugins.on("phone") && Plugins.on("phone-files")
	readonly property bool reachable: root.enabled && Phone.reachable
	readonly property string name: Phone.name
	readonly property string cache: `${Paths.cache}/phone-files`

	readonly property var collections: [
		{ id: "camera", label: "Camera", icon: "camera_outline" },
		{ id: "screenshots", label: "Screenshots", icon: "cellphone_screenshot" },
		{ id: "whatsapp", label: "WhatsApp", icon: "whatsapp" },
		{ id: "downloads", label: "Downloads", icon: "download" },
		{ id: "videos", label: "Videos", icon: "filmstrip" },
		{ id: "pictures", label: "All pictures", icon: "image_multiple_outline" },
		{ id: "music", label: "Music", icon: "music_note" },
		{ id: "documents", label: "Documents", icon: "file_document_outline" }
	]

	function collectionOf(id) {
		return root.collections.find(entry => entry.id === id) ?? { id: id, label: id, icon: "cellphone" };
	}

	// the phone's error, said so a person understands it
	function problemOf(error) {
		const code = String(error?.code ?? "");
		if (code === "permission") return "permission";
		if (code === "unreachable") return `${root.name} is not connected`;
		return String(error?.message ?? error ?? "The phone did not answer");
	}

	// ── what is on it ──────────────────────────────────────────────────────
	// done(entries, error): entries look like the daemon's, with path "phone:<id>"
	function browse(collection, options, done) {
		const args = Object.assign({ collection: collection, limit: 400 }, options || {});
		Phone.call("phone.files", "browse", args, (data, error) => {
			if (error) {
				done([], root.problemOf(error));
				return;
			}
			const entries = (data?.items ?? []).map(item => root.entryOf(item));
			done(entries, "");
			root.wantThumbs(entries.filter(entry => entry.thumb === "" && /^(image|video|audio)\//.test(entry.mime)).map(entry => entry.phoneId));
		});
	}

	function entryOf(item) {
		const id = String(item.id);
		const known = root.thumbs[id] ?? "";
		return {
			name: String(item.name),
			path: `phone:${id}`,
			phoneId: id,
			dir: false,
			link: false,
			broken: false,
			size: Number(item.size) || 0,
			mtime: Number(item.modified) || 0,
			mime: String(item.mime || ""),
			hidden: false,
			exec: false,
			thumb: known,
			canThumb: false,
			text: false,
			sniff: false,
			key: String(item.name).toLowerCase(),
			// where on the phone, shown like a folder
			folder: String(item.folder || "")
		};
	}

	// ── small pictures ─────────────────────────────────────────────────────
	// phone id → a JPEG in the cache
	property var thumbs: ({})
	property int thumbTick: 0
	property var waiting: []

	function wantThumbs(ids) {
		for (const id of ids) if (!root.thumbs[id] && !root.waiting.includes(id)) root.waiting.push(id);
		if (root.waiting.length > 0 && !thumbTimer.running) thumbTimer.start();
	}

	Timer {
		id: thumbTimer

		interval: 60
		onTriggered: {
			const batch = root.waiting.splice(0, 30);
			if (batch.length === 0) return;
			Phone.call("phone.files", "thumbs", { ids: batch }, (data, error) => {
				const pictures = data?.thumbs ?? {};
				const ids = Object.keys(pictures);
				if (ids.length > 0) Files.request("phonethumbs", { thumbs: pictures }, saved => {
					const next = Object.assign({}, root.thumbs, saved?.paths ?? {});
					root.thumbs = next;
					root.thumbTick += 1;
				});
				if (root.waiting.length > 0) thumbTimer.restart();
			});
		}
	}

	// ── files up to the PC ─────────────────────────────────────────────────
	// ticket → { folder, wanted: count, got: [paths], done(paths) }
	property var transfers: ({})

	// the phone sends the files into folder; done(paths) once all are there
	function fetch(entries, folder, done) {
		const ids = entries.map(entry => entry.phoneId ?? String(entry.path).replace(/^phone:/, ""));
		Phone.call("files", "ticket", { folder: folder }, (data, error) => {
			if (error || !data?.ticket) {
				Files.fail(root.problemOf(error));
				return;
			}
			const ticket = String(data.ticket);
			root.transfers[ticket] = { folder: folder, wanted: ids.length, got: [], done: done, started: Date.now() };
			Phone.call("phone.files", "upload", { ids: ids, ticket: ticket }, (answer, problem) => {
				if (problem) {
					delete root.transfers[ticket];
					Files.fail(root.problemOf(problem));
				}
			});
			root.progressChanged();
		});
	}

	signal progressChanged

	// what is on its way: [{ ticket, folder, wanted, got }]
	readonly property var running: {
		root.progressTick;
		return Object.keys(root.transfers).map(ticket => Object.assign({ ticket: ticket }, root.transfers[ticket]));
	}
	property int progressTick: 0

	Connections {
		target: Phone

		function onEvent(topic, name, data, device) {
			if (topic !== "files" || name !== "received" || !data?.ticket) return;
			const transfer = root.transfers[String(data.ticket)];
			if (!transfer) return;
			transfer.got.push(String(data.path));
			root.progressTick += 1;
			if (transfer.got.length >= transfer.wanted) {
				delete root.transfers[String(data.ticket)];
				root.progressTick += 1;
				if (transfer.done) transfer.done(transfer.got);
			}
		}
	}

	// opens a file of the phone here: it comes into the cache first
	function open(entry) {
		Files.say(`Getting ${entry.name} from ${root.name}…`, "cellphone_arrow_down");
		root.fetch([entry], root.cache, paths => {
			if (paths.length > 0) Files.launch([paths[0]]);
		});
	}

	// ── importing ──────────────────────────────────────────────────────────
	// "~/Pictures/From the phone/2026-10-12" (where imports go by default)
	function importFolder() {
		const base = String(FileLibrary.setting("phoneImportFolder") || `${Files.home}/Pictures/From ${root.name}`);
		return `${base}/${Qt.formatDate(new Date(), "yyyy-MM-dd")}`;
	}

	function importEntries(entries, folder) {
		const target = folder || root.importFolder();
		if (entries.length === 0) return;
		Files.say(entries.length === 1 ? `Importing ${entries[0].name}…` : `Importing ${entries.length} files…`, "cellphone_arrow_down");
		root.fetch(entries, target, paths => {
			Sounds.play("taskDone");
			FileLibrary.set("phoneImportedAt", Math.floor(Date.now() / 1000));
			Notifs.pushInternal("done", paths.length === 1 ? "Imported from the phone" : `${paths.length} files imported from the phone`, Files.pretty(target), {
				icon: "cellphone_arrow_down",
				actions: [{ label: "Show", icon: "folder_open_outline", run: () => Files.reveal(paths) }]
			});
		});
	}

	// new camera pictures since the last import, for the home page
	property var fresh: []

	function checkFresh() {
		if (!root.reachable) {
			root.fresh = [];
			return;
		}
		const since = Number(FileLibrary.setting("phoneImportedAt")) || Math.floor(Date.now() / 1000) - 3 * 86400;
		root.browse("camera", { since: since, limit: 60 }, (entries, error) => root.fresh = error ? [] : entries);
	}

	onReachableChanged: if (root.reachable) freshTimer.restart()

	Timer {
		id: freshTimer

		interval: 3000
		onTriggered: root.checkFresh()
	}
}
