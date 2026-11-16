// Shared links: download and upload links with expiry, password and a
// counter; copy, QR, remove.
import { h, icon, clear, nameOf, when, plural, copyText, toDate } from "../util.js";
import * as api from "../api.js";
import { setting } from "../store.js";
import { stagger, animate, EASE } from "../motion.js";
import { confirm, toast, errorToast, openDialog } from "../ui.js";
import * as actions from "../actions.js";

export default function shares(route, app) {
	let list = [];
	const listEl = h("div.list-card");
	const newDownload = h("button.btn.small.soft", icon("link_variant"), "Download link…");
	const newUpload = h("button.btn.small.primary", icon("cloud_upload_outline"), "Upload link…");
	const publicNote = h("div.warn-box", { hidden: true });
	const page = h("div.page",
		h("div.page-head", h("div", h("h1", "Shared links"), h("div.subtle", "Links to files on the NAS, and drop links that only take files.")), h("div.page-tools", newDownload, newUpload)),
		publicNote,
		h("div", { style: { height: "12px" } }),
		listEl);
	const root = h("div.page-scroll", page);

	const showPublic = () => {
		const on = setting("public_shares", false);
		publicNote.hidden = false;
		clear(publicNote).append(icon(on ? "earth" : "home_outline"), h("div", on ? "Public links are on: links also work from the internet through netcore-iseeu.duckdns.org." : "Public links are off: links work at home and over the VPN only. Settings › Sharing switches it."));
		publicNote.classList.toggle("danger-box", !!on);
	};
	showPublic();

	newUpload.addEventListener("click", () => actions.shareDialog([], "upload").then(() => load()));
	newDownload.addEventListener("click", async () => {
		const { pickFolder } = await import("../picker.js");
		const target = await pickFolder({ title: "What to share", confirmLabel: "Share this folder" });
		if (target) {
			await actions.shareDialog([{ path: target.path, name: nameOf(target.path), dir: true }], "download");
			load();
		}
	});

	async function load(first) {
		if (first) clear(listEl).append(...[1, 2, 3].map(() => h("div.skeleton", { style: { height: "64px", margin: "4px" } })));
		try {
			const data = await api.get("/api/shares");
			list = Array.isArray(data) ? data : data.shares || [];
			render(first);
		} catch (error) {
			clear(listEl).appendChild(h("div.empty", icon("alert_circle_outline"), h("h3", "Could not load the links"), h("p", error.message)));
		}
	}

	function render(animateIn) {
		clear(listEl);
		if (!list.length) {
			listEl.appendChild(h("div.empty", icon("link_variant"), h("h3", "No shared links"), h("p", "Right-click files › Share, or make an upload link here.")));
			return;
		}
		const now = Date.now() / 1000;
		for (const s of list) {
			const expired = s.expires && s.expires < now;
			const usedUp = s.max_downloads && s.downloads >= s.max_downloads;
			const upload = s.kind === "upload";
			const title = upload ? `Drop link${s.note ? ` – ${s.note}` : ""}` : (s.paths || []).length === 1 ? nameOf(s.paths[0]) : `${plural((s.paths || []).length, "item")}${s.note ? ` – ${s.note}` : ""}`;
			const url = s.url_public || s.url;
			const meta = h("div.share-meta",
				h(`span.chip${expired ? ".bad" : ""}`, icon("timer_outline"), expired ? "Expired" : s.expires ? `Until ${when(s.expires)}` : "Never expires"),
				upload ? (s.folder ? h("span.chip", icon("folder_outline"), s.folder) : null) : h(`span.chip${usedUp ? ".warn" : ""}`, icon("download_outline"), s.max_downloads ? `${s.downloads || 0} / ${s.max_downloads}` : `${s.downloads || 0} downloads`),
				s.password ? h("span.chip.accent", icon("lock_outline"), "Password") : null,
				s.url_public ? h("span.chip.warn", icon("earth"), "Public") : null);
			const el = h(`div.list-row.share-card${expired || usedUp ? ".expired" : ""}`,
				h(`div.share-kind${upload ? ".upload" : ""}`, icon(upload ? "cloud_upload_outline" : "link_variant")),
				h("div.row-main", h("div.row-title", h("span.ellipsis", title)), h("div.row-sub", `${upload ? "Upload only" : (s.paths || []).join(", ")} · made ${when(s.created)}${s.by ? ` by ${s.by}` : ""}`), meta),
				h("div.row-side",
					h("button.icon-btn.small", { title: "Copy the link", onclick: () => copyText(url).then(() => toast("Link copied", { icon: "link_variant", timeout: 1500 })) }, icon("content_copy")),
					h("button.icon-btn.small", { title: "QR code and link", onclick: () => actions.showShareLink(s, (s.paths || []).map(p => ({ name: nameOf(p), path: p })), s.kind) }, icon("qrcode")),
					h("button.icon-btn.small", { title: "Open", onclick: () => window.open(url, "_blank", "noopener") }, icon("open_in_new")),
					h("button.icon-btn.small", { title: "Remove the link", onclick: async () => {
						const ok = await confirm({ title: "Remove this link?", body: "Whoever has it can no longer use it.", confirmLabel: "Remove", danger: true, icon: "link_variant_off" });
						if (!ok) return;
						try {
							await api.del(`/api/shares/${s.id}`);
							await animate(el, [{ opacity: 1, transform: "none" }, { opacity: 0, transform: "translateX(40px)" }], { duration: 280, easing: EASE.accel }).finished;
							list = list.filter(x => x.id !== s.id);
							render();
						} catch (error) {
							errorToast(error);
						}
					} }, icon("delete_outline"))));
			listEl.appendChild(el);
		}
		if (animateIn) stagger(listEl.children, { step: 24, distance: 10 });
	}

	load(true);
	return { el: root, title: "Shared links", icon: "link_variant", refresh: () => load() };
}
