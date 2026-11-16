// The public pages behind shared links: /s/{token} (download, with
// previews) and /u/{token} (drop files, never lists anything). They only
// talk to /api/public/{token}…, wear the NAS's palette and need no login.
import * as theme from "./theme.js";
import { h, icon, clear, size as fmtSize, when, plural, kindIcon, thumbable, fullDate } from "./util.js";
import { stagger, animate, EASE, DUR, installRipples, flipFrom } from "./motion.js";
import { toast, shake } from "./ui.js";
import { pdfView } from "./pdfview.js";

theme.applyCached();
theme.load();
installRipples();

const [, kindPart, token] = location.pathname.split("/");
const base = `/api/public/${encodeURIComponent(token || new URLSearchParams(location.search).get("t") || "")}`;
const app = document.getElementById("app");

const q = (path, params) => {
	const query = new URLSearchParams(params || {}).toString();
	return `${base}${path}${query ? `?${query}` : ""}`;
};

async function getJson(url) {
	const response = await fetch(url, { credentials: "same-origin" });
	let data = null;
	try {
		data = await response.json();
	} catch (error) {}
	return { ok: response.ok, status: response.status, data: data || {} };
}

function header(title, sub, extra) {
	return h("header.public-head",
		h("div.app-tile", icon("server")),
		h("div.public-title", { style: { flex: "1", minWidth: "0" } }, h("h1", title), h("div.subtle", sub)),
		extra || null);
}

async function start() {
	clear(app);
	const page = h("div.public");
	app.appendChild(page);
	page.appendChild(h("div.skeleton", { style: { height: "64px", borderRadius: "22px", marginBottom: "20px" } }));
	const { ok, status, data } = await getJson(base);
	clear(page);
	if (status === 401 && data.code === "password") return passwordPage(page, data);
	if (!ok) return gonePage(page, data, status);
	document.title = data.note || (data.kind === "upload" ? "Send files" : "Shared");
	if (data.kind === "upload") return uploadPage(page, data);
	return downloadPage(page, data);
}

function gonePage(page, data, status) {
	const card = h("div.login-card", { style: { margin: "12vh auto 0" } },
		h("div.login-logo", h("div.logo-disk", h("i"), h("i"), h("i")), h("div.logo-glow")),
		h("h1.login-name", status === 410 ? "This link has ended" : "No such link"),
		h("p.subtle", data.error || "It may have expired, been used up or removed."));
	page.appendChild(card);
	animate(card, [{ opacity: 0, transform: "translateY(20px) scale(0.95)" }, { opacity: 1, transform: "none" }], { duration: 600, easing: EASE.spring, fill: "none" });
}

function passwordPage(page, data) {
	const input = h("input", { type: "password", placeholder: "Password", autocomplete: "off" });
	const go = h("button.btn.primary.large.login-go", { type: "submit" }, h("span", "Open"), icon("arrow_right"));
	const error = h("div.login-error");
	const form = h("form.login-step", h("label.field.login-field", icon("lock_outline"), input), go);
	const card = h("div.login-card", { style: { margin: "12vh auto 0" } },
		h("div.login-logo", h("div.logo-disk", h("i"), h("i"), h("i")), h("div.logo-glow")),
		h("h1.login-name", data.note || (data.kind === "upload" ? "Send files" : "Shared with you")),
		h("div.login-sub", "This link has a password"),
		form, error);
	page.appendChild(card);
	animate(card, [{ opacity: 0, transform: "translateY(20px) scale(0.95)" }, { opacity: 1, transform: "none" }], { duration: 600, easing: EASE.spring, fill: "none" });
	setTimeout(() => input.focus(), 50);
	form.addEventListener("submit", async event => {
		event.preventDefault();
		go.classList.add("busy");
		const response = await fetch(q("/unlock"), { method: "POST", headers: { "Content-Type": "application/json", "X-Pshell": "1" }, body: JSON.stringify({ password: input.value }), credentials: "same-origin" });
		go.classList.remove("busy");
		if (response.ok) {
			await animate(card, [{ opacity: 1 }, { opacity: 0, transform: "scale(1.04)" }], { duration: 300, easing: EASE.accel }).finished;
			start();
			return;
		}
		let message = "Wrong password";
		try {
			message = (await response.json()).error || message;
		} catch (e) {}
		error.textContent = message;
		error.classList.add("on");
		shake(form);
		input.select();
	});
}

