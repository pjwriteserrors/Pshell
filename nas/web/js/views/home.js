// Home (HomeView.qml): a glance at the NAS – space, who computes, tasks,
// health, backups and sync – then what came lately, favourites, places and
// the kinds of files.
import { h, icon, clear, nameOf, parentOf, size as fmtSize, when, plural, uptime, kindIcon } from "../util.js";
import * as api from "../api.js";
import { state, on as onStore, refreshStatus, isAdmin } from "../store.js";
import { ring, rollText, roll, stagger, animate, EASE, countUp } from "../motion.js";
import { art, recentEntries } from "../files.js";
import { showMenu, toast, errorToast } from "../ui.js";
import * as actions from "../actions.js";
import { openQuickLook } from "../quicklook.js";
import { encodePath } from "../app.js";
import { activityIcon } from "../details.js";

const KIND_TILES = [
	{ kind: "image", label: "Pictures", icon: "image_multiple_outline", tone: "var(--secondary)" },
	{ kind: "video", label: "Videos", icon: "movie_outline", tone: "var(--tertiary)" },
	{ kind: "audio", label: "Music", icon: "music_note", tone: "var(--warning)" },
	{ kind: "pdf", label: "PDFs", icon: "file_pdf_box", tone: "var(--danger)" },
	{ kind: "office", label: "Documents", icon: "file_document_outline", tone: "var(--primary)" },
	{ kind: "archive", label: "Archives", icon: "zip_box_outline", tone: "var(--warning)" },
	{ kind: "code", label: "Code", icon: "code_braces", tone: "var(--success)" },
	{ kind: "text", label: "Text", icon: "text_box_outline", tone: "var(--text-muted)" }
];

function greeting() {
	const hour = new Date().getHours();
	return hour < 5 ? "Good night" : hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening";
}

