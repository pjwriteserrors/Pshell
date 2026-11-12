// Page styles: Stylus done the shell's way (docs/browser.md, "Page styles").
//
// A style is { id, name, on, sites: [pattern], css, updated }, all of them in
// storage "styles". A pattern is a host (also its subdomains), a host with *
// ("*.example.*"), a URL prefix ("https://example.com/app") or a regular
// expression "/…/" against the whole URL; no pattern means every page.
//
// What matches a frame goes in as a user sheet (tabs.insertCSS, so no page's
// CSP stops it), every declaration made !important: a user's !important wins
// over anything a page says, inline styles included. In front of it the
// shell's colours as custom properties (--pshell-bg, --pshell-primary, …),
// read from the theme the shell sends (background/bridge.js), so a style
// written with them follows every change of colours.
//
// The editor (content/styler.js) is put into a page on demand: the menu entry
// "Restyle page", the toolbar popup or Alt+Shift+S (experiments/parts/keys.js).

const ROLES = [
	["bg", "Background", "frame"],
	["layer1", "Layer 1", "toolbar_field"],
	["layer2", "Layer 2", "tab_selected"],
	["layer3", "Layer 3", "button_background_active"],
	["fg", "Text", "tab_background_text"],
	["muted", "Muted text", null],
	["subtle", "Subtle text", null],
	["outline", "Outline", "popup_border"],
	["primary", "Primary", "icons_attention"],
	["on-primary", "On primary", "popup_highlight_text"],
	["primary-container", "Primary container", null],
	["primary-soft", "Primary soft", "popup_highlight"],
	["secondary", "Secondary", "tab_line"],
	["tertiary", "Tertiary", "toolbar_bottom_separator"],
	["danger", "Danger", "tab_background_separator"],
	["warning", "Warning", "toolbar_vertical_separator"],
	["success", "Success", "toolbar_top_separator"]
];

const FALLBACK = {
	frame: "rgb(20, 20, 20)", toolbar_field: "rgb(31, 31, 31)", tab_selected: "rgb(40, 40, 40)",
	button_background_active: "rgb(50, 50, 50)", tab_background_text: "rgb(230, 230, 230)",
	popup_border: "rgba(230, 230, 230, 0.08)", icons_attention: "rgb(138, 180, 248)",
	popup_highlight_text: "rgb(20, 20, 20)", popup_highlight: "rgba(138, 180, 248, 0.14)",
	tab_line: "rgb(197, 138, 249)", toolbar_bottom_separator: "rgb(120, 220, 200)",
	tab_background_separator: "rgb(229, 72, 77)", toolbar_vertical_separator: "rgb(245, 165, 36)",
	toolbar_top_separator: "rgb(70, 167, 88)"
};

const DERIVED = {
	muted: "color-mix(in srgb, var(--pshell-fg) 64%, transparent)",
	subtle: "color-mix(in srgb, var(--pshell-fg) 42%, transparent)",
	"primary-container": "color-mix(in srgb, var(--pshell-primary) 20%, var(--pshell-bg))"
};

let styles = [];
let themeColors = {};
let themeDark = true;
let measures = {}; // the shell's radii and gap (config "measures", background/bridge.js)
let varsCss = "";
let learned = {}; // learning below
const frames = new Map(); // "tab:frame" → url
const applied = new Map(); // "tab:frame" → code inserted
const suspended = new Set(); // tab ids shown without their styles (Auto, compare)
const compiled = new Map(); // css → css with every declaration !important
const removed = new Set(); // ids deleted while the browser runs

function paletteOf() {
	return ROLES.map(([name, label, key]) => ({
		name,
		label,
		variable: `--pshell-${name}`,
		value: key ? themeColors[key] || FALLBACK[key] : DERIVED[name]
	}));
}

function buildVars() {
	const lines = paletteOf().map(role => `\t${role.variable}: ${role.value};`);
	const px = (value, fallback) => `${Number.isFinite(Number(value)) ? Number(value) : fallback}px`;
	lines.push(
		`\t--pshell-radius: ${px(measures.radius, 14)};`,
		`\t--pshell-radius-small: ${px(measures.radiusSmall, 6)};`,
		`\t--pshell-radius-medium: ${px(measures.radiusMedium, 10)};`,
		`\t--pshell-radius-large: ${px(measures.radiusLarge, 16)};`,
		`\t--pshell-gap: ${px(measures.gap, 8)};`
	);
	varsCss = `:root {\n${lines.join("\n")}\n\t--pshell-dark: ${themeDark ? 1 : 0};\n}\n`;
}

