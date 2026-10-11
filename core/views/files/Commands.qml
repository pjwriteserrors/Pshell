pragma ComponentBehavior: Bound

import QtQuick
import qs.core.services
import "FileKinds.js" as Kinds

// Everything the file manager can do, in one place: the right-click menus,
// the command palette and the keys all come from here, so a feature that
// is on (the shelves, the phone, the AI, captures) shows up in all three.
QtObject {
	id: root

	required property var view

	readonly property bool shelves: Plugins.on("shelves")
	readonly property bool ai: Plugins.on("chat")
	readonly property bool reader: Plugins.on("fast-reader")
	readonly property bool captures: Plugins.on("screenshot")
	readonly property bool pins: Plugins.on("pins")
	readonly property bool ocr: Plugins.on("ocr")
	readonly property bool wallpaper: Plugins.on("studio-wallpaper")
	readonly property bool agents: Plugins.on("agents")

	function paths(rows) {
		return rows.map(row => row.path);
	}

	function isArchive(row) {
		return Kinds.kindOf(row) === "archive" && !/\.(deb|rpm|apk|jar)$/i.test(row.name);
	}

	// ── what the picked files can do ───────────────────────────────────────
	function forRows(pane, rows) {
		if (rows.length === 0) return root.forPlace(pane);
		const one = rows.length === 1 ? rows[0] : null;
		const dirs = rows.filter(row => row.dir);
		const files = rows.filter(row => !row.dir);
		const images = files.filter(row => row.kind === "image");
		const texts = files.filter(row => row.text);
		const kind = pane.location.kind;
		const paths = root.paths(rows);
		const view = root.view;
		const out = [];

		if (kind === "trash") {
			out.push({ label: rows.length === 1 ? "Restore" : `Restore ${rows.length} items`, icon: "restore", run: () => Files.restore(rows) });
			out.push({ label: "Delete for good", icon: "delete_forever_outline", danger: true, shortcut: "Shift+Del", run: () => Files.remove(paths) });
			out.push({ separator: true });
			out.push({ label: "Quick look", icon: "eye_outline", shortcut: "Space", run: () => view.quickLook(pane) });
			return out;
		}

		out.push({ label: one ? (one.dir ? "Open" : "Open") : `Open ${rows.length} items`, icon: "open_in_app", shortcut: "Enter", run: () => view.openRows(pane, rows, false) });
		if (dirs.length > 0) out.push({ label: dirs.length === 1 ? "Open in a new tab" : "Open in new tabs", icon: "tab_plus", shortcut: "Ctrl+Enter", run: () => dirs.forEach(row => view.newTab({ kind: "dir", path: row.path }, true)) });
		if (one?.dir && view.tab.split) out.push({ label: "Open in the other pane", icon: "dock_right", run: () => view.tab.other.openFolder(one.path) });
		if (one && !one.dir) out.push({ label: "Open with", icon: "apps", children: done => root.openWith(one, done) });
		if (pane.virtual) out.push({ label: "Show in its folder", icon: "folder_search_outline", run: () => view.revealIn(pane, paths) });
		out.push({ label: "Quick look", icon: "eye_outline", shortcut: "Space", run: () => view.quickLook(pane) });

		out.push({ separator: true });
		out.push({ label: "Cut", icon: "content_cut", shortcut: "Ctrl+X", run: () => Files.clipboardSet(paths, true) });
		out.push({ label: "Copy", icon: "content_copy", shortcut: "Ctrl+C", run: () => Files.clipboardSet(paths, false) });
		if (one?.dir) out.push({ label: "Paste into it", icon: "content_paste", run: () => Files.paste(one.path) });
		out.push({ label: "Duplicate", icon: "content_duplicate", run: () => Files.duplicate(paths) });
		out.push({ label: "Copy path", icon: "clipboard_text_outline", shortcut: "Ctrl+Shift+C", run: () => Files.copyText(paths.join("\n"), rows.length === 1 ? "Path copied" : `${rows.length} paths copied`) });
		out.push({ label: rows.length === 1 ? "Rename" : `Rename ${rows.length} items`, icon: "form_textbox", shortcut: "F2", run: () => view.rename(pane, rows) });

		out.push({ separator: true });
		if (one?.dir) out.push({ label: FileLibrary.isFavorite(one.path) ? "Remove from favorites" : "Add to favorites", icon: FileLibrary.isFavorite(one.path) ? "star_off_outline" : "star_outline", shortcut: "Ctrl+D", run: () => FileLibrary.toggleFavorite(one.path) });
		out.push({ label: "Tags", icon: "tag_outline", children: () => root.tagEntries(paths) });
		out.push({ label: "Add to a collection", icon: "bookmark_box_multiple_outline", children: () => root.collectionEntries(paths) });
		if (kind === "collection") out.push({ label: "Take out of this collection", icon: "bookmark_remove_outline", run: () => FileLibrary.removeFromCollection(pane.location.id, paths) });
		if (kind === "tag") out.push({ label: `Remove “${pane.title}”`, icon: "tag_remove_outline", run: () => FileLibrary.toggleTag(paths, pane.location.id) });

		// what the rest of the shell can do with them
		const elsewhere = [];
		if (root.shelves) elsewhere.push({ label: "Put on a shelf", icon: "tray_arrow_down", shortcut: "Ctrl+S", run: () => view.toShelf(rows) });
		if (Phone.available) elsewhere.push({ label: `Send to ${Phone.name}`, icon: "cellphone_arrow_down", run: () => files.forEach(row => Phone.shareFile(row.path)), enabled: files.length > 0 });
		if (root.ai && files.length > 0 && files.length <= 6) elsewhere.push({ label: files.length === 1 ? "Ask AI about it" : "Ask AI about them", icon: "creation", run: () => view.askAi(files) });
		if (root.reader && texts.length === 1) elsewhere.push({ label: "Speed-read it", icon: "book_open_page_variant", run: () => view.speedRead(texts[0]) });
		if (images.length === 1) {
			if (root.captures) elsewhere.push({ label: "Annotate", icon: "draw", run: () => Screenshot.editShot(images[0].path) });
			if (root.pins) elsewhere.push({ label: "Pin to the screen", icon: "pin_outline", run: () => Screenshot.pinShot(images[0].path) });
			if (root.ocr) elsewhere.push({ label: "Copy text from it", icon: "text_recognition", run: () => Screenshot.runOcr(images[0].path, null, false) });
		}
		if (root.wallpaper && one && (one.kind === "image" || one.kind === "video")) elsewhere.push({ label: "Set as wallpaper", icon: "wallpaper", run: () => view.setWallpaper(one.path) });
		if (elsewhere.length > 0) {
			out.push({ separator: true });
			for (const entry of elsewhere) out.push(entry);
		}

		out.push({ separator: true });
		if (one && root.isArchive(one)) out.push({ label: "Extract here", icon: "package_variant", run: () => Files.extract(one.path, pane.isFolder ? pane.location.path : Files.parentOf(one.path)) });
		out.push({ label: rows.length === 1 && one.dir ? `Pack “${one.name}” as ZIP` : "Pack as ZIP", icon: "zip_box_outline", run: () => Files.compress(paths) });
		if (one?.dir) {
			out.push({ label: "Open a terminal here", icon: "console", shortcut: "F4", run: () => Files.terminal(one.path) });
			if (root.agents) out.push({ label: "Claude Code here", icon: "robot_outline", run: () => Files.agent(one.path) });
		}

		out.push({ separator: true });
		out.push({ label: "Move to the trash", icon: "trash_can_outline", danger: true, shortcut: "Del", run: () => Files.trash(paths) });
		out.push({ label: "Properties", icon: "information_outline", shortcut: "Alt+Enter", run: () => view.showDetails(true) });
		return out;
	}

	function openWith(row, done) {
		Files.request("apps", { path: row.path }, data => {
			const apps = data?.apps ?? [];
			const entries = apps.map(app => ({
				label: app.name + (app.default ? "  ·  default" : ""),
				image: AppIcons.resolveIconSource(app.icon),
				run: () => Files.launch([row.path], app.id)
			}));
			if (apps.length > 1) {
				entries.push({ separator: true });
				entries.push({ label: "Always open with", icon: "check_decagram_outline", children: apps.filter(app => !app.default).map(app => ({
					label: app.name,
					image: AppIcons.resolveIconSource(app.icon),
					run: () => Files.setDefaultApp(row.path, app.id)
				})) });
			}
			if (entries.length === 0) entries.push({ label: "No app opens this", enabled: false });
			done(entries);
		});
	}

	function tagEntries(paths) {
		const out = FileLibrary.tags.map(tag => ({
			label: tag.name,
			icon: "tag",
			checked: paths.every(path => FileLibrary.hasTag(path, tag.id)),
			run: () => FileLibrary.toggleTag(paths, tag.id)
		}));
		out.push({ separator: true });
		out.push({ label: "New tag…", icon: "tag_plus_outline", run: () => root.view.ask("New tag", "Name of the tag", "", name => {
			const id = FileLibrary.addTag(name);
			if (id) FileLibrary.toggleTag(paths, id);
		}) });
		return out;
	}

	function collectionEntries(paths) {
		const out = FileLibrary.collections.map(collection => ({
			label: collection.name,
			icon: "bookmark_box_multiple_outline",
			checked: paths.every(path => collection.paths.includes(path)),
			run: () => FileLibrary.addToCollection(collection.id, paths)
		}));
		if (out.length > 0) out.push({ separator: true });
		out.push({ label: "New collection…", icon: "bookmark_plus_outline", run: () => root.view.ask("New collection", "Name of the collection", "", name => {
			FileLibrary.newCollection(name, paths);
			Sounds.play("pinned");
		}) });
		return out;
	}

	// ── what a place can do (a right click on its empty space) ─────────────
	function forPlace(pane) {
		const view = root.view;
		const folder = pane.isFolder ? pane.location.path : "";
		const out = [];
		if (pane.location.kind === "trash") {
			out.push({ label: "Empty the trash", icon: "delete_sweep_outline", danger: true, run: () => Files.emptyTrash() });
			out.push({ separator: true });
		}
		if (folder !== "" && pane.writable) {
			out.push({ label: "New folder", icon: "folder_plus_outline", shortcut: "Ctrl+Shift+N", run: () => Files.makeFolder(folder, "New folder") });
			out.push({ label: "New file", icon: "file_plus_outline", children: [
				{ label: "Text file", icon: "text_box_outline", shortcut: "Ctrl+Alt+N", run: () => Files.makeFile(folder, "New file.txt", "") },
				{ label: "Markdown note", icon: "language_markdown_outline", run: () => Files.makeFile(folder, "Note.md", "# Note\n\n") },
				{ label: "Shell script", icon: "console", run: () => Files.makeFile(folder, "script.sh", "#!/usr/bin/env bash\nset -euo pipefail\n\n") }
			] });
			out.push({ label: "Paste", icon: "content_paste", shortcut: "Ctrl+V", run: () => Files.paste(folder) });
			out.push({ separator: true });
		}
		if (pane.rows.length > 0) out.push({ label: "Pick all", icon: "select_all", shortcut: "Ctrl+A", run: () => pane.selectAll() });
		out.push({ label: "View", icon: "eye_outline", children: () => root.viewEntries(pane) });
		out.push({ separator: true });
		if (folder !== "") {
			out.push({ label: FileLibrary.isFavorite(folder) ? "Remove from favorites" : "Add to favorites", icon: FileLibrary.isFavorite(folder) ? "star_off_outline" : "star_outline", shortcut: "Ctrl+D", run: () => FileLibrary.toggleFavorite(folder) });
			out.push({ label: "Open a terminal here", icon: "console", shortcut: "F4", run: () => Files.terminal(folder) });
			if (root.agents) out.push({ label: "Claude Code here", icon: "robot_outline", run: () => Files.agent(folder) });
			out.push({ label: "Copy the path", icon: "clipboard_text_outline", run: () => Files.copyText(folder, "Path copied") });
		}
		out.push({ label: view.tab.split ? "Close the split" : "Split", icon: "view_split_vertical", shortcut: "F3", run: () => view.tab.toggleSplit() });
		out.push({ label: "Read again", icon: "refresh", shortcut: "Ctrl+R", run: () => pane.reload(false) });
		return out;
	}

	function viewEntries(pane) {
		const path = pane.isFolder ? pane.location.path : `:${pane.location.kind}`;
		const set = changes => FileLibrary.setView(path, changes);
		return [
			{ header: "Show as" },
			{ label: "Cards", icon: "view_grid_outline", checked: pane.mode === "grid", shortcut: "Ctrl+1", run: () => set({ mode: "grid" }) },
			{ label: "List", icon: "view_list_outline", checked: pane.mode === "list", shortcut: "Ctrl+2", run: () => set({ mode: "list" }) },
			{ header: "Sort by" },
			{ label: "Name", checked: pane.sort === "name", run: () => set({ sort: "name", desc: false }) },
			{ label: "Modified", checked: pane.sort === "modified", run: () => set({ sort: "modified", desc: true }) },
			{ label: "Size", checked: pane.sort === "size", run: () => set({ sort: "size", desc: true }) },
			{ label: "Kind", checked: pane.sort === "kind", run: () => set({ sort: "kind", desc: false }) },
			{ label: pane.desc ? "Descending" : "Ascending", icon: pane.desc ? "sort_descending" : "sort_ascending", run: () => set({ desc: !pane.desc }) },
			{ header: "Group by" },
			{ label: "Nothing", checked: pane.group === "none", run: () => set({ group: "none" }) },
			{ label: "Kind", checked: pane.group === "kind", run: () => set({ group: "kind" }) },
			{ label: "Date", checked: pane.group === "date", run: () => set({ group: "date" }) },
			{ label: "Size", checked: pane.group === "size", run: () => set({ group: "size" }) },
			{ separator: true },
			{ label: "Hidden files", checked: !!FileLibrary.view.hidden, shortcut: "Ctrl+H", run: () => FileLibrary.setView("", { hidden: !FileLibrary.view.hidden }) },
			{ label: "Folders first", checked: FileLibrary.view.foldersFirst !== false, run: () => {
				FileLibrary.setView("", { foldersFirst: FileLibrary.view.foldersFirst === false });
				pane.arrange(false);
			} }
		];
	}

	// ── the palette: everything above, and places to go ────────────────────
	function palette(pane) {
		const view = root.view;
		const out = [];
		// a header of a menu ("Sort by") becomes part of the names under it
		const flatten = (entries, group, prefix) => {
			let header = prefix;
			for (const entry of entries) {
				if (entry.header) {
					header = entry.header;
					continue;
				}
				if (entry.separator || entry.enabled === false) continue;
				// submenus made on the spot are taken in when they need no answer to wait for
				const children = typeof entry.children === "function" && entry.children.length === 0 ? entry.children() : entry.children;
				if (Array.isArray(children)) flatten(children, group, entry.label);
				else if (typeof entry.run === "function") out.push({ label: header ? `${header}: ${entry.label}` : entry.label, icon: entry.icon || (entry.checked ? "check" : "circle_small"), shortcut: entry.shortcut || "", group: group, run: entry.run });
			}
		};
		const picked = pane.targets();
		if (picked.length > 0) flatten(root.forRows(pane, picked), picked.length === 1 ? picked[0].name : `${picked.length} picked`, "");
		flatten(root.forPlace(pane), pane.title, "");
		if (Files.undoTitle !== "") out.push({ label: `Undo ${Files.undoTitle.charAt(0).toLowerCase()}${Files.undoTitle.slice(1)}`, icon: "undo", shortcut: "Ctrl+Z", group: "Edit", run: () => Files.undo() });
		out.push({ label: "New tab", icon: "tab_plus", shortcut: "Ctrl+T", group: "Window", run: () => view.newTab({ kind: "home" }, true) });
		out.push({ label: FileLibrary.view.sidebar === false ? "Show the sidebar" : "Hide the sidebar", icon: "dock_left", shortcut: "Ctrl+B", group: "Window", run: () => FileLibrary.setView("", { sidebar: FileLibrary.view.sidebar === false }) });
		out.push({ label: view.detailsOpen ? "Hide the details" : "Show the details", icon: "dock_right", shortcut: "Ctrl+I", group: "Window", run: () => view.showDetails(!view.detailsOpen) });
		out.push({ label: "Search everywhere", icon: "magnify", shortcut: "Ctrl+F", group: "Window", run: () => view.focusSearch() });
		// places
		const go = (label, icon, location) => out.push({ label: label, icon: icon, group: "Go to", run: () => pane.go(location) });
		go("Home", "home_variant_outline", { kind: "home" });
		go("Recent", "history", { kind: "recent" });
		go("Trash", "trash_can_outline", { kind: "trash" });
		go("Home folder", "home_outline", { kind: "dir", path: Files.home });
		for (const name of ["Desktop", "Documents", "Downloads", "Pictures", "Videos", "Music"])
			go(name, "folder_outline", { kind: "dir", path: `${Files.home}/${name}` });
		for (const path of FileLibrary.favorites) go(Files.nameOf(path), "star_outline", { kind: "dir", path: path });
		for (const tag of FileLibrary.tags) go(`Files tagged ${tag.name}`, "tag_outline", { kind: "tag", id: tag.id });
		for (const collection of FileLibrary.collections) go(collection.name, "bookmark_box_multiple_outline", { kind: "collection", id: collection.id });
		for (const place of Files.places.filter(place => place.mounted && place.path)) go(place.name, "harddisk", { kind: "dir", path: place.path });
		// folders visited in this tab
		const seen = new Set();
		for (const entry of pane.back.slice().reverse()) {
			const loc = entry.location;
			if (loc.kind !== "dir" || seen.has(loc.path)) continue;
			seen.add(loc.path);
			go(Files.pretty(loc.path), "history", loc);
		}
		return out;
	}
}
