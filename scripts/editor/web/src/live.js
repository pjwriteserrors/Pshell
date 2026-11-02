// Live preview: the document stays Markdown, what the cursor is not in shows
// rendered. Marks that hide come from a view plugin over what is visible,
// whole blocks (tables, columns, pictures, previews) from a state field.
import { syntaxTree } from "@codemirror/language";
import { EditorSelection, RangeSetBuilder, StateEffect, StateField } from "@codemirror/state";
import { Decoration, EditorView, ViewPlugin, WidgetType } from "@codemirror/view";
import { fileUrl, hydrate, render } from "./render.js";
import { icon } from "./ui.js";

const hidden = Decoration.replace({});
const line = cls => Decoration.line({ class: cls });
const mark = cls => Decoration.mark({ class: cls });

export const RUNNABLE = new Set(["bash", "sh", "shell", "zsh", "fish", "python", "py", "python3"]);
const WEB = new Set(["html", "css", "js", "javascript"]);
const CALLOUTS = { note: "information_outline", info: "information_outline", tip: "lightbulb_outline", warning: "alert_outline", danger: "alert_circle_outline", todo: "check_circle_outline" };

function touches(selection, from, to) {
	return selection.ranges.some(range => range.from <= to && range.to >= from);
}

function linesTouch(state, from, to) {
	const start = state.doc.lineAt(from).from;
	const end = state.doc.lineAt(to).to;
	return touches(state.selection, start, end);
}

// ── small inline widgets ────────────────────────────────────────────────
class Bullet extends WidgetType {
	constructor(depth) { super(); this.depth = depth; }
	eq(other) { return other.depth === this.depth; }
	toDOM() {
		const span = document.createElement("span");
		span.className = `md-bullet d${this.depth % 3}`;
		return span;
	}
}

class Check extends WidgetType {
	constructor(checked, pos) { super(); this.checked = checked; this.pos = pos; }
	eq(other) { return other.checked === this.checked && other.pos === this.pos; }
	toDOM(view) {
		const box = document.createElement("span");
		box.className = `md-check${this.checked ? " on" : ""}`;
		box.setAttribute("role", "checkbox");
		box.addEventListener("mousedown", event => {
			event.preventDefault();
			const at = this.pos;
			const text = view.state.doc.sliceString(at, at + 3);
			view.dispatch({ changes: { from: at, to: at + 3, insert: text[1] === " " ? "[x]" : "[ ]" } });
		});
		return box;
	}
	ignoreEvent() { return true; }
}

class CalloutIcon extends WidgetType {
	constructor(name) { super(); this.name = name; }
	eq(other) { return other.name === this.name; }
	toDOM() {
		const span = document.createElement("span");
		span.className = "md-callout-title";
		span.append(icon(CALLOUTS[this.name]), this.name[0].toUpperCase() + this.name.slice(1));
		return span;
	}
}

class Rule extends WidgetType {
	eq() { return true; }
	toDOM() {
		const span = document.createElement("span");
		span.className = "md-rule";
		return span;
	}
}

