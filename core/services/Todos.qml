pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// Markdown todo lists in ~/todo (plain files, with or without .md – the
// Mod+T keybind creates them with nano). Lists the files with their task
// counts, parses and edits task lines, and remembers which lists are pinned
// to the desktop and where (todo-pins.json in the shell dir).
Singleton {
	id: root

	readonly property string dir: `${Quickshell.env("HOME")}/todo`
	readonly property string pinsPath: Paths.stateFile("todo-pins.json")

	// [{ name, path, total, done, modified }] sorted by name
	property var lists: []
	property bool loading: false
	// [{ path, x, y }]
	property var pins: []
	property bool pinsLoaded: false

	signal listCreated(string path)

	readonly property var taskPattern: /^(\s*)[-*+]\s+\[([ xX])\](?:\s+(.*))?$/

	function displayName(path) {
		const base = String(path || "").split("/").pop();
		return base.replace(/\.(md|markdown)$/i, "");
	}

	function refresh() {
		if (listProc.running) {
			listProc.again = true;
			return;
		}
		root.loading = true;
		listProc.running = true;
	}

	function parseLists(raw) {
		const lists = [];
		for (const record of String(raw || "").split("\x1e")) {
			const fields = record.replace(/^\n/, "").split("\x1f");
			if (fields.length < 4 || fields[1] === "") continue;
			lists.push({
				modified: Number(fields[0]) || 0,
				path: fields[1],
				name: root.displayName(fields[1]),
				total: Number(fields[2]) || 0,
				done: Number(fields[3]) || 0
			});
		}
		lists.sort((left, right) => left.name.localeCompare(right.name));
		root.lists = lists;
	}

	// ── markdown ──────────────────────────────────────────────────────────
	// one entry per line: { line, kind: heading|task|bullet|code|text|blank,
	// level, indent, done, text }
	function parse(text) {
		const out = [];
		const lines = String(text || "").replace(/\r\n/g, "\n").split("\n");
		if (lines.length > 0 && lines[lines.length - 1] === "") lines.pop();
		let fence = false;
		for (let i = 0; i < lines.length; i += 1) {
			const line = lines[i];
			if (/^\s*(```|~~~)/.test(line)) {
				fence = !fence;
				continue;
			}
			if (fence) {
				out.push({ line: i, kind: "code", level: 0, indent: 0, done: false, text: line });
				continue;
			}
			if (line.trim() === "") {
				out.push({ line: i, kind: "blank", level: 0, indent: 0, done: false, text: "" });
				continue;
			}
			const heading = /^(#{1,6})\s+(.*)$/.exec(line);
			if (heading) {
				out.push({ line: i, kind: "heading", level: heading[1].length, indent: 0, done: false, text: heading[2].replace(/\s+#+\s*$/, "") });
				continue;
			}
			const task = root.taskPattern.exec(line);
			if (task) {
				out.push({ line: i, kind: "task", level: 0, indent: Math.floor(task[1].replace(/\t/g, "  ").length / 2), done: task[2] !== " ", text: task[3] || "" });
				continue;
			}
			const bullet = /^(\s*)(?:[-*+]|(\d+[.)]))\s+(.*)$/.exec(line);
			if (bullet) {
				out.push({ line: i, kind: "bullet", level: 0, indent: Math.floor(bullet[1].replace(/\t/g, "  ").length / 2), done: false, text: bullet[3], marker: bullet[2] || "" });
				continue;
			}
			out.push({ line: i, kind: "text", level: 0, indent: 0, done: false, text: line.trim() });
		}
		return out;
	}

	function counts(text) {
		let total = 0;
		let done = 0;
		for (const line of String(text || "").split("\n")) {
			const task = root.taskPattern.exec(line.replace(/\r$/, ""));
			if (!task) continue;
			total += 1;
			if (task[2] !== " ") done += 1;
		}
		return { total, done };
	}

	function escapeHtml(text) {
		return String(text || "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
	}

	// inline markdown → Qt StyledText: `code`, **bold**, *italic*, ~~strike~~, [links](url)
	function inline(text, codeColor, mono) {
		const parts = String(text || "").split("`");
		let html = "";
		for (let i = 0; i < parts.length; i += 1) {
			const part = root.escapeHtml(parts[i]);
			if (i % 2 === 1 && i < parts.length - 1) {
				html += `<font face="${mono}" color="${codeColor}">${part}</font>`;
				continue;
			}
			html += (i % 2 === 1 ? "`" : "") + part
				.replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, (match, label, url) => `<a href="${url.replace(/"/g, "%22")}">${label}</a>`)
				.replace(/(\*\*|__)(\S(?:.*?\S)??)\1/g, "<b>$2</b>")
				.replace(/(^|[^\w*])\*(\S(?:.*?\S)??)\*(?![\w*])/g, "$1<i>$2</i>")
				.replace(/(^|\W)_(\S(?:.*?\S)??)_(?!\w)/g, "$1<i>$2</i>")
				.replace(/~~(\S(?:.*?\S)??)~~/g, "<s>$1</s>");
		}
		return html;
	}

	// ── edits (pure: text in, text out) ───────────────────────────────────
	function toggled(text, lineIndex) {
		const lines = String(text || "").split("\n");
		const line = lines[lineIndex];
		if (line === undefined) return String(text || "");
		lines[lineIndex] = line.replace(/^(\s*[-*+]\s+\[)([ xX])(\])/, (match, head, mark, tail) => `${head}${mark === " " ? "x" : " "}${tail}`);
		return lines.join("\n");
	}

	function withTask(text, task) {
		const value = String(text || "");
		const entry = `- [ ] ${String(task || "").trim()}\n`;
		if (value === "" || value.endsWith("\n")) return value + entry;
		return `${value}\n${entry}`;
	}

	// plays the list-done haptic when an edit checks off the last open task
	function noteEdit(before, after) {
		const was = root.counts(before);
		const now = root.counts(after);
		if (now.total > 0 && now.done === now.total && was.done < was.total)
			Haptics.play("listDone");
	}

	function fileNameFor(name) {
		return String(name || "").trim().replace(/\//g, "-").replace(/^\.+/, "");
	}

	// creates ~/todo/<name> (and the folder) with optional first content and
	// returns its path; listCreated(path) follows once the file exists
	function createList(name, initialText) {
		const file = root.fileNameFor(name);
		if (file === "") return "";
		const path = `${root.dir}/${file}`;
		const existing = root.lists.find(list => list.path === path || list.path === `${path}.md`);
		if (existing) return existing.path;
		const proc = writer.createObject(root, { path });
		proc.command = ["sh", "-c", 'mkdir -p "$1" && { [ -e "$2" ] || printf "%s" "$3" > "$2"; }', "sh", root.dir, path, String(initialText || "")];
		proc.running = true;
		const counts = root.counts(initialText);
		const next = root.lists.concat([{ modified: Date.now() / 1000, path, name: root.displayName(path), total: counts.total, done: counts.done }]);
		next.sort((left, right) => left.name.localeCompare(right.name));
		root.lists = next;
		return path;
	}

	// ── desktop pins ──────────────────────────────────────────────────────
	function isPinned(path) {
		return root.pins.some(pin => pin.path === path);
	}

	function pin(path) {
		if (path === "" || root.isPinned(path)) return;
		const offset = root.pins.length * 36;
		root.savePins(root.pins.concat([{ path, x: 80 + offset, y: 90 + offset }]));
	}

	function unpin(path) {
		root.savePins(root.pins.filter(pin => pin.path !== path));
	}

	function togglePin(path) {
		if (root.isPinned(path)) root.unpin(path);
		else root.pin(path);
	}

	function movePin(path, x, y) {
		root.savePins(root.pins.map(pin => pin.path === path ? { path, x: Math.round(x), y: Math.round(y) } : pin));
	}

	function savePins(next) {
		root.pins = next;
		pinsFile.setText(JSON.stringify(next, null, 2));
	}

	FileView {
		id: pinsFile

		path: root.pinsPath
		printErrors: false
		watchChanges: true
		onFileChanged: reload()
		onLoaded: {
			try {
				const data = JSON.parse(text());
				root.pins = Array.isArray(data) ? data.filter(pin => pin && pin.path).map(pin => ({
					path: String(pin.path),
					x: Number(pin.x) || 0,
					y: Number(pin.y) || 0
				})) : [];
			} catch (error) {
				root.pins = [];
			}
			root.pinsLoaded = true;
		}
		onLoadFailed: {
			root.pins = [];
			root.pinsLoaded = true;
		}
	}

	Process {
		id: listProc

		property bool again: false

		command: ["sh", "-c", `
			[ -d "$1" ] || exit 0
			find "$1" -maxdepth 1 -type f ! -name '.*' ! -name '*~' ! -name '*.swp' ! -name '*.tmp' -printf '%T@\\t%p\\n' |
			while IFS="$(printf '\\t')" read -r modified path; do
				total=$(grep -cE '^[[:space:]]*[-*+][[:space:]]+\\[[ xX]\\]' "$path")
				checked=$(grep -cE '^[[:space:]]*[-*+][[:space:]]+\\[[xX]\\]' "$path")
				printf '%s\\037%s\\037%s\\037%s\\036' "$modified" "$path" "$total" "$checked"
			done`, "sh", root.dir]
		stdout: StdioCollector {
			onStreamFinished: root.parseLists(text)
		}
		onExited: {
			root.loading = false;
			if (listProc.again) {
				listProc.again = false;
				root.refresh();
			}
		}
	}

	Component {
		id: writer

		Process {
			id: proc

			property string path: ""

			onExited: {
				root.listCreated(proc.path);
				root.refresh();
				proc.destroy();
			}
		}
	}

	Component.onCompleted: root.refresh()
}
