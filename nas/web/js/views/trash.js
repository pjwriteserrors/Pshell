// The trash: restore, delete for good, empty – with what is left of the
// days the NAS keeps it.
import { h, icon, clear, nameOf, parentOf, when, plural, size as fmtSize, debounce } from "../util.js";
import * as api from "../api.js";
import { setting } from "../store.js";
import { stagger, animate, EASE } from "../motion.js";
import { confirm, toast, errorToast, showMenu } from "../ui.js";
import { art } from "../files.js";
import * as jobs from "../jobs.js";

export default function trash(route, app) {
	let items = [];
	let picked = new Set();
	let filter = "";
	const listEl = h("div.list-card");
	const count = h("span.subtle");
	const restoreBtn = h("button.btn.small.soft", { disabled: true }, icon("restore"), "Restore");
	const deleteBtn = h("button.btn.small.danger", { disabled: true }, icon("delete_forever_outline"), "Delete for good");
	const emptyBtn = h("button.btn.small.danger", icon("delete_sweep_outline"), "Empty the trash");
	const filterInput = h("input", { placeholder: "Find", spellcheck: false });
	const page = h("div.page",
		h("div.page-head", h("div", h("h1", "Trash"), h("div.subtle", `Deleted things stay ${setting("trash_days", 30)} days, then they go for good.`)), h("div.page-tools", h("label.filter-box", icon("filter_variant"), filterInput), emptyBtn)),
		h("div.list-head", count, h("div.page-tools", restoreBtn, deleteBtn)),
		listEl);
	const root = h("div.page-scroll", page);

	filterInput.addEventListener("input", debounce(() => {
		filter = filterInput.value.trim().toLowerCase();
		render();
	}, 120));

	async function load(first) {
		if (first) clear(listEl).append(...[1, 2, 3, 4].map(() => h("div.skeleton", { style: { height: "58px", margin: "4px" } })));
		try {
			const data = await api.get("/api/trash");
			items = (Array.isArray(data) ? data : data.items || []).sort((a, b) => (b.deleted || 0) - (a.deleted || 0));
			picked = new Set([...picked].filter(id => items.some(i => i.id === id)));
			render(first);
		} catch (error) {
			clear(listEl).appendChild(h("div.empty", icon("alert_circle_outline"), h("h3", "Could not read the trash"), h("p", error.message)));
		}
	}

	function shown() {
		return filter ? items.filter(i => (i.name || nameOf(i.path)).toLowerCase().includes(filter) || (i.path || "").toLowerCase().includes(filter)) : items;
	}

	function render(animateIn) {
		clear(listEl);
		const list = shown();
		const total = items.reduce((s, i) => s + (i.size || 0), 0);
		count.textContent = items.length ? `${plural(items.length, "item")} · ${fmtSize(total)}${picked.size ? ` · ${picked.size} picked` : ""}` : "";
		restoreBtn.disabled = deleteBtn.disabled = !picked.size;
		emptyBtn.disabled = !items.length;
		restoreBtn.parentElement.parentElement.hidden = !items.length;
		if (!list.length) {
			listEl.appendChild(h("div.empty", icon("trash_can_outline"), h("h3", items.length ? "Nothing matches" : "The trash is empty"), h("p", items.length ? "" : "What you delete lands here first.")));
			return;
		}
		const days = Number(setting("trash_days", 30));
		for (const item of list) {
			const left = item.deleted ? Math.max(0, Math.ceil(days - (Date.now() / 1000 - item.deleted) / 86400)) : null;
			const entry = { name: item.name || nameOf(item.path), path: item.path, dir: item.dir, kind: item.kind || kindGuess(item.name || item.path), size: item.size };
			const check = h("button.row-check", icon("check_bold"));
			const el = h("div.list-row", { class: picked.has(item.id) ? "selected" : "" },
				check,
				h("div.row-thumb", art(entry)),
				h("div.row-main", h("div.row-title", h("span.ellipsis", entry.name)), h("div.row-sub", `${parentOf(item.path)} · ${fmtSize(item.size)} · deleted ${when(item.deleted)}${item.by ? ` by ${item.by}` : ""}`)),
				h("div.row-side", left !== null ? h(`span.chip${left <= 3 ? ".warn" : ""}`, icon("timer_outline"), `${left} d`) : null,
					h("button.icon-btn.small", { title: "Restore", onclick: event => {
						event.stopPropagation();
						restore([item.id], el);
					} }, icon("restore"))));
			el.addEventListener("click", event => {
				if (picked.has(item.id)) picked.delete(item.id);
				else picked.add(item.id);
				el.classList.toggle("selected", picked.has(item.id));
				render();
			});
			el.addEventListener("contextmenu", event => {
				event.preventDefault();
				showMenu([
					{ label: "Restore", icon: "restore", run: () => restore([item.id], el) },
					{ label: "Delete for good", icon: "delete_forever_outline", danger: true, run: () => remove([item.id]) }
				], event.clientX, event.clientY);
			});
			el._id = item.id;
			listEl.appendChild(el);
		}
		if (animateIn) stagger(listEl.children, { step: 18, distance: 8 });
	}

	async function restore(ids, el) {
		try {
			const { job } = await api.post("/api/trash/restore", { ids });
			const rowsOut = [...listEl.children].filter(r => ids.includes(r._id));
			rowsOut.forEach(r => animate(r, [{ opacity: 1, transform: "none" }, { opacity: 0, transform: "translateX(40px)" }], { duration: 300, easing: EASE.accel }));
			jobs.track(job, done => {
				if (done.error) errorToast(new Error(done.error));
				else toast(ids.length === 1 ? "Back where it was" : `${ids.length} items are back`, { icon: "restore", tone: "good" });
				ids.forEach(id => picked.delete(id));
				load();
			});
		} catch (error) {
			errorToast(error);
		}
	}

	async function remove(ids) {
		const ok = await confirm({ title: ids.length === 1 ? "Delete it for good?" : `Delete ${ids.length} items for good?`, body: "This cannot be undone.", confirmLabel: "Delete for good", danger: true, icon: "delete_forever_outline" });
		if (!ok) return;
		try {
			await api.post("/api/trash/empty", { ids });
			ids.forEach(id => picked.delete(id));
			toast("Deleted for good", { icon: "delete_forever_outline" });
			load();
		} catch (error) {
			errorToast(error);
		}
	}

	restoreBtn.addEventListener("click", () => restore([...picked]));
	deleteBtn.addEventListener("click", () => remove([...picked]));
	emptyBtn.addEventListener("click", async () => {
		const total = items.reduce((s, i) => s + (i.size || 0), 0);
		const ok = await confirm({ title: "Empty the trash?", body: `${plural(items.length, "item")} (${fmtSize(total)}) go for good. This cannot be undone.`, confirmLabel: "Empty the trash", danger: true, icon: "delete_sweep_outline", typeToConfirm: items.length > 20 ? "empty" : undefined });
		if (!ok) return;
		try {
			const result = await api.post("/api/trash/empty", {});
			[...listEl.children].forEach((r, i) => animate(r, [{ opacity: 1, transform: "none" }, { opacity: 0, transform: "translateY(20px) scale(0.96)" }], { duration: 260, delay: Math.min(i, 20) * 20, easing: EASE.accel }));
			toast(`The trash is empty${result?.removed ? ` – ${plural(result.removed, "item")} gone` : ""}`, { icon: "delete_sweep_outline", tone: "good" });
			setTimeout(() => load(), 500);
		} catch (error) {
			errorToast(error);
		}
	});

	const offs = [api.on("changed", debounce(() => load(), 400))];
	load(true);
	return { el: root, title: "Trash", icon: "trash_can_outline", unmount: () => offs.forEach(o => o()), refresh: () => load() };
}

function kindGuess(name) {
	const ext = /\.([^.]+)$/.exec(name || "")?.[1]?.toLowerCase() || "";
	if (/^(jpe?g|png|gif|webp|avif|heic|bmp|tiff?|jxl)$/.test(ext)) return "image";
	if (/^(mp4|mkv|webm|mov|avi|m4v)$/.test(ext)) return "video";
	if (/^(mp3|flac|ogg|opus|m4a|wav)$/.test(ext)) return "audio";
	if (ext === "pdf") return "pdf";
	if (/^(zip|7z|rar|tar|gz|xz)$/.test(ext)) return "archive";
	return "other";
}