// ── the inline pass ─────────────────────────────────────────────────────
function inline(view, fresh) {
	const { state } = view;
	const sel = state.selection;
	const found = [];
	const add = (from, to, deco) => { if (from <= to) found.push(deco.range(from, to)); };
	const shown = (from, to) => mark(fresh ? "md-marker fresh" : "md-marker").range(from, to);

	for (const { from, to } of view.visibleRanges) {
		const notes = [...state.sliceDoc(from, to).matchAll(/\[\[([^\]\n|]+)(\|[^\]\n]+)?\]\]/g)].map(match => ({ match, from: from + match.index, to: from + match.index + match[0].length }));
		syntaxTree(state).iterate({
			from, to,
			enter(node) {
				const name = node.name;
				if (notes.some(each => node.from >= each.from && node.to <= each.to)) return false;
				const onLine = () => linesTouch(state, node.from, node.to);
				const heading = name.match(/^(?:ATXHeading|SetextHeading)(\d)$/);
				if (heading) {
					for (let at = state.doc.lineAt(node.from).from; at <= node.to;) {
						const each = state.doc.lineAt(at);
						add(each.from, each.from, line(`md-h md-h${heading[1]}`));
						at = each.to + 1;
					}
					return;
				}
				switch (name) {
				case "HeaderMark": {
					const end = Math.min(node.to + 1, state.doc.lineAt(node.from).to);
					if (onLine()) found.push(shown(node.from, end));
					else if (end > node.from) add(node.from, end, hidden);
					return;
				}
				case "EmphasisMark": case "StrikethroughMark": case "LinkMark": {
					const parent = node.node.parent;
					if (parent?.name === "Image") return;
					if (parent && touches(sel, parent.from, parent.to)) found.push(shown(node.from, node.to));
					else add(node.from, node.to, hidden);
					return;
				}
				case "CodeMark": {
					const parent = node.node.parent;
					if (parent?.name !== "InlineCode") return;
					if (touches(sel, parent.from, parent.to)) found.push(shown(node.from, node.to));
					else add(node.from, node.to, hidden);
					return;
				}
				case "URL": {
					const parent = node.node.parent;
					if (parent?.name === "Link") {
						if (!touches(sel, parent.from, parent.to)) add(node.from, node.to, hidden);
					} else if (parent?.name !== "Image") {
						add(node.from, node.to, Decoration.mark({ class: "md-link", attributes: { "data-href": state.sliceDoc(node.from, node.to) } }));
					}
					return;
				}
				case "LinkTitle": {
					const parent = node.node.parent;
					if (parent && !touches(sel, parent.from, parent.to)) add(node.from, node.to, hidden);
					return;
				}
				case "Emphasis": add(node.from, node.to, mark("md-em")); return;
				case "StrongEmphasis": add(node.from, node.to, mark("md-strong")); return;
				case "Strikethrough": add(node.from, node.to, mark("md-strike")); return;
				case "InlineCode": add(node.from, node.to, mark("md-code-inline")); return;
				case "Link": {
					const url = node.node.getChild("URL");
					const href = url ? state.sliceDoc(url.from, url.to) : "";
					add(node.from, node.to, Decoration.mark({ class: "md-link", attributes: { "data-href": href } }));
					return;
				}
				case "HorizontalRule":
					if (!onLine()) add(node.from, node.to, Decoration.replace({ widget: new Rule() }));
					return;
				case "QuoteMark": {
					const end = Math.min(node.to + 1, state.doc.lineAt(node.from).to);
					if (!onLine()) add(node.from, end, hidden);
					return;
				}
				case "Blockquote": {
					let kind = "";
					const first = state.doc.lineAt(node.from);
					const callout = first.text.match(/^>\s*\[!(\w+)\]/);
					if (callout && CALLOUTS[callout[1].toLowerCase()]) kind = callout[1].toLowerCase();
					for (let at = first.from; at <= node.to;) {
						const each = state.doc.lineAt(at);
						add(each.from, each.from, line(`md-quote${kind ? ` md-callout md-callout-${kind}` : ""}${at === first.from ? " first" : ""}${each.to >= node.to ? " last" : ""}`));
						at = each.to + 1;
					}
					if (kind && !linesTouch(state, first.from, first.from)) {
						add(first.from, first.to, Decoration.replace({ widget: new CalloutIcon(kind) }));
					}
					return;
				}
				case "ListMark": {
					const parentName = node.node.parent?.parent?.name;
					const item = node.node.parent;
					const task = item?.getChild("Task");
					if (task) {
						const marker = task.getChild("TaskMarker");
						if (marker && !touches(sel, node.from, marker.to)) {
							const checked = state.sliceDoc(marker.from, marker.to).toLowerCase() === "[x]";
							add(node.from, marker.to, Decoration.replace({ widget: new Check(checked, marker.from) }));
							const body = state.doc.lineAt(node.from);
							if (checked) add(marker.to, body.to, mark("md-task-done"));
						}
						return;
					}
					if (parentName === "BulletList" && !touches(sel, node.from, node.to)) {
						let depth = 0;
						for (let up = item.parent; up; up = up.parent) if (up.name === "BulletList") depth += 1;
						add(node.from, node.to, Decoration.replace({ widget: new Bullet(depth - 1) }));
					} else if (parentName === "OrderedList") {
						add(node.from, node.to, mark("md-number"));
					}
					return;
				}
				default:
				}
			},
		});
		// [[notes]]
		for (const { match, from: start, to: end } of notes) {
			const inside = syntaxTree(state).resolveInner(start, 1).name;
			if (/Code|CodeText/.test(inside)) continue;
			add(start, end, Decoration.mark({ class: "md-wiki", attributes: { "data-wiki": match[1] } }));
			if (touches(sel, start, end)) continue;
			add(start, start + 2 + (match[2] ? match[1].length + 1 : 0), hidden);
			add(end - 2, end, hidden);
		}
	}
	return Decoration.set(dedupe(found), true);
}

