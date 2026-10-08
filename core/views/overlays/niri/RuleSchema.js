.pragma library

// What a window or layer rule can say, for the rule editor: every property
// with the kind of control it gets, the matchers and how a rule is told in
// words.

const WINDOW = [
	{ name: "open-floating", group: "Opening", label: "Opens floating", icon: "dock_window", type: "bool", fallback: true },
	{ name: "open-maximized", group: "Opening", label: "Opens maximized", icon: "arrow_expand_all", type: "bool", fallback: true },
	{ name: "open-maximized-to-edges", group: "Opening", label: "Maximized to the edges", icon: "fit_to_screen_outline", type: "bool", fallback: true },
	{ name: "open-fullscreen", group: "Opening", label: "Opens fullscreen", icon: "fullscreen", type: "bool", fallback: true },
	{ name: "open-focused", group: "Opening", label: "Gets the focus", icon: "target", type: "bool", fallback: false },
	{ name: "open-on-output", group: "Opening", label: "On monitor", icon: "monitor", type: "output", fallback: "" },
	{ name: "open-on-workspace", group: "Opening", label: "On workspace", icon: "view_grid_outline", type: "workspace", fallback: "" },
	{ name: "default-column-width", group: "Size", label: "Width", icon: "arrow_split_vertical", type: "size", fallback: null },
	{ name: "default-window-height", group: "Size", label: "Height", icon: "arrow_split_horizontal", type: "size", fallback: null },
	{ name: "default-floating-position", group: "Opening", label: "Floating position", icon: "crosshairs_gps", type: "position", fallback: null },
	{ name: "default-column-display", group: "Opening", label: "Column shows as", icon: "tab", type: "display", fallback: "tabbed" },
	{ name: "min-width", group: "Size", label: "Narrowest", icon: "arrow_collapse_horizontal", type: "pixels", fallback: 400 },
	{ name: "max-width", group: "Size", label: "Widest", icon: "arrow_expand_horizontal", type: "pixels", fallback: 1600 },
	{ name: "min-height", group: "Size", label: "Lowest", icon: "arrow_collapse_vertical", type: "pixels", fallback: 300 },
	{ name: "max-height", group: "Size", label: "Highest", icon: "arrow_expand_vertical", type: "pixels", fallback: 1000 },
	{ name: "opacity", group: "Look", label: "Opacity", icon: "opacity", type: "opacity", fallback: 0.9 },
	{ name: "geometry-corner-radius", group: "Look", label: "Corners", icon: "rounded_corner", type: "radius", fallback: 12 },
	{ name: "clip-to-geometry", group: "Look", label: "Cut to the corners", icon: "content_cut", type: "bool", fallback: true },
	{ name: "draw-border-with-background", group: "Look", label: "Border with background", icon: "border_all_variant", type: "bool", fallback: false },
	{ name: "focus-ring", group: "Look", label: "Focus ring", icon: "selection_ellipse", type: "ring", fallback: null },
	{ name: "border", group: "Look", label: "Border", icon: "border_all_variant", type: "ring", fallback: null },
	{ name: "shadow", group: "Look", label: "Shadow", icon: "box_shadow", type: "shadow", fallback: null },
	{ name: "tab-indicator", group: "Look", label: "Tab colors", icon: "tab", type: "tabs", fallback: null },
	{ name: "background-effect", group: "Look", label: "Background blur", icon: "blur", type: "effect", fallback: null },
	{ name: "popups", group: "Look", label: "Its pop-ups", icon: "message_outline", type: "popups", fallback: null },
	{ name: "block-out-from", group: "Behaviour", label: "Hidden when sharing", icon: "eye_off_outline", type: "blockout", fallback: "screencast" },
	{ name: "variable-refresh-rate", group: "Behaviour", label: "Variable refresh rate", icon: "sine_wave", type: "bool", fallback: true },
	{ name: "scroll-factor", group: "Behaviour", label: "Scroll speed", icon: "mouse_move_vertical", type: "factor", fallback: 1 },
	{ name: "tiled-state", group: "Behaviour", label: "Told it is tiled", icon: "view_grid", type: "bool", fallback: true },
	{ name: "baba-is-float", group: "Behaviour", label: "Baba is float", icon: "waves", type: "bool", fallback: true }
];

const LAYER = [
	{ name: "opacity", group: "Look", label: "Opacity", icon: "opacity", type: "opacity", fallback: 0.9 },
	{ name: "geometry-corner-radius", group: "Look", label: "Corners", icon: "rounded_corner", type: "radius", fallback: 12 },
	{ name: "shadow", group: "Look", label: "Shadow", icon: "box_shadow", type: "shadow", fallback: null },
	{ name: "background-effect", group: "Look", label: "Background blur", icon: "blur", type: "effect", fallback: null },
	{ name: "popups", group: "Look", label: "Its pop-ups", icon: "message_outline", type: "popups", fallback: null },
	{ name: "place-within-backdrop", group: "Behaviour", label: "Inside the backdrop", icon: "layers_outline", type: "bool", fallback: true },
	{ name: "block-out-from", group: "Behaviour", label: "Hidden when sharing", icon: "eye_off_outline", type: "blockout", fallback: "screencast" },
	{ name: "baba-is-float", group: "Behaviour", label: "Baba is float", icon: "waves", type: "bool", fallback: true }
];

