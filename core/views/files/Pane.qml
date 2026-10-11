pragma ComponentBehavior: Bound

import QtQuick
import qs.core.services
import "Listing.js" as Listing

// One place a tab shows (two in a split): where it is, where it was, what
// is in it and what is picked. Views draw it; it never draws anything.
//
// A location is { kind, path, query, id, contents }:
//   home, dir (path), recent, search (query below path, names or contents),
//   tag (id), collection (id), trash, shelf (id)
Item {
	id: root

	visible: false

	readonly property string paneId: `pane${root.serial}`
	property int serial: 0
	property var location: ({ kind: "home" })
	property var back: []
	property var forward: []

	// what was read, as the daemon gave it
	property var raw: []
	// the same arranged; the ListModel follows it change by change
	property var rows: []
	readonly property alias items: model
	property bool loading: false
	// what was asked for is in: until then an empty list means nothing yet
	property bool settled: false
	property string error: ""
	property bool writable: false
	property real free: 0
	property real total: 0
	// the model was refilled rather than changed: views play their entrance
	property int resets: 0
	// "in", "out" or "jump": how the last navigation went, for the transition
	property string direction: "jump"
	// the model is being refilled: views hold their change animations back
	property bool resetting: false

	// view settings: those of the folder, else the general ones
	readonly property var view: root.location.kind === "dir" ? FileLibrary.viewOf(root.location.path) : FileLibrary.viewOf(`:${root.location.kind}`)
	readonly property string mode: root.view.mode
	readonly property string sort: root.location.kind === "recent" && !FileLibrary.folderViews[":recent"]?.sort ? "modified" : root.view.sort
	readonly property bool desc: root.location.kind === "recent" && !FileLibrary.folderViews[":recent"]?.sort ? true : !!root.view.desc
	readonly property string group: root.view.group
	readonly property bool showHidden: !!FileLibrary.view.hidden
	property string filter: ""

	// ── selection ──────────────────────────────────────────────────────────
	property var selected: ({})
	property int selectionTick: 0
	property int selectionCount: 0
	property int anchor: -1
	property int current: -1
	// pick these once the next read is in
	property var pendingSelect: []
	// rename this once it is in view
	property string pendingRename: ""
	property string renaming: ""
	// views keep their scroll position per place in the history
	property real restoreY: -1

	readonly property string title: {
		const loc = root.location;
		switch (loc.kind) {
		case "home": return "Home";
		case "recent": return "Recent";
		case "trash": return "Trash";
		case "search": return loc.query ? `“${loc.query}”` : "Search";
		case "tag": return FileLibrary.tagById(loc.id)?.name ?? "Tag";
		case "collection": return FileLibrary.collectionById(loc.id)?.name ?? "Collection";
		case "shelf": return Shelf.titleOf(Shelf.shelfById(loc.id)) || "Shelf";
		default: return loc.path === Files.home ? "Home folder" : (Files.nameOf(loc.path) || "/");
		}
	}
	readonly property string icon: {
		switch (root.location.kind) {
		case "home": return "home_variant_outline";
		case "recent": return "history";
		case "trash": return "trash_can_outline";
		case "search": return "magnify";
		case "tag": return "tag_outline";
		case "collection": return "bookmark_box_multiple_outline";
		case "shelf": return "tray_arrow_down";
		default: return root.location.path === Files.home ? "home_outline" : "folder_outline";
		}
	}
	// a folder on disk: what can be pasted into, created in, watched
	readonly property bool isFolder: root.location.kind === "dir"
	readonly property bool virtual: !root.isFolder && root.location.kind !== "home"
	readonly property string folder: root.isFolder ? String(root.location.path) : (root.location.kind === "search" ? String(root.location.path || Files.home) : Files.home)

	signal loaded(bool reset)
	signal renameRequested(string path)

	ListModel {
		id: model

		dynamicRoles: false
	}

	// ── going places ───────────────────────────────────────────────────────
	function same(a, b) {
		return a.kind === b.kind && String(a.path || "") === String(b.path || "") && String(a.query || "") === String(b.query || "")
			&& String(a.id || "") === String(b.id || "") && !!a.contents === !!b.contents;
	}

	// opts: { select: [paths], history: false, direction }
	function go(location, opts) {
		const options = opts || {};
		const next = Object.assign({}, location);
		if (next.kind === "dir") next.path = String(next.path).replace(/(.)\/+$/, "$1");
		if (root.same(next, root.location) && !options.force) {
			if (options.select) root.selectPaths(options.select);
			return;
		}
		// typing a search again replaces the last one instead of piling up
		const replace = options.history === false || (root.location.kind === "search" && next.kind === "search");
		if (!replace) {
			root.back = root.back.concat([{ location: root.location, selected: root.selectedPaths().slice(0, 50) }]).slice(-60);
			root.forward = [];
		}
		root.direction = options.direction || root.directionTo(root.location, next);
		root.location = next;
		root.filter = "";
		root.pendingSelect = options.select || [];
		root.restoreY = options.restoreY ?? -1;
		root.reload(true);
	}

	function directionTo(from, to) {
		if (from.kind === "dir" && to.kind === "dir") {
			if (String(to.path).startsWith(String(from.path).replace(/\/$/, "") + "/")) return "in";
			if (String(from.path).startsWith(String(to.path).replace(/\/$/, "") + "/") || to.path === "/") return "out";
		}
		return "jump";
	}

	function openFolder(path) {
		root.go({ kind: "dir", path: path });
	}

	function goBack() {
		if (root.back.length === 0) return false;
		const entry = root.back[root.back.length - 1];
		root.back = root.back.slice(0, -1);
		root.forward = root.forward.concat([{ location: root.location, selected: root.selectedPaths().slice(0, 50) }]);
		root.direction = "out";
		root.location = entry.location;
		root.filter = "";
		root.pendingSelect = entry.selected || [];
		root.reload(true);
		return true;
	}

	function goForward() {
		if (root.forward.length === 0) return false;
		const entry = root.forward[root.forward.length - 1];
		root.forward = root.forward.slice(0, -1);
		root.back = root.back.concat([{ location: root.location, selected: root.selectedPaths().slice(0, 50) }]);
		root.direction = "in";
		root.location = entry.location;
		root.filter = "";
		root.pendingSelect = entry.selected || [];
		root.reload(true);
		return true;
	}

	// one folder up, with the folder that was left picked
	function goUp() {
		if (!root.isFolder || root.location.path === "/") return false;
		const from = root.location.path;
		root.go({ kind: "dir", path: Files.parentOf(from) }, { select: [from], direction: "out" });
		return true;
	}

	// ── reading ────────────────────────────────────────────────────────────
	property int generation: 0
	property string searchId: ""
	property bool searching: false

	function reload(navigated) {
		root.generation += 1;
		const generation = root.generation;
		const loc = root.location;
		Files.watch(root.paneId, loc.kind === "dir" ? loc.path : "");
		if (navigated) {
			root.settled = false;
			root.error = "";
			root.selected = {};
			root.selectionCount = 0;
			root.selectionTick += 1;
			root.anchor = -1;
			root.current = -1;
		}
		// a slow read shows its placeholder only after a moment
		loadingTimer.restart();
		const done = (entries, error, extra) => {
			if (generation !== root.generation) return;
			loadingTimer.stop();
			root.loading = false;
			root.settled = true;
			root.error = error || "";
			root.writable = !!extra?.writable;
			root.free = Number(extra?.free) || 0;
			root.total = Number(extra?.total) || 0;
			root.raw = entries || [];
			root.arrange(navigated);
		};
		switch (loc.kind) {
		case "home":
			loadingTimer.stop();
			root.settled = true;
			root.raw = [];
			root.arrange(true);
			break;
		case "dir":
			Files.request("list", { path: loc.path }, (data, error) => done(data?.entries ?? [], error, data));
			break;
		case "trash":
			Files.request("list", { path: "trash:///" }, (data, error) => done(data?.entries ?? [], error, {}));
			break;
		case "recent":
			Files.request("recent", { limit: 150 }, (data, error) => {
				const own = FileLibrary.opened.map(entry => entry.path);
				Files.request("describe", { paths: own }, described => {
					const byPath = {};
					for (const entry of data?.entries ?? []) byPath[entry.path] = entry;
					for (const entry of described?.entries ?? []) {
						const at = FileLibrary.opened.find(item => item.path === entry.path)?.at ?? 0;
						if (entry.dir) continue;
						if (!byPath[entry.path] || (byPath[entry.path].used ?? 0) < at) byPath[entry.path] = Object.assign(entry, { used: at });
					}
					done(Object.values(byPath), error, {});
				});
			});
			break;
		case "tag":
			Files.request("describe", { paths: FileLibrary.pathsWithTag(loc.id) }, (data, error) => done(data?.entries ?? [], error, {}));
			break;
		case "collection":
			Files.request("describe", { paths: FileLibrary.collectionById(loc.id)?.paths ?? [] }, (data, error) => done(data?.entries ?? [], error, {}));
			break;
		case "shelf": {
			const shelf = Shelf.shelfById(loc.id);
			const paths = (shelf?.items ?? []).filter(item => item.kind === "file").map(item => item.path);
			Files.request("describe", { paths: paths }, (data, error) => done(data?.entries ?? [], error, {}));
			break;
		}
		case "search":
			root.raw = [];
			root.arrange(true);
			root.searchId = `s${root.paneId}-${generation}`;
			root.searching = String(loc.query || "").trim() !== "";
			loadingTimer.stop();
			root.loading = false;
			root.settled = true;
			if (root.searching)
				Files.request("search", { search: root.searchId, root: loc.path || Files.home, query: loc.query, contents: !!loc.contents, hidden: root.showHidden, limit: 800 });
			break;
		}
	}

	Timer {
		id: loadingTimer

		interval: 140
		onTriggered: root.loading = true
	}

	// the folder on the screen changed on disk: read again, keep what is picked
	Connections {
		target: Files

		function onFolderChanged(path) {
			if (root.location.kind === "dir" && path === root.location.path) changedTimer.restart();
			else if (root.location.kind === "trash" && path.endsWith("/Trash/files")) changedTimer.restart();
		}

		function onSearchResults(search, entries, done, error) {
			if (search !== root.searchId) return;
			if (entries.length > 0) {
				root.raw = root.raw.concat(entries);
				root.arrange(false);
			}
			if (done) root.searching = false;
			if (error) root.error = error;
		}

		function onJobFinished(job) {
			// what a job made in this folder is picked (a paste, a new folder)
			const created = (job.created || []).filter(path => Files.parentOf(path) === root.location.path);
			if (job.state !== "done" || created.length === 0 || root.location.kind !== "dir") return;
			if (["copy", "move", "auto", "paste", "mkdir", "newfile", "rename", "batchrename", "extract", "compress", "download", "link", "restore", "undo"].includes(job.kind)) {
				root.pendingSelect = created;
				if (job.kind === "mkdir" || job.kind === "newfile") root.pendingRename = created[0];
				changedTimer.stop();
				root.reload(false);
			}
		}
	}

	Connections {
		target: FileLibrary
		enabled: root.location.kind === "tag" || root.location.kind === "collection"

		function onTaggedChanged() {
			if (root.location.kind === "tag") changedTimer.restart();
		}
		function onCollectionsChanged() {
			if (root.location.kind === "collection") changedTimer.restart();
		}
	}

	Connections {
		target: Shelf
		enabled: root.location.kind === "shelf"

		function onShelvesChanged() {
			changedTimer.restart();
		}
	}

	Timer {
		id: changedTimer

		interval: 120
		onTriggered: root.reload(false)
	}

	onShowHiddenChanged: if (root.location.kind === "search") root.reload(false); else root.arrange(false)
	onSortChanged: root.arrange(false)
	onDescChanged: root.arrange(false)
	onGroupChanged: root.arrange(false)
	onFilterChanged: root.arrange(false)

	function arrange(reset) {
		const next = Listing.arrange(root.raw, {
			sort: root.sort,
			desc: root.desc,
			group: root.group,
			hidden: root.showHidden,
			filter: root.filter,
			foldersFirst: FileLibrary.view.foldersFirst !== false,
			home: Files.home
		});
		const wasEmpty = model.count === 0;
		let restarted = false;
		if (reset || wasEmpty || next.length === 0 || Math.abs(next.length - model.count) > 300) {
			root.resetting = true;
			model.clear();
			if (next.length > 0) model.append(next);
			root.resetting = false;
			restarted = true;
		} else {
			restarted = Listing.sync(model, next, 300);
		}
		root.rows = next;
		if (restarted || wasEmpty) root.resets += 1;
		// what was picked stays picked where it still is
		const keep = {};
		let count = 0;
		const want = root.pendingSelect.length > 0 ? root.pendingSelect : null;
		for (let i = 0; i < next.length; i += 1) {
			const path = next[i].path;
			if (want ? want.includes(path) : root.selected[path]) {
				keep[path] = true;
				count += 1;
			}
		}
		root.selected = keep;
		root.selectionCount = count;
		root.selectionTick += 1;
		if (want && count > 0) {
			root.current = next.findIndex(row => keep[row.path]);
			root.anchor = root.current;
			root.pendingSelect = [];
		} else if (want && root.location.kind !== "search") {
			root.pendingSelect = [];
		}
		if (root.current >= next.length) root.current = next.length - 1;
		if (root.pendingRename !== "" && next.some(row => row.path === root.pendingRename)) {
			const path = root.pendingRename;
			root.pendingRename = "";
			root.renaming = path;
			root.renameRequested(path);
		}
		root.loaded(restarted);
	}

	// ── selection ──────────────────────────────────────────────────────────
	function isSelected(path) {
		return root.selected[path] === true;
	}

	function commit(next) {
		root.selected = next;
		root.selectionCount = Object.keys(next).length;
		root.selectionTick += 1;
	}

	// how: "only", "toggle", "range", "add"
	function pick(index, how) {
		if (index < 0 || index >= root.rows.length) return;
		const path = root.rows[index].path;
		if (how === "toggle") {
			const next = Object.assign({}, root.selected);
			if (next[path]) delete next[path];
			else next[path] = true;
			root.commit(next);
			root.anchor = index;
		} else if (how === "range" && root.anchor >= 0) {
			const next = {};
			const from = Math.min(root.anchor, index);
			const to = Math.max(root.anchor, index);
			for (let i = from; i <= to; i += 1) next[root.rows[i].path] = true;
			root.commit(next);
		} else if (how === "add") {
			const next = Object.assign({}, root.selected);
			next[path] = true;
			root.commit(next);
		} else {
			root.commit({ [path]: true });
			root.anchor = index;
		}
		root.current = index;
	}

	function pickIndexes(indexes, add) {
		const next = add ? Object.assign({}, root.selected) : {};
		for (const index of indexes) if (root.rows[index]) next[root.rows[index].path] = true;
		root.commit(next);
	}

	function selectAll() {
		const next = {};
		for (const row of root.rows) next[row.path] = true;
		root.commit(next);
	}

	function clearSelection() {
		if (root.selectionCount === 0) return false;
		root.commit({});
		return true;
	}

	function invertSelection() {
		const next = {};
		for (const row of root.rows) if (!root.selected[row.path]) next[row.path] = true;
		root.commit(next);
	}

	function selectPaths(paths) {
		const next = {};
		for (const path of paths) if (root.rows.some(row => row.path === path)) next[path] = true;
		root.commit(next);
		const first = root.rows.findIndex(row => next[row.path]);
		if (first >= 0) {
			root.current = first;
			root.anchor = first;
		}
	}

	function selectedPaths() {
		return root.rows.filter(row => root.selected[row.path]).map(row => row.path);
	}

	function selectedRows() {
		return root.rows.filter(row => root.selected[row.path]);
	}

	// what an action works on: the picked ones, else the one under the cursor
	function targets() {
		const picked = root.selectedRows();
		if (picked.length > 0) return picked;
		return root.current >= 0 && root.rows[root.current] ? [root.rows[root.current]] : [];
	}

	readonly property var currentRow: root.current >= 0 && root.current < root.rows.length ? root.rows[root.current] : null
	readonly property real selectedSize: {
		root.selectionTick;
		let sum = 0;
		for (const row of root.rows) if (root.selected[row.path] && !row.dir) sum += row.size;
		return sum;
	}

	// type-ahead: the next name that starts with what was typed
	property string typed: ""

	function typeAhead(text) {
		root.typed = (root.typed + text).toLowerCase();
		typedTimer.restart();
		const start = root.typed.length === 1 ? root.current + 1 : Math.max(0, root.current);
		for (let n = 0; n < root.rows.length; n += 1) {
			const i = (start + n) % root.rows.length;
			if (root.rows[i].name.toLowerCase().startsWith(root.typed)) {
				root.pick(i, "only");
				return true;
			}
		}
		return false;
	}

	Timer {
		id: typedTimer

		interval: 900
		onTriggered: root.typed = ""
	}

	Component.onDestruction: Files.watch(root.paneId, "")
}