// ── matching ─────────────────────────────────────────────────────────────────
function globRegExp(pattern) {
	return new RegExp(`^${pattern.split("*").map(part => part.replace(/[.+?^${}()|[\]\\]/g, "\\$&")).join(".*")}$`, "i");
}

function patternMatches(pattern, url, host) {
	pattern = String(pattern || "").trim();
	if (!pattern) return false;
	if (pattern.length > 2 && pattern.startsWith("/") && pattern.endsWith("/")) {
		try {
			return new RegExp(`^(?:${pattern.slice(1, -1)})$`, "i").test(url);
		} catch (error) {
			return false;
		}
	}
	if (/^[a-z][a-z0-9+.-]*:/i.test(pattern)) return url.startsWith(pattern);
	if (pattern.includes("*")) return globRegExp(pattern).test(host);
	const plain = pattern.toLowerCase().replace(/^www\./, "");
	return host === plain || host.endsWith(`.${plain}`);
}

function styleMatches(style, url) {
	const sites = (style.sites || []).filter(site => String(site).trim());
	if (sites.length === 0) return true;
	let host = "";
	try {
		host = new URL(url).hostname.toLowerCase();
	} catch (error) {}
	return sites.some(site => patternMatches(site, url, host));
}

function stylable(url) {
	return /^(https?|file):/.test(url || "");
}

// ── the sheet that goes in ───────────────────────────────────────────────────
// declarations split on ";" outside strings and brackets (cssText from the
// CSSOM, so without comments)
function splitDeclarations(text) {
	const parts = [];
	let depth = 0;
	let quote = "";
	let start = 0;
	for (let i = 0; i < text.length; i++) {
		const c = text[i];
		if (quote) {
			if (c === "\\") i++;
			else if (c === quote) quote = "";
		} else if (c === "\"" || c === "'") quote = c;
		else if (c === "(" || c === "[") depth++;
		else if (c === ")" || c === "]") depth--;
		else if (c === ";" && depth === 0) {
			parts.push(text.slice(start, i));
			start = i + 1;
		}
	}
	parts.push(text.slice(start));
	return parts.map(part => part.trim()).filter(Boolean);
}

function important(css) {
	if (compiled.has(css)) return compiled.get(css);
	let out = css;
	try {
		const sheet = new CSSStyleSheet();
		sheet.replaceSync(css);
		const walk = rules => {
			for (const rule of rules) {
				if (rule.selectorText !== undefined && rule.style) {
					const text = splitDeclarations(rule.style.cssText)
						.map(declaration => /!\s*important$/i.test(declaration) ? declaration : `${declaration} !important`)
						.join("; ");
					rule.style.cssText = text;
				}
				if (rule.cssRules) walk(rule.cssRules);
			}
		};
		walk(sheet.cssRules);
		out = [...sheet.cssRules].map(rule => rule.cssText).join("\n");
	} catch (error) {}
	compiled.set(css, out);
	if (compiled.size > 200) compiled.delete(compiled.keys().next().value);
	return out;
}

function codeFor(url) {
	const parts = styles.filter(style => style.on !== false && style.css && styleMatches(style, url))
		.map(style => `/* ${String(style.name || "").replace(/\*\//g, "")} */\n${important(style.css)}`);
	return parts.length ? `${varsCss}${parts.join("\n")}\n` : "";
}

// one frame's sheet changes one after the other: two at once (Auto clicked
// quickly) could put an older sheet in after a newer one, out of reach then
const chains = new Map(); // "tab:frame" → the change under way
const generation = new Map(); // "tab:frame" → documents seen (a new one has no sheet)

function applyFrame(key) {
	const run = (chains.get(key) || Promise.resolve()).then(() => applyFrameNow(key));
	chains.set(key, run.catch(() => {}));
	return run;
}

async function applyFrameNow(key) {
	const gen = generation.get(key) || 0;
	const url = frames.get(key);
	const [tabId, frameId] = key.split(":").map(Number);
	const code = url && !suspended.has(tabId) && stylable(url) ? codeFor(url) : "";
	const before = applied.get(key) || "";
	if (before === code) return;
	if (code) applied.set(key, code);
	else applied.delete(key);
	if (before) await browser.tabs.removeCSS(tabId, { code: before, frameId, cssOrigin: "user" }).catch(() => {});
	// the frame went on to another document meanwhile: that one starts afresh
	if ((generation.get(key) || 0) !== gen) return;
	if (code) {
		await browser.tabs.insertCSS(tabId, { code, frameId, cssOrigin: "user", runAt: "document_start" }).catch(() => {
			if (applied.get(key) === code) applied.delete(key);
		});
	}
}