// a replaced range may not overlap another: the outer one, first come, stays
function dedupe(list) {
	const sorted = list.slice().sort((a, b) => a.from - b.from || a.value.startSide - b.value.startSide || b.to - a.to);
	const out = [];
	let replacedTo = -1;
	for (const each of sorted) {
		const replacing = each.value.spec?.widget !== undefined || each.value === hidden;
		if (replacing && each.from < replacedTo) continue;
		out.push(each);
		if (replacing && each.to > replacedTo) replacedTo = each.to;
	}
	return out;
}

const inlinePlugin = ViewPlugin.fromClass(class {
	constructor(view) {
		this.line = -1;
		this.decorations = inline(view, false);
	}
	update(update) {
		const tree = syntaxTree(update.state) !== syntaxTree(update.startState);
		if (!(update.docChanged || update.viewportChanged || update.selectionSet || tree)) return;
		const at = update.state.doc.lineAt(update.state.selection.main.head).number;
		const moved = at !== this.line;
		this.line = at;
		this.decorations = inline(update.view, moved && !update.docChanged);
	}
}, {
	decorations: value => value.decorations,
	provide: plugin => [EditorView.atomicRanges.of(view => view.plugin(plugin)?.decorations.update({
		filter: (_f, _t, deco) => deco.spec.widget !== undefined || deco === hidden,
	}) ?? Decoration.none)],
});

// ── block widgets ───────────────────────────────────────────────────────
class Rendered extends WidgetType {
	constructor(text, kind, from, base) { super(); this.text = text; this.kind = kind; this.from = from; this.base = base; }
	eq(other) { return other.text === this.text && other.kind === this.kind && other.base === this.base; }
	get estimatedHeight() { return Math.max(60, this.text.split("\n").length * 28); }
	toDOM(view) {
		const box = document.createElement("div");
		box.className = `md-block md-${this.kind}`;
		if (this.kind === "table") this.table(box, view);
		else this.columns(box, view);
		box.addEventListener("mousedown", event => {
			if (event.target.closest("button, a")) return;
			event.preventDefault();
			view.focus();
			const pos = Math.min(view.posAtDOM(box) + 2, view.state.doc.length);
			view.dispatch({ selection: EditorSelection.cursor(pos), scrollIntoView: false });
		});
		return box;
	}
	table(box, view) {
		const wrap = document.createElement("div");
		wrap.className = "md-table-wrap md-rendered";
		wrap.innerHTML = render(this.text, this.base);
		hydrate(wrap);
		box.append(wrap);
		const button = (name, cls, fn) => {
			const each = document.createElement("button");
			each.className = `md-table-add ${cls}`;
			each.append(icon(name));
			each.addEventListener("mousedown", event => {
				event.preventDefault();
				event.stopPropagation();
				fn(view, view.posAtDOM(box));
			});
			return each;
		};
		box.append(button("plus", "row", addRow), button("plus", "column", addColumn));
	}
	columns(box) {
		const parts = this.text.replace(/^:::\s*columns[^\n]*\n/, "").replace(/\n?:::\s*$/, "").split(/^\|\|\|\s*$/m);
		box.style.setProperty("--columns", parts.length);
		for (const part of parts) {
			const column = document.createElement("div");
			column.className = "md-column md-rendered";
			column.innerHTML = render(part.trim(), this.base);
			hydrate(column);
			box.append(column);
		}
	}
	ignoreEvent() { return false; }
}

function tableAt(state, pos) {
	const node = syntaxTree(state).resolveInner(pos + 1, 1);
	for (let each = node; each; each = each.parent) if (each.name === "Table") return each;
	return null;
}

function addRow(view, pos) {
	const node = tableAt(view.state, pos);
	if (!node) return;
	const last = view.state.doc.lineAt(node.to);
	const cells = last.text.split("|").length - 2;
	view.dispatch({ changes: { from: last.to, insert: `\n|${"  |".repeat(Math.max(cells, 1))}` } });
}

