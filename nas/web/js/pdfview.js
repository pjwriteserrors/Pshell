// PDFs shown by the page itself (pdf.js), never left to the browser – some
// save PDFs instead of showing them, many phones have no viewer at all. The
// file streams in with Range requests: page 1 is there long before a 70 MB
// book has arrived. Pages lie in a column like the shell's PDF viewer; only
// the ones on screen are drawn, each with a text layer to select and find.
import { h, icon, clear } from "./util.js";
import { animate, EASE } from "./motion.js";

let lib = null;
async function pdfjs() {
	if (lib) return lib;
	lib = await import("../vendor/pdfjs/pdf.min.mjs");
	lib.GlobalWorkerOptions.workerSrc = new URL("../vendor/pdfjs/pdf.worker.min.mjs", import.meta.url).href;
	return lib;
}

export function pdfView(url, { name = "", headers } = {}) {
	const column = h("div.pdf-column");
	const scroller = h("div.pdf-scroll", { tabindex: "0" }, column);
	const pageInput = h("input.pdf-page-input", { inputmode: "numeric", value: "1", "aria-label": "Page" });
	const count = h("span.pdf-count", "/ …");
	const zoomText = h("span.pdf-zoom-text", "Fit");
	const find = h("input.pdf-find", { placeholder: "Find", spellcheck: false });
	const findInfo = h("span.pdf-find-info");
	const btn = (iconName, title, run) => {
		const b = h("button.icon-btn.small", { type: "button", title }, icon(iconName));
		b.addEventListener("click", event => {
			event.stopPropagation();
			run();
		});
		return b;
	};
	const status = h("div.pdf-status", h("div.spinner"), h("span", "Opening…"));
	const bar = h("div.pdf-bar",
		btn("chevron_up", "Previous page", () => goTo(current - 1)),
		h("label.pdf-pages", pageInput, count),
		btn("chevron_down", "Next page", () => goTo(current + 1)),
		h("span.pdf-sep"),
		btn("magnify_minus_outline", "Smaller (−)", () => setZoom(scaleNow() / 1.2)),
		h("button.btn.small.ghost.pdf-fit", { type: "button", title: "Fit the width", onclick: event => {
			event.stopPropagation();
			setZoom("fit");
		} }, zoomText),
		btn("magnify_plus_outline", "Bigger (+)", () => setZoom(scaleNow() * 1.2)),
		h("span.pdf-sep.hide-mobile"),
		h("label.pdf-find-box.hide-mobile", icon("magnify"), find, findInfo));
	const el = h("div.pdf-view", scroller, bar, status);

	let doc = null;
	let task = null;
	let destroyed = false;
	let zoom = "fit";
	let base = { width: 612, height: 792 };
	let current = 1;
	const pages = []; // { el, canvas, text, drawn, task, size }
	const sizes = new Map();

	// the width of the column, but not wider than a page reads well
	const fitScale = () => Math.max(0.2, Math.min(scroller.clientWidth - 32, 1000) / base.width);
	const scaleNow = () => (zoom === "fit" ? fitScale() : zoom);

	function layout() {
		const s = scaleNow();
		for (const p of pages) {
			const size = sizes.get(p.n) || base;
			p.el.style.width = `${Math.floor(size.width * s)}px`;
			p.el.style.height = `${Math.floor(size.height * s)}px`;
			if (p.drawnAt && Math.abs(p.drawnAt - s) > 0.01) undraw(p);
		}
		zoomText.textContent = zoom === "fit" ? "Fit" : `${Math.round(s * 100)} %`;
		requestAnimationFrame(checkVisible);
	}

	function setZoom(next) {
		const before = scroller.scrollTop / Math.max(1, scroller.scrollHeight);
		zoom = next === "fit" ? "fit" : Math.max(0.25, Math.min(5, next));
		layout();
		scroller.scrollTop = before * scroller.scrollHeight;
	}

	function goTo(n, smooth = true) {
		if (!doc) return;
		n = Math.max(1, Math.min(doc.numPages, n));
		const far = Math.abs(pages[n - 1].el.offsetTop - scroller.scrollTop) > scroller.clientHeight * 4;
		scroller.scrollTo({ top: pages[n - 1].el.offsetTop - 12, behavior: smooth && !far ? "smooth" : "auto" });
		setCurrent(n);
	}

	function setCurrent(n) {
		current = n;
		if (document.activeElement !== pageInput) pageInput.value = String(n);
	}

	function undraw(p) {
		p.task?.cancel?.();
		p.task = null;
		p.drawnAt = 0;
		clear(p.el);
		p.el.classList.remove("drawn");
	}

	async function draw(p) {
		const s = scaleNow();
		if (p.drawnAt === s || p.busy) return;
		p.busy = true;
		try {
			const page = await doc.getPage(p.n);
			if (destroyed) return;
			const vp1 = page.getViewport({ scale: 1 });
			if (!sizes.has(p.n) || sizes.get(p.n).width !== vp1.width) {
				sizes.set(p.n, { width: vp1.width, height: vp1.height });
				p.el.style.width = `${Math.floor(vp1.width * s)}px`;
				p.el.style.height = `${Math.floor(vp1.height * s)}px`;
			}
			const vp = page.getViewport({ scale: s });
			const ratio = Math.min(window.devicePixelRatio || 1, 2);
			const canvas = h("canvas.pdf-canvas");
			canvas.width = Math.floor(vp.width * ratio);
			canvas.height = Math.floor(vp.height * ratio);
			canvas.style.width = `${Math.floor(vp.width)}px`;
			canvas.style.height = `${Math.floor(vp.height)}px`;
			const ctx = canvas.getContext("2d");
			p.task = page.render({ canvasContext: ctx, viewport: vp, transform: ratio !== 1 ? [ratio, 0, 0, ratio, 0, 0] : null });
			await p.task.promise;
			if (destroyed) return;
			clear(p.el).appendChild(canvas);
			// the words, invisible, over the picture: select, copy, find
			try {
				const textDiv = h("div.textLayer");
				textDiv.style.setProperty("--scale-factor", String(s));
				p.el.appendChild(textDiv);
				const layer = new lib.TextLayer({ textContentSource: page.streamTextContent(), container: textDiv, viewport: vp });
				await layer.render();
			} catch (error) {}
			p.drawnAt = s;
			if (!p.el.classList.contains("drawn")) {
				p.el.classList.add("drawn");
				animate(canvas, [{ opacity: 0 }, { opacity: 1 }], { duration: 220, fill: "none" });
			}
		} catch (error) {
			if (error?.name !== "RenderingCancelledException") console.warn("pdf page", p.n, error);
		} finally {
			p.busy = false;
		}
	}

	// only what is on screen (and a page around it) is drawn; far pages let go
	function checkVisible() {
		if (!doc) return;
		const top = scroller.scrollTop;
		const bottom = top + scroller.clientHeight;
		let best = current;
		let bestArea = -1;
		for (const p of pages) {
			const y = p.el.offsetTop;
			const hgt = p.el.offsetHeight;
			const near = y + hgt > top - scroller.clientHeight && y < bottom + scroller.clientHeight;
			if (near) draw(p);
			else if (p.drawnAt && (y + hgt < top - 4 * scroller.clientHeight || y > bottom + 4 * scroller.clientHeight)) undraw(p);
			const area = Math.min(bottom, y + hgt) - Math.max(top, y);
			if (area > bestArea) {
				bestArea = area;
				best = p.n;
			}
		}
		setCurrent(best);
	}

	let ticking = false;
	scroller.addEventListener("scroll", () => {
		if (ticking) return;
		ticking = true;
		requestAnimationFrame(() => {
			ticking = false;
			checkVisible();
		});
	}, { passive: true });
	const resize = new ResizeObserver(() => zoom === "fit" && doc && layout());
	resize.observe(scroller);

	pageInput.addEventListener("keydown", event => {
		event.stopPropagation();
		if (event.key === "Enter") {
			goTo(Number(pageInput.value) || 1);
			scroller.focus({ preventScroll: true });
		}
	});
	pageInput.addEventListener("click", event => event.stopPropagation());

	// find: the next page whose text holds it
	let findFrom = 0;
	find.addEventListener("click", event => event.stopPropagation());
	find.addEventListener("keydown", async event => {
		event.stopPropagation();
		if (event.key === "Escape") {
			find.value = "";
			findInfo.textContent = "";
			scroller.focus({ preventScroll: true });
			return;
		}
		if (event.key !== "Enter" || !doc) return;
		const q = find.value.trim().toLowerCase();
		if (!q) return;
		findInfo.textContent = "…";
		for (let k = 0; k < doc.numPages; k += 1) {
			const n = ((findFrom + k) % doc.numPages) + 1;
			const page = await doc.getPage(n);
			const text = (await page.getTextContent()).items.map(i => i.str).join(" ").toLowerCase();
			if (text.includes(q)) {
				findFrom = n;
				findInfo.textContent = `p. ${n}`;
				goTo(n);
				setTimeout(() => {
					for (const span of pages[n - 1].el.querySelectorAll(".textLayer span")) {
						if (span.textContent.toLowerCase().includes(q)) {
							span.classList.add("pdf-hit");
							scroller.scrollTo({ top: pages[n - 1].el.offsetTop + span.offsetTop - scroller.clientHeight / 2 });
							break;
						}
					}
				}, 700);
				return;
			}
		}
		findInfo.textContent = "not found";
	});

	(async () => {
		try {
			const pdf = await pdfjs();
			task = pdf.getDocument({
				url,
				httpHeaders: headers,
				withCredentials: true,
				rangeChunkSize: 512 * 1024,
				disableAutoFetch: true,
				disableStream: true,
				isEvalSupported: false
			});
			task.onPassword = (update, reason) => {
				const pw = prompt(reason === 2 ? "Wrong password – try again" : `“${name}” is locked. Its password:`);
				if (pw === null) {
					status.querySelector("span").textContent = "Locked with a password";
					status.querySelector(".spinner")?.remove();
					return;
				}
				update(pw);
			};
			doc = await task.promise;
			if (destroyed) return;
			const first = await doc.getPage(1);
			const vp = first.getViewport({ scale: 1 });
			base = { width: vp.width, height: vp.height };
			sizes.set(1, base);
			count.textContent = `/ ${doc.numPages}`;
			for (let n = 1; n <= doc.numPages; n += 1) {
				const pageEl = h("div.pdf-page", { dataset: { n } });
				pages.push({ n, el: pageEl, drawnAt: 0 });
				column.appendChild(pageEl);
			}
			status.remove();
			layout();
		} catch (error) {
			if (destroyed) return;
			status.querySelector(".spinner")?.remove();
			status.querySelector("span").textContent = `This PDF does not open here: ${error.message || error}`;
		}
	})();

	return {
		el,
		key(event) {
			const k = event.key;
			if (k === "PageDown" || (k === "ArrowDown" && event.ctrlKey)) goTo(current + 1);
			else if (k === "PageUp" || (k === "ArrowUp" && event.ctrlKey)) goTo(current - 1);
			else if (k === "+" || k === "=") setZoom(scaleNow() * 1.2);
			else if (k === "-") setZoom(scaleNow() / 1.2);
			else if (k === "0") setZoom("fit");
			else if (k === "Home") goTo(1, false);
			else if (k === "End") goTo(doc?.numPages || 1, false);
			else if (k === "f" && (event.ctrlKey || event.metaKey)) find.focus();
			else return false;
			return true;
		},
		cleanup() {
			destroyed = true;
			resize.disconnect();
			pages.forEach(p => p.task?.cancel?.());
			task?.destroy?.();
		}
	};
}