let reapplyDue = null;
function reapplyAll() {
	clearTimeout(reapplyDue);
	reapplyDue = setTimeout(() => {
		for (const key of frames.keys()) applyFrame(key);
	}, 30);
}

// a new document has none of what went into the one before
browser.webNavigation.onCommitted.addListener(details => {
	const key = `${details.tabId}:${details.frameId}`;
	if (details.frameId === 0) {
		for (const other of [...frames.keys()]) if (other.startsWith(`${details.tabId}:`)) {
			frames.delete(other);
			applied.delete(other);
			generation.set(other, (generation.get(other) || 0) + 1);
		}
	}
	applied.delete(key);
	generation.set(key, (generation.get(key) || 0) + 1);
	frames.set(key, details.url);
	applyFrame(key);
});

// a page that changes its address itself (history API)
for (const event of [browser.webNavigation.onHistoryStateUpdated, browser.webNavigation.onReferenceFragmentUpdated]) {
	event.addListener(details => {
		const key = `${details.tabId}:${details.frameId}`;
		frames.set(key, details.url);
		applyFrame(key);
	});
}

browser.tabs.onRemoved.addListener(tabId => {
	suspended.delete(tabId);
	for (const timer of followDue.get(tabId) || []) clearTimeout(timer);
	followDue.delete(tabId);
	for (const key of [...frames.keys()]) if (key.startsWith(`${tabId}:`)) {
		frames.delete(key);
		applied.delete(key);
	}
});

async function scanFrames() {
	for (const tab of await browser.tabs.query({})) {
		if (tab.discarded) continue;
		try {
			for (const frame of await browser.webNavigation.getAllFrames({ tabId: tab.id }) || []) {
				frames.set(`${tab.id}:${frame.frameId}`, frame.url);
			}
		} catch (error) {}
	}
	reapplyAll();
}

// ── storage ──────────────────────────────────────────────────────────────────
function readTheme(theme) {
	themeColors = theme && theme.colors ? theme.colors : {};
	themeDark = !(theme && theme.properties && theme.properties.color_scheme === "light");
	buildVars();
}

browser.storage.local.get(["styles", "theme", "measures", "learned"]).then(kept => {
	styles = Array.isArray(kept.styles) ? kept.styles : [];
	learned = kept.learned && typeof kept.learned === "object" ? kept.learned : {};
	measures = kept.measures || {};
	readTheme(kept.theme);
	scanFrames();
});

browser.storage.onChanged.addListener((changes, area) => {
	if (area !== "local") return;
	if (changes.measures) {
		measures = changes.measures.newValue || {};
		buildVars();
		reapplyAll();
	}
	if (changes.theme) {
		readTheme(changes.theme.newValue);
		reapplyAll();
		tellEditors({ op: "palette", palette: paletteOf(), dark: themeDark });
	}
});

function persist() {
	reapplyAll();
	return browser.storage.local.set({ styles });
}

function tellEditors(message) {
	browser.tabs.query({}).then(tabs => {
		for (const tab of tabs) browser.tabs.sendMessage(tab.id, Object.assign({ pshellStyler: true }, message), { frameId: 0 }).catch(() => {});
	});
}

function cleanStyle(style) {
	return {
		id: String(style.id || crypto.randomUUID()),
		name: String(style.name || "Style").slice(0, 120),
		on: style.on !== false,
		sites: (Array.isArray(style.sites) ? style.sites : []).map(site => String(site).trim()).filter(Boolean).slice(0, 50),
		css: String(style.css || ""),
		look: !!style.look,
		follow: !!style.follow,
		autoMap: style.autoMap && typeof style.autoMap === "object" ? style.autoMap : null,
		updated: Date.now()
	};
}

// ── subpages ─────────────────────────────────────────────────────────────────
// A style with "follow" colours every page of its sites the way Auto coloured
// the first: content/styler.js reads the page (with its styles on, so nothing
// flickers) and only what no rule covers yet gets one, from the mapping the
// first Auto kept (autoMap). Rules once written never change, so a sidebar
// keeps its colours on every page.
const AUTO_END = "/* /pshell:auto */";
const followDue = new Map(); // tab → timers

function wantsFollow(url) {
	return stylable(url) && styles.some(style => style.on !== false && style.follow && style.autoMap && styleMatches(style, url));
}