function addColumn(view, pos) {
	const node = tableAt(view.state, pos);
	if (!node) return;
	const changes = [];
	for (let at = node.from; at <= node.to;) {
		const each = view.state.doc.lineAt(at);
		const end = each.text.trimEnd().length;
		changes.push({ from: each.from + end, insert: /^\s*\|[\s:|-]+\|\s*$/.test(each.text) ? "---|" : "  |" });
		at = each.to + 1;
	}
	view.dispatch({ changes });
}

class Picture extends WidgetType {
	constructor(src, alt, base) { super(); this.src = src; this.alt = alt; this.base = base; }
	eq(other) { return other.src === this.src && other.alt === this.alt && other.base === this.base; }
	get estimatedHeight() { return 240; }
	toDOM(view) {
		const box = document.createElement("div");
		box.className = "md-block md-picture loading";
		const img = document.createElement("img");
		img.alt = this.alt;
		img.onload = () => { box.classList.remove("loading"); view.requestMeasure(); };
		img.onerror = () => { box.classList.remove("loading"); box.classList.add("broken"); box.textContent = this.src; };
		img.src = fileUrl(this.src, this.base);
		box.append(img);
		box.addEventListener("mousedown", event => {
			event.preventDefault();
			view.focus();
			view.dispatch({ selection: EditorSelection.cursor(view.posAtDOM(box)) });
		});
		return box;
	}
	ignoreEvent() { return false; }
}

class FenceHead extends WidgetType {
	constructor(lang, group, on, from, to) { super(); this.lang = lang; this.group = group; this.on = on; this.from = from; this.to = to; }
	eq(other) { return other.lang === this.lang && other.group === this.group && other.on === this.on; }
	toDOM(view) {
		const box = document.createElement("span");
		box.className = "md-fence-head";
		const label = document.createElement("span");
		label.className = "md-lang";
		label.textContent = this.lang || "text";
		box.append(label);
		const tools = document.createElement("span");
		tools.className = "md-fence-tools";
		const add = (name, title, active, fn) => {
			const each = document.createElement("button");
			each.className = `md-fence-button${active ? " on" : ""}`;
			each.title = title;
			each.append(icon(name));
			each.addEventListener("mousedown", event => {
				event.preventDefault();
				event.stopPropagation();
				fn(view.posAtDOM(box));
			});
			tools.append(each);
		};
		add("content_copy", "Copy", false, pos => view.dom.dispatchEvent(new CustomEvent("pe-fence", { bubbles: true, detail: { action: "copy", pos } })));
		if (this.group) add(this.on ? "stop" : "play", "Render", this.on, pos => {
			view.dispatch({ effects: togglePreview.of(groupFirst(view.state, pos)) });
		});
		if (RUNNABLE.has(this.lang)) {
			add("console", "Terminal", false, pos => view.dom.dispatchEvent(new CustomEvent("pe-fence", { bubbles: true, detail: { action: "terminal", pos } })));
			add("play", "Output", false, pos => view.dom.dispatchEvent(new CustomEvent("pe-fence", { bubbles: true, detail: { action: "output", pos } })));
		}
		box.append(tools);
		return box;
	}
	ignoreEvent() { return true; }
}

// ── rendered html/css/js ────────────────────────────────────────────────
export const togglePreview = StateEffect.define();
export const previewPositions = StateField.define({
	create: () => [],
	update(value, tr) {
		let next = tr.docChanged ? value.map(pos => tr.changes.mapPos(pos, 1)) : value;
		for (const effect of tr.effects) {
			if (effect.is(togglePreview)) {
				next = next.includes(effect.value) ? next.filter(each => each !== effect.value) : next.concat(effect.value);
			}
		}
		return next;
	},
});

export function fences(state) {
	const out = [];
	syntaxTree(state).iterate({
		enter(node) {
			if (node.name === "FencedCode") {
				const info = node.node.getChild("CodeInfo");
				const lang = info ? state.sliceDoc(info.from, info.to).trim().split(/\s/)[0].toLowerCase() : "";
				out.push({ from: node.from, to: node.to, lang });
				return false;
			}
		},
	});
	return out;
}

