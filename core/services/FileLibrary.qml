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
	// tagged paths that are not on the disk right now (Files keeps it)
	property var missing: ({})
	// [{ id, name, icon, paths: [path] }]
	property var collections: []
	// searches kept in the sidebar: [{ id, name, query, path, contents }]
	property var searches: []
	// notes stuck to files and folders: path → { text, at }
	property var notes: ({})
	// folders that open their terminals, agents and apps on a workspace of their own: path → workspace index
	property var workspaces: ({})
	// how folders are shown unless one was set for a folder
	property var view: ({ mode: "grid", sort: "name", desc: false, group: "none", cardSize: 172, hidden: false, foldersFirst: true, sidebar: true, details: false })
	// path → { mode, sort, desc, group } of folders that keep their own
	property var folderViews: ({})
	// what the settings page sets (see defaults)
	property var settings: ({})
	readonly property var defaults: ({
		startPage: "restore",
		startFolder: "",
		singleClick: false,
		confirmTrash: false,
		archiveOpen: "extract",
		trashArchive: false,
		textPreviews: true,
		folderPeeks: true,
		thumbLimit: 300,
		remoteThumbs: false,
		dateStyle: "relative",
		sizeUnits: "si",
		sounds: true,
		windowsRunner: "auto",
		protonVersion: "",
		vtUpload: "ask",
		vtDownloads: false,
		avYara: true,
		avDownloads: false,
		pdfQuality: "ebook",
		restoreSelection: true,
		shareHost: "litterbox",
		shareHours: 24,
		shareServer: null,
		gitBadges: true,
		aiIndex: false,
		aiFolders: [],
		aiPictures: true,
		aiOcr: true,
		aiDescribe: true,
		// models picked per feature (scripts/files/ai.py FEATURES); none is the one found
		aiModels: ({}),
		downloadToast: true,
		keepAwake: true,
		ledPulse: true,
		phoneAll: false,
		phoneImportFolder: "",
		terminalBeside: true,
		wallRotation: null
	})
	// [{ path, at }], newest first
	property var opened: []
	// folders looked into lately: [{ path, at }], newest first (the launcher and the radial menu offer them)
	property var visited: []
	// the tabs of the last session: [{ panes: [location], split }]
	property var session: []
	// how often files went to a WhatsApp chat: { chatId: count }
	property var sentTo: ({})
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
		return root.pathsWithTag(id).filter(path => !root.missing[path]).length;
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
		const nextNotes = {};
		for (const path of Object.keys(root.notes)) {
			const target = remap(path);
			if (target !== path) changed = true;
			nextNotes[target] = root.notes[path];
		}
		if (!changed && favorites.every((path, i) => path === root.favorites[i]) && JSON.stringify(collections) === JSON.stringify(root.collections)) return;
		root.notes = nextNotes;
		root.tagged = nextTagged;
		root.favorites = favorites;
		root.collections = collections;
		root.save();
	}

	// ── searches kept ──────────────────────────────────────────────────────
	function addSearch(name, query, path, contents, ai) {
		const id = `s${Date.now().toString(36)}`;
		root.searches = root.searches.concat([{ id: id, name: String(name).trim() || String(query), query: String(query), path: String(path || ""), contents: !!contents, ai: !!ai }]);
		root.save();
		return id;
	}

	function searchById(id) {
		return root.searches.find(entry => entry.id === id) ?? null;
	}

	function renameSearch(id, name) {
		root.searches = root.searches.map(entry => entry.id === id ? Object.assign({}, entry, { name: String(name).trim() || entry.name }) : entry);
		root.save();
	}

	function removeSearch(id) {
		root.searches = root.searches.filter(entry => entry.id !== id);
		root.save();
	}

	// ── notes on files ─────────────────────────────────────────────────────
	function noteOf(path) {
		return root.notes[String(path)]?.text ?? "";
	}

	function setNote(path, text) {
		const next = Object.assign({}, root.notes);
		const clean = String(text || "").trim();
		if (clean === "") delete next[String(path)];
		else next[String(path)] = { text: clean, at: Date.now() / 1000 };
		root.notes = next;
		root.save();
	}

	// ── a workspace per folder ─────────────────────────────────────────────
	// the folder itself or the nearest one above it that has one; -1 for none
	function workspaceOf(path) {
		let current = String(path);
		while (current !== "" && current !== "/") {
			const index = root.workspaces[current];
			if (index !== undefined) return Number(index);
			current = current.slice(0, current.lastIndexOf("/"));
		}
		return -1;
	}

	function setWorkspace(path, index) {
		const next = Object.assign({}, root.workspaces);
		if (index === undefined || index === null || Number(index) < 0) delete next[String(path)];
		else next[String(path)] = Number(index);
		root.workspaces = next;
		root.save();
	}

	// ── how a folder is shown ──────────────────────────────────────────────
	// The layout, the order and the groups are each the same everywhere,
	// unless a folder keeps its own (its scope is "here"). Sort and its
	// direction go together.
	readonly property var scoped: ["mode", "sort", "group"]

	function viewOf(path) {
		return Object.assign({}, root.view, root.folderViews[String(path)] ?? {});
	}

	function keysOf(key) {
		return key === "sort" || key === "desc" ? ["sort", "desc"] : [key];
	}

	// "here" when the folder keeps its own, else "everywhere"
	function scopeOf(path, key) {
		const own = root.folderViews[String(path)];
		return own && own[key === "desc" ? "sort" : key] !== undefined ? "here" : "everywhere";
	}

	// a change goes where the folder's scope for it says
	function setView(path, changes) {
		const own = {};
		const shared = {};
		for (const key of Object.keys(changes)) {
			if (path && ["mode", "sort", "desc", "group"].includes(key) && root.scopeOf(path, key) === "here") own[key] = changes[key];
			else shared[key] = changes[key];
		}
		if (Object.keys(shared).length > 0) root.view = Object.assign({}, root.view, shared);
		if (Object.keys(own).length > 0) {
			const next = Object.assign({}, root.folderViews);
			next[path] = Object.assign({}, next[path] ?? {}, own);
			root.folderViews = next;
		}
		root.save();
	}

	// "here": the folder keeps what it shows now; "everywhere": it follows the rest again
	function setScope(path, key, scope) {
		if (!path) return;
		const next = Object.assign({}, root.folderViews);
		const own = Object.assign({}, next[path] ?? {});
		const current = root.viewOf(path);
		for (const each of root.keysOf(key)) {
			if (scope === "here") own[each] = current[each];
			else delete own[each];
		}
		if (Object.keys(own).length > 0) next[path] = own;
		else delete next[path];
		// the oldest folders are forgotten
		const keys = Object.keys(next);
		if (keys.length > 600) delete next[keys[0]];
		root.folderViews = next;
		root.save();
	}

	readonly property int ownViews: Object.keys(root.folderViews).length

	function forgetFolderViews() {
		root.folderViews = {};
		root.save();
	}

	// ── settings ───────────────────────────────────────────────────────────
	function setting(key) {
		const value = root.settings[key];
		return value === undefined ? root.defaults[key] : value;
	}

	function set(key, value) {
		root.settings = Object.assign({}, root.settings, { [key]: value });
		root.save();
	}

	function resetSettings() {
		root.settings = {};
		root.save();
	}

	// ── opened ─────────────────────────────────────────────────────────────
	function noteOpened(path) {
		const value = String(path);
		root.opened = [{ path: value, at: Date.now() / 1000 }].concat(root.opened.filter(entry => entry.path !== value)).slice(0, 80);
		root.save();
	}

	function forgetOpened() {
		root.opened = [];
		root.visited = [];
		root.save();
	}

	function noteVisited(path) {
		const value = String(path);
		if (value === "" || value === "/") return;
		if (root.visited[0]?.path === value) return;
		root.visited = [{ path: value, at: Date.now() / 1000 }].concat(root.visited.filter(entry => entry.path !== value)).slice(0, 40);
		root.save();
	}

	function noteSent(chatId) {
		root.sentTo = Object.assign({}, root.sentTo, { [chatId]: (root.sentTo[chatId] ?? 0) + 1 });
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
			searches: root.searches,
			notes: root.notes,
			workspaces: root.workspaces,
			view: root.view,
			folderViews: root.folderViews,
			settings: root.settings,
			version: 2,
			opened: root.opened,
			visited: root.visited,
			session: root.session,
			sentTo: root.sentTo
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
		root.searches = Array.isArray(data.searches) ? data.searches : [];
		root.notes = data.notes && typeof data.notes === "object" ? data.notes : {};
		root.workspaces = data.workspaces && typeof data.workspaces === "object" ? data.workspaces : {};
		root.view = Object.assign({}, root.view, data.view ?? {});
		root.folderViews = data.folderViews && typeof data.folderViews === "object" ? data.folderViews : {};
		root.settings = data.settings && typeof data.settings === "object" ? data.settings : {};
		// before scopes every choice was kept for its folder as well: what is
		// the same as everywhere is not the folder's own
		if (!data.version) {
			const next = {};
			for (const path of Object.keys(root.folderViews)) {
				const own = {};
				for (const key of ["mode", "sort", "desc", "group"]) {
					const value = root.folderViews[path][key];
					if (value !== undefined && value !== root.view[key]) own[key] = value;
				}
				if (own.desc !== undefined && own.sort === undefined) own.sort = root.view.sort;
				if (own.sort !== undefined && own.desc === undefined) own.desc = root.view.desc;
				if (Object.keys(own).length > 0) next[path] = own;
			}
			root.folderViews = next;
		}
		root.opened = Array.isArray(data.opened) ? data.opened : [];
		root.visited = Array.isArray(data.visited) ? data.visited : [];
		root.session = Array.isArray(data.session) ? data.session : [];
		root.sentTo = data.sentTo && typeof data.sentTo === "object" ? data.sentTo : {};
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
