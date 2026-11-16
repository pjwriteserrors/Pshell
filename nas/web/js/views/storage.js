// Storage (StorageView.qml + Treemap.js): what takes the space, as a
// squarified treemap from the index (GET /api/du). A click zooms into a
// folder; the crumbs and Backspace go back up.
import { h, icon, clear, nameOf, parentOf, size as fmtSize, plural } from "../util.js";
import * as api from "../api.js";
import { state, refreshStatus } from "../store.js";
import { ring, rollText, animate, EASE, stagger, reduced } from "../motion.js";
import { showMenu, toast, errorToast } from "../ui.js";
import { encodePath } from "../app.js";

const TONES = ["var(--primary)", "var(--secondary)", "var(--tertiary)", "var(--warning)", "var(--success)", "var(--danger)"];

// Bruls, Huizing, van Wijk – as Treemap.js in the shell
function worst(row, side, total, area) {
	if (!row.length) return Infinity;
	let min = Infinity;
	let max = 0;
	let sum = 0;
	for (const item of row) {
		const a = (item.size / total) * area;
		sum += a;
		if (a < min) min = a;
		if (a > max) max = a;
	}
	const s2 = sum * sum;
	const side2 = side * side;
	return Math.max((side2 * max) / s2, s2 / (side2 * min));
}

export function layout(items, x, y, w, hgt) {
	const list = items.filter(i => i.size > 0).sort((a, b) => b.size - a.size);
	const total = list.reduce((s, i) => s + i.size, 0);
	const out = [];
	if (total <= 0 || w <= 0 || hgt <= 0) return out;
	let box = { x, y, w, h: hgt };
	let rest = list.slice();
	let remaining = total;
	while (rest.length) {
		const side = Math.min(box.w, box.h);
		const area = box.w * box.h;
		const row = [];
		while (rest.length) {
			const next = row.concat([rest[0]]);
			if (row.length && worst(next, side, remaining, area) > worst(row, side, remaining, area)) break;
			row.push(rest.shift());
		}
		const rowSize = row.reduce((s, i) => s + i.size, 0);
		const share = rowSize / remaining;
		if (box.w >= box.h) {
			const rowW = box.w * share;
			let cy = box.y;
			for (const item of row) {
				const ih = (box.h * item.size) / rowSize;
				out.push({ ...item, x: box.x, y: cy, w: rowW, h: ih });
				cy += ih;
			}
			box = { x: box.x + rowW, y: box.y, w: box.w - rowW, h: box.h };
		} else {
			const rowH = box.h * share;
			let cx = box.x;
			for (const item of row) {
				const iw = (box.w * item.size) / rowSize;
				out.push({ ...item, x: cx, y: box.y, w: iw, h: rowH });
				cx += iw;
			}
			box = { x: box.x, y: box.y + rowH, w: box.w, h: box.h - rowH };
		}
		remaining -= rowSize;
	}
	return out;
}