// matchers: text ones are regexes, the others true/false
const WINDOW_MATCH = [
	{ name: "app-id", label: "App", type: "regex" },
	{ name: "title", label: "Title", type: "regex" },
	{ name: "is-active", label: "Active", type: "flag" },
	{ name: "is-focused", label: "Focused", type: "flag" },
	{ name: "is-active-in-column", label: "Active in its column", type: "flag" },
	{ name: "is-floating", label: "Floating", type: "flag" },
	{ name: "is-urgent", label: "Urgent", type: "flag" },
	{ name: "is-window-cast-target", label: "Being shared", type: "flag" },
	{ name: "at-startup", label: "At startup", type: "flag" }
];

const LAYER_MATCH = [
	{ name: "namespace", label: "Namespace", type: "regex" },
	{ name: "layer", label: "Layer", type: "layer" },
	{ name: "at-startup", label: "At startup", type: "flag" }
];

function props(kind) {
	return kind === "layer" ? LAYER : WINDOW;
}

function matchers(kind) {
	return kind === "layer" ? LAYER_MATCH : WINDOW_MATCH;
}

function info(kind, name) {
	return props(kind).find(p => p.name === name) ?? { name: name, group: "Other", label: name, icon: "code_braces", type: "raw" };
}

// a niri (Rust) regex as a JavaScript one; null when JavaScript cannot read it
function regex(text) {
	let source = String(text || "");
	let flags = "";
	const inline = /^\(\?([a-z]+)\)/.exec(source);
	if (inline) {
		source = source.slice(inline[0].length);
		if (inline[1].includes("i")) flags += "i";
	}
	try {
		return new RegExp(source, flags);
	} catch (error) {
		return null;
	}
}

// does one `match` line fit the window?
function fits(matcher, window) {
	const p = matcher.props || {};
	for (const key in p) {
		const value = p[key];
		if (key === "app-id" || key === "title") {
			const re = regex(value);
			if (!re || !re.test(String(key === "app-id" ? window.appId : window.title))) return false;
		} else if (key === "is-floating") {
			if (!!window.floating !== !!value) return false;
		} else if (key === "is-focused" || key === "is-active") {
			if (!!window.focused !== !!value) return false;
		} else if (key === "namespace") {
			const re = regex(value);
			if (!re || !re.test(String(window.namespace ?? ""))) return false;
		} else if (key === "layer") {
			if (String(window.layer ?? "") !== String(value)) return false;
		}
		// the rest (urgent, startup, …) cannot be told from here: they fit
	}
	return true;
}

function applies(rule, window) {
	const kids = rule.children || [];
	const matches = kids.filter(c => c.name === "match" && !c.disabled);
	const excludes = kids.filter(c => c.name === "exclude" && !c.disabled);
	if (matches.length > 0 && !matches.some(m => fits(m, window))) return false;
	return !excludes.some(m => fits(m, window));
}

// "^org\.foo\.Bar$" → "Bar"; what a person would call the app
function nice(regexText) {
	const s = String(regexText || "").replace(/^\(\?i\)/, "").replace(/^\^/, "").replace(/\$$/, "").replace(/\\\./g, ".");
	const last = s.split(".").pop();
	return last || s;
}

// the rule told in words: who it is for
function who(rule, kind) {
	const kids = rule.children || [];
	const matches = kids.filter(c => c.name === "match" && !c.disabled);
	if (matches.length === 0) return kind === "layer" ? "Every surface" : "Every window";
	const names = matches.map(m => {
		const p = m.props || {};
		if (p["app-id"] !== undefined) return nice(p["app-id"]);
		if (p.namespace !== undefined) return nice(p.namespace);
		if (p.title !== undefined) return `“${nice(p.title)}”`;
		const flag = matchers(kind).find(f => p[f.name] !== undefined);
		return flag ? `${p[flag.name] ? "" : "not "}${flag.label.toLowerCase()}` : "some";
	});
	const shown = names.slice(0, 3).join(", ");
	return names.length > 3 ? `${shown} +${names.length - 3}` : shown;
}

// and what it does
function what(rule, kind) {
	const kids = (rule.children || []).filter(c => c.name !== "match" && c.name !== "exclude" && !c.disabled);
	if (kids.length === 0) return "Does nothing yet";
	return kids.map(c => {
		const p = info(kind, c.name);
		if (p.type === "bool") return c.args[0] === false ? `not ${p.label.toLowerCase()}` : p.label.toLowerCase();
		if (p.type === "opacity") return `${Math.round(Number(c.args[0]) * 100)}% opaque`;
		if (p.type === "output") return `on ${c.args[0]}`;
		if (p.type === "workspace") return `on “${c.args[0]}”`;
		if (p.type === "radius") return `${c.args[0]} px corners`;
		return p.label.toLowerCase();
	}).join(" · ");
}
