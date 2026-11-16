// The details panel (DetailsPanel.qml): a large picture, what it is, its
// tags, star and note, what its kind can do, and what happened to it.
import { h, icon, clear, size as fmtSize, fullDate, when, KIND_LABEL, plural, duration as fmtDuration, nameOf, parentOf, kindOf } from "./util.js";
import * as api from "./api.js";
import { art } from "./files.js";
import { state, rememberTags } from "./store.js";
import { showMenu, openDialog, errorToast, toast, prompt } from "./ui.js";
import { animate, EASE, DUR, stagger } from "./motion.js";
import * as actions from "./actions.js";
import { encodePath } from "./app.js";

export function createDetails({ onClose, view }) {
	const body = h("div.details-body");
	const el = h("aside.details", h("div.details-head", h("button.icon-btn.small", { title: "Close (Alt+Enter)", onclick: () => onClose() }, icon("close"))), body);
	let shownKey = "";
	let token = 0;

	function show(rows, folder) {
		if (!el.isConnected || !el.offsetParent) {
			shownKey = "";
			return;
		}
		const key = rows.length ? rows.map(r => r.path).join("|") + rows.map(r => `${r.favorite}${(r.tags || []).join()}`).join() : `folder:${folder?.path}:${folder?.count}`;
		if (key === shownKey) return;
		shownKey = key;
		const t = ++token;
		clear(body);
		const content = rows.length === 1 ? one(rows[0], t) : rows.length > 1 ? many(rows) : folder ? folderInfo(folder) : h("div.empty", icon("information_outline"), h("p", "Pick something to see it here."));
		body.appendChild(content);
		stagger(content.children, { step: 26, distance: 8, from: 0.98 });
	}

	function one(entry, t) {
		const wrap = h("div.details-one");
		const picture = h("div.details-art", art(entry, { size: 1024 }));
		picture.addEventListener("click", () => !entry.dir && view().quickLook(entry));
		const fav = !!entry.favorite || state.favorites.includes(entry.path);
		const star = h("button.icon-btn.star-btn", { title: fav ? "Remove from favorites" : "Add to favorites", class: fav ? "on" : "" }, icon(fav ? "star" : "star_outline"));
		star.addEventListener("click", async () => {
			await actions.toggleFavorite(entry);
			const on = !!entry.favorite;
			star.classList.toggle("on", on);
			star.firstChild.replaceWith(icon(on ? "star" : "star_outline"));
			animate(star, [{ transform: "scale(1.4) rotate(-12deg)" }, { transform: "none" }], { duration: 520, easing: EASE.spring, fill: "none" });
		});
		const facts = h("div.facts",
			fact("Kind", entry.dir ? "Folder" : `${KIND_LABEL[entry.kind] || "File"}${entry.mime ? ` · ${entry.mime}` : ""}`),
			entry.dir ? null : fact("Size", fmtSize(entry.size)),
			fact("Modified", fullDate(entry.mtime)),
			fact("Where", h("a", { href: `#/files${encodePath(parentOf(entry.path))}?select=${encodeURIComponent(entry.name)}` }, parentOf(entry.path))));
		const kind = actions.kindMenu([entry]);
		const buttons = h("div.details-actions",
			entry.dir ? h("button.btn.small.soft", { onclick: () => window.nasApp.openFolder(entry.path) }, icon("folder_open_outline"), "Open") : h("button.btn.small.soft", { onclick: () => view().quickLook(entry) }, icon("eye_outline"), "Look"),
			h("button.btn.small", { onclick: () => actions.download([entry]) }, icon("download_outline"), entry.dir ? "ZIP" : "Download"),
			kind ? h("button.btn.small", { onclick: event => showMenu(kind.entries, event.clientX, event.clientY) }, icon(kind.icon), kind.short || kind.label) : null,
			h("button.icon-btn.small", { title: "Share a link", onclick: () => actions.shareDialog([entry]) }, icon("share_variant_outline")),
			h("button.icon-btn.small", { title: "More", onclick: event => showMenu(actions.forRows({ rows: [entry], view: view(), folder: parentOf(entry.path) }), event.clientX, event.clientY) }, icon("dots_vertical")));
		const tags = tagEditor(entry);
		const note = h("textarea.note", { placeholder: "A note…", rows: 2 });
		note.value = entry.note || "";
		note.addEventListener("change", async () => {
			try {
				await api.put("/api/meta", { path: entry.path, note: note.value });
				entry.note = note.value;
				toast("Note saved", { icon: "note_outline", timeout: 1200 });
			} catch (error) {
				errorToast(error);
			}
		});
		const history = h("div.details-history");
		const subLine = h("div.details-sub", entry.dir ? "Folder" : [`${(/\.([^./]{1,6})$/.exec(entry.name)?.[1] || "").toUpperCase()} ${(KIND_LABEL[entry.kind] || "file").toLowerCase()}`.trim(), fmtSize(entry.size)].join(" · "));
		wrap.append(picture, h("div.details-name", h("h3", entry.name), star), subLine, buttons, facts, h("div.section-label", "Tags"), tags, h("div.section-label", "Note"), h("div.field.area", note), history);
		// more facts and what happened, once known
		api.get("/api/stat", { path: entry.path }, { quiet: true }).then(stat => {
			if (t !== token) return;
			if (stat.width) facts.appendChild(fact("Dimensions", `${stat.width} × ${stat.height}`));
			if (stat.duration) facts.appendChild(fact("Length", fmtDuration(stat.duration)));
			const exif = stat.exif || {};
			const camera = [exif.make || exif.Make, exif.model || exif.Model].filter(Boolean).join(" ");
			if (camera) facts.appendChild(fact("Camera", camera));
			if (exif.taken || exif.date || exif.DateTimeOriginal) facts.appendChild(fact("Taken", fullDate(exif.taken || exif.date || exif.DateTimeOriginal)));
			if (exif.place) facts.appendChild(fact("Place", exif.place));
		}).catch(() => {});
		api.get("/api/activity", { path: entry.path, limit: 6 }, { quiet: true }).then(log => {
			if (t !== token || !log?.length) return;
			history.appendChild(h("div.section-label", "Lately"));
			for (const item of log) history.appendChild(h("div.history-row", icon(activityIcon(item.what)), h("span.ellipsis", `${item.what.replace("_", " ")} by ${item.who}`), h("span.subtle", when(item.at))));
		}).catch(() => {});
		return wrap;
	}

	function many(rows) {
		const total = rows.reduce((s, r) => s + (r.size || 0), 0);
		const kinds = {};
		rows.forEach(r => (kinds[kindOf(r)] = (kinds[kindOf(r)] || 0) + 1));
		const stack = h("div.details-stack", rows.slice(0, 4).reverse().map((r, i, list) => {
			const layer = h("div.stack-card", art(r, { size: 256 }));
			const depth = list.length - 1 - i;
			layer.style.transform = `translate(${depth * 10}px, ${-depth * 8}px) rotate(${(depth - 1.5) * 4}deg)`;
			return layer;
		}));
		const kind = actions.kindMenu(rows);
		return h("div.details-many",
			stack,
			h("h3", `${rows.length} items`),
			h("div.subtle", total ? fmtSize(total) : ""),
			h("div.kind-list", Object.entries(kinds).map(([k, n]) => h("span.chip", `${n} ${k === "dir" ? "folders" : (KIND_LABEL[k] || "file").toLowerCase()}${n > 1 && k !== "dir" && k !== "audio" ? "s" : ""}`))),
			h("div.details-actions",
				h("button.btn.small", { onclick: () => actions.download(rows) }, icon("download_outline"), "ZIP"),
				kind ? h("button.btn.small", { onclick: event => showMenu(kind.entries, event.clientX, event.clientY) }, icon(kind.icon), kind.short || kind.label) : null,
				h("button.btn.small", { onclick: () => actions.shareDialog(rows) }, icon("share_variant_outline"), "Share")));
	}

	function folderInfo(folder) {
		return h("div.details-folder",
			h("div.details-art.folder", art({ dir: true, name: folder.name, path: folder.path })),
			h("h3", folder.path === "/" ? state.hello?.name || "NAS" : folder.name),
			h("div.facts", fact("Items", String(folder.count)), fact("Files here", fmtSize(folder.size)), fact("Path", folder.path)),
			h("div.details-actions",
				h("button.btn.small", { onclick: () => window.nasApp.go(`#/storage?path=${encodeURIComponent(folder.path)}`) }, icon("chart_donut"), "Space"),
				h("button.btn.small", { onclick: () => actions.download([{ path: folder.path, dir: true, name: folder.name }]) }, icon("download_outline"), "ZIP")));
	}

	function tagEditor(entry) {
		const box = h("div.tag-editor");
		const render = () => {
			clear(box);
			for (const tag of entry.tags || []) {
				const chip = h("span.chip.on.tag-chip", tag, h("button.tag-x", { title: "Take off", onclick: () => setTags((entry.tags || []).filter(t => t !== tag)) }, icon("close")));
				box.appendChild(chip);
			}
			const add = h("button.chip.ripple.add-tag", icon("plus"), "Tag");
			add.addEventListener("click", event => {
				const known = state.tags.filter(t => !(entry.tags || []).includes(t));
				showMenu([
					...known.map(t => ({ label: t, icon: "tag_outline", run: () => setTags([...(entry.tags || []), t]) })),
					known.length ? { separator: true } : null,
					{ label: "New tag…", icon: "tag_plus_outline", run: async () => {
						const name = await prompt({ title: "New tag", label: "Name", icon: "tag_plus_outline" });
						if (name) setTags([...(entry.tags || []), name]);
					} }
				].filter(Boolean), event.clientX, event.clientY);
			});
			box.appendChild(add);
		};
		const setTags = async tags => {
			const before = entry.tags || [];
			try {
				await api.put("/api/meta", { path: entry.path, tags });
				entry.tags = tags;
				rememberTags(tags);
				render();
				const last = box.querySelector(".tag-chip:last-of-type");
				if (tags.length > before.length && last) animate(last, [{ transform: "scale(0.6)", opacity: 0 }, { transform: "none", opacity: 1 }], { duration: 420, easing: EASE.spring, fill: "none" });
			} catch (error) {
				errorToast(error);
			}
		};
		render();
		return box;
	}

	return {
		el,
		show,
		sheet(rows) {
			if (!rows.length) return;
			const content = rows.length === 1 ? one(rows[0], ++token) : many(rows);
			openDialog({ body: content, sheet: true, className: "details-sheet" });
		},
		destroy() {}
	};
}

function fact(label, value) {
	return h("div.fact", h("span.subtle", label), typeof value === "string" ? h("span.fact-value", value) : h("span.fact-value", value));
}

export function activityIcon(what) {
	return {
		upload: "upload", delete: "trash_can_outline", move: "folder_move_outline", copy: "content_copy", rename: "form_textbox",
		restore: "restore", share: "link_variant", login: "login", login_failed: "alert_circle_outline", task: "cog_outline", setting: "cog_outline"
	}[what] || "circle_small";
}