export function fenceBody(state, fence) {
	const first = state.doc.lineAt(fence.from);
	const last = state.doc.lineAt(fence.to);
	if (first.number === last.number) return "";
	const closed = /^\s*(`{3,}|~{3,})\s*$/.test(last.text);
	const end = closed ? last.from - 1 : last.to;
	return first.to + 1 > end ? "" : state.sliceDoc(first.to + 1, end);
}

// neighbouring html, css and js blocks are one page
function webGroups(state) {
	const groups = [];
	let current = null;
	for (const fence of fences(state)) {
		if (!WEB.has(fence.lang)) { current = null; continue; }
		const between = current ? state.sliceDoc(current.to, fence.from) : "";
		if (current && between.trim() === "") {
			current.items.push(fence);
			current.to = fence.to;
		} else {
			current = { from: fence.from, to: fence.to, items: [fence] };
			groups.push(current);
		}
	}
	return groups;
}

function groupFirst(state, pos) {
	return webGroups(state).find(group => group.from <= pos && pos <= group.to)?.from ?? pos;
}

class Preview extends WidgetType {
	constructor(html, css, js, bridge) { super(); this.html = html; this.css = css; this.js = js; this.bridge = bridge; }
	eq(other) { return other.html === this.html && other.css === this.css && other.js === this.js; }
	get estimatedHeight() { return 200; }
	document() {
		const style = getComputedStyle(document.documentElement);
		const vars = ["fg", "bg", "primary", "secondary"].map(name => `--${name}:${style.getPropertyValue(`--${name}`)}`).join(";");
		return `<style>:root{${vars}}</style><style>${this.css}</style>${this.html}<script>${this.js}<\/script>`;
	}
	load(box) {
		this.bridge.call("preview", this.document()).then(id => {
			const frame = document.createElement("iframe");
			frame.setAttribute("sandbox", "allow-scripts");
			frame.dataset.preview = id;
			frame.className = "md-frame entering";
			frame.src = `pe://preview/${id}`;
			frame.addEventListener("load", () => {
				const old = box.querySelector("iframe:not(.entering)");
				frame.classList.remove("entering");
				if (old) {
					this.bridge.call("previewDrop", [old.dataset.preview]);
					setTimeout(() => old.remove(), 200);
					old.classList.add("leaving");
				}
			});
			box.append(frame);
		});
	}
	toDOM() {
		const box = document.createElement("div");
		box.className = "md-block md-preview";
		box.style.height = "96px";
		this.load(box);
		return box;
	}
	updateDOM(box) {
		this.load(box);
		return true;
	}
	destroy(box) {
		const ids = [...box.querySelectorAll("iframe")].map(each => each.dataset.preview);
		this.bridge.call("previewDrop", ids);
	}
	ignoreEvent() { return true; }
}

