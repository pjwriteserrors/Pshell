// What the keys and the slash commands do to Markdown text.
import { syntaxTree } from "@codemirror/language";
import { EditorSelection } from "@codemirror/state";

export function wrap(view, before, after = before) {
	view.dispatch(view.state.changeByRange(range => {
		const inner = view.state.sliceDoc(range.from, range.to);
		const out = view.state.sliceDoc(range.from - before.length, range.from) === before
			&& view.state.sliceDoc(range.to, range.to + after.length) === after;
		if (out) {
			return {
				changes: [{ from: range.from - before.length, to: range.from }, { from: range.to, to: range.to + after.length }],
				range: EditorSelection.range(range.from - before.length, range.to - before.length),
			};
		}
		if (inner.startsWith(before) && inner.endsWith(after) && inner.length >= before.length + after.length) {
			return {
				changes: { from: range.from, to: range.to, insert: inner.slice(before.length, inner.length - after.length) },
				range: EditorSelection.range(range.from, range.to - before.length - after.length),
			};
		}
		return {
			changes: [{ from: range.from, insert: before }, { from: range.to, insert: after }],
			range: EditorSelection.range(range.from + before.length, range.to + before.length),
		};
	}));
	view.focus();
	return true;
}

// sets or takes off a prefix on each line of the selection
export function linePrefix(view, prefix, pattern) {
	const { state } = view;
	const changes = [];
	const seen = new Set();
	for (const range of state.selection.ranges) {
		for (let at = range.from; at <= range.to;) {
			const line = state.doc.lineAt(at);
			at = line.to + 1;
			if (seen.has(line.number)) continue;
			seen.add(line.number);
			const found = line.text.match(pattern);
			if (found && found[0] === prefix) changes.push({ from: line.from, to: line.from + found[0].length });
			else changes.push({ from: line.from, to: line.from + (found ? found[0].length : 0), insert: prefix });
		}
	}
	view.dispatch({ changes });
	view.focus();
	return true;
}

