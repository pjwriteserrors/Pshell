pragma ComponentBehavior: Bound

import QtQuick
import qs.core.services
import "FileKinds.js" as Kinds
import "../../lib/AiIntents.js" as Intents

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
	// The menu stays short: opening, the clipboard, one submenu for what this
	// kind of file can do (also behind the button in the preview), sorting
	// it away, sending it, the rest under "More".
	function forRows(pane, rows) {
		if (rows.length === 0) return root.forPlace(pane);
		const one = rows.length === 1 ? rows[0] : null;
		const dirs = rows.filter(row => row.dir);
		const files = rows.filter(row => !row.dir);
		const songs = files.filter(row => row.kind === "audio");
		const kind = pane.location.kind;
		const paths = root.paths(rows);
		const view = root.view;
		const out = [];

		if (kind === "phone") return root.phoneEntries(pane, rows);
		if (kind === "pc") return root.pcEntries(pane, rows);
		if (kind === "clipboard") return root.clipEntries(pane, rows);
		if (kind === "trash") {
			out.push({ label: rows.length === 1 ? "Restore" : `Restore ${rows.length} items`, icon: "restore", run: () => Files.restore(rows) });
			out.push({ label: "Delete for good", icon: "delete_forever_outline", danger: true, shortcut: "Shift+Del", run: () => Files.remove(paths) });
			out.push({ separator: true });
			out.push({ label: "Quick look", icon: "eye_outline", shortcut: "Space", run: () => view.quickLook(pane) });
			return out;
		}

		// open
		out.push({ label: one ? "Open" : `Open ${rows.length} items`, icon: "open_in_app", shortcut: "Enter", run: () => view.openRows(pane, rows, false) });
		if (dirs.length > 0) out.push({ label: dirs.length === 1 ? "Open in a new tab" : "Open in new tabs", icon: "tab_plus", shortcut: "Ctrl+Enter", run: () => dirs.forEach(row => view.newTab({ kind: "dir", path: row.path }, true)) });
		if (one?.dir && view.tab.split) out.push({ label: "Open in the other pane", icon: "dock_right", run: () => view.tab.other.openFolder(one.path) });
		if (one && !one.dir) out.push({ label: "Open with", icon: "apps", children: done => root.openWith(one, done) });
		if (songs.length > 0 && songs.length === files.length) {
			out.push({ label: songs.length === 1 ? "Play" : `Play ${songs.length}`, icon: "play_outline", run: () => Files.play(root.paths(songs), false) });
			if (Files.music.playing) out.push({ label: "Add to the queue", icon: "playlist_plus", run: () => Files.play(root.paths(songs), true) });
		}
		if (pane.virtual) out.push({ label: "Show in its folder", icon: "folder_search_outline", run: () => view.revealIn(pane, paths) });
		out.push({ label: "Quick look", icon: "eye_outline", shortcut: "Space", run: () => view.quickLook(pane) });
		if (one?.dir) {
			out.push({ label: "Open a terminal here", icon: "console", shortcut: "F4", run: () => Files.terminal(one.path) });
			if (root.agents) out.push({ label: "Claude Code here", icon: "robot_outline", run: () => Files.agent(one.path) });
		}

		// the clipboard and the name
		out.push({ separator: true });
		out.push({ label: "Cut", icon: "content_cut", shortcut: "Ctrl+X", run: () => Files.clipboardSet(paths, true) });
		out.push({ label: "Copy", icon: "content_copy", shortcut: "Ctrl+C", run: () => Files.clipboardSet(paths, false) });
		if (one?.dir) out.push({ label: "Paste into it", icon: "content_paste", run: () => Files.paste(one.path) });
		out.push({ label: "Copy path", icon: "clipboard_text_outline", shortcut: "Ctrl+Shift+C", run: () => Files.copyText(paths.join("\n"), rows.length === 1 ? "Path copied" : `${rows.length} paths copied`) });
		out.push({ label: "Duplicate", icon: "content_duplicate", run: () => Files.duplicate(paths) });
		out.push({ label: rows.length === 1 ? "Rename" : `Rename ${rows.length} items`, icon: "form_textbox", shortcut: "F2", run: () => view.rename(pane, rows) });

		// what this kind of file can do
		out.push({ separator: true });
		const own = root.kindMenu(pane, rows);
		if (own) out.push(own.entries.length === 1 ? own.entries[0] : { label: own.label, icon: own.icon, children: own.entries });
		if (one && root.isArchive(one)) out.push({ label: "Extract here", icon: "package_variant", run: () => Files.extract(one.path, pane.isFolder ? pane.location.path : Files.parentOf(one.path)) });
		if (one && /\.ics$/i.test(one.name) && MsCalendar.enabled && MsCalendar.signedIn) out.push({ label: "Add to the calendar", icon: "calendar_plus", run: () => Files.importCalendar(one.path) });
		if (one && Kinds.isWeblink(one)) out.push({ label: "Copy the link", icon: "link_variant", run: () => Files.request("info", { path: one.path }, data => { if (data?.url) Files.copyText(data.url, "Link copied"); }) });
		out.push({ label: rows.length === 1 && one.dir ? `Pack “${one.name}” as ZIP` : "Pack as ZIP", icon: "zip_box_outline", run: () => Files.compress(paths) });

		// sorting it away
		out.push({ separator: true });
		if (one?.dir) out.push({ label: FileLibrary.isFavorite(one.path) ? "Remove from favorites" : "Add to favorites", icon: FileLibrary.isFavorite(one.path) ? "star_off_outline" : "star_outline", shortcut: "Ctrl+D", run: () => FileLibrary.toggleFavorite(one.path) });
		out.push({ label: "Tags", icon: "tag_outline", children: () => root.tagEntries(paths) });
		out.push({ label: "Add to a collection", icon: "bookmark_box_multiple_outline", children: () => root.collectionEntries(paths) });
		if (kind === "collection") out.push({ label: "Take out of this collection", icon: "bookmark_remove_outline", run: () => FileLibrary.removeFromCollection(pane.location.id, paths) });
		if (kind === "tag") out.push({ label: `Remove “${pane.title}”`, icon: "tag_remove_outline", run: () => FileLibrary.toggleTag(paths, pane.location.id) });
		if (root.shelves) out.push({ label: "Put on a shelf", icon: "tray_arrow_down", shortcut: "Ctrl+S", run: () => view.toShelf(rows) });
		if (Plugins.on("todos")) out.push({ label: "Remember as a task", icon: "checkbox_marked_circle_plus_outline", children: () => root.taskEntries(paths) });

		// elsewhere: other people, the phone, a server
		const send = root.sendEntries(rows);
		if (send.length > 0) out.push({ label: "Send to", icon: "send", children: send });

		// the rest
		const git = pane.git;
		const changed = git && pane.isFolder ? rows.filter(row => git.files?.[row.name]) : [];
		if (changed.length > 0) out.push({ label: "Git", icon: "source_branch", children: [
			{ label: changed.length === 1 ? `Commit ${changed[0].name}…` : `Commit ${changed.length} items…`, icon: "source_commit", run: () => view.commitDialog(changed.map(row => row.path), changed.length === 1 ? changed[0].name : `${changed.length} items`) },
			{ label: "Show the changes", icon: "file_compare", shown: changed.length === 1, run: () => view.showDiff(changed[0].path) }
		] });
		const more = root.moreEntries(pane, rows);
		if (more.length > 0) out.push({ label: "More", icon: "dots_horizontal", children: more });

		out.push({ separator: true });
		out.push({ label: "Move to the trash", icon: "trash_can_outline", danger: true, shortcut: "Del", run: () => Files.trash(paths) });
		out.push({ label: "Properties", icon: "information_outline", shortcut: "Alt+Enter", run: () => view.showDetails(true) });
		return out;
	}

	// what one kind of file can do, as one submenu: { label, short, icon, entries } or null.
	// The preview and the details show it as a button.
	function kindMenu(pane, rows) {
		const one = rows.length === 1 ? rows[0] : null;
		const dirs = rows.filter(row => row.dir);
		const files = rows.filter(row => !row.dir);
		const all = test => files.length > 0 && dirs.length === 0 && files.every(test);
		const view = root.view;
		if (["trash", "phone", "clipboard"].includes(pane.location.kind)) return null;
		const convert = () => ({ label: "Convert to", icon: "swap_horizontal", children: done => Files.convertible(root.paths(files), targets => done(root.convertEntries(files, targets))) });

		if (one?.dir) return { label: "Folder", short: "Folder", icon: "folder_open_outline", entries: root.folderEntries(pane, one.path) };
		if (all(row => row.kind === "image")) return { label: files.length === 1 ? "Edit the picture" : "Edit the pictures", short: "Edit", icon: "image_edit_outline", entries: root.imageEntries(files) };
		// PDFs, also with pictures to merge them into
		const pdfs = files.filter(row => row.mime === "application/pdf");
		if (pdfs.length > 0 && all(row => row.mime === "application/pdf" || row.kind === "image")) return { label: "PDF tools", short: "PDF tools", icon: "file_pdf_box", entries: root.pdfEntries(rows, pdfs) };
		if (all(row => row.kind === "video")) {
			const entries = [];
			if (one) {
				entries.push({ label: "Cut the recording…", icon: "content_cut", run: () => view.trim(one.path, "cut") });
				entries.push({ label: "Make a GIF…", icon: "file_gif_box", run: () => view.trim(one.path, "gif") });
				if (root.wallpaper) entries.push({ label: "Set as wallpaper", icon: "wallpaper", run: () => view.setWallpaper(one.path) });
			}
			entries.push(convert());
			return { label: files.length === 1 ? "Edit the video" : "Edit the videos", short: "Edit", icon: "filmstrip", entries: entries };
		}
		if (all(row => row.kind === "audio")) {
			const entries = [];
			if (one) entries.push({ label: "Edit the tags…", icon: "tag_text_outline", run: () => view.tagsDialog(one) });
			entries.push(convert());
			return { label: files.length === 1 ? "Edit the song" : "Edit the songs", short: "Edit", icon: "music_note", entries: entries };
		}
		if (all(row => row.kind === "image" || row.kind === "video" || row.kind === "audio")) return { label: "Convert to", short: "Convert", icon: "swap_horizontal", entries: [convert()] };
		if (one && Kinds.isWindows(one)) return { label: "Windows", short: "Run", icon: "microsoft_windows", entries: [
			{ label: "Run with", icon: "play_outline", children: done => Files.knowRunners(() => done(root.runnerEntries(one))) },
			{ label: "Open in the Windows VM", icon: "monitor_shimmer", shown: Plugins.on("vm-launcher"), run: () => Files.openInVm(one.path) },
			{ label: "Add to Games…", icon: "gamepad_variant", shown: Plugins.on("games"), run: () => {
				Popups.openModal("games", Popups.primaryScreen);
				Games.addRequested(one.path);
			} },
			{ label: "Add to Steam…", icon: "steam", run: () => view.ask("Name in the Steam library", "Name", one.name.replace(/\.[^.]+$/, ""), name => Files.addToSteam(one.path, name, FileLibrary.setting("protonVersion"))) }
		] };
		if (all(row => /\.(docx?|odt|rtf|xlsx?|ods|pptx?|odp)$/i.test(row.name))) return { label: "Make a PDF", short: "PDF", icon: "file_pdf_box", entries: [root.pdfEntry("officetopdf", "Make a PDF", "file_pdf_box", files)] };
		if (all(row => /\.html?$/i.test(row.name))) return { label: "Make a PDF", short: "PDF", icon: "file_pdf_box", entries: [root.pdfEntry("htmltopdf", "Make a PDF", "file_pdf_box", files)] };
		return null;
	}

	// a folder: what is in it, its rules, where its terminals open
	function folderEntries(pane, folder, writable) {
		const view = root.view;
		return [
			{ label: "What takes the space", icon: "chart_donut", run: () => pane.go({ kind: "storage", path: folder }) },
			{ label: "Find copies in it", icon: "content_duplicate", run: () => pane.go({ kind: "duplicates", path: folder }) },
			{ label: "Make a rule for it…", icon: "playlist_check", run: () => view.ruleDialog(null, folder) },
			{ label: "New vault in it…", icon: "safe_square_outline", enabled: writable !== false, run: () => view.newVault(folder) },
			{ label: "Its own workspace", icon: "view_dashboard_outline", children: () => root.workspaceEntries(folder) },
			{ label: "Wallpapers from it…", icon: "wallpaper", shown: root.wallpaper, run: () => view.wallpaperFolder(folder) }
		];
	}

	// mail, chats, the phone, a server, a link
	function sendEntries(rows) {
		const files = rows.filter(row => !row.dir);
		const view = root.view;
		const out = [];
		if (Plugins.on("mail") && Mail.accounts.length > 0) out.push({ label: "Mail", icon: "email_outline", run: () => Files.mailFiles(root.paths(rows)) });
		if (Files.recentChats.length > 0 && files.length > 0) out.push({ label: "WhatsApp", icon: "whatsapp", children: () => Files.recentChats.map(chat => ({
			label: chat.name,
			icon: "account_outline",
			run: () => Files.sendToChat(chat, root.paths(files))
		})) });
		if (Phone.available) out.push({ label: Phone.name, icon: "cellphone_arrow_down", enabled: files.length > 0, run: () => files.forEach(row => Phone.shareFile(row.path)) });
		// another PC takes folders as well
		for (const pc of Pcs.reachable) out.push({ label: pc.name, icon: "laptop", run: () => {
			Pcs.sendFiles(pc.id, root.paths(rows));
			Files.say(rows.length === 1 ? `Sending ${rows[0].name} to ${pc.name}` : `Sending ${rows.length} items to ${pc.name}`, "laptop");
		} });
		if (Plugins.on("ssh")) out.push({ label: "A server…", icon: "server_network", run: () => view.sendToServer(rows) });
		if (out.length > 0) out.push({ separator: true });
		out.push({ label: "Share a link…", icon: "link_variant", run: () => view.shareDialog(rows) });
		return out;
	}

	// asking, reading, looking further, checking
	function moreEntries(pane, rows) {
		const one = rows.length === 1 ? rows[0] : null;
		const files = rows.filter(row => !row.dir);
		const texts = files.filter(row => row.text);
		const readable = files.filter(row => row.text || row.mime === "application/pdf");
		const view = root.view;
		const out = [];
		if (root.ai && files.length > 0 && files.length <= 6) out.push({ label: files.length === 1 ? "Ask AI about it" : "Ask AI about them", icon: "creation", run: () => view.askAi(files) });
		if (Plugins.on("translate") && readable.length > 0 && readable.length === files.length) out.push({ label: "Translate…", icon: "translate", run: () => view.translateDialog(readable) });
		if (root.reader && texts.length === 1) out.push({ label: "Speed-read it", icon: "book_open_page_variant", run: () => view.speedRead(texts[0]) });
		if (out.length > 0) out.push({ separator: true });
		if (one && !one.dir) out.push({ label: "Earlier versions", icon: "history", run: () => view.showVersions() });
		if (one && !one.dir && (Files.index.files ?? 0) > 0) out.push({ label: "Find similar files", icon: "approximately_equal", run: () => pane.go({ kind: "similar", path: one.path }) });
		out.push({ separator: true });
		out.push({ label: "Scan for viruses", icon: "shield_search", run: () => Files.avScan(root.paths(rows)) });
		if (files.length > 0 && files.length <= 20 && files.length === rows.length) out.push({ label: "Check with VirusTotal", icon: "shield_search", run: () => Files.vtScan(root.paths(files)) });
		return out;
	}

	// a folder's terminals, agents and apps open on a workspace of its own
	function workspaceEntries(folder) {
		const own = FileLibrary.workspaces[folder];
		const inherited = FileLibrary.workspaceOf(folder);
		const out = [{ header: own === undefined && inherited >= 0 ? `Workspace ${inherited} comes from a folder above` : "Terminals, agents and apps open on" }];
		for (let index = 1; index <= 9; index += 1) out.push({ label: `Workspace ${index}`, icon: "numeric_" + index + "_box_outline", checked: own === index, run: () => {
			FileLibrary.setWorkspace(folder, index);
			Files.say(`${Files.nameOf(folder)} opens on workspace ${index}`, "view_dashboard_outline");
		} });
		out.push({ separator: true });
		out.push({ label: "Where I am", icon: "close", enabled: own !== undefined, run: () => FileLibrary.setWorkspace(folder, -1) });
		return out;
	}

	// the task groups a file can go into as a task (with a link back)
	function taskEntries(paths) {
		const last = String(FileLibrary.setting("taskGroup") || "");
		const out = Todos.groups.map(group => ({
			label: group.name,
			icon: group.name === last ? "star_outline" : (group.name === Todos.inbox ? "inbox_outline" : "folder_outline"),
			hint: `${group.open} open`,
			run: () => Files.rememberTask(paths, group.name)
		}));
		out.push({ separator: true });
		out.push({ label: "With a note…", icon: "note_edit_outline", run: () => root.view.ask("What is to do with it?", "Note for the task", "", note => Files.rememberTask(paths, last || Todos.inbox, note)) });
		out.push({ label: "New group…", icon: "playlist_plus", run: () => root.view.ask("New group", "Name of the group", "Files", name => Files.rememberTask(paths, name)) });
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

	// files and folders of another PC: they come over first, opened or fetched
	function pcEntries(pane, rows) {
		const view = root.view;
		const files = rows.filter(row => !row.dir);
		const out = [];
		out.push({ label: rows.length === 1 ? "Open" : `Open ${rows.length} items`, icon: "open_in_app", shortcut: "Enter", run: () => view.openRows(pane, rows, false) });
		out.push({ separator: true });
		out.push({ label: "Get to Downloads", icon: "download", run: () => view.fetchFrom(pane, rows, `${Files.home}/Downloads`) });
		if (view.tab.split && view.tab.other.isFolder) out.push({ label: `Get to ${view.tab.other.title}`, icon: "dock_right", shortcut: "F5", run: () => view.fetchFrom(pane, rows, view.tab.other.location.path) });
		out.push({ label: "Get to…", icon: "folder_arrow_down_outline", run: () => view.ask("Into which folder?", "Folder", `${Files.home}/Downloads`, folder => view.fetchFrom(pane, rows, folder.replace(/^~/, Files.home))) });
		return out;
	}

	// everything for pictures: changes make a new one beside it (or replace it, asked in the dialogs)
	function imageEntries(images) {
		const paths = images.map(row => row.path);
		const one = images.length === 1 ? images[0] : null;
		return [
			{ header: "Edit" },
			{ label: "Draw on it", icon: "draw", shown: !!one && root.captures, run: () => Screenshot.editShot(one.path) },
			{ label: "Crop…", icon: "crop", shown: !!one, run: () => root.view.crop(one.path) },
			{ label: "Resize…", icon: "resize", run: () => root.view.resizeDialog(images) },
			{ label: "Turn left", icon: "rotate_left", run: () => Files.imageTool("rotate", paths, { degrees: 270 }) },
			{ label: "Turn right", icon: "rotate_right", run: () => Files.imageTool("rotate", paths, { degrees: 90 }) },
			{ label: "Mirror", icon: "flip_horizontal", run: () => Files.imageTool("flip", paths, { axis: "horizontal" }) },
			{ label: "Watermark…", icon: "water_outline", run: () => root.view.watermarkDialog(images) },
			{ label: "Remove location and camera data", icon: "map_marker_off_outline", run: () => Files.imageTool("strip", paths, {}) },
			{ header: "Text" },
			{ label: "Copy the text", icon: "text_recognition", shown: !!one && root.ocr, run: () => Screenshot.runOcr(one.path, null, false) },
			{ label: "Text as a .txt beside it", icon: "text_box_outline", run: () => Files.startJob("capturetext", { paths: paths }) },
			{ label: one ? "Name it by what it shows" : "Name them by what they show", icon: "creation", run: () => Files.startJob("ainame", { paths: paths }, job => {
				if (job.state === "failed") Files.fail(job.error);
			}) },
			{ header: "Use" },
			{ label: "Pin to the screen", icon: "pin_outline", shown: !!one && root.pins, run: () => Screenshot.pinShot(one.path) },
			{ label: "Set as wallpaper", icon: "wallpaper", shown: !!one && root.wallpaper, run: () => root.view.setWallpaper(one.path) },
			{ label: one ? "Make a PDF of it" : "Make one PDF of them", icon: "file_pdf_box", run: () => Files.pdfTool("fromimages", paths, {}) },
			{ label: "Convert to", icon: "swap_horizontal", children: done => Files.convertible(paths, targets => done(root.convertEntries(images, targets))) }
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
		out.push({ label: view.tab.split ? "Close the split" : "Split", icon: "view_split_vertical", shortcut: "F3", run: () => view.tab.toggleSplit() });
		if (view.tab.split && view.tab.first.isFolder && view.tab.second.isFolder) {
			out.push(pane.compareStates ? { label: "Stop comparing", icon: "file_compare", run: () => view.stopComparing() }
				: { label: "Compare with the other side", icon: "file_compare", shortcut: "F7", run: () => view.compareSides() });
			out.push({ label: "Sync with the other side…", icon: "folder_sync_outline", run: () => view.openSync(pane) });
		}
		if (folder !== "") {
			out.push({ separator: true });
			out.push({ label: FileLibrary.isFavorite(folder) ? "Remove from favorites" : "Add to favorites", icon: FileLibrary.isFavorite(folder) ? "star_off_outline" : "star_outline", shortcut: "Ctrl+D", run: () => FileLibrary.toggleFavorite(folder) });
			out.push({ label: "Open a terminal here", icon: "console", shortcut: "F4", run: () => Files.terminal(folder) });
			if (root.agents) out.push({ label: "Claude Code here", icon: "robot_outline", run: () => Files.agent(folder) });
			out.push({ label: "Copy the path", icon: "clipboard_text_outline", run: () => Files.copyText(folder, "Path copied") });
			const entries = root.folderEntries(pane, folder, pane.writable);
			entries.push({ separator: true });
			entries.push({ label: "Scan for viruses", icon: "shield_search", run: () => Files.avScan([folder]) });
			out.push({ label: "This folder", icon: "folder_open_outline", children: entries });
			if (pane.git) out.push({ label: "Git", icon: "source_branch", children: () => view.gitMenu(pane) });
		}
		out.push({ separator: true });
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

	// ── the AI line (Ctrl+Shift+A): what a sentence asks for ─────────────────
	function aiLine(pane, prompt) {
		return Intents.rank(prompt, root.aiIntents(pane));
	}

	// the AI features, each with the words that ask for it; on the picked
	// files when they fit, else on everything
	function aiIntents(pane) {
		const view = root.view;
		const rows = pane.targets().filter(row => !String(row.path).startsWith("phone:"));
		const files = rows.filter(row => !row.dir);
		const one = files.length === 1 ? files[0] : null;
		const images = files.filter(row => row.kind === "image");
		const pdfs = files.filter(row => row.mime === "application/pdf");
		const texts = files.filter(row => row.text);
		const readable = files.filter(row => row.text || row.mime === "application/pdf");
		const them = list => list.length === 1 ? `“${list[0].name}”` : `${list.length} files`;
		const quoted = rest => rest !== "" ? ` “${rest}”` : "";
		const search = rest => pane.go({ kind: "search", path: Files.home, query: rest, ai: true });
		return [
			{ id: "find", group: "Your files", icon: "magnify", label: rest => rest !== "" ? `Find${quoted(rest)} by meaning` : "Find by meaning…",
				words: ["such", "find", "wo ist", "wo sind", "where", "zeig", "show me", "gibt es", "hab ich"],
				hints: ["rechnung", "invoice", "vertrag", "foto", "photo", "bild", "picture", "screenshot", "datei", "file", "dokument", "document", "pdf", "brief", "letter"],
				run: rest => rest !== "" ? search(rest) : view.ask("What are you looking for?", "the Telekom invoice from the spring", "", search) },
			{ id: "similar", group: "Picked", icon: "approximately_equal", label: `Files like ${one ? them([one]) : "it"}`, shown: !!one && (Files.index.files ?? 0) > 0,
				words: ["ähnlich", "aehnlich", "similar", "wie dies", "like this", "gleich"],
				run: () => pane.go({ kind: "similar", path: one.path }) },
			{ id: "name", group: "Picked", icon: "creation", label: `Name ${them(images)} by what they show`, shown: images.length > 0 && images.length === files.length,
				words: ["benenn", "umbenenn", "name", "rename", "titel", "title", "nach inhalt", "by content"],
				run: () => Files.startJob("ainame", { paths: root.paths(images) }, job => {
					if (job.state === "failed") Files.fail(job.error);
				}) },
			{ id: "ocr", group: "Picked", icon: "text_recognition", label: one && root.ocr ? `Copy the text of ${them([one])}` : `The text of ${them(images)} as .txt beside`, shown: images.length > 0 && images.length === files.length,
				words: ["text", "ocr", "abschreib", "erkenn", "lesen", "read", "extract", "kopier", "copy"],
				run: () => one && root.ocr ? Screenshot.runOcr(one.path, null, false) : Files.startJob("capturetext", { paths: root.paths(images) }) },
			{ id: "searchable", group: "Picked", icon: "text_recognition", label: `Make ${them(pdfs)} searchable`, shown: pdfs.length > 0 && pdfs.length === files.length,
				words: ["durchsuchbar", "searchable", "ocr", "text erkenn", "scan"],
				run: () => view.pdfTool("ocr", pdfs) },
			{ id: "translate", group: "Picked", icon: "translate", label: `Translate ${them(readable)}…`, shown: Plugins.on("translate") && readable.length > 0 && readable.length === files.length,
				words: ["übersetz", "uebersetz", "translat", "sprache", "language"],
				run: (rest, prompt) => view.translateDialog(readable, Intents.language(prompt)) },
			{ id: "read", group: "Picked", icon: "book_open_page_variant", label: `Speed-read ${them(texts)}`, shown: root.reader && texts.length === 1,
				words: ["speed", "schnell les", "vorles", "lies", "read"],
				run: () => view.speedRead(texts[0]) },
			{ id: "ask", group: "Picked", icon: "creation", label: rest => rest !== "" ? `Ask about ${them(files)}:${quoted(rest)}` : `Ask AI about ${them(files)}`, shown: root.ai && files.length > 0 && files.length <= 6,
				words: ["frag", "ask", "erklär", "erklaer", "explain", "zusammenfass", "zusammen", "summar", "was steht", "what", "worum", "wer", "who", "wann", "when", "warum", "why", "wie", "how", "inhalt"],
				run: (rest, prompt) => view.askAi(files, prompt) },
			{ id: "settings", group: "Settings", icon: "cog_outline", label: "Models and the index",
				words: ["modell", "model", "index", "einstell", "setting", "ollama"],
				run: () => view.openSettings("ai") },
			{ id: "find-any", fallback: true, instead: "find", group: "", icon: "magnify", label: rest => `Find “${rest}” by meaning`, shown: true,
				run: (rest, prompt) => search(prompt) },
			{ id: "ask-any", fallback: true, instead: "ask", group: "", icon: "creation", label: rest => files.length > 0 && files.length <= 6 ? `Ask about ${them(files)}: “${rest}”` : `Ask AI: “${rest}”`, shown: root.ai,
				run: (rest, prompt) => view.askAi(files.length <= 6 ? files : [], prompt) }
		].map(intent => intent.group === "Picked" ? Object.assign(intent, { group: files.length === 1 ? files[0].name : `${files.length} picked` }) : intent);
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
				if (entry.separator || entry.enabled === false || entry.shown === false) continue;
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
		out.push({ label: "AI…", icon: "creation", shortcut: "Ctrl+Shift+A", group: "Window", run: () => view.openAiLine() });
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
		for (const pc of Pcs.devices) if (pc.files) go(`Files of ${pc.name}`, "laptop", { kind: "pc", id: pc.id, path: "" });
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