// ── download ───────────────────────────────────────────────────────────────
function downloadPage(page, data) {
	let path = "/";
	const entriesTop = data.entries || [];
	const single = entriesTop.length === 1 && !entriesTop[0].dir ? entriesTop[0] : null;
	// one folder: its name is the title and its content shows right away
	const folder = entriesTop.length === 1 && entriesTop[0].dir ? entriesTop[0] : null;
	const sub = [data.server ? `From ${data.server}` : "", data.expires ? `until ${fullDate(data.expires)}` : "", data.max_downloads ? `${Math.max(0, data.max_downloads - (data.downloads || 0))} downloads left` : ""].filter(Boolean).join(" · ");
	const zip = h("a.btn.primary", { href: data.zip, download: "" }, icon("download"), single ? "Download" : "Download all");
	if (single) zip.href = q("/file", { path: single.path, dl: 1 });
	if (data.used_up) {
		zip.classList.add("disabled");
		zip.removeAttribute("href");
	}
	page.appendChild(header(data.note || (single || folder ? (single || folder).name : plural(entriesTop.length, "item")), sub, zip));
	if (data.used_up) page.appendChild(h("div.warn-box", { style: { marginBottom: "16px" } }, icon("alert_outline"), h("div", "This link has been used up – previews still work, downloads do not.")));
	const crumbs = h("div.picker-crumbs");
	const grid = h("div.public-grid");
	page.append(crumbs, grid);
	animate(page.firstChild, [{ opacity: 0, transform: "translateY(-10px)" }, { opacity: 1, transform: "none" }], { duration: 500, easing: EASE.spring, fill: "none" });

	const show = async (next, entries) => {
		path = next;
		clear(crumbs);
		if (path !== "/" && !(folder && path === folder.path)) {
			const parts = path.split("/").filter(Boolean);
			const all = [{ label: folder ? folder.name : "Shared", path: folder ? folder.path : "/" }, ...parts.slice(folder ? 1 : 0).map((p, i) => ({ label: p, path: `/${parts.slice(0, i + (folder ? 2 : 1)).join("/")}` }))];
			all.forEach((c, i) => {
				if (i) crumbs.appendChild(icon("chevron_right", "crumb-sep"));
				crumbs.appendChild(h(`button.crumb${i === all.length - 1 ? ".last" : ""}`, { onclick: () => open(c.path) }, c.label));
			});
		}
		if (!entries) {
			grid.replaceChildren(...[1, 2, 3, 4].map(() => h("div.skeleton", { style: { height: "170px", borderRadius: "16px" } })));
			const { ok, data: listing } = await getJson(q("/ls", { path }));
			entries = ok ? listing.entries || [] : [];
		}
		clear(grid);
		const files = entries.filter(e => !e.dir);
		for (const e of entries) {
			const tile = h("div.art", { dataset: { kind: e.dir ? "dir" : e.kind } });
			tile.style.setProperty("--tone", e.dir ? "var(--primary)" : e.kind === "video" ? "var(--tertiary)" : e.kind === "audio" ? "var(--warning)" : e.kind === "pdf" ? "var(--danger)" : "var(--secondary)");
			const ext = e.dir ? "" : (/\.([^./]{1,5})$/.exec(e.name)?.[1] || "").toUpperCase();
			tile.appendChild(h("div.kind-tile", icon(kindIcon(e)), ext ? h("span.kind-ext", ext) : null));
			if (e.dir) tile.classList.add("folder");
			if (thumbable(e)) {
				const img = h("img.thumb", { alt: "", loading: "lazy" });
				img.addEventListener("load", () => {
					img.classList.add("loaded");
					tile.classList.add("has-thumb");
				});
				img.addEventListener("error", () => img.classList.add("failed"));
				img.src = q("/thumb", { path: e.path, size: 256 });
				tile.appendChild(img);
			}
			const dl = h("a.icon-btn.small.dl", { href: q("/file", { path: e.path, dl: 1 }), title: "Download", onclick: event => event.stopPropagation() }, icon("download_outline"));
			const card = h("div.public-card", tile, h("div.ellipsis", { style: { fontWeight: 600 } }, e.name), h("div.subtle", { style: { fontSize: "var(--fs-small)" } }, e.dir ? "Folder" : `${fmtSize(e.size)} · ${when(e.mtime)}`), data.used_up ? null : dl);
			card.addEventListener("click", () => (e.dir ? open(e.path) : view(files, files.indexOf(e), tile)));
			grid.appendChild(card);
		}
		if (!entries.length) grid.appendChild(h("div.empty", { style: { gridColumn: "1 / -1" } }, icon("folder_open_outline"), h("h3", "Empty")));
		stagger(grid.children, { step: 30, distance: 14 });
	};
	const open = next => show(next === "/" && folder ? folder.path : next);
	if (folder) show(folder.path);
	else show("/", entriesTop);

	// the viewer: everything shows here, nothing downloads unless asked
	function view(files, index, from) {
		const e = files[index];
		const url = q("/file", { path: e.path, view: 1 });
		let media;
		let pdf = null;
		const isText = e.kind === "text" || e.kind === "code" || /\.(json|ya?ml|toml|ini|conf|log|md|csv|txt|xml|sh|py|js|ts)$/i.test(e.name);
		if (e.kind === "image") {
			media = h("img.ql-img", { src: q("/thumb", { path: e.path, size: 1024 }), alt: e.name });
			media.onerror = () => {
				if (!media.dataset.full) {
					media.dataset.full = "1";
					media.src = url;
				}
			};
			if ((e.size || 0) < 6e6) {
				const full = new Image();
				full.onload = () => (media.src = full.src);
				full.src = url;
			}
		} else if (e.kind === "video") {
			media = h("video", { src: url, controls: true, autoplay: true, playsinline: true, preload: "metadata", style: { maxWidth: "100%", maxHeight: "100%" } });
		} else if (e.kind === "audio") {
			media = h("div.ql-audio", h("div.ql-audio-name", e.name), h("audio", { src: url, controls: true, autoplay: true, preload: "metadata", style: { width: "100%" } }));
		} else if (e.kind === "pdf" || /\.pdf$/i.test(e.name)) {
			pdf = pdfView(url, { name: e.name });
			media = h("div.ql-doc.pdf", pdf.el);
		} else if (isText) {
			const code = h("code", "…");
			media = h("div.ql-doc.text", h("pre.ql-text", code));
			fetch(url, { headers: { Range: "bytes=0-1048575" }, credentials: "same-origin" }).then(r => r.text()).then(t => (code.textContent = t)).catch(() => (code.textContent = "Could not read it"));
		} else {
			const tile = h("div.kind-tile", icon(kindIcon(e)), h("span.kind-ext", (/\.([^./]{1,5})$/.exec(e.name)?.[1] || "").toUpperCase()));
			tile.style.setProperty("--tone", "var(--primary)");
			media = h("div.ql-none", h("div.art", tile), h("h3", e.name), h("p.subtle", `${fmtSize(e.size)} – this kind of file is not shown in the browser`),
				data.used_up ? null : h("a.btn.primary", { href: q("/file", { path: e.path, dl: 1 }) }, icon("download_outline"), "Download"));
		}
		const close = () => {
			pdf?.cleanup();
			media.querySelector?.("video, audio")?.pause?.();
			if (media.pause) media.pause();
			animate(root, [{ opacity: 1 }, { opacity: 0 }], { duration: DUR.medium }).finished.then(() => root.remove());
			document.removeEventListener("keydown", key);
		};
		const step = d => {
			const n = index + d;
			if (n < 0 || n >= files.length) return;
			close();
			view(files, n);
		};
		const key = event => {
			if (pdf?.key(event)) {
				event.preventDefault();
				return;
			}
			if (event.key === "Escape") close();
			if (event.key === "ArrowRight") step(1);
			if (event.key === "ArrowLeft") step(-1);
		};
		document.addEventListener("keydown", key);
		const root = h("div.quicklook",
			h("div.ql-scrim", { onclick: close }),
			h("div.ql-body",
				h("div.ql-bar", h("button.icon-btn", { onclick: close, title: "Close" }, icon("close")), h("div.ql-titles", h("div.ql-title.ellipsis", e.name), h("div.ql-sub", fmtSize(e.size))), data.used_up ? null : h("a.icon-btn", { href: q("/file", { path: e.path, dl: 1 }), title: "Download" }, icon("download_outline"))),
				h("div.ql-middle", h("div.ql-stage", media),
					index > 0 ? h("button.ql-nav.prev", { onclick: () => step(-1) }, icon("chevron_left")) : null,
					index < files.length - 1 ? h("button.ql-nav.next", { onclick: () => step(1) }, icon("chevron_right")) : null)));
		document.getElementById("overlays").appendChild(root);
		animate(root.firstChild, [{ opacity: 0 }, { opacity: 1 }], { duration: DUR.long, fill: "none" });
		if (from) requestAnimationFrame(() => flipFrom(media, from.getBoundingClientRect(), { duration: 520 }));
		else animate(media, [{ opacity: 0, transform: "scale(0.94)" }, { opacity: 1, transform: "none" }], { duration: 420, easing: EASE.spring, fill: "none" });
		let touch = null;
		root.addEventListener("touchstart", ev => (touch = ev.target.closest(".ql-doc") ? null : ev.touches[0]), { passive: true });
		root.addEventListener("touchend", ev => {
			if (!touch) return;
			const dx = ev.changedTouches[0].clientX - touch.clientX;
			const dy = ev.changedTouches[0].clientY - touch.clientY;
			if (dy > 100) close();
			else if (dx < -60) step(1);
			else if (dx > 60) step(-1);
			touch = null;
		});
	}
}

