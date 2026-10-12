pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.core.services
import "Listing.js" as Listing

// One place a tab shows (two in a split): where it is, where it was, what
// is in it and what is picked. Views draw it; it never draws anything.
//
// A location is { kind, path, query, id, contents }:
//   home, dir (path), recent, search (query below path, names or contents),
//   tag (id), collection (id), trash, shelf (id), duplicates (path: the
//   copies below a folder), storage (path: what takes its space)
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
	// { repo, branch, ahead, behind, files: { name: "M" | "A" | "?" | "D" | "U" } } of a folder in git
	property var git: null
	// two folders compared: { name: "only" | "newer" | "older" | "differs" | "same" } of this side
	property var compareStates: null
	// copies found: groups and how much could go
	property var dupeSummary: null
	// how a search by meaning was read: { words, read: { kind, after, before }, relaxed }
	property var aiRead: null
	// the model was refilled rather than changed: views play their entrance
	property int resets: 0
	// "in", "out" or "jump": how the last navigation went, for the transition
	property string direction: "jump"
	// the last navigation went back or forth in the history (a place seen before)
	property bool historyStep: false
	// the model is being refilled: views hold their change animations back
	property bool resetting: false

	// view settings: those of the folder, else the general ones
	readonly property string viewKey: root.location.kind === "dir" ? String(root.location.path) : `:${root.location.kind}`
	readonly property var view: FileLibrary.viewOf(root.viewKey)
	// in a split each side may show its files its own way
	property string modeOverride: ""
	readonly property string mode: root.modeOverride || root.view.mode
	// recent things come newest first unless the place was given an order of its own
	readonly property bool newestFirst: ["recent", "clipboard", "phone", "captures"].includes(root.location.kind) && !FileLibrary.folderViews[`:${root.location.kind}`]?.sort
	// matches by meaning come best first
	readonly property bool ranked: (root.location.kind === "search" && !!root.location.ai) || root.location.kind === "similar"
	readonly property string sort: root.ranked ? "given" : (root.location.kind === "duplicates" ? "modified" : (root.newestFirst ? "modified" : root.view.sort))
	readonly property bool desc: root.location.kind === "duplicates" ? false : (root.newestFirst ? true : !!root.view.desc)
	// copies come in their groups, as they were found
	readonly property string group: root.ranked ? "none" : root.location.kind === "duplicates" ? "given"
		// captures are a timeline unless they were given groups of their own
		: (root.location.kind === "captures" && !FileLibrary.folderViews[":captures"]?.group ? "date" : root.view.group)
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
		case "similar": return `Like ${Files.nameOf(loc.path)}`;
		case "tag": return FileLibrary.tagById(loc.id)?.name ?? "Tag";
		case "collection": return FileLibrary.collectionById(loc.id)?.name ?? "Collection";
		case "shelf": return Shelf.titleOf(Shelf.shelfById(loc.id)) || "Shelf";
		case "duplicates": return `Copies in ${loc.path === Files.home ? "your home" : Files.nameOf(loc.path)}`;
		case "phone": return `${PhoneDrive.collectionOf(loc.id).label} on ${PhoneDrive.name}`;
		case "clipboard": return "Clipboard history";
		case "captures": return "Captures";
		case "storage": return `Space of ${loc.path === Files.home ? "your home" : (loc.path === "/" ? "the system" : Files.nameOf(loc.path))}`;
		default: return loc.path === Files.home ? "Home folder" : (Files.nameOf(loc.path) || "/");
		}
	}
	readonly property string icon: {
		switch (root.location.kind) {
		case "home": return "home_variant_outline";
		case "recent": return "history";
		case "trash": return "trash_can_outline";
		case "search": return root.location.ai ? "creation" : "magnify";
		case "similar": return "approximately_equal";
		case "tag": return "tag_outline";
		case "collection": return "bookmark_box_multiple_outline";
		case "shelf": return "tray_arrow_down";
		case "duplicates": return "content_duplicate";
		case "storage": return "chart_donut";
		case "phone": return PhoneDrive.collectionOf(root.location.id).icon;
		case "clipboard": return "clipboard_text_multiple_outline";
		case "captures": return "camera_outline";
		default: return root.location.path === Files.home ? "home_outline" : "folder_outline";
		}
	}
	// a folder on disk: what can be pasted into, created in, watched
	readonly property bool isFolder: root.location.kind === "dir"
	readonly property bool virtual: !root.isFolder && root.location.kind !== "home" && root.location.kind !== "storage"
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
			&& String(a.id || "") === String(b.id || "") && !!a.contents === !!b.contents && String(a.at || "") === String(b.at || "") && !!a.ai === !!b.ai;
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
		root.historyStep = false;
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
		root.historyStep = true;
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
		root.historyStep = true;
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
		// the folders of captures, watched while they are shown
		for (let i = 0; i < 3; i += 1) Files.watch(`${root.paneId}-c${i}`, "");
		if (navigated) {
			root.compareStates = null;
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
			root.git = extra?.git ?? null;
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
			if (navigated && loc.path !== Files.home) FileLibrary.noteVisited(loc.path);
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
		case "duplicates":
			root.readDupes(generation, done);
			break;
		case "captures":
			Files.request("captures", {}, (data, error) => {
				done(data?.entries ?? [], error, {});
				for (const [index, folder] of (data?.folders ?? []).entries()) Files.watch(`${root.paneId}-c${index}`, folder);
			});
			break;
		case "clipboard":
			Files.request("clips", {}, (data, error) => done(data?.entries ?? [], error, {}));
			// a new entry (cliphist writes its database) reads the list again
			Files.watch(root.paneId, `${Quickshell.env("XDG_CACHE_HOME") || Files.home + "/.cache"}/cliphist`);
			break;
		case "phone":
			PhoneDrive.browse(String(loc.id), { limit: 600 }, (entries, error) => done(entries, error === "permission"
				? `Allow the Pshell app on ${PhoneDrive.name} to see photos: in the app, Files → Let the PC see your photos` : error, {}));
			break;
		case "storage":
			loadingTimer.stop();
			root.settled = true;
			root.raw = [];
			root.arrange(true);
			break;
		case "similar":
			root.searching = true;
			Files.request("similar", { path: loc.path }, (data, error) => {
				root.searching = false;
				done((data?.entries ?? []).map((entry, index) => Object.assign(entry, { order: index })), error, {});
			});
			break;
		case "search":
			if (loc.ai && String(loc.query || "").trim() !== "") {
				root.raw = [];
				root.arrange(true);
				root.searching = true;
				root.aiRead = null;
				Files.request("aisearch", { query: loc.query }, (data, error) => {
					if (generation !== root.generation) return;
					root.searching = false;
					root.aiRead = data ? { words: data.words ?? [], read: data.read, relaxed: !!data.relaxed } : null;
					done((data?.entries ?? []).map((entry, index) => Object.assign(entry, { order: index })), error, {});
				});
				break;
			}
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

	// the copies of the last look, else a look is started (and waited for)
	function readDupes(generation, done) {
		const path = String(root.location.path);
		const found = Files.dupeResults[path];
		if (!found) {
			root.dupeSummary = null;
			if (!Files.dupeRunning[path]) Files.findDupes(path, { pictures: true });
			root.searching = true;
			return;
		}
		root.searching = false;
		const order = [];
		const info = {};
		let waste = 0;
		const labels = {};
		found.groups.forEach((group, rank) => {
			const first = group.paths[0];
			let label = `${Files.nameOf(first.path)} · ${group.kind === "same" ? `${group.paths.length} copies, ${Files.sizeText(group.size)} each` : `${group.paths.length} look alike`}`;
			while (labels[label]) label += " ";
			labels[label] = true;
			waste += group.kind === "same" ? group.size * (group.paths.length - 1) : 0;
			for (const item of group.paths) {
				order.push(item.path);
				info[item.path] = { group: label, groupRank: rank };
			}
		});
		root.dupeSummary = { groups: found.groups.length, waste: waste, at: found.at, firsts: found.groups.map(group => group.paths[0].path) };
		Files.request("describe", { paths: order }, (data, error) => {
			const entries = (data?.entries ?? []).map(entry => Object.assign(entry, info[entry.path] ?? {}));
			// a group of which only one is left is no group of copies any more
			const counts = {};
			for (const entry of entries) counts[entry.group] = (counts[entry.group] ?? 0) + 1;
			done(entries.filter(entry => counts[entry.group] > 1), error, {});
		});
	}

	Connections {
		target: Files
		enabled: root.location.kind === "duplicates"

		function onDupeResultsChanged() {
			root.reload(false);
		}
		function onDupeRunningChanged() {
			if (!Files.dupeRunning[String(root.location.path)] && !Files.dupeResults[String(root.location.path)]) root.searching = false;
		}
	}

	// pictures of the phone's files come in after the list: the rows take them
	Connections {
		target: PhoneDrive
		enabled: root.location.kind === "phone"

		function onThumbTickChanged() {
			root.raw = root.raw.map(entry => entry.phoneId && PhoneDrive.thumbs[entry.phoneId] && entry.thumb !== PhoneDrive.thumbs[entry.phoneId] ? Object.assign({}, entry, { thumb: PhoneDrive.thumbs[entry.phoneId] }) : entry);
			root.arrange(false);
		}
	}

	// copies: all but the first (the oldest) of each group are picked
	function pickCopies() {
		const firsts = new Set(root.dupeSummary?.firsts ?? []);
		const seen = new Set();
		const next = {};
		for (const row of root.rows) {
			if (seen.has(row.group) || !firsts.has(row.path)) {
				if (!firsts.has(row.path)) next[row.path] = true;
			}
			seen.add(row.group);
		}
		root.commit(next);
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
			else if (root.location.kind === "clipboard" && path.endsWith("/cliphist")) changedTimer.restart();
			else if (root.location.kind === "captures" && /\/(Screenshots|Recordings|Screencasts)$/.test(path)) changedTimer.restart();
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
			const here = root.location.kind === "dir" && (job.touched || []).includes(root.location.path);
			if (job.state !== "done" || created.length === 0 || root.location.kind !== "dir") {
				// what it took away goes even if the folder's watch missed it
				if (here || (root.location.kind === "trash" && ["trash", "restore", "emptytrash", "delete", "undo"].includes(job.kind))) changedTimer.restart();
			// copies that were thrown away leave the list of copies
			if (root.location.kind === "duplicates" && ["trash", "delete", "move", "auto", "undo"].includes(job.kind)) changedTimer.restart();
				return;
			}
			if (["copy", "move", "auto", "paste", "mkdir", "newfile", "rename", "batchrename", "extract", "compress", "download", "link", "restore", "undo", "convert", "pdf"].includes(job.kind)) {
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
			foldersFirst: root.location.kind !== "duplicates" && FileLibrary.view.foldersFirst !== false,
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

	Component.onDestruction: {
		Files.watch(root.paneId, "");
		for (let i = 0; i < 3; i += 1) Files.watch(`${root.paneId}-c${i}`, "");
	}
}