export default function home(route, app) {
	const offs = [];
	const name = state.me?.name || state.me?.user || "";
	const today = new Date().toLocaleDateString("en-GB", { weekday: "long", day: "numeric", month: "long" });
	const hero = h("section.hero",
		h("div.hero-text",
			h("h1", `${greeting()}${name ? `, ${name}` : ""}`),
			h("p.hero-line", h("span", today), h("span.hero-dot", "·"), h("span.hero-state", ""))));

	// ── the glance tiles ─────────────────────────────────────────────────
	const diskRing = ring(0, { size: 74, stroke: 8 });
	const diskPct = h("span.ring-pct");
	const diskFree = h("span.stat-big");
	const diskTile = h("a.stat-tile.disk-tile", { href: "#/storage" },
		h("div.ring-wrap", diskRing, diskPct),
		h("div.stat-body", h("div.section-label", "Space"), diskFree, h("div.stat-sub.subtle", "")));

	const workerTile = h("a.stat-tile.worker-tile", { href: "#/tasks" },
		h("div.worker-art", h("div.worker-orbit", h("i"), h("i"), h("i")), icon("chip")),
		h("div.stat-body", h("div.section-label", "Computing"), h("span.stat-big.worker-name", "…"), h("div.stat-sub.subtle", "")));

	const runningNum = roll("0", "stat-big");
	const queuedNum = roll("0");
	const tasksTile = h("a.stat-tile", { href: "#/tasks" },
		h("div.tile-icon", icon("cog_transfer_outline")),
		h("div.stat-body", h("div.section-label", "Tasks"), h("div.stat-line", runningNum, h("span.stat-unit", "running")), h("div.stat-sub.subtle", queuedNum, " queued")));

	const filesNum = roll("0", "stat-big");
	const indexTile = h("a.stat-tile", { href: "#/search?recent=1" },
		h("div.tile-icon", icon("file_tree_outline")),
		h("div.stat-body", h("div.section-label", "Indexed"), h("div.stat-line", filesNum, h("span.stat-unit", "files")), h("div.stat-sub.subtle", "")));

	const healthTile = h("a.stat-tile.health-tile", { href: "#/health" },
		h("div.tile-icon", icon("heart_pulse")),
		h("div.stat-body", h("div.section-label", "Health"), h("span.stat-big", "…"), h("div.stat-sub.subtle", "")));

	const tiles = h("section.stat-grid", diskTile, workerTile, tasksTile, indexTile, healthTile);

	const showStatus = s => {
		if (!s) return;
		const disk = s.disk || {};
		const used = disk.total ? (disk.used ?? disk.total - disk.free) / disk.total : 0;
		diskRing.set(used, used > 0.9 ? "var(--danger)" : used > 0.75 ? "var(--warning)" : "var(--primary)");
		rollText(diskPct, `${Math.round(used * 100)}%`);
		diskFree.textContent = disk.total ? `${fmtSize(disk.free)} free` : "–";
		diskTile.querySelector(".stat-sub").textContent = disk.total ? `${fmtSize(disk.used ?? disk.total - disk.free)} of ${fmtSize(disk.total)} used` : "";
		const pc = s.worker?.connected;
		workerTile.classList.toggle("pc", !!pc);
		workerTile.classList.toggle("pi", !pc);
		workerTile.querySelector(".worker-name").textContent = pc ? "PC computing" : "Pi computing";
		workerTile.querySelector(".stat-sub").textContent = pc ? `${s.worker.device || "The PC"} takes every task${s.worker.since ? ` · since ${when(s.worker.since)}` : ""}` : state.settings?.pi_compute === false ? "The Pi waits for the PC" : "No PC connected – the Pi works alone";
		rollText(runningNum, String(s.tasks?.running ?? 0));
		rollText(queuedNum, String(s.tasks?.queued ?? 0));
		rollText(filesNum, Number(s.index?.files ?? 0).toLocaleString("en-US"));
		indexTile.querySelector(".stat-sub").textContent = s.index?.scanning ? "Reading the disk…" : s.index?.folders ? `${Number(s.index.folders).toLocaleString("en-US")} folders` : "";
		indexTile.classList.toggle("scanning", !!s.index?.scanning);
		const health = s.health || {};
		const ok = health.ok !== false;
		healthTile.classList.toggle("bad", !ok);
		healthTile.querySelector(".stat-big").textContent = ok ? "All good" : (health.warnings || [])[0] || "Look";
		healthTile.querySelector(".stat-sub").textContent = health.temp ? `${health.temp} °C${health.throttled?.undervoltage ? " · undervoltage" : ""}` : "";
		hero.querySelector(".hero-state").textContent = [
			pc ? `${s.worker.device || "The PC"} is connected` : "The Pi is on its own",
			s.uploads ? `${plural(s.uploads, "upload")} unfinished` : "",
			s.tasks?.running ? `${plural(s.tasks.running, "task")} running` : ""
		].filter(Boolean).join(" · ");
	};
	offs.push(onStore("status", showStatus));
	showStatus(state.status);
	refreshStatus();

	// ── sections ─────────────────────────────────────────────────────────
	const section = (title, sub, content, more) => h("section.home-section",
		h("div.section-head", h("div", h("h2", title), sub ? h("div.subtle", sub) : null), more || null),
		content);

	const recentRow = h("div.card-row", skeletons(6));
	const picGrid = h("div.pic-mosaic");
	const docList = h("div.doc-list");
	const favRow = h("div.place-grid");
	const placeRow = h("div.place-grid", skeletons(4, "place"));
	const kindRow = h("div.kind-grid", KIND_TILES.map(k => {
		const tile = h("a.kind-tile", { href: `#/search?kind=${k.kind}&all=1` }, h("div.kind-icon", icon(k.icon)), h("span", k.label));
		tile.style.setProperty("--tone", k.tone);
		return tile;
	}));
	const careRow = h("div.care-grid");
	const activityList = h("div.activity-mini");
	const tasksList = h("div.tasks-mini");

	const showAll = (href, label = "Show all") => h("a.show-all", { href }, icon("arrow_right"), label);
	const picSection = section("Pictures", "", picGrid, showAll("#/photos", "Photos"));
	const docSection = section("Documents", "", docList, showAll("#/search?kind=pdf&all=1"));
	const page = h("div.home",
		hero,
		section("Places", "", placeRow),
		section("Lately", "Uploads and changes of the last days", recentRow, showAll("#/search?recent=1")),
		h("div.home-split", picSection, docSection),
		section("At a glance", "", tiles),
		section("Favorites", "", favRow),
		section("Backups and sync", "What the PCs keep here", careRow),
		section("Kinds", "", kindRow),
		h("div.home-split",
			section("Running", "Tasks and where they run", tasksList, showAll("#/tasks", "Tasks")),
			section("Activity", "Who did what", activityList, showAll("#/activity", "Log"))));
	const root = h("div.page-scroll", page);

	stagger([hero], { step: 50, distance: 18, from: 0.98 });
	stagger(tiles.children, { step: 50, distance: 14, from: 0.96 });
	stagger(page.querySelectorAll(".home-section"), { step: 60, distance: 24, from: 1 });

	// what came lately
	(async () => {
		let list = [];
		try {
			list = await recentEntries(18);
		} catch (error) {}
		clear(recentRow);
		if (!list.length) {
			recentRow.appendChild(h("div.row-empty.subtle", icon("cloud_upload_outline"), "Nothing new yet – drop files on Files to upload."));
			return;
		}
		const files = list.filter(e => !e.dir);
		list.forEach(entry => {
			const c = h("div.home-card", { tabindex: "0" }, h("div.card-art", art(entry, { size: 256 })), h("div.home-card-name.ellipsis", entry.name), h("div.home-card-meta.ellipsis", `${when(entry.mtime)} · ${fmtSize(entry.size)}`));
			c.addEventListener("click", () => {
				if (entry.dir) app.openFolder(entry.path);
				else openQuickLook(files, files.indexOf(entry), { origin: c.querySelector(".art").getBoundingClientRect(), originEl: p => recentRow.querySelector(`[data-p="${CSS.escape(p)}"] .art`), menu: (e, x, y) => showMenu(actions.forRows({ rows: [e], view: homeView(app), folder: parentOf(e.path), virtual: true }), x, y) });
			});
			c.dataset.p = entry.path;
			c.addEventListener("contextmenu", event => {
				event.preventDefault();
				showMenu(actions.forRows({ rows: [entry], view: homeView(app), folder: parentOf(entry.path), virtual: true }), event.clientX, event.clientY);
			});
			recentRow.appendChild(c);
		});
		stagger(recentRow.children, { step: 35 });
		// the newest pictures and documents among them
		const pics = files.filter(e => e.kind === "image").slice(0, 10);
		clear(picGrid);
		pics.forEach(p => {
			const tile = h("button.pic", { type: "button", title: p.name }, art(p, { size: 256 }));
			tile.addEventListener("click", () => openQuickLook(pics, pics.indexOf(p), { origin: tile.getBoundingClientRect() }));
			picGrid.appendChild(tile);
		});
		picSection.hidden = !pics.length;
		const docs = files.filter(e => ["pdf", "office", "text"].includes(e.kind)).slice(0, 7);
		clear(docList);
		docs.forEach(d => {
			const row = h("button.doc-row", { type: "button" }, h("div.doc-art", art(d, { size: 256 })), h("div.doc-text", h("div.ellipsis", d.name), h("div.subtle.ellipsis", `${parentOf(d.path)} · ${when(d.mtime)}`)));
			row.addEventListener("click", () => openQuickLook(docs, docs.indexOf(d), { origin: row.querySelector(".art").getBoundingClientRect() }));
			docList.appendChild(row);
		});
		docSection.hidden = !docs.length;
		stagger([...picGrid.children, ...docList.children], { step: 25, distance: 10 });
	})();

	// the places at the top
	api.get("/api/ls", { path: "/" }, { quiet: true }).then(data => {
		clear(placeRow);
		const dirs = (data.entries || []).filter(e => e.dir);
		dirs.slice(0, 14).forEach(d => placeRow.appendChild(placeTile(d, app)));
		if (!dirs.length) placeRow.appendChild(h("div.row-empty.subtle", "No folders yet"));
		stagger(placeRow.children, { step: 30 });
	}).catch(() => clear(placeRow));

	const showFavs = () => {
		clear(favRow);
		if (!state.favorites.length) {
			favRow.appendChild(h("div.row-empty.subtle", icon("star_outline"), "Star folders with Ctrl+D to keep them here."));
			return;
		}
		state.favorites.slice(0, 8).forEach(p => favRow.appendChild(placeTile({ path: p, name: nameOf(p), dir: true, favorite: true }, app)));
	};
	offs.push(onStore("favorites", showFavs));
	showFavs();

	// backups and sync from kv
	Promise.all([
		api.get("/api/kv/backup", null, { quiet: true }).catch(() => ({})),
		api.get("/api/kv/sync", null, { quiet: true }).catch(() => ({})),
		api.get("/api/kv/devices", null, { quiet: true }).catch(() => ({}))
	]).then(([backup, sync]) => {
		clear(careRow);
		const items = [];
		for (const [host, rec] of Object.entries(backup || {})) {
			const v = rec?.value ?? rec ?? {};
			const ok = v.ok !== false;
			const age = v.last ? (Date.now() / 1000 - v.last) / 86400 : null;
			const tone = !ok ? "bad" : age !== null && age > 8 ? "warn" : "good";
			items.push(h(`div.care-tile.${tone}`,
				h("div.care-icon", icon(ok ? "backup_restore" : "alert_circle_outline")),
				h("div.care-body",
					h("div.care-title", `Backup of ${host}`),
					h("div.subtle", !ok ? v.error || "The last one failed" : v.last ? `Last ${when(v.last)}${v.size ? ` · ${fmtSize(v.size)}` : ""}` : "Not yet"),
					v.next ? h("div.subtle", `Next ${when(v.next)}`) : null)));
		}
		for (const [pair, rec] of Object.entries(sync || {})) {
			const v = rec?.value ?? rec ?? {};
			const conflicts = v.conflicts?.length ?? v.conflicts ?? 0;
			const tone = v.state === "error" || v.error ? "bad" : conflicts ? "warn" : "good";
			items.push(h(`div.care-tile.${tone}`,
				h("div.care-icon", icon("folder_sync_outline")),
				h("div.care-body",
					h("div.care-title.ellipsis", v.name || v.local || pair),
					h("div.subtle.ellipsis", [v.mode, v.remote].filter(Boolean).join(" → ") || "Sync"),
					h("div.subtle", conflicts ? `${plural(conflicts, "conflict")}` : v.last ? `In step ${when(v.last)}` : v.state || ""))));
		}
		if (!items.length) careRow.appendChild(h("div.row-empty.subtle", icon("backup_restore"), "No backups or sync pairs report here yet – the shell's NAS page sets them up."));
		items.forEach(i => careRow.appendChild(i));
		stagger(careRow.children, { step: 40 });
	});

	// running tasks
	const showTasks = async () => {
		try {
			const list = await api.get("/api/tasks", { state: "running,queued,waiting_pc", limit: 6 }, { quiet: true });
			clear(tasksList);
			if (!list?.length) {
				tasksList.appendChild(h("div.row-empty.subtle", icon("check_all"), "Nothing running"));
				return;
			}
			for (const t of list.slice(0, 6)) {
				const r = ring(t.state === "running" ? t.progress || null : 0, { size: 30, stroke: 3, tone: t.where === "pc" ? "var(--secondary)" : "var(--tertiary)" });
				tasksList.appendChild(h("div.mini-row", r, h("div.mini-text", h("div.ellipsis", t.label || t.type), h("div.subtle.ellipsis", t.state === "waiting_pc" ? "Waits for the PC" : t.state === "queued" ? "Queued" : t.text || `${Math.round((t.progress || 0) * 100)} %`)), t.where ? h(`span.chip.${t.where}`, t.where === "pc" ? "PC" : "Pi") : null));
			}
		} catch (error) {}
	};
	showTasks();
	offs.push(api.on("task", () => showTasksSoon()));
	let tasksTimer = 0;
	const showTasksSoon = () => {
		clearTimeout(tasksTimer);
		tasksTimer = setTimeout(showTasks, 600);
	};

	api.get("/api/activity", { limit: 7 }, { quiet: true }).then(log => {
		clear(activityList);
		for (const item of log || []) {
			activityList.appendChild(h("div.mini-row", h("div.mini-icon", icon(activityIcon(item.what))), h("div.mini-text", h("div.ellipsis", describe(item)), h("div.subtle", `${item.who} · ${when(item.at)}`))));
		}
		if (!log?.length) activityList.appendChild(h("div.row-empty.subtle", "Quiet so far"));
	}).catch(() => {});

	return {
		el: root,
		title: "Home",
		icon: "home_outline",
		unmount: () => offs.forEach(off => off())
	};
}

