pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// cliphist history: list, restore, delete, wipe. Image entries are decoded
// to /tmp on demand for thumbnails.
Singleton {
	id: root

	property var entries: []
	readonly property bool loading: listProc.running

	function shellEscape(value) {
		return String(value).replace(/'/g, `'"'"'`);
	}

	function imageExtension(preview) {
		const text = String(preview || "").toLowerCase();
		if (text.includes(" png ")) return "png";
		if (text.includes(" jpeg ") || text.includes(" jpg ")) return "jpg";
		if (text.includes(" webp ")) return "webp";
		if (text.includes(" gif ")) return "gif";
		return "";
	}

	function parse(raw) {
		const next = [];
		for (const line of String(raw || "").split("\n")) {
			if (line.trim() === "") continue;
			const match = line.match(/^(\d+)\s+(.*)$/);
			if (!match) continue;
			const preview = match[2];
			const extension = root.imageExtension(preview);
			const isImage = preview.startsWith("[[ binary data") && extension !== "";
			const size = isImage ? (preview.match(/(\d+(?:\.\d+)?\s*[KMG]i?B)/) || [""])[0] : "";
			const dims = isImage ? (preview.match(/(\d+x\d+)/) || [""])[0] : "";
			next.push({
				id: match[1],
				preview: preview,
				raw: line,
				isImage: isImage,
				extension: extension,
				meta: [extension.toUpperCase(), dims, size].filter(v => v !== "").join(" · "),
				previewPath: isImage ? `/tmp/qs-cliphist-preview-${match[1]}.${extension}` : ""
			});
		}
		root.entries = next;
	}

	function refresh() {
		listProc.running = true;
	}

	function restore(entry) {
		if (!entry?.raw) return;
		Quickshell.execDetached(["sh", "-lc", `printf '%s\n' '${root.shellEscape(entry.raw)}' | cliphist decode | wl-copy`]);
	}

	function remove(entry) {
		if (!entry?.raw) return;
		Quickshell.execDetached(["sh", "-lc", `printf '%s\n' '${root.shellEscape(entry.raw)}' | cliphist delete`]);
		root.entries = root.entries.filter(e => e.raw !== entry.raw);
	}

	function wipe() {
		Quickshell.execDetached(["sh", "-lc", "cliphist wipe"]);
		root.entries = [];
	}

	function decodeCommand(entry) {
		return ["sh", "-lc", `[ -s '${root.shellEscape(entry.previewPath)}' ] || printf '%s\n' '${root.shellEscape(entry.raw)}' | cliphist decode > '${root.shellEscape(entry.previewPath)}'`];
	}

	Process {
		id: listProc
		command: ["sh", "-lc", "cliphist list"]
		stdout: StdioCollector {
			onStreamFinished: root.parse(text)
		}
	}
}
