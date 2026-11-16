// The command palette (CommandPalette.qml), Ctrl+K: every page, everything
// the picked files can do (the same entries as the right-click menu), and
// files by name while typing.
import { h, icon, clear, debounce, nameOf, parentOf, kindIcon } from "./util.js";
import * as api from "./api.js";
import { animate, EASE, DUR } from "./motion.js";
import { isAdmin } from "./store.js";
import { encodePath } from "./app.js";
import * as uploads from "./uploads.js";

let openNow = null;

function flatten(entries, prefix = "", out = []) {
	for (const entry of entries || []) {
		if (!entry || entry.separator || entry.header || entry.shown === false || entry.enabled === false) continue;
		if (Array.isArray(entry.children)) flatten(entry.children, `${prefix}${entry.label} › `, out);
		else if (typeof entry.children === "function") {
			try {
				const result = entry.children();
				if (Array.isArray(result)) flatten(result, `${prefix}${entry.label} › `, out);
			} catch (error) {}
		} else if (entry.run) out.push({ label: `${prefix}${entry.label}`, icon: entry.icon, run: entry.run, shortcut: entry.shortcut, group: "Actions" });
	}
	return out;
}

function pages(app) {
	const go = hash => () => app.go(hash);
	const list = [
		["Home", "home_outline", "#/home"],
		["All files", "folder_outline", "#/files/"],
		["Photos", "image_multiple_outline", "#/photos"],
		["People", "account_multiple_outline", "#/photos?tab=people"],
		["Places", "map_marker_outline", "#/photos?tab=places"],
		["Recent", "history", "#/search?recent=1"],
		["Storage – what takes the space", "chart_donut", "#/storage"],
		["Duplicates", "content_duplicate", "#/dupes"],
		["Trash", "trash_can_outline", "#/trash"],
		["Shared links", "link_variant", "#/shares"],
		["Tasks", "cog_transfer_outline", "#/tasks"],
		["Activity", "chart_timeline_variant", "#/activity"]
	];
	if (isAdmin()) list.push(["Health", "heart_pulse", "#/health"], ["Devices", "devices", "#/devices"], ["Settings", "cog_outline", "#/settings"], ["Users and password", "account_outline", "#/settings?section=account"]);
	const out = list.map(([label, iconName, hash]) => ({ label: `Go to ${label}`, icon: iconName, run: go(hash), group: "Pages" }));
	const folder = app.view?.folder?.() ?? "/";
	out.push({ label: "Upload files here", icon: "upload_outline", run: () => uploads.pick(folder, false), group: "Pages", shortcut: "U" });
	out.push({ label: "Upload a folder here", icon: "folder_arrow_down_outline", run: () => uploads.pick(folder, true), group: "Pages" });
	return out;
}

function score(label, q) {
	const l = label.toLowerCase();
	if (!q) return 1;
	if (l.startsWith(q)) return 3;
	if (l.includes(` ${q}`) || l.includes(`›${q}`)) return 2.5;
	if (l.includes(q)) return 2;
	// letters in order
	let i = 0;
	for (const c of l) if (c === q[i]) i += 1;
	return i === q.length ? 1 : 0;
}

export function openPalette(app) {
	if (openNow) {
		openNow.input.focus();
		return;
	}
	const input = h("input", { placeholder: "Type a command or a file name", spellcheck: false, autocomplete: "off" });
	const list = h("div.palette-list", { role: "listbox" });
	const box = h("div.palette", h("label.palette-field", icon("console_line"), input, h("span.kbd", "Esc")), list);
	const scrim = h("div.dialog-scrim");
	const wrap = h("div.palette-wrap", scrim, box);
	document.getElementById("overlays").appendChild(wrap);
	animate(scrim, [{ opacity: 0 }, { opacity: 1 }], { duration: DUR.medium, fill: "none" });
	animate(box, [{ opacity: 0, transform: "translateY(-16px) scale(0.96)" }, { opacity: 1, transform: "none" }], { duration: DUR.spring, easing: EASE.spring, fill: "none" });

	const base = flatten(app.view?.commands?.() || []).concat(pages(app));
	let shown = [];
	let files = [];
	let current = 0;

	const render = () => {
		const q = input.value.trim().toLowerCase();
		const commands = base.map(c => ({ ...c, s: score(c.label, q) })).filter(c => c.s > 0).sort((a, b) => b.s - a.s).slice(0, q ? 40 : 60);
		shown = commands.concat(files);
		clear(list);
		let group = "";
		shown.forEach((item, i) => {
			if (item.group !== group) {
				group = item.group;
				list.appendChild(h("div.menu-header", group));
			}
			const row = h("div.palette-row", { class: i === current ? "current" : "" },
				icon(item.icon || "chevron_right"),
				h("div.palette-text", h("span.ellipsis", item.label), item.sub ? h("span.subtle.ellipsis", item.sub) : null),
				item.shortcut ? h("span.kbd", item.shortcut) : null);
			row.addEventListener("pointerenter", () => setCurrent(i));
			row.addEventListener("click", () => activate(i));
			list.appendChild(row);
		});
		if (!shown.length) list.appendChild(h("div.palette-none.subtle", "Nothing matches"));
	};

	const setCurrent = i => {
		current = Math.max(0, Math.min(shown.length - 1, i));
		[...list.querySelectorAll(".palette-row")].forEach((r, k) => r.classList.toggle("current", k === current));
		list.querySelectorAll(".palette-row")[current]?.scrollIntoView({ block: "nearest" });
	};

	const activate = i => {
		const item = shown[i];
		if (!item) return;
		close();
		setTimeout(() => item.run(), 0);
	};

	const searchFiles = debounce(async q => {
		if (q.length < 2) {
			files = [];
			render();
			return;
		}
		try {
			const data = await api.get("/api/search", { q, limit: 12 }, { quiet: true });
			if (input.value.trim() !== q) return;
			files = (data.entries || []).map(e => ({
				label: e.name,
				sub: parentOf(e.path),
				icon: kindIcon(e),
				group: "Files",
				run: () => (e.dir ? app.openFolder(e.path) : app.go(`#/files${encodePath(parentOf(e.path))}?select=${encodeURIComponent(e.name)}`))
			}));
			files.push({ label: `Search everywhere for “${q}”`, icon: "magnify", group: "Files", run: () => app.go(`#/search?q=${encodeURIComponent(q)}`) });
			render();
		} catch (error) {}
	}, 200);

	input.addEventListener("input", () => {
		current = 0;
		render();
		searchFiles(input.value.trim());
	});
	input.addEventListener("keydown", event => {
		if (event.key === "ArrowDown") {
			event.preventDefault();
			setCurrent(current + 1);
		} else if (event.key === "ArrowUp") {
			event.preventDefault();
			setCurrent(current - 1);
		} else if (event.key === "Enter") {
			event.preventDefault();
			activate(current);
		} else if (event.key === "Escape") {
			event.preventDefault();
			event.stopPropagation();
			close();
		}
	});
	scrim.addEventListener("click", () => close());

	let closed = false;
	function close() {
		if (closed) return;
		closed = true;
		openNow = null;
		wrap.style.pointerEvents = "none";
		animate(scrim, [{ opacity: 1 }, { opacity: 0 }], { duration: DUR.short });
		animate(box, [{ opacity: 1, transform: "none" }, { opacity: 0, transform: "translateY(-8px) scale(0.98)" }], { duration: DUR.short, easing: EASE.accel }).finished.then(() => wrap.remove());
	}

	render();
	openNow = { input, close };
	setTimeout(() => input.focus(), 10);
}
