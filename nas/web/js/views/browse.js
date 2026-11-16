// Browse (BrowseView.qml): a folder, a search, a tag or what came lately as
// a virtualised grid of cards or a list. Multi-select with clicks, Shift,
// Ctrl and a rubber band; the keyboard walks it; drag & drop moves; files
// from the desktop upload; Space opens Quick look.
import { h, icon, clear, nameOf, parentOf, join, plural, debounce, throttleFrame, isMobile, isTouch, size as fmtSize, KIND_LABEL } from "../util.js";
import * as api from "../api.js";
import { state, setView, on as onStore, setting } from "../store.js";
import { card, row as listRow, listHeader, dragGhost, sortEntries, groupOf, recentEntries } from "../files.js";
import { stagger, animate, EASE, DUR, reduced } from "../motion.js";
import { showMenu, toast, errorToast, segmented } from "../ui.js";
import * as actions from "../actions.js";
import * as uploads from "../uploads.js";
import { encodePath } from "../app.js";
import { openQuickLook } from "../quicklook.js";
import { createDetails } from "../details.js";

const GAP = 6;
const PAD = 16;
const KINDS = ["image", "video", "audio", "pdf", "text", "office", "archive", "code"];

export default function browse(route, app) {
	let mode = route.name; // files | search | tag
	let folder = mode === "files" ? route.path : null;
	let entries = []; // as loaded
	let items = []; // sorted, filtered
	let positions = [];
	let rows = [];
	let total = 0;
	let cols = 1;
	let selected = new Set();
	let anchor = -1;
	let current = -1;
	let loading = true;
	let loadToken = 0;
	let firstPaint = true;
	let kindFilter = route.query.kind || "";
	let filterText = "";
	let selectMode = false;
	const els = new Map();
	const seen = new Set();

	// ── chrome ───────────────────────────────────────────────────────────
	const crumbs = h("nav.crumbs", { "aria-label": "Where" });
	const titleEl = h("div.top-crumbs", crumbs);

	const countText = h("span.status-count");
	const pickedChip = h("span.picked-chip", { hidden: true });
	const kindChips = h("div.kind-chips");
	const modeSeg = segmented([
		{ value: "grid", icon: "view_grid_outline", title: "Cards" },
		{ value: "list", icon: "view_list_outline", title: "List" }
	], state.view.mode, value => setView({ mode: value }), { icons: true });
	const sizeSlider = h("input.size-slider", { type: "range", min: 110, max: 300, step: 2, value: state.view.card, title: "Card size (Ctrl + / −)" });
	const freeText = h("span.status-free");
	const fillSlider = () => sizeSlider.style.setProperty("--fill", `${((Number(sizeSlider.value) - 110) / 190) * 100}%`);
	fillSlider();
	sizeSlider.addEventListener("input", () => {
		fillSlider();
		setView({ card: Number(sizeSlider.value) });
	});
	const sortBtn = h("button.icon-btn.small.sort-btn", { title: "Sort, group, show" }, icon("sort"), h("span.sort-label", { hidden: true }, sortLabel()));
	sortBtn.addEventListener("click", event => showMenu(viewMenu(), event.clientX, event.clientY));
	const detailsBtn = h("button.icon-btn.small", { title: "Details (Alt+Enter)" }, icon("dock_right"));
	detailsBtn.classList.toggle("on", state.view.details);
	detailsBtn.addEventListener("click", () => setView({ details: !state.view.details }));
	const selectBtn = h("button.icon-btn.small.only-mobile", { title: "Pick" }, icon("checkbox_multiple_marked_outline"));
	selectBtn.addEventListener("click", () => {
		selectMode = !selectMode;
		root.classList.toggle("select-mode", selectMode);
		selectBtn.classList.toggle("on", selectMode);
		if (!selectMode) setSelection([]);
	});
	const newBtn = h("button.icon-btn.small.new-btn", { title: "New folder, file, upload" }, icon("plus"));
	newBtn.addEventListener("click", event => {
		const r = newBtn.getBoundingClientRect();
		showMenu([
			{ label: "New folder", icon: "folder_plus_outline", shortcut: "Ctrl+Shift+N", run: () => actions.newFolder(folder, api_) },
			{ label: "Text file", icon: "text_box_outline", run: () => actions.newFile(folder, "New file.txt", "") },
			{ label: "Markdown note", icon: "language_markdown_outline", run: () => actions.newFile(folder, "Note.md", "# Note\n\n") },
			{ separator: true },
			{ label: "Upload files…", icon: "upload_outline", shortcut: "U", run: () => uploads.pick(folder, false) },
			{ label: "Upload a folder…", icon: "folder_arrow_down_outline", run: () => uploads.pick(folder, true) }
		], r.left, r.bottom + 6);
	});
	newBtn.hidden = mode !== "files";
	modeSeg.classList.add("filled");
	const toolsEl = h("div.view-tools", newBtn, selectBtn, sortBtn, modeSeg, detailsBtn);
	const statusBar = h("div.status-bar", countText, pickedChip, kindChips, h("div.top-gap"), freeText, h("div.hide-mobile.size-wrap", sizeSlider));
	const showFree = s => {
		freeText.textContent = s?.disk?.total ? `${fmtSize(s.disk.free)} free` : "";
	};
	showFree(state.status);

	const canvas = h("div.canvas", { role: "listbox", "aria-multiselectable": "true" });
	const band = h("div.band", { hidden: true });
	const empty = h("div.browse-empty", { hidden: true });
	const listHead = h("div.list-head-wrap");
	const scroller = h("div.scroller", { tabindex: "0" }, listHead, canvas, empty);
	const drawListHead = () => {
		listHead.hidden = state.view.mode !== "list";
		listHead.replaceChildren(listHeader(state.view, key => setView(state.view.sort === key ? { desc: !state.view.desc } : { sort: key, desc: false })));
	};
	drawListHead();
	canvas.appendChild(band);
	const dropZone = h("div.drop-zone", h("div.drop-inner", icon("cloud_upload_outline"), h("div.drop-title", "Drop to upload"), h("div.drop-sub", "")));
	const selectionBar = buildSelectionBar();
	const details = createDetails({ onClose: () => setView({ details: false }), view: () => api_ });
	const main = h("div.browse-main", scroller, dropZone, selectionBar.el, statusBar);
	const root = h("div.browse", main);
	const showDetails = on => {
		app.el.root.classList.toggle("with-details", on && !isMobile());
	};

	// ── loading ──────────────────────────────────────────────────────────
	async function load({ keep = false } = {}) {
		const token = ++loadToken;
		loading = !keep;
		if (!keep) {
			showSkeleton();
			firstPaint = true;
		}
		try {
			let list = [];
			if (mode === "files") {
				const data = await api.get("/api/ls", { path: folder, hidden: state.view.hidden ? 1 : 0 });
				list = data.entries || [];
				folder = data.path || folder;
			} else if (mode === "search" && route.query.recent) {
				list = await recentEntries(80);
			} else if (mode === "search") {
				// a kind on its own: every name with a dot, of that kind (the index has no "list by kind")
				const q = route.query.all ? "." : route.query.q || "";
				if (!q.trim()) list = [];
				else {
					const data = await api.get("/api/search", { q, semantic: route.query.semantic === "1" ? 1 : undefined, kind: kindFilter || undefined, path: route.query.path || undefined, limit: 1000 });
					list = data.entries || [];
					if (route.query.semantic === "1" && data.semantic === false) toast("Searching by meaning needs the semantic index – names only for now", { icon: "creation", tone: "warn", timeout: 3000 });
				}
			} else if (mode === "tag") {
				list = await taggedEntries(route.parts[0] || "");
			}
			if (token !== loadToken) return;
			const before = new Set(entries.map(e => e.path));
			entries = list;
			loading = false;
			hideSkeleton();
			// what is new since the last look rises in
			const fresh = keep ? new Set(list.filter(e => !before.has(e.path)).map(e => e.path)) : null;
			rebuild({ fresh });
			if (route.query.select && !keep) {
				const i = items.findIndex(e => e.name === route.query.select);
				if (i >= 0) {
					setSelection([items[i].path]);
					setCurrent(i, false);
				}
			}
		} catch (error) {
			if (token !== loadToken) return;
			loading = false;
			hideSkeleton();
			entries = [];
			rebuild();
			showEmpty(error.status === 404 ? "folder_alert_outline" : "alert_circle_outline", error.status === 404 ? "This folder is not there" : "Could not read it", error.message);
		}
	}

	async function taggedEntries(tag) {
		const data = await api.get("/api/search", { tag, limit: 1000 });
		return data.entries || [];
	}

	function showSkeleton() {
		clearCanvas();
		const w = scroller.clientWidth - PAD * 2 || 800;
		const c = state.view.mode === "list" ? 1 : Math.max(1, Math.floor((w + GAP) / (state.view.card + GAP)));
		const cw = state.view.mode === "list" ? w : (w - GAP * (c - 1)) / c;
		const ch = state.view.mode === "list" ? 37 : (cw - 16) / 1.24 + 58;
		for (let i = 0; i < c * 3; i += 1) {
			const s = h("div.skeleton.sk-card", { style: { left: `${PAD + (i % c) * (cw + GAP)}px`, top: `${PAD + Math.floor(i / c) * (ch + GAP)}px`, width: `${cw}px`, height: `${state.view.mode === "list" ? 36 : ch}px`, animationDelay: `${i * 40}ms` } });
			canvas.appendChild(s);
		}
		canvas.style.height = `${PAD * 2 + 3 * (ch + GAP)}px`;
	}

	function hideSkeleton() {
		canvas.querySelectorAll(".sk-card").forEach(s => s.remove());
	}

	function clearCanvas() {
		for (const el of els.values()) el.remove();
		els.clear();
		hideSkeleton();
	}

	// ── layout ───────────────────────────────────────────────────────────
	function rebuild({ fresh } = {}) {
		let list = entries;
		const localKinds = mode !== "search" || !!route.query.recent;
		if (kindFilter && localKinds) list = list.filter(e => (kindFilter === "dir" ? e.dir : e.kind === kindFilter && !e.dir));
		if (filterText) list = list.filter(e => e.name.toLowerCase().includes(filterText));
		if (!state.view.hidden && mode === "files") list = list.filter(e => !e.name.startsWith("."));
		items = mode === "search" && state.view.sort === "name" ? list.slice() : sortEntries(list, state.view);
		if (state.view.group !== "none") {
			const order = [];
			const buckets = new Map();
			for (const e of items) {
				const g = groupOf(e, state.view.group);
				if (!buckets.has(g)) {
					buckets.set(g, []);
					order.push(g);
				}
				buckets.get(g).push(e);
			}
			items = order.flatMap(g => buckets.get(g));
		}
		// a selection keeps what is still there
		const paths = new Set(items.map(e => e.path));
		selected = new Set([...selected].filter(p => paths.has(p)));
		if (current >= items.length) current = items.length - 1;
		relayout();
		paint(fresh);
		updateCount();
		renderKindChips();
		details.show(selectedEntries(), folderEntry());
		if (!loading && !items.length) {
			if (mode === "search" && !route.query.q && !route.query.recent && !route.query.all) showEmpty("magnify", "Search the NAS", "Names, or by meaning with the switch beside the field.");
			else if (mode === "search") showEmpty("magnify_close", "Nothing found", route.query.recent ? "Nothing arrived lately." : `Nothing is called like “${route.query.q}”.`);
			else if (mode === "tag") showEmpty("tag_outline", "Nothing has this tag", "Tags come from the right-click menu › Tags.");
			else if (filterText || kindFilter) showEmpty("filter_variant", "Nothing matches", "Clear the filter to see everything.");
			else showEmpty("folder_open_outline", "An empty folder", "Drop files here, or upload with the button above.");
		} else {
			empty.hidden = true;
		}
	}

	function showEmpty(iconName, title, text) {
		empty.hidden = false;
		clear(empty).appendChild(h("div.empty", icon(iconName), h("h3", title), h("p", text)));
	}

	function relayout() {
		const width = Math.max(100, scroller.clientWidth - PAD * 2);
		const list = state.view.mode === "list";
		const mobile = isMobile();
		let cw;
		let ch;
		if (list) {
			cols = 1;
			cw = width;
			ch = mobile ? 54 : 37;
		} else {
			const target = mobile ? Math.min(state.view.card, 150) : state.view.card;
			cols = Math.max(mobile ? 2 : 1, Math.floor((width + GAP) / (target + GAP)));
			cw = (width - GAP * (cols - 1)) / cols;
			ch = Math.round((cw - 16) / 1.24 + 58);
		}
		const gap = list ? 0 : GAP;
		positions = new Array(items.length);
		rows = [];
		let y = list ? 4 : PAD;
		let lastGroup = null;
		let i = 0;
		while (i < items.length) {
			const g = state.view.group !== "none" ? groupOf(items[i], state.view.group) : "";
			if (g !== lastGroup && state.view.group !== "none") {
				const count = items.filter(e => groupOf(e, state.view.group) === g).length;
				rows.push({ type: "header", y, h: 40, label: g, count });
				y += 40;
				lastGroup = g;
			}
			const start = i;
			let n = 0;
			while (i < items.length && n < cols && (state.view.group === "none" || groupOf(items[i], state.view.group) === g)) {
				positions[i] = { x: PAD + n * (cw + gap * (list ? 0 : 1)), y, w: cw, h: ch, row: rows.length };
				i += 1;
				n += 1;
			}
			rows.push({ type: "items", y, h: ch, start, end: i });
			y += ch + gap;
		}
		total = y + PAD + 70;
		canvas.style.height = `${total}px`;
		canvas.dataset.mode = list ? "list" : "grid";
		root.style.setProperty("--card-w", `${cw}px`);
	}

	// which rows are on screen (binary search on y)
	function visibleRange() {
		const top = scroller.scrollTop - 400;
		const bottom = scroller.scrollTop + scroller.clientHeight + 400;
		let lo = 0;
		let hi = rows.length - 1;
		while (lo < hi) {
			const mid = (lo + hi) >> 1;
			if (rows[mid].y + rows[mid].h < top) lo = mid + 1;
			else hi = mid;
		}
		const out = [];
		for (let r = lo; r < rows.length && rows[r].y <= bottom; r += 1) out.push(r);
		return out;
	}

	const headers = new Map();
	function paint(fresh) {
		const visible = visibleRange();
		const want = new Set();
		const wantHeaders = new Set();
		const entering = [];
		const list = state.view.mode === "list";
		for (const r of visible) {
			const rowInfo = rows[r];
			if (rowInfo.type === "header") {
				const key = `${rowInfo.label}`;
				wantHeaders.add(key);
				let el = headers.get(key);
				if (!el) {
					el = h("div.group-head", h("span", rowInfo.label), h("span.subtle", String(rowInfo.count)));
					headers.set(key, el);
					canvas.appendChild(el);
				}
				el.style.top = `${rowInfo.y}px`;
				continue;
			}
			for (let i = rowInfo.start; i < rowInfo.end; i += 1) {
				const entry = items[i];
				const key = `${list ? "l" : "g"}:${entry.path}`;
				want.add(key);
				let el = els.get(key);
				if (!el || el._entry !== entry) {
					el?.remove();
					el = list ? listRow(entry, { showFolder: mode !== "files" }) : card(entry, { showFolder: mode !== "files" });
					el._entry = entry;
					el.dataset.index = i;
					els.set(key, el);
					canvas.appendChild(el);
					if (firstPaint || fresh?.has(entry.path)) entering.push(el);
				}
				el.dataset.index = i;
				const p = positions[i];
				el.style.left = `${p.x}px`;
				el.style.top = `${p.y}px`;
				el.style.width = `${p.w}px`;
				el.style.height = `${p.h}px`;
				el.classList.toggle("selected", selected.has(entry.path));
				el.classList.toggle("current", i === current);
				el.classList.toggle("cut", state.clipboard.cut && state.clipboard.paths.includes(entry.path));
				el.classList.toggle("hidden-file", entry.name.startsWith("."));
				if (list) el.classList.toggle("odd", i % 2 === 1);
			}
		}
		for (const [key, el] of els) {
			if (!want.has(key)) {
				el.remove();
				els.delete(key);
			}
		}
		for (const [key, el] of headers) {
			if (!wantHeaders.has(key)) {
				el.remove();
				headers.delete(key);
			}
		}
		if (entering.length) stagger(entering, { step: firstPaint ? 14 : 30, distance: 14, from: 0.9 });
		firstPaint = false;
	}

	const onScroll = throttleFrame(() => paint());
	scroller.addEventListener("scroll", onScroll, { passive: true });
	const resizeObserver = new ResizeObserver(throttleFrame(() => {
		relayout();
		paint();
	}));
	resizeObserver.observe(scroller);

	// ── selection ────────────────────────────────────────────────────────
	function selectedEntries() {
		return items.filter(e => selected.has(e.path));
	}

	function folderEntry() {
		return mode === "files" ? { path: folder, name: nameOf(folder), dir: true, count: items.length, size: items.reduce((s, e) => s + (e.size || 0), 0) } : null;
	}

	function setSelection(paths, { keepAnchor = false } = {}) {
		selected = new Set(paths);
		if (!keepAnchor) anchor = current;
		refreshMarks();
	}

	const refreshMarks = throttleFrame(() => {
		for (const el of els.values()) {
			const i = Number(el.dataset.index);
			el.classList.toggle("selected", selected.has(el._entry.path));
			el.classList.toggle("current", i === current);
		}
		updateCount();
		selectionBar.update();
		details.show(selectedEntries(), folderEntry());
	});

	function setCurrent(i, extend) {
		if (!items.length) return;
		i = Math.max(0, Math.min(items.length - 1, i));
		current = i;
		if (extend && anchor >= 0) {
			const [a, b] = anchor < i ? [anchor, i] : [i, anchor];
			setSelection(items.slice(a, b + 1).map(e => e.path), { keepAnchor: true });
		} else if (!extend) {
			anchor = i;
			setSelection([items[i].path], { keepAnchor: true });
		}
		ensureVisible(i);
		refreshMarks();
	}

	function ensureVisible(i) {
		const p = positions[i];
		if (!p) return;
		if (p.y < scroller.scrollTop + 8) scroller.scrollTo({ top: p.y - 12, behavior: reduced() ? "auto" : "smooth" });
		else if (p.y + p.h > scroller.scrollTop + scroller.clientHeight - 8) scroller.scrollTo({ top: p.y + p.h - scroller.clientHeight + 12 + (selected.size ? 70 : 0), behavior: reduced() ? "auto" : "smooth" });
	}

	function updateCount() {
		const n = items.length;
		const picked = selected.size;
		countText.textContent = loading ? "" : mode === "files" ? plural(n, "item") : plural(n, "result");
		pickedChip.hidden = !picked;
		if (picked) {
			const sizeSum = selectedEntries().reduce((s, e) => s + (e.size || 0), 0);
			pickedChip.textContent = `${picked} picked${sizeSum ? ` · ${fmtSize(sizeSum)}` : ""}`;
		}
	}

	function renderKindChips() {
		clear(kindChips);
		if (mode === "files") return;
		const present = new Set(entries.map(e => (e.dir ? "dir" : e.kind)));
		const kinds = mode === "search" && !route.query.recent ? KINDS : ["dir", ...KINDS].filter(k => present.has(k));
		if (kinds.length < 2 && !kindFilter) return;
		for (const k of kinds) {
			const chip = h("button.chip.small.ripple", { type: "button", class: kindFilter === k ? "on" : "" }, k === "dir" ? "Folders" : `${KIND_LABEL[k]}${k === "audio" || k === "code" || k === "text" ? "" : "s"}`);
			chip.addEventListener("click", () => {
				kindFilter = kindFilter === k ? "" : k;
				if (mode === "search" && !route.query.recent) load();
				else rebuild();
			});
			kindChips.appendChild(chip);
		}
	}

	// ── pointer ──────────────────────────────────────────────────────────
	const itemAt = target => target.closest?.(".file-card, .file-row");
	let pressed = null;
	let bandStart = null;
	let longTimer = 0;

	canvas.addEventListener("pointerdown", event => {
		scroller.focus({ preventScroll: true });
		const el = itemAt(event.target);
		if (event.button === 2) return;
		if (el) {
			const i = Number(el.dataset.index);
			const path = el._entry.path;
			if (event.pointerType === "touch") {
				longTimer = setTimeout(() => {
					selectMode = true;
					root.classList.add("select-mode");
					selectBtn.classList.add("on");
					navigator.vibrate?.(12);
					toggle(i);
					pressed = { handled: true };
				}, 480);
				pressed = { i, path, touch: true, x: event.clientX, y: event.clientY };
				return;
			}
			if (event.shiftKey) {
				current = i;
				const [a, b] = anchor < i ? [Math.max(0, anchor), i] : [i, anchor];
				setSelection(items.slice(a, b + 1).map(e => e.path), { keepAnchor: true });
			} else if (event.ctrlKey || event.metaKey) {
				toggle(i);
			} else if (!selected.has(path)) {
				current = i;
				anchor = i;
				setSelection([path], { keepAnchor: true });
			} else {
				// a click on something picked keeps the picks for a drag; the click narrows it
				pressed = { i, path, narrow: true };
				current = i;
				refreshMarks();
			}
			return;
		}
		// empty space: the rubber band
		if (event.pointerType === "touch") return;
		if (!event.shiftKey && !event.ctrlKey && !event.metaKey) setSelection([]);
		const rect = canvas.getBoundingClientRect();
		bandStart = { x: event.clientX - rect.left, y: event.clientY - rect.top, base: new Set(selected), id: event.pointerId };
		canvas.setPointerCapture(event.pointerId);
	});

	function toggle(i) {
		const path = items[i].path;
		const next = new Set(selected);
		if (next.has(path)) next.delete(path);
		else next.add(path);
		current = i;
		anchor = i;
		setSelection([...next], { keepAnchor: true });
	}

	let autoScroll = 0;
	canvas.addEventListener("pointermove", event => {
		if (pressed?.touch && Math.hypot(event.clientX - pressed.x, event.clientY - pressed.y) > 10) clearTimeout(longTimer);
		if (!bandStart) return;
		const rect = canvas.getBoundingClientRect();
		const x = event.clientX - rect.left;
		const y = event.clientY - rect.top;
		drawBand(x, y);
		// near an edge the view scrolls along
		const sr = scroller.getBoundingClientRect();
		const edge = event.clientY < sr.top + 40 ? -1 : event.clientY > sr.bottom - 40 ? 1 : 0;
		cancelAnimationFrame(autoScroll);
		if (edge) {
			const step = () => {
				scroller.scrollTop += edge * 14;
				drawBand(x, y + edge * 14);
				autoScroll = requestAnimationFrame(step);
			};
			autoScroll = requestAnimationFrame(step);
		}
	});

	function drawBand(x, y) {
		const left = Math.min(bandStart.x, x);
		const top = Math.min(bandStart.y, y);
		const w = Math.abs(x - bandStart.x);
		const hgt = Math.abs(y - bandStart.y);
		if (w < 4 && hgt < 4) return;
		band.hidden = false;
		band.style.left = `${left}px`;
		band.style.top = `${top}px`;
		band.style.width = `${w}px`;
		band.style.height = `${hgt}px`;
		const next = new Set(bandStart.base);
		for (let i = 0; i < items.length; i += 1) {
			const p = positions[i];
			if (p.x < left + w && p.x + p.w > left && p.y < top + hgt && p.y + p.h > top) next.add(items[i].path);
		}
		selected = next;
		refreshMarks();
	}

	const endPointer = event => {
		clearTimeout(longTimer);
		cancelAnimationFrame(autoScroll);
		if (bandStart) {
			band.hidden = true;
			bandStart = null;
			try {
				canvas.releasePointerCapture(event.pointerId);
			} catch (error) {}
			return;
		}
		const el = itemAt(event.target);
		if (pressed?.touch && !pressed.handled && el && Number(el.dataset.index) === pressed.i && event.type === "pointerup") {
			// a tap: open, or pick in pick mode
			if (selectMode) toggle(pressed.i);
			else openEntry(items[pressed.i], el);
		} else if (pressed?.narrow && el && Number(el.dataset.index) === pressed.i && event.type === "pointerup") {
			anchor = pressed.i;
			setSelection([pressed.path], { keepAnchor: true });
		}
		pressed = null;
	};
	canvas.addEventListener("pointerup", endPointer);
	canvas.addEventListener("pointercancel", endPointer);

	canvas.addEventListener("dblclick", event => {
		const el = itemAt(event.target);
		if (el) openEntry(el._entry, el);
	});

	canvas.addEventListener("contextmenu", event => {
		event.preventDefault();
		if (pressed?.touch) return;
		const el = itemAt(event.target);
		if (el) {
			const i = Number(el.dataset.index);
			if (!selected.has(el._entry.path)) {
				current = i;
				anchor = i;
				setSelection([el._entry.path], { keepAnchor: true });
			}
			showMenu(actions.forRows(ctx()), event.clientX, event.clientY);
		} else {
			setSelection([]);
			showMenu(actions.forPlace(ctx()), event.clientX, event.clientY);
		}
	});

	// ── drag & drop ──────────────────────────────────────────────────────
	let dragPaths = null;
	canvas.addEventListener("dragstart", event => {
		const el = itemAt(event.target);
		if (!el || isTouch()) {
			event.preventDefault();
			return;
		}
		if (!selected.has(el._entry.path)) setSelection([el._entry.path]);
		const picked = selectedEntries();
		dragPaths = picked.map(e => e.path);
		event.dataTransfer.setData("application/x-nas-paths", JSON.stringify(dragPaths));
		event.dataTransfer.setData("text/plain", dragPaths.join("\n"));
		// a single file can also be dragged out to the desktop (Chromium)
		if (picked.length === 1 && !picked[0].dir) {
			const url = new URL(api.fileUrl(picked[0].path, true), location.href).href;
			event.dataTransfer.setData("DownloadURL", `${picked[0].mime || "application/octet-stream"}:${picked[0].name}:${url}`);
		}
		event.dataTransfer.effectAllowed = "copyMove";
		const ghost = dragGhost(picked);
		event.dataTransfer.setDragImage(ghost, 30, 30);
		root.classList.add("dragging");
		for (const p of dragPaths) canvas.querySelector(`[data-path="${CSS.escape(p)}"]`)?.classList.add("lifted");
	});
	canvas.addEventListener("dragend", () => {
		dragPaths = null;
		root.classList.remove("dragging");
		canvas.querySelectorAll(".lifted, .drop").forEach(el => el.classList.remove("lifted", "drop"));
	});

	let dropDepth = 0;
	main.addEventListener("dragenter", event => {
		if (uploads.isFileDrag(event) && mode === "files") {
			dropDepth += 1;
			root.classList.add("file-drag");
			dropZone.querySelector(".drop-sub").textContent = `into ${folder === "/" ? "the top folder" : nameOf(folder)}`;
		}
	});
	main.addEventListener("dragleave", event => {
		if (uploads.isFileDrag(event)) {
			dropDepth = Math.max(0, dropDepth - 1);
			if (!dropDepth) root.classList.remove("file-drag");
		}
		const el = itemAt(event.target);
		if (el && !el.contains(event.relatedTarget)) el.classList.remove("drop");
	});
	main.addEventListener("dragover", event => {
		const el = itemAt(event.target);
		const onFolder = el?._entry.dir && !(dragPaths || []).includes(el._entry.path);
		canvas.querySelectorAll(".drop").forEach(other => other !== el && other.classList.remove("drop"));
		if (onFolder) {
			el.classList.add("drop");
			event.preventDefault();
			event.dataTransfer.dropEffect = event.ctrlKey ? "copy" : "move";
			return;
		}
		if (uploads.isFileDrag(event) && mode === "files") {
			event.preventDefault();
			event.dataTransfer.dropEffect = "copy";
		}
	});
	main.addEventListener("drop", event => {
		dropDepth = 0;
		root.classList.remove("file-drag");
		const el = itemAt(event.target);
		canvas.querySelectorAll(".drop").forEach(other => other.classList.remove("drop"));
		if (el?._entry.dir && !(dragPaths || []).includes(el._entry.path)) {
			event.preventDefault();
			const target = el;
			animate(target, [{ transform: "scale(1.06)" }, { transform: "scale(1)" }], { duration: 420, easing: EASE.spring, fill: "none" });
			actions.dropOn(el._entry.path, event);
			return;
		}
		if (uploads.isFileDrag(event) && mode === "files") {
			event.preventDefault();
			actions.dropOn(folder, event);
		}
	});

	// ── opening ──────────────────────────────────────────────────────────
	function openEntry(entry, el) {
		if (!entry) return;
		if (entry.dir) {
			app.openFolder(entry.path);
			return;
		}
		quickLook(entry, el);
	}

	function quickLook(entry, el) {
		const files = items.filter(e => !e.dir);
		const index = Math.max(0, files.findIndex(e => e.path === entry.path));
		const thumb = (el || canvas.querySelector(`[data-path="${CSS.escape(entry.path)}"]`))?.querySelector(".art");
		openQuickLook(files, index, {
			origin: thumb?.getBoundingClientRect(),
			originEl: path => canvas.querySelector(`[data-path="${CSS.escape(path)}"] .art`),
			onIndex: e => {
				const i = items.findIndex(x => x.path === e.path);
				if (i >= 0) {
					current = i;
					anchor = i;
					setSelection([e.path], { keepAnchor: true });
					ensureVisible(i);
				}
			},
			menu: (e, x, y) => showMenu(actions.forRows({ ...ctx(), rows: [e] }), x, y)
		});
	}

	// ── renaming in place ────────────────────────────────────────────────
	function renameRows(list) {
		if (list.length > 1) {
			actions.batchRename(list).then(() => load({ keep: true }));
			return;
		}
		const entry = list[0];
		const i = items.indexOf(entry);
		ensureVisible(i);
		setTimeout(() => {
			const el = canvas.querySelector(`[data-path="${CSS.escape(entry.path)}"]`);
			const text = el?.querySelector(".name-text");
			if (!text) return;
			const input = h("input.rename-input", { value: entry.name, spellcheck: false });
			text.replaceWith(input);
			el.classList.add("renaming");
			el.draggable = false;
			input.focus();
			const dot = entry.dir ? -1 : entry.name.lastIndexOf(".");
			input.setSelectionRange(0, dot > 0 ? dot : entry.name.length);
			let done = false;
			const finish = async commit => {
				if (done) return;
				done = true;
				el.classList.remove("renaming");
				el.draggable = true;
				input.replaceWith(text);
				scroller.focus();
				if (commit) {
					const name = input.value.trim();
					const result = await actions.rename(entry, name);
					if (result) {
						text.textContent = name;
						route.query.select = name;
					}
				}
			};
			input.addEventListener("keydown", event => {
				event.stopPropagation();
				if (event.key === "Enter") finish(true);
				if (event.key === "Escape") finish(false);
			});
			input.addEventListener("blur", () => finish(true));
			input.addEventListener("pointerdown", event => event.stopPropagation());
		}, 120);
	}

	// ── keys ─────────────────────────────────────────────────────────────
	let typed = "";
	let typedTimer = 0;
	function onKey(event) {
		const mod = event.ctrlKey || event.metaKey;
		const picked = selectedEntries();
		const k = event.key;
		const handled = () => event.preventDefault();
		if (k === "ArrowRight" || k === "ArrowLeft" || k === "ArrowDown" || k === "ArrowUp") {
			const step = state.view.mode === "list" ? { ArrowDown: 1, ArrowUp: -1, ArrowRight: 1, ArrowLeft: -1 }[k] : { ArrowDown: cols, ArrowUp: -cols, ArrowRight: 1, ArrowLeft: -1 }[k];
			setCurrent(current < 0 ? 0 : current + step, event.shiftKey);
			return handled();
		}
		if (k === "Home") {
			setCurrent(0, event.shiftKey);
			return handled();
		}
		if (k === "End") {
			setCurrent(items.length - 1, event.shiftKey);
			return handled();
		}
		if (k === "PageDown" || k === "PageUp") {
			const per = Math.max(1, Math.floor(scroller.clientHeight / ((positions[0]?.h || 100) + GAP))) * cols;
			setCurrent(current + (k === "PageDown" ? per : -per), event.shiftKey);
			return handled();
		}
		if (k === "Enter" && event.altKey) {
			setView({ details: !state.view.details });
			return handled();
		}
		if (k === "Enter" && picked.length) {
			if (picked.length === 1) openEntry(picked[0]);
			else picked.filter(e => e.dir).forEach(e => window.open(`#/files${encodePath(e.path)}`, "_blank"));
			return handled();
		}
		if (k === " " && picked.length) {
			quickLook(picked.find(e => !e.dir) || picked[0]);
			return handled();
		}
		if (k === "Backspace" && mode === "files" && folder !== "/") {
			app.go(`#/files${encodePath(parentOf(folder))}?select=${encodeURIComponent(nameOf(folder))}`);
			return handled();
		}
		if (k === "Escape") {
			if (selected.size) setSelection([]);
			return handled();
		}
		if (k === "F2" && picked.length) {
			renameRows(picked);
			return handled();
		}
		if (k === "Delete" && picked.length) {
			if (event.shiftKey) actions.deleteForGood(picked);
			else actions.trash(picked);
			return handled();
		}
		if (mod && k.toLowerCase() === "a") {
			setSelection(items.map(e => e.path));
			return handled();
		}
		if (mod && event.shiftKey && k.toLowerCase() === "c" && picked.length) {
			import("../util.js").then(u => u.copyText(picked.map(e => e.path).join("\n")));
			toast("Path copied", { icon: "clipboard_text_outline", timeout: 1400 });
			return handled();
		}
		if (mod && k.toLowerCase() === "c" && picked.length) {
			actions.copy(picked);
			return handled();
		}
		if (mod && k.toLowerCase() === "x" && picked.length) {
			actions.cut(picked);
			paint();
			return handled();
		}
		if (mod && k.toLowerCase() === "v" && mode === "files") {
			actions.paste(folder);
			return handled();
		}
		if (mod && k.toLowerCase() === "d") {
			if (picked.length === 1) actions.toggleFavorite(picked[0]);
			else if (!picked.length && mode === "files" && folder !== "/") actions.toggleFavorite({ path: folder, dir: true });
			return handled();
		}
		if (mod && event.shiftKey && k.toLowerCase() === "n" && mode === "files") {
			actions.newFolder(folder, api_);
			return handled();
		}
		if (mod && k.toLowerCase() === "r") {
			load({ keep: true });
			return handled();
		}
		if (mod && (k === "+" || k === "=")) {
			setView({ card: Math.min(300, state.view.card + 20) });
			return handled();
		}
		if (mod && k === "-") {
			setView({ card: Math.max(110, state.view.card - 20) });
			return handled();
		}
		if (!mod && !event.altKey && k.toLowerCase() === "u" && mode === "files") {
			uploads.pick(folder, false);
			return handled();
		}
		if (k === "ContextMenu" || (event.shiftKey && k === "F10")) {
			const p = positions[current];
			const rect = canvas.getBoundingClientRect();
			showMenu(actions.forRows(ctx()), p ? rect.left + p.x + 30 : innerWidth / 2, p ? rect.top + p.y + 30 : innerHeight / 2, { keyboard: true });
			return handled();
		}
		// type the start of a name to jump to it
		if (k.length === 1 && !mod && !event.altKey && /\S/.test(k)) {
			typed += k.toLowerCase();
			clearTimeout(typedTimer);
			typedTimer = setTimeout(() => (typed = ""), 800);
			const i = items.findIndex(e => e.name.toLowerCase().startsWith(typed));
			if (i >= 0) setCurrent(i, false);
		}
	}

	// ── the bar of what is picked (ChooserBar.qml) ───────────────────────
	function buildSelectionBar() {
		const label = h("span.sel-label");
		const button = (iconName, title, run) => {
			const b = h("button.icon-btn", { title }, icon(iconName));
			b.addEventListener("click", event => run(event));
			return b;
		};
		const el = h("div.selection-bar.panel-glass",
			button("close", "Pick nothing (Esc)", () => setSelection([])),
			label,
			h("div.sel-actions",
				button("download_outline", "Download", () => actions.download(selectedEntries())),
				button("share_variant_outline", "Share a link", () => actions.shareDialog(selectedEntries())),
				button("folder_move_outline", "Move to…", () => moveTo(selectedEntries())),
				button("trash_can_outline", "Move to the trash (Del)", () => actions.trash(selectedEntries())),
				button("dots_vertical", "More", event => showMenu(actions.forRows(ctx()), event.clientX, event.clientY))));
		let shown = false;
		return {
			el,
			update() {
				const n = selected.size;
				label.textContent = n === 1 ? selectedEntries()[0]?.name || "1 picked" : `${n} picked`;
				const show = n > 0 && (n > 1 || isMobile() || selectMode);
				if (show === shown) return;
				shown = show;
				el.classList.toggle("on", show);
			}
		};
	}

	async function moveTo(list) {
		const { pickFolder } = await import("../picker.js");
		const target = await pickFolder({ title: list.length === 1 ? `Move “${list[0].name}” to` : `Move ${list.length} items to`, start: folder || parentOf(list[0].path), confirmLabel: "Move here", allowCopy: true });
		if (!target) return;
		actions.transfer(list.map(e => e.path), target.path, target.copy ? "copy" : "move");
	}

	function viewMenu() {
		return [
			{ header: "Sort by" },
			...[["name", "Name"], ["mtime", "Modified"], ["size", "Size"], ["kind", "Kind"]].map(([key, label]) => ({ label, icon: "sort", checked: state.view.sort === key, run: () => setView({ sort: key }) })),
			{ label: state.view.desc ? "Descending" : "Ascending", icon: state.view.desc ? "sort_descending" : "sort_ascending", run: () => setView({ desc: !state.view.desc }) },
			{ header: "Group by" },
			...[["none", "Nothing"], ["kind", "Kind"], ["date", "Date"]].map(([key, label]) => ({ label, icon: "group", checked: state.view.group === key, run: () => setView({ group: key }) })),
			{ separator: true },
			{ label: "Folders first", icon: "folder_outline", checked: state.view.foldersFirst, run: () => setView({ foldersFirst: !state.view.foldersFirst }) },
			{ label: "Hidden files", icon: "file_hidden", checked: state.view.hidden, run: () => setView({ hidden: !state.view.hidden }) },
			{ header: "Show only" },
			{ label: "Everything", icon: "shape_outline", checked: !kindFilter, run: () => setKind("") },
			...(mode === "search" && !route.query.recent ? KINDS : ["dir", ...KINDS].filter(k => entries.some(e => (e.dir ? "dir" : e.kind) === k))).map(k => ({ label: k === "dir" ? "Folders" : KIND_LABEL[k], icon: k === "dir" ? "folder_outline" : "circle_small", checked: kindFilter === k, run: () => setKind(k) }))
		];
	}

	function setKind(k) {
		kindFilter = k;
		if (mode === "search" && !route.query.recent) load();
		else rebuild();
	}

	function sortLabel() {
		return { name: "Name", mtime: "Modified", size: "Size", kind: "Kind" }[state.view.sort] || "Name";
	}

	// ── crumbs ───────────────────────────────────────────────────────────
	function renderCrumbs(previous) {
		clear(crumbs);
		if (mode === "search") {
			const kindTitle = { image: "Pictures", video: "Videos", audio: "Music", pdf: "PDFs", office: "Documents", archive: "Archives", code: "Code", text: "Text" }[kindFilter] || "Files";
			crumbs.appendChild(h("div.page-title", icon(route.query.recent ? "history" : route.query.all ? "shape_outline" : route.query.semantic === "1" ? "creation" : "magnify"), h("span.ellipsis", route.query.recent ? "Recent" : route.query.all ? `All ${kindTitle.toLowerCase()}` : route.query.q ? `“${route.query.q}”` : "Search")));
			return;
		}
		if (mode === "tag") {
			crumbs.appendChild(h("div.page-title", icon("tag_outline"), h("span.ellipsis", route.parts[0] || "Tag")));
			return;
		}
		const parts = folder.split("/").filter(Boolean);
		const make = (label, path, last) => {
			const a = h(`a.crumb${last ? ".last" : ""}`, { href: `#/files${encodePath(path)}`, dataset: { path } }, path === "/" ? icon("harddisk") : null, h("span", label));
			a.addEventListener("dragover", event => {
				event.preventDefault();
				a.classList.add("drop");
			});
			a.addEventListener("dragleave", () => a.classList.remove("drop"));
			a.addEventListener("drop", event => {
				event.preventDefault();
				a.classList.remove("drop");
				actions.dropOn(path, event);
			});
			if (last) a.addEventListener("click", event => {
				event.preventDefault();
				const r = a.getBoundingClientRect();
				showMenu(actions.forPlace(ctx()), r.left, r.bottom + 6);
			});
			return a;
		};
		const all = [{ label: state.hello?.name || "NAS", path: "/" }, ...parts.map((p, i) => ({ label: p, path: `/${parts.slice(0, i + 1).join("/")}` }))];
		// long paths fold their middle into a menu
		let shown = all;
		if (isMobile() && all.length > 1) {
			const hidden = all.slice(0, -1);
			const more = h("button.crumb.more", { title: "Further up" }, icon("dots_horizontal"));
			more.addEventListener("click", event => showMenu(hidden.reverse().map(c => ({ label: c.label, icon: c.path === "/" ? "harddisk" : "folder_outline", run: () => app.openFolder(c.path) })), event.clientX, event.clientY));
			shown = [{ more }, all[all.length - 1]];
		} else if (all.length > 5) {
			const hidden = all.slice(1, all.length - 2);
			const more = h("button.crumb.more", { title: "Further up" }, icon("dots_horizontal"));
			more.addEventListener("click", event => showMenu(hidden.map(c => ({ label: c.label, icon: "folder_outline", run: () => app.openFolder(c.path) })), event.clientX, event.clientY));
			shown = [all[0], { more }, ...all.slice(-2)];
		}
		shown.forEach((c, i) => {
			if (i > 0) crumbs.appendChild(icon("chevron_right", "crumb-sep"));
			crumbs.appendChild(c.more || make(c.label, c.path, i === shown.length - 1));
		});
		// the new part slides in
		const last = crumbs.lastElementChild;
		if (previous !== undefined && last) animate(last, [{ opacity: 0, transform: "translateX(12px)" }, { opacity: 1, transform: "none" }], { duration: DUR.long, easing: EASE.spatial, fill: "none" });
	}

	// ── live updates ─────────────────────────────────────────────────────
	const reloadSoon = debounce(() => load({ keep: true }), 250);
	const offChanged = api.on("changed", data => {
		const paths = data.paths || [];
		if (mode === "files" && (paths.includes(folder) || paths.some(p => parentOf(p) === folder))) reloadSoon();
		else if (mode !== "files") reloadSoon();
	});
	const offView = onStore("view", v => {
		modeSeg.select(v.mode);
		sizeSlider.value = v.card;
		fillSlider();
		sortBtn.querySelector(".sort-label").textContent = sortLabel();
		detailsBtn.classList.toggle("on", v.details);
		showDetails(v.details);
		if (v.hidden !== hiddenWas) {
			hiddenWas = v.hidden;
			load({ keep: true });
			return;
		}
		if (v.mode !== modeWas) {
			modeWas = v.mode;
			clearCanvas();
			firstPaint = true;
		}
		drawListHead();
		rebuild();
		if (v.details && isMobile() && selected.size) details.sheet(selectedEntries());
	});
	let hiddenWas = state.view.hidden;
	let modeWas = state.view.mode;
	const offClip = onStore("clipboard", () => paint());
	const offFav = onStore("favorites", () => details.show(selectedEntries(), folderEntry()));

	// ── the view's face to the app and the menus ─────────────────────────
	const api_ = {
		open: list => {
			if (list.length === 1) openEntry(list[0]);
			else list.forEach(e => (e.dir ? window.open(`#/files${encodePath(e.path)}`, "_blank") : null));
		},
		quickLook: e => quickLook(e),
		rename: list => renameRows(list),
		reload: () => load({ keep: true }),
		selectAll: () => setSelection(items.map(e => e.path)),
		count: () => items.length,
		setView: patch => setView(patch),
		details: () => {
			if (isMobile()) details.sheet(selectedEntries());
			else setView({ details: true });
		},
		reveal: name => {
			route.query.select = name;
			setTimeout(() => {
				const i = items.findIndex(e => e.name === name);
				if (i >= 0) setCurrent(i, false);
			}, 400);
		}
	};
	const ctx = () => ({ folder: mode === "files" ? folder : null, rows: selectedEntries(), view: api_, virtual: mode !== "files" });

	// ── mount ────────────────────────────────────────────────────────────
	renderCrumbs();
	load();

	const offStatus = onStore("status", showFree);
	const viewFace = {
		el: root,
		toolsEl,
		tabTitle: () => (mode === "files" ? (folder === "/" ? state.hello?.name || "NAS" : nameOf(folder)) : mode === "tag" ? route.parts[0] || "Tag" : route.query.recent ? "Recent" : route.query.all ? "Everything of a kind" : "Search"),
		tabIcon: () => (mode === "files" ? (folder === "/" ? "harddisk" : "folder_outline") : mode === "tag" ? "tag_outline" : route.query.recent ? "history" : "magnify"),
		titleEl,
		accepts: next => next.name === mode || (mode !== "files" && next.name !== "files" && (next.name === "search" || next.name === "tag")),
		update(next, previous) {
			const sameFolder = mode === "files" && next.name === "files" && next.path === folder;
			route = next;
			mode = next.name;
			if (mode === "files") {
				const from = folder;
				folder = next.path;
				if (!sameFolder) {
					selected = new Set();
					current = -1;
					anchor = -1;
					filterText = "";
					kindFilter = "";
					scroller.scrollTop = 0;
					// deeper: the canvas slides from the right; up: from the left
					const deeper = folder.startsWith(from === "/" ? "/" : `${from}/`) && folder !== from;
					animate(scroller, [{ opacity: 0, transform: `translateX(${deeper ? 24 : -24}px)` }, { opacity: 1, transform: "none" }], { duration: DUR.xlong, easing: EASE.spatial, fill: "none" });
				}
			} else {
				kindFilter = next.query.kind || "";
				selected = new Set();
				current = -1;
			}
			newBtn.hidden = mode !== "files";
			renderCrumbs(previous);
			app.el.top.setTitle(viewFace);
			load({ keep: sameFolder });
		},
		folder: () => (mode === "files" ? folder : "/"),
		focusList: () => {
			scroller.focus();
			if (current < 0 && items.length) setCurrent(0, false);
		},
		refresh: () => load({ keep: true }),
		commands: () => (selected.size ? actions.forRows(ctx()) : actions.forPlace(ctx())),
		onKey,
		mounted: () => {
			app.el.right.replaceChildren(details.el);
			showDetails(state.view.details);
			scroller.focus({ preventScroll: true });
		},
		unmount() {
			showDetails(false);
			details.el.remove();
			offStatus();
			resizeObserver.disconnect();
			offChanged();
			offView();
			offClip();
			offFav();
			details.destroy();
		}
	};
	return viewFace;
}
