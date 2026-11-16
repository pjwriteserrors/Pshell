// Duplicates: the same file (or a look-alike picture) more than once. One of
// each group is kept, the others can go to the trash in one go.
import { h, icon, clear, nameOf, parentOf, size as fmtSize, plural, kindOf } from "../util.js";
import * as api from "../api.js";
import { stagger, animate, EASE, rollText } from "../motion.js";
import { segmented, confirm, toast, errorToast } from "../ui.js";
import { art } from "../files.js";
import { openQuickLook } from "../quicklook.js";
import * as jobs from "../jobs.js";

export default function dupes(route, app) {
	let mode = route.query.mode === "similar" ? "similar" : "exact";
	const scope = route.query.path || "";
	let groups = [];
	const drop = new Set();
	const listEl = h("div.dupe-list");
	const freed = h("strong");
	const goBtn = h("button.btn.danger", icon("trash_can_outline"), "To the trash");
	const bar = h("div.sticky-bar.panel-glass", h("div", "Frees ", freed, h("span.subtle.drop-count", "")), goBtn);
	const seg = segmented([{ value: "exact", label: "Same content" }, { value: "similar", label: "Look alike" }], mode, value => {
		mode = value;
		load();
	});
	const hashBtn = h("button.btn.small.ghost", { title: "Make checksums for files that have none yet" }, icon("pound"), "Check more files");
	hashBtn.addEventListener("click", async () => {
		try {
			await api.get("/api/dupes", { mode, hash: 1 });
			toast("Checksums are being made – look again in a while", { icon: "pound" });
		} catch (error) {
			errorToast(error);
		}
	});
	const page = h("div.page",
		h("div.page-head", h("div", h("h1", "Duplicates"), h("div.subtle", scope ? `In ${scope}` : "From the index: the same bytes, or pictures that look the same.")), h("div.page-tools", hashBtn, seg)),
		listEl,
		bar);
	const root = h("div.page-scroll", page);

	async function load() {
		clear(listEl).append(...[1, 2].map(() => h("div.skeleton", { style: { height: "200px", borderRadius: "22px" } })));
		drop.clear();
		try {
			const data = await api.get("/api/dupes", { mode });
			groups = (Array.isArray(data) ? data : data.groups || []).filter(g => (g.paths || []).length > 1);
			if (scope) groups = groups.filter(g => g.paths.some(p => p === scope || p.startsWith(`${scope.replace(/\/$/, "")}/`)));
			// keep the one with the shortest path, the others are suggested to go
			for (const g of groups) {
				g.paths.sort((a, b) => a.split("/").length - b.split("/").length || a.length - b.length);
				if (mode === "exact") g.paths.slice(1).forEach(p => drop.add(p));
			}
			render();
		} catch (error) {
			clear(listEl).appendChild(h("div.empty", icon("alert_circle_outline"), h("h3", "Could not look"), h("p", error.message)));
		}
	}

	function render() {
		clear(listEl);
		if (!groups.length) {
			listEl.appendChild(h("div.empty", icon("check_decagram_outline"), h("h3", "No duplicates"), h("p", mode === "exact" ? "Every file is there once – as far as the checksums go." : "No pictures look alike.")));
			updateBar();
			return;
		}
		for (const g of groups.slice(0, 300)) {
			const items = h("div.dupe-items");
			for (const p of g.paths) {
				const known = ["image", "video", "audio", "pdf", "text", "archive", "code", "office"];
				const entry = { path: p, name: nameOf(p), kind: known.includes(g.kind) ? g.kind : guessKind(p), size: g.size };
				const badge = h("span.badge");
				const item = h("div.dupe-item", art(entry), badge, h("div.ellipsis", entry.name), h("div.dupe-path", { title: p }, parentOf(p)));
				const paint = () => {
					const dropping = drop.has(p);
					item.classList.toggle("drop", dropping);
					item.classList.toggle("keep", !dropping);
					badge.textContent = dropping ? "Goes" : "Keep";
				};
				item.addEventListener("click", () => {
					if (drop.has(p)) drop.delete(p);
					else {
						// at least one stays
						if (g.paths.filter(x => !drop.has(x)).length <= 1) {
							animate(item, [{ transform: "translateX(-5px)" }, { transform: "translateX(5px)" }, { transform: "none" }], { duration: 260, fill: "none" });
							return;
						}
						drop.add(p);
					}
					paint();
					animate(item, [{ transform: "scale(0.95)" }, { transform: "none" }], { duration: 360, easing: EASE.spring, fill: "none" });
					updateBar();
				});
				item.addEventListener("dblclick", () => openQuickLook([entry], 0, { origin: item.querySelector(".art").getBoundingClientRect() }));
				paint();
				items.appendChild(item);
			}
			listEl.appendChild(h("div.dupe-group",
				h("div.dupe-head", h("div", h("strong", nameOf(g.paths[0])), h("div.subtle", `${plural(g.paths.length, "copy", "copies")} · ${fmtSize(g.size)} each`)),
					h("button.btn.small.ghost", { onclick: () => {
						g.paths.forEach(p => drop.delete(p));
						render();
					} }, "Keep all")),
				items));
		}
		stagger(listEl.children, { step: 30, distance: 14 });
		updateBar();
	}

	function updateBar() {
		let bytes = 0;
		for (const g of groups) for (const p of g.paths) if (drop.has(p)) bytes += g.size || 0;
		rollText(freed, fmtSize(bytes));
		bar.querySelector(".drop-count").textContent = drop.size ? ` · ${plural(drop.size, "copy", "copies")} go` : "";
		bar.hidden = !groups.length;
		goBtn.disabled = !drop.size;
	}

	goBtn.addEventListener("click", async () => {
		const paths = [...drop];
		const ok = await confirm({ title: `Move ${plural(paths.length, "copy", "copies")} to the trash?`, body: "One of each stays. The trash keeps them for a while.", details: paths, confirmLabel: "To the trash", danger: true, icon: "trash_can_outline" });
		if (!ok) return;
		try {
			const { job } = await api.post("/api/delete", { paths });
			jobs.track(job, done => {
				if (done.error) errorToast(new Error(done.error));
				else toast(`${plural(paths.length, "copy", "copies")} in the trash`, { icon: "trash_can_outline", tone: "good" });
				load();
			});
		} catch (error) {
			errorToast(error);
		}
	});

	load();
	return { el: root, title: "Duplicates", icon: "content_duplicate" };
}

function guessKind(path) {
	const ext = /\.([^.]+)$/.exec(path)?.[1]?.toLowerCase() || "";
	if (/^(jpe?g|png|gif|webp|avif|heic|bmp|tiff?|jxl)$/.test(ext)) return "image";
	if (/^(mp4|mkv|webm|mov|avi|m4v)$/.test(ext)) return "video";
	if (/^(mp3|flac|ogg|opus|m4a|wav)$/.test(ext)) return "audio";
	if (ext === "pdf") return "pdf";
	return "other";
}
