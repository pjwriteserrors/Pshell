pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.style.theme

// Tasks and notes of the todos plugin, both plain markdown in ~/todo:
//
// Tasks.md holds every task. A `## heading` is a group, a `###` below it one
// of the group's categories (the tasks below it are in it); a task is `- [m] text`, its mark the state (`/` in progress, `x`
// done …, as Obsidian writes them), the lines indented below it its
// description, ⏫ 🔼 🔽 at its end the priority (as the Obsidian Tasks
// plugin writes it) and every [[name]] in it a note it has.
//
// notes/ holds the notes, one markdown file each; a note knows its tasks by
// the links to it. Also here: the editor window of a note (TodoEditor), what
// is pinned to the desktop and how (todo-pins.json: note paths, overviewKey
// for every group, groupKey(name) for one), the folded headings
// (todo-folds.json) and the way into the launcher at a task or note.
//
// A task that is added (or moved to another group) is sorted into one of its
// group's categories by a local model (scripts/todos/classify.py, Ollama;
// plugin todo-ai), which gets its title, description and linked notes.
Singleton {
	id: root

	readonly property string dir: `${Quickshell.env("HOME")}/todo`
	readonly property string tasksPath: `${root.dir}/Tasks.md`
	readonly property string notesDir: `${root.dir}/notes`
	readonly property string pinsPath: Paths.stateFile("todo-pins.json")
	readonly property string foldsPath: Paths.stateFile("todo-folds.json")
	// the group of tasks that come without one
	readonly property string inbox: "Inbox"
	// pin keys of the boards: every group, one group
	readonly property string overviewKey: "@open"

	function groupKey(name) {
		return `@group:${name}`;
	}

	function isGroupKey(key) {
		return String(key).startsWith("@group:");
	}

	function groupOfKey(key) {
		return String(key).slice(7);
	}

	// ── state ─────────────────────────────────────────────────────────────
	property string tasksText: ""
	property bool tasksLoaded: false
	// { groups: [{ name, line, open, done, tasks }], tasks: [task] } – see buildBoard()
	readonly property var board: root.buildBoard(root.tasksText)
	readonly property var groups: root.board.groups
	readonly property var tasks: root.board.tasks
	readonly property var openTasks: root.board.tasks.filter(task => !task.closed)
	// [{ name, path, modified }] sorted by name
	property var notes: []
	property bool notesLoaded: false
	// [{ path, x, y, w, h, collapsed }]; path is a note path or a board key; w and h 0 while the widget has its own size
	property var pins: []
	property bool pinsLoaded: false
	// { key: ["<level>:<heading>", …] } of the folded headings (key: note path or groupKey)
	property var folds: ({})

	// the editor window: open on editorPath ("" names a new note first)
	property bool editorOpen: false
	property string editorPath: ""
	// line to put the cursor on, -1 for the end
	property int editorLine: -1

	// what the launcher is to show when it opens on >todo: "tasks" or "notes"
	property string launcherTab: "tasks"
	// where the launcher is to go: { kind: "task", key } or { kind: "note", path }, with a stamp
	property var target: null

	signal noteCreated(string path)
	// a pinned widget is to show itself (and the task, when one is named)
	signal highlightRequested(string pinKey, string taskKey)
	// the editor is asked for again while it is open: raise it, go to editorLine
	signal editorRequested

	// ── states and priorities ─────────────────────────────────────────────
	readonly property var taskPattern: /^(\s*)[-*+]\s+\[(.)\](?:\s+(.*))?$/
	// the marks a task can carry, in the order the pickers show them
	readonly property var states: [
		{ mark: " ", name: "Open", icon: "checkbox_blank_outline" },
		{ mark: "/", name: "In progress", icon: "progress_clock" },
		{ mark: "!", name: "Important", icon: "alert_box_outline" },
		{ mark: "?", name: "Question", icon: "help_circle_outline" },
		{ mark: ">", name: "Later", icon: "arrow_right_bold_box_outline" },
		{ mark: "r", name: "Ready to ship", icon: "rocket_launch_outline" },
		{ mark: "x", name: "Done", icon: "checkbox_marked" },
		{ mark: "-", name: "Cancelled", icon: "close_box_outline" }
	]

	function state(mark) {
		const key = mark === "X" ? "x" : mark;
		return root.states.find(entry => entry.mark === key) ?? root.states[0];
	}

	function isDone(mark) {
		return mark === "x" || mark === "X";
	}

	function markColor(mark) {
		switch (mark) {
		case "/":
			return Theme.warning;
		case "!":
			return Theme.danger;
		case "?":
			return Theme.secondary;
		case ">":
			return Theme.tertiary;
		case "r":
			return Theme.success;
		case "x":
		case "X":
			return Theme.primary;
		case "-":
			return Theme.textSubtle;
		default:
			return Theme.textMuted;
		}
	}

	// highest first; level 0 is none
	readonly property var priorities: [
		{ level: 3, name: "High", icon: "chevron_double_up", sign: "⏫" },
		{ level: 2, name: "Medium", icon: "chevron_up", sign: "🔼" },
		{ level: 1, name: "Low", icon: "chevron_down", sign: "🔽" }
	]
	// 🔺 ⏫ 🔼 🔽 ⏬ (🔺 and ⏬ read as high and low)
	readonly property var priorityPattern: /[ \t]*(🔺|⏫|🔼|🔽|⏬)️?/g
	// [[name]], [[name|label]], [[name#part]]
	readonly property var linkPattern: /[ \t]*\[\[([^\]|#]+)(?:[|#][^\]]*)?\]\]/g

	function priorityOf(text) {
		let level = 0;
		String(text || "").replace(root.priorityPattern, (match, sign) => {
			const value = sign === "⏫" || sign === "🔺" ? 3 : (sign === "🔼" ? 2 : 1);
			level = Math.max(level, value);
			return match;
		});
		return level;
	}

	function withoutPriority(text) {
		return String(text || "").replace(root.priorityPattern, "").replace(/\s+$/, "");
	}

	function priorityColor(level) {
		return level === 3 ? Theme.danger : (level === 2 ? Theme.warning : Theme.secondary);
	}

	function linksOf(text) {
		const out = [];
		String(text || "").replace(root.linkPattern, (match, name) => {
			const clean = name.trim();
			if (clean !== "" && out.indexOf(clean) < 0) out.push(clean);
			return match;
		});
		return out;
	}

	function withoutLinks(text) {
		return String(text || "").replace(root.linkPattern, "").replace(/\s+$/, "");
	}

	// ── markdown ──────────────────────────────────────────────────────────
	// one entry per line: { line, kind: heading|task|bullet|code|text|blank|rule,
	// level, indent, done, text }; tasks also carry mark, closed, priority,
	// raw (the text as written), notes (the names linked) and note (their
	// description), whose lines are not entries of their own: lines indented
	// below a task, or right after it without a blank line between
	function columns(space) {
		return String(space || "").replace(/\t/g, "    ").length;
	}

	function parse(text) {
		const out = [];
		const lines = String(text || "").replace(/\r\n/g, "\n").split("\n");
		if (lines.length > 0 && lines[lines.length - 1] === "") lines.pop();
		let fence = false;
		// the task a description line would belong to, and if the line before was blank
		let owner = null;
		let gap = false;
		for (let i = 0; i < lines.length; i += 1) {
			const line = lines[i];
			if (/^\s*(```|~~~)/.test(line)) {
				fence = !fence;
				owner = null;
				continue;
			}
			if (fence) {
				out.push({ line: i, kind: "code", level: 0, indent: 0, done: false, text: line });
				continue;
			}
			if (line.trim() === "") {
				if (owner) {
					gap = true;
					continue;
				}
				out.push({ line: i, kind: "blank", level: 0, indent: 0, done: false, text: "" });
				continue;
			}
			const rule = /^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$/.test(line);
			const heading = rule ? null : /^(#{1,6})\s+(.*)$/.exec(line);
			const task = rule || heading ? null : root.taskPattern.exec(line);
			const bullet = rule || heading || task ? null : /^(\s*)(?:[-*+]|(\d+[.)]))\s+(.*)$/.exec(line);
			if (owner && !rule && !heading && !task && !bullet) {
				const lead = /^\s*/.exec(line)[0];
				if (!gap || root.columns(lead) > owner.columns) {
					owner.note += (owner.note === "" ? "" : "\n") + line.trim();
					owner.lines.push(i);
					gap = false;
					continue;
				}
			}
			if (owner && gap) out.push({ line: i - 1, kind: "blank", level: 0, indent: 0, done: false, text: "" });
			owner = null;
			gap = false;
			if (rule) {
				out.push({ line: i, kind: "rule", level: 0, indent: 0, done: false, text: "" });
				continue;
			}
			if (heading) {
				out.push({ line: i, kind: "heading", level: heading[1].length, indent: 0, done: false, text: heading[2].replace(/\s+#+\s*$/, "") });
				continue;
			}
			if (task) {
				const mark = task[2];
				const raw = task[3] || "";
				owner = {
					line: i,
					kind: "task",
					level: 0,
					indent: Math.floor(task[1].replace(/\t/g, "  ").length / 2),
					columns: root.columns(task[1]),
					mark,
					done: root.isDone(mark),
					closed: root.isDone(mark) || mark === "-",
					text: root.withoutLinks(root.withoutPriority(raw)),
					raw,
					priority: root.priorityOf(raw),
					notes: root.linksOf(raw),
					note: "",
					lines: [i]
				};
				out.push(owner);
				continue;
			}
			if (bullet) {
				out.push({ line: i, kind: "bullet", level: 0, indent: Math.floor(bullet[1].replace(/\t/g, "  ").length / 2), done: false, text: bullet[3], marker: bullet[2] || "" });
				continue;
			}
			out.push({ line: i, kind: "text", level: 0, indent: 0, done: false, text: line.trim() });
		}
		return out;
	}

	// cancelled tasks don't count
	function counts(text) {
		let total = 0;
		let done = 0;
		for (const line of String(text || "").split("\n")) {
			const task = root.taskPattern.exec(line.replace(/\r$/, ""));
			if (!task || task[2] === "-") continue;
			total += 1;
			if (root.isDone(task[2])) done += 1;
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

	// ── the board ─────────────────────────────────────────────────────────
	// groups in file order (the inbox always, first); a task is its parse
	// entry plus key (stable while its group and text stay), group and section
	function buildBoard(text) {
		const groups = [];
		const tasks = [];
		const seen = {};
		let current = null;
		let section = "";
		const inbox = { name: root.inbox, line: -1, open: 0, done: 0, tasks: [], categories: [] };
		for (const entry of root.parse(text)) {
			if (entry.kind === "heading") {
				if (entry.level <= 2) {
					const name = entry.text.trim();
					current = name.toLowerCase() === root.inbox.toLowerCase() ? inbox : groups.find(group => group.name === name);
					if (current === inbox) inbox.line = entry.line;
					else if (!current) {
						current = { name, line: entry.line, open: 0, done: 0, tasks: [], categories: [] };
						groups.push(current);
					}
					section = "";
				} else if (entry.level === 3) {
					section = entry.text.trim();
					const group = current ?? inbox;
					if (section !== "" && group.categories.indexOf(section) < 0) group.categories.push(section);
				}
				continue;
			}
			if (entry.kind !== "task") continue;
			const group = current ?? inbox;
			// mark, priority and notes change, the key stays
			const id = `${group.name}\u0001${entry.text}`;
			seen[id] = (seen[id] ?? 0) + 1;
			const task = Object.assign({}, entry, { key: `${id}\u0001${seen[id]}`, group: group.name, section });
			group.tasks.push(task);
			tasks.push(task);
			if (task.done) group.done += 1;
			else if (!task.closed) group.open += 1;
		}
		return { groups: [inbox].concat(groups), tasks };
	}

	function findTask(key) {
		return root.tasks.find(task => task.key === key) ?? null;
	}

	function findGroup(name) {
		return root.groups.find(group => group.name === name) ?? null;
	}

	// open tasks first by priority, then as in the file; done ones as in the file
	function openOf(group) {
		return (group?.tasks ?? []).filter(task => !task.closed).sort((left, right) => right.priority - left.priority || left.line - right.line);
	}

	function closedOf(group) {
		return (group?.tasks ?? []).filter(task => task.closed);
	}

	// ── edits of Tasks.md (pure: text in, text out) ───────────────────────
	function withMark(text, lineIndex, mark) {
		const lines = String(text || "").split("\n");
		const line = lines[lineIndex];
		if (line === undefined) return String(text || "");
		lines[lineIndex] = line.replace(/^(\s*[-*+]\s+\[)(.)(\])/, (match, head, old, tail) => `${head}${mark}${tail}`);
		return lines.join("\n");
	}

	function markAt(text, lineIndex) {
		const task = root.taskPattern.exec(String(text || "").split("\n")[lineIndex] ?? "");
		return task ? task[2] : "";
	}

	function toggled(text, lineIndex) {
		return root.withMark(text, lineIndex, root.isDone(root.markAt(text, lineIndex)) ? " " : "x");
	}

	// open → in progress → done → open
	function cycled(text, lineIndex) {
		const mark = root.markAt(text, lineIndex);
		const next = mark === "/" ? "x" : (root.isDone(mark) ? " " : "/");
		return root.withMark(text, lineIndex, next);
	}

	function signOf(level) {
		return root.priorities.find(entry => entry.level === level)?.sign ?? "";
	}

	function withPriority(text, lineIndex, level) {
		const lines = String(text || "").split("\n");
		if (lines[lineIndex] === undefined) return String(text || "");
		const sign = root.signOf(level);
		lines[lineIndex] = root.withoutPriority(lines[lineIndex]) + (sign === "" ? "" : ` ${sign}`);
		return lines.join("\n");
	}

	// a task line from its parts
	function taskLine(lead, mark, text, notes, priority) {
		const links = (notes ?? []).map(name => ` [[${name}]]`).join("");
		const sign = root.signOf(priority);
		return `${lead}- [${mark}] ${String(text || "").trim()}${links}${sign === "" ? "" : ` ${sign}`}`;
	}

	// [start, end) of the lines a task takes: its own, its description and
	// whatever is indented below it (sub tasks, bullets)
	function blockOf(lines, start) {
		const own = root.columns(/^\s*/.exec(lines[start] ?? "")[0]);
		let end = start + 1;
		let last = start + 1;
		let gap = false;
		while (end < lines.length) {
			const line = lines[end];
			if (line.trim() === "") {
				gap = true;
				end += 1;
				continue;
			}
			const lead = root.columns(/^\s*/.exec(line)[0]);
			const plain = !/^\s*([-*+]|\d+[.)])\s/.test(line) && !/^#{1,6}\s/.test(line) && !/^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$/.test(line);
			if (lead > own || (!gap && plain)) {
				end += 1;
				last = end;
				gap = false;
				continue;
			}
			break;
		}
		return { start, end: last };
	}

	// [start, stop) of a group's lines after its heading; null: the group is not there
	function groupRange(lines, name) {
		const isInbox = name === root.inbox;
		const isGroup = line => /^#{1,2}\s/.test(line);
		let start = lines.findIndex(line => {
			const heading = /^(#{1,2})\s+(.*)$/.exec(line);
			if (!heading) return false;
			const title = heading[2].replace(/\s+#+\s*$/, "").trim();
			return isInbox ? title.toLowerCase() === root.inbox.toLowerCase() : title === name;
		});
		let stop;
		if (start >= 0) {
			start += 1;
			stop = lines.findIndex((line, index) => index >= start && isGroup(line));
		} else {
			// the inbox without a heading: the tasks before the first group
			if (!isInbox) return null;
			stop = lines.findIndex(isGroup);
			if (stop === 0) return null;
			start = 0;
		}
		return { start, stop: stop < 0 ? lines.length : stop };
	}

	// [start, stop) of a category of a group ("": the tasks before its first category); null: not there
	function sectionRange(lines, groupName, section) {
		const group = root.groupRange(lines, groupName);
		if (!group) return null;
		const isCategory = line => /^###\s/.test(line);
		if (section === "") {
			const first = lines.findIndex((line, index) => index >= group.start && index < group.stop && isCategory(line));
			return { start: group.start, stop: first < 0 ? group.stop : first };
		}
		const at = lines.findIndex((line, index) => {
			if (index < group.start || index >= group.stop) return false;
			const heading = /^###\s+(.*)$/.exec(line);
			return heading !== null && heading[1].replace(/\s+#+\s*$/, "").trim() === section;
		});
		if (at < 0) return null;
		const next = lines.findIndex((line, index) => index > at && index < group.stop && isCategory(line));
		return { start: at + 1, stop: next < 0 ? group.stop : next };
	}

	// after the last line of the range that is not blank
	function endOf(lines, range) {
		let end = range.start;
		for (let i = range.start; i < range.stop; i += 1) {
			if (lines[i].trim() !== "") end = i + 1;
		}
		return end;
	}

	// block: lines of one task (starting at its own indent of 0); section: its category, "" for none
	function withBlockIn(text, groupName, block, section) {
		const lines = String(text || "").replace(/\n+$/, "").split("\n");
		if (lines.length === 1 && lines[0] === "") lines.pop();
		if (!root.groupRange(lines, groupName)) {
			if (groupName === root.inbox) {
				lines.splice(0, 0, `## ${root.inbox}`, "");
			} else {
				if (lines.length > 0) lines.push("");
				lines.push(`## ${groupName}`);
			}
		}
		let range = root.sectionRange(lines, groupName, section ?? "");
		if (!range) {
			// a category that is not there yet comes at the end of the group
			const group = root.groupRange(lines, groupName);
			const at = root.endOf(lines, group);
			lines.splice(at, 0, "", `### ${section}`);
			range = root.sectionRange(lines, groupName, section);
		}
		const at = root.endOf(lines, range);
		// right below a heading, or after the tasks before it
		lines.splice(at, 0, ...block);
		return lines.join("\n") + "\n";
	}

	function withTaskIn(text, groupName, task, priority) {
		return root.withBlockIn(text, groupName, [root.taskLine("", " ", task, [], priority ?? 0)]);
	}

	function withoutBlock(text, line) {
		const lines = String(text || "").split("\n");
		const block = root.blockOf(lines, line);
		lines.splice(block.start, block.end - block.start);
		return lines.join("\n");
	}

	function movedTo(text, line, groupName, section) {
		const lines = String(text || "").split("\n");
		const block = root.blockOf(lines, line);
		const lead = /^\s*/.exec(lines[line])[0];
		const moved = lines.slice(block.start, block.end).map(part => part.startsWith(lead) ? part.slice(lead.length) : part.replace(/^\s+/, ""));
		lines.splice(block.start, block.end - block.start);
		return root.withBlockIn(lines.join("\n"), groupName, moved, section ?? "");
	}

	// new text and description; the mark, priority and notes stay
	function withContent(text, line, title, description) {
		const lines = String(text || "").split("\n");
		const task = root.taskPattern.exec(lines[line] ?? "");
		if (!task) return String(text || "");
		const lead = task[1];
		lines[line] = root.taskLine(lead, task[2], title, root.linksOf(task[3] || ""), root.priorityOf(task[3] || ""));
		// the description: the plain lines right below, before sub items
		let end = line + 1;
		while (end < lines.length && lines[end].trim() !== "" && root.columns(/^\s*/.exec(lines[end])[0]) > root.columns(lead) && !/^\s*([-*+]|\d+[.)])\s/.test(lines[end])) end += 1;
		const below = String(description || "").split("\n").map(part => part.trim()).filter(part => part !== "").map(part => `${lead}\t${part}`);
		lines.splice(line + 1, end - line - 1, ...below);
		return lines.join("\n");
	}

	function withLink(text, line, name, linked) {
		const lines = String(text || "").split("\n");
		const task = root.taskPattern.exec(lines[line] ?? "");
		if (!task) return String(text || "");
		const raw = task[3] || "";
		const notes = root.linksOf(raw).filter(entry => entry !== name);
		if (linked) notes.push(name);
		lines[line] = root.taskLine(task[1], task[2], root.withoutLinks(root.withoutPriority(raw)), notes, root.priorityOf(raw));
		return lines.join("\n");
	}

	// every [[from]] in a task becomes [[to]] ("" removes them)
	function withRenamedLinks(text, from, to) {
		const lower = String(from).toLowerCase();
		return String(text || "").split("\n").map(line => {
			if (!root.taskPattern.test(line)) return line;
			return line.replace(/([ \t]*)\[\[([^\]|#]+)((?:[|#][^\]]*)?)\]\]/g, (match, space, name, rest) => {
				if (name.trim().toLowerCase() !== lower) return match;
				return to === "" ? "" : `${space}[[${to}${rest}]]`;
			});
		}).join("\n");
	}

	function headingLineOf(lines, name) {
		return lines.findIndex(line => {
			const heading = /^(#{1,2})\s+(.*)$/.exec(line);
			return heading && heading[2].replace(/\s+#+\s*$/, "").trim() === name;
		});
	}

	// ── task actions (on Tasks.md) ────────────────────────────────────────
	// plays the list-done haptic when an edit checks off the last open task
	function noteEdit(before, after) {
		const was = root.counts(before);
		const now = root.counts(after);
		if (now.total > 0 && now.done === now.total && was.done < was.total)
			Haptics.play("listDone");
	}

	function writeTasks(next) {
		if (next === root.tasksText) return;
		root.noteEdit(root.tasksText, next);
		root.tasksText = next;
		tasksFile.setText(next);
	}

	// change(text, line) on the task's line, while it is still that task
	function editTask(key, change) {
		const task = root.findTask(key);
		if (!task) return;
		const line = String(root.tasksText).split("\n")[task.line] ?? "";
		const current = root.taskPattern.exec(line);
		if (!current || (current[3] || "") !== task.raw) return;
		root.writeTasks(change(root.tasksText, task.line));
	}

	function toggleTask(key) {
		root.editTask(key, (text, line) => root.toggled(text, line));
	}

	function cycleTask(key) {
		root.editTask(key, (text, line) => root.cycled(text, line));
	}

	function setMark(key, mark) {
		root.editTask(key, (text, line) => root.withMark(text, line, mark));
	}

	function setPriority(key, level) {
		root.editTask(key, (text, line) => root.withPriority(text, line, level));
	}

	function setContent(key, title, description) {
		if (String(title || "").trim() === "") return;
		root.editTask(key, (text, line) => root.withContent(text, line, title, description));
	}

	// into another group, where the model sorts it again
	function moveTask(key, groupName) {
		const task = root.findTask(key);
		if (!task || task.group === groupName) return;
		root.editTask(key, (text, line) => root.movedTo(text, line, groupName, ""));
		root.classify(`${groupName}\u0001${task.text}\u0001${root.tasks.filter(other => other.group === groupName && other.text === task.text).length}`);
	}

	// into a category of its group ("" for none)
	function setCategory(key, section) {
		const task = root.findTask(key);
		if (!task || task.section === section) return;
		root.editTask(key, (text, line) => root.movedTo(text, line, task.group, section));
	}

	function deleteTask(key) {
		root.editTask(key, (text, line) => root.withoutBlock(text, line));
	}

	// "#group" picks the group (the start of its name is enough), "!" "!!" "!!!"
	// the priority; returns the group the task went to
	function addTask(groupName, input) {
		let group = groupName || root.inbox;
		let priority = 0;
		const words = [];
		for (const word of String(input || "").trim().split(/\s+/)) {
			if (/^!{1,3}$/.test(word)) {
				priority = word.length;
				continue;
			}
			if (/^#\S/.test(word)) {
				const wanted = word.slice(1).toLowerCase();
				const match = root.groups.find(entry => entry.name.toLowerCase() === wanted) ?? root.groups.find(entry => entry.name.toLowerCase().startsWith(wanted));
				if (match) {
					group = match.name;
					continue;
				}
			}
			words.push(word);
		}
		const text = words.join(" ").trim();
		if (text === "") return "";
		root.writeTasks(root.withTaskIn(root.tasksText, group, text, priority));
		const added = root.tasks.filter(task => task.group === group && task.text === text).sort((left, right) => right.line - left.line)[0];
		if (added) root.classify(added.key);
		return group;
	}

	// ── groups ────────────────────────────────────────────────────────────
	function groupNameFor(name) {
		return String(name || "").replace(/[\r\n#]/g, " ").trim();
	}

	function addGroup(name) {
		const clean = root.groupNameFor(name);
		if (clean === "" || root.findGroup(clean)) return clean;
		const text = String(root.tasksText).replace(/\n+$/, "");
		root.writeTasks(`${text}${text === "" ? "" : "\n\n"}## ${clean}\n`);
		return clean;
	}

	function renameGroup(from, to) {
		const clean = root.groupNameFor(to);
		if (clean === "" || clean === from || from === root.inbox || root.findGroup(clean)) return from;
		const lines = String(root.tasksText).split("\n");
		const at = root.headingLineOf(lines, from);
		if (at < 0) return from;
		lines[at] = `## ${clean}`;
		root.writeTasks(lines.join("\n"));
		const key = root.groupKey(from);
		if (root.isPinned(key)) root.savePins(root.pins.map(pin => pin.path === key ? Object.assign({}, pin, { path: root.groupKey(clean) }) : pin));
		return clean;
	}

	// its tasks go to the inbox
	function deleteGroup(name) {
		const group = root.findGroup(name);
		if (!group || name === root.inbox) return;
		let text = root.tasksText;
		for (const task of group.tasks.slice().reverse()) {
			if (task.indent === 0) text = root.movedTo(text, task.line, root.inbox);
		}
		const lines = text.split("\n");
		const at = root.headingLineOf(lines, name);
		if (at >= 0) {
			lines.splice(at, 1);
			while (at < lines.length && at > 0 && lines[at].trim() === "" && lines[at - 1].trim() === "") lines.splice(at, 1);
		}
		root.writeTasks(lines.join("\n"));
		root.unpin(root.groupKey(name));
	}

	// ── categories ────────────────────────────────────────────────────────
	function categoryNameFor(name) {
		return String(name || "").replace(/[\r\n#]/g, " ").trim();
	}

	function addCategory(groupName, name) {
		const clean = root.categoryNameFor(name);
		const group = root.findGroup(groupName);
		if (clean === "" || !group || group.categories.indexOf(clean) >= 0) return;
		const lines = String(root.tasksText).replace(/\n+$/, "").split("\n");
		if (lines.length === 1 && lines[0] === "") lines.pop();
		let range = root.groupRange(lines, groupName);
		if (!range) {
			if (groupName === root.inbox) lines.splice(0, 0, `## ${root.inbox}`);
			range = root.groupRange(lines, groupName);
		}
		const at = root.endOf(lines, range);
		lines.splice(at, 0, "", `### ${clean}`);
		root.writeTasks(lines.join("\n") + "\n");
	}

	function renameCategory(groupName, from, to) {
		const clean = root.categoryNameFor(to);
		const group = root.findGroup(groupName);
		if (clean === "" || !group || group.categories.indexOf(clean) >= 0) return;
		const lines = String(root.tasksText).split("\n");
		const range = root.sectionRange(lines, groupName, from);
		if (!range) return;
		lines[range.start - 1] = `### ${clean}`;
		root.writeTasks(lines.join("\n"));
	}

	// its tasks stay in the group, without a category
	function removeCategory(groupName, name) {
		let text = root.tasksText;
		const group = root.findGroup(groupName);
		if (!group) return;
		for (const task of group.tasks.filter(task => task.section === name && task.indent === 0).reverse())
			text = root.movedTo(text, task.line, groupName, "");
		const lines = text.split("\n");
		const range = root.sectionRange(lines, groupName, name);
		if (range) {
			lines.splice(range.start - 1, 1);
			if (range.start - 2 >= 0 && lines[range.start - 2]?.trim() === "" && (lines[range.start - 1] ?? "").trim() === "") lines.splice(range.start - 2, 1);
		}
		root.writeTasks(lines.join("\n"));
	}

	// ── the model that sorts tasks ────────────────────────────────────────
	readonly property bool aiEnabled: Plugins.on("todo-ai")
	// installed models, from the fastest to the best: [{ name, size }]
	property var aiModels: []
	// the one picked; "" or one that is gone means the fastest
	property string aiPicked: ""
	readonly property string aiModel: root.aiModels.some(model => model.name === root.aiPicked) ? root.aiPicked : (root.aiModels[0]?.name ?? "")
	// keys of the tasks waiting for it, the first one is being sorted
	property var aiQueue: []
	property string aiError: ""

	function isClassifying(key) {
		return root.aiQueue.indexOf(key) >= 0;
	}

	function pickModel(name) {
		root.aiPicked = name;
		aiSettings.setText(JSON.stringify({ model: name }, null, "\t") + "\n");
	}

	function lookForModels() {
		if (!aiLister.running) aiLister.running = true;
	}

	// asks the model for the task's category (when its group has categories)
	function classify(key) {
		const task = root.findTask(key);
		if (!root.aiEnabled || !task || (root.findGroup(task.group)?.categories.length ?? 0) === 0) return;
		if (root.aiQueue.indexOf(key) >= 0) return;
		root.aiQueue = root.aiQueue.concat([key]);
		if (!aiRunner.running) root.nextClassify();
	}

	function nextClassify() {
		while (root.aiQueue.length > 0) {
			const task = root.findTask(root.aiQueue[0]);
			const group = task ? root.findGroup(task.group) : null;
			if (!task || !group || group.categories.length === 0) {
				root.aiQueue = root.aiQueue.slice(1);
				continue;
			}
			const notes = task.notes.map(name => root.findNote(name)).filter(note => note !== null).map(note => {
				const view = directFile.createObject(root, { path: note.path });
				const text = view.text();
				view.destroy();
				return { name: note.name, text };
			});
			aiRunner.key = task.key;
			aiRunner.command = ["python3", `${Paths.scripts}/todos/classify.py`, "classify", JSON.stringify({
				model: root.aiModel,
				group: task.group,
				categories: group.categories,
				title: task.text,
				description: task.note,
				notes
			})];
			aiRunner.running = true;
			return;
		}
	}

	Process {
		id: aiRunner

		property string key: ""

		stdout: SplitParser {
			onRead: line => {
				let data = {};
				try {
					data = JSON.parse(line);
				} catch (error) {}
				if (data.error) {
					root.aiError = String(data.error);
					return;
				}
				root.aiError = "";
				if (data.category !== undefined && data.category !== "") root.setCategory(aiRunner.key, String(data.category));
			}
		}
		onExited: {
			root.aiQueue = root.aiQueue.filter(key => key !== aiRunner.key);
			root.nextClassify();
		}
	}

	Process {
		id: aiLister

		running: root.aiEnabled
		command: ["python3", `${Paths.scripts}/todos/classify.py`, "models"]
		stdout: SplitParser {
			onRead: line => {
				try {
					const data = JSON.parse(line);
					if (data.models) root.aiModels = data.models;
					if (data.error) root.aiError = String(data.error);
				} catch (error) {}
			}
		}
	}

	FileView {
		id: aiSettings

		path: Paths.stateFile("todo-ai.json")
		printErrors: false
		onLoaded: {
			try {
				root.aiPicked = String(JSON.parse(String(text() || "{}")).model ?? "");
			} catch (error) {}
		}
	}

	Component {
		id: directFile

		FileView {
			blockAllReads: true
			printErrors: false
		}
	}

	// ── notes ─────────────────────────────────────────────────────────────
	function displayName(path) {
		if (path === root.overviewKey) return "Tasks";
		if (root.isGroupKey(path)) return root.groupOfKey(path);
		const base = String(path || "").split("/").pop();
		return base.replace(/\.(md|markdown)$/i, "");
	}

	function cleanName(name) {
		return String(name || "").trim().replace(/[\/\\:*?"<>|\[\]#^]/g, "-").replace(/^\.+/, "").slice(0, 80).trim();
	}

	function notePath(name) {
		return `${root.notesDir}/${root.cleanName(name)}.md`;
	}

	function findNote(name) {
		const lower = String(name || "").toLowerCase();
		return root.notes.find(note => note.name.toLowerCase() === lower) ?? null;
	}

	// the tasks that link a note
	function tasksOf(name) {
		const lower = String(name || "").toLowerCase();
		return root.tasks.filter(task => task.notes.some(entry => entry.toLowerCase() === lower));
	}

	// a name no other note has
	function freeName(name) {
		const base = root.cleanName(name);
		if (base === "") return "";
		let candidate = base;
		for (let i = 2; root.findNote(candidate); i += 1) candidate = `${base} ${i}`;
		return candidate;
	}

	function refreshNotes() {
		if (notesProc.running) {
			notesProc.again = true;
			return;
		}
		notesProc.running = true;
	}

	// kept for the callers that only know lists
	function refresh() {
		root.refreshNotes();
	}

	function parseNotes(raw) {
		const notes = [];
		for (const line of String(raw || "").split("\n")) {
			const at = line.indexOf("\t");
			if (at < 0) continue;
			const path = line.slice(at + 1);
			notes.push({ modified: Number(line.slice(0, at)) || 0, path, name: root.displayName(path) });
		}
		notes.sort((left, right) => left.name.localeCompare(right.name));
		if (JSON.stringify(notes) !== JSON.stringify(root.notes)) root.notes = notes;
		root.notesLoaded = true;
	}

	// creates notes/<name>.md with its first content; returns its path, noteCreated(path) follows
	function createNote(name, initialText) {
		const clean = root.freeName(name);
		if (clean === "") return "";
		const path = root.notePath(clean);
		const proc = writer.createObject(root, { path });
		proc.command = ["sh", "-c", 'mkdir -p "$1" && { [ -e "$2" ] || printf "%s" "$3" > "$2"; }', "sh", root.notesDir, path, String(initialText ?? `# ${clean}\n\n`)];
		proc.running = true;
		const next = root.notes.concat([{ modified: Date.now() / 1000, path, name: clean }]);
		next.sort((left, right) => left.name.localeCompare(right.name));
		root.notes = next;
		return path;
	}

	// a new note about a task: linked to it, pinned to the desktop and open in the editor
	function createNoteFor(key) {
		const task = root.findTask(key);
		if (!task) return "";
		const path = root.createNote(task.text, `# ${task.text}\n\n`);
		if (path === "") return "";
		const name = root.displayName(path);
		root.editTask(key, (text, line) => root.withLink(text, line, name, true));
		root.pin(path);
		root.openEditor(path, -1);
		return path;
	}

	function linkNote(key, name, linked) {
		root.editTask(key, (text, line) => root.withLink(text, line, name, linked));
	}

	function renameNote(path, name) {
		const clean = root.freeName(name);
		const old = root.displayName(path);
		if (clean === "" || path === "" || clean.toLowerCase() === old.toLowerCase()) return path;
		const target = root.notePath(clean);
		const proc = writer.createObject(root, { path: target });
		proc.command = ["mv", "-n", "--", path, target];
		proc.running = true;
		root.notes = root.notes.map(note => note.path === path ? { modified: note.modified, path: target, name: clean } : note)
			.sort((left, right) => left.name.localeCompare(right.name));
		root.writeTasks(root.withRenamedLinks(root.tasksText, old, clean));
		if (root.isPinned(path)) root.savePins(root.pins.map(pin => pin.path === path ? Object.assign({}, pin, { path: target }) : pin));
		if (root.folds[path]) {
			const folds = Object.assign({}, root.folds);
			folds[target] = folds[path];
			delete folds[path];
			root.saveFolds(folds);
		}
		if (root.editorPath === path) root.editorPath = target;
		return target;
	}

	// to the trash; its links go too
	function deleteNote(path) {
		const name = root.displayName(path);
		Quickshell.execDetached(["gio", "trash", "--", path]);
		root.notes = root.notes.filter(note => note.path !== path);
		root.writeTasks(root.withRenamedLinks(root.tasksText, name, ""));
		root.unpin(path);
		if (root.editorOpen && root.editorPath === path) root.closeEditor();
		refreshLater.restart();
	}

	// ── following a link ──────────────────────────────────────────────────
	// the pinned board a task shows on: its group's, else the one of every group
	function pinFor(task) {
		if (!task) return "";
		if (root.isPinned(root.groupKey(task.group))) return root.groupKey(task.group);
		return root.isPinned(root.overviewKey) ? root.overviewKey : "";
	}

	// to the pinned widget of a note, or into the launcher at it
	function openNote(name) {
		const note = root.findNote(name);
		if (note && root.isPinned(note.path)) {
			root.highlight(note.path, "");
			return;
		}
		root.showNote(note ? note.path : name);
	}

	function openTask(key) {
		const pin = root.pinFor(root.findTask(key));
		if (pin !== "") root.highlight(pin, key);
		else root.showTask(key);
	}

	function highlight(pinKey, taskKey) {
		if (Popups.current === "launcher") Popups.close();
		root.highlightRequested(pinKey, taskKey);
	}

	// ── into the launcher ─────────────────────────────────────────────────
	function showTask(key) {
		root.launcherTab = "tasks";
		root.target = { kind: "task", key, stamp: Date.now() };
		root.openLauncher();
	}

	// a note that is not there yet is made
	function showNote(nameOrPath) {
		let path = String(nameOrPath || "");
		if (!path.startsWith("/")) {
			const note = root.findNote(path);
			path = note ? note.path : root.createNote(path);
		}
		if (path === "") return;
		root.launcherTab = "notes";
		root.target = { kind: "note", path, stamp: Date.now() };
		root.openLauncher();
	}

	function openLauncher() {
		Popups.withFocusedScreen(screen => {
			if (Popups.current === "launcher") Popups.close();
			Popups.open("launcher", screen, "", ">todo ");
		});
	}

	// ── editor window ─────────────────────────────────────────────────────
	function openEditor(path, line) {
		root.editorPath = path || "";
		root.editorLine = line === undefined ? -1 : line;
		if (root.editorOpen) root.editorRequested();
		root.editorOpen = true;
	}

	function newNote() {
		root.openEditor("", -1);
	}

	function closeEditor() {
		root.editorOpen = false;
	}

	// ── desktop pins ──────────────────────────────────────────────────────
	function isPinned(path) {
		return root.pins.some(pin => pin.path === path);
	}

	// the first free place of a grid, left to right, top to bottom
	function pin(path) {
		if (path === "" || root.isPinned(path)) return;
		const screen = Popups.primaryScreen;
		const width = screen?.width ?? 1920;
		const height = screen?.height ?? 1080;
		const taken = root.pins.map(pin => ({ x: pin.x, y: pin.y, w: pin.w > 0 ? pin.w : 310, h: pin.h > 0 ? pin.h : 300 }));
		const free = (x, y) => !taken.some(box => x < box.x + box.w + 16 && x + 310 + 16 > box.x && y < box.y + box.h + 16 && y + 300 + 16 > box.y);
		let spot = { x: 80 + (root.pins.length % 8) * 36, y: 90 + (root.pins.length % 8) * 36 };
		search: for (let y = 60; y + 300 <= height; y += 40) {
			for (let x = 40; x + 310 <= width; x += 40) {
				if (free(x, y)) {
					spot = { x, y };
					break search;
				}
			}
		}
		root.savePins(root.pins.concat([{ path, x: spot.x, y: spot.y, w: 0, h: 0, collapsed: false }]));
	}

	function unpin(path) {
		if (!root.isPinned(path)) return;
		root.savePins(root.pins.filter(pin => pin.path !== path));
	}

	function togglePin(path) {
		if (root.isPinned(path)) root.unpin(path);
		else root.pin(path);
	}

	function movePin(path, x, y) {
		root.savePins(root.pins.map(pin => pin.path === path ? Object.assign({}, pin, { x: Math.round(x), y: Math.round(y) }) : pin));
	}

	function resizePin(path, width, height) {
		root.savePins(root.pins.map(pin => pin.path === path ? Object.assign({}, pin, { w: Math.round(width), h: Math.round(height) }) : pin));
	}

	function setCollapsed(path, collapsed) {
		root.savePins(root.pins.map(pin => pin.path === path ? Object.assign({}, pin, { collapsed }) : pin));
	}

	function savePins(next) {
		root.pins = next;
		pinsFile.setText(JSON.stringify(next, null, 2));
	}

	// ── folded headings ───────────────────────────────────────────────────
	function foldKey(entry) {
		return `${entry.level}:${entry.text}`;
	}

	function isFolded(path, key) {
		return (root.folds[path] ?? []).indexOf(key) >= 0;
	}

	function toggleFold(path, key) {
		const folds = Object.assign({}, root.folds);
		const keys = folds[path] ?? [];
		folds[path] = keys.indexOf(key) >= 0 ? keys.filter(entry => entry !== key) : keys.concat([key]);
		if (folds[path].length === 0) delete folds[path];
		root.saveFolds(folds);
	}

	function saveFolds(next) {
		root.folds = next;
		foldsFile.setText(JSON.stringify(next, null, 2));
	}

	FileView {
		id: tasksFile

		path: root.tasksPath
		watchChanges: true
		atomicWrites: false
		printErrors: false
		onFileChanged: reload()
		onLoaded: {
			root.tasksText = text();
			root.tasksLoaded = true;
		}
		onLoadFailed: root.tasksLoaded = true
	}

	FileView {
		id: foldsFile

		path: root.foldsPath
		printErrors: false
		watchChanges: true
		onFileChanged: reload()
		onLoaded: {
			try {
				const data = JSON.parse(text());
				root.folds = data && typeof data === "object" && !Array.isArray(data) ? data : {};
			} catch (error) {
				root.folds = {};
			}
		}
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
					y: Number(pin.y) || 0,
					w: Number(pin.w) || 0,
					h: Number(pin.h) || 0,
					collapsed: pin.collapsed === true
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
		id: notesProc

		property bool again: false

		command: ["sh", "-c", `[ -d "$1" ] || exit 0
			find "$1" -maxdepth 1 -type f -iname '*.md' ! -name '.*' -printf '%T@\\t%p\\n'`, "sh", root.notesDir]
		stdout: StdioCollector {
			onStreamFinished: root.parseNotes(text)
		}
		onExited: {
			if (notesProc.again) {
				notesProc.again = false;
				root.refreshNotes();
			}
		}
	}

	Timer {
		id: refreshLater

		interval: 400
		onTriggered: root.refreshNotes()
	}

	Component {
		id: writer

		Process {
			id: proc

			property string path: ""

			onExited: {
				root.noteCreated(proc.path);
				root.refreshNotes();
				proc.destroy();
			}
		}
	}

	Component.onCompleted: root.refreshNotes()
}