const BLOCK = /^(#{1,6}\s+|[-*+]\s+\[[ xX]\]\s+|[-*+]\s+|\d+\.\s+|>\s?)/;
export const heading = (view, level) => linePrefix(view, level ? `${"#".repeat(level)} ` : "", BLOCK);
export const bullet = view => linePrefix(view, "- ", BLOCK);
export const numbered = view => linePrefix(view, "1. ", BLOCK);
export const task = view => linePrefix(view, "- [ ] ", BLOCK);
export const quote = view => linePrefix(view, "> ", BLOCK);

// a block on lines of its own at the cursor; | in text is where the cursor lands
export function insertBlock(view, text, from, to) {
	const { state } = view;
	const start = from ?? state.selection.main.from;
	const end = to ?? state.selection.main.to;
	const before = state.doc.lineAt(start);
	const after = state.doc.lineAt(end);
	const lead = state.sliceDoc(before.from, start).trim() === "" ? "" : "\n\n";
	const trail = state.sliceDoc(end, after.to).trim() === "" ? "" : "\n\n";
	const from2 = lead === "" ? before.from : start;
	const to2 = trail === "" ? after.to : end;
	const cursor = text.indexOf("‸");
	const clean = text.replace("‸", "");
	view.dispatch({
		changes: { from: from2, to: to2, insert: lead + clean + trail },
		selection: EditorSelection.cursor(from2 + lead.length + (cursor < 0 ? clean.length : cursor)),
		scrollIntoView: true,
	});
	view.focus();
	return true;
}

export const insertTable = (view, from, to, columns = 3, rows = 2) => {
	const head = `| ‸Column 1 |${Array.from({ length: columns - 1 }, (_, i) => ` Column ${i + 2} |`).join("")}`;
	const rule = `|${"----------|".repeat(columns)}`;
	const row = `|${"          |".repeat(columns)}`;
	return insertBlock(view, [head, rule, ...Array(rows).fill(row)].join("\n"), from, to);
};
export const insertCode = (view, from, to, lang = "") => insertBlock(view, `\`\`\`${lang}\n‸\n\`\`\``, from, to);
export const insertColumns = (view, from, to) => insertBlock(view, "::: columns\n‸\n|||\n\n:::", from, to);
export const insertRule = (view, from, to) => insertBlock(view, "---\n‸", from, to);
export const insertCallout = (view, kind, from, to) => insertBlock(view, `> [!${kind}]\n> ‸`, from, to);
export const insertWeb = (view, from, to) => insertBlock(view, "```html\n‸\n```\n\n```css\n\n```\n\n```js\n\n```", from, to);

export function link(view) {
	const range = view.state.selection.main;
	const text = view.state.sliceDoc(range.from, range.to);
	const isUrl = /^https?:\/\//.test(text);
	const insert = isUrl ? `[](${text})` : `[${text}]()`;
	const cursor = isUrl ? range.from + 1 : range.from + insert.length - 1;
	view.dispatch({ changes: { from: range.from, to: range.to, insert }, selection: EditorSelection.cursor(cursor) });
	view.focus();
	return true;
}

export function toggleTask(view) {
	const line = view.state.doc.lineAt(view.state.selection.main.head);
	const found = line.text.match(/^(\s*[-*+]\s+\[)( |x|X)\]/);
	if (!found) return false;
	const at = line.from + found[1].length;
	view.dispatch({ changes: { from: at, to: at + 1, insert: found[2] === " " ? "x" : " " } });
	return true;
}

// ── tables: Tab through cells, the columns line up on the way ───────────
function tableAt(state, pos) {
	for (let node = syntaxTree(state).resolveInner(pos, -1); node; node = node.parent) if (node.name === "Table") return node;
	return null;
}

function cellsOf(text) {
	const inner = text.trim().replace(/^\|/, "").replace(/(?<!\\)\|$/, "");
	return inner.split(/(?<!\\)\|/).map(cell => cell.trim());
}

function formatted(state, table) {
	const first = state.doc.lineAt(table.from);
	const last = state.doc.lineAt(table.to);
	const rows = [];
	for (let number = first.number; number <= last.number; number += 1) rows.push(cellsOf(state.doc.line(number).text));
	const count = Math.max(...rows.map(row => row.length));
	const widths = Array(count).fill(3);
	rows.forEach((row, index) => {
		if (index === 1) return;
		row.forEach((cell, column) => { widths[column] = Math.max(widths[column], [...cell].length); });
	});
	const lines = rows.map((row, index) => {
		const cells = Array.from({ length: count }, (_, column) => {
			const cell = row[column] ?? "";
			if (index !== 1) return ` ${cell}${" ".repeat(widths[column] - [...cell].length)} `;
			const left = cell.startsWith(":");
			const right = cell.endsWith(":");
			return `${left ? ":" : "-"}${"-".repeat(widths[column])}${right ? ":" : "-"}`;
		});
		return `|${cells.join("|")}|`;
	});
	return { from: first.from, to: last.to, lines, first: first.number };
}

export function tableMove(view, direction) {
	const { state } = view;
	const head = state.selection.main.head;
	const table = tableAt(state, head);
	if (!table) return false;
	const line = state.doc.lineAt(head);
	const before = state.sliceDoc(line.from, head);
	const column = Math.max(0, (before.match(/(?<!\\)\|/g) || []).length - 1);
	// Enter on an empty last row leaves the table
	if (direction === "down" && line.number === state.doc.lineAt(table.to).number && line.number > state.doc.lineAt(table.from).number + 1 && cellsOf(line.text).every(cell => cell === "")) {
		const end = Math.min(line.to + 1, state.doc.length);
		view.dispatch({ changes: { from: line.from, to: end, insert: line.to === state.doc.length ? "\n" : "" }, selection: EditorSelection.cursor(line.from + (line.to === state.doc.length ? 1 : 0)) });
		return true;
	}
	const out = formatted(state, table);
	let row = line.number - out.first;
	let cell = column;
	const count = cellsOf(out.lines[0]).length;
	if (direction === "next") {
		cell += 1;
		if (cell >= count) { cell = 0; row += 1; }
	} else if (direction === "previous") {
		cell -= 1;
		if (cell < 0) { cell = count - 1; row -= 1; }
	} else {
		row += 1;
	}
	if (row === 1) row = direction === "previous" ? 0 : 2;
	if (row < 0) { row = 0; cell = 0; }
	if (row >= out.lines.length) {
		out.lines.push(`|${out.lines[0].split("|").slice(1, -1).map(each => " ".repeat(each.length)).join("|")}|`);
		row = out.lines.length - 1;
	}
	const offset = out.lines.slice(0, row).reduce((sum, each) => sum + each.length + 1, 0);
	const parts = out.lines[row].split("|");
	let inside = 0;
	for (let i = 0; i <= cell; i += 1) inside += parts[i].length + 1;
	const text = parts[cell + 1] ?? "";
	const trimmed = text.trimEnd().length;
	view.dispatch({
		changes: { from: out.from, to: out.to, insert: out.lines.join("\n") },
		selection: EditorSelection.range(out.from + offset + inside + Math.min(1, text.length), out.from + offset + inside + Math.max(trimmed, Math.min(1, text.length))),
		scrollIntoView: true,
	});
	return true;
}
