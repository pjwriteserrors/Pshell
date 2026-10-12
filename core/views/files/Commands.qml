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

		if (kind === "phone") return root.phoneEntries(pane, rows);
		if (kind === "clipboard") return root.clipEntries(pane, rows);
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
		if (Plugins.on("todos")) elsewhere.push({ label: "Remember as a task", icon: "checkbox_marked_circle_plus_outline", children: () => root.taskEntries(paths) });
		if (Plugins.on("ssh")) elsewhere.push({ label: "Send to a server…", icon: "server_network", run: () => root.view.sendToServer(rows) });
		if (Phone.available) elsewhere.push({ label: `Send to ${Phone.name}`, icon: "cellphone_arrow_down", run: () => files.forEach(row => Phone.shareFile(row.path)), enabled: files.length > 0 });
		if (root.ai && files.length > 0 && files.length <= 6) elsewhere.push({ label: files.length === 1 ? "Ask AI about it" : "Ask AI about them", icon: "creation", run: () => view.askAi(files) });
		if (root.reader && texts.length === 1) elsewhere.push({ label: "Speed-read it", icon: "book_open_page_variant", run: () => view.speedRead(texts[0]) });
		if (images.length > 0 && images.length === files.length) {
			elsewhere.push({ label: images.length === 1 ? "Name it by what it shows" : "Name them by what they show", icon: "creation", run: () => Files.startJob("ainame", { paths: images.map(row => row.path) }, job => {
				if (job.state === "failed") Files.fail(job.error);
			}) });
			elsewhere.push({ label: "Text from it as a .txt beside it", icon: "text_recognition", run: () => Files.startJob("capturetext", { paths: images.map(row => row.path) }) });
		}
		const clips = files.filter(row => row.kind === "video");
		if (one && clips.length === 1) {
			elsewhere.push({ label: "Cut the recording…", icon: "content_cut", run: () => view.trim(one.path, "cut") });
			elsewhere.push({ label: "Make a GIF…", icon: "file_gif_box", run: () => view.trim(one.path, "gif") });
		}
		if (images.length === 1) {
			if (root.captures) elsewhere.push({ label: "Annotate", icon: "draw", run: () => Screenshot.editShot(images[0].path) });
			if (root.pins) elsewhere.push({ label: "Pin to the screen", icon: "pin_outline", run: () => Screenshot.pinShot(images[0].path) });
			if (root.ocr) elsewhere.push({ label: "Copy text from it", icon: "text_recognition", run: () => Screenshot.runOcr(images[0].path, null, false) });
		}
		if (root.wallpaper && one && (one.kind === "image" || one.kind === "video")) elsewhere.push({ label: "Set as wallpaper", icon: "wallpaper", run: () => view.setWallpaper(one.path) });
		elsewhere.push({ label: "Share a link…", icon: "link_variant", run: () => view.shareDialog(rows) });
		if (elsewhere.length > 0) {
			out.push({ separator: true });
			for (const entry of elsewhere) out.push(entry);
		}

		// Windows programs, PDFs, a second opinion on files
		const special = [];
		if (one && Kinds.isWindows(one)) {
			special.push({ label: "Run with", icon: "microsoft_windows", children: done => Files.knowRunners(() => done(root.runnerEntries(one))) });
			special.push({ label: "Add to Steam…", icon: "steam", run: () => root.view.ask("Name in the Steam library", "Name", one.name.replace(/\.[^.]+$/, ""), name => Files.addToSteam(one.path, name, FileLibrary.setting("protonVersion"))) });
		}
		const pdfs = files.filter(row => row.mime === "application/pdf");
		if (pdfs.length > 0) special.push({ label: "PDF tools", icon: "file_pdf_box", children: () => root.pdfEntries(rows, pdfs) });
		else if (images.length > 0 && images.length === files.length) special.push({ label: images.length === 1 ? "Make a PDF of it" : "Make one PDF of them", icon: "file_pdf_box", run: () => Files.pdfTool("fromimages", images.map(row => row.path), {}) });
		else if (files.length > 0 && files.every(row => /\.(docx?|odt|rtf|xlsx?|ods|pptx?|odp)$/i.test(row.name))) special.push(root.pdfEntry("officetopdf", "Make a PDF", "file_pdf_box", files));
		else if (files.length > 0 && files.every(row => /\.html?$/i.test(row.name))) special.push(root.pdfEntry("htmltopdf", "Make a PDF", "file_pdf_box", files));
		if (one && Kinds.isWeblink(one)) special.push({ label: "Copy the link", icon: "link_variant", run: () => Files.request("info", { path: one.path }, data => { if (data?.url) Files.copyText(data.url, "Link copied"); }) });
		if (images.length > 0 && images.length === files.length && dirs.length === 0) special.push({ label: images.length === 1 ? "Edit the picture" : "Edit the pictures", icon: "image_edit_outline", children: () => root.imageEntries(images) });
		const songs = files.filter(row => row.kind === "audio");
		if (one && songs.length === 1) special.push({ label: "Edit the tags…", icon: "tag_text_outline", run: () => view.tagsDialog(one) });
		const media = files.filter(row => row.kind === "image" || row.kind === "video" || row.kind === "audio");
		if (media.length > 0 && media.length === files.length && dirs.length === 0) special.push({ label: "Convert to", icon: "swap_horizontal", children: done => Files.convertible(root.paths(files), targets => done(root.convertEntries(files, targets))) });
		special.push({ label: "Scan for viruses (on this PC)", icon: "shield_search", run: () => Files.avScan(paths) });
		if (files.length > 0 && files.length <= 20 && dirs.length === 0) special.push({ label: "Check with VirusTotal", icon: "shield_search", run: () => Files.vtScan(root.paths(files)) });
		if (special.length > 0) {
			out.push({ separator: true });
			for (const entry of special) out.push(entry);
		}

		// git: what changed, a commit, the history
		const git = pane.git;
		if (git && pane.isFolder) {
			const changed = rows.filter(row => git.files?.[row.name]);
			if (changed.length > 0) {
				out.push({ separator: true });
				out.push({ label: changed.length === 1 ? `Commit ${changed[0].name}…` : `Commit ${changed.length} items…`, icon: "source_commit", run: () => view.commitDialog(changed.map(row => row.path), changed.length === 1 ? changed[0].name : `${changed.length} items`) });
				if (changed.length === 1) out.push({ label: "Show the changes", icon: "file_compare", run: () => view.showDiff(changed[0].path) });
			}
		}
		if (one && !one.dir && kind !== "trash") out.push({ label: "Earlier versions", icon: "history", run: () => view.showVersions() });
		if (one && !one.dir && (Files.index.files ?? 0) > 0) out.push({ label: "Find similar files", icon: "approximately_equal", run: () => pane.go({ kind: "similar", path: one.path }) });

		out.push({ separator: true });
		if (one && root.isArchive(one)) out.push({ label: "Extract here", icon: "package_variant", run: () => Files.extract(one.path, pane.isFolder ? pane.location.path : Files.parentOf(one.path)) });
		out.push({ label: rows.length === 1 && one.dir ? `Pack “${one.name}” as ZIP` : "Pack as ZIP", icon: "zip_box_outline", run: () => Files.compress(paths) });
		if (one?.dir) {
			out.push({ label: "Look at it", icon: "chart_donut", children: [
				{ label: "What takes the space", icon: "chart_donut", run: () => pane.go({ kind: "storage", path: one.path }) },
				{ label: "Find copies in it", icon: "content_duplicate", run: () => pane.go({ kind: "duplicates", path: one.path }) },
				{ label: "Make a rule for it…", icon: "playlist_check", run: () => view.ruleDialog(null, one.path) }
			] });
			out.push({ label: "Open a terminal here", icon: "console", shortcut: "F4", run: () => Files.terminal(one.path) });
			if (root.agents) out.push({ label: "Claude Code here", icon: "robot_outline", run: () => Files.agent(one.path) });
		}

		out.push({ separator: true });
		out.push({ label: "Move to the trash", icon: "trash_can_outline", danger: true, shortcut: "Del", run: () => Files.trash(paths) });
		out.push({ label: "Properties", icon: "information_outline", shortcut: "Alt+Enter", run: () => view.showDetails(true) });
		return out;
	}

	// the todo lists a file can go into as a task (with a link back)
	function taskEntries(paths) {
		const last = String(FileLibrary.setting("taskList") || "");
		const out = Todos.lists.map(list => ({
			label: list.name,
			icon: list.path === last ? "star_outline" : "format_list_checks",
			hint: `${list.total - list.done} open`,
			run: () => Files.rememberTask(paths, list.path)
		}));
		if (out.length > 0) out.push({ separator: true });
		out.push({ label: "With a note…", icon: "note_edit_outline", enabled: Todos.lists.length > 0, run: () => root.view.ask("What is to do with it?", "Note for the task", "", note => Files.rememberTask(paths, last || Todos.lists[0].path, note)) });
		out.push({ label: "New list…", icon: "playlist_plus", run: () => root.view.ask("New todo list", "Name of the list", "Files", name => Files.rememberTask(paths, name)) });
		return out;
	}

	// entries of the clipboard history: files in the runtime folder, newest first
	function clipEntries(pane, rows) {
		const view = root.view;
		const own = rows.filter(row => row.clipId !== "" && row.clipKind !== "files");
		const out = [];
		out.push({ label: rows.length === 1 ? "Open" : `Open ${rows.length} items`, icon: "open_in_app", shortcut: "Enter", run: () => Files.launch(rows.map(row => row.path)) });
		out.push({ label: "Quick look", icon: "eye_outline", shortcut: "Space", run: () => view.quickLook(pane) });
		if (rows.length === 1 && rows[0].clipId !== "") out.push({ label: "Put on the clipboard again", icon: "clipboard_arrow_left_outline", run: () => Files.request("cliprestore", { clip: rows[0].clipId }, () => Files.say("On the clipboard again", "content_paste")) });
		out.push({ separator: true });
		out.push({ label: "Save to Downloads", icon: "download", run: () => Files.transfer(rows.map(row => row.path), `${Files.home}/Downloads`, "copy") });
		if (view.tab.split && view.tab.other.isFolder) out.push({ label: `Save to ${view.tab.other.title}`, icon: "dock_right", run: () => Files.transfer(rows.map(row => row.path), view.tab.other.location.path, "copy") });
		out.push({ label: "Save to…", icon: "content_save_outline", run: () => view.ask("Save to which folder?", "Folder", `${Files.home}/Documents`, folder => Files.transfer(rows.map(row => row.path), folder.replace(/^~/, Files.home), "copy")) });
		if (root.ai && own.length > 0 && own.length <= 6) out.push({ label: "Ask AI about it", icon: "creation", run: () => view.askAi(own) });
		out.push({ separator: true });
		out.push({ label: rows.length === 1 ? "Remove from the history" : `Remove ${rows.length} from the history`, icon: "delete_outline", danger: true, shortcut: "Del", run: () => Files.request("clipdelete", { clips: rows.map(row => row.clipId).filter(clip => clip !== "") }, () => pane.reload(false)) });
		return out;
	}

	// files of the phone: they come over first, opened or imported
	function phoneEntries(pane, rows) {
		const entries = rows.map(row => Object.assign({ phoneId: row.path.slice(6) }, row));
		const out = [];
		out.push({ label: rows.length === 1 ? "Open" : `Open ${rows.length} files`, icon: "open_in_app", shortcut: "Enter", run: () => rows.forEach(row => root.view.openElsewhere(pane, row)) });
		out.push({ separator: true });
		out.push({ label: `Import to ${Files.pretty(PhoneDrive.importFolder())}`, icon: "cellphone_arrow_down", run: () => PhoneDrive.importEntries(entries) });
		out.push({ label: "Import to Downloads", icon: "download", run: () => PhoneDrive.importEntries(entries, `${Files.home}/Downloads`) });
		if (root.view.tab.split && root.view.tab.other.isFolder) out.push({ label: `Import to ${root.view.tab.other.title}`, icon: "dock_right", run: () => PhoneDrive.importEntries(entries, root.view.tab.other.location.path) });
		out.push({ label: "Import to…", icon: "folder_arrow_down_outline", run: () => root.view.ask("Import to which folder?", "Folder", PhoneDrive.importFolder(), folder => PhoneDrive.importEntries(entries, folder.replace(/^~/, Files.home))) });
		return out;
	}

	// quick changes to pictures: each makes a new one beside it (or replaces it, asked in the dialogs)
	function imageEntries(images) {
		const paths = images.map(row => row.path);
		const one = images.length === 1 ? images[0] : null;
		return [
			{ label: "Resize…", icon: "resize", run: () => root.view.resizeDialog(images) },
			{ label: "Crop…", icon: "crop", enabled: !!one, run: () => root.view.crop(one.path) },
			{ label: "Turn left", icon: "rotate_left", run: () => Files.imageTool("rotate", paths, { degrees: 270 }) },
			{ label: "Turn right", icon: "rotate_right", run: () => Files.imageTool("rotate", paths, { degrees: 90 }) },
			{ label: "Mirror", icon: "flip_horizontal", run: () => Files.imageTool("flip", paths, { axis: "horizontal" }) },
			{ separator: true },
			{ label: "Remove location and camera data", icon: "map_marker_off_outline", run: () => Files.imageTool("strip", paths, {}) },
			{ label: "Watermark…", icon: "water_outline", run: () => root.view.watermarkDialog(images) }
		];
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

	// the formats of the same kind, videos also to their sound
	function convertEntries(rows, targets) {
		const out = [];
		let kind = "";
		for (const target of targets) {
			if (target.kind !== kind) {
				kind = target.kind;
				out.push({ header: kind === "video" ? "Video" : (kind === "audio" ? "Audio" : "Picture") });
			}
			out.push({ label: target.label, icon: kind === "video" ? "filmstrip" : (kind === "audio" ? "music_note" : "image_outline"), run: () => Files.convert(root.paths(rows), target.format) });
		}
		if (out.length === 0) out.push({ label: "Nothing to convert these to", enabled: false });
		return out;
	}

	function runnerEntries(row) {
		const out = Files.runners.map(runner => ({
			label: runner.name,
			icon: runner.kind === "wine" ? "glass_wine" : "steam",
			run: () => Files.runWindows(row.path, runner.id)
		}));
		if (out.length === 0) out.push({ label: "Neither Proton nor Wine is installed", enabled: false });
		return out;
	}

	function pdfEntry(tool, label, icon, rows, extra) {
		const missing = Files.pdfMissing[tool];
		return Object.assign({ label: label, icon: icon, enabled: !missing, hint: missing ? `needs ${missing}` : "", run: () => root.view.pdfTool(tool, rows) }, extra || {});
	}

	// everything a PDF can go through (iLovePDF's tools, here on the machine)
	function pdfEntries(rows, pdfs) {
		const one = pdfs.length === 1;
		const mergeable = rows.filter(row => row.mime === "application/pdf" || row.kind === "image");
		const out = [];
		out.push({ header: "Pages" });
		if (mergeable.length > 1) out.push(root.pdfEntry("merge", `Merge ${mergeable.length} into one…`, "call_merge", mergeable));
		out.push(root.pdfEntry("split", "Split…", "call_split", pdfs));
		out.push(root.pdfEntry("extract", "Take pages out…", "file_move_outline", pdfs));
		out.push(root.pdfEntry("remove", "Remove pages…", "file_remove_outline", pdfs));
		out.push(root.pdfEntry("rotate", "Rotate…", "rotate_right", pdfs));
		if (one) out.push(root.pdfEntry("organize", "Organize pages…", "view_grid_outline", pdfs));
		out.push({ header: "On the pages" });
		out.push(root.pdfEntry("pagenumbers", "Page numbers…", "format_list_numbered", pdfs));
		out.push(root.pdfEntry("watermark", "Watermark…", "water_outline", pdfs));
		if (one) out.push(root.pdfEntry("sign", "Sign…", "draw_pen", pdfs));
		out.push(root.pdfEntry("redact", "Black out words…", "eye_off_outline", pdfs));
		out.push(root.pdfEntry("crop", "Crop the margins", "crop", pdfs));
		out.push(root.pdfEntry("flatten", "Flatten forms and notes", "layers_outline", pdfs));
		out.push(root.pdfEntry("grayscale", "Grayscale", "format_color_fill", pdfs));
		out.push({ header: "Convert" });
		out.push(root.pdfEntry("toimages", "To pictures…", "image_multiple_outline", pdfs));
		out.push(root.pdfEntry("totext", "To text", "text_box_outline", pdfs));
		out.push(root.pdfEntry("tooffice", "To Word…", "file_word_outline", pdfs));
		out.push(root.pdfEntry("imagesout", "Take the pictures out", "file_image_outline", pdfs));
		out.push(root.pdfEntry("pdfa", "To PDF/A (for archiving)", "archive", pdfs));
		out.push({ header: "Size, safety, repair" });
		out.push(root.pdfEntry("compress", "Compress…", "arrow_collapse_vertical", pdfs));
		out.push(root.pdfEntry("protect", "Lock with a password…", "lock_outline", pdfs));
		out.push(root.pdfEntry("unlock", "Remove the password…", "lock_open_variant_outline", pdfs));
		out.push(root.pdfEntry("ocr", "Make the text searchable (OCR)", "text_recognition", pdfs));
		out.push(root.pdfEntry("repair", "Repair", "wrench_outline", pdfs));
		if (one) out.push(root.pdfEntry("metadata", "Title and author…", "information_variant", pdfs));
		if (pdfs.length === 2) out.push(root.pdfEntry("compare", "Compare the two", "file_compare", pdfs));
		return out;
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
			out.push({ label: "Scan this folder for viruses", icon: "shield_search", run: () => Files.avScan([folder]) });
			out.push({ label: "Look at it", icon: "chart_donut", children: [
				{ label: "What takes the space here", icon: "chart_donut", run: () => pane.go({ kind: "storage", path: folder }) },
				{ label: "Find copies here", icon: "content_duplicate", run: () => pane.go({ kind: "duplicates", path: folder }) },
				{ label: "Make a rule for this folder…", icon: "playlist_check", run: () => view.ruleDialog(null, folder) },
				{ label: "New vault here…", icon: "safe_square_outline", enabled: pane.writable, run: () => view.newVault(folder) }
			] });
			if (pane.git) out.push({ label: "Git", icon: "source_branch", children: () => view.gitMenu(pane) });
		}
		if (view.tab.split && view.tab.first.isFolder && view.tab.second.isFolder) {
			out.push(pane.compareStates ? { label: "Stop comparing", icon: "file_compare", run: () => view.stopComparing() }
				: { label: "Compare with the other side", icon: "file_compare", shortcut: "F7", run: () => view.compareSides() });
			out.push({ label: "Sync with the other side…", icon: "folder_sync_outline", run: () => view.openSync(pane) });
		}
		out.push({ label: view.tab.split ? "Close the split" : "Split", icon: "view_split_vertical", shortcut: "F3", run: () => view.tab.toggleSplit() });
		out.push({ label: "Read again", icon: "refresh", shortcut: "Ctrl+R", run: () => pane.reload(false) });
		return out;
	}

	function viewEntries(pane) {
		const path = pane.viewKey;
		const set = changes => FileLibrary.setView(path, changes);
		const own = key => FileLibrary.scopeOf(path, key) === "here";
		return [
			{ header: "Show as" },
			{ label: "Cards", icon: "view_grid_outline", checked: pane.mode === "grid", shortcut: "Ctrl+1", run: () => root.view.setMode(pane, "grid") },
			{ label: "List", icon: "view_list_outline", checked: pane.mode === "list", shortcut: "Ctrl+2", run: () => root.view.setMode(pane, "list") },
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
			{ header: "Keep for this folder only" },
			{ label: "Layout", checked: own("mode"), run: () => FileLibrary.setScope(path, "mode", own("mode") ? "everywhere" : "here") },
			{ label: "Order", checked: own("sort"), run: () => FileLibrary.setScope(path, "sort", own("sort") ? "everywhere" : "here") },
			{ label: "Groups", checked: own("group"), run: () => FileLibrary.setScope(path, "group", own("group") ? "everywhere" : "here") },
			{ separator: true },
			{ label: "Hidden files", checked: !!FileLibrary.view.hidden, shortcut: "Ctrl+H", run: () => FileLibrary.setView("", { hidden: !FileLibrary.view.hidden }) },
			{ label: "Folders first", checked: FileLibrary.view.foldersFirst !== false, run: () => {
				FileLibrary.setView("", { foldersFirst: FileLibrary.view.foldersFirst === false });
				pane.arrange(false);
			} },
			{ label: "Default card size", icon: "restore", enabled: (FileLibrary.view.cardSize || 172) !== 172, run: () => FileLibrary.setView("", { cardSize: 172 }) }
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
		out.push({ label: "Ask your files…", icon: "creation", group: "Window", run: () => view.ask("What are you looking for?", "the Telekom invoice from the spring", "", query => pane.go({ kind: "search", path: Files.home, query: query, ai: true })) });
		out.push({ label: "Undo history", icon: "history", shortcut: "Ctrl+Shift+Z", group: "Edit", run: () => view.openHistory() });
		out.push({ label: "Rules for folders", icon: "playlist_check", group: "Window", run: () => view.openSettings("rules") });
		out.push({ label: "Vaults", icon: "safe_square_outline", group: "Window", run: () => view.openSettings("vaults") });
		out.push({ label: "Shared links", icon: "link_variant", group: "Window", run: () => view.openSettings("sharing") });
		out.push({ label: "New tab", icon: "tab_plus", shortcut: "Ctrl+T", group: "Window", run: () => view.newTab({ kind: "home" }, true) });
		out.push({ label: FileLibrary.view.sidebar === false ? "Show the sidebar" : "Hide the sidebar", icon: "dock_left", shortcut: "Ctrl+B", group: "Window", run: () => FileLibrary.setView("", { sidebar: FileLibrary.view.sidebar === false }) });
		out.push({ label: view.detailsOpen ? "Hide the details" : "Show the details", icon: "dock_right", shortcut: "Ctrl+I", group: "Window", run: () => view.showDetails(!view.detailsOpen) });
		out.push({ label: "Search everywhere", icon: "magnify", shortcut: "Ctrl+F", group: "Window", run: () => view.focusSearch() });
		out.push({ label: "Settings", icon: "cog_outline", shortcut: "Ctrl+,", group: "Window", run: () => view.openSettings("") });
		out.push({ label: "View options", icon: "tune_variant", shortcut: "Ctrl+J", group: "Window", run: () => view.activePaneView()?.viewOptions() });
		// places
		const go = (label, icon, location) => out.push({ label: label, icon: icon, group: "Go to", run: () => pane.go(location) });
		go("Home", "home_variant_outline", { kind: "home" });
		go("Recent", "history", { kind: "recent" });
		go("Trash", "trash_can_outline", { kind: "trash" });
		if (Plugins.on("clipboard")) go("Clipboard history", "clipboard_text_multiple_outline", { kind: "clipboard" });
		if (Plugins.on("screenshot") || Plugins.on("recording")) go("Captures", "camera_outline", { kind: "captures" });
		if (PhoneDrive.enabled) for (const entry of PhoneDrive.collections) go(`${entry.label} on ${PhoneDrive.name}`, entry.icon, { kind: "phone", id: entry.id });
		go("What takes the space in your home", "chart_donut", { kind: "storage", path: Files.home });
		go("Copies in your home", "content_duplicate", { kind: "duplicates", path: Files.home });
		for (const search of FileLibrary.searches) go(search.name, "magnify", { kind: "search", path: search.path, query: search.query, contents: search.contents });
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
