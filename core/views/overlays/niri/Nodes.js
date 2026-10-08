.pragma library

// KDL nodes as plain data ({ name, args, props, children }) read and changed
// without touching the original: every `with…` returns a changed copy. The
// editors work on a section (a `border {}` of the layout, of a window rule, of
// a monitor's layout) and hand back the new one.

function clone(value) {
	return value === undefined ? undefined : JSON.parse(JSON.stringify(value));
}

function make(name, args, props, children) {
	const node = { name: name, args: args || [], props: props || {} };
	if (children !== undefined) node.children = children;
	return node;
}

function find(list, name) {
	return (list || []).find(node => node.name === name && !node.disabled) ?? null;
}

function get(node, path) {
	let current = node;
	for (const name of [].concat(path)) {
		current = find(current?.children, name);
		if (!current) return null;
	}
	return current;
}

function has(node, path) {
	return !!get(node, path);
}

function arg(node, path, fallback) {
	const found = get(node, path);
	return found && found.args.length > 0 ? found.args[0] : fallback;
}

function prop(node, path, name, fallback) {
	const value = get(node, path)?.props?.[name];
	return value === undefined ? fallback : value;
}

function flag(node, path) {
	const found = get(node, path);
	return !!found && found.args[0] !== false;
}

// on/off inside a section; `fallback` when it says neither
function on(node, fallback) {
	const off = find(node?.children, "off");
	if (off && off.args[0] !== false) return false;
	const yes = find(node?.children, "on");
	if (yes && yes.args[0] !== false) return true;
	return fallback;
}

function base(node, name) {
	const copy = node ? clone(node) : make(name || "section", [], {}, []);
	if (!copy.children) copy.children = [];
	return copy;
}

// a copy with the leaf at `path` set (parents made when missing)
function withNode(node, path, args, props) {
	const copy = base(node);
	const names = [].concat(path);
	let list = copy.children;
	for (let i = 0; i < names.length - 1; i++) {
		let next = find(list, names[i]);
		if (!next) {
			next = make(names[i], [], {}, []);
			list.push(next);
		}
		if (!next.children) next.children = [];
		list = next.children;
	}
	const last = names[names.length - 1];
	const found = find(list, last);
	if (found) {
		found.args = args || [];
		if (props !== undefined) found.props = props;
	} else {
		list.push(make(last, args, props));
	}
	return copy;
}

function withArg(node, path, value) {
	return withNode(node, path, [value]);
}

function without(node, path) {
	const copy = base(node);
	const names = [].concat(path);
	let list = copy.children;
	for (let i = 0; i < names.length - 1; i++) {
		const next = find(list, names[i]);
		if (!next) return copy;
		list = next.children || [];
	}
	const last = names[names.length - 1];
	for (let i = list.length - 1; i >= 0; i--)
		if (list[i].name === last && !list[i].disabled) list.splice(i, 1);
	return copy;
}

function withFlag(node, path, value) {
	return value ? withNode(node, path, []) : without(node, path);
}

// `name true/false`, gone when it is the default
function withBool(node, path, value, fallback) {
	return value === fallback ? without(node, path) : withNode(node, path, [value]);
}

function withOn(node, value) {
	const copy = base(node);
	copy.children = copy.children.filter(child => child.name !== "on" && child.name !== "off");
	copy.children.unshift(make(value ? "on" : "off"));
	return copy;
}

function withChild(node, child) {
	const copy = base(node);
	const index = copy.children.findIndex(item => item.name === child.name && !item.disabled);
	if (index >= 0) copy.children[index] = clone(child);
	else copy.children.push(clone(child));
	return copy;
}

// ── colors and gradients ─────────────────────────────────────────────────
// { from, to, angle, relativeTo, space } of `active-gradient from=… to=…`
function gradient(node, name) {
	const found = get(node, name);
	if (!found) return null;
	const p = found.props || {};
	return {
		from: String(p.from ?? "#000000"),
		to: String(p.to ?? "#ffffff"),
		angle: p.angle === undefined ? 180 : Number(p.angle),
		relativeTo: String(p["relative-to"] ?? ""),
		space: String(p["in"] ?? "srgb")
	};
}

function gradientProps(g) {
	const props = { from: g.from, to: g.to };
	if (Number(g.angle) !== 180) props.angle = Math.round(Number(g.angle));
	if (g.relativeTo) props["relative-to"] = g.relativeTo;
	if (g.space && g.space !== "srgb") props["in"] = g.space;
	return props;
}

function withGradient(node, name, g) {
	return g ? withNode(node, name, [], gradientProps(g)) : without(node, name);
}

// sizes: `proportion 0.5` / `fixed 1280` → { kind, value }; null when empty
function size(node) {
	const kid = (node?.children || []).find(child => child.name === "proportion" || child.name === "fixed");
	if (!kid) return null;
	return { kind: kid.name, value: Number(kid.args[0]) };
}

function sizeNode(name, s) {
	return make(name, [], {}, s ? [make(s.kind, [s.kind === "fixed" ? Math.round(s.value) : Number(s.value)])] : []);
}

function fraction(value) {
	const v = Number(value);
	const known = [[1 / 4, "¼"], [1 / 3, "⅓"], [1 / 2, "½"], [2 / 3, "⅔"], [3 / 4, "¾"], [1, "Full"], [1 / 5, "⅕"], [2 / 5, "⅖"], [3 / 5, "⅗"], [4 / 5, "⅘"], [1 / 6, "⅙"], [5 / 6, "⅚"]];
	for (const [n, label] of known)
		if (Math.abs(n - v) < 0.004) return label;
	return `${Math.round(v * 100)}%`;
}