export default function storage(route, app) {
	let path = route.query.path || "/";
	let tree = null;
	let token = 0;
	const crumbs = h("div.storage-crumbs");
	const total = h("span");
	const where = h("span");
	const sub = h("div.subtle");
	const barFill = h("i", { style: { width: "0%" } });
	const again = h("button.btn.small", icon("refresh"), "Measure again");
	again.addEventListener("click", async () => {
		again.classList.add("busy");
		try {
			await api.post("/api/index/rescan", { path });
			toast("Reading the folder again – the map follows", { icon: "refresh", timeout: 2200 });
			setTimeout(() => load(), 2500);
		} catch (error) {
			errorToast(error);
		} finally {
			setTimeout(() => again.classList.remove("busy"), 800);
		}
	});
	const map = h("div.treemap");
	const biggest = h("div.biggest");
	const tip = h("div.popover.tm-tip", { hidden: true, style: { pointerEvents: "none", minWidth: "0", padding: "8px 12px" } });
	const root = h("div.storage",
		h("div.storage-head", h("div.storage-title", h("h2", total, " in ", where), sub), again),
		h("div.storage-bar", barFill),
		h("div.storage-body", map, biggest));
	const titleEl = h("div.top-crumbs", crumbs);
	document.getElementById("overlays").appendChild(tip);

	const showDisk = s => {
		const d = s?.disk;
		if (!d?.total) return;
		const used = (d.used ?? d.total - d.free) / d.total;
		disk = d;
		paintHead();
	};
	let disk = null;
	const paintHead = () => {
		const size = tree?.size || 0;
		total.textContent = fmtSize(size);
		where.textContent = path === "/" ? state.hello?.name || "the NAS" : path;
		sub.textContent = [`${(tree?.children || []).length} parts`, disk?.total ? `${fmtSize(disk.free)} of ${fmtSize(disk.total)} free on the disk` : ""].filter(Boolean).join(" · ");
		barFill.style.width = disk?.total ? `${Math.max(1, (size / disk.total) * 100)}%` : "0%";
	};
	showDisk(state.status);
	refreshStatus().then(showDisk);

	async function load(fromRect) {
		const t = ++token;
		renderCrumbs();
		if (!tree) clear(map).appendChild(h("div.skeleton", { style: { position: "absolute", inset: "0" } }));
		try {
			const data = await api.get("/api/du", { path, depth: 2 });
			if (t !== token) return;
			tree = data;
			paintHead();
			draw(fromRect);
		} catch (error) {
			clear(map).appendChild(h("div.empty", icon("chart_donut"), h("h3", "No sizes yet"), h("p", error.message)));
		}
	}

	function draw(fromRect) {
		clear(map);
		const W = map.clientWidth;
		const H = map.clientHeight;
		const kids = (tree.children || []).filter(c => c.size > 0);
		if (!kids.length) {
			map.appendChild(h("div.empty", icon("folder_open_outline"), h("h3", "Nothing here takes space"), h("p", "Or the index has not read it yet.")));
			return;
		}
		const cells = layout(kids, 0, 0, W, H);
		const sum = tree.size || kids.reduce((s, c) => s + c.size, 0);
		cells.forEach((cell, i) => {
			const tone = cell.files ? "var(--secondary)" : "var(--primary)";
			cell.tone = tone;
			const tiny = cell.w < 70 || cell.h < 46;
			const el = h(`div.tm-cell${cell.files ? ".files" : ""}${tiny ? ".tiny" : ""}`, { style: { left: `${cell.x}px`, top: `${cell.y}px`, width: `${cell.w}px`, height: `${cell.h}px` } });
			el.style.setProperty("--tone", tone);
			el.style.setProperty("--mix", `${Math.round(18 + 22 * Math.sqrt(cell.size / sum))}%`);
			const inner = h("div.tm-inner", h("div.tm-name", cell.files ? "Files here" : cell.name), h("div.tm-size", `${fmtSize(cell.size)} · ${Math.round((cell.size / sum) * 100)} %`));
			// the next level faintly inside
			if (!cell.files && cell.children?.length && cell.w > 120 && cell.h > 90) {
				const inside = h("div.tm-kids");
				const iw = cell.w - 16;
				const ih = cell.h - 54;
				layout(cell.children, 0, 0, iw, ih).forEach(k => inside.appendChild(h("div.tm-kid", { style: { left: `${k.x + 1}px`, top: `${k.y + 1}px`, width: `${Math.max(0, k.w - 2)}px`, height: `${Math.max(0, k.h - 2)}px` }, title: `${k.name} · ${fmtSize(k.size)}` }, k.w > 70 && k.h > 24 ? (k.files ? "files" : k.name) : "")));
				inner.appendChild(inside);
			}
			el.appendChild(inner);
			el.addEventListener("pointermove", event => {
				tip.hidden = false;
				clear(tip).append(h("strong", cell.files ? `Files in ${nameOf(path) || "NAS"}` : cell.name), h("div.subtle", `${fmtSize(cell.size)} · ${((cell.size / sum) * 100).toFixed(1)} %`));
				tip.style.left = `${Math.min(innerWidth - tip.offsetWidth - 8, event.clientX + 14)}px`;
				tip.style.top = `${Math.min(innerHeight - tip.offsetHeight - 8, event.clientY + 14)}px`;
			});
			el.addEventListener("pointerleave", () => (tip.hidden = true));
			if (!cell.files) {
				el.addEventListener("click", () => {
					tip.hidden = true;
					path = cell.path;
					history.replaceState(null, "", `#/storage?path=${encodeURIComponent(path)}`);
					load(el.getBoundingClientRect());
				});
				el.addEventListener("contextmenu", event => {
					event.preventDefault();
					showMenu([
						{ label: "Open the folder", icon: "folder_open_outline", run: () => app.openFolder(cell.path) },
						{ label: "Zoom in", icon: "magnify_plus_outline", run: () => el.click() },
						{ label: "Find copies in it", icon: "content_duplicate", run: () => app.go(`#/dupes?path=${encodeURIComponent(cell.path)}`) }
					], event.clientX, event.clientY);
				});
				el.addEventListener("dblclick", () => app.openFolder(cell.path));
			}
			map.appendChild(el);
		});
		drawBiggest(cells, sum);
		// zooming in: the new map grows out of the clicked cell
		if (fromRect && !reduced()) {
			const mr = map.getBoundingClientRect();
			const sx = fromRect.width / mr.width;
			const sy = fromRect.height / mr.height;
			[...map.children].forEach(c => (c.style.transition = "none"));
			animate(map, [
				{ transformOrigin: "0 0", transform: `translate(${fromRect.left - mr.left}px, ${fromRect.top - mr.top}px) scale(${sx}, ${sy})`, opacity: 0.4 },
				{ transformOrigin: "0 0", transform: "none", opacity: 1 }
			], { duration: 560, easing: EASE.spring, fill: "none" }).finished.then(() => [...map.children].forEach(c => (c.style.transition = "")));
		} else {
			stagger(map.children, { step: 16, distance: 0, from: 0.9 });
		}
	}

	function drawBiggest(cells, sum) {
		clear(biggest).appendChild(h("h3", "Biggest here"));
		cells.slice().sort((a, b) => b.size - a.size).slice(0, 14).forEach(cell => {
			const row = h("button.big-row", { type: "button" }, icon(cell.files ? "file_multiple_outline" : "folder"), h("div.big-name", h("span.ellipsis", cell.files ? "Files here" : cell.name), h("div.bar", h("i", { style: { width: `${Math.max(2, (cell.size / sum) * 100)}%` } }))), h("span.big-size", fmtSize(cell.size)));
			row.style.setProperty("--tone", cell.tone);
			if (!cell.files) row.addEventListener("click", () => {
				path = cell.path;
				history.replaceState(null, "", `#/storage?path=${encodeURIComponent(path)}`);
				load();
			});
			biggest.appendChild(row);
		});
		stagger([...biggest.children].slice(1), { step: 20, distance: 6 });
	}

	function renderCrumbs() {
		clear(crumbs);
		const parts = path.split("/").filter(Boolean);
		const all = [{ label: state.hello?.name || "NAS", path: "/" }, ...parts.map((p, i) => ({ label: p, path: `/${parts.slice(0, i + 1).join("/")}` }))];
		all.forEach((c, i) => {
			if (i) crumbs.appendChild(icon("chevron_right", "crumb-sep"));
			const b = h(`button.crumb${i === all.length - 1 ? ".last" : ""}`, i === 0 ? icon("chart_donut") : null, h("span", c.label));
			b.addEventListener("click", () => {
				if (c.path === path) return;
				path = c.path;
				history.replaceState(null, "", `#/storage?path=${encodeURIComponent(path)}`);
				load();
			});
			crumbs.appendChild(b);
		});
	}

	const resize = new ResizeObserver(() => tree && draw());
	resize.observe(map);
	load();
	return {
		el: root,
		titleEl,
		title: "Storage",
		icon: "chart_donut",
		onKey(event) {
			if (event.key === "Backspace" && path !== "/") {
				path = parentOf(path);
				load();
			}
		},
		unmount() {
			resize.disconnect();
			tip.remove();
		}
	};
}
