pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.style.theme
import qs.style.widgets
import qs.core.services

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

	// the tabs of the last session come back
	function restore() {
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
	}

	function handle(request) {
		if (tabModel.count === 0) root.restore();
		const paths = (request.paths || []).map(path => String(path));
		if (request.kind === "search") {
			root.pane.go({ kind: "search", path: root.pane.isFolder ? root.pane.location.path : Files.home, query: request.query || "" });
			root.focusSearch();
			return;
		}
		if (paths.length === 0) {
			if (request.newTab) root.newTab({ kind: "home" }, true);
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

	// ── opening things ─────────────────────────────────────────────────────
	function openRow(pane, row, newTab) {
		if (!row) return;
		if (pane.location.kind === "trash") {
			root.quickLook(pane);
			return;
		}
		if (row.dir) {
			if (newTab) root.newTab({ kind: "dir", path: row.path }, false);
			else pane.openFolder(row.path);
			return;
		}
		Files.launch([row.path]);
		Sounds.play("open");
	}

	function openRows(pane, rows, newTab) {
		const dirs = rows.filter(row => row.dir);
		const files = rows.filter(row => !row.dir);
		if (files.length > 0) {
			Files.launch(files.map(row => row.path));
			Sounds.play("open");
		}
		if (dirs.length === 1 && files.length === 0 && !newTab) pane.openFolder(dirs[0].path);
		else dirs.forEach(row => root.newTab({ kind: "dir", path: row.path }, false));
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

	function openPalette() {
		if (root.pane) palette.open(commands.palette(root.pane));
	}

	function menuFromSidebar(entries, x, y) {
		menu.show(entries, x, y);
	}

	function showViewMenu(pane, item) {
		const at = item.mapToItem(root, item.width - 210, item.height + 6);
		menu.show(commands.viewEntries(pane), at.x, at.y);
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

	function askAi(rows) {
		Popups.withFocusedScreen(screen => Popups.open("launcher", screen, "", {
			aiFiles: rows.map(row => ({ path: row.path, name: row.name, mimeType: row.mime, size: row.size, isDir: false }))
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

	// ── details and quick look ─────────────────────────────────────────────
	readonly property bool detailsOpen: !!FileLibrary.view.details

	function showDetails(on) {
		FileLibrary.setView("", { details: !!on });
	}

	function quickLook(pane) {
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
			if (root.tab.split && targets.length > 0 && root.tab.other.isFolder) Files.transfer(paths, root.tab.other.location.path, "copy");
			else pane.reload(false);
			break;
		case Qt.Key_F6:
			if (root.tab.split && targets.length > 0 && root.tab.other.isFolder) Files.transfer(paths, root.tab.other.location.path, "move");
			break;
		case Qt.Key_Delete:
			if (pane.location.kind === "trash" || shift) Files.remove(paths);
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
				pane.selectAll();
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
				Files.undo();
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
			case Qt.Key_1:
				FileLibrary.setView(pane.isFolder ? folder : `:${pane.location.kind}`, { mode: "grid" });
				break;
			case Qt.Key_2:
				FileLibrary.setView(pane.isFolder ? folder : `:${pane.location.kind}`, { mode: "list" });
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
	JobsTray {
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

	FileMenu {
		id: menu

		anchors.fill: parent
		onClosed: keyTarget.forceActiveFocus()
	}

	CommandPalette {
		id: palette

		anchors.fill: parent
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

	function takeFocus() {
		keyTarget.forceActiveFocus();
	}
}
