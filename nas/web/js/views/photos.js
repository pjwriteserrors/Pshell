// Photos: a timeline of justified rows by day with a scrubber along the
// side, the people the faces task found, and the places (a dot map of the
// world). A click opens Quick look; Ctrl/Shift pick for the file menu.
import { h, icon, clear, nameOf, parentOf, plural, toDate, throttleFrame, isMobile, size as fmtSize } from "../util.js";
import * as api from "../api.js";
import { stagger, animate, EASE, reduced } from "../motion.js";
import { segmented, showMenu, prompt, toast, errorToast, confirm } from "../ui.js";
import { thumbSrc, waitForThumb } from "../files.js";
import { openQuickLook } from "../quicklook.js";
import * as actions from "../actions.js";
import { WORLD } from "../world.js";

const monthFmt = new Intl.DateTimeFormat("en-GB", { month: "long", year: "numeric" });
const dayFmt = new Intl.DateTimeFormat("en-GB", { weekday: "short", day: "numeric", month: "long", year: "numeric" });

export default function photos(route, app) {
	let tab = route.query.tab || "timeline";
	const bar = h("div.photos-bar");
	const body = h("div.photos-body");
	const root = h("div.photos", bar, body);
	let current = null;

	const title = h("div.page-title", icon("image_multiple_outline"), h("span.ellipsis", "Photos"));
	const seg = segmented([
		{ value: "timeline", label: "Timeline", icon: "calendar_month" },
		{ value: "people", label: "People", icon: "account_multiple_outline" },
		{ value: "places", label: "Places", icon: "map_marker_outline" }
	], tab, value => {
		tab = value;
		route.query = { tab: value };
		history.replaceState(null, "", `#/photos?tab=${value}`);
		show();
	});
	const count = h("span.subtle.browse-count");
	const back = h("button.btn.small.ghost", { hidden: true }, icon("arrow_left"), "All photos");
	back.addEventListener("click", () => {
		route.query = { tab: "timeline" };
		history.replaceState(null, "", "#/photos");
		show();
	});
	bar.append(h("div.bar-left", back, count));

	function show() {
		current?.destroy?.();
		clear(body);
		back.hidden = !(route.query.person || route.query.place);
		seg.select(route.query.person || route.query.place ? "timeline" : tab);
		if (tab === "people" && !route.query.person) current = people();
		else if (tab === "places" && !route.query.place) current = places();
		else current = timeline({ person: route.query.person, place: route.query.place, name: route.query.name });
		body.appendChild(current.el);
		animate(current.el, [{ opacity: 0, transform: "translateY(8px)" }, { opacity: 1, transform: "none" }], { duration: 380, easing: EASE.spatial, fill: "none" });
	}

	// ── the timeline ─────────────────────────────────────────────────────
	function timeline(filter) {
		let list = [];
		let days = [];
		let done = false;
		let loading = false;
		let rows = []; // { type: "day"|"photos", y, h, ... }
		let placed = []; // per photo { x, y, w, h }
		let total = 0;
		const picked = new Set();
		const els = new Map();
		const canvas = h("div.photo-canvas");
		const scroll = h("div.photo-scroll", { tabindex: "0" }, canvas);
		const scrubber = h("div.scrubber", h("div.scrub-thumb"), h("div.scrub-bubble"));
		const el = h("div", { style: { display: "flex", flex: "1", minWidth: "0", position: "relative" } }, scroll, scrubber);
		const label = filter.person ? `Person` : filter.place ? filter.place : "";
		count.textContent = label;
		if (filter.person) api.get("/api/people", { min: 1 }, { quiet: true }).then(list => {
			const p = (list || []).find(x => String(x.id) === String(filter.person));
			if (p) count.textContent = p.name || "Someone without a name";
		}).catch(() => {});

		async function loadMore() {
			if (loading || done) return;
			loading = true;
			try {
				const before = list.length ? list[list.length - 1].taken : undefined;
				const batch = await api.get("/api/photos", { limit: 1200, before, person: filter.person, place: filter.place });
				if (!batch?.length || batch.length < 1200) done = true;
				list = list.concat(batch || []);
				relayout();
				paint(list.length === (batch || []).length);
				if (!filter.person && !filter.place) count.textContent = `${plural(list.length, "photo")}${done ? "" : "+"}`;
				else if (!count.textContent) count.textContent = plural(list.length, "photo");
				if (!list.length) {
					canvas.appendChild(h("div.empty", { style: { position: "absolute", inset: "0" } }, icon("image_multiple_outline"), h("h3", "No photos yet"), h("p", "The index reads the photo folders (Settings › Files) and their dates; the phone's uploads land in /Phone photos.")));
				}
			} catch (error) {
				clear(canvas).appendChild(h("div.empty", icon("alert_circle_outline"), h("h3", "Could not load the photos"), h("p", error.message)));
				done = true;
			} finally {
				loading = false;
			}
		}

		function dayKey(p) {
			const d = toDate(p.taken);
			return d ? d.toISOString().slice(0, 10) : "unknown";
		}

		function relayout() {
			const pad = isMobile() ? 8 : 18;
			const W = scroll.clientWidth - pad * 2;
			const target = isMobile() ? 110 : 190;
			const gap = 4;
			rows = [];
			placed = new Array(list.length);
			let y = 8;
			let i = 0;
			while (i < list.length) {
				const key = dayKey(list[i]);
				let j = i;
				while (j < list.length && dayKey(list[j]) === key) j += 1;
				const placesOfDay = [...new Set(list.slice(i, j).map(p => p.place).filter(Boolean))].slice(0, 3);
				rows.push({ type: "day", y, h: 44, key, count: j - i, date: toDate(list[i].taken), places: placesOfDay, start: i });
				y += 44;
				// justified rows inside the day
				let k = i;
				while (k < j) {
					let sum = 0;
					let end = k;
					while (end < j) {
						const p = list[end];
						const aspect = p.width && p.height ? Math.max(0.4, Math.min(3, p.width / p.height)) : 1.4;
						sum += aspect;
						end += 1;
						if ((W - gap * (end - k - 1)) / sum < target) break;
					}
					let rowH = (W - gap * (end - k - 1)) / sum;
					const last = end === j && rowH > target * 1.3;
					if (last) rowH = target;
					let x = pad;
					for (let m = k; m < end; m += 1) {
						const p = list[m];
						const aspect = p.width && p.height ? Math.max(0.4, Math.min(3, p.width / p.height)) : 1.4;
						const w = aspect * rowH;
						placed[m] = { x, y, w, h: rowH };
						x += w + gap;
					}
					rows.push({ type: "photos", y, h: rowH, start: k, end });
					y += rowH + gap;
					k = end;
				}
				y += 14;
				i = j;
			}
			total = y + 40;
			canvas.style.height = `${total}px`;
			drawScrubber();
		}

		const dayEls = new Map();
		function paint(first) {
			const top = scroll.scrollTop - 600;
			const bottom = scroll.scrollTop + scroll.clientHeight + 600;
			const want = new Set();
			const wantDays = new Set();
			const entering = [];
			for (const r of rows) {
				if (r.y + r.h < top || r.y > bottom) continue;
				if (r.type === "day") {
					wantDays.add(r.key);
					let d = dayEls.get(r.key);
					if (!d) {
						d = h("div.photo-day", h("span", r.date ? dayFmt.format(r.date) : "Without a date"), h("span.subtle", plural(r.count, "photo")), r.places.map(pl => h("span.place-tag", icon("map_marker_outline"), pl)));
						dayEls.set(r.key, d);
						canvas.appendChild(d);
					}
					d.style.top = `${r.y + 14}px`;
					continue;
				}
				for (let m = r.start; m < r.end; m += 1) {
					const p = list[m];
					want.add(p.path);
					let e = els.get(p.path);
					if (!e) {
						const img = h("img", { alt: "", loading: "lazy", decoding: "async", draggable: false });
						img.addEventListener("load", () => img.classList.add("loaded"));
						img.dataset.size = placed[m].h > 260 ? 1024 : 256;
						img.addEventListener("error", () => waitForThumb(img, p.path));
						img.src = thumbSrc(p, placed[m].h > 260 ? 1024 : 256);
						e = h("div.photo", { dataset: { path: p.path, index: m } }, img);
						e._p = p;
						els.set(p.path, e);
						canvas.appendChild(e);
						if (first) entering.push(e);
					}
					e.dataset.index = m;
					const pos = placed[m];
					Object.assign(e.style, { left: `${pos.x}px`, top: `${pos.y}px`, width: `${pos.w}px`, height: `${pos.h}px` });
					e.classList.toggle("selected", picked.has(p.path));
				}
			}
			for (const [k, e] of els) if (!want.has(k)) {
				e.remove();
				els.delete(k);
			}
			for (const [k, e] of dayEls) if (!wantDays.has(k)) {
				e.remove();
				dayEls.delete(k);
			}
			if (entering.length) stagger(entering.slice(0, 60), { step: 10, distance: 10, from: 0.94 });
			// near the end: more
			if (!done && scroll.scrollTop + scroll.clientHeight > total - 1500) loadMore();
			moveThumb();
		}

		// ── the scrubber: days spread by their counts ───────────────────
		function drawScrubber() {
			[...scrubber.querySelectorAll(".scrub-mark, .scrub-tick")].forEach(m => m.remove());
			const source = days.length ? days : [];
			const sum = source.reduce((s, d) => s + d.count, 0) || 1;
			let acc = 0;
			let lastYear = "";
			let lastMonth = "";
			const H = scrubber.clientHeight || 600;
			for (const d of source) {
				const frac = acc / sum;
				const year = d.day.slice(0, 4);
				const month = d.day.slice(0, 7);
				if (year !== lastYear) {
					scrubber.appendChild(h("div.scrub-mark", { style: { top: `${frac * H}px` } }, year));
					lastYear = year;
				} else if (month !== lastMonth && source.length > 6) {
					scrubber.appendChild(h("div.scrub-tick", { style: { top: `${frac * H}px`, width: "6px" } }));
				}
				lastMonth = month;
				acc += d.count;
			}
		}

		function fracOfDay(key) {
			const sum = days.reduce((s, d) => s + d.count, 0) || 1;
			let acc = 0;
			for (const d of days) {
				if (d.day <= key) return acc / sum;
				acc += d.count;
			}
			return 1;
		}

		function dayAtFrac(frac) {
			const sum = days.reduce((s, d) => s + d.count, 0) || 1;
			let acc = 0;
			for (const d of days) {
				if ((acc + d.count) / sum >= frac) return d;
				acc += d.count;
			}
			return days[days.length - 1];
		}

		const thumb = scrubber.querySelector(".scrub-thumb");
		const bubble = scrubber.querySelector(".scrub-bubble");
		function moveThumb() {
			if (!days.length) {
				const f = total > scroll.clientHeight ? scroll.scrollTop / (total - scroll.clientHeight) : 0;
				thumb.style.top = `${f * (scrubber.clientHeight - 3)}px`;
				return;
			}
			const top = rows.find(r => r.type === "day" && r.y + 200 >= scroll.scrollTop) || rows[rows.length - 1];
			if (!top) return;
			const f = fracOfDay(top.key);
			thumb.style.top = `${f * (scrubber.clientHeight - 3)}px`;
			bubble.style.top = thumb.style.top;
			bubble.textContent = top.date ? monthFmt.format(top.date) : "";
		}

		let dragging = false;
		const scrubTo = async (event, final) => {
			const rect = scrubber.getBoundingClientRect();
			const f = Math.max(0, Math.min(1, (event.clientY - rect.top) / rect.height));
			thumb.style.top = `${f * (rect.height - 3)}px`;
			bubble.style.top = thumb.style.top;
			if (!days.length) {
				scroll.scrollTop = f * (total - scroll.clientHeight);
				return;
			}
			const d = dayAtFrac(f);
			bubble.textContent = monthFmt.format(new Date(`${d.day}T12:00:00`));
			// jump: load until that day is there
			let row = rows.find(r => r.type === "day" && r.key <= d.day);
			while (!row && !done && final !== false) {
				await loadMore();
				row = rows.find(r => r.type === "day" && r.key <= d.day);
			}
			if (row) scroll.scrollTop = row.y;
		};
		scrubber.addEventListener("pointerdown", event => {
			dragging = true;
			scrubber.setPointerCapture(event.pointerId);
			scrubber.classList.add("active");
			scrubTo(event, false);
		});
		scrubber.addEventListener("pointermove", event => {
			if (!dragging) {
				const rect = scrubber.getBoundingClientRect();
				const f = Math.max(0, Math.min(1, (event.clientY - rect.top) / rect.height));
				const d = days.length ? dayAtFrac(f) : null;
				bubble.style.top = `${f * rect.height}px`;
				if (d) bubble.textContent = monthFmt.format(new Date(`${d.day}T12:00:00`));
				return;
			}
			scrubTo(event, false);
		});
		const endDrag = event => {
			if (!dragging) return;
			dragging = false;
			scrubber.classList.remove("active");
			scrubTo(event, true);
		};
		scrubber.addEventListener("pointerup", endDrag);
		scrubber.addEventListener("pointercancel", endDrag);

		// ── picking and opening ─────────────────────────────────────────
		const entryOf = p => ({ path: p.path, name: nameOf(p.path), kind: "image", dir: false, mtime: p.taken, size: p.size });
		let anchor = -1;
		canvas.addEventListener("click", event => {
			const e = event.target.closest(".photo");
			if (!e) return;
			const i = Number(e.dataset.index);
			if (event.ctrlKey || event.metaKey || (picked.size && isMobile())) {
				if (picked.has(e._p.path)) picked.delete(e._p.path);
				else picked.add(e._p.path);
				anchor = i;
				paint();
				count.textContent = picked.size ? `${picked.size} picked` : plural(list.length, "photo");
				return;
			}
			if (event.shiftKey && anchor >= 0) {
				const [a, b] = anchor < i ? [anchor, i] : [i, anchor];
				for (let k = a; k <= b; k += 1) picked.add(list[k].path);
				paint();
				count.textContent = `${picked.size} picked`;
				return;
			}
			const entries = list.map(entryOf);
			openQuickLook(entries, i, {
				origin: e.getBoundingClientRect(),
				originEl: path => canvas.querySelector(`.photo[data-path="${CSS.escape(path)}"]`),
				onIndex: entry => {
					const k = list.findIndex(p => p.path === entry.path);
					const pos = placed[k];
					if (pos && (pos.y < scroll.scrollTop || pos.y + pos.h > scroll.scrollTop + scroll.clientHeight)) scroll.scrollTop = pos.y - scroll.clientHeight / 3;
				},
				menu: (entry, x, y) => showMenu(actions.forRows({ rows: [entry], view: viewApi, folder: parentOf(entry.path), virtual: true }), x, y)
			});
		});
		canvas.addEventListener("contextmenu", event => {
			const e = event.target.closest(".photo");
			if (!e) return;
			event.preventDefault();
			if (!picked.has(e._p.path)) {
				picked.clear();
				picked.add(e._p.path);
				paint();
			}
			const rows2 = list.filter(p => picked.has(p.path)).map(entryOf);
			showMenu(actions.forRows({ rows: rows2, view: viewApi, folder: parentOf(rows2[0].path), virtual: true }), event.clientX, event.clientY);
		});
		let pressTimer = 0;
		canvas.addEventListener("touchstart", event => {
			const e = event.target.closest(".photo");
			if (!e) return;
			pressTimer = setTimeout(() => {
				picked.add(e._p.path);
				navigator.vibrate?.(12);
				paint();
				count.textContent = `${picked.size} picked`;
			}, 480);
		}, { passive: true });
		canvas.addEventListener("touchend", () => clearTimeout(pressTimer));
		canvas.addEventListener("touchmove", () => clearTimeout(pressTimer), { passive: true });

		const viewApi = {
			open: rows2 => rows2[0] && openQuickLook(rows2, 0),
			quickLook: entry => openQuickLook([entry], 0),
			rename: rows2 => actions.batchRename(rows2),
			reload: () => {
				list = [];
				done = false;
				clear(canvas);
				els.clear();
				dayEls.clear();
				loadMore();
			},
			selectAll: () => {
				list.forEach(p => picked.add(p.path));
				paint();
			},
			count: () => list.length,
			setView() {},
			details: entry => app.go(`#/files${parentOf(entry?.path || "/")}`)
		};

		scroll.addEventListener("scroll", throttleFrame(() => paint()), { passive: true });
		const ro = new ResizeObserver(throttleFrame(() => {
			relayout();
			paint();
		}));
		ro.observe(scroll);
		api.get("/api/photos/days", null, { quiet: true }).then(d => {
			days = filter.person || filter.place ? [] : d || [];
			drawScrubber();
		}).catch(() => {});
		loadMore();
		return {
			el,
			destroy: () => ro.disconnect(),
			key(event) {
				if (event.key === "Escape" && picked.size) {
					picked.clear();
					paint();
					count.textContent = plural(list.length, "photo");
				}
				if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "a") {
					event.preventDefault();
					viewApi.selectAll();
					count.textContent = `${picked.size} picked`;
				}
			}
		};
	}

	// ── people ───────────────────────────────────────────────────────────
	function people() {
		const grid = h("div.people-grid");
		const el = h("div.page-scroll", grid);
		const merging = new Set();
		const mergeBar = h("div.sticky-bar.panel-glass", { hidden: true, style: { margin: "0 24px 16px" } }, h("span.merge-text"), h("div.page-tools", h("button.btn.small.ghost", { onclick: () => {
			merging.clear();
			draw();
		} }, "Cancel"), h("button.btn.small.primary", { onclick: merge }, icon("call_merge"), "Merge")));
		el.appendChild(mergeBar);
		let list = [];
		count.textContent = "";
		const load = async () => {
			grid.replaceChildren(...[...Array(8)].map(() => h("div.person", h("div.face.skeleton"), h("div.skeleton", { style: { width: "80px", height: "14px" } }))));
			try {
				list = await api.get("/api/people");
				count.textContent = plural(list.length, "person", "people");
				draw(true);
			} catch (error) {
				grid.replaceChildren(h("div.empty", { style: { gridColumn: "1 / -1" } }, icon("alert_circle_outline"), h("h3", "No people"), h("p", error.message)));
			}
		};
		function draw(first) {
			clear(grid);
			if (!list.length) {
				grid.appendChild(h("div.empty", { style: { gridColumn: "1 / -1" } }, icon("face_recognition"), h("h3", "No faces found yet"), h("p", "The faces task looks at the photos (setting Faces); people show up here once someone is seen twice.")));
				return;
			}
			for (const p of list) {
				const face = h("div.face", icon("account_outline"));
				if (p.cover) faceImage(face, p);
				const person = h("div.person", { class: merging.has(p.id) ? "picked" : "" }, face, h(`div.person-name${p.name ? "" : ".unnamed"}`, p.name || "Add a name"), h("div.subtle", plural(p.count, "photo")));
				person.addEventListener("click", event => {
					if (merging.size || event.ctrlKey || event.metaKey) {
						if (merging.has(p.id)) merging.delete(p.id);
						else merging.add(p.id);
						draw();
						return;
					}
					route.query = { tab: "timeline", person: String(p.id) };
					history.replaceState(null, "", `#/photos?person=${p.id}`);
					tab = "timeline";
					show();
				});
				person.addEventListener("contextmenu", event => {
					event.preventDefault();
					showMenu([
						{ label: p.name ? "Rename…" : "Add a name…", icon: "form_textbox", run: () => rename(p) },
						{ label: "Merge with…", icon: "call_merge", run: () => {
							merging.add(p.id);
							draw();
							toast("Pick the others that are the same person", { icon: "call_merge" });
						} },
						{ label: "Show the photos", icon: "image_multiple_outline", run: () => person.click() }
					], event.clientX, event.clientY);
				});
				grid.appendChild(person);
			}
			mergeBar.hidden = merging.size < 1;
			mergeBar.querySelector(".merge-text").textContent = merging.size < 2 ? "Pick one more to merge" : `Merge ${merging.size} into one person`;
			if (first) stagger(grid.children, { step: 25, distance: 12, from: 0.85 });
		}
		async function rename(p) {
			const name = await prompt({ title: p.name ? "Rename" : "Who is this?", label: "Name", value: p.name || "", icon: "account_edit_outline", confirmLabel: "Save" });
			if (name === null) return;
			try {
				await api.put(`/api/people/${p.id}`, { name });
				p.name = name;
				draw();
			} catch (error) {
				errorToast(error);
			}
		}
		async function merge() {
			if (merging.size < 2) return;
			const ok = await confirm({ title: `Merge ${merging.size} people?`, body: "Their faces become one person; a name that is set is kept.", confirmLabel: "Merge", icon: "call_merge" });
			if (!ok) return;
			try {
				await api.post("/api/people/merge", { ids: [...merging] });
				merging.clear();
				toast("Merged", { icon: "call_merge", tone: "good" });
				load();
			} catch (error) {
				errorToast(error);
			}
		}
		load();
		return { el };
	}

	// a face cut out of its photo: box in pixels or 0..1
	async function faceImage(face, p) {
		const img = h("img", { alt: "", loading: "lazy" });
		img.src = thumbSrc({ path: p.cover }, 1024);
		img.style.opacity = "0";
		img.addEventListener("load", async () => {
			const box = p.box;
			if (Array.isArray(box) && box.length >= 4) {
				let [x, y, w, hh] = box;
				let W = 1;
				let H = 1;
				if (Math.max(x, y, w, hh) > 1.5) {
					try {
						const st = await api.get("/api/stat", { path: p.cover }, { quiet: true });
						W = st.width || img.naturalWidth;
						H = st.height || img.naturalHeight;
					} catch (error) {
						W = img.naturalWidth;
						H = img.naturalHeight;
					}
				}
				const cx = (x + w / 2) / W;
				const cy = (y + hh / 2) / H;
				const zoom = Math.min(4, Math.max(1, 0.55 / Math.max(w / W, hh / H)));
				img.style.transformOrigin = `${cx * 100}% ${cy * 100}%`;
				img.style.transform = `scale(${zoom})`;
				img.style.objectPosition = `${cx * 100}% ${cy * 100}%`;
			}
			face.querySelector(".i")?.remove();
			img.style.transition = "opacity 400ms";
			img.style.opacity = "1";
		});
		face.appendChild(img);
	}

	// ── places ───────────────────────────────────────────────────────────
	function places() {
		const map = h("div.world");
		const listEl = h("div.place-list");
		const el = h("div.page-scroll", h("div.places-wrap", map, listEl));
		count.textContent = "";
		(async () => {
			let list = [];
			try {
				list = await api.get("/api/places");
			} catch (error) {}
			count.textContent = plural(list.length, "place");
			const max = Math.max(1, ...list.map(p => p.count));
			const dots = list.filter(p => p.lat !== null && p.lon !== null).map((p, i) => {
				const x = ((p.lon + 180) / 360) * 360;
				const y = ((90 - p.lat) / 180) * 180;
				const r = 1.4 + 3.2 * Math.sqrt(p.count / max);
				return `<circle class="halo" cx="${x}" cy="${y}" r="${r}" style="animation-delay:${(i % 7) * 0.4}s"/><circle class="spot" data-i="${i}" cx="${x}" cy="${y}" r="${r}" style="animation-delay:${200 + i * 30}ms"><title>${escapeXml(p.place)} · ${p.count}</title></circle>`;
			}).join("");
			const grid = [];
			for (let lon = -150; lon <= 150; lon += 30) grid.push(`<line class="grid-line" x1="${lon + 180}" y1="0" x2="${lon + 180}" y2="180"/>`);
			for (let lat = -60; lat <= 60; lat += 30) grid.push(`<line class="grid-line" x1="0" y1="${90 - lat}" x2="360" y2="${90 - lat}"/>`);
			map.innerHTML = `<svg viewBox="0 0 360 180" preserveAspectRatio="xMidYMid meet">${grid.join("")}<path class="land" d="${WORLD}"/>${dots}</svg>`;
			const shown = list.filter(p => p.lat !== null && p.lon !== null);
			map.querySelectorAll(".spot").forEach(s => s.addEventListener("click", () => openPlace(shown[Number(s.dataset.i)])));
			if (!list.length) {
				listEl.appendChild(h("div.empty", { style: { gridColumn: "1 / -1" } }, icon("map_marker_outline"), h("h3", "No places yet"), h("p", "Photos with GPS data get their place from an offline list of towns.")));
				return;
			}
			for (const p of list) {
				const chip = h("div.place-chip", icon("map_marker_outline"), h("div.row-main", h("div.row-title.ellipsis", p.place), h("div.row-sub", [p.country, plural(p.count, "photo")].filter(Boolean).join(" · "))));
				chip.addEventListener("click", () => openPlace(p));
				listEl.appendChild(chip);
			}
			stagger(listEl.children, { step: 20, distance: 10 });
		})();
		function openPlace(p) {
			route.query = { tab: "timeline", place: p.place };
			history.replaceState(null, "", `#/photos?place=${encodeURIComponent(p.place)}`);
			tab = "timeline";
			show();
		}
		return { el };
	}

	show();
	return {
		el: root,
		titleEl: title,
		toolsEl: seg,
		title: "Photos",
		icon: "image_multiple_outline",
		onKey: event => current?.key?.(event),
		update(next) {
			route = next;
			tab = next.query.tab || (next.query.person || next.query.place ? "timeline" : "timeline");
			show();
		},
		unmount: () => current?.destroy?.()
	};
}

function escapeXml(s) {
	return String(s).replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
}
