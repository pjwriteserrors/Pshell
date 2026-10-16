pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "FileKinds.js" as Kinds

// The file manager: a sidebar of places, tabs of panes (one or two side by
// side), details beside them, and everything that comes over them – menus,
// the command palette, quick look, questions, the jobs that run.
FocusScope {
	id: root

	// the window is up: what was asked for is shown
	property bool shown: false

	// the window is up and has the keyboard: finished jobs need no word
	Binding {
		target: Files
		property: "windowActive"
		value: root.shown && root.Window.active
	}

	// ── tabs ───────────────────────────────────────────────────────────────
	ListModel {
		id: tabModel
	}

	property var tabMap: ({})
	property int tabTick: 0
	property int currentIndex: 0
	property int tabSerial: 0
	readonly property var tab: {
		root.tabTick;
		const entry = root.currentIndex < tabModel.count ? tabModel.get(root.currentIndex) : null;
		return entry ? root.tabMap[entry.tabId] : null;
	}
	readonly property var pane: root.tab?.pane ?? null
	readonly property alias tabs: tabModel

	Component {
		id: tabComponent

		TabState {}
	}

	function newTab(location, focus, select) {
		root.tabSerial += 1;
		const id = `tab${root.tabSerial}`;
		const tab = tabComponent.createObject(root, { tabId: id, serial: root.tabSerial });
		root.tabMap[id] = tab;
		const at = Math.min(tabModel.count, root.currentIndex + 1);
		tabModel.insert(tabModel.count === 0 ? 0 : at, { tabId: id });
		root.tabTick += 1;
		tab.first.go(location || { kind: "home" }, { history: false, force: true, select: select || [] });
		if (focus !== false) root.currentIndex = tabModel.count === 1 ? 0 : at;
		root.saveSession();
		return tab;
	}

	function closeTab(index) {
		if (tabModel.count <= 1) {
			Files.close();
			return;
		}
		const id = tabModel.get(index).tabId;
		const tab = root.tabMap[id];
		tabModel.remove(index, 1);
		delete root.tabMap[id];
		if (root.currentIndex >= tabModel.count) root.currentIndex = tabModel.count - 1;
		else if (index < root.currentIndex) root.currentIndex -= 1;
		root.tabTick += 1;
		Sounds.play("close");
		tab.destroy(500);
		root.saveSession();
	}

	function selectTab(index) {
		if (index < 0 || index >= tabModel.count) return;
		root.currentIndex = index;
		keyTarget.forceActiveFocus();
	}

	function moveTab(from, to) {
		if (from === to || to < 0 || to >= tabModel.count) return;
		tabModel.move(from, to, 1);
		root.currentIndex = to;
		root.saveSession();
	}

	function saveSession() {
		sessionTimer.restart();
	}

	Timer {
		id: sessionTimer

		interval: 800
		onTriggered: {
			const tabs = [];
			for (let i = 0; i < tabModel.count; i += 1) {
				const tab = root.tabMap[tabModel.get(i).tabId];
				if (tab) tabs.push(tab.snapshot());
			}
			FileLibrary.setSession(tabs);
		}
	}

	// the tabs of the last session come back (or the page the settings say)
	function restore() {
		const start = FileLibrary.setting("startPage");
		if (start === "home" || (start === "folder" && FileLibrary.setting("startFolder") === "")) {
			root.newTab({ kind: "home" }, true);
			return;
		}
		if (start === "folder") {
			root.newTab({ kind: "dir", path: FileLibrary.setting("startFolder") }, true);
			return;
		}
		const saved = FileLibrary.session.filter(tab => Array.isArray(tab.panes) && tab.panes.length > 0).slice(0, 12);
		if (saved.length === 0) {
			root.newTab({ kind: "home" }, true);
			return;
		}
		for (const entry of saved) {
			const tab = root.newTab(entry.panes[0], false);
			if (entry.split && entry.panes[1]) {
				tab.second.go(entry.panes[1], { history: false, force: true });
				tab.split = true;
				tab.side = entry.focus === 1 ? 1 : 0;
				tab.first.modeOverride = String(entry.modes?.[0] ?? "");
				tab.second.modeOverride = String(entry.modes?.[1] ?? "");
			}
		}
		root.currentIndex = 0;
	}

	Connections {
		target: FileLibrary

		function onLoadedChanged() {
			if (FileLibrary.loaded && tabModel.count === 0) root.restore();
		}
	}

	Component.onCompleted: {
		if (FileLibrary.loaded) root.restore();
	}

	// where the session goes changes with every navigation
	Connections {
		target: root.pane
		ignoreUnknownSignals: true

		function onLocationChanged() {
			root.saveSession();
		}
		// a name typed in place is done: the keys come back to the files
		function onRenamingChanged() {
			if (root.pane.renaming === "") keyTarget.forceActiveFocus();
		}
	}

	// ── what other parts of the shell ask for ──────────────────────────────
	Connections {
		target: Files

		function onShowRequested(request) {
			root.handle(request);
			if (request.kind !== "search") keyTarget.forceActiveFocus();
		}
		function onSaid(text, icon, undo) {
			snackbar.show(text, icon, undo);
		}
		function onConfirmRequested(question) {
			confirm.ask(question);
		}
		function onPasswordAsked(title, path, done) {
			root.ask(`${title} – ${Files.nameOf(path)}`, "Password", "", done, true);
		}
		function onScanned(results) {
			scanResults.open(results);
		}
		function onLocalScanned(result) {
			scanResults.openLocal(result);
		}
		function onCompared(result) {
			compareResults.open(result);
		}
		function onSettingsAsked(page) {
			settings.open(page);
		}
	}

	function sendToServer(rows) {
		sender.open(rows);
	}

	function openSettings(page) {
		settings.open(page || "");
	}

	// a PDF tool: one with questions asks them first, the others start
	function pdfTool(tool, rows) {
		const paths = rows.map(row => row.path);
		if (tool === "organize") organizer.open(rows[0]);
		else if (tool === "sign") signer.open(rows[0]);
		else if (pdfDialog.needsAsking(tool)) pdfDialog.open(tool, rows);
		else Files.pdfTool(tool, paths, tool === "compress" ? { level: FileLibrary.setting("pdfQuality") } : {});
	}

	function handle(request) {
		if (tabModel.count === 0) root.restore();
		const paths = (request.paths || []).map(path => String(path));
		if (request.kind === "search") {
			root.pane.go({ kind: "search", path: root.pane.isFolder ? root.pane.location.path : Files.home, query: request.query || "" });
			root.focusSearch();
			return;
		}
		if (request.kind === "compare") {
			const tab = root.newTab({ kind: "dir", path: request.left }, true);
			tab.second.go({ kind: "dir", path: request.right }, { history: false, force: true });
			tab.split = true;
			compareTimer.restart();
			return;
		}
		if (request.kind === "place" && request.location) {
			root.pane.go(request.location);
			return;
		}
		if (paths.length === 0) {
			if (request.newTab) root.newTab({ kind: "home" }, true);
			return;
		}
		if (request.kind === "look") {
			const folder = Files.parentOf(paths[0]);
			root.goSomewhere({ kind: "dir", path: folder }, false, [paths[0]]);
			lookLater.path = paths[0];
			lookLater.tries = 0;
			lookLater.restart();
			return;
		}
		if (request.kind === "items" || request.kind === "properties") {
			const folder = Files.parentOf(paths[0]);
			root.goSomewhere({ kind: "dir", path: folder }, request.newTab, paths.filter(path => Files.parentOf(path) === folder));
			if (request.kind === "properties") root.showDetails(true);
			return;
		}
		root.goSomewhere({ kind: "dir", path: paths[0] }, request.newTab, []);
		for (const path of paths.slice(1)) root.newTab({ kind: "dir", path: path }, false);
	}

	// a tab already showing the place is used; otherwise the current one, unless asked for a new one
	function goSomewhere(location, newTab, select) {
		for (let i = 0; i < tabModel.count; i += 1) {
			const tab = root.tabMap[tabModel.get(i).tabId];
			if (tab?.pane.location.kind === location.kind && tab.pane.location.path === location.path) {
				root.selectTab(i);
				if (select.length > 0) tab.pane.selectPaths(select);
				return;
			}
		}
		if (newTab && root.pane?.location.kind !== "home") root.newTab(location, true, select);
		else root.pane.go(location, { select: select });
	}

	// quick look once the folder is read and the file picked
	Timer {
		id: lookLater

		property string path: ""
		property int tries: 0
		interval: 120
		onTriggered: {
			const pane = root.pane;
			if (pane && pane.settled && pane.rows.some(row => row.path === lookLater.path)) {
				pane.selectPaths([lookLater.path]);
				root.quickLook(pane);
			} else if (lookLater.tries < 25) {
				lookLater.tries += 1;
				lookLater.restart();
			}
		}
	}

	// ── opening things ─────────────────────────────────────────────────────
	function openRow(pane, row, newTab) {
		if (!row) return;
		if (pane.location.kind === "trash") {
			root.quickLook(pane);
			return;
		}
		if (row.dir) {
			if (newTab) root.newTab(pane.placeOf(row.path), false);
			else pane.openFolder(row.path);
			return;
		}
		root.openFiles(pane, [row]);
	}

	// a double click on an archive takes it apart here, a Windows program
	// starts with Proton or Wine, everything else opens in its app
	function openFiles(pane, rows) {
		// on the phone or another PC: each comes over first
		if (pane.location.kind === "phone" || pane.location.kind === "pc") {
			for (const row of rows) root.openElsewhere(pane, row);
			return;
		}
		const rest = [];
		for (const row of rows) {
			if (commands.isArchive(row) && FileLibrary.setting("archiveOpen") === "extract" && !/\.(iso|img|deb|rpm|apk|jar|cbz|cbr|epub)$/i.test(row.name)) {
				Files.extract(row.path, pane.isFolder ? pane.location.path : Files.parentOf(row.path));
				Sounds.play("open");
			} else if (Kinds.isWindows(row)) {
				Files.runWindows(row.path, "auto");
			} else if (/\.ics$/i.test(row.name) && Outlook.enabled && Outlook.signedIn) {
				// an invitation or a calendar file: into the calendar, once agreed
				Files.confirmRequested({ title: `Add ${row.name} to the calendar?`, detail: "Its events go into your Microsoft 365 calendar.", confirm: "Add", danger: false, run: () => Files.importCalendar(row.path) });
			} else {
				rest.push(row);
			}
		}
		if (rest.length > 0) {
			Files.launch(rest.map(row => row.path));
			Sounds.play("open");
		}
	}

	function openElsewhere(pane, row) {
		if (row.pcId) {
			Files.say(`Getting ${row.name} from ${Pcs.nameOf(row.pcId)}…`, "laptop");
			Pcs.open(row.pcId, row.pcPath);
			return;
		}
		PhoneDrive.open(Object.assign({ phoneId: row.path.slice(6) }, row));
	}

	// files and folders of another PC into a folder here
	function fetchFrom(pane, rows, folder) {
		const id = String(pane.location.id);
		Files.say(rows.length === 1 ? `Getting ${rows[0].name} from ${Pcs.nameOf(id)}…` : `Getting ${rows.length} items from ${Pcs.nameOf(id)}…`, "laptop");
		Pcs.fetch(id, rows.map(row => row.pcPath), folder, paths => {
			Sounds.play("taskDone");
			Files.say(paths.length === 1 ? `${Files.nameOf(paths[0])} is here` : `${paths.length} items are here`, "laptop");
		});
	}

	function openRows(pane, rows, newTab) {
		const dirs = rows.filter(row => row.dir);
		const files = rows.filter(row => !row.dir);
		if (files.length > 0) root.openFiles(pane, files);
		if (dirs.length === 1 && files.length === 0 && !newTab) pane.openFolder(dirs[0].path);
		else dirs.forEach(row => root.newTab(pane.placeOf(row.path), false));
	}

	function revealIn(pane, paths) {
		if (paths.length === 0) return;
		const folder = Files.parentOf(paths[0]);
		pane.go({ kind: "dir", path: folder }, { select: paths.filter(path => Files.parentOf(path) === folder) });
	}

	function openPlace(pane, place) {
		if (place.mounted && place.path) {
			pane.openFolder(place.path);
			return;
		}
		Files.mount(place.uri || place.id, "", (path, error) => {
			if (error === "password") {
				root.ask(`Password for ${place.name}`, "Password", "", password => Files.mount(place.uri || place.id, password, mounted => {
					if (mounted) pane.openFolder(mounted);
				}), true);
				return;
			}
			if (path) pane.openFolder(path);
		});
	}

	// ── menus ──────────────────────────────────────────────────────────────
	Commands {
		id: commands

		view: root
	}

	function showItemMenu(pane, index, x, y) {
		if (pane !== root.pane) root.focusPane(pane);
		const rows = index >= 0 ? pane.selectedRows() : [];
		menu.show(commands.forRows(pane, rows), x, y);
	}

	function showRowsMenu(pane, rows, x, y) {
		menu.show(commands.forRows(pane, rows), x, y);
	}

	// what this kind of file can do, for a button in the preview or the details
	function kindMenu(pane, rows) {
		return pane && rows.length > 0 ? commands.kindMenu(pane, rows) : null;
	}

	function showKindMenu(pane, rows, x, y) {
		const own = root.kindMenu(pane, rows);
		if (own) menu.show(own.entries, x, y);
	}

	function openPalette() {
		if (root.pane) palette.open(commands.palette(root.pane));
	}

	function openAiLine() {
		const pane = root.pane;
		if (!pane) return;
		aiLine.provider = prompt => commands.aiLine(pane, prompt);
		aiLine.open([]);
	}

	function menuFromSidebar(entries, x, y) {
		menu.show(entries, x, y);
	}

	function showViewMenu(pane, item) {
		if (pane !== root.pane) root.focusPane(pane);
		viewPopover.open(pane, item);
	}

	// cards or a list: in a split only for that side, else where the folder's scope says
	function setMode(pane, mode) {
		if (root.tab?.split) {
			pane.modeOverride = mode === pane.view.mode ? "" : mode;
			root.saveSession();
			return;
		}
		pane.modeOverride = "";
		FileLibrary.setView(pane.viewKey, { mode: mode });
	}

	function focusPane(pane) {
		if (!root.tab) return;
		if (root.tab.split) root.tab.side = pane === root.tab.second ? 1 : 0;
		keyTarget.forceActiveFocus();
	}

	// ── actions the menus and keys share ───────────────────────────────────
	function rename(pane, rows) {
		if (rows.length === 1) {
			pane.renaming = rows[0].path;
		} else if (rows.length > 1) {
			batchRename.open(rows);
		}
	}

	function toShelf(rows) {
		if (!Plugins.on("shelves") || rows.length === 0) return;
		const items = rows.map(row => ({ kind: "file", path: row.path }));
		// a new shelf is made in a moment: it takes the items with it
		if (Shelf.shelves.length === 0) Shelf.create(items);
		else Shelf.keep(items, null);
		Sounds.play("pinned");
		snackbar.show(rows.length === 1 ? "On the shelf" : `${rows.length} items on the shelf`, "tray_arrow_down");
	}

	// a chat about the files; with a prompt it is asked once they are read
	function askAi(rows, prompt) {
		Popups.withFocusedScreen(screen => Popups.open("launcher", screen, "", {
			aiFiles: rows.map(row => ({ path: row.path, name: row.name, mimeType: row.mime, size: row.size, isDir: false })),
			aiAsk: String(prompt || "")
		}));
	}

	function speedRead(row) {
		Files.request("read", { path: row.path, limit: 400000 }, (data, error) => {
			if (error || !data?.text) {
				snackbar.show("Nothing to read in it", "alert_circle_outline");
				return;
			}
			Reader.read(data.text, null);
		});
	}

	function setWallpaper(path) {
		Quickshell.execDetached(["bash", `${Paths.scripts}/apply_theme_selection.sh`, path]);
		snackbar.show("The wallpaper changes in a moment", "wallpaper");
	}

	// a short question with a field: ask(title, placeholder, text, done, password)
	function ask(title, placeholder, text, done, password) {
		prompt.open(title, placeholder, text, done, !!password);
	}

	// ── forms: a few questions, then something is done ─────────────────────
	function form(spec, done) {
		formDialog.here = root.pane?.isFolder ? root.pane.location.path : "";
		formDialog.open(spec, done);
		return formDialog;
	}

	function taskMenu(paths) {
		return commands.taskEntries(paths);
	}

	function openHistory() {
		history.open();
	}

	function showDiff(path) {
		diff.open(path);
	}

	function crop(path) {
		cropper.open(path);
	}

	function wallpaperFolder(folder) {
		wallpapers.open(folder);
	}

	function trim(path, mode) {
		trimmer.open(path, mode);
	}

	// ── pictures, tags, links ──────────────────────────────────────────────
	function resizeDialog(rows) {
		root.form({
			title: rows.length === 1 ? "Resize the picture" : `Resize ${rows.length} pictures`,
			subtitle: rows.length === 1 ? rows[0].name : "",
			icon: "resize",
			accent: Theme.tertiary,
			action: "Resize",
			fields: [
				{ key: "mode", type: "choice", label: "By", value: "longest", options: [{ value: "longest", label: "Longest side" }, { value: "percent", label: "Percent" }] },
				{ key: "longest", type: "menu", label: "Longest side", value: 1920, when: v => v.mode === "longest", options: [640, 1080, 1280, 1920, 2560, 3840].map(n => ({ value: n, label: `${n} px` })) },
				{ key: "percent", type: "slider", label: "Size", value: 50, min: 10, max: 100, step: 5, unit: "%", when: v => v.mode === "percent" },
				{ key: "replace", type: "switch", label: "Replace the original", hint: "It goes to the trash, so this can be undone", value: false }
			]
		}, values => Files.imageTool("resize", rows.map(row => row.path), { mode: values.mode, longest: Number(values.longest), percent: Number(values.percent), replace: values.replace }));
	}

	function watermarkDialog(rows) {
		root.form({
			title: "Watermark",
			subtitle: rows.length === 1 ? rows[0].name : `${rows.length} pictures`,
			icon: "water_outline",
			accent: Theme.tertiary,
			action: "Put it on",
			fields: [
				{ key: "text", type: "text", label: "Text", placeholder: `© ${new Date().getFullYear()} …`, required: true },
				{ key: "position", type: "menu", label: "Where", value: "bottomright", options: [{ value: "bottomright", label: "Bottom right" }, { value: "bottomleft", label: "Bottom left" }, { value: "topright", label: "Top right" }, { value: "center", label: "Middle" }, { value: "tile", label: "All over" }] },
				{ key: "opacity", type: "slider", label: "Strength", value: 0.5, min: 0.1, max: 1, step: 0.05, unit: "%" },
				{ key: "size", type: "slider", label: "Size", value: 0.05, min: 0.02, max: 0.15, step: 0.01, unit: "%" }
			]
		}, values => Files.imageTool("watermark", rows.map(row => row.path), values));
	}

	function tagsDialog(row) {
		const dialog = root.form({
			title: "Tags",
			subtitle: row.name,
			icon: "music_note",
			accent: Theme.secondary,
			action: "Save",
			width: 500,
			fields: [
				{ key: "title", type: "text", label: "Title" },
				{ key: "artist", type: "text", label: "Artist" },
				{ key: "album", type: "text", label: "Album" },
				{ key: "album_artist", type: "text", label: "Album artist" },
				{ key: "date", type: "text", label: "Year" },
				{ key: "track", type: "text", label: "Track" },
				{ key: "genre", type: "text", label: "Genre" },
				{ key: "cover", type: "path", label: "Cover (a picture file)", placeholder: "Leave empty to keep the one it has" },
				{ key: "removeCover", type: "switch", label: "Take the cover out", value: false, when: v => !!v.hasCover && !v.cover }
			]
		}, values => {
			const tags = {};
			for (const key of ["title", "artist", "album", "album_artist", "date", "track", "genre"]) if (values[key] !== undefined) tags[key] = String(values[key]);
			Files.writeTags(row.path, tags, String(values.cover || ""), !!values.removeCover);
		});
		Files.request("mediatags", { path: row.path }, data => {
			if (data) dialog.merge(Object.assign({ hasCover: !!data.cover }, data.tags ?? {}));
		});
	}

	function shareDialog(rows) {
		const paths = rows.map(row => row.path);
		const server = FileLibrary.setting("shareServer");
		const images = rows.filter(row => row.kind === "image");
		const dialog = root.form({
			title: "Share a link",
			subtitle: rows.length === 1 ? rows[0].name : `${rows.length} items (as one ZIP)`,
			icon: "link_variant",
			action: "Upload",
			actionIcon: "upload_outline",
			fields: [
				{ key: "host", type: "menu", label: "Upload to", value: FileLibrary.setting("shareHost") === "ssh" && !server ? "litterbox" : FileLibrary.setting("shareHost"), options: [
					{ value: "litterbox", label: "Litterbox (up to 1 GB)", icon: "cloud_upload_outline" },
					{ value: "0x0", label: "0x0.st (up to 512 MB)", icon: "cloud_upload_outline" },
					{ value: "ssh", label: server ? `My server (${server.name || "SSH"})` : "My server – set it up in the settings", icon: "server_network" }
				] },
				{ key: "hours", type: "menu", label: "For", value: FileLibrary.setting("shareHours"), options: [{ value: 1, label: "1 hour" }, { value: 12, label: "12 hours" }, { value: 24, label: "1 day" }, { value: 72, label: "3 days" }, { value: 168, label: "1 week (0x0.st)" }] },
				{ key: "where", type: "info", tone: "warning", text: v => "Anyone with the link can download it until it runs out. The host can see what you upload.", when: v => v.host !== "ssh" },
				{ key: "gps", type: "info", tone: "warning", icon: "map_marker_alert_outline", text: "A picture says where it was taken – use Edit picture → Remove location first if that should stay private.", when: v => !!v.located }
			],
			check: values => values.host === "ssh" && !server ? "Set up your server in the settings first" : ""
		}, values => {
			FileLibrary.set("shareHost", values.host);
			FileLibrary.set("shareHours", Number(values.hours));
			Files.share(paths, { host: values.host, hours: Number(values.hours) });
		});
		for (const row of images.slice(0, 10)) Files.request("imageinfo", { path: row.path }, data => {
			if (data?.location) dialog.merge({ located: true });
		});
	}

	function translateDialog(rows, target) {
		root.form({
			title: "Translate",
			subtitle: rows.length === 1 ? rows[0].name : `${rows.length} files`,
			icon: "translate",
			action: "Translate",
			fields: [
				{ key: "target", type: "menu", label: "Into", value: target || FileLibrary.setting("translateTo") || "en", options: [
					{ value: "en", label: "English" }, { value: "de", label: "German" }, { value: "fr", label: "French" }, { value: "es", label: "Spanish" },
					{ value: "it", label: "Italian" }, { value: "nl", label: "Dutch" }, { value: "pl", label: "Polish" }, { value: "tr", label: "Turkish" },
					{ value: "uk", label: "Ukrainian" }, { value: "ru", label: "Russian" }, { value: "ja", label: "Japanese" }, { value: "zh", label: "Chinese" }
				] },
				{ key: "engine", type: "choice", label: "With", value: FileLibrary.setting("translateEngine") || "online", options: [{ value: "online", label: "Google (fast)" }, { value: "local", label: "Ollama on this PC" }] },
				{ key: "privacy", type: "info", tone: "warning", text: "The text goes to Google for it. For private files: Ollama on this PC.", when: v => v.engine === "online" },
				{ key: "where", type: "info", text: "The translation is saved beside it as “name (EN).txt”; a PDF's text comes as text." }
			]
		}, values => {
			FileLibrary.set("translateTo", values.target);
			FileLibrary.set("translateEngine", values.engine);
			Files.startJob("translate", { paths: rows.map(row => row.path), target: values.target, engine: values.engine }, job => {
				if (job.state === "done" && job.error) Files.say(job.error, "alert_circle_outline");
			});
		});
	}

	// ── rules ──────────────────────────────────────────────────────────────
	function ruleDialog(rule, folder) {
		const given = rule ?? { id: `r${Date.now().toString(36)}`, enabled: true, folder: folder || "", when: "new", match: { kind: "any" }, action: { kind: "move", target: "" } };
		const match = given.match ?? {};
		const action = given.action ?? {};
		const dialog = root.form({
			title: rule ? "Change the rule" : "New rule",
			subtitle: "What happens on its own with files in a folder",
			icon: "playlist_check",
			action: rule ? "Save" : "Make the rule",
			width: 540,
			fields: [
				{ key: "name", type: "text", label: "Name", placeholder: "Invoices", value: given.name ?? "" },
				{ key: "folder", type: "path", label: "Watch the folder", value: given.folder, required: true, offers: [Files.home + "/Downloads", Files.home + "/Desktop", root.pane?.isFolder ? root.pane.location.path : ""].filter((path, index, list) => path !== "" && list.indexOf(path) === index) },
				{ key: "subfolders", type: "switch", label: "Also in its subfolders", value: !!given.subfolders },
				{ key: "when", type: "choice", label: "When", value: given.when ?? "new", options: [{ value: "new", label: "A file arrives" }, { value: "hourly", label: "Every hour" }] },
				{ key: "kind", type: "menu", label: "Files that are", value: match.kind ?? "any", options: [
					{ value: "any", label: "Anything" }, { value: "pdf", label: "PDFs" }, { value: "image", label: "Pictures" }, { value: "video", label: "Videos" },
					{ value: "audio", label: "Sound" }, { value: "document", label: "Documents" }, { value: "archive", label: "Archives" }, { value: "program", label: "Programs" }
				] },
				{ key: "name_", type: "text", label: "Named (words or a pattern like Screenshot*.png)", value: match.name ?? "" },
				{ key: "contains", type: "text", label: "That mention (PDFs and text)", placeholder: "Rechnung", value: match.contains ?? "" },
				{ key: "olderThan", type: "text", label: "Older than (days)", placeholder: "30", value: match.olderThan ? String(match.olderThan) : "" },
				{ key: "largerThan", type: "text", label: "Bigger than (MB)", placeholder: "", value: match.largerThan ? String(match.largerThan) : "" },
				{ key: "action", type: "choice", label: "Then", value: action.kind ?? "move", options: [{ value: "move", label: "Move" }, { value: "copy", label: "Copy" }, { value: "trash", label: "Trash" }, { value: "extract", label: "Unpack" }] },
				{ key: "target", type: "path", label: "To the folder", value: action.target ?? "", when: v => v.action === "move" || v.action === "copy", offers: [Files.home + "/Documents", Files.home + "/Pictures", Files.home + "/Videos", Files.home + "/Music"] },
				{ key: "byDate", type: "switch", label: "Into a folder per year and month", value: !!action.byDate, when: v => v.action === "move" || v.action === "copy" },
				{ key: "trashSource", type: "switch", label: "Trash the archive afterwards", value: !!action.trashSource, when: v => v.action === "extract" },
				{ key: "preview", type: "info", text: v => v.previewText || "Files already there are left alone – only new ones are taken." }
			],
			check: values => (values.action === "move" || values.action === "copy") && String(values.target || "").trim() === "" ? "Pick the folder they go to" : ""
		}, values => {
			Files.saveRule({
				id: given.id,
				name: String(values.name || "").trim(),
				enabled: given.enabled !== false,
				folder: String(values.folder).trim().replace(/^~/, Files.home),
				subfolders: !!values.subfolders,
				when: values.when,
				match: {
					kind: values.kind,
					name: String(values.name_ || "").trim(),
					contains: String(values.contains || "").trim(),
					olderThan: Number(values.olderThan) || 0,
					largerThan: Number(values.largerThan) || 0
				},
				action: { kind: values.action, target: String(values.target || "").trim().replace(/^~/, Files.home), byDate: !!values.byDate, trashSource: !!values.trashSource }
			});
			Sounds.play("taskDone");
			snackbar.show(rule ? "Rule saved" : "The rule is on", "playlist_check");
		});
		return dialog;
	}

	// ── vaults ─────────────────────────────────────────────────────────────
	function newVault(folder) {
		Files.knowVaults(status => {
			if (!status.installed) {
				root.openSettings("vaults");
				return;
			}
			root.form({
				title: "New vault",
				subtitle: `In ${Files.pretty(folder)}`,
				icon: "safe_square_outline",
				accent: Theme.success,
				action: "Make the vault",
				fields: [
					{ key: "name", type: "text", label: "Name", value: "Vault", required: true },
					{ key: "password", type: "password", label: "Password", required: true },
					{ key: "repeat", type: "password", label: "Once more", required: true },
					{ key: "remember", type: "switch", label: "Keep the password in the keyring", hint: status.fingerprint ? "Opening then asks for your finger" : (Plugins.on("phone-unlock") ? "Opening then asks for your finger on the phone" : "Opening then needs no password while you are logged in"), value: false },
					{ key: "about", type: "info", icon: "information_outline", text: "Files in it are encrypted on disk (gocryptfs). Without the password nobody can read them – there is no way back if it is lost." }
				],
				check: values => String(values.password || "").length > 0 && String(values.password).length < 6 ? "At least 6 characters" : (values.password !== values.repeat ? "The passwords are not the same" : "")
			}, values => Files.vaultDo({ action: "create", name: values.name, folder: folder, password: values.password, remember: values.remember }, (data, error) => {
				if (error) {
					Files.fail(error);
					return;
				}
				Sounds.play("taskDone");
				const made = (data?.vaults ?? []).slice(-1)[0];
				if (made) root.pane.openFolder(made.mount);
			}));
		});
	}

	function unlockVault(vault, then) {
		const opened = path => {
			Sounds.play("unlocked");
			if (then) then(path);
			else root.pane.openFolder(path);
		};
		const ask = () => root.form({
			title: `Open ${vault.name}`,
			icon: "lock_open_variant_outline",
			accent: Theme.success,
			action: "Open",
			fields: [
				{ key: "password", type: "password", label: "Password", required: true },
				{ key: "remember", type: "switch", label: "Keep the password in the keyring", value: false, when: () => !vault.keyring }
			]
		}, values => Files.vaultDo({ action: "open", vault: vault.id, password: values.password, remember: !!values.remember }, (data, error) => {
			if (error === "password") {
				Files.fail("Wrong password");
				ask();
			} else if (error) Files.fail(error);
			else opened(data.path);
		}));
		if (!vault.keyring) {
			ask();
			return;
		}
		Files.proveIdentity(`Open the vault ${vault.name}?`, (ok, problem) => {
			if (!ok) {
				if (problem) Files.say(problem, "fingerprint_off");
				ask();
				return;
			}
			Files.vaultDo({ action: "open", vault: vault.id, keyring: true }, (data, error) => {
				if (error) ask();
				else opened(data.path);
			});
		});
	}

	// ── git ────────────────────────────────────────────────────────────────
	function gitMenu(pane) {
		const folder = pane.location.path;
		const git = pane.git ?? {};
		const changed = Object.keys(git.files ?? {}).length;
		return [
			{ header: `${git.branch || "git"} · ${Files.pretty(git.repo || folder)}` },
			{ label: "Commit the changes here…", icon: "source_commit", enabled: changed > 0, run: () => root.commitDialog([folder], Files.nameOf(folder)) },
			{ label: "Show the changes", icon: "file_compare", enabled: changed > 0, run: () => root.showDiff(folder) },
			{ separator: true },
			{ label: "Pull", icon: "source_pull", run: () => Files.gitRun(folder, "pull") },
			{ label: "Push", icon: "upload_outline", enabled: (git.ahead ?? 0) > 0, run: () => Files.gitRun(folder, "push") },
			{ separator: true },
			{ label: "Open a terminal here", icon: "console", run: () => Files.terminal(folder) }
		];
	}

	function commitDialog(paths, what) {
		root.form({
			title: "Commit",
			subtitle: what,
			icon: "source_commit",
			accent: Theme.warning,
			action: "Commit",
			fields: [
				{ key: "message", type: "area", label: "What changed", placeholder: "Fix the …", required: true },
				{ key: "push", type: "switch", label: "Push right after", value: false }
			]
		}, values => Files.commit(paths, values.message.trim(), values.push));
	}

	// ── two sides compared ─────────────────────────────────────────────────
	function compareSides() {
		const tab = root.tab;
		if (!tab?.split || !tab.first.isFolder || !tab.second.isFolder) {
			snackbar.show("Open two folders side by side first (F3)", "view_split_vertical");
			return;
		}
		const left = tab.first;
		const right = tab.second;
		Files.compareFolders(left.location.path, right.location.path, data => {
			if (!data) return;
			left.compareStates = root.topStates(data.left);
			right.compareStates = root.topStates(data.right);
			Sounds.play("select");
		});
	}

	// what is deep inside a folder shows on the folder: changed when anything below it is
	function topStates(states) {
		const out = {};
		for (const rel of Object.keys(states)) {
			const slash = rel.indexOf("/");
			if (slash < 0) {
				out[rel] = states[rel];
				continue;
			}
			const top = rel.slice(0, slash);
			const state = states[rel];
			const before = out[top];
			if (before === undefined) out[top] = state === "same" ? "same" : (state === "only" ? "only" : "changed");
			else if (before !== state && !(before === "changed" && state === "same")) out[top] = state === "same" && before === "only" ? "changed" : (before === "same" && state === "only" ? "changed" : (before === "only" && state === "only" ? "only" : "changed"));
		}
		return out;
	}

	// both sides read first
	Timer {
		id: compareTimer

		interval: 500
		onTriggered: root.compareSides()
	}

	function stopComparing() {
		if (!root.tab) return;
		root.tab.first.compareStates = null;
		root.tab.second.compareStates = null;
	}

	function openSync(pane) {
		const tab = root.tab;
		if (!tab?.split) return;
		syncer.open(tab.first.location.path, tab.second.location.path);
	}

	Connections {
		target: Files

		// a sync that is through: the comparison is made again
		function onJobFinished(job) {
			if (job.kind === "sync" && root.tab?.first.compareStates) root.compareSides();
		}
	}

	// ── details and quick look ─────────────────────────────────────────────
	readonly property bool detailsOpen: !!FileLibrary.view.details

	function showDetails(on) {
		FileLibrary.setView("", { details: !!on });
	}

	function showVersions() {
		root.showDetails(true);
		Qt.callLater(() => details.loadVersions());
	}

	function quickLook(pane) {
		if (pane.location.kind === "phone" || pane.location.kind === "pc") {
			const row = pane.currentRow ?? pane.selectedRows()[0];
			if (row) root.openElsewhere(pane, row);
			return;
		}
		const rows = pane.selectionCount > 1 ? pane.selectedRows() : pane.rows;
		const current = pane.currentRow ?? pane.selectedRows()[0] ?? null;
		if (!current || rows.length === 0) return;
		look.open(pane, rows, Math.max(0, rows.findIndex(row => row.path === current.path)));
	}

	function focusSearch() {
		topBar.focusSearch();
	}

	// ── the keyboard ───────────────────────────────────────────────────────
	Item {
		id: keyTarget

		focus: true

		Keys.onPressed: event => root.key(event)
	}

	// whatever had the keys and went away (a field, a dialog), they come back to the files
	Connections {
		target: root.Window.window
		ignoreUnknownSignals: true

		function onActiveFocusItemChanged() {
			const window = root.Window.window;
			if (window && (!window.activeFocusItem || window.activeFocusItem === window.contentItem)) refocus.restart();
		}
	}

	Timer {
		id: refocus

		interval: 1
		onTriggered: {
			const window = root.Window.window;
			if (window && (!window.activeFocusItem || window.activeFocusItem === window.contentItem)) keyTarget.forceActiveFocus();
		}
	}

	function key(event) {
		const pane = root.pane;
		if (!pane) return;
		const ctrl = (event.modifiers & Qt.ControlModifier) !== 0;
		const shift = (event.modifiers & Qt.ShiftModifier) !== 0;
		const alt = (event.modifiers & Qt.AltModifier) !== 0;
		const view = root.activeBrowse();
		const targets = pane.targets();
		const paths = targets.map(row => row.path);
		const folder = pane.isFolder ? pane.location.path : "";
		let handled = true;
		switch (event.key) {
		case Qt.Key_Left:
			if (alt) pane.goBack();
			else view?.step("left", shift, ctrl);
			break;
		case Qt.Key_Right:
			if (alt) pane.goForward();
			else view?.step("right", shift, ctrl);
			break;
		case Qt.Key_Up:
			if (alt) pane.goUp();
			else view?.step("up", shift, ctrl);
			break;
		case Qt.Key_Down:
			if (alt && pane.currentRow?.dir) pane.openFolder(pane.currentRow.path);
			else view?.step("down", shift, ctrl);
			break;
		case Qt.Key_Home:
			view?.step("home", shift, ctrl);
			break;
		case Qt.Key_End:
			view?.step("end", shift, ctrl);
			break;
		case Qt.Key_PageUp:
			view?.step("pageup", shift, ctrl);
			break;
		case Qt.Key_PageDown:
			view?.step("pagedown", shift, ctrl);
			break;
		case Qt.Key_Return:
		case Qt.Key_Enter:
			if (alt) root.showDetails(true);
			else if (targets.length > 0) root.openRows(pane, targets, ctrl);
			break;
		case Qt.Key_Backspace:
			if (pane.filter !== "") pane.filter = pane.filter.slice(0, -1);
			else if (!pane.goBack()) pane.goUp();
			break;
		case Qt.Key_Space:
			if (ctrl && pane.current >= 0) pane.pick(pane.current, "toggle");
			else root.quickLook(pane);
			break;
		case Qt.Key_Escape:
			if (pane.renaming !== "") pane.renaming = "";
			else if (pane.filter !== "") pane.filter = "";
			else if (!pane.clearSelection() && pane.location.kind === "search") pane.goBack();
			break;
		case Qt.Key_F2:
			root.rename(pane, targets);
			break;
		case Qt.Key_Menu:
			root.keyMenu(pane);
			break;
		case Qt.Key_F10:
			if (shift) root.keyMenu(pane);
			else handled = false;
			break;
		case Qt.Key_F3:
			root.tab.toggleSplit();
			break;
		case Qt.Key_F4:
			Files.terminal(pane.currentRow?.dir && pane.selectionCount === 1 ? pane.currentRow.path : pane.folder);
			break;
		case Qt.Key_F5:
			// between this PC and another one: over the link
			if (root.tab.split && targets.length > 0 && pane.location.kind === "pc" && root.tab.other.isFolder) root.fetchFrom(pane, targets, root.tab.other.location.path);
			else if (root.tab.split && targets.length > 0 && root.tab.other.location.kind === "pc" && pane.isFolder) Pcs.sendFiles(root.tab.other.location.id, paths, Pcs.byId(root.tab.other.location.id)?.files ? root.tab.other.location.path : undefined);
			else if (root.tab.split && targets.length > 0 && root.tab.other.isFolder) Files.transfer(paths, root.tab.other.location.path, "copy");
			else pane.reload(false);
			break;
		case Qt.Key_F6:
			if (root.tab.split && targets.length > 0 && root.tab.other.isFolder) Files.transfer(paths, root.tab.other.location.path, "move");
			break;
		case Qt.Key_F7:
			if (pane.compareStates) root.stopComparing();
			else root.compareSides();
			break;
		case Qt.Key_Delete:
			if (pane.location.kind === "clipboard") Files.request("clipdelete", { clips: targets.map(row => row.clipId).filter(clip => clip !== "") }, () => pane.reload(false));
			else if (pane.location.kind === "phone" || pane.location.kind === "pc") break;
			else if (pane.location.kind === "trash" || shift) Files.remove(paths);
			else Files.trash(paths);
			break;
		case Qt.Key_Tab:
			if (ctrl) root.selectTab((root.currentIndex + (shift ? -1 : 1) + tabModel.count) % tabModel.count);
			else if (root.tab.split) root.tab.side = 1 - root.tab.side;
			break;
		case Qt.Key_Backtab:
			if (ctrl) root.selectTab((root.currentIndex - 1 + tabModel.count) % tabModel.count);
			else if (root.tab.split) root.tab.side = 1 - root.tab.side;
			break;
		default:
			handled = false;
		}
		if (!handled && ctrl) {
			handled = true;
			switch (event.key) {
			case Qt.Key_A:
				if (shift) root.openAiLine();
				else pane.selectAll();
				break;
			case Qt.Key_I:
				if (shift) pane.invertSelection();
				else root.showDetails(!root.detailsOpen);
				break;
			case Qt.Key_C:
				if (shift) Files.copyText(paths.join("\n"), paths.length === 1 ? "Path copied" : `${paths.length} paths copied`);
				else Files.clipboardSet(paths, false);
				break;
			case Qt.Key_X:
				Files.clipboardSet(paths, true);
				break;
			case Qt.Key_V:
				if (folder !== "") Files.paste(folder);
				break;
			case Qt.Key_Z:
				if (shift) root.openHistory();
				else Files.undo();
				break;
			case Qt.Key_K:
			case Qt.Key_P:
				root.openPalette();
				break;
			case Qt.Key_F:
				root.focusSearch();
				break;
			case Qt.Key_L:
				root.activePaneView()?.editPath();
				break;
			case Qt.Key_T:
				root.newTab(pane.isFolder ? pane.location : { kind: "home" }, true);
				break;
			case Qt.Key_W:
				root.closeTab(root.currentIndex);
				break;
			case Qt.Key_N:
				if (folder !== "" && shift) Files.makeFolder(folder, "New folder");
				else if (folder !== "" && alt) Files.makeFile(folder, "New file.txt", "");
				else root.newTab({ kind: "home" }, true);
				break;
			case Qt.Key_H:
				FileLibrary.setView("", { hidden: !FileLibrary.view.hidden });
				snackbar.show(FileLibrary.view.hidden ? "Hidden files shown" : "Hidden files hidden", "eye_outline");
				break;
			case Qt.Key_B:
				FileLibrary.setView("", { sidebar: FileLibrary.view.sidebar === false });
				break;
			case Qt.Key_D:
				if (targets.length === 1 && targets[0].dir) FileLibrary.toggleFavorite(targets[0].path);
				else if (folder !== "") FileLibrary.toggleFavorite(folder);
				break;
			case Qt.Key_S:
				root.toShelf(targets);
				break;
			case Qt.Key_R:
				pane.reload(false);
				break;
			case Qt.Key_Comma:
				root.openSettings("");
				break;
			case Qt.Key_J:
				root.activePaneView()?.viewOptions();
				break;
			case Qt.Key_1:
				root.setMode(pane, "grid");
				break;
			case Qt.Key_2:
				root.setMode(pane, "list");
				break;
			case Qt.Key_Plus:
			case Qt.Key_Equal:
				FileLibrary.setView("", { cardSize: Math.min(340, (FileLibrary.view.cardSize || 172) + 20) });
				break;
			case Qt.Key_Minus:
				FileLibrary.setView("", { cardSize: Math.max(110, (FileLibrary.view.cardSize || 172) - 20) });
				break;
			default:
				handled = false;
			}
		}
		if (!handled && alt && event.key >= Qt.Key_1 && event.key <= Qt.Key_9) {
			root.selectTab(event.key === Qt.Key_9 ? tabModel.count - 1 : event.key - Qt.Key_1);
			handled = true;
		}
		if (!handled && alt && event.key === Qt.Key_Home) {
			pane.openFolder(Files.home);
			handled = true;
		}
		// letters jump to the names that start with them
		if (!handled && !ctrl && !alt && event.text.length === 1 && event.text.trim() !== "" && pane.rows.length > 0) {
			pane.typeAhead(event.text);
			view?.ensureVisible(pane.current, false);
			handled = true;
		}
		event.accepted = handled;
	}

	// the menu of what is picked, opened from the keyboard: beside the current card
	function keyMenu(pane) {
		const browse = root.activeBrowse();
		const item = browse?.itemOf(pane.current) ?? null;
		const at = item ? item.mapToItem(root, item.width * 0.6, item.height * 0.5) : Qt.point(root.width / 2, root.height / 3);
		if (pane.current >= 0 && !pane.isSelected(pane.rows[pane.current]?.path)) pane.pick(pane.current, "only");
		root.showItemMenu(pane, pane.selectionCount > 0 ? pane.current : -1, at.x, at.y);
	}

	function activePaneView() {
		const page = pages.itemAt(root.currentIndex);
		return page ? page.paneView(root.tab?.side ?? 0) : null;
	}

	function activeBrowse() {
		return root.activePaneView()?.browse ?? null;
	}

	// ── the layout ─────────────────────────────────────────────────────────
	Rectangle {
		anchors.fill: parent
		color: Theme.base
	}

	Sidebar {
		id: sidebar

		x: 10
		y: 10
		height: parent.height - 20
		width: FileLibrary.view.sidebar === false ? 0 : 236
		opacity: FileLibrary.view.sidebar === false ? 0 : 1
		visible: width > 1
		view: root
		pane: root.pane

		Behavior on width {
			SpatialAnim {
				duration: Motion.medium
			}
		}
		Behavior on opacity {
			Anim {}
		}
	}

	Item {
		id: main

		anchors.left: sidebar.right
		anchors.leftMargin: sidebar.width > 1 ? 10 : 10
		anchors.right: details.left
		anchors.rightMargin: details.width > 1 ? 10 : 0
		anchors.top: parent.top
		anchors.bottom: parent.bottom

		TopBar {
			id: topBar

			anchors.left: parent.left
			anchors.right: parent.right
			anchors.top: parent.top
			anchors.topMargin: 10
			height: 40
			view: root
			pane: root.pane
		}

		Item {
			anchors.left: parent.left
			anchors.right: parent.right
			anchors.top: topBar.bottom
			anchors.topMargin: 6
			anchors.bottom: parent.bottom

			Repeater {
				id: pages

				model: tabModel

				delegate: Item {
					id: page

					required property string tabId
					required property int index
					readonly property var tab: {
						root.tabTick;
						return root.tabMap[page.tabId] ?? null;
					}
					readonly property bool current: page.index === root.currentIndex

					function paneView(which) {
						return which === 1 && page.tab?.split ? rightView : leftView;
					}

					anchors.fill: parent
					visible: page.current
					opacity: page.current ? 1 : 0

					Behavior on opacity {
						Anim {
							duration: Motion.short
						}
					}

					PaneView {
						id: leftView

						x: 0
						width: page.tab?.split ? (parent.width - 8) / 2 : parent.width
						height: parent.height
						pane: page.tab?.first ?? null
						shell: root
						split: !!page.tab?.split
						active: !page.tab?.split || page.tab?.side === 0
						onFocusRequested: {
							if (page.tab) page.tab.side = 0;
							keyTarget.forceActiveFocus();
						}

						Behavior on width {
							SpatialAnim {
								duration: Motion.medium
							}
						}
					}

					PaneView {
						id: rightView

						visible: !!page.tab?.split
						x: (parent.width + 8) / 2
						width: (parent.width - 8) / 2
						height: parent.height
						pane: page.tab?.second ?? null
						shell: root
						split: true
						active: page.tab?.side === 1
						opacity: visible ? 1 : 0
						onFocusRequested: {
							if (page.tab) page.tab.side = 1;
							keyTarget.forceActiveFocus();
						}

						Behavior on opacity {
							Anim {}
						}
					}
				}
			}
		}
	}

	DetailsPanel {
		id: details

		anchors.right: parent.right
		anchors.rightMargin: root.detailsOpen ? 10 : 0
		y: 10
		height: parent.height - 20
		width: root.detailsOpen ? Math.min(340, Math.max(280, root.width * 0.24)) : 0
		opacity: root.detailsOpen ? 1 : 0
		visible: width > 1
		pane: root.pane
		view: root

		Behavior on width {
			SpatialAnim {
				duration: Motion.medium
			}
		}
		Behavior on opacity {
			Anim {}
		}
	}

	// ── over everything ────────────────────────────────────────────────────
	// what the file manager plays
	Rectangle {
		id: nowPlaying

		anchors.right: details.left
		anchors.rightMargin: 20
		anchors.bottom: jobsTray.top
		anchors.bottomMargin: jobsTray.height > 0 ? 8 : 0
		width: 340
		height: Files.music.playing ? 52 : 0
		visible: height > 1
		radius: Theme.radius.large
		color: Theme.layer2
		border.width: 1
		border.color: Theme.outline
		clip: true

		Behavior on height {
			SpatialAnim {
				duration: Motion.medium
			}
		}

		Glyph {
			x: 14
			anchors.verticalCenter: parent.verticalCenter
			icon: "music_note"
			size: 18
			color: Theme.primary
		}

		Column {
			x: 42
			anchors.verticalCenter: parent.verticalCenter
			width: parent.width - 42 - musicButtons.width - 10

			StyledText {
				width: parent.width
				text: String(Files.music.title || Files.nameOf(Files.music.path || ""))
				font.pixelSize: Theme.size.small
				font.weight: Font.DemiBold
				elide: Text.ElideRight
			}

			StyledText {
				width: parent.width
				text: `${Math.floor((Files.music.position ?? 0) / 60)}:${String(Math.floor((Files.music.position ?? 0) % 60)).padStart(2, "0")}${(Files.music.count ?? 0) > 1 ? ` · ${(Files.music.index ?? 0) + 1} of ${Files.music.count}` : ""}`
				tone: Theme.textSubtle
				font.pixelSize: Theme.size.tiny
			}
		}

		Row {
			id: musicButtons

			anchors.right: parent.right
			anchors.rightMargin: 6
			anchors.verticalCenter: parent.verticalCenter

			IconButton {
				width: 30
				height: 30
				iconSize: 16
				icon: Files.music.paused ? "play" : "pause"
				onClicked: Files.musicDo("toggle")
			}
			IconButton {
				width: 30
				height: 30
				iconSize: 16
				icon: "skip_next"
				enabled: (Files.music.index ?? 0) < (Files.music.count ?? 0) - 1
				onClicked: Files.musicDo("next")
			}
			IconButton {
				width: 30
				height: 30
				iconSize: 16
				icon: "stop"
				onClicked: Files.musicDo("stop")
			}
		}
	}

	JobsTray {
		id: jobsTray

		anchors.right: details.left
		anchors.rightMargin: 20
		anchors.bottom: parent.bottom
		anchors.bottomMargin: 40
		width: 340
	}

	Snackbar {
		id: snackbar

		anchors.horizontalCenter: main.horizontalCenter
		anchors.bottom: parent.bottom
		anchors.bottomMargin: 44
	}

	QuickLook {
		id: look

		anchors.fill: parent
		view: root
		onClosed: keyTarget.forceActiveFocus()
	}

	ViewPopover {
		id: viewPopover

		anchors.fill: parent
		view: root
		onClosed: keyTarget.forceActiveFocus()
	}

	FileMenu {
		id: menu

		anchors.fill: parent
		onClosed: look.shown ? look.takeKeys() : keyTarget.forceActiveFocus()
	}

	CommandPalette {
		id: palette

		anchors.fill: parent
		onClosed: keyTarget.forceActiveFocus()
	}

	CommandPalette {
		id: aiLine

		anchors.fill: parent
		glyph: "creation"
		placeholder: "Ask, find, name, translate…"
		onClosed: keyTarget.forceActiveFocus()
	}

	ConflictDialog {
		anchors.fill: parent
		onClosed: keyTarget.forceActiveFocus()
	}

	ConfirmDialog {
		id: confirm

		anchors.fill: parent
		onClosed: keyTarget.forceActiveFocus()
	}

	PromptDialog {
		id: prompt

		anchors.fill: parent
		onClosed: keyTarget.forceActiveFocus()
	}

	BatchRename {
		id: batchRename

		anchors.fill: parent
		onClosed: keyTarget.forceActiveFocus()
	}

	PdfDialog {
		id: pdfDialog

		anchors.fill: parent
		view: root
		onClosed: keyTarget.forceActiveFocus()
	}

	PageOrganizer {
		id: organizer

		anchors.fill: parent
		onClosed: keyTarget.forceActiveFocus()
	}

	SignDialog {
		id: signer

		anchors.fill: parent
		onClosed: keyTarget.forceActiveFocus()
	}

	ScanResults {
		id: scanResults

		anchors.fill: parent
		onClosed: keyTarget.forceActiveFocus()
	}

	CompareResults {
		id: compareResults

		anchors.fill: parent
		onClosed: keyTarget.forceActiveFocus()
	}

	SendDialog {
		id: sender

		anchors.fill: parent
		onClosed: keyTarget.forceActiveFocus()
	}

	HistoryDialog {
		id: history

		anchors.fill: parent
		onClosed: keyTarget.forceActiveFocus()
	}

	DiffDialog {
		id: diff

		anchors.fill: parent
		onClosed: keyTarget.forceActiveFocus()
		onCommitAsked: path => root.commitDialog([path], Files.nameOf(path))
	}

	CropDialog {
		id: cropper

		anchors.fill: parent
		onClosed: keyTarget.forceActiveFocus()
	}

	WallpaperDialog {
		id: wallpapers

		anchors.fill: parent
		view: root
		onClosed: keyTarget.forceActiveFocus()
	}

	TrimDialog {
		id: trimmer

		anchors.fill: parent
		onClosed: keyTarget.forceActiveFocus()
	}

	SyncDialog {
		id: syncer

		anchors.fill: parent
		onClosed: keyTarget.forceActiveFocus()
	}

	SettingsDialog {
		id: settings

		anchors.fill: parent
		view: root
		onClosed: keyTarget.forceActiveFocus()
	}

	// above the settings: a rule or a vault is made from there
	FormDialog {
		id: formDialog

		anchors.fill: parent
		onClosed: keyTarget.forceActiveFocus()
	}

	function takeFocus() {
		keyTarget.forceActiveFocus();
	}
}