function scheduleFollow(tabId, url) {
	for (const timer of followDue.get(tabId) || []) clearTimeout(timer);
	followDue.delete(tabId);
	if (!wantsFollow(url)) return;
	// once the page settled, and again for what comes in late
	followDue.set(tabId, [1200, 4500].map(delay => setTimeout(() => runFollow(tabId), delay)));
}

async function runFollow(tabId) {
	try {
		await browser.tabs.executeScript(tabId, { code: "window.pshellFollowOnly = true;", frameId: 0 });
		await browser.tabs.executeScript(tabId, { file: "/content/styler.js", frameId: 0 });
	} catch (error) {}
}

browser.webNavigation.onCompleted.addListener(details => {
	if (details.frameId === 0) scheduleFollow(details.tabId, details.url);
});
browser.webNavigation.onHistoryStateUpdated.addListener(details => {
	if (details.frameId === 0) scheduleFollow(details.tabId, details.url);
});

// rules for selectors the style has none for yet go in before the end of
// its Auto block; frame rules ("force") even when the selector has some
function extendStyle(id, lines, map) {
	const style = styles.find(other => other.id === id);
	if (!style) return 0;
	let css = style.css;
	const end = css.indexOf(AUTO_END);
	if (end < 0) return 0;
	const added = [];
	for (const line of lines) {
		const brace = line.text.indexOf(" {");
		if (brace < 0) continue;
		const head = `${line.text.slice(0, brace)} {`;
		const block = css.slice(0, end);
		if (line.force ? block.includes(line.text) : (block.includes(`\n${head}`) || added.some(text => text.startsWith(head)))) continue;
		added.push(line.text);
	}
	if (!added.length && !map) return 0;
	// what Auto wrote, so the user's changes to it can be told apart (content/styler.js learn)
	const made = Object.assign({}, style.autoMap && style.autoMap.made);
	for (const text of added) {
		const open = text.indexOf("{");
		const selector = text.slice(0, open).trim();
		const props = made[selector] = Object.assign({}, made[selector]);
		for (const part of splitDeclarations(text.slice(open + 1, text.lastIndexOf("}")))) {
			const colon = part.indexOf(":");
			if (colon > 0) props[part.slice(0, colon).trim()] = part.slice(colon + 1).trim();
		}
	}
	style.autoMap = Object.assign({}, style.autoMap, map || {}, { made });
	style.css = css.slice(0, end) + added.map(text => `${text}\n`).join("") + css.slice(end);
	style.updated = Date.now();
	persist();
	return added.length;
}

// ── learning ─────────────────────────────────────────────────────────────────
// What the user gave a kind of element (content/styler.js kindOf: "sidebar",
// "sidebar/item", "page/message:hover" …) in their own rules, kept per style
// and rule: learned[styleId][rule] = { key, props: { prop: role } }. Auto
// takes a role every style that has the kind agrees on (or most of them).

function persistLearned() {
	return browser.storage.local.set({ learned });
}

function learnFrom(id, entries, keep) {
	if (!styles.some(style => style.id === id)) return;
	const own = Object.assign({}, learned[id]);
	for (const rule of Object.keys(own)) if (!keep.includes(rule)) delete own[rule];
	for (const [rule, entry] of Object.entries(entries || {})) {
		if (entry && entry.key && entry.props && Object.keys(entry.props).length) own[rule] = { key: String(entry.key), props: entry.props };
		else delete own[rule];
	}
	if (Object.keys(own).length) learned[id] = own;
	else delete learned[id];
	return persistLearned();
}

// key → prop → role; every style votes once per key and prop, a role wins
// with more than half of them. "*/leaf" gathers a leaf from every region.
function learnedModel() {
	const tally = new Map();
	for (const [id, rules] of Object.entries(learned)) {
		if (!styles.some(style => style.id === id)) continue;
		const seen = new Set();
		for (const { key, props } of Object.values(rules)) {
			const keys = key.includes("/") ? [key, `*/${key.slice(key.indexOf("/") + 1)}`] : [key];
			for (const k of keys) {
				for (const [prop, role] of Object.entries(props)) {
					const mark = `${k}|${prop}|${role}`;
					if (seen.has(mark)) continue;
					seen.add(mark);
					if (!tally.has(k)) tally.set(k, new Map());
					const byProp = tally.get(k);
					if (!byProp.has(prop)) byProp.set(prop, new Map());
					byProp.get(prop).set(role, (byProp.get(prop).get(role) || 0) + 1);
				}
			}
		}
	}
	const model = {};
	for (const [key, byProp] of tally) {
		for (const [prop, roles] of byProp) {
			const total = [...roles.values()].reduce((a, b) => a + b, 0);
			const [role, count] = [...roles.entries()].sort((a, b) => b[1] - a[1])[0];
			if (count * 2 > total) (model[key] = model[key] || {})[prop] = role;
		}
	}
	return model;
}