// ── upload ─────────────────────────────────────────────────────────────────
function uploadPage(page, data) {
	page.appendChild(header(data.note || "Send files", [data.server ? `To ${data.server}` : "", data.expires ? `open until ${fullDate(data.expires)}` : ""].filter(Boolean).join(" · ")));
	const input = h("input", { type: "file", multiple: true, hidden: true });
	const drop = h("div.drop-big", { tabindex: "0", role: "button" },
		icon("cloud_upload_outline"),
		h("h2", "Drop files here"),
		h("div.subtle", "or tap to pick them – nothing on the NAS is shown to you"),
		input);
	const list = h("div.up-list");
	page.append(drop, list);
	animate(drop, [{ opacity: 0, transform: "translateY(16px) scale(0.97)" }, { opacity: 1, transform: "none" }], { duration: 600, easing: EASE.spring, fill: "none" });

	drop.addEventListener("click", () => input.click());
	drop.addEventListener("keydown", event => (event.key === "Enter" || event.key === " ") && input.click());
	input.addEventListener("change", () => send([...input.files]));
	let depth = 0;
	document.addEventListener("dragenter", event => {
		event.preventDefault();
		depth += 1;
		drop.classList.add("over");
	});
	document.addEventListener("dragleave", () => {
		depth = Math.max(0, depth - 1);
		if (!depth) drop.classList.remove("over");
	});
	document.addEventListener("dragover", event => event.preventDefault());
	document.addEventListener("drop", event => {
		event.preventDefault();
		depth = 0;
		drop.classList.remove("over");
		send([...(event.dataTransfer?.files || [])]);
	});

	const queue = [];
	let running = 0;
	let failed = 0;
	function send(files) {
		for (const file of files) {
			const bar = h("div.bar", h("i", { style: { width: "0%" } }));
			const state = h("span.subtle", "waiting");
			const row = h("div.up-row", h("div.row-icon", icon("file_outline")), h("div.row-main", h("div.ellipsis", { style: { fontWeight: 600 } }, file.name), h("div.subtle", fmtSize(file.size))), bar, state);
			list.prepend(row);
			animate(row, [{ opacity: 0, transform: "translateY(-10px)" }, { opacity: 1, transform: "none" }], { duration: 400, easing: EASE.spring, fill: "none" });
			queue.push({ file, bar, state, row });
		}
		pump();
	}
	function pump() {
		while (running < 2 && queue.length) {
			const item = queue.shift();
			running += 1;
			upload(item).finally(() => {
				running -= 1;
				pump();
				if (!running && !queue.length) {
					if (failed) toast(`${failed} did not arrive`, { icon: "alert_circle_outline", tone: "bad" });
					else toast("Everything arrived – thank you", { icon: "check_circle_outline", tone: "good" });
					failed = 0;
				}
			});
		}
	}
	function upload({ file, bar, state, row }) {
		return new Promise(resolve => {
			const xhr = new XMLHttpRequest();
			xhr.open("POST", q("/upload", { name: file.name }));
			xhr.setRequestHeader("Content-Type", "application/octet-stream");
			// the NAS asks for it whenever a session cookie rides along (CSRF)
			xhr.setRequestHeader("X-Pshell", "1");
			xhr.upload.onprogress = event => {
				const p = event.total ? event.loaded / event.total : 0;
				bar.firstChild.style.width = `${Math.round(p * 100)}%`;
				state.textContent = `${Math.round(p * 100)} %`;
			};
			xhr.onload = () => {
				if (xhr.status >= 200 && xhr.status < 300) {
					bar.firstChild.style.width = "100%";
					bar.firstChild.style.background = "var(--success)";
					state.replaceChildren(icon("check_circle"));
					state.style.color = "var(--success)";
					row.querySelector(".row-icon").style.color = "var(--success)";
				} else {
					let message = "failed";
					try {
						message = JSON.parse(xhr.responseText).error || message;
					} catch (e) {}
					state.textContent = message;
					state.style.color = "var(--danger)";
					bar.classList.add("bad");
					failed += 1;
				}
				resolve();
			};
			xhr.onerror = () => {
				failed += 1;
				state.textContent = "connection lost";
				state.style.color = "var(--danger)";
				resolve();
			};
			xhr.send(file);
		});
	}
}

start();
