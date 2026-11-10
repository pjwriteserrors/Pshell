// The page: documents, tabs in panes, the sidebar, the commands.
import { syntaxTree } from "@codemirror/language";
import { openSearchPanel } from "@codemirror/search";
import { EditorSelection, Transaction } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { createView, isMarkdown } from "./editor.js";
import { fenceBody, fences, previewPositions, togglePreview } from "./live.js";
import { hydrate, render } from "./render.js";
import * as format from "./format.js";
import { animate, ask, confirmDialog, el, flip, fuzzy, icon, iconButton, menu, motion, overlay, palette, rollText, segmented, toast } from "./ui.js";
import "./style.css";

const { token, kind } = window.__pe ?? { token: "", kind: "main" };
const scratch = kind === "scratch";
export const bridge = {
	async call(method, ...args) {
		const raw = await window.webkit.messageHandlers.bridge.postMessage({ token, method, args });
		return JSON.parse(raw);
	},
};

const dirname = path => path.replace(/\/[^/]*$/, "") || "/";
const basename = path => path.replace(/^.*\//, "");
let home = "";
const pretty = path => (home && path.startsWith(home) ? `~${path.slice(home.length)}` : path);
let serial = 0;
const newId = () => ++serial;

// ── documents ───────────────────────────────────────────────────────────
const docs = new Map();

function newDoc({ path = null, text = "", saved = text, mtime = 0, crlf = false, readonly = false }) {
	const doc = { id: newId(), path, initial: text, saved, mtime, crlf, readonly, tabs: new Set(), banner: null };
	docs.set(doc.id, doc);
	return doc;
}

const docName = doc => (doc.path ? basename(doc.path) : (doc.untitled ?? "Untitled"));
const docText = doc => {
	const tab = [...doc.tabs].find(each => each.view);
	return tab ? tab.view.state.doc.toString() : doc.initial;
};
const isDirty = doc => !scratch && docText(doc) !== doc.saved;

function refreshDoc(doc) {
	for (const tab of doc.tabs) {
		tab.button?.classList.toggle("dirty", isDirty(doc));
		const label = tab.button?.querySelector(".tab-title");
		if (label) label.textContent = docName(doc);
	}
	saveSoon();
}

// ── panes: a tree of splits with panes as leaves ────────────────────────
let root = null;
let activePane = null;
const app = document.getElementById("app");
const stage = el("div", "stage");

function createPane() {
	const pane = { type: "pane", id: newId(), tabs: [], active: null, size: 1, parent: null };
	pane.dom = el("section", "pane");
	pane.bar = el("div", "tabbar");
	pane.strip = el("div", "tabs");
	pane.indicator = el("div", "tab-indicator");
	pane.strip.append(pane.indicator);
	pane.watcher = new ResizeObserver(() => placeIndicator(pane));
	pane.bar.append(pane.strip, iconButton("plus", "New", () => { setActive(pane); newUntitled(); }, "bar-action"));
	pane.body = el("div", "pane-body", sheetEdge(pane, "left"), sheetEdge(pane, "right"));
	pane.banner = el("div", "banner-slot");
	if (!scratch) pane.dom.append(pane.bar);
	pane.dom.append(pane.banner, pane.body);
	pane.dom.addEventListener("mousedown", () => setActive(pane), true);
	drawEmpty(pane);
	return pane;
}

function createSplit(direction, children) {
	const split = { type: "split", direction, children, size: 1, parent: null };
	split.dom = el("div", `split ${direction}`);
	children.forEach(child => { child.parent = split; });
	return split;
}

function layoutDom(node) {
	if (node.type === "pane") {
		node.dom.style.flexGrow = node.size;
		return node.dom;
	}
	node.dom.replaceChildren();
	node.dom.style.flexGrow = node.size;
	node.children.forEach((child, index) => {
		if (index > 0) node.dom.append(gutter(node, index));
		node.dom.append(layoutDom(child));
	});
	return node.dom;
}

function redraw() {
	stage.replaceChildren(layoutDom(root));
	allPanes().forEach(placeIndicator);
	measureAll();
}

function gutter(split, index) {
	const handle = el("div", "gutter");
	handle.addEventListener("pointerdown", event => {
		event.preventDefault();
		handle.setPointerCapture(event.pointerId);
		const a = split.children[index - 1];
		const b = split.children[index];
		const vertical = split.direction === "down";
		const box = a.dom.getBoundingClientRect();
		const other = b.dom.getBoundingClientRect();
		const total = vertical ? box.height + other.height : box.width + other.width;
		const sum = a.size + b.size;
		const start = vertical ? event.clientY : event.clientX;
		const first = vertical ? box.height : box.width;
		stage.classList.add("resizing");
		const move = moved => {
			const delta = (vertical ? moved.clientY : moved.clientX) - start;
			const share = Math.min(0.9, Math.max(0.1, (first + delta) / total));
			a.size = share * sum;
			b.size = (1 - share) * sum;
			a.dom.style.flexGrow = a.size;
			b.dom.style.flexGrow = b.size;
		};
		const up = () => {
			handle.removeEventListener("pointermove", move);
			handle.removeEventListener("pointerup", up);
			stage.classList.remove("resizing");
			measureAll();
			saveSoon();
		};
		handle.addEventListener("pointermove", move);
		handle.addEventListener("pointerup", up);
	});
	handle.addEventListener("dblclick", () => {
		const mean = (split.children[index - 1].size + split.children[index].size) / 2;
		for (const each of [split.children[index - 1], split.children[index]]) {
			each.size = mean;
			each.dom.style.flexGrow = mean;
		}
		saveSoon();
	});
	return handle;
}

function allPanes(node = root, out = []) {
	if (!node) return out;
	if (node.type === "pane") out.push(node);
	else node.children.forEach(child => allPanes(child, out));
	return out;
}

function measureAll() {
	for (const pane of allPanes()) pane.active?.view?.requestMeasure();
}

function setActive(pane) {
	if (activePane === pane) return;
	activePane?.dom.classList.remove("active");
	activePane = pane;
	pane.dom.classList.add("active");
	updateChrome();
}

// a new pane beside `target`; it grows out of nothing
function splitPane(target, direction, before = false) {
	const pane = createPane();
	const wanted = direction === "down" ? "down" : "right";
	if (target.parent?.direction === wanted) {
		const parent = target.parent;
		const at = parent.children.indexOf(target);
		pane.parent = parent;
		pane.size = target.size / 2;
		target.size /= 2;
		parent.children.splice(before ? at : at + 1, 0, pane);
	} else {
		const parent = target.parent;
		const split = createSplit(wanted, before ? [pane, target] : [target, pane]);
		split.size = target.size;
		target.size = 1;
		pane.size = 1;
		split.parent = parent;
		if (parent) parent.children[parent.children.indexOf(target)] = split;
		else root = split;
	}
	const size = pane.size;
	pane.size = 0.0001;
	stage.classList.add("instant");
	redraw();
	void pane.dom.offsetWidth;
	stage.classList.remove("instant");
	pane.size = size;
	pane.dom.style.flexGrow = size;
	if (target.parent) target.dom.style.flexGrow = target.size;
	setTimeout(measureAll, motion.long + 20);
	setActive(pane);
	return pane;
}

async function removePane(pane) {
	const parent = pane.parent;
	if (!parent) return;
	const index = parent.children.indexOf(pane);
	const neighbour = parent.children[index - 1] ?? parent.children[index + 1];
	pane.dom.style.flexGrow = 0.0001;
	pane.dom.classList.add("leaving");
	parent.children.splice(index, 1);
	neighbour.size += pane.size;
	neighbour.dom.style.flexGrow = neighbour.size;
	if (activePane === pane) {
		activePane = null;
		setActive(firstPane(neighbour));
	}
	await new Promise(done => setTimeout(done, motion.medium));
	if (parent.children.length === 1) {
		const only = parent.children[0];
		only.size = parent.size;
		only.parent = parent.parent;
		if (parent.parent) parent.parent.children[parent.parent.children.indexOf(parent)] = only;
		else root = only;
	}
	redraw();
	saveSoon();
}

function firstPane(node) {
	return node.type === "pane" ? node : firstPane(node.children[0]);
}

function drawEmpty(pane) {
	if (pane.tabs.length > 0 || scratch) {
		pane.empty?.remove();
		pane.empty = null;
		return;
	}
	if (pane.empty) return;
	const list = el("div", "empty-list");
	pane.empty = el("div", "empty", icon("text_box_outline", "empty-icon"), list);
	pane.body.append(pane.empty);
	animate(pane.empty, [{ opacity: 0, transform: "scale(.97)" }, { opacity: 1, transform: "none" }], motion.long, motion.spatial);
	bridge.call("recent").then(paths => {
		paths.slice(0, 6).forEach((path, index) => {
			const row = el("button", "empty-row", icon(isMarkdown(path) ? "language_markdown_outline" : "file_outline"), el("span", "", basename(path)), el("span", "muted", pretty(dirname(path))));
			row.addEventListener("click", () => { setActive(pane); openPath(path); });
			animate(row, [{ opacity: 0, transform: "translateY(8px)" }, { opacity: 1, transform: "none" }], motion.medium, motion.decel, { delay: index * 28 });
			list.append(row);
		});
	});
}

// ── tabs ────────────────────────────────────────────────────────────────
function createTab(doc, mode) {
	const tab = { id: newId(), doc, mode: mode ?? (isMarkdown(doc.path) ? "live" : "source"), columns: 1, host: el("div", "tab-host"), view: null, pane: null, button: null };
	doc.tabs.add(tab);
	tab.host.addEventListener("pe-fence", onFence);
	tab.button = tabButton(tab);
	return tab;
}

function tabButton(tab) {
	const dot = el("span", "tab-dot");
	const close = iconButton("close", "Close", () => closeTab(tab), "tab-close");
	const button = el("div", "tab", icon(isMarkdown(tab.doc.path) ? "language_markdown_outline" : "file_outline", "tab-icon"), el("span", "tab-title", docName(tab.doc)), el("span", "tab-end", dot, close));
	button.addEventListener("pointerdown", event => {
		if (event.button === 1) { event.preventDefault(); closeTab(tab); return; }
		if (event.button !== 0 || event.target.closest(".tab-close")) return;
		setActive(tab.pane);
		activateTab(tab);
		dragTab(tab, event);
	});
	button.addEventListener("contextmenu", event => {
		event.preventDefault();
		menu(event.clientX, event.clientY, [
			{ title: "Close", icon: "close", keys: "Ctrl+W", run: () => closeTab(tab) },
			{ title: "Close others", run: () => tab.pane.tabs.filter(each => each !== tab).forEach(closeTab) },
			"-",
			{ title: "Split right", icon: "view_column_outline", keys: "Ctrl+\\", run: () => splitWith(tab, "right") },
			{ title: "Split down", icon: "split_horizontal", keys: "Ctrl+Shift+\\", run: () => splitWith(tab, "down") },
			...(tab.doc.path ? ["-", { title: "Copy path", icon: "content_copy", run: () => bridge.call("copy", tab.doc.path) }, { title: "Put on shelf", icon: "tray_arrow_down", run: () => toShelf(tab.doc.path) }, { title: "Send to phone", icon: "cellphone_arrow_down", run: () => bridge.call("phoneFile", tab.doc.path) }] : []),
		]);
	});
	return button;
}

function placeIndicator(pane) {
	const button = pane.active?.button;
	if (button && pane.watched !== button) {
		pane.watcher.disconnect();
		pane.watcher.observe(button);
		pane.watched = button;
	}
	if (!button || !button.offsetWidth) {
		pane.indicator.style.opacity = 0;
		return;
	}
	pane.indicator.style.opacity = 1;
	pane.indicator.style.width = `${button.offsetWidth}px`;
	pane.indicator.style.transform = `translateX(${button.offsetLeft}px)`;
}

function addTab(tab, pane, index = pane.tabs.length) {
	tab.pane = pane;
	pane.tabs.splice(index, 0, tab);
	pane.strip.insertBefore(tab.button, pane.tabs[index + 1]?.button ?? null);
	const width = tab.button.offsetWidth;
	animate(tab.button, [{ opacity: 0, maxWidth: "0px", transform: "scale(.8)" }, { opacity: 1, maxWidth: `${width}px`, transform: "none" }], motion.medium, motion.spatial);
	pane.body.append(tab.host);
	drawEmpty(pane);
}

function ensureView(tab) {
	if (tab.view || tab.mode === "reader-only") return;
	const { doc } = tab;
	const sibling = [...doc.tabs].find(each => each.view);
	tab.view = createView({
		text: sibling ? sibling.view.state.doc.toString() : doc.initial,
		path: doc.path,
		base: doc.path ? dirname(doc.path) : home,
		mode: tab.mode,
		app: appApi,
		parent: tab.host,
		onUpdate: update => onViewUpdate(tab, update),
	});
	if (tab.previews?.length) {
		const starts = fences(tab.view.state).filter(each => /^(html|css|js|javascript)$/.test(each.lang));
		const positions = tab.previews.map(index => starts[index]?.from).filter(pos => pos !== undefined);
		tab.view.dispatch({ effects: positions.map(pos => togglePreview.of(pos)) });
	}
	if (tab.selection !== undefined) {
		const at = Math.min(tab.selection, tab.view.state.doc.length);
		tab.view.dispatch({ selection: EditorSelection.cursor(at), effects: EditorView.scrollIntoView(at, { y: "center" }) });
		tab.selection = undefined;
	}
	if (doc.readonly) tab.view.contentDOM.setAttribute("contenteditable", "false");
}

function onViewUpdate(tab, update) {
	const { doc } = tab;
	if (update.docChanged) {
		const remote = update.transactions.some(each => each.annotation(Transaction.remote));
		if (!remote) {
			for (const other of doc.tabs) {
				if (other === tab || !other.view) continue;
				for (const each of update.transactions) {
					if (each.docChanged) other.view.dispatch({ changes: each.changes, annotations: [Transaction.remote.of(true), Transaction.addToHistory.of(false)] });
				}
			}
		}
		refreshDoc(doc);
		if (tab.mode === "reader") drawReader(tab);
	}
	if (tab === activePane?.active && (update.docChanged || update.selectionSet)) updateChrome();
	if (update.docChanged && scratch) saveSoon();
}

function activateTab(tab, focus = true) {
	const { pane } = tab;
	const previous = pane.active;
	if (previous && previous !== tab) {
		previous.host.classList.remove("shown");
		previous.button.classList.remove("on");
	}
	pane.active = tab;
	ensureView(tab);
	drawMode(tab);
	tab.host.classList.add("shown");
	tab.button.classList.add("on");
	placeIndicator(pane);
	tab.button.scrollIntoView({ block: "nearest", inline: "nearest" });
	if (previous !== tab) animate(tab.host, [{ opacity: 0, transform: "translateY(4px)" }, { opacity: 1, transform: "none" }], motion.medium, motion.decel);
	tab.view?.requestMeasure();
	if (focus && tab.mode !== "reader") tab.view?.focus();
	updateChrome();
	saveSoon();
}

async function closeTab(tab) {
	const { doc, pane } = tab;
	if (doc.tabs.size === 1 && isDirty(doc)) {
		const choice = await confirmDialog(`Save ${docName(doc)}?`, [
			{ label: "Cancel", value: null },
			{ label: "Discard", value: "discard", tone: "danger" },
			{ label: "Save", value: "save", tone: "primary" },
		]);
		if (!choice) return;
		if (choice === "save" && !(await saveDoc(doc))) return;
	}
	const index = pane.tabs.indexOf(tab);
	pane.tabs.splice(index, 1);
	const next = pane.tabs[index] ?? pane.tabs[index - 1];
	if (pane.active === tab) {
		pane.active = null;
		if (next) activateTab(next);
	}
	placeIndicator(pane);
	tab.host.remove();
	doc.tabs.delete(tab);
	const button = tab.button;
	const width = button.offsetWidth;
	button.style.pointerEvents = "none";
	animate(button, [{ opacity: 1, maxWidth: `${width}px` }, { opacity: 0, maxWidth: "0px", paddingLeft: 0, paddingRight: 0 }], motion.short, motion.standard, { fill: "forwards" }).finished.then(() => {
		button.remove();
		placeIndicator(pane);
	});
	tab.view?.destroy();
	if (doc.tabs.size === 0) docs.delete(doc.id);
	drawEmpty(pane);
	if (pane.tabs.length === 0 && pane.parent) removePane(pane);
	updateChrome();
	watchFiles();
	saveSoon();
}

function moveTab(tab, target, index) {
	const from = tab.pane;
	if (from === target) {
		flip(() => [...target.strip.querySelectorAll(".tab")], () => {
			const at = target.tabs.indexOf(tab);
			target.tabs.splice(at, 1);
			target.tabs.splice(index, 0, tab);
			target.strip.insertBefore(tab.button, target.tabs[index + 1]?.button ?? null);
		});
		requestAnimationFrame(() => placeIndicator(target));
		saveSoon();
		return;
	}
	from.tabs.splice(from.tabs.indexOf(tab), 1);
	const next = from.tabs[0];
	if (from.active === tab) {
		from.active = null;
		if (next) activateTab(next, false);
	}
	placeIndicator(from);
	addTab(tab, target, index);
	setActive(target);
	activateTab(tab);
	drawEmpty(from);
	if (from.tabs.length === 0 && from.parent) removePane(from);
}

function splitWith(tab, direction) {
	const pane = splitPane(tab.pane, direction);
	const copy = createTab(tab.doc, tab.mode);
	addTab(copy, pane);
	activateTab(copy);
}

// a tab goes along with the pointer: within its strip it reorders, over a
// pane it opens there or at an edge splits it
function dragTab(tab, start) {
	const button = tab.button;
	let ghost = null;
	let zone = null;
	let drop = null;
	const move = event => {
		if (!ghost) {
			if (Math.hypot(event.clientX - start.clientX, event.clientY - start.clientY) < 6) return;
			ghost = button.cloneNode(true);
			ghost.classList.add("tab-ghost");
			document.body.append(ghost);
			button.classList.add("dragged");
			zone = el("div", "drop-zone");
			document.body.append(zone);
		}
		ghost.style.transform = `translate(${event.clientX - 40}px,${event.clientY - 16}px) rotate(-1.5deg)`;
		drop = null;
		zone.classList.remove("on");
		for (const pane of allPanes()) {
			const barRect = pane.bar.getBoundingClientRect();
			if (event.clientY >= barRect.top && event.clientY <= barRect.bottom && event.clientX >= barRect.left && event.clientX <= barRect.right) {
				const others = pane.tabs.filter(each => each !== tab);
				let index = others.findIndex(each => {
					const rect = each.button.getBoundingClientRect();
					return event.clientX < rect.left + rect.width / 2;
				});
				if (index < 0) index = others.length;
				drop = { pane, index };
				if (pane === tab.pane && pane.tabs.indexOf(tab) !== index) moveTab(tab, pane, index);
				return;
			}
			const rect = pane.body.getBoundingClientRect();
			if (event.clientX < rect.left || event.clientX > rect.right || event.clientY < rect.top || event.clientY > rect.bottom) continue;
			const x = (event.clientX - rect.left) / rect.width;
			const y = (event.clientY - rect.top) / rect.height;
			const edge = Math.min(x, 1 - x, y, 1 - y);
			let side = "center";
			if (edge < 0.25) side = edge === x ? "left" : edge === 1 - x ? "right" : edge === y ? "up" : "down";
			if (side === "center" && pane === tab.pane) return;
			if (side !== "center" && pane === tab.pane && pane.tabs.length === 1) return;
			drop = { pane, side };
			zone.classList.add("on");
			zone.style.left = `${rect.left + (side === "right" ? rect.width / 2 : 0)}px`;
			zone.style.top = `${rect.top + (side === "down" ? rect.height / 2 : 0)}px`;
			zone.style.width = `${side === "left" || side === "right" ? rect.width / 2 : rect.width}px`;
			zone.style.height = `${side === "up" || side === "down" ? rect.height / 2 : rect.height}px`;
			return;
		}
	};
	const up = () => {
		button.removeEventListener("pointermove", move);
		button.removeEventListener("pointerup", up);
		button.classList.remove("dragged");
		ghost?.remove();
		zone?.remove();
		if (!drop) return;
		if (drop.side && drop.side !== "center") {
			const pane = splitPane(drop.pane, drop.side === "up" || drop.side === "down" ? "down" : "right", drop.side === "left" || drop.side === "up");
			moveTab(tab, pane, 0);
		} else if (drop.pane !== tab.pane) {
			moveTab(tab, drop.pane, drop.index ?? drop.pane.tabs.length);
		}
	};
	button.setPointerCapture(start.pointerId);
	button.addEventListener("pointermove", move);
	button.addEventListener("pointerup", up);
}

// ── opening and saving ──────────────────────────────────────────────────
function findDoc(path) {
	return [...docs.values()].find(doc => doc.path === path);
}

async function openPath(path, { line = 0, column = 0, pane = activePane } = {}) {
	let doc = findDoc(path);
	let tab = doc ? [...doc.tabs].find(each => each.pane === pane) ?? [...doc.tabs][0] : null;
	if (!doc) {
		const read = await bridge.call("read", path);
		if (read.error) {
			toast(`${basename(path)}: ${read.error}`, "danger");
			return null;
		}
		doc = newDoc({ path, text: read.text ?? "", mtime: read.mtime ?? 0, crlf: read.crlf, readonly: read.writable === false });
		tab = createTab(doc);
		addTab(tab, pane);
		watchFiles();
	}
	setActive(tab.pane);
	activateTab(tab);
	if (line > 0 && tab.view) {
		const each = tab.view.state.doc.line(Math.min(line, tab.view.state.doc.lines));
		const at = Math.min(each.from + Math.max(column - (column ? 1 : 0), 0), each.to);
		tab.view.dispatch({ selection: EditorSelection.cursor(at), effects: EditorView.scrollIntoView(at, { y: "center" }) });
	}
	return tab;
}

function newUntitled() {
	const used = new Set([...docs.values()].map(each => each.untitled));
	let number = 1;
	while (used.has(`Untitled ${number}`)) number += 1;
	const doc = newDoc({ text: "" });
	doc.untitled = `Untitled ${number}`;
	const tab = createTab(doc);
	addTab(tab, activePane);
	activateTab(tab);
	return tab;
}

async function saveDoc(doc, as = false) {
	if (doc.readonly && !as) {
		toast("Read-only", "danger");
		return false;
	}
	let path = doc.path;
	if (!path || as) {
		const typed = await ask("Save as", path ? pretty(path) : pretty(`${home}/${docName(doc).replace(/\s+/g, "-")}.md`));
		if (!typed) return false;
		path = typed.replace(/^~/, home);
		if (!path.startsWith("/")) path = `${home}/${path}`;
		const there = await bridge.call("stat", path);
		if (there.exists && path !== doc.path) {
			const sure = await confirmDialog(`${basename(path)} exists`, [{ label: "Cancel", value: false }, { label: "Replace", value: true, tone: "danger" }]);
			if (!sure) return false;
		}
	}
	const text = docText(doc);
	const same = path === doc.path;
	const done = await bridge.call("write", path, text, same ? doc.mtime : null, doc.crlf);
	if (done.conflict) {
		const choice = await confirmDialog(`${docName(doc)} changed on disk`, [
			{ label: "Cancel", value: null },
			{ label: "Overwrite", value: "write", tone: "danger" },
		]);
		if (choice !== "write") return false;
		doc.mtime = 0;
		return saveDoc(doc);
	}
	if (done.error) {
		toast(done.error, "danger");
		return false;
	}
	const changedPath = path !== doc.path;
	doc.path = path;
	doc.mtime = done.mtime;
	doc.saved = text;
	doc.selfWrite = done.mtime;
	refreshDoc(doc);
	for (const tab of doc.tabs) {
		tab.button.classList.remove("saved-pulse");
		void tab.button.offsetWidth;
		tab.button.classList.add("saved-pulse");
		if (changedPath) {
			tab.button.querySelector(".tab-icon").textContent = icon(isMarkdown(path) ? "language_markdown_outline" : "file_outline").textContent;
		}
	}
	clearBanner(doc);
	watchFiles();
	updateChrome();
	refreshTree();
	return true;
}

function watchFiles() {
	const paths = [...docs.values()].map(doc => doc.path).filter(Boolean);
	bridge.call("watch", paths);
}

function clearBanner(doc) {
	for (const tab of doc.tabs) {
		const old = tab.pane?.banner.querySelector(`[data-doc="${doc.id}"]`);
		if (old) closeBanner(old);
	}
}

function closeBanner(banner) {
	animate(banner, [{ height: `${banner.offsetHeight}px`, opacity: 1 }, { height: "0px", opacity: 0 }], motion.short, motion.standard, { fill: "forwards" }).finished.then(() => banner.remove());
}

function showBanner(doc, text, actions) {
	clearBanner(doc);
	for (const tab of doc.tabs) {
		if (!tab.pane) continue;
		const banner = el("div", "banner", icon("alert_outline"), el("span", "", text));
		banner.dataset.doc = doc.id;
		for (const action of actions) {
			const button = el("button", "text-button", action.label);
			button.addEventListener("click", () => { closeBanner(banner); action.run(); });
			banner.append(button);
		}
		tab.pane.banner.append(banner);
		animate(banner, [{ height: "0px", opacity: 0 }, { height: `${banner.offsetHeight}px`, opacity: 1 }], motion.medium, motion.spatial);
	}
}

function setDocText(doc, text) {
	const tab = [...doc.tabs].find(each => each.view);
	if (tab) tab.view.dispatch({ changes: { from: 0, to: tab.view.state.doc.length, insert: text }, selection: EditorSelection.cursor(Math.min(tab.view.state.selection.main.head, text.length)) });
	else doc.initial = text;
}

async function onFileChanged({ path, exists, mtime }) {
	const doc = findDoc(path);
	if (!doc || mtime === doc.mtime) return;
	if (!exists) {
		showBanner(doc, "Deleted on disk", [{ label: "Close", run: () => [...doc.tabs].forEach(closeTab) }, { label: "Keep", run: () => { doc.saved = null; refreshDoc(doc); } }]);
		return;
	}
	const read = await bridge.call("read", path);
	if (read.error || read.text === undefined || read.text === doc.saved) {
		if (read.mtime) doc.mtime = read.mtime;
		return;
	}
	const load = () => {
		doc.saved = read.text;
		doc.mtime = read.mtime;
		setDocText(doc, read.text);
		refreshDoc(doc);
	};
	// a clean document follows the file, as nothing of the user's can be lost
	if (!isDirty(doc)) load();
	else showBanner(doc, "Changed on disk", [{ label: "Reload", run: load }, { label: "Keep", run: () => { doc.mtime = read.mtime; } }]);
}

// ── modes ───────────────────────────────────────────────────────────────
function drawReader(tab) {
	if (!tab.reader) return;
	const sheet = tab.reader.firstElementChild;
	sheet.innerHTML = render(docText(tab.doc), tab.doc.path ? dirname(tab.doc.path) : home);
	hydrate(sheet);
	sheet.style.setProperty("--reader-columns", tab.columns);
	sheet.classList.toggle("multi", tab.columns > 1);
}

function drawMode(tab) {
	if (tab.mode === "reader") {
		if (!tab.reader) {
			tab.reader = el("div", "reader", el("article", "reader-sheet md-rendered"));
			tab.reader.addEventListener("click", onRenderedClick);
			tab.host.append(tab.reader);
		}
		drawReader(tab);
	}
	tab.host.classList.toggle("reading", tab.mode === "reader");
	tab.reader?.classList.toggle("shown", tab.mode === "reader");
}

function setMode(tab, mode) {
	if (tab.mode === mode) return;
	const leftLive = tab.mode === "live" || mode === "live";
	tab.mode = mode;
	if (leftLive && tab.view && mode !== "reader") tab.view.peSetMode(mode);
	drawMode(tab);
	const showing = mode === "reader" ? tab.reader : tab.view?.dom;
	if (showing) animate(showing, [{ opacity: 0, transform: "translateY(6px)" }, { opacity: 1, transform: "none" }], motion.medium, motion.decel);
	if (mode !== "reader") tab.view?.focus();
	updateChrome();
	saveSoon();
}

// ── the bottom line ─────────────────────────────────────────────────────
const status = {};
function buildStatus() {
	status.box = el("footer", "status");
	status.path = el("span", "status-path");
	status.modes = segmented([
		{ value: "live", icon: "pencil_outline", title: "Live" },
		{ value: "source", icon: "code_tags", title: "Source" },
		{ value: "reader", icon: "book_open_page_variant", title: "Reader" },
	], "live", value => activePane?.active && setMode(activePane.active, value));
	status.columns = segmented([1, 2, 3].map(value => ({ value, label: String(value), title: `${value}` })), 1, value => {
		const tab = activePane?.active;
		if (tab) { tab.columns = value; drawReader(tab); saveSoon(); }
	});
	status.columns.classList.add("status-columns");
	status.words = rollText();
	status.position = rollText();
	status.sidebar = iconButton("dock_left", "Sidebar", toggleSidebar);
	status.box.append(status.sidebar, status.path, el("span", "spacer"), status.position, el("span", "status-sep"), status.words, status.columns, status.modes);
	return status.box;
}

let chromeTimer = 0;
function updateChrome() {
	if (chromeTimer) return;
	chromeTimer = requestAnimationFrame(() => {
		chromeTimer = 0;
		const tab = activePane?.active;
		const dirtyCount = [...docs.values()].filter(isDirty).length;
		const text = tab ? docText(tab.doc) : "";
		const words = (text.match(/\S+/g) || []).length;
		if (status.box) {
			status.path.textContent = tab ? (tab.doc.path ? pretty(tab.doc.path) : docName(tab.doc)) : "";
			status.words.set(words);
			const head = tab?.view?.state.selection.main.head ?? 0;
			const line = tab?.view?.state.doc.lineAt(head);
			status.position.set(line ? `${line.number}:${head - line.from + 1}` : "");
			status.modes.classList.toggle("hidden", !tab || !isMarkdown(tab.doc.path));
			if (tab) status.modes.set(tab.mode);
			status.columns.classList.toggle("shown", tab?.mode === "reader");
			if (tab) status.columns.set(tab.columns);
		}
		const title = tab ? `${docName(tab.doc)} – Pshell Editor` : "Pshell Editor";
		if (!scratch) {
			bridge.call("title", title);
			bridge.call("status", { open: true, tabs: [...docs.values()].length, unsaved: dirtyCount, title: tab ? docName(tab.doc) : "", path: tab?.doc.path ?? "", words });
		}
		drawOutline();
		tellProse();
	});
}

// Autocorrect (the shell's, it types) only where the cursor stands in running
// text: not in code, a link's address, front matter or a file that is code.
const NOT_PROSE = new Set(["FencedCode", "CodeBlock", "InlineCode", "CodeText", "HTMLBlock", "HTMLTag", "CommentBlock", "ProcessingInstructionBlock", "URL", "Autolink", "LinkReference"]);
function inProse() {
	const tab = activePane?.active;
	const view = tab?.view;
	if (!view || tab.mode === "reader" || !isMarkdown(tab.doc.path) || tab.doc.readonly || !view.hasFocus) return false;
	const { state } = view;
	if (state.selection.ranges.length > 1) return false;
	const head = state.selection.main.head;
	for (let node = syntaxTree(state).resolveInner(head, -1); node; node = node.parent) if (NOT_PROSE.has(node.name)) return false;
	const line = state.doc.lineAt(head);
	if (/\[\[[^\]]*$/.test(line.text.slice(0, head - line.from))) return false;
	if (state.doc.line(1).text.trimEnd() === "---") {
		for (let number = 2; number <= Math.min(state.doc.lines, 200); number += 1) {
			if (/^(---|\.\.\.)\s*$/.test(state.doc.line(number).text)) { if (line.number <= number) return false; break; }
		}
	}
	return true;
}
let proseTold = null;
function tellProse() {
	const on = inProse();
	if (on === proseTold) return;
	proseTold = on;
	bridge.call("prose", on);
}
addEventListener("focusin", () => updateChrome());
addEventListener("focusout", () => setTimeout(updateChrome));

// ── sidebar ─────────────────────────────────────────────────────────────
const side = { open: false, view: "files", roots: [], opened: new Set() };
function buildSidebar() {
	side.box = el("aside", "sidebar");
	side.tree = el("div", "tree");
	side.outline = el("div", "outline");
	const tabs = segmented([{ value: "files", icon: "folder_outline", title: "Files" }, { value: "outline", icon: "format_list_bulleted", title: "Outline" }], "files", value => {
		side.view = value;
		side.tree.classList.toggle("shown", value === "files");
		side.outline.classList.toggle("shown", value === "outline");
		animate(value === "files" ? side.tree : side.outline, [{ opacity: 0, transform: `translateX(${value === "files" ? -10 : 10}px)` }, { opacity: 1, transform: "none" }], motion.medium, motion.decel);
		saveSoon();
	});
	side.tabs = tabs;
	side.tree.classList.add("shown");
	side.box.append(el("div", "sidebar-head", tabs, iconButton("folder", "Open folder", openFolder)), side.tree, side.outline);
	return side.box;
}

function toggleSidebar(force) {
	side.open = typeof force === "boolean" ? force : !side.open;
	app.classList.toggle("side-open", side.open);
	status.sidebar?.classList.toggle("on", side.open);
	if (side.open) refreshTree();
	setTimeout(() => { measureAll(); allPanes().forEach(placeIndicator); }, motion.long + 20);
	saveSoon();
}

async function openFolder() {
	const typed = await ask("Folder", pretty(side.roots[0] ?? home));
	if (!typed) return;
	const path = typed.replace(/^~/, home).replace(/\/$/, "");
	const info = await bridge.call("stat", path);
	if (!info.dir) { toast("Not a folder", "danger"); return; }
	if (!side.roots.includes(path)) side.roots.unshift(path);
	side.opened.add(path);
	toggleSidebar(true);
	refreshTree();
}

async function treeRow(entry, depth) {
	const open = side.opened.has(entry.path);
	const row = el("button", `tree-row${entry.dir ? " folder" : ""}${open ? " open" : ""}`, entry.dir ? icon("chevron_right", "tree-chevron") : el("span", "tree-gap"), icon(entry.dir ? (open ? "folder_open" : "folder") : (isMarkdown(entry.path) ? "language_markdown_outline" : "file_outline")), el("span", "tree-name", entry.name));
	row.style.paddingLeft = `${8 + depth * 14}px`;
	row.dataset.path = entry.path;
	row.draggable = !entry.dir;
	const wrap = el("div", "tree-item", row);
	if (entry.dir) {
		const kids = el("div", `tree-kids${open ? " open" : ""}`, el("div", "tree-kids-inner"));
		wrap.append(kids);
		const fill = async () => {
			const list = await bridge.call("list", entry.path);
			kids.firstElementChild.replaceChildren(...await Promise.all(list.map(each => treeRow(each, depth + 1))));
		};
		if (open) await fill();
		row.addEventListener("click", async () => {
			const now = !side.opened.has(entry.path);
			if (now) { side.opened.add(entry.path); await fill(); } else side.opened.delete(entry.path);
			row.classList.toggle("open", now);
			kids.classList.toggle("open", now);
			row.children[1].textContent = icon(now ? "folder_open" : "folder").textContent;
			saveSoon();
		});
	} else {
		row.addEventListener("click", () => openPath(entry.path));
		row.addEventListener("contextmenu", event => {
			event.preventDefault();
			menu(event.clientX, event.clientY, [
				{ title: "Copy path", icon: "content_copy", run: () => bridge.call("copy", entry.path) },
				{ title: "Put on shelf", icon: "tray_arrow_down", run: () => toShelf(entry.path) },
				{ title: "Send to phone", icon: "cellphone_arrow_down", run: () => bridge.call("phoneFile", entry.path) },
			]);
		});
	}
	return wrap;
}

async function refreshTree() {
	if (!side.open || !side.tree) return;
	const rows = await Promise.all(side.roots.map(path => treeRow({ name: basename(path) || path, path, dir: true }, 0)));
	side.tree.replaceChildren(...rows);
}

function drawOutline() {
	if (!side.open || side.view !== "outline") return;
	const tab = activePane?.active;
	if (!tab?.view) { side.outline.replaceChildren(); return; }
	const { state } = tab.view;
	const rows = [];
	const head = state.selection.main.head;
	let current = -1;
	syntaxTree(state).iterate({
		enter(node) {
			const match = node.name.match(/^(?:ATX|Setext)Heading(\d)$/);
			if (!match) return;
			const text = state.sliceDoc(node.from, node.to).split("\n")[0].replace(/^#+\s*/, "");
			if (node.from <= head) current = rows.length;
			rows.push({ text, level: Number(match[1]), from: node.from });
			return false;
		},
	});
	const key = rows.map(row => row.text + row.level).join("|");
	if (key !== side.outlineKey) {
		side.outlineKey = key;
		side.outline.replaceChildren(...rows.map(row => {
			const button = el("button", `outline-row l${row.level}`, row.text);
			button.addEventListener("click", () => {
				const view = activePane.active.view;
				const line = view.state.doc.lineAt(Math.min(row.from, view.state.doc.length));
				view.dispatch({ selection: EditorSelection.cursor(line.to), effects: EditorView.scrollIntoView(line.from, { y: "start", yMargin: 40 }) });
				view.focus();
			});
			return button;
		}));
	}
	[...side.outline.children].forEach((row, index) => row.classList.toggle("on", index === current));
}

// ── what the rendered things and the document can reach ─────────────────
async function followLink(href) {
	if (/^(https?:|mailto:)/.test(href)) { bridge.call("openUri", href); return; }
	const tab = activePane?.active;
	const base = tab?.doc.path ? dirname(tab.doc.path) : home;
	const clean = decodeURI(href.split("#")[0]);
	if (!clean) return;
	openPath(clean.startsWith("/") ? clean : `${base}/${clean}`);
}

async function followWiki(name) {
	const tab = activePane?.active;
	const file = /\.\w+$/.test(name) ? name : `${name}.md`;
	const candidates = [];
	if (tab?.doc.path) candidates.push(`${dirname(tab.doc.path)}/${file}`);
	candidates.push(`${home}/todo/notes/${file}`);
	for (const path of candidates) {
		if ((await bridge.call("stat", path)).exists) { openPath(path); return; }
	}
	openPath(candidates[candidates.length - 1]);
}

function onRenderedClick(event) {
	const wiki = event.target.closest("[data-wiki]");
	if (wiki) { event.preventDefault(); followWiki(wiki.dataset.wiki); return; }
	const anchor = event.target.closest("a[href]");
	if (anchor) { event.preventDefault(); followLink(anchor.getAttribute("href")); }
}

function currentView() {
	return activePane?.active?.view ?? null;
}

function insertAtCursor(view, text) {
	const range = view.state.selection.main;
	view.dispatch({ changes: { from: range.from, to: range.to, insert: text }, selection: EditorSelection.cursor(range.from + text.length), scrollIntoView: true });
	view.focus();
}

const PICTURE = /\.(png|jpe?g|gif|webp|svg|avif|bmp)$/i;
function linkUris(doc, list) {
	return list.split(/\r?\n/).filter(each => each && !each.startsWith("#")).map(uri => {
		if (!uri.startsWith("file://")) return `[${uri}](${uri})`;
		const path = decodeURIComponent(uri.slice(7));
		const target = relativeTo(doc, path);
		return PICTURE.test(path) ? `![${basename(path)}](${target})` : `[${basename(path)}](${target})`;
	}).join("\n");
}

function readBase64(file) {
	return new Promise((resolve, reject) => {
		const reader = new FileReader();
		reader.onload = () => resolve(String(reader.result).replace(/^data:[^,]*,/, ""));
		reader.onerror = () => reject(reader.error);
		reader.readAsDataURL(file);
	});
}

async function pastePictures(view, doc, files) {
	for (const file of files) {
		let done;
		try {
			done = await bridge.call("pasteImage", doc.path ?? "", file.type, await readBase64(file));
		} catch (error) {
			done = { error: String(error) };
		}
		pasted(view, doc, done);
	}
}

function pasted(view, doc, done) {
	if (done.error) toast(done.error, "danger");
	if (done.path) insertAtCursor(view, `![](${relativeTo(doc, done.path)})\n`);
}

function relativeTo(doc, path) {
	const encode = each => each.split("/").map(part => encodeURIComponent(part)).join("/");
	if (!doc.path) return encode(path);
	const from = dirname(doc.path).split("/");
	const to = path.split("/");
	let same = 0;
	while (same < from.length && same < to.length - 1 && from[same] === to[same]) same += 1;
	return encode([...Array(from.length - same).fill(".."), ...to.slice(same)].join("/"));
}

function toShelf(path) {
	bridge.call("shelfFile", path).then(done => toast(done.ok ? "On the shelf" : "Shelf not reachable", done.ok ? "" : "danger"));
}

function selectionText(view) {
	const range = view.state.selection.main;
	return view.state.sliceDoc(range.from, range.to);
}

// runs something slow at the cursor: a shimmer where the result will land
async function working(view, label, job) {
	const chip = toastWorking(label);
	const result = await job();
	chip();
	if (result?.error) toast(result.error, "danger");
	return result?.error ? null : result;
}

function toastWorking(label) {
	const item = el("div", "working", el("span", "shimmer", label));
	document.body.append(item);
	animate(item, [{ opacity: 0, transform: "translate(-50%,10px) scale(.94)" }, { opacity: 1, transform: "translate(-50%,0)" }], motion.medium, motion.spatial);
	return () => animate(item, [{ opacity: 1 }, { opacity: 0 }], motion.short, motion.standard, { fill: "forwards" }).finished.then(() => item.remove());
}

const appApi = {
	bridge,
	slashIcon(name) {
		return icon(name, "slash-icon");
	},
	insert: insertAtCursor,
	domHandlers: {
		mousedown(event) {
			if (!(event.ctrlKey || event.metaKey) || event.button !== 0) return false;
			const wiki = event.target.closest?.("[data-wiki]");
			if (wiki) { event.preventDefault(); followWiki(wiki.dataset.wiki); return true; }
			const link = event.target.closest?.("[data-href]");
			if (link?.dataset.href) { event.preventDefault(); followLink(link.dataset.href); return true; }
			return false;
		},
		contextmenu(event, view) {
			event.preventDefault();
			editorMenu(event, view);
			return true;
		},
		dragover(event) {
			if (event.dataTransfer?.types?.includes("text/uri-list")) { event.preventDefault(); return true; }
			return false;
		},
		drop(event, view) {
			const list = event.dataTransfer?.getData("text/uri-list");
			if (!list) return false;
			event.preventDefault();
			const at = view.posAtCoords({ x: event.clientX, y: event.clientY }) ?? view.state.selection.main.head;
			const text = linkUris(activePane.active.doc, list);
			view.dispatch({ changes: { from: at, insert: text }, selection: EditorSelection.cursor(at + text.length) });
			view.focus();
			return true;
		},
		paste(event, view) {
			const tab = activePane?.active;
			const data = event.clipboardData;
			if (!tab || tab.doc.readonly || !data || !isMarkdown(tab.doc.path)) return false;
			const pictures = [...data.files].filter(file => file.type.startsWith("image/"));
			if (pictures.length) {
				event.preventDefault();
				pastePictures(view, tab.doc, pictures);
				return true;
			}
			// files copied in a file manager: links, pictures shown
			const list = data.getData("text/uri-list");
			if (list && list.split(/\r?\n/).some(each => each.startsWith("file://"))) {
				event.preventDefault();
				insertAtCursor(view, linkUris(tab.doc, list));
				return true;
			}
			// no text: perhaps a picture WebKit does not hand over
			if (!data.types.includes("text/plain")) {
				event.preventDefault();
				bridge.call("pasteImage", tab.doc.path ?? "").then(done => pasted(view, tab.doc, done));
				return true;
			}
			return false;
		},
	},
	async askAi(view) {
		const prompt = await ask("Ask the AI");
		if (!prompt) return;
		const before = view.state.sliceDoc(Math.max(0, view.state.selection.main.head - 2000), view.state.selection.main.head);
		const done = await working(view, "AI", () => bridge.call("ai", `${before ? `Context, the text so far:\n${before}\n\n` : ""}${prompt}\n\nAnswer with the Markdown to insert, nothing around it.`));
		if (done) insertAtCursor(view, done.result);
	},
	async screenshot(view) {
		const doc = activePane.active.doc;
		const done = await bridge.call("screenshot", doc.path ?? "");
		if (done.error) toast(done.error, "danger");
		if (done.path) insertAtCursor(view, `![](${relativeTo(doc, done.path)})\n`);
	},
	async pickClip(view) {
		const entries = await bridge.call("clipEntries");
		const items = entries.map(text => ({ title: text.split("\n")[0].slice(0, 90), detail: text.includes("\n") ? `${text.split("\n").length} lines` : "", icon: "clipboard_text_outline", run: () => insertAtCursor(view, text), text }));
		await palette({ placeholder: "Clipboard", source: query => items.filter(item => fuzzy(query, item.text) >= 0) });
	},
	async askCalc(view) {
		const typed = await ask("Calculate");
		if (!typed) return;
		const done = await working(view, "Calculate", () => bridge.call("calc", typed));
		if (done) insertAtCursor(view, done.result);
	},
	async askTranslate(view) {
		const selected = selectionText(view);
		const text = selected || await ask("Translate");
		if (!text) return;
		const target = await ask("To", "en");
		if (!target) return;
		const done = await working(view, "Translate", () => bridge.call("translate", text, target));
		if (done) insertAtCursor(view, done.result);
	},
	async askTask(view) {
		const typed = selectionText(view) || await ask("Task");
		if (!typed) return;
		const done = await bridge.call("addTask", typed);
		toast(done.ok ? "Added to tasks" : "Tasks not reachable", done.ok ? "" : "danger");
		view.focus();
	},
	async pickEmoji(view) {
		const set = "😀 smile,😂 laugh,🙂 slight,😉 wink,😍 love,😎 cool,🤔 think,😴 sleep,😭 cry,😡 angry,👍 yes up,👎 no down,👏 clap,🙏 thanks,💪 strong,👀 eyes,🎉 party,🔥 fire,✨ sparkles,⭐ star,❤️ heart,💡 idea,✅ check done,❌ cross no,⚠️ warning,❗ important,❓ question,📌 pin,📎 attach,📝 note,📅 calendar,⏰ alarm,🚀 rocket,🐛 bug,🔧 fix tool,🔒 lock,💰 money,📈 up chart,📉 down chart,🎯 target,☕ coffee,🍕 pizza".split(",").map(each => {
			const [glyph, ...words] = each.split(" ");
			return { title: `${glyph}  ${words.join(" ")}`, words: words.join(" "), run: () => insertAtCursor(view, glyph) };
		});
		await palette({ placeholder: "Emoji", source: query => set.filter(item => fuzzy(query, item.words) >= 0) });
	},
	async pickNote(view) {
		const notes = (await bridge.call("files", [`${home}/todo/notes`])).filter(path => path.endsWith(".md"));
		const items = notes.map(path => ({ title: basename(path).replace(/\.md$/, ""), icon: "note_outline", run: () => insertAtCursor(view, `[[${basename(path).replace(/\.md$/, "")}]]`) }));
		await palette({ placeholder: "Note", source: query => items.filter(item => fuzzy(query, item.title) >= 0).sort((a, b) => fuzzy(query, b.title) - fuzzy(query, a.title)) });
	},
};

function editorMenu(event, view) {
	const has = !view.state.selection.main.empty;
	const items = [];
	if (has) {
		items.push(
			{ title: "Copy", icon: "content_copy", keys: "Ctrl+C", run: () => bridge.call("copy", selectionText(view)) },
			"-",
			{ title: "Bold", icon: "format_bold", keys: "Ctrl+B", run: () => format.wrap(view, "**") },
			{ title: "Italic", icon: "format_italic", keys: "Ctrl+I", run: () => format.wrap(view, "*") },
			{ title: "Link", icon: "link_variant", keys: "Ctrl+K", run: () => format.link(view) },
			"-",
			{ title: "Ask AI about this", icon: "robot_outline", run: () => aiOnSelection(view) },
			{ title: "Translate", icon: "translate", run: () => appApi.askTranslate(view) },
			{ title: "Calculate", icon: "calculator", run: () => calcSelection(view) },
			"-",
			{ title: "Add to tasks", icon: "format_list_checks", run: () => appApi.askTask(view) },
			{ title: "Put on shelf", icon: "tray_arrow_down", run: () => bridge.call("shelfText", selectionText(view)).then(done => toast(done.ok ? "On the shelf" : "Shelf not reachable", done.ok ? "" : "danger")) },
			{ title: "Send to phone", icon: "cellphone_arrow_down", run: () => bridge.call("phoneText", selectionText(view)).then(done => toast(done.ok ? "Sent" : "Phone not reachable", done.ok ? "" : "danger")) },
		);
	} else {
		items.push(
			{ title: "Table", icon: "table", keys: "Ctrl+Shift+T", run: () => format.insertTable(view) },
			{ title: "Code block", icon: "code_tags", keys: "Ctrl+Shift+C", run: () => format.insertCode(view) },
			{ title: "Columns", icon: "view_column", keys: "Ctrl+Shift+M", run: () => format.insertColumns(view) },
			"-",
			{ title: "Screenshot", icon: "monitor_screenshot", run: () => appApi.screenshot(view) },
			{ title: "Clipboard history", icon: "clipboard_text_outline", run: () => appApi.pickClip(view) },
		);
	}
	menu(event.clientX, event.clientY, items);
}

async function aiOnSelection(view) {
	const prompt = await ask("What about it?");
	if (!prompt) return;
	const done = await working(view, "AI", () => bridge.call("ai", `${prompt}\n\nText:\n${selectionText(view)}\n\nAnswer with the replacement Markdown only.`));
	if (!done) return;
	const range = view.state.selection.main;
	view.dispatch({ changes: { from: range.to, insert: `\n\n${done.result}` }, selection: EditorSelection.cursor(range.to + done.result.length + 2) });
}

async function calcSelection(view) {
	const done = await working(view, "Calculate", () => bridge.call("calc", selectionText(view)));
	if (!done) return;
	const range = view.state.selection.main;
	view.dispatch({ changes: { from: range.to, insert: ` = ${done.result}` } });
}

async function onFence({ detail, target }) {
	const tab = activePane?.active;
	const view = EditorView.findFromDOM(target) ?? tab?.view;
	if (!view) return;
	const fence = fences(view.state).find(each => each.from <= detail.pos && detail.pos <= each.to);
	if (!fence) return;
	const code = fenceBody(view.state, fence);
	const cwd = tab?.doc.path ? dirname(tab.doc.path) : home;
	if (detail.action === "copy") {
		bridge.call("copy", code);
		toast("Copied");
	} else if (detail.action === "terminal") {
		const done = await bridge.call("runTerminal", fence.lang, code, cwd);
		if (!done.ok) toast(done.error || "Terminal not reachable", "danger");
	} else if (detail.action === "output") {
		const done = await working(view, "Running", () => bridge.call("runOutput", fence.lang, code, cwd));
		if (!done) return;
		const now = fences(view.state).find(each => each.from <= detail.pos && detail.pos <= each.to);
		if (!now) return;
		const next = fences(view.state).find(each => each.from > now.to);
		const body = `\`\`\`output\n${done.output.replace(/\n$/, "")}\n\`\`\``;
		if (next?.lang === "output" && view.state.sliceDoc(now.to, next.from).trim() === "") {
			view.dispatch({ changes: { from: next.from, to: next.to, insert: body } });
		} else {
			view.dispatch({ changes: { from: now.to, insert: `\n\n${body}` } });
		}
		if (done.code) toast(`Exit ${done.code}`, "danger");
	}
}

// ── commands: palette and keys ──────────────────────────────────────────
const tabNow = () => activePane?.active ?? null;
const commands = [
	{ title: "Save", icon: "content_save_outline", keys: "Ctrl+S", key: "c-s", run: () => tabNow() && saveDoc(tabNow().doc) },
	{ title: "Save as", icon: "content_save_outline", keys: "Ctrl+Shift+S", key: "cs-s", run: () => tabNow() && saveDoc(tabNow().doc, true) },
	{ title: "Save all", icon: "content_save", keys: "Ctrl+Alt+S", key: "ca-s", run: () => [...docs.values()].filter(isDirty).forEach(doc => saveDoc(doc)) },
	{ title: "New tab", icon: "plus", keys: "Ctrl+N", key: "c-n", run: newUntitled },
	{ title: "Close tab", icon: "close", keys: "Ctrl+W", key: "c-w", run: () => tabNow() && closeTab(tabNow()) },
	{ title: "Open", icon: "file_document_outline", keys: "Ctrl+P", key: "c-p", also: "c-o", run: () => openQuick("") },
	{ title: "Commands", icon: "keyboard_outline", keys: "Ctrl+Shift+P", key: "cs-p", run: () => openQuick(">") },
	{ title: "Find in files", icon: "magnify", keys: "Ctrl+Shift+F", key: "cs-f", run: () => openQuick("?") },
	{ title: "Find", icon: "magnify", keys: "Ctrl+F", run: () => currentView() && openSearchPanel(currentView()) },
	{ title: "Split right", icon: "view_column_outline", keys: "Ctrl+\\", key: "c-\\", run: () => tabNow() && splitWith(tabNow(), "right") },
	{ title: "Split down", icon: "split_horizontal", keys: "Ctrl+Shift+\\", key: "cs-\\", also: "cs-|", run: () => tabNow() && splitWith(tabNow(), "down") },
	{ title: "Next tab", keys: "Ctrl+Tab", key: "c-tab", run: () => cycleTab(1) },
	{ title: "Previous tab", keys: "Ctrl+Shift+Tab", key: "cs-tab", run: () => cycleTab(-1) },
	{ title: "Next pane", keys: "Ctrl+Alt+→", key: "ca-arrowright", run: () => cyclePane(1) },
	{ title: "Previous pane", keys: "Ctrl+Alt+←", key: "ca-arrowleft", run: () => cyclePane(-1) },
	{ title: "Live", icon: "pencil_outline", run: () => tabNow() && setMode(tabNow(), "live") },
	{ title: "Source", icon: "code_tags", run: () => tabNow() && setMode(tabNow(), "source") },
	{ title: "Reader", icon: "book_open_page_variant", keys: "Ctrl+E", key: "c-e", run: () => { const tab = tabNow(); if (tab) setMode(tab, tab.mode === "reader" ? "live" : "reader"); } },
	{ title: "Reader in columns", icon: "view_column", keys: "Ctrl+Shift+E", key: "cs-e", run: () => { const tab = tabNow(); if (tab) { tab.columns = tab.columns % 3 + 1; setMode(tab, "reader"); drawReader(tab); updateChrome(); } } },
	{ title: "Sidebar", icon: "dock_left", keys: "Ctrl+B", key: null, run: toggleSidebar },
	{ title: "Sidebar", icon: "dock_left", keys: "Ctrl+Shift+B", key: "cs-b", run: toggleSidebar },
	{ title: "Open folder", icon: "folder", run: openFolder },
	{ title: "Larger text", keys: "Ctrl+=", key: "c-=", also: "c-+", run: () => zoom(1) },
	{ title: "Smaller text", keys: "Ctrl+-", key: "c--", run: () => zoom(-1) },
	{ title: "Wider column", icon: "arrow_expand_horizontal", run: () => stepSheet(1) },
	{ title: "Narrower column", icon: "arrow_collapse_horizontal", run: () => stepSheet(-1) },
	{ title: "Column width: standard", icon: "arrow_collapse_horizontal", run: () => setSheet(SHEET.standard) },
	{ title: "Shortcuts", icon: "keyboard_outline", keys: "Ctrl+/", key: "c-/", run: showShortcuts },
].filter(each => each.keys !== "Ctrl+B");

const SHORTCUTS = [
	["Text", [["Bold", "Ctrl+B"], ["Italic", "Ctrl+I"], ["Strikethrough", "Ctrl+Shift+X"], ["Code", "Ctrl+`"], ["Link", "Ctrl+K"]]],
	["Blocks", [["Heading 1–6", "Ctrl+1…6"], ["Paragraph", "Ctrl+0"], ["Table", "Ctrl+Shift+T"], ["Code block", "Ctrl+Shift+C"], ["Columns", "Ctrl+Shift+M"], ["Task", "Ctrl+Shift+L"], ["Tick task", "Ctrl+Enter"], ["List", "Ctrl+Shift+U"], ["Numbered", "Ctrl+Shift+O"], ["Quote", "Ctrl+Shift+Q"], ["Divider", "Ctrl+Shift+H"]]],
	["Tables", [["Next cell", "Tab"], ["Previous cell", "Shift+Tab"], ["Next row", "Enter"]]],
	["Tabs & panes", [["Open", "Ctrl+P"], ["New", "Ctrl+N"], ["Close", "Ctrl+W"], ["Tab 1–9", "Alt+1…9"], ["Next tab", "Ctrl+Tab"], ["Split right", "Ctrl+\\"], ["Split down", "Ctrl+Shift+\\"], ["Other pane", "Ctrl+Alt+←→"]]],
	["View", [["Reader", "Ctrl+E"], ["Reader columns", "Ctrl+Shift+E"], ["Sidebar", "Ctrl+Shift+B"], ["Commands", "Ctrl+Shift+P"], ["Find in files", "Ctrl+Shift+F"], ["Text size", "Ctrl+= / −"]]],
];

function showShortcuts() {
	const grid = el("div", "shortcuts");
	SHORTCUTS.forEach(([title, rows], index) => {
		const box = el("section", "", el("h3", "", title), ...rows.map(([name, keys]) => el("div", "shortcut", el("span", "", name), el("kbd", "", keys))));
		animate(box, [{ opacity: 0, transform: "translateY(10px)" }, { opacity: 1, transform: "none" }], motion.long, motion.spatial, { delay: index * 30 });
		grid.append(box);
	});
	const shell = overlay(el("div", "dialog wide", grid), { origin: "50% 50%" });
	const key = event => { if (event.key === "Escape" || event.key === "/") { event.preventDefault(); event.stopPropagation(); shell.close(); removeEventListener("keydown", key, true); } };
	addEventListener("keydown", key, true);
}

function cycleTab(delta) {
	const pane = activePane;
	if (!pane || pane.tabs.length < 2) return;
	const index = pane.tabs.indexOf(pane.active);
	activateTab(pane.tabs[(index + delta + pane.tabs.length) % pane.tabs.length]);
}

function cyclePane(delta) {
	const panes = allPanes();
	const next = panes[(panes.indexOf(activePane) + delta + panes.length) % panes.length];
	setActive(next);
	next.active?.view?.focus();
}

// the width of the text column, dragged at its edges; the same in every pane
const SHEET = { min: 360, max: 4000, step: 80, standard: 760 };
let sheetWidth = SHEET.standard;
function setSheet(width, save = true) {
	sheetWidth = Math.round(Math.min(SHEET.max, Math.max(SHEET.min, width)));
	document.documentElement.style.setProperty("--sheet", `${sheetWidth}px`);
	measureAll();
	if (save) saveSoon();
}
// as wide as the pane: kept at the most, so a larger window is filled as well
const sheetRoom = () => Math.max(...allPanes().map(pane => pane.body.clientWidth - 56), SHEET.min);
const sheetShown = () => Math.min(sheetWidth, sheetRoom());
function stepSheet(delta) {
	const next = sheetShown() + delta * SHEET.step;
	setSheet(next >= sheetRoom() ? SHEET.max : next);
}

function sheetEdge(pane, side) {
	const edge = el("div", `sheet-edge ${side}`);
	edge.addEventListener("pointerdown", event => {
		if (event.button !== 0) return;
		event.preventDefault();
		edge.setPointerCapture(event.pointerId);
		const room = pane.body.clientWidth - 56;
		const startX = event.clientX;
		const start = Math.min(sheetWidth, room);
		const sign = side === "right" ? 1 : -1;
		document.body.classList.add("sizing-sheet");
		const move = each => {
			const next = start + sign * 2 * (each.clientX - startX);
			setSheet(next >= room ? SHEET.max : next, false);
		};
		const up = () => {
			edge.removeEventListener("pointermove", move);
			edge.removeEventListener("pointerup", up);
			edge.removeEventListener("pointercancel", up);
			document.body.classList.remove("sizing-sheet");
			saveSoon();
		};
		edge.addEventListener("pointermove", move);
		edge.addEventListener("pointerup", up);
		edge.addEventListener("pointercancel", up);
	});
	edge.addEventListener("dblclick", () => setSheet(SHEET.standard));
	return edge;
}

let textSize = 15;
function zoom(delta) {
	textSize = Math.min(28, Math.max(11, textSize + delta));
	document.documentElement.style.setProperty("--text", `${textSize}px`);
	measureAll();
	saveSoon();
}

async function openQuick(start) {
	const recent = await bridge.call("recent");
	const roots = [...new Set([...side.roots, ...[...docs.values()].filter(doc => doc.path).map(doc => dirname(doc.path))])];
	let known = null;
	const fileItem = path => ({ title: basename(path), detail: pretty(dirname(path)), icon: isMarkdown(path) ? "language_markdown_outline" : "file_outline", run: () => openPath(path) });
	await palette({
		placeholder: "Open",
		value: start,
		source: async query => {
			if (query.startsWith(">")) {
				const words = query.slice(1).trim();
				return commands.map(each => ({ ...each, score: fuzzy(words, each.title) })).filter(each => each.score >= 0).sort((a, b) => b.score - a.score);
			}
			if (query.startsWith("?")) {
				const words = query.slice(1).trim();
				if (words.length < 2) return [];
				await new Promise(done => setTimeout(done, 140));
				const hits = await bridge.call("search", words, roots);
				return hits.map(hit => ({ title: hit.text, detail: `${pretty(hit.path)}:${hit.line}`, icon: "text_box_outline", run: () => openPath(hit.path, { line: hit.line, column: hit.column + 1 }) }));
			}
			if (known === null && query) known = await bridge.call("files", roots);
			const all = [...new Set([...recent, ...(query ? known ?? [] : [])])];
			const hits = all.map(path => ({ path, score: fuzzy(query, pretty(path)) })).filter(each => each.score >= 0);
			hits.sort((a, b) => b.score - a.score);
			const out = hits.slice(0, 60).map(each => fileItem(each.path));
			if (query.includes("/") || query.startsWith("~")) {
				const path = query.replace(/^~/, home);
				out.unshift({ title: pretty(path), icon: "plus", run: () => openPath(path) });
			}
			return out;
		},
	});
}

addEventListener("keydown", event => {
	if (document.querySelector(".scrim") && event.key !== "Escape") return;
	const mods = `${event.ctrlKey || event.metaKey ? "c" : ""}${event.altKey ? "a" : ""}${event.shiftKey ? "s" : ""}`;
	if (scratch && event.key === "Escape" && !document.querySelector(".scrim, .cm-tooltip-autocomplete, .cm-panels")) {
		bridge.call("hide");
		return;
	}
	if (mods === "a" && /^[1-9]$/.test(event.key) && activePane) {
		const tab = activePane.tabs[Number(event.key) - 1];
		if (tab) activateTab(tab);
		event.preventDefault();
		return;
	}
	if (!mods.startsWith("c")) return;
	const name = `${mods}-${event.key.toLowerCase()}`;
	const found = commands.find(each => each.key === name || each.also === name);
	if (found) {
		event.preventDefault();
		event.stopPropagation();
		found.run();
	}
}, true);

// ── session: tabs, layout, what is unsaved ──────────────────────────────
let saveTimer = 0;
function saveSoon() {
	clearTimeout(saveTimer);
	saveTimer = setTimeout(saveSession, 600);
}

function saveLayout(node) {
	if (node.type === "split") return { type: "split", direction: node.direction, size: node.size, children: node.children.map(saveLayout) };
	return {
		type: "pane", size: node.size,
		active: node.tabs.indexOf(node.active),
		tabs: node.tabs.map(tab => {
			const dirty = isDirty(tab.doc);
			const on = tab.view ? tab.view.state.field(previewPositions, false) ?? [] : [];
			const starts = tab.view ? fences(tab.view.state).filter(each => /^(html|css|js|javascript)$/.test(each.lang)).map(each => each.from) : [];
			return {
				path: tab.doc.path, untitled: tab.doc.untitled, mode: tab.mode, columns: tab.columns,
				draft: dirty || !tab.doc.path ? docText(tab.doc) : undefined,
				selection: tab.view?.state.selection.main.head ?? tab.selection,
				previews: tab.view ? on.map(pos => starts.indexOf(pos)).filter(each => each >= 0) : tab.previews,
			};
		}),
	};
}

function saveSession() {
	if (!root) return;
	bridge.call("sessionSave", kind, { layout: saveLayout(root), side: { open: side.open, view: side.view, roots: side.roots, opened: [...side.opened] }, textSize, sheet: sheetWidth });
}

async function restoreLayout(data, parent) {
	if (data.type === "split") {
		const children = [];
		for (const child of data.children) children.push(await restoreLayout(child, null));
		const split = createSplit(data.direction, children);
		split.size = data.size ?? 1;
		split.parent = parent;
		return split;
	}
	const pane = createPane();
	pane.size = data.size ?? 1;
	pane.parent = parent;
	for (const saved of data.tabs ?? []) {
		let doc = saved.path ? findDoc(saved.path) : null;
		if (!doc) {
			if (saved.path) {
				const read = await bridge.call("read", saved.path);
				if (read.error) continue;
				if (read.missing && saved.draft === undefined) continue;
				doc = newDoc({ path: saved.path, text: saved.draft ?? read.text ?? "", saved: read.text ?? "", mtime: read.mtime ?? 0, crlf: read.crlf, readonly: read.writable === false });
			} else {
				doc = newDoc({ text: saved.draft ?? "", saved: "" });
				doc.untitled = saved.untitled;
			}
		}
		const tab = createTab(doc, saved.mode);
		tab.columns = saved.columns ?? 1;
		tab.selection = saved.selection;
		tab.previews = saved.previews;
		tab.pane = pane;
		pane.tabs.push(tab);
		pane.strip.append(tab.button);
		pane.body.append(tab.host);
	}
	pane.restoreActive = data.active;
	drawEmpty(pane);
	return pane;
}

function applyTheme(tokens) {
	const css = document.documentElement.style;
	for (const [key, value] of Object.entries(tokens)) css.setProperty(`--${key}`, String(value));
}

window.peEvent = (name, data) => {
	if (name === "open") {
		if (!activePane) pendingOpens.push(data);
		else openPath(data.path, { line: data.line, column: data.column });
	} else if (name === "theme") {
		document.documentElement.classList.add("recolour");
		applyTheme(data);
		setTimeout(() => document.documentElement.classList.remove("recolour"), motion.extraLong);
	} else if (name === "fileChanged") {
		onFileChanged(data);
	} else if (name === "closeRequested") {
		saveSession();
		setTimeout(() => bridge.call("closeNow"), 60);
	} else if (name === "shown") {
		animate(document.body, [{ opacity: 0, transform: "scale(.97) translateY(-8px)" }, { opacity: 1, transform: "none" }], motion.medium, motion.spatial);
		currentView()?.focus();
	} else if (name === "hiding") {
		saveSession();
		animate(document.body, [{ opacity: 1, transform: "none" }, { opacity: 0, transform: "scale(.98)" }], motion.short, motion.accel);
	}
};
const pendingOpens = [];

async function start() {
	const hello = await bridge.call("ready");
	home = hello.home;
	applyTheme(hello.theme);
	document.body.classList.add(scratch ? "scratch" : "full");
	if (!scratch) app.append(buildSidebar());
	const column = el("div", "column", stage);
	if (!scratch) column.append(buildStatus());
	app.append(column);

	const saved = await bridge.call("sessionLoad", kind);
	side.roots = saved?.side?.roots ?? [`${home}/todo/notes`];
	side.opened = new Set(saved?.side?.opened ?? side.roots);
	side.view = saved?.side?.view ?? "files";
	if (saved?.textSize) { textSize = saved.textSize; zoom(0); }
	if (saved?.sheet) setSheet(saved.sheet, false);
	if (side.view === "outline") side.tabs?.set("outline");
	side.tree?.classList.toggle("shown", side.view === "files");
	side.outline?.classList.toggle("shown", side.view === "outline");

	root = saved?.layout ? await restoreLayout(saved.layout, null) : createPane();
	stage.classList.add("instant");
	redraw();
	setActive(firstPane(root));
	for (const pane of allPanes()) {
		const tab = pane.tabs[pane.restoreActive] ?? pane.tabs[0];
		if (tab) activateTab(tab, false);
	}
	if (scratch && !activePane.active) {
		const tab = createTab(newDoc({ text: "" }), "live");
		tab.doc.untitled = "Scratchpad";
		addTab(tab, activePane);
		activateTab(tab);
	}
	stage.classList.remove("instant");
	if (saved?.side?.open) toggleSidebar(true);
	watchFiles();
	activePane.active?.view?.focus();
	document.body.classList.add("ready");
	const opens = pendingOpens.splice(0);
	for (const each of opens) await openPath(each.path, { line: each.line, column: each.column });
	addEventListener("resize", () => allPanes().forEach(placeIndicator));
	// in case the fonts arrive after the first measure
	document.fonts?.ready.then(() => { allPanes().forEach(placeIndicator); measureAll(); });
}

start();
