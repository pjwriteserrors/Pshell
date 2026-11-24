// Watches (docs/browser.md "Watches"): what the shell asks of a page for
// pshell-core's watches, beside background/bridge.js (same scope: COMMANDS,
// toShell, inTab, scriptable, activeTab, config).
//
// commands:  watchPick {tabId, mode: element|price}  the picker (content/watch.js);
//                                                     its answer comes as the event `watchPicked`
//            product {tabId}  → {url, title, price, currency, image}   the page's schema.org data
//            parcels {tabId}  → {numbers: [{number, carrier, name, hint}]}
// events:    watchPicked {mode, url, title, selector, attr, value, price, currency}
//            parcels {numbers, page, title}   an order page shows tracking numbers
//                                             (config.parcels; never a private window)

// what a product page says of itself (JSON-LD, microdata, product:price metas)
function readProduct() {
	const number = value => {
		if (typeof value === "number") return value;
		let raw = String(value || "").replace(/[^\d.,]/g, "");
		if (!raw) return null;
		if (raw.includes(",") && raw.includes(".")) raw = raw.lastIndexOf(",") > raw.lastIndexOf(".") ? raw.replace(/\./g, "").replace(",", ".") : raw.replace(/,/g, "");
		else if (raw.includes(",")) raw = /,\d{3}$/.test(raw) ? raw.replace(/,/g, "") : raw.replace(",", ".");
		const n = Number(raw);
		return isFinite(n) ? n : null;
	};
	const out = { url: location.href, title: "", price: null, currency: "", image: "" };
	const isA = (thing, kind) => [].concat(thing["@type"] || []).some(t => String(t).split("/").pop() === kind);
	const offer = offers => {
		for (const o of [].concat(offers || [])) {
			if (!o || typeof o !== "object") continue;
			for (const key of ["price", "lowPrice"]) {
				const n = number(o[key]);
				if (n !== null) return [n, o.priceCurrency || ""];
			}
			const inner = offer(o.priceSpecification || o.offers);
			if (inner) return inner;
		}
		return null;
	};
	const walk = (data, depth) => {
		if (depth > 8 || !data) return;
		if (Array.isArray(data)) return data.forEach(item => walk(item, depth + 1));
		if (typeof data !== "object") return;
		if (isA(data, "Product") || isA(data, "ProductGroup")) {
			out.title = out.title || String(data.name || "");
			const image = [].concat(data.image || [])[0];
			out.image = out.image || String((image && (image.url || image)) || "");
			const found = offer(data.offers);
			if (found && out.price === null) [out.price, out.currency] = found;
		}
		for (const key of ["@graph", "mainEntity", "itemListElement", "item", "hasVariant"]) walk(data[key], depth + 1);
	};
	for (const script of document.querySelectorAll('script[type*="ld+json"]')) {
		try {
			walk(JSON.parse(script.textContent), 0);
		} catch (error) {}
	}
	if (out.price === null) {
		const el = document.querySelector('[itemprop="price"]');
		if (el) {
			out.price = number(el.getAttribute("content") || el.textContent);
			out.currency = document.querySelector('[itemprop="priceCurrency"]')?.getAttribute("content") || "";
		}
	}
	if (out.price === null) {
		const meta = document.querySelector('meta[property="product:price:amount"], meta[property="og:price:amount"]');
		if (meta) {
			out.price = number(meta.content);
			out.currency = document.querySelector('meta[property="product:price:currency"], meta[property="og:price:currency"]')?.content || "";
		}
	}
	out.title = out.title || document.querySelector('meta[property="og:title"]')?.content || document.title;
	out.image = out.image || document.querySelector('meta[property="og:image"]')?.content || "";
	return out;
}