function homeView(app) {
	return {
		open: rows => rows[0]?.dir ? app.openFolder(rows[0].path) : null,
		quickLook: e => openQuickLook([e], 0),
		rename: rows => actions.batchRename(rows),
		reload: () => app.view?.refresh?.(),
		selectAll() {},
		count: () => 0,
		setView() {},
		details: () => app.go(`#/files${encodePath(parentOf(app.route?.path || "/"))}`)
	};
}

export function describe(item) {
	const name = nameOf(item.path || "");
	switch (item.what) {
	case "upload": return `Uploaded ${name}`;
	case "delete": return item.detail?.includes?.("trash_emptied") ? "Emptied the trash" : `Deleted ${name}`;
	case "move": return `Moved ${name}${item.to ? ` to ${nameOf(parentOf(item.to)) || "NAS"}` : ""}`;
	case "copy": return `Copied ${name}`;
	case "rename": return `Renamed ${name}${item.to ? ` to ${nameOf(item.to)}` : ""}`;
	case "restore": return `Restored ${name}`;
	case "share": return `Shared ${name}`;
	case "login": return "Logged in";
	case "login_failed": return "A login failed";
	case "task": return `Task ${item.detail || ""} on ${name}`.trim();
	case "setting": return `Changed ${item.path || "a setting"}`;
	}
	return `${item.what} ${name}`;
}

