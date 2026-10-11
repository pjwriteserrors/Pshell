pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.style.theme

// What the file manager keeps for the user (files.json): favourite folders,
// tags and the files that carry them, collections (files gathered without
// moving them), how folders are shown, what was opened, and the tabs that
// were open. Files never move for any of it.
Singleton {
	id: root

	// [path]
	property var favorites: []
	// [{ id, name, color }] – color is a role of the palette (see colorOf)
	property var tags: []
	// path → [tag id]
	property var tagged: ({})
	// [{ id, name, icon, paths: [path] }]
	property var collections: []
	// how folders are shown unless one was set for a folder
	property var view: ({ mode: "grid", sort: "name", desc: false, group: "none", cardSize: 172, hidden: false, foldersFirst: true, sidebar: true, details: false })
	// path → { mode, sort, desc, group } where it differs
	property var folderViews: ({})
	// [{ path, at }], newest first
	property var opened: []
	// the tabs of the last session: [{ panes: [location], split }]
	property var session: []
	property bool loaded: false

	readonly property var tagColors: ["danger", "warning", "success", "primary", "secondary", "tertiary", "text"]
	readonly property var defaultTags: [
		{ id: "important", name: "Important", color: "danger" },
		{ id: "work", name: "Work", color: "primary" },
		{ id: "personal", name: "Personal", color: "success" },
		{ id: "later", name: "Later", color: "warning" }
	]

	// ── favourites ─────────────────────────────────────────────────────────
	function isFavorite(path) {
		return root.favorites.includes(String(path));
	}

	function toggleFavorite(path) {
		const value = String(path);
		root.favorites = root.isFavorite(value) ? root.favorites.filter(p => p !== value) : root.favorites.concat([value]);
		Sounds.play(root.isFavorite(value) ? "pinned" : "toggleOff");
		root.save();
	}

	function moveFavorite(from, to) {
		const list = root.favorites.slice();
		const [item] = list.splice(from, 1);
		list.splice(Math.max(0, Math.min(list.length, to)), 0, item);
		root.favorites = list;
		root.save();
	}

	// ── tags ───────────────────────────────────────────────────────────────
	function tagById(id) {
		return root.tags.find(tag => tag.id === id) ?? null;
	}

	function tagsOf(path) {
		return root.tagged[String(path)] ?? [];
	}

	function hasTag(path, id) {
		return root.tagsOf(path).includes(id);
	}

	function pathsWithTag(id) {
		return Object.keys(root.tagged).filter(path => root.tagged[path].includes(id));
	}

	function countOf(id) {
		return root.pathsWithTag(id).length;
	}

	// on for every path if one of them lacks it, off otherwise
	function toggleTag(paths, id) {
		const all = paths.every(path => root.hasTag(path, id));
		const next = Object.assign({}, root.tagged);
		for (const path of paths) {
			const current = (next[path] ?? []).filter(tag => tag !== id);
			if (!all) current.push(id);
			if (current.length > 0) next[path] = current;
			else delete next[path];
		}
		root.tagged = next;
		Sounds.play(all ? "toggleOff" : "toggleOn");
		root.save();
	}

	function addTag(name, color) {
		const clean = String(name).trim();
		if (clean === "") return "";
		const existing = root.tags.find(tag => tag.name.toLowerCase() === clean.toLowerCase());
		if (existing) return existing.id;
		const id = `t${Date.now().toString(36)}`;
		root.tags = root.tags.concat([{ id: id, name: clean, color: color || root.tagColors[root.tags.length % root.tagColors.length] }]);
		root.save();
		return id;
	}

	function renameTag(id, name) {
		root.tags = root.tags.map(tag => tag.id === id ? Object.assign({}, tag, { name: String(name).trim() || tag.name }) : tag);
		root.save();
	}

	function recolorTag(id, color) {
		root.tags = root.tags.map(tag => tag.id === id ? Object.assign({}, tag, { color: color }) : tag);
		root.save();
	}

	function removeTag(id) {
		root.tags = root.tags.filter(tag => tag.id !== id);
		const next = {};
		for (const path of Object.keys(root.tagged)) {
			const left = root.tagged[path].filter(tag => tag !== id);
			if (left.length > 0) next[path] = left;
		}
		root.tagged = next;
		root.save();
	}

	// ── collections ────────────────────────────────────────────────────────
	function collectionById(id) {
		return root.collections.find(collection => collection.id === id) ?? null;
	}

	function newCollection(name, paths) {
		const id = `c${Date.now().toString(36)}`;
		root.collections = root.collections.concat([{ id: id, name: String(name).trim() || "Collection", icon: "bookmark_box_multiple_outline", paths: (paths || []).slice() }]);
		root.save();
		return id;
	}

	function addToCollection(id, paths) {
		root.collections = root.collections.map(collection => collection.id !== id ? collection
			: Object.assign({}, collection, { paths: collection.paths.concat(paths.filter(path => !collection.paths.includes(path))) }));
		Sounds.play("pinned");
		root.save();
	}

	function removeFromCollection(id, paths) {
		root.collections = root.collections.map(collection => collection.id !== id ? collection
			: Object.assign({}, collection, { paths: collection.paths.filter(path => !paths.includes(path)) }));
		root.save();
	}

	function renameCollection(id, name) {
		root.collections = root.collections.map(collection => collection.id === id ? Object.assign({}, collection, { name: String(name).trim() || collection.name }) : collection);
		root.save();
	}

	function removeCollection(id) {
		root.collections = root.collections.filter(collection => collection.id !== id);
		root.save();
	}

	// files moved or renamed by the file manager keep their tags, favourites
	// and collections
	function moved(from, to) {
		const a = String(from);
		const b = String(to);
		const remap = path => path === a ? b : (path.startsWith(a + "/") ? b + path.slice(a.length) : path);
		let changed = false;
		const nextTagged = {};
		for (const path of Object.keys(root.tagged)) {
			const target = remap(path);
			if (target !== path) changed = true;
			nextTagged[target] = root.tagged[path];
		}
		const favorites = root.favorites.map(remap);
		const collections = root.collections.map(collection => Object.assign({}, collection, { paths: collection.paths.map(remap) }));
		if (!changed && favorites.every((path, i) => path === root.favorites[i]) && JSON.stringify(collections) === JSON.stringify(root.collections)) return;
		root.tagged = nextTagged;
		root.favorites = favorites;
		root.collections = collections;
		root.save();
	}

	// ── how a folder is shown ──────────────────────────────────────────────
	function viewOf(path) {
		return Object.assign({}, root.view, root.folderViews[String(path)] ?? {});
	}

	// mode, sort, desc and group are kept for the folder; the rest for all
	function setView(path, changes) {
		const own = {};
		const shared = {};
		for (const key of Object.keys(changes)) {
			if (["mode", "sort", "desc", "group"].includes(key) && path) own[key] = changes[key];
			else shared[key] = changes[key];
		}
		if (Object.keys(shared).length > 0) root.view = Object.assign({}, root.view, shared);
		if (Object.keys(own).length > 0) {
			const next = Object.assign({}, root.folderViews);
			next[path] = Object.assign({}, next[path] ?? {}, own);
			// the oldest folders are forgotten
			const keys = Object.keys(next);
			if (keys.length > 400) delete next[keys[0]];
			root.folderViews = next;
			// a choice made here becomes what other folders start with
			root.view = Object.assign({}, root.view, own);
		}
		root.save();
	}

	// ── opened ─────────────────────────────────────────────────────────────
	function noteOpened(path) {
		const value = String(path);
		root.opened = [{ path: value, at: Date.now() / 1000 }].concat(root.opened.filter(entry => entry.path !== value)).slice(0, 80);
		root.save();
	}

	function setSession(tabs) {
		root.session = tabs;
		root.save();
	}

	// ── colours ────────────────────────────────────────────────────────────
	function colorOf(role) {
		switch (role) {
		case "danger": return Theme.danger;
		case "warning": return Theme.warning;
		case "success": return Theme.success;
		case "secondary": return Theme.secondary;
		case "tertiary": return Theme.tertiary;
		case "text": return Theme.textMuted;
		default: return Theme.primary;
		}
	}

	// ── storage ────────────────────────────────────────────────────────────
	function save() {
		if (root.loaded) saveTimer.restart();
	}

	Timer {
		id: saveTimer

		interval: 400
		onTriggered: file.setText(JSON.stringify({
			favorites: root.favorites,
			tags: root.tags,
			tagged: root.tagged,
			collections: root.collections,
			view: root.view,
			folderViews: root.folderViews,
			opened: root.opened,
			session: root.session
		}, null, "\t") + "\n")
	}

	function load(text) {
		let data = {};
		try {
			data = JSON.parse(String(text || "{}"));
		} catch (error) {
			data = {};
		}
		root.favorites = Array.isArray(data.favorites) ? data.favorites.map(String) : [];
		root.tags = Array.isArray(data.tags) ? data.tags : root.defaultTags;
		root.tagged = data.tagged && typeof data.tagged === "object" ? data.tagged : {};
		root.collections = Array.isArray(data.collections) ? data.collections : [];
		root.view = Object.assign({}, root.view, data.view ?? {});
		root.folderViews = data.folderViews && typeof data.folderViews === "object" ? data.folderViews : {};
		root.opened = Array.isArray(data.opened) ? data.opened : [];
		root.session = Array.isArray(data.session) ? data.session : [];
		root.loaded = true;
	}

	FileView {
		id: file

		// a machine without the file manager never reads the file
		path: Plugins.on("filemanager") ? Paths.stateFile("files.json") : ""
		printErrors: false
		onLoaded: root.load(file.text())
		onLoadFailed: root.load("{}")
	}
}