// tracking numbers a page shows: from carriers' tracking links, and from
// text near words like "Sendungsnummer" or a carrier's name
function scanParcels() {
	const carriers = { dhl: /dhl/i, dpd: /dpd/i, hermes: /hermes/i, gls: /\bgls\b|gls-pakete|gls-group/i, ups: /\bups\b|ups\.com/i };
	const names = { dhl: "DHL", dpd: "DPD", hermes: "Hermes", gls: "GLS", ups: "UPS" };
	const fits = {
		ups: n => /^1Z[0-9A-Z]{16}$/.test(n),
		hermes: n => /^(H\d{19}|\d{14}|\d{16})$/.test(n),
		dhl: n => /^((JJD|JVGL)\d{10,22}|\d{12}|\d{20}|00340\d{15}|[A-Z]{2}\d{9}DE)$/.test(n),
		dpd: n => /^\d{14}$/.test(n),
		gls: n => /^(\d{11,12}|[A-Z0-9]{8})$/.test(n)
	};
	const strong = n => /^(1Z[0-9A-Z]{16}|(JJD|JVGL)\d{10,22}|00340\d{15}|H\d{19})$/.test(n);
	const found = new Map();
	const add = (number, carrier, hint) => {
		const n = String(number).replace(/[\s-]/g, "").toUpperCase();
		if (n.length < 8 || n.length > 35 || found.has(n)) return;
		if (carrier && fits[carrier] && !fits[carrier](n)) return;
		found.set(n, { number: n, carrier: carrier || "", name: names[carrier] || "", hint: String(hint || "").slice(0, 120) });
	};
	const carrierIn = text => Object.keys(carriers).find(key => carriers[key].test(text)) || "";
	// links to the carriers' tracking pages
	for (const a of document.querySelectorAll("a[href]")) {
		let url;
		try {
			url = new URL(a.href);
		} catch (error) {
			continue;
		}
		const carrier = carrierIn(url.hostname);
		if (!carrier) continue;
		const params = ["piececode", "idc", "tracknum", "trackingNumber", "tracking", "match", "parcelNumber", "shipmentNumber", "query", "id"];
		let number = params.map(p => url.searchParams.get(p)).find(v => v && /^[A-Z0-9]{8,35}$/i.test(v.replace(/[\s-]/g, "")));
		if (!number) number = (url.pathname + url.hash).match(/(?:parcel|sendung|tracking|track|sendungsinformation)[\/#=]+([A-Z0-9]{8,35})/i)?.[1];
		if (number) add(number, carrier, a.textContent);
	}
	// numbers in text near the words
	const text = String(document.body?.innerText || "").slice(0, 200000);
	const words = /sendungs?nummer|sendungs?-?nr|paketnummer|tracking|trackingnummer|sendungsverfolgung|shipment|track(ing)? (number|id)|lieferung|versand|parcel/i;
	const re = /\b(1Z[0-9A-Z]{16}|(?:JJD|JVGL)\d{10,22}|H\d{19}|[A-Z]{2}\d{9}DE|\d{11,20})\b/g;
	for (const m of text.matchAll(re)) {
		const around = text.slice(Math.max(0, m.index - 120), m.index + m[0].length + 60);
		const carrier = carrierIn(around);
		if (strong(m[1]) || (words.test(around) && carrier)) add(m[1], carrier, around.replace(/\s+/g, " "));
	}
	return { numbers: [...found.values()].slice(0, 6) };
}

async function tabFor(message) {
	const tab = message.tabId >= 0 ? await browser.tabs.get(message.tabId) : await activeTab();
	if (!scriptable(tab)) throw new Error("no page");
	return tab;
}

Object.assign(COMMANDS, {
	async watchPick(message) {
		const tab = await tabFor(message);
		await browser.scripting.executeScript({ target: { tabId: tab.id }, func: mode => {
			window.__pshellWatchMode = mode;
		}, args: [message.mode === "price" ? "price" : "element"] });
		await browser.scripting.executeScript({ target: { tabId: tab.id }, files: ["content/watch.js"] });
		if (!tab.active) await browser.tabs.update(tab.id, { active: true });
		return true;
	},
	async product(message) {
		return await inTab((await tabFor(message)).id, readProduct);
	},
	async parcels(message) {
		return await inTab((await tabFor(message)).id, scanParcels);
	}
});

browser.runtime.onMessage.addListener((message, sender) => {
	if (!message || message.pshell !== "watchPicked") return;
	const tab = sender.tab;
	if (!tab || tab.incognito) return Promise.resolve(false);
	const { pshell, ...picked } = message;
	toShell(Object.assign({ type: "event", name: "watchPicked" }, picked, { tabId: tab.id }));
	return Promise.resolve(true);
});

// order pages, read once per address when the shell wants it
const ORDER_PAGE = /order|bestell|sendung|versand|track|shipment|lieferung|delivery|paket|parcel|kaufhistorie|purchase/i;
const scanned = new Set();
browser.tabs.onUpdated.addListener(async (id, change, tab) => {
	if (change.status !== "complete" || !config.parcels || !bridge.connected || tab.incognito || !scriptable(tab)) return;
	if (!ORDER_PAGE.test(`${tab.url} ${tab.title || ""}`) || scanned.has(tab.url)) return;
	scanned.add(tab.url);
	if (scanned.size > 500) scanned.delete(scanned.values().next().value);
	try {
		const result = await inTab(id, scanParcels);
		if (result && result.numbers && result.numbers.length) toShell({ type: "event", name: "parcels", numbers: result.numbers, page: tab.url, title: tab.title || "" });
	} catch (error) {}
});