function skeletons(n, kind = "card") {
	return [...Array(n)].map((_, i) => h(`div.skeleton.sk-${kind}`, { style: { animationDelay: `${i * 60}ms` } }));
}

function placeTile(entry, app) {
	const sub = h("div.subtle.ellipsis", entry.mtime ? when(entry.mtime) : "");
	const tile = h("a.place-tile", { href: entry.dir ? `#/files${encodePath(entry.path)}` : "#" }, h("div.place-art", art(entry, { size: 256 })), h("div.place-text", h("div.ellipsis", entry.name), sub));
	tile.addEventListener("folder-count", event => {
		if (event.detail !== null) sub.textContent = plural(event.detail, "item");
	});
	tile.addEventListener("dragover", event => {
		event.preventDefault();
		tile.classList.add("drop");
	});
	tile.addEventListener("dragleave", () => tile.classList.remove("drop"));
	tile.addEventListener("drop", event => {
		event.preventDefault();
		tile.classList.remove("drop");
		actions.dropOn(entry.path, event);
	});
	tile.addEventListener("contextmenu", event => {
		event.preventDefault();
		showMenu(actions.forRows({ rows: [entry], view: homeView(app), folder: parentOf(entry.path), virtual: true }), event.clientX, event.clientY);
	});
	return tile;
}