// ── the block pass ──────────────────────────────────────────────────────
function blocks(state, base, bridge) {
	const sel = state.selection;
	const found = [];
	const on = state.field(previewPositions);
	const inFence = [];
	const groups = webGroups(state);
	for (const fence of fences(state)) {
		inFence.push(fence);
		const first = state.doc.lineAt(fence.from);
		const last = state.doc.lineAt(fence.to);
		const active = linesTouch(state, fence.from, fence.to);
		const group = groups.find(each => each.from <= fence.from && fence.to <= each.to);
		for (let number = first.number; number <= last.number; number += 1) {
			const each = state.doc.line(number);
			const closed = !active && /^\s*(`{3,}|~{3,})\s*$/.test(last.text);
			const edge = number === first.number ? " top" : (number === last.number ? (closed ? " bottom closed" : " bottom") : "");
			found.push(line(`md-code${edge}`).range(each.from));
		}
		if (first.number !== last.number) {
			if (!active) {
				found.push(Decoration.replace({ widget: new FenceHead(fence.lang, Boolean(group), Boolean(group && on.includes(group.from))) }).range(first.from, first.to));
				if (/^\s*(`{3,}|~{3,})\s*$/.test(last.text) && last.length > 0) found.push(hidden.range(last.from, last.to));
			} else {
				found.push(Decoration.widget({ widget: new FenceHead(fence.lang, Boolean(group), Boolean(group && on.includes(group.from))), side: 1 }).range(first.to));
			}
		}
	}
	for (const group of groups) {
		if (!on.includes(group.from)) continue;
		const parts = { html: "", css: "", js: "" };
		for (const item of group.items) {
			const body = fenceBody(state, item);
			if (item.lang === "html") parts.html += `${body}\n`;
			else if (item.lang === "css") parts.css += `${body}\n`;
			else parts.js += `${body}\n`;
		}
		found.push(Decoration.widget({ widget: new Preview(parts.html, parts.css, parts.js, bridge), block: true, side: 1 }).range(state.doc.lineAt(group.to).to));
	}

	syntaxTree(state).iterate({
		enter(node) {
			if (node.name === "FencedCode") return false;
			if (node.name === "Table") {
				if (!linesTouch(state, node.from, node.to)) {
					found.push(Decoration.replace({ widget: new Rendered(state.sliceDoc(node.from, node.to), "table", node.from, base), block: true }).range(state.doc.lineAt(node.from).from, state.doc.lineAt(node.to).to));
				} else {
					for (let at = node.from; at <= node.to;) {
						const each = state.doc.lineAt(at);
						found.push(line("md-table-raw").range(each.from));
						at = each.to + 1;
					}
				}
				return false;
			}
			if (node.name === "Image") {
				const each = state.doc.lineAt(node.from);
				const whole = state.sliceDoc(node.from, node.to) === each.text.trim();
				const url = node.node.getChild("URL");
				if (whole && url && !touches(sel, each.from, each.to)) {
					const alt = state.sliceDoc(node.from + 2, url.from).replace(/\]\($/, "");
					found.push(Decoration.replace({ widget: new Picture(state.sliceDoc(url.from, url.to), alt, base), block: true }).range(each.from, each.to));
				}
				return false;
			}
		},
	});

	// ::: columns … ||| … :::
	for (let number = 1; number <= state.doc.lines; number += 1) {
		const start = state.doc.line(number);
		if (!/^:::\s*columns\b/.test(start.text)) continue;
		if (inFence.some(each => each.from <= start.from && start.from <= each.to)) continue;
		let end = number + 1;
		while (end <= state.doc.lines && !/^:::\s*$/.test(state.doc.line(end).text)) end += 1;
		if (end > state.doc.lines) break;
		const close = state.doc.line(end);
		if (!touches(sel, start.from, close.to)) {
			found.push(Decoration.replace({ widget: new Rendered(state.sliceDoc(start.from, close.to), "columns", start.from, base), block: true }).range(start.from, close.to));
		} else {
			for (let each = number; each <= end; each += 1) {
				const row = state.doc.line(each);
				found.push(line(/^(:::|\|\|\|)/.test(row.text) ? "md-columns-raw edge" : "md-columns-raw").range(row.from));
			}
		}
		number = end;
	}

	// front matter
	if (state.doc.line(1).text === "---") {
		for (let number = 2; number <= Math.min(state.doc.lines, 60); number += 1) {
			if (state.doc.line(number).text === "---") {
				for (let each = 1; each <= number; each += 1) found.push(line("md-front").range(state.doc.line(each).from));
				break;
			}
		}
	}
	return Decoration.set(found.sort((a, b) => a.from - b.from || a.value.startSide - b.value.startSide), true);
}

export function livePreview(base, bridge) {
	const field = StateField.define({
		create: state => blocks(state, base, bridge),
		update(value, tr) {
			const changed = tr.docChanged || tr.selection || syntaxTree(tr.state) !== syntaxTree(tr.startState)
				|| tr.effects.some(effect => effect.is(togglePreview));
			return changed ? blocks(tr.state, base, bridge) : value;
		},
		provide: each => [EditorView.decorations.from(each), EditorView.atomicRanges.of(view => view.state.field(each).update({
			filter: (_f, _t, deco) => deco.spec.widget !== undefined && deco.spec.block,
		}))],
	});
	return [previewPositions, field, inlinePlugin];
}

// a preview tells how tall it is
window.addEventListener("message", event => {
	const data = event.data;
	if (!data || typeof data.preview !== "string") return;
	const frame = document.querySelector(`iframe[data-preview="${CSS.escape(data.preview)}"]`);
	if (!frame || frame.contentWindow !== event.source) return;
	const box = frame.parentElement;
	if (typeof data.height === "number") {
		box.style.height = `${Math.min(Math.max(48, data.height), 900)}px`;
		frame.closest(".cm-editor")?.dispatchEvent(new CustomEvent("pe-measure"));
	}
	if (data.error) box.dataset.error = String(data.error).slice(0, 200);
});
