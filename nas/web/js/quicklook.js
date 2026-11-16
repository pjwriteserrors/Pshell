// Quick look (QuickLook.qml): Space on a file. The thumbnail grows into the
// preview (FLIP) and shrinks back on close. Pictures zoom and pan, videos
// stream with Range and show the scrub sprite over the timeline, audio plays
// with its cover, PDFs open in the browser's viewer, text and code as text.
// Arrows walk the folder; on a phone swipe sideways, swipe down to close.
import { h, icon, clear, size as fmtSize, fullDate, duration as fmtDuration, KIND_LABEL, extOf } from "./util.js";
import * as api from "./api.js";
import { art, thumbSrc } from "./files.js";
import { pdfView } from "./pdfview.js";
import { flipFrom, flipTo, animate, EASE, DUR, reduced } from "./motion.js";
import { errorToast } from "./ui.js";
import * as actions from "./actions.js";

let open = null;

export function openQuickLook(entries, index, options = {}) {
	if (open) open.close();
	const list = entries.slice();
	let i = Math.max(0, Math.min(index, list.length - 1));
	let cleanup = () => {};
	let infoOn = false;

	const title = h("div.ql-title.ellipsis");
	const sub = h("div.ql-sub.ellipsis");
	const counter = h("span.ql-counter.tabular");
	const btn = (iconName, label, run) => {
		const b = h("button.icon-btn", { title: label }, icon(iconName));
		b.addEventListener("click", event => {
			event.stopPropagation();
			run(event);
		});
		return b;
	};
	const infoBtn = btn("information_outline", "Details (I)", () => toggleInfo());
	const thumbSlot = h("div.ql-thumb");
	const openBtn = h("button.btn.small.primary", { title: "Open in a new tab" }, icon("open_in_new"), "Open");
	openBtn.addEventListener("click", event => {
		event.stopPropagation();
		window.open(api.fileUrl(list[i].path), "_blank");
	});
	const editBtn = h("button.btn.small", { title: "What this kind of file can do" }, icon("image_edit_outline"), h("span", "Edit"));
	editBtn.addEventListener("click", event => {
		event.stopPropagation();
		const kind = actions.kindMenu([list[i]]);
		if (kind) import("./ui.js").then(ui => ui.showMenu(kind.entries, event.clientX, event.clientY));
	});
	const bar = h("div.ql-bar",
		thumbSlot,
		h("div.ql-titles", title, sub),
		counter,
		openBtn,
		editBtn,
		infoBtn,
		btn("download_outline", "Download", () => actions.download([list[i]])),
		btn("dots_vertical", "More", event => options.menu?.(list[i], event.clientX, event.clientY)),
		btn("close", "Close (Esc)", () => close()));
	const stage = h("div.ql-stage");
	const info = h("aside.ql-info");
	const prev = h("button.ql-nav.prev", { title: "Previous (←)" }, icon("chevron_left"));
	const next = h("button.ql-nav.next", { title: "Next (→)" }, icon("chevron_right"));
	prev.addEventListener("click", event => {
		event.stopPropagation();
		go(-1);
	});
	next.addEventListener("click", event => {
		event.stopPropagation();
		go(1);
	});
	const scrim = h("div.ql-scrim");
	const root = h("div.quicklook", { role: "dialog", "aria-modal": "true" }, scrim, h("div.ql-body", bar, h("div.ql-middle", stage, prev, next), info));
	document.getElementById("overlays").appendChild(root);
	document.body.classList.add("ql-open");
	animate(scrim, [{ opacity: 0 }, { opacity: 1 }], { duration: DUR.long, fill: "none" });
	const body = root.querySelector(".ql-body");
	animate(body, [{ opacity: 0, transform: "scale(0.96)" }, { opacity: 1, transform: "none" }], { duration: DUR.xlong, easing: EASE.spring, fill: "none" });

	function show(direction = 0, origin = null) {
		cleanup();
		cleanup = () => {};
		const entry = list[i];
		title.textContent = entry.name;
		sub.textContent = [list.length > 1 ? `${i + 1} of ${list.length}` : "", (() => {
			const ext = (/\.([^./]{1,6})$/.exec(entry.name)?.[1] || "").toUpperCase();
			const kind = (KIND_LABEL[entry.kind] || "file").toLowerCase();
			return ext.toLowerCase() === kind ? ext : `${ext} ${kind}`.trim();
		})(), fmtSize(entry.size), fullDate(entry.mtime)].filter(Boolean).join("  ·  ");
		thumbSlot.replaceChildren(art(entry, { size: 256, folder: false }));
		openBtn.hidden = !["image", "video", "audio", "text", "code"].includes(entry.kind);
		const kind = actions.kindMenu([entry]);
		editBtn.hidden = !kind;
		if (kind) {
			editBtn.firstChild.replaceWith(icon(kind.icon));
			editBtn.lastChild.textContent = kind.short || "Edit";
		}
		counter.textContent = list.length > 1 ? `${i + 1} / ${list.length}` : "";
		prev.hidden = i === 0;
		next.hidden = i >= list.length - 1;
		const old = stage.firstElementChild;
		const view = build(entry);
		const media = view.el;
		stage.appendChild(media);
		if (old) {
			old.style.position = "absolute";
			animate(old, [{ opacity: 1, transform: "none" }, { opacity: 0, transform: `translateX(${-direction * 60}px) scale(0.96)` }], { duration: DUR.medium, easing: EASE.accel }).finished.then(() => {
				old._cleanup?.();
				old.remove();
			});
		}
		cleanup = view.cleanup || (() => {});
		media._cleanup = view.cleanup;
		if (origin && view.flip) {
			requestAnimationFrame(() => flipFrom(view.flip(), origin, { duration: 520, easing: EASE.spring, radius: "16px" }));
			animate(media.querySelector(".ql-controls") || media, [{ opacity: 0 }, { opacity: 1 }], { duration: DUR.long, delay: 200, fill: "backwards" });
		} else if (direction) {
			animate(media, [{ opacity: 0, transform: `translateX(${direction * 60}px) scale(0.96)` }, { opacity: 1, transform: "none" }], { duration: DUR.xlong, easing: EASE.spatial, fill: "none" });
		} else {
			animate(media, [{ opacity: 0, transform: "scale(0.94)" }, { opacity: 1, transform: "none" }], { duration: DUR.xlong, easing: EASE.spring, fill: "none" });
		}
		if (infoOn) renderInfo();
		options.onIndex?.(entry);
		// the neighbours' pictures in advance
		for (const k of [i - 1, i + 1]) if (list[k]?.kind === "image") new Image().src = thumbSrc(list[k], 1024);
	}

	function build(entry) {
		const kind = entry.kind;
		if (kind === "image") return imageView(entry);
		if (kind === "video") return mediaView(entry, "video");
		if (kind === "audio") return mediaView(entry, "audio");
		if (kind === "pdf" || entry.mime === "application/pdf") {
			// drawn by pdf.js here – the browser's own handling may save it instead
			const view = pdfView(api.fileUrl(entry.path), { name: entry.name });
			const wrap = h("div.ql-doc.pdf", view.el);
			wrap._key = view.key;
			return { el: wrap, flip: () => wrap, cleanup: view.cleanup };
		}
		if (kind === "text" || kind === "code" || /^text\//.test(entry.mime || "") || /\.(json|ya?ml|toml|ini|conf|log|md|csv|sh|py|js|ts|qml|kdl|css|html?)$/i.test(entry.name)) return textView(entry);
		const wrap = h("div.ql-none", art(entry, { size: 1024 }), h("h3", entry.name), h("p.subtle", `${KIND_LABEL[kind] || "File"} · ${fmtSize(entry.size)}`), h("button.btn.primary", { onclick: () => actions.download([entry]) }, icon("download_outline"), "Download"));
		return { el: wrap, flip: () => wrap.firstChild };
	}

	// ── pictures: fit, zoom at the pointer, pan, pinch ──────────────────
	function imageView(entry) {
		const img = h("img.ql-img", { alt: entry.name, draggable: false });
		const full = new Image();
		img.src = thumbSrc(entry, 1024);
		img.onerror = () => {
			if (!img.dataset.fallback) {
				img.dataset.fallback = "1";
				img.src = api.fileUrl(entry.path);
			}
		};
		full.onload = () => {
			img.src = full.src;
			img.classList.add("sharp");
		};
		// the original only when it is not huge
		// the original as well when it is small; a big one only once it is zoomed into
		const browserShows = !/\.(heic|heif|tiff?|raw|cr2|nef|arw|dng|psd|jxl)$/i.test(entry.name);
		let wantFull = () => {
			wantFull = () => {};
			if (browserShows) full.src = api.fileUrl(entry.path);
		};
		if (entry.size < 6e6) setTimeout(() => wantFull(), 180);
		const wrap = h("div.ql-image", img);
		let scale = 1;
		let tx = 0;
		let ty = 0;
		const apply = (smooth) => {
			img.style.transition = smooth && !reduced() ? "transform 260ms var(--ease-spatial)" : "none";
			img.style.transform = `translate(${tx}px, ${ty}px) scale(${scale})`;
			wrap.classList.toggle("zoomed", scale > 1.01);
		};
		const zoomAt = (factor, cx, cy, smooth) => {
			const rect = wrap.getBoundingClientRect();
			const px = cx - rect.left - rect.width / 2;
			const py = cy - rect.top - rect.height / 2;
			const next = Math.max(1, Math.min(10, scale * factor));
			const k = next / scale;
			tx = px - (px - tx) * k;
			ty = py - (py - ty) * k;
			scale = next;
			if (scale > 1.05) wantFull();
			if (scale === 1) tx = ty = 0;
			apply(smooth);
		};
		wrap.addEventListener("wheel", event => {
			event.preventDefault();
			zoomAt(Math.exp(-event.deltaY * 0.0022), event.clientX, event.clientY, false);
		}, { passive: false });
		wrap.addEventListener("dblclick", event => {
			if (scale > 1) {
				scale = 1;
				tx = ty = 0;
				apply(true);
			} else zoomAt(2.5, event.clientX, event.clientY, true);
		});
		const pointers = new Map();
		let last = null;
		let pinch = null;
		wrap.addEventListener("pointerdown", event => {
			pointers.set(event.pointerId, { x: event.clientX, y: event.clientY });
			wrap.setPointerCapture(event.pointerId);
			last = { x: event.clientX, y: event.clientY };
			if (pointers.size === 2) {
				const [a, b] = [...pointers.values()];
				pinch = { d: Math.hypot(a.x - b.x, a.y - b.y), scale };
			}
		});
		wrap.addEventListener("pointermove", event => {
			if (!pointers.has(event.pointerId)) return;
			pointers.set(event.pointerId, { x: event.clientX, y: event.clientY });
			if (pointers.size === 2 && pinch) {
				const [a, b] = [...pointers.values()];
				const d = Math.hypot(a.x - b.x, a.y - b.y);
				zoomAt((pinch.scale * d / pinch.d) / scale, (a.x + b.x) / 2, (a.y + b.y) / 2, false);
				return;
			}
			if (scale > 1 && last) {
				tx += event.clientX - last.x;
				ty += event.clientY - last.y;
				last = { x: event.clientX, y: event.clientY };
				apply(false);
			}
		});
		const up = event => {
			pointers.delete(event.pointerId);
			if (pointers.size < 2) pinch = null;
			if (!pointers.size) last = null;
		};
		wrap.addEventListener("pointerup", up);
		wrap.addEventListener("pointercancel", up);
		wrap._zoomed = () => scale > 1.01;
		return { el: wrap, flip: () => img, cleanup: () => (full.src = "") };
	}

	// ── video and audio with own controls, the sprite over the timeline ──
	function mediaView(entry, type) {
		const media = h(type, { src: api.fileUrl(entry.path), preload: "metadata", playsinline: true });
		if (type === "video") media.poster = thumbSrc(entry, 1024);
		const play = h("button.icon-btn.ql-play", { title: "Play (K)" }, icon("play"));
		const time = h("span.ql-time.tabular", "0:00");
		const length = h("span.ql-time.tabular.subtle", "");
		const fill = h("div.tl-fill");
		const buffered = h("div.tl-buffer");
		const knob = h("div.tl-knob");
		const hoverPic = h("div.tl-preview", h("div.tl-sprite"), h("span.tl-time"));
		const line = h("div.tl", h("div.tl-track", buffered, fill), knob, hoverPic);
		const mute = h("button.icon-btn.small", { title: "Sound (M)" }, icon("volume_high"));
		const fs = type === "video" ? h("button.icon-btn.small", { title: "Full screen (F)" }, icon("fullscreen")) : null;
		const speed = h("button.btn.small.ghost.ql-speed", { title: "Speed" }, "1×");
		const controls = h("div.ql-controls", play, time, line, length, speed, mute, fs);
		let el;
		if (type === "audio") {
			const cover = h("div.ql-cover", art(entry, { size: 1024 }));
			el = h("div.ql-audio", cover, h("div.ql-audio-name", entry.name), media, controls);
		} else {
			el = h("div.ql-video", media, controls);
		}
		const toggle = () => (media.paused ? media.play() : media.pause());
		play.addEventListener("click", toggle);
		media.addEventListener("click", toggle);
		media.addEventListener("play", () => {
			play.firstChild.replaceWith(icon("pause"));
			el.classList.add("playing");
		});
		media.addEventListener("pause", () => {
			play.firstChild.replaceWith(icon("play"));
			el.classList.remove("playing");
		});
		media.addEventListener("loadedmetadata", () => (length.textContent = fmtDuration(media.duration)));
		media.addEventListener("timeupdate", () => {
			const p = media.duration ? media.currentTime / media.duration : 0;
			fill.style.transform = `scaleX(${p})`;
			knob.style.left = `${p * 100}%`;
			time.textContent = fmtDuration(media.currentTime);
		});
		media.addEventListener("progress", () => {
			try {
				const end = media.buffered.length ? media.buffered.end(media.buffered.length - 1) : 0;
				buffered.style.transform = `scaleX(${media.duration ? end / media.duration : 0})`;
			} catch (error) {}
		});
		media.addEventListener("error", () => controls.prepend(h("span.ql-error", "This file does not play in the browser – a stream-friendly copy helps")));
		mute.addEventListener("click", () => {
			media.muted = !media.muted;
			mute.firstChild.replaceWith(icon(media.muted ? "volume_off" : "volume_high"));
		});
		fs?.addEventListener("click", () => (document.fullscreenElement ? document.exitFullscreen() : el.requestFullscreen?.()));
		const speeds = [1, 1.25, 1.5, 2, 0.5, 0.75];
		speed.addEventListener("click", () => {
			const nextSpeed = speeds[(speeds.indexOf(media.playbackRate) + 1) % speeds.length];
			media.playbackRate = nextSpeed;
			speed.textContent = `${nextSpeed}×`;
		});
		// the scrub sprite (GET /api/preview) – made on first ask
		let sprite = null;
		if (type === "video") {
			api.get(api.withQuery("/api/preview", { path: entry.path, json: 1 }), null, { quiet: true }).then(meta => {
				sprite = meta;
				const s = hoverPic.firstChild;
				s.style.backgroundImage = `url("${api.previewUrl(entry.path)}")`;
				s.style.width = `${meta.width}px`;
				s.style.height = `${meta.height}px`;
				s.style.backgroundSize = `${meta.width * meta.cols}px ${meta.height * meta.rows}px`;
			}).catch(() => {});
		}
		const seekAt = event => {
			const rect = line.getBoundingClientRect();
			return Math.max(0, Math.min(1, (event.clientX - rect.left) / rect.width));
		};
		line.addEventListener("pointermove", event => {
			const p = seekAt(event);
			const dur = media.duration || sprite?.duration || 0;
			hoverPic.style.left = `${p * 100}%`;
			hoverPic.lastChild.textContent = fmtDuration(p * dur);
			hoverPic.classList.toggle("has-sprite", !!sprite);
			if (sprite) {
				const n = Math.min(sprite.count - 1, Math.floor((p * dur) / sprite.interval));
				hoverPic.firstChild.style.backgroundPosition = `-${(n % sprite.cols) * sprite.width}px -${Math.floor(n / sprite.cols) * sprite.height}px`;
			}
			if (dragging) media.currentTime = p * (media.duration || 0);
		});
		let dragging = false;
		line.addEventListener("pointerdown", event => {
			dragging = true;
			line.setPointerCapture(event.pointerId);
			line.classList.add("dragging");
			media.currentTime = seekAt(event) * (media.duration || 0);
		});
		line.addEventListener("pointerup", () => {
			dragging = false;
			line.classList.remove("dragging");
		});
		el._key = event => {
			const k = event.key.toLowerCase();
			if (k === "k" || (k === " " && event.target === document.body)) toggle();
			else if (k === "j") media.currentTime -= 10;
			else if (k === "l") media.currentTime += 10;
			else if (k === "m") mute.click();
			else if (k === "f") fs?.click();
			else return false;
			return true;
		};
		setTimeout(() => media.play?.().catch(() => {}), 380);
		return { el, flip: () => (type === "video" ? media : el.querySelector(".ql-cover")), cleanup: () => {
			media.pause();
			media.removeAttribute("src");
			media.load();
		} };
	}

	// ── text and code ────────────────────────────────────────────────────
	function textView(entry) {
		const pre = h("pre.ql-text", h("code", ""));
		const wrap = h("div.ql-doc.text", pre);
		const controller = new AbortController();
		fetch(api.fileUrl(entry.path), { headers: { Range: "bytes=0-1048575" }, credentials: "same-origin", signal: controller.signal })
			.then(r => r.text())
			.then(text => {
				const lines = text.split("\n");
				const code = pre.firstChild;
				const gutter = h("div.ql-gutter", lines.map((_, n) => h("span", String(n + 1))));
				code.textContent = text;
				if (/\.md$/i.test(entry.name)) code.classList.add("markdown");
				pre.prepend(gutter);
				if (entry.size > 1048576) wrap.appendChild(h("div.ql-more", `The first 1 MB of ${fmtSize(entry.size)}`));
			})
			.catch(error => error.name !== "AbortError" && errorToast(error));
		return { el: wrap, flip: () => wrap, cleanup: () => controller.abort() };
	}

	// ── details beside it ───────────────────────────────────────────────
	async function renderInfo() {
		const entry = list[i];
		clear(info);
		const rows = [["Kind", KIND_LABEL[entry.kind] || "File"], ["Size", fmtSize(entry.size)], ["Modified", fullDate(entry.mtime)], ["Where", entry.path]];
		const table = h("div.ql-facts", rows.map(([k, v]) => h("div.fact", h("span.subtle", k), h("span", v))));
		info.appendChild(h("h3", entry.name));
		info.appendChild(table);
		try {
			const stat = await api.get("/api/stat", { path: entry.path });
			if (list[i] !== entry) return;
			const extra = [];
			if (stat.width) extra.push(["Dimensions", `${stat.width} × ${stat.height}`]);
			if (stat.duration) extra.push(["Length", fmtDuration(stat.duration)]);
			for (const [k, v] of Object.entries(stat.exif || {})) {
				if (v === null || v === "" || typeof v === "object") continue;
				const label = k.replace(/_/g, " ").replace(/^./, c => c.toUpperCase());
				extra.push([label, /taken|date|time/i.test(k) && typeof v === "number" ? fullDate(v) : String(v)]);
			}
			extra.forEach(([k, v]) => table.appendChild(h("div.fact", h("span.subtle", k), h("span", v))));
		} catch (error) {}
	}

	function toggleInfo() {
		infoOn = !infoOn;
		root.classList.toggle("with-info", infoOn);
		infoBtn.classList.toggle("on", infoOn);
		if (infoOn) renderInfo();
	}

	function go(delta) {
		const n = i + delta;
		if (n < 0 || n >= list.length) {
			animate(stage, [{ transform: "translateX(0)" }, { transform: `translateX(${-delta * 18}px)` }, { transform: "translateX(0)" }], { duration: 320, easing: EASE.spatial, fill: "none" });
			return;
		}
		i = n;
		show(delta);
	}

	// ── keys, swipes ─────────────────────────────────────────────────────
	const onKey = event => {
		if (document.querySelector(".menu-layer, .dialog-wrap")) return;
		// typing in the PDF's page or find field stays there
		if (event.target.closest?.("input, textarea") && root.contains(event.target)) return;
		const media = stage.lastElementChild;
		if (media?._key?.(event)) {
			event.preventDefault();
			return;
		}
		if (event.key === "Escape" || event.key === " " && !media?._key) {
			event.preventDefault();
			event.stopPropagation();
			close();
		} else if (event.key === "ArrowRight") {
			event.preventDefault();
			go(1);
		} else if (event.key === "ArrowLeft") {
			event.preventDefault();
			go(-1);
		} else if (event.key.toLowerCase() === "i") {
			toggleInfo();
		} else if (event.key === " ") {
			event.preventDefault();
			close();
		}
	};
	document.addEventListener("keydown", onKey, true);

	let touch = null;
	stage.addEventListener("touchstart", event => {
		// documents scroll with the finger: no swiping there
		if (event.touches.length !== 1 || stage.lastElementChild?._zoomed?.() || event.target.closest(".ql-doc")) return;
		touch = { x: event.touches[0].clientX, y: event.touches[0].clientY, t: Date.now() };
	}, { passive: true });
	stage.addEventListener("touchmove", event => {
		if (!touch || event.touches.length !== 1) return;
		const dx = event.touches[0].clientX - touch.x;
		const dy = event.touches[0].clientY - touch.y;
		const media = stage.lastElementChild;
		if (Math.abs(dy) > Math.abs(dx) && dy > 0) {
			media.style.transform = `translateY(${dy}px) scale(${1 - Math.min(0.2, dy / 1600)})`;
			scrim.style.opacity = String(1 - Math.min(0.7, dy / 500));
		} else {
			media.style.transform = `translateX(${dx}px)`;
		}
	}, { passive: true });
	stage.addEventListener("touchend", event => {
		if (!touch) return;
		const t = event.changedTouches[0];
		const dx = t.clientX - touch.x;
		const dy = t.clientY - touch.y;
		const media = stage.lastElementChild;
		touch = null;
		media.style.transform = "";
		scrim.style.opacity = "";
		if (dy > 110 && Math.abs(dy) > Math.abs(dx)) close();
		else if (dx < -70) go(1);
		else if (dx > 70) go(-1);
	});
	scrim.addEventListener("click", () => close());
	stage.addEventListener("click", event => {
		if (event.target === stage) close();
	});

	let closed = false;
	async function close() {
		if (closed) return;
		closed = true;
		open = null;
		document.removeEventListener("keydown", onKey, true);
		root.style.pointerEvents = "none";
		const entry = list[i];
		const target = options.originEl?.(entry.path);
		const media = stage.lastElementChild;
		const flipEl = media?.querySelector?.("img, video, .ql-cover") || media;
		animate(scrim, [{ opacity: 1 }, { opacity: 0 }], { duration: DUR.long });
		root.classList.add("closing");
		animate(bar, [{ opacity: 1 }, { opacity: 0 }], { duration: DUR.short });
		animate(info, [{ opacity: 1 }, { opacity: 0 }], { duration: DUR.short });
		[prev, next].forEach(b => animate(b, [{ opacity: 1 }, { opacity: 0 }], { duration: DUR.short }));
		media?.querySelector?.(".ql-controls")?.remove();
		const rect = target?.getBoundingClientRect();
		if (rect && rect.width && flipEl && rect.bottom > 0 && rect.top < innerHeight) await flipTo(flipEl, rect, { duration: 340, easing: EASE.accel });
		else if (media) await animate(media, [{ opacity: 1, transform: "none" }, { opacity: 0, transform: "scale(0.92)" }], { duration: DUR.medium, easing: EASE.accel }).finished;
		cleanup();
		root.remove();
		document.body.classList.remove("ql-open");
		options.onClose?.(entry);
	}

	open = { close };
	show(0, options.origin);
	return open;
}

export function closeQuickLook() {
	open?.close();
}