// a Stylus backup (Stylus › Backup › Export): every section becomes a style
function fromStylus(data) {
	const list = Array.isArray(data) ? data : [data];
	const out = [];
	for (const entry of list) {
		if (!entry || !Array.isArray(entry.sections)) continue;
		const sections = entry.sections.filter(section => section && String(section.code || "").trim());
		sections.forEach((section, index) => {
			const sites = [
				...(section.domains || []),
				...(section.urlPrefixes || []),
				...(section.urls || []),
				...(section.regexps || []).map(re => `/${re}/`)
			];
			out.push(cleanStyle({
				name: sections.length > 1 ? `${entry.name || "Style"} ${index + 1}` : entry.name,
				on: entry.enabled !== false,
				sites,
				css: section.code
			}));
		});
	}
	return out;
}

// ── the editor ───────────────────────────────────────────────────────────────
async function openEditor(tab) {
	if (!tab || !stylable(tab.url)) return;
	try {
		await browser.tabs.executeScript(tab.id, { file: "/content/styler.js", frameId: 0 });
	} catch (error) {
		console.error("[pshell] styler:", error);
	}
}

// in the Pshell menu (background/bridge.js buildMenu), first
function stylesMenu(parentId) {
	browser.menus.create({
		id: "pshell-restyle",
		parentId,
		title: "Restyle page",
		contexts: ["page", "frame", "selection", "link", "image"],
		documentUrlPatterns: ["http://*/*", "https://*/*", "file:///*"]
	});
}

browser.menus.onClicked.addListener((info, tab) => {
	if (info.menuItemId === "pshell-restyle") openEditor(tab);
});

browser.runtime.onMessage.addListener((message, sender) => {
	if (!message || message.pshell !== "styles") return;
	const tab = sender.tab;
	switch (message.op) {
		case "state": {
			const url = message.url || (tab ? tab.url : "");
			return Promise.resolve({
				styles: styles.map(style => Object.assign({}, style, { matches: styleMatches(style, url) })),
				palette: paletteOf(),
				dark: themeDark,
				learned: learnedModel(),
				learnedCount: Object.keys(learned).length
			});
		}
		case "save": {
			// an editor still holding a style deleted meanwhile does not bring it back
			if (removed.has(String((message.style || {}).id))) return Promise.resolve({ gone: true });
			const style = cleanStyle(message.style || {});
			const index = styles.findIndex(other => other.id === style.id);
			if (index >= 0) styles[index] = style;
			else styles.push(style);
			return persist().then(() => Object.assign({}, style, { matches: tab ? styleMatches(style, tab.url) : false }));
		}
		case "remove":
			removed.add(String(message.id));
			styles = styles.filter(style => style.id !== message.id);
			if (learned[message.id]) {
				delete learned[message.id];
				persistLearned();
			}
			return persist().then(() => true);
		case "learn":
			return Promise.resolve(learnFrom(String(message.id), message.entries, Array.isArray(message.keep) ? message.keep : [])).then(() => true);
		case "forget":
			learned = {};
			return persistLearned().then(() => true);
		case "import": {
			let added = [];
			try {
				added = fromStylus(JSON.parse(message.text));
			} catch (error) {
				return Promise.resolve({ error: "Not a Stylus backup" });
			}
			styles.push(...added);
			return persist().then(() => ({ count: added.length }));
		}
		case "open":
			return browser.tabs.query({ active: true, currentWindow: true }).then(([active]) => openEditor(active)).then(() => true);
		case "toggle": {
			const style = styles.find(other => other.id === message.id);
			if (!style) return Promise.resolve(false);
			style.on = !!message.on;
			style.updated = Date.now();
			return persist().then(() => true);
		}
		case "extend":
			return Promise.resolve(extendStyle(message.id, Array.isArray(message.lines) ? message.lines : [], message.map || null));
		case "export":
			return Promise.resolve(styles);
		case "suspend":
			if (!tab) return Promise.resolve(false);
			if (message.on) suspended.add(tab.id);
			else suspended.delete(tab.id);
			return Promise.all([...frames.keys()].filter(key => key.startsWith(`${tab.id}:`)).map(applyFrame)).then(() => true);
	}
});
