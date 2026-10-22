pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The clipboard history, the shell's own (scripts/clipboard): its daemon
// keeps every copy as a file and an index, which is read here whenever it
// changes. Restoring, deleting and wiping go through the daemon.
Singleton {
	id: root

	readonly property bool enabled: Plugins.on("clipboard")
	readonly property string folder: `${Quickshell.env("XDG_CACHE_HOME") || Paths.home + "/.cache"}/pshell/clipboard`
	// [{ id, kind, mime, preview, isImage, extension, meta, path, previewPath, time }], newest first
	property var entries: []
	readonly property bool loading: false

	function parse(raw) {
		let list = [];
		try {
			list = JSON.parse(raw || "[]");
		} catch (error) {
			return;
		}
		root.entries = (Array.isArray(list) ? list : []).map(entry => {
			const isImage = entry.kind === "image";
			const path = `${root.folder}/items/${entry.file ?? entry.id}`;
			const extension = isImage ? String(entry.file ?? "").split(".").pop() : "";
			return {
				id: String(entry.id),
				kind: entry.kind,
				mime: entry.mime,
				// copied files read as their uris, the way they came
				preview: isImage ? "" : String(entry.preview ?? ""),
				isImage: isImage,
				extension: extension,
				meta: isImage ? [extension.toUpperCase(), entry.width ? `${entry.width}x${entry.height}` : "", Format.bytes(entry.size)].filter(v => v !== "").join(" · ") : "",
				path: path,
				previewPath: isImage ? path : "",
				time: Number(entry.time || 0)
			};
		});
	}

	function send(command) {
		if (daemon.running) daemon.write(JSON.stringify(command) + "\n");
	}

	// the list is read as it changes; kept for callers of old
	function refresh() {
		index.reload();
	}

	// the newest image or text of the history becomes the clipboard again
	function restoreLatest(kind) {
		root.send({ op: "latest", kind: kind });
	}

	function restore(entry) {
		if (entry?.id !== undefined) root.send({ op: "restore", id: Number(entry.id) });
	}

	function remove(entry) {
		if (entry?.id === undefined) return;
		root.send({ op: "delete", ids: [Number(entry.id)] });
		root.entries = root.entries.filter(e => e.id !== entry.id);
	}

	function wipe() {
		root.send({ op: "wipe" });
		root.entries = [];
	}

	Process {
		id: daemon

		running: root.enabled
		stdinEnabled: true
		command: ["python3", "-u", `${Paths.scripts}/clipboard/history.py`]
		stdout: SplitParser {
			// the index file is watched; this only makes sure of it
			onRead: line => {
				if (line.indexOf('"added"') >= 0) index.reload();
			}
		}
		onExited: if (root.enabled) revive.restart()
	}

	Timer {
		id: revive

		interval: 3000
		onTriggered: daemon.running = root.enabled
	}

	FileView {
		id: index

		path: root.enabled ? `${root.folder}/index.json` : ""
		watchChanges: true
		printErrors: false
		onFileChanged: index.reload()
		onLoaded: root.parse(index.text())
	}
}
