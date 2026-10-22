pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.style.theme
import qs.style.widgets
import qs.core.services
import qs.core.views.games
import qs.core.views.launcher
import "../../lib/GameText.js" as GameText
import qs.core.views

// The game library (`games`, >games). The picked game's hero fills the
// screen; over it its logo, how long it was played and how it starts, and
// the covers on a shelf along the bottom – the one picked grows at the
// front, those passed slide out to the left. G turns the shelf into a grid
// of every cover. Typing searches, Tab walks the filters, Enter plays.
//
// Steam's games start through Steam; the others with Proton, Wine or as
// they are, or through Steam once they were added to it. A program dropped
// on the library is added; its cover is found by its name.
ModalWindow {
	id: root

	// all | recent | favorites | steam | other | hidden
	property string filter: "all"
	// recent | name | playtime
	property string sort: "recent"
	property string query: ""
	property bool grid: false
	property real gridness: root.grid ? 1 : 0
	property string selectedId: ""
	// the first moments after opening: covers come in one after another
	property bool intro: false
	property double lastSound: 0

	readonly property var filters: {
		const all = Games.games;
		const shown = all.filter(game => !game.hidden);
		const tabs = [
			{ id: "all", label: "All", count: shown.length },
			{ id: "recent", label: "Recent", count: shown.filter(game => game.lastPlayed > 0).length },
			{ id: "favorites", label: "Favourites", count: shown.filter(game => game.favorite).length },
			{ id: "steam", label: "Steam", count: shown.filter(game => game.kind === "steam").length },
			{ id: "other", label: "Non-Steam", count: shown.filter(game => game.kind !== "steam").length }
		];
		const hidden = all.filter(game => game.hidden).length;
		if (hidden > 0) tabs.push({ id: "hidden", label: "Hidden", count: hidden });
		return tabs.filter(tab => tab.id === "all" || tab.count > 0 || tab.id === root.filter);
	}

	readonly property var list: {
		// a search looks through everything but what is hidden
		const filter = root.query.trim() !== "" && root.filter !== "hidden" ? "all" : root.filter;
		let games = Games.games.filter(game => filter === "hidden" ? game.hidden : !game.hidden);
		if (filter === "recent") games = games.filter(game => game.lastPlayed > 0);
		else if (filter === "favorites") games = games.filter(game => game.favorite);
		else if (filter === "steam") games = games.filter(game => game.kind === "steam");
		else if (filter === "other") games = games.filter(game => game.kind !== "steam");
		const query = root.query.trim();
		if (query !== "") {
			return games.map(game => ({ game: game, score: GameText.matches(game, query) })).filter(entry => entry.score > 0).sort((a, b) => b.score - a.score || GameText.sortName(a.game.name).localeCompare(GameText.sortName(b.game.name))).map(entry => entry.game);
		}
		const byName = (a, b) => GameText.sortName(a.name).localeCompare(GameText.sortName(b.name));
		const sort = filter === "recent" ? "recent" : root.sort;
		if (sort === "name") return games.sort(byName);
		if (sort === "playtime") return games.sort((a, b) => (b.playtime || 0) - (a.playtime || 0) || byName(a, b));
		// what runs first, then what was played last; never played after, by name
		// (a game just added counts as just played)
		const recent = game => Math.max(game.lastPlayed || 0, game.added || 0);
		return games.sort((a, b) => (Games.isRunning(b.id) - Games.isRunning(a.id)) || recent(b) - recent(a) || byName(a, b));
	}

	readonly property int index: Math.max(0, root.list.findIndex(game => game.id === root.selectedId))
	readonly property var selected: root.list.length > 0 ? root.list[root.index] : null
	readonly property bool running: !!root.selected && Games.isRunning(root.selected.id)
	readonly property int totalMinutes: Games.games.filter(game => !game.hidden).reduce((sum, game) => sum + (game.playtime || 0), 0)
	readonly property bool busy: curtain.up || sheet.open || menu.open

	// card sizes follow the screen
	readonly property real cardH: Math.max(210, Math.min(330, root.height * 0.24))
	readonly property real cardW: Math.round(root.cardH * 2 / 3)
	readonly property real bigW: Math.round(root.cardW * 1.32)
	readonly property real side: Math.max(48, Math.round(root.width * 0.045))

	function select(i, quiet) {
		if (root.list.length === 0) return;
		const next = Math.max(0, Math.min(root.list.length - 1, i));
		const id = root.list[next].id;
		if (id === root.selectedId) return;
		root.selectedId = id;
		if (!quiet && Date.now() - root.lastSound > 70) {
			root.lastSound = Date.now();
			Sounds.play("select");
		}
	}

	function step(delta) {
		root.select(root.index + delta);
	}

	function setFilter(id) {
		if (root.filter === id) return;
		root.filter = id;
		Sounds.play("select");
		Qt.callLater(() => root.select(0, true));
	}

	function cycleFilter(delta) {
		const at = root.filters.findIndex(tab => tab.id === root.filter);
		const next = root.filters[(at + delta + root.filters.length) % root.filters.length];
		root.setFilter(next.id);
	}

	function toggleGrid() {
		root.grid = !root.grid;
		Sounds.play("select");
		Qt.callLater(() => {
			if (root.grid) gridView.positionViewAtIndex(root.index, GridView.Contain);
			else shelf.positionViewAtIndex(root.index, ListView.Beginning);
		});
	}

	function cycleSort() {
		const order = ["recent", "name", "playtime"];
		root.sort = order[(order.indexOf(root.sort) + 1) % order.length];
		Sounds.play("select");
		Qt.callLater(() => root.select(0, true));
	}

	// ── playing ────────────────────────────────────────────────────────────
	// the window of a game that runs: Steam's are steam_app_<id>, others by title
	function windowOf(game) {
		if (!game) return null;
		const name = String(game.name || "").toLowerCase();
		return Niri.windows.find(window => (game.appid && window.app_id === `steam_app_${game.appid}`)) ?? Niri.windows.find(window => name.length > 3 && String(window.title || "").toLowerCase().includes(name) && !/steam/i.test(window.app_id || "")) ?? null;
	}

	function play(game, runner) {
		if (!game || curtain.up) return;
		if (Games.isRunning(game.id)) {
			const window = root.windowOf(game);
			if (window) {
				Niri.focusWindow(window.id);
				Popups.closeModal();
			} else {
				// it runs, but no window says so (yet): not a second time
				Sounds.play("attention");
				nudge.restart();
			}
			return;
		}
		const card = root.grid ? gridView.currentItem : shelf.currentItem;
		let from = Qt.rect(root.width / 2 - 100, root.height - 300, 200, 300);
		if (card) {
			const point = card.mapToItem(curtain, 0, card.height - card.width * 1.5);
			from = Qt.rect(point.x, point.y, card.width, card.width * 1.5);
		}
		root.pendingRunner = runner ?? "";
		curtain.begin(game, from);
		Games.launch(game.id, runner ?? "");
	}

	property string pendingRunner: ""

	function startWith(game) {
		const out = [];
		if (game.gameid && (game.kind === "shortcut" || game.inSteam)) out.push({ icon: "steam", label: "Steam", detail: "As Steam starts it", run: () => root.play(game, "steam") });
		if (game.kind === "custom") {
			if (game.windows) {
				for (const tool of Games.runners) {
					out.push({ icon: tool.kind === "wine" ? "glass_wine" : "microsoft_windows", label: tool.name, detail: tool.kind === "wine" ? "~/.wine" : "A prefix of the game's own", checked: game.runner === tool.id, run: () => root.play(game, tool.id) });
				}
			} else {
				out.push({ icon: "linux", label: "As a Linux program", run: () => root.play(game, "native") });
			}
		}
		return out;
	}

	function menuFor(game) {
		if (!game) return [];
		const running = Games.isRunning(game.id);
		const storeApp = game.kind === "steam" ? game.appid : (String(game.artChoice || "").startsWith("steam:") ? game.artChoice.slice(6) : "");
		const others = root.startWith(game);
		return [
			{ icon: running ? "open_in_new" : "play", label: running ? "Show the game" : "Play", detail: GameText.runnerLabel(game, Games.runners), run: () => root.play(game) },
			{ icon: "tune_variant", label: "Start with", children: others, shown: others.length > 1 || (game.kind === "custom" && others.length > 0) },
			{ icon: "steam", label: "Add to Steam", detail: Games.steamRunning ? "As a non-Steam game; Steam restarts" : "As a non-Steam game", shown: game.kind === "custom" && !game.inSteam && Games.steam, enabled: Games.steamAdding === "", run: () => Games.addToSteam(game.id) },
			{ icon: game.favorite ? "heart_outline" : "heart", label: game.favorite ? "No longer a favourite" : "Favourite", run: () => Games.toggleFavorite(game.id) },
			{ icon: "image_outline", label: "Change cover", run: () => sheet.begin("cover", game) },
			{ icon: "pencil_outline", label: game.kind === "custom" ? "Edit" : "Rename", detail: game.kind === "custom" ? "Name, program, how it starts" : "", run: () => sheet.begin("edit", game) },
			{ icon: "folder_open_outline", label: "Open its folder", shown: !!game.dir, run: () => {
				Popups.closeModal();
				if (Plugins.on("filemanager")) Files.open(game.dir);
				else Qt.openUrlExternally(`file://${game.dir}`);
			} },
			{ icon: "tag_outline", label: "Store page", shown: storeApp !== "", run: () => {
				Popups.closeModal();
				Qt.openUrlExternally(`steam://store/${storeApp}`);
			} },
			{ icon: game.hidden ? "eye_outline" : "eye_off_outline", label: game.hidden ? "Show again" : "Hide", detail: game.hidden ? "" : "The Hidden filter brings it back", run: () => Games.setHidden(game.id, !game.hidden) },
			{ icon: "delete_outline", label: "Remove from the library", detail: "The game itself stays", danger: true, confirm: "Click again to remove", shown: game.kind === "custom", run: () => Games.remove(game.id) }
		];
	}

	function openMenu(x, y) {
		if (!root.selected) return;
		menu.show(root.menuFor(root.selected), x, y);
	}

	modalId: "games"
	scrimColor: Qt.rgba(0, 0, 0, 0.92)

	onShownChanged: {
		Games.watched = root.shown;
		if (!root.shown) {
			curtain.reset();
			sheet.close();
			menu.close();
		}
	}

	onModalOpened: {
		Games.refresh();
		root.query = "";
		search.text = "";
		if (root.filter === "hidden") root.filter = "all";
		root.intro = true;
		introEnd.restart();
		root.selectedId = "";
		const focus = Games.focusId;
		const withMenu = Games.focusMenu;
		const withStats = Games.focusStats;
		Games.focusId = "";
		Games.focusMenu = false;
		Games.focusStats = false;
		Qt.callLater(() => {
			root.select(0, true);
			shelf.positionViewAtBeginning();
			keys.forceActiveFocus();
			// opened from the bar's panel on a game
			if (focus !== "" && root.list.some(game => game.id === focus)) {
				root.selectedId = focus;
				shelf.positionViewAtIndex(root.index, ListView.Beginning);
				if (withMenu) Qt.callLater(() => root.openMenu(root.side + 300, root.height / 2));
				if (withStats) Qt.callLater(() => stats.show(root.selected));
			}
		});
		rising.restart();
	}

	// the views follow the list in place: a change moves or updates a card, never rebuilds them
	SyncedModel {
		id: games
	}

	onListChanged: {
		// the picked game stays picked when it is still there
		if (root.list.length > 0 && !root.list.some(game => game.id === root.selectedId)) root.selectedId = root.list[0].id;
		games.sync(root.list.map(game => Object.assign({ key: game.id }, game)));
		if (shelf.currentIndex !== root.index) shelf.currentIndex = root.index;
		if (gridView.currentIndex !== root.index) gridView.currentIndex = root.index;
	}

	onIndexChanged: {
		if (shelf.currentIndex !== root.index) shelf.currentIndex = root.index;
		if (gridView.currentIndex !== root.index) gridView.currentIndex = root.index;
	}

	onSelectedChanged: infoSwap.restart()

	Behavior on gridness {
		NumberAnimation {
			duration: Motion.extraLong
			easing.type: Easing.BezierSpline
			easing.bezierCurve: Motion.emphasized
		}
	}

	Timer {
		id: introEnd

		interval: 1400
		onTriggered: root.intro = false
	}

	// the library is open: header from above, details from the left
	property real riseHeader: 0
	property real riseInfo: 0

	ParallelAnimation {
		id: rising

		NumberAnimation {
			target: root
			property: "riseHeader"
			from: 0
			to: 1
			duration: Motion.extraLong
			easing.type: Easing.BezierSpline
			easing.bezierCurve: Motion.spatial
		}
		SequentialAnimation {
			PropertyAction {
				target: root
				property: "riseInfo"
				value: 0
			}
			PauseAnimation {
				duration: 160
			}
			NumberAnimation {
				target: root
				property: "riseInfo"
				to: 1
				duration: Motion.extraLong
				easing.type: Easing.BezierSpline
				easing.bezierCurve: Motion.spatial
			}
		}
	}

	// the details of another game come in from the side
	property real infoIn: 1

	NumberAnimation {
		id: infoSwap

		target: root
		property: "infoIn"
		from: 0
		to: 1
		duration: Motion.long
		easing.type: Easing.OutCubic
	}

	Connections {
		target: Games

		function onLaunched(id) {
			if (!curtain.up) return;
			curtain.succeed(Games.launchVia);
			leave.restart();
		}

		function onFailed(id, message) {
			if (curtain.up) curtain.failWith(message);
		}

		function onAddRequested(path) {
			sheet.begin("add", null, path);
		}

		// a gamepad walks the library like the keys do
		function onPad(button) {
			if (!root.shown) return;
			if (curtain.up) {
				if (curtain.phase === "failed" && button === "a") curtain.retry();
				else if (curtain.phase === "failed" && button === "b") curtain.back();
				return;
			}
			if (sheet.open) {
				if (button === "b") sheet.close();
				else if (button === "start") sheet.save();
				return;
			}
			if (menu.open) {
				const count = Math.max(1, menu.shown.length);
				if (button === "up") menu.at = (menu.at - 1 + count) % count;
				else if (button === "down") menu.at = (menu.at + 1) % count;
				else if (button === "a" || button === "right") menu.run(menu.shown[menu.at]);
				else if (button === "b" || button === "left") menu.back();
				return;
			}
			const columns = Math.max(1, Math.floor(gridView.width / gridView.cellWidth));
			switch (button) {
			case "left":
				root.step(-1);
				break;
			case "right":
				root.step(1);
				break;
			case "up":
				if (root.grid) root.step(-columns);
				break;
			case "down":
				if (root.grid) root.step(columns);
				break;
			case "a":
				root.play(root.selected);
				break;
			case "b":
				if (root.query !== "") {
					root.query = "";
					search.text = "";
				} else {
					Popups.closeModal();
				}
				break;
			case "x":
				if (root.selected) {
					Games.toggleFavorite(root.selected.id);
					heartPop.restart();
				}
				break;
			case "y":
			case "start":
				root.openMenu(root.side + 300, root.height / 2);
				break;
			case "lb":
				root.cycleFilter(-1);
				break;
			case "rb":
				root.cycleFilter(1);
				break;
			case "select":
				root.toggleGrid();
				break;
			}
		}
	}

	// once it started the library gives way
	Timer {
		id: leave

		interval: 1300
		onTriggered: Popups.closeModal()
	}

	// ── behind everything: the picked game ─────────────────────────────────
	Backdrop {
		anchors.fill: parent
		game: root.selected
		recede: root.gridness
	}

	// a click on nothing is not one beside the library
	MouseArea {
		anchors.fill: parent
		acceptedButtons: Qt.AllButtons
		onClicked: keys.forceActiveFocus()
	}

	Item {
		id: keys

		anchors.fill: parent
		focus: true

		Keys.onPressed: event => {
			Games.padUsed = false;
			if (root.busy) return;
			const ctrl = event.modifiers & Qt.ControlModifier;
			const columns = Math.max(1, Math.floor(gridView.width / gridView.cellWidth));
			switch (event.key) {
			case Qt.Key_Left:
				root.step(-1);
				break;
			case Qt.Key_Right:
				root.step(1);
				break;
			case Qt.Key_Up:
				if (root.grid) root.step(-columns);
				else search.input.forceActiveFocus();
				break;
			case Qt.Key_Down:
				if (root.grid) root.step(columns);
				break;
			case Qt.Key_Home:
				root.select(0);
				break;
			case Qt.Key_End:
				root.select(root.list.length - 1);
				break;
			case Qt.Key_PageUp:
				root.step(root.grid ? -columns * 3 : -6);
				break;
			case Qt.Key_PageDown:
				root.step(root.grid ? columns * 3 : 6);
				break;
			case Qt.Key_Return:
			case Qt.Key_Enter:
			case Qt.Key_Space:
				root.play(root.selected);
				break;
			case Qt.Key_Tab:
				root.cycleFilter(1);
				break;
			case Qt.Key_Backtab:
				root.cycleFilter(-1);
				break;
			case Qt.Key_Menu:
				root.openMenu(root.side + 300, root.height / 2);
				break;
			case Qt.Key_Escape:
				if (root.query !== "") {
					root.query = "";
					search.text = "";
				} else {
					Popups.closeModal();
				}
				break;
			case Qt.Key_N:
				if (!ctrl) return root.typeAhead(event);
				sheet.begin("add", null, "");
				break;
			case Qt.Key_F:
				if (!ctrl) return root.typeAhead(event);
				search.input.forceActiveFocus();
				break;
			default:
				root.typeAhead(event);
				return;
			}
			event.accepted = true;
		}
	}

	// letters go to the search; a few of them, alone, are shortcuts while it is empty
	function typeAhead(event) {
		const text = String(event.text || "");
		if (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) return;
		if (root.query === "") {
			if (text === "g" || text === "G") {
				root.toggleGrid();
				event.accepted = true;
				return;
			}
			if (text === "*") {
				if (root.selected) Games.toggleFavorite(root.selected.id);
				event.accepted = true;
				return;
			}
			if (text === "+") {
				sheet.begin("add", null, "");
				event.accepted = true;
				return;
			}
			if ((text === "i" || text === "I") && root.selected) {
				stats.show(root.selected);
				event.accepted = true;
				return;
			}
		}
		if (/^\S$/.test(text)) {
			search.input.forceActiveFocus();
			search.text = search.text + text;
			root.query = search.text;
			event.accepted = true;
		}
	}

	// a program dragged over the library is added
	DropArea {
		id: drop

		anchors.fill: parent
		enabled: !sheet.open
		keys: ["text/uri-list"]
		onDropped: event => {
			if (event.hasUrls && event.urls.length > 0) sheet.begin("add", null, decodeURIComponent(String(event.urls[0]).replace(/^file:\/\//, "")));
		}
	}

	// ── the header ─────────────────────────────────────────────────────────
	RowLayout {
		id: header

		anchors.left: parent.left
		anchors.right: parent.right
		anchors.top: parent.top
		anchors.leftMargin: root.side
		anchors.rightMargin: root.side
		anchors.topMargin: 34
		spacing: 28
		opacity: root.riseHeader
		transform: Translate {
			y: -30 * (1 - root.riseHeader)
		}

		RowLayout {
			spacing: 10

			Glyph {
				icon: "gamepad_variant"
				size: 26
				color: Theme.primary
				surface: "transparent"
			}

			StyledText {
				text: "Games"
				tone: "white"
				surface: "transparent"
				font.pixelSize: 24
				font.weight: Font.Black
			}
		}

		// the filters, a line under the one that is on
		Item {
			id: tabs

			Layout.preferredHeight: 40
			Layout.preferredWidth: tabRow.implicitWidth

			Row {
				id: tabRow

				anchors.verticalCenter: parent.verticalCenter
				spacing: 6

				Repeater {
					id: tabRepeater

					model: root.filters

					delegate: Clickable {
						id: tab

						required property var modelData
						required property int index
						readonly property bool on: root.filter === tab.modelData.id

						implicitWidth: tabLine.implicitWidth + 24
						implicitHeight: 36
						radius: 18
						color: "transparent"
						tint: "white"
						sound: ""
						onClicked: root.setFilter(tab.modelData.id)

						RowLayout {
							id: tabLine

							anchors.centerIn: parent
							spacing: 6

							StyledText {
								text: tab.modelData.label
								tone: tab.on ? "white" : Qt.rgba(1, 1, 1, 0.55)
								surface: "transparent"
								font.pixelSize: Theme.size.title
								font.weight: tab.on ? Font.Bold : Font.Medium

								Behavior on tone {
									ColorAnim {}
								}
							}

							StyledText {
								text: tab.modelData.count
								tone: tab.on ? Theme.primary : Qt.rgba(1, 1, 1, 0.3)
								surface: "transparent"
								font.pixelSize: Theme.size.small
								font.weight: Font.Bold
							}
						}
					}
				}
			}

			Rectangle {
				readonly property var item: tabRepeater.itemAt(Math.max(0, root.filters.findIndex(tab => tab.id === root.filter)))

				x: item ? item.x + 12 : 0
				y: parent.height - 3
				width: item ? item.width - 24 : 0
				height: 3
				radius: 1.5
				color: Theme.primary

				Behavior on x {
					SpatialAnim {
						duration: Motion.long
					}
				}
				Behavior on width {
					SpatialAnim {
						duration: Motion.long
					}
				}
			}
		}

		Item {
			Layout.fillWidth: true
		}

		StyledText {
			visible: root.width >= 1700
			text: `${root.filters[0]?.count ?? 0} games${root.totalMinutes > 60 ? ` · ${GameText.hours(root.totalMinutes)} h played` : ""}`
			tone: Qt.rgba(1, 1, 1, 0.45)
			surface: "transparent"
			font.pixelSize: Theme.size.body
		}

		Field {
			id: search

			Layout.preferredWidth: (search.focused || root.query !== "" ? 340 : 240) * (root.width < 1500 ? 0.8 : 1)
			implicitHeight: 40
			icon: "magnify"
			placeholder: "Search games"
			color: Qt.rgba(1, 1, 1, 0.1)
			onEdited: text => root.query = text
			onAccepted: {
				root.select(0, true);
				keys.forceActiveFocus();
				if (root.selected && root.query !== "") root.play(root.selected);
			}
			onEscapePressed: {
				if (search.text !== "") {
					search.text = "";
					root.query = "";
				}
				keys.forceActiveFocus();
			}
			onDownPressed: keys.forceActiveFocus()

			Behavior on Layout.preferredWidth {
				SpatialAnim {
					duration: Motion.long
				}
			}
		}

		Row {
			spacing: 6

			IconButton {
				implicitWidth: 40
				implicitHeight: 40
				icon: root.sort === "name" ? "sort_ascending" : (root.sort === "playtime" ? "clock_outline" : "history")
				iconColor: "white"
				visible: root.filter !== "recent"
				onClicked: root.cycleSort()
			}

			IconButton {
				implicitWidth: 40
				implicitHeight: 40
				icon: root.grid ? "view_column_outline" : "view_grid_outline"
				iconColor: "white"
				onClicked: root.toggleGrid()
			}

			IconButton {
				implicitWidth: 40
				implicitHeight: 40
				variant: "filled"
				icon: "plus"
				onClicked: sheet.begin("add", null, "")
			}
		}
	}

	// how the list is sorted, said for a moment when it changes
	Rectangle {
		id: sortSay

		anchors.top: header.bottom
		anchors.topMargin: 10
		anchors.right: parent.right
		anchors.rightMargin: root.side + 50
		width: sortText.implicitWidth + 22
		height: 28
		radius: 14
		color: Qt.rgba(0, 0, 0, 0.6)
		opacity: 0

		StyledText {
			id: sortText

			anchors.centerIn: parent
			text: root.sort === "name" ? "By name" : (root.sort === "playtime" ? "Most played first" : "Last played first")
			tone: "white"
			surface: "transparent"
			font.pixelSize: Theme.size.small
			font.weight: Font.DemiBold
		}

		SequentialAnimation {
			id: sortFlash

			NumberAnimation {
				target: sortSay
				property: "opacity"
				to: 1
				duration: Motion.short
			}
			PauseAnimation {
				duration: 1100
			}
			NumberAnimation {
				target: sortSay
				property: "opacity"
				to: 0
				duration: Motion.long
			}
		}
	}

	onSortChanged: sortFlash.restart()

	// ── the picked game ────────────────────────────────────────────────────
	ColumnLayout {
		id: info

		anchors.left: parent.left
		anchors.leftMargin: root.side
		anchors.bottom: shelf.top
		anchors.bottomMargin: 34
		width: Math.min(parent.width * 0.5, 760)
		spacing: 16
		visible: root.selected !== null && root.gridness < 0.99
		opacity: root.riseInfo * (1 - root.gridness) * (0.3 + 0.7 * root.infoIn)
		transform: Translate {
			x: -40 * (1 - root.riseInfo) + 18 * (1 - root.infoIn)
			y: 60 * root.gridness
		}

		// the logo, or the name where there is none
		Item {
			Layout.preferredWidth: Math.min(info.width, 560)
			Layout.preferredHeight: logo.status === Image.Ready && logo.source != "" ? Math.min(160, logo.paintedHeight) : title.implicitHeight

			Image {
				id: logo

				anchors.left: parent.left
				anchors.bottom: parent.bottom
				width: Math.min(info.width, 560)
				height: 160
				source: root.selected?.art?.logo ? `file://${root.selected.art.logo}` : ""
				fillMode: Image.PreserveAspectFit
				horizontalAlignment: Image.AlignLeft
				verticalAlignment: Image.AlignBottom
				asynchronous: true
				sourceSize.width: 1120
				visible: false
			}

			MultiEffect {
				anchors.fill: logo
				source: logo
				visible: logo.status === Image.Ready && logo.source != ""
				shadowEnabled: true
				shadowBlur: 0.8
				shadowOpacity: 0.7
				shadowColor: "black"
			}

			StyledText {
				id: title

				anchors.left: parent.left
				anchors.bottom: parent.bottom
				width: info.width
				visible: !(logo.status === Image.Ready && logo.source != "")
				text: root.selected?.name ?? ""
				tone: "white"
				surface: "transparent"
				wrapMode: Text.WordWrap
				maximumLineCount: 2
				elide: Text.ElideRight
				font.pixelSize: 56
				font.weight: Font.Black
				lineHeight: 0.95
				style: Text.Normal
			}
		}

		// what is known about it
		Flow {
			Layout.fillWidth: true
			spacing: 8

			Repeater {
				model: {
					const game = root.selected;
					if (!game) return [];
					const out = [];
					if (root.running) out.push({ icon: "", text: "Playing now", tone: Theme.success, live: true });
					if (game.missing) out.push({ icon: "alert", text: "The program is gone", tone: Theme.danger });
					if (game.updating) out.push({ icon: "download", text: "Update pending", tone: Theme.warning });
					out.push({ icon: GameText.kindIcon(game), text: Games.steamAdding === game.id ? Games.steamProgress : GameText.runnerLabel(game, Games.runners) });
					const time = GameText.playtime(game.playtime);
					if (time) out.push({ icon: "clock_outline", text: time });
					const last = GameText.ago(game.lastPlayed);
					out.push({ icon: "history", text: last || "Not played yet" });
					const size = Format.bytes(game.size, "");
					if (size) out.push({ icon: "harddisk", text: size });
					return out;
				}

				delegate: Rectangle {
					id: fact

					required property var modelData
					required property int index

					width: factRow.implicitWidth + 22
					height: 30
					radius: 15
					color: fact.modelData.tone ? Qt.alpha(fact.modelData.tone, 0.2) : Qt.rgba(1, 1, 1, 0.1)
					border.width: 1
					border.color: fact.modelData.tone ? Qt.alpha(fact.modelData.tone, 0.45) : Qt.rgba(1, 1, 1, 0.08)
					opacity: Math.max(0, Math.min(1, root.infoIn * 4 - fact.index * 0.5))

					RowLayout {
						id: factRow

						anchors.centerIn: parent
						spacing: 6

						Rectangle {
							visible: !!fact.modelData.live
							Layout.preferredWidth: 7
							Layout.preferredHeight: 7
							radius: 3.5
							color: Theme.success

							SequentialAnimation on opacity {
								running: !!fact.modelData.live && root.shown
								loops: Animation.Infinite

								NumberAnimation {
									to: 0.3
									duration: 800
								}
								NumberAnimation {
									to: 1
									duration: 800
								}
							}
						}

						Glyph {
							visible: fact.modelData.icon !== ""
							icon: fact.modelData.icon || "circle_small"
							size: 15
							color: fact.modelData.tone ?? Qt.rgba(1, 1, 1, 0.8)
							surface: "transparent"
						}

						StyledText {
							text: fact.modelData.text
							tone: fact.modelData.tone ?? Qt.rgba(1, 1, 1, 0.88)
							surface: "transparent"
							font.pixelSize: Theme.size.body
							font.weight: Font.Medium
						}
					}
				}
			}
		}

		// ── what to do ─────────────────────────────────────────────────────
		RowLayout {
			Layout.topMargin: 6
			spacing: 12

			Item {
				id: playButton

				readonly property bool busy: Games.launching !== "" && Games.launching === root.selected?.id

				Layout.preferredWidth: Math.max(190, playRow.implicitWidth + 56)
				Layout.preferredHeight: 58

				Behavior on Layout.preferredWidth {
					SpatialAnim {
						duration: Motion.medium
					}
				}

				RectangularShadow {
					anchors.fill: playFace
					radius: playFace.radius
					blur: playMouse.containsMouse ? 40 : 24
					offset.y: 8
					color: Qt.alpha(root.running ? Theme.success : Theme.primary, 0.5)
					scale: playFace.scale

					Behavior on blur {
						Anim {}
					}
				}

				SequentialAnimation {
					id: nudge

					NumberAnimation {
						target: playFace
						property: "anchors.horizontalCenterOffset"
						to: 8
						duration: 50
					}
					NumberAnimation {
						target: playFace
						property: "anchors.horizontalCenterOffset"
						to: -6
						duration: 70
					}
					NumberAnimation {
						target: playFace
						property: "anchors.horizontalCenterOffset"
						to: 3
						duration: 60
					}
					NumberAnimation {
						target: playFace
						property: "anchors.horizontalCenterOffset"
						to: 0
						duration: 50
					}
				}

				Rectangle {
					id: playFace

					anchors.verticalCenter: parent.verticalCenter
					anchors.horizontalCenter: parent.horizontalCenter
					width: parent.width
					height: parent.height
					radius: height / 2
					color: root.running ? Theme.success : Theme.primary
					scale: playMouse.pressed ? 0.95 : (playMouse.containsMouse ? 1.04 : 1)
					clip: true

					Behavior on color {
						ColorAnim {}
					}
					Behavior on scale {
						SpatialAnim {
							duration: Motion.medium
						}
					}

					// light runs over it now and then, more often while pointed at
					Rectangle {
						id: glint

						property real travel: 0

						width: 80
						height: parent.height * 2
						y: -parent.height / 2
						rotation: 20
						x: -width + (parent.width + width * 2) * glint.travel
						gradient: Gradient {
							orientation: Gradient.Horizontal
							GradientStop {
								position: 0
								color: Qt.rgba(1, 1, 1, 0)
							}
							GradientStop {
								position: 0.5
								color: Qt.rgba(1, 1, 1, 0.3)
							}
							GradientStop {
								position: 1
								color: Qt.rgba(1, 1, 1, 0)
							}
						}

						SequentialAnimation on travel {
							running: root.shown && !root.busy
							loops: Animation.Infinite

							NumberAnimation {
								from: 0
								to: 1
								duration: 900
								easing.type: Easing.InOutQuad
							}
							PauseAnimation {
								duration: playMouse.containsMouse ? 600 : 4200
							}
						}
					}

					RowLayout {
						id: playRow

						anchors.centerIn: parent
						spacing: 10

						Glyph {
							icon: root.running ? "open_in_new" : "play"
							size: 26
							color: Theme.onPrimary
							surface: playFace.color
						}

						StyledText {
							text: root.running ? "Playing" : "Play"
							tone: Theme.onPrimary
							surface: playFace.color
							font.pixelSize: 20
							font.weight: Font.Black
						}
					}
				}

				MouseArea {
					id: playMouse

					anchors.fill: parent
					hoverEnabled: true
					cursorShape: Qt.PointingHandCursor
					onClicked: {
						Sounds.play("click");
						root.play(root.selected);
					}
				}
			}

			// a favourite: the heart pops
			IconButton {
				id: heart

				implicitWidth: 52
				implicitHeight: 52
				radius: 26
				variant: "tonal"
				color: Qt.rgba(1, 1, 1, 0.12)
				icon: root.selected?.favorite ? "heart" : "heart_outline"
				iconColor: root.selected?.favorite ? "#ff5d7a" : "white"
				sound: ""
				onClicked: {
					Games.toggleFavorite(root.selected.id);
					heartPop.restart();
				}

				SequentialAnimation {
					id: heartPop

					NumberAnimation {
						target: heart
						property: "scale"
						to: 1.25
						duration: 120
						easing.type: Easing.OutQuad
					}
					NumberAnimation {
						target: heart
						property: "scale"
						to: 1
						duration: 380
						easing.type: Easing.OutBack
					}
				}
			}

			IconButton {
				implicitWidth: 52
				implicitHeight: 52
				radius: 26
				variant: "tonal"
				color: Qt.rgba(1, 1, 1, 0.12)
				visible: root.selected?.kind === "custom" && !root.selected?.inSteam && Games.steam
				icon: "steam"
				iconColor: "white"
				enabled: Games.steamAdding === ""
				onClicked: Games.addToSteam(root.selected.id)

				Spinner {
					anchors.fill: parent
					anchors.margins: 4
					visible: Games.steamAdding !== "" && Games.steamAdding === root.selected?.id
					color: Theme.primary
				}
			}

			// the landing page: how far along, how long it takes, the last weeks
			IconButton {
				implicitWidth: 52
				implicitHeight: 52
				radius: 26
				variant: "tonal"
				color: Qt.rgba(1, 1, 1, 0.12)
				icon: "chart_bar"
				iconColor: "white"
				onClicked: if (root.selected) stats.show(root.selected)
			}

			IconButton {
				id: moreButton

				implicitWidth: 52
				implicitHeight: 52
				radius: 26
				variant: "tonal"
				color: Qt.rgba(1, 1, 1, 0.12)
				icon: "dots_horizontal"
				iconColor: "white"
				onClicked: {
					const at = moreButton.mapToItem(null, 0, moreButton.height + 8);
					root.openMenu(at.x, at.y);
				}
			}
		}
	}

	// ── the shelf ──────────────────────────────────────────────────────────
	ListView {
		id: shelf

		anchors.left: parent.left
		anchors.right: parent.right
		anchors.bottom: parent.bottom
		anchors.bottomMargin: 64
		height: root.bigW * 1.5 + 40
		orientation: ListView.Horizontal
		spacing: 22
		leftMargin: root.side
		rightMargin: root.width
		model: games
		highlightRangeMode: ListView.StrictlyEnforceRange
		preferredHighlightBegin: root.side
		preferredHighlightEnd: root.side + root.bigW
		highlightMoveDuration: 420
		highlightMoveVelocity: -1
		highlightResizeDuration: 0
		boundsBehavior: Flickable.StopAtBounds
		interactive: root.gridness < 0.5
		visible: root.gridness < 0.99
		opacity: 1 - root.gridness
		cacheBuffer: root.cardW * 6
		transform: Translate {
			y: 80 * root.gridness
		}

		onCurrentIndexChanged: {
			// a flick moves what is picked (a change of the list does not)
			if ((shelf.moving || shelf.dragging) && shelf.currentIndex >= 0 && shelf.currentIndex < root.list.length && root.list[shelf.currentIndex].id !== root.selectedId) root.select(shelf.currentIndex);
		}

		WheelHandler {
			acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
			onWheel: event => {
				const delta = event.angleDelta.y !== 0 ? event.angleDelta.y : event.angleDelta.x;
				if (Math.abs(delta) < 30) return;
				root.step(delta > 0 ? -1 : 1);
			}
		}

		displaced: Transition {
			SpatialAnim {
				property: "x"
				duration: Motion.long
			}
		}

		delegate: Item {
			id: slot

			required property string json
			required property int index
			readonly property var modelData: JSON.parse(slot.json)
			readonly property bool current: slot.index === root.index
			readonly property bool passed: slot.index < root.index

			width: slot.current ? root.bigW : root.cardW
			height: shelf.height
			opacity: slot.passed ? 0 : (slot.current ? 1 : 0.72)

			Behavior on width {
				SpatialAnim {
					duration: Motion.long
				}
			}
			Behavior on opacity {
				Anim {
					duration: Motion.long
				}
			}

			GameCard {
				anchors.bottom: parent.bottom
				anchors.bottomMargin: 14
				width: parent.width
				height: parent.width * 1.5
				game: slot.modelData
				current: slot.current
				appearDelay: root.intro ? Math.min(slot.index, 10) * 55 + 120 : -1
				onPicked: root.select(slot.index)
				onActivated: root.play(slot.modelData)
				onMenuAsked: (x, y) => root.openMenu(x, y)
			}
		}
	}

	// ── the grid ───────────────────────────────────────────────────────────
	GridView {
		id: gridView

		readonly property real cell: Math.max(150, Math.min(200, root.cardW * 0.9))

		anchors.fill: parent
		anchors.topMargin: header.y + header.height + 30
		anchors.leftMargin: root.side - 14
		anchors.rightMargin: root.side - 14
		cellWidth: Math.floor(width / Math.max(1, Math.floor(width / (gridView.cell + 34))))
		cellHeight: gridView.cell * 1.5 + 70
		model: games
		clip: true
		visible: root.gridness > 0.01
		opacity: root.gridness
		scale: 0.96 + 0.04 * root.gridness
		interactive: root.grid
		highlightFollowsCurrentItem: false
		boundsBehavior: Flickable.StopAtBounds
		topMargin: 14
		bottomMargin: 40
		cacheBuffer: 600

		onCurrentIndexChanged: gridView.positionViewAtIndex(gridView.currentIndex, GridView.Contain)

		ScrollBar.vertical: ThinScrollBar {}

		add: Transition {
			ParallelAnimation {
				Anim {
					property: "opacity"
					from: 0
					to: 1
					duration: Motion.long
				}
				SpatialAnim {
					property: "scale"
					from: 0.8
					to: 1
					duration: Motion.long
				}
			}
		}
		remove: Transition {
			ParallelAnimation {
				Anim {
					property: "opacity"
					to: 0
					duration: Motion.medium
				}
				Anim {
					property: "scale"
					to: 0.85
					duration: Motion.medium
				}
			}
		}
		displaced: Transition {
			SpatialAnim {
				properties: "x,y"
				duration: Motion.long
			}
		}

		delegate: Item {
			id: cell

			required property string json
			required property int index
			readonly property var modelData: JSON.parse(cell.json)

			width: gridView.cellWidth
			height: gridView.cellHeight

			GameCard {
				anchors.horizontalCenter: parent.horizontalCenter
				y: 10
				width: gridView.cell
				height: gridView.cell * 1.5
				game: cell.modelData
				current: cell.index === root.index
				currentScale: 1.05
				showName: true
				appearDelay: root.grid && root.gridness < 1 ? Math.min(cell.index, 24) * 22 : -1
				onPicked: root.select(cell.index)
				onActivated: root.play(cell.modelData)
				onMenuAsked: (x, y) => root.openMenu(x, y)
			}
		}
	}

	// ── nothing to show ────────────────────────────────────────────────────
	ColumnLayout {
		anchors.centerIn: parent
		spacing: 14
		visible: root.list.length === 0 && Games.loaded
		opacity: visible ? 1 : 0

		Behavior on opacity {
			Anim {
				duration: Motion.long
			}
		}

		Glyph {
			id: emptyGlyph

			Layout.alignment: Qt.AlignHCenter
			icon: root.query !== "" ? "magnify" : "gamepad_variant"
			size: 72
			color: Qt.alpha(Theme.primary, 0.8)
			surface: "transparent"

			SequentialAnimation on rotation {
				running: emptyGlyph.visible && root.query === "" && root.shown
				loops: Animation.Infinite

				NumberAnimation {
					to: 8
					duration: 1400
					easing.type: Easing.InOutSine
				}
				NumberAnimation {
					to: -8
					duration: 1400
					easing.type: Easing.InOutSine
				}
			}
		}

		StyledText {
			Layout.alignment: Qt.AlignHCenter
			text: root.query !== "" ? `Nothing called “${root.query}”` : (Games.games.length === 0 ? "No games yet" : "Nothing here")
			tone: "white"
			surface: "transparent"
			font.pixelSize: Theme.size.display
			font.weight: Font.Bold
		}

		StyledText {
			Layout.alignment: Qt.AlignHCenter
			text: root.query !== "" ? "Escape clears the search" : (Games.games.length === 0 ? (Games.steam ? "Steam's installed games show up here, and every program you add." : "Add a game by its program – or drop one here.") : "Another filter has more")
			tone: Qt.rgba(1, 1, 1, 0.6)
			surface: "transparent"
			font.pixelSize: Theme.size.title
		}

		TextButton {
			Layout.alignment: Qt.AlignHCenter
			Layout.topMargin: 8
			visible: root.query === ""
			variant: "filled"
			implicitHeight: 44
			text: "Add a game"
			icon: "plus"
			onClicked: sheet.begin("add", null, "")
		}
	}

	Spinner {
		anchors.centerIn: parent
		width: 36
		height: 36
		visible: !Games.loaded
		color: Theme.primary
	}

	// ── the keys ───────────────────────────────────────────────────────────
	Row {
		anchors.right: parent.right
		anchors.bottom: parent.bottom
		anchors.rightMargin: root.side
		anchors.bottomMargin: 22
		spacing: 18
		opacity: 0.5 * root.riseHeader

		Repeater {
			model: Games.padUsed && Games.pads > 0 ? [
				{ key: "A", what: root.running ? "Show" : "Play" },
				{ key: "✛", what: "Browse" },
				{ key: "LB RB", what: "Filter" },
				{ key: "X", what: "Favourite" },
				{ key: "Y", what: "More" },
				{ key: "Select", what: root.grid ? "Shelf" : "Grid" },
				{ key: "B", what: root.query !== "" ? "Clear" : "Close" }
			] : [
				{ key: "↵", what: root.running ? "Show" : "Play" },
				{ key: root.grid ? "←↑→↓" : "← →", what: "Browse" },
				{ key: "Tab", what: "Filter" },
				{ key: "G", what: root.grid ? "Shelf" : "Grid" },
				{ key: "*", what: "Favourite" },
				{ key: "I", what: "Stats" },
				{ key: "☰", what: "More" },
				{ key: "+", what: "Add" },
				{ key: "Esc", what: root.query !== "" ? "Clear" : "Close" }
			]

			delegate: Row {
				id: hint

				required property var modelData

				spacing: 6

				Rectangle {
					anchors.verticalCenter: parent.verticalCenter
					width: Math.max(22, keyText.implicitWidth + 12)
					height: 20
					radius: 5
					color: Qt.rgba(1, 1, 1, 0.1)
					border.width: 1
					border.color: Qt.rgba(1, 1, 1, 0.14)

					StyledText {
						id: keyText

						anchors.centerIn: parent
						text: hint.modelData.key
						tone: "white"
						surface: "transparent"
						font.pixelSize: Theme.size.tiny
						font.weight: Font.Bold
					}
				}

				StyledText {
					anchors.verticalCenter: parent.verticalCenter
					text: hint.modelData.what
					tone: "white"
					surface: "transparent"
					font.pixelSize: Theme.size.small
				}
			}
		}
	}

	// ── a program over the library ─────────────────────────────────────────
	Rectangle {
		anchors.fill: parent
		anchors.margins: 28
		radius: Theme.radius.huge
		color: Qt.alpha(Theme.primary, 0.12)
		border.width: 3
		border.color: Theme.primary
		opacity: drop.containsDrag ? 1 : 0
		scale: drop.containsDrag ? 1 : 1.03
		z: 30

		Behavior on opacity {
			Anim {}
		}
		Behavior on scale {
			SpatialAnim {
				duration: Motion.medium
			}
		}

		ColumnLayout {
			anchors.centerIn: parent
			spacing: 10

			Glyph {
				Layout.alignment: Qt.AlignHCenter
				icon: "plus"
				size: 64
				color: Theme.primary
				surface: "transparent"
			}

			StyledText {
				Layout.alignment: Qt.AlignHCenter
				text: "Drop to add the game"
				tone: "white"
				surface: "transparent"
				font.pixelSize: Theme.size.display
				font.weight: Font.Bold
			}
		}
	}

	GameSheet {
		id: sheet

		onDone: id => {
			root.selectedId = id;
			Qt.callLater(() => {
				shelf.positionViewAtIndex(root.index, ListView.Beginning);
				keys.forceActiveFocus();
			});
		}
		onOpenChanged: if (!sheet.open) keys.forceActiveFocus()
	}

	GameStats {
		id: stats

		onClosed: keys.forceActiveFocus()
	}

	GameMenu {
		id: menu

		onClosed: keys.forceActiveFocus()
	}

	LaunchCurtain {
		id: curtain

		onRetry: {
			const game = curtain.game;
			curtain.reset();
			root.play(game, root.pendingRunner);
		}
		onBack: {
			curtain.reset();
			keys.forceActiveFocus();
		}
	}

	// the file chooser is a window: the library steps aside while it is up
	aside: Games.picking
}
