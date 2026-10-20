pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import qs.style.theme
import qs.style.widgets
import qs.core.services
import qs.core.views.files

// Launcher >file with the file manager on: the folders looked into lately,
// favourites and the files opened lately; typed words search the home
// folder as you type, the one under the cursor large on the right.
// Enter opens, Ctrl+Enter shows it in Files, Shift+Enter looks at it
// (quick look), Alt+Enter searches in the Files window.
Item {
	id: root

	property string argument: ""
	property bool active: false
	property int currentIndex: 0
	property var found: []
	property bool searching: false
	property string searchId: ""
	readonly property string query: root.argument.trim()

	signal closeRequested

	// without words: what was used lately, by kind
	readonly property var recentRows: {
		const out = [];
		const seen = new Set();
		for (const path of FileLibrary.favorites) {
			if (seen.has(path)) continue;
			seen.add(path);
			out.push({ path: path, name: Files.nameOf(path), dir: true, group: "Favorites", mime: "inode/directory" });
		}
		for (const entry of FileLibrary.visited.slice(0, 12)) {
			if (seen.has(entry.path)) continue;
			seen.add(entry.path);
			out.push({ path: entry.path, name: Files.nameOf(entry.path), dir: true, group: "Folders lately", mime: "inode/directory", when: entry.at });
		}
		for (const entry of FileLibrary.opened.slice(0, 12)) {
			if (seen.has(entry.path)) continue;
			seen.add(entry.path);
			out.push({ path: entry.path, name: Files.nameOf(entry.path), dir: false, group: "Opened lately", mime: "", when: entry.at });
		}
		return out;
	}
	readonly property var rows: root.query === "" ? root.recentRows : root.found
	readonly property var current: root.rows[root.currentIndex] ?? null

	onActiveChanged: {
		if (root.active) {
			root.currentIndex = 0;
			root.look();
		} else {
			root.found = [];
		}
	}
	onQueryChanged: {
		root.currentIndex = 0;
		searchTimer.restart();
	}

	Timer {
		id: searchTimer

		interval: 140
		onTriggered: root.look()
	}

	function look() {
		if (!root.active || root.query === "") {
			root.found = [];
			root.searching = false;
			return;
		}
		root.searchId = `launcher-${Date.now()}`;
		root.found = [];
		root.searching = true;
		Files.request("search", { search: root.searchId, root: Files.home, query: root.query, contents: false, hidden: false, limit: 80 });
	}

	Connections {
		target: Files

		function onSearchResults(search, entries, done, error) {
			if (search !== root.searchId) return;
			if (entries.length > 0) root.found = root.found.concat(entries.map(entry => Object.assign(entry, { group: "" })));
			if (done) root.searching = false;
		}
	}

	// the details of the one under the cursor (a picture, its size, a folder's count)
	property var info: null

	onCurrentChanged: infoTimer.restart()

	Timer {
		id: infoTimer

		interval: 80
		onTriggered: {
			const path = root.current?.path ?? "";
			if (path === "") {
				root.info = null;
				return;
			}
			Files.request("info", { path: path }, (data, error) => {
				if (root.current?.path === path) root.info = error ? null : data;
			});
		}
	}

	function move(delta) {
		root.select(root.currentIndex + delta);
	}

	function select(index) {
		if (root.rows.length === 0) return;
		root.currentIndex = Math.max(0, Math.min(root.rows.length - 1, index));
		list.positionViewAtIndex(root.currentIndex, ListView.Contain);
	}

	function handleKey(event) {
		return false;
	}

	function cancel() {
		return false;
	}

	function activate(modifiers) {
		const row = root.current;
		const shift = (modifiers & Qt.ShiftModifier) !== 0;
		const ctrl = (modifiers & Qt.ControlModifier) !== 0;
		const alt = (modifiers & Qt.AltModifier) !== 0;
		if (alt || (!row && root.query !== "")) {
			root.closeRequested();
			Files.searchFor(root.query);
			return;
		}
		if (!row) {
			root.closeRequested();
			Files.open("");
			return;
		}
		root.closeRequested();
		if (row.dir) Files.open(row.path);
		else if (shift) Files.look(row.path);
		else if (ctrl) Files.reveal([row.path]);
		else Files.launch([row.path]);
	}

	// ── the list ───────────────────────────────────────────────────────────
	ListView {
		id: list

		anchors.left: parent.left
		anchors.top: parent.top
		anchors.bottom: parent.bottom
		width: parent.width * 0.56
		clip: true
		model: root.rows
		currentIndex: root.currentIndex
		boundsBehavior: Flickable.StopAtBounds

		ScrollBar.vertical: ThinScrollBar {}

		delegate: Item {
			id: holder

			required property var modelData
			required property int index
			// a group starts: its name above the first of it
			readonly property bool head: !!holder.modelData.group && (holder.index === 0 || root.rows[holder.index - 1]?.group !== holder.modelData.group)

			width: list.width - 6
			height: row.height + (holder.head ? 28 : 0)

			Text {
				visible: holder.head
				x: 12
				y: 8
				text: String(holder.modelData.group ?? "")
				color: Theme.textSubtle
				font.family: Theme.fontFamily
				font.pixelSize: Theme.size.small
				font.weight: Font.DemiBold
			}

			Rectangle {
				id: row

				readonly property var modelData: holder.modelData
				readonly property int index: holder.index
				readonly property bool selected: row.index === root.currentIndex

				y: holder.head ? 28 : 0
				width: holder.width
				height: 46
				radius: Theme.radius.medium
				color: Qt.alpha(Theme.primary, row.selected ? 0.16 : (rowHover.hovered ? 0.07 : 0))

				Behavior on color {
					ColorAnim {}
				}

				HoverHandler {
					id: rowHover

					onPointChanged: if (rowHover.hovered && Pointer.moved(row, point.position.x, point.position.y)) root.currentIndex = row.index
				}

				TapHandler {
					onTapped: {
						root.currentIndex = row.index;
						root.activate(0);
					}
				}

				FileThumb {
					x: 8
					anchors.verticalCenter: parent.verticalCenter
					width: 34
					height: 34
					compact: true
					radius: 8
					path: row.modelData.path
					name: row.modelData.name
					mime: String(row.modelData.mime ?? "")
					dir: !!row.modelData.dir
					kind: row.modelData.dir ? "folder" : "other"
					thumb: String(row.modelData.thumb ?? "")
					canThumb: !!row.modelData.canThumb
				}

				Column {
					x: 52
					anchors.verticalCenter: parent.verticalCenter
					width: parent.width - 60

					Text {
						width: parent.width
						text: row.modelData.name
						color: Theme.text
						font.family: Theme.fontFamily
						font.pixelSize: Theme.size.body
						font.weight: row.selected ? Font.DemiBold : Font.Normal
						elide: Text.ElideMiddle
					}

					Text {
						width: parent.width
						text: Files.pretty(Files.parentOf(row.modelData.path)) + (row.modelData.when ? `  ·  ${Files.whenText(row.modelData.when)}` : "")
						color: Theme.textSubtle
						font.family: Theme.fontFamily
						font.pixelSize: Theme.size.small
						elide: Text.ElideLeft
					}
				}
			}
		}
	}

	EmptyState {
		anchors.centerIn: list
		visible: root.rows.length === 0
		icon: root.searching ? "magnify" : "folder_search_outline"
		title: root.searching ? "Looking…" : (root.query === "" ? "Nothing opened yet" : "Nothing found")
		subtitle: root.query === "" ? "Type to search your home folder" : "Alt+Enter searches in Files, with its contents"
	}

	// ── the one under the cursor ───────────────────────────────────────────
	Rectangle {
		id: preview

		anchors.right: parent.right
		anchors.top: parent.top
		anchors.bottom: parent.bottom
		anchors.left: list.right
		anchors.leftMargin: 10
		radius: Theme.radius.large
		color: Theme.layer1
		visible: !!root.current

		FileThumb {
			id: big

			x: 14
			y: 14
			width: parent.width - 28
			height: Math.min(parent.height * 0.58, width * 0.8)
			size: "x-large"
			radius: Theme.radius.medium
			path: String(root.info?.path ?? root.current?.path ?? "")
			name: String(root.info?.name ?? root.current?.name ?? "")
			mime: String(root.info?.mime ?? root.current?.mime ?? "")
			dir: !!(root.info?.dir ?? root.current?.dir)
			kind: String(root.info?.mime ?? "").startsWith("image/") ? "image" : (String(root.info?.mime ?? "").startsWith("video/") ? "video" : ((root.info?.dir ?? root.current?.dir) ? "folder" : "other"))
			thumb: String(root.info?.thumb ?? root.current?.thumb ?? "")
			canThumb: !!(root.info?.canThumb ?? root.current?.canThumb)
			isText: !!root.info?.text
			mtime: Number(root.info?.mtime ?? 0)
		}

		Column {
			x: 14
			anchors.top: big.bottom
			anchors.topMargin: 12
			width: parent.width - 28
			spacing: 4

			Text {
				width: parent.width
				text: String(root.current?.name ?? "")
				color: Theme.text
				font.family: Theme.fontFamily
				font.pixelSize: Theme.size.title
				font.weight: Font.DemiBold
				wrapMode: Text.WrapAtWordBoundaryOrAnywhere
				maximumLineCount: 2
				elide: Text.ElideRight
			}

			Text {
				width: parent.width
				text: {
					const info = root.info;
					if (!info) return "";
					if (info.dir) return info.items !== undefined ? `Folder · ${info.items} items` : "Folder";
					return `${info.kind ?? ""} · ${Format.bytes(info.size)} · ${Files.whenText(info.mtime)}`;
				}
				color: Theme.textMuted
				font.family: Theme.fontFamily
				font.pixelSize: Theme.size.small
				wrapMode: Text.WordWrap
			}

			Text {
				width: parent.width
				text: Files.pretty(Files.parentOf(String(root.current?.path ?? "")))
				color: Theme.textSubtle
				font.family: Theme.fontFamily
				font.pixelSize: Theme.size.small
				elide: Text.ElideLeft
			}

			Item {
				width: 1
				height: 6
			}

			Text {
				width: parent.width
				text: root.current?.dir ? "Enter opens it in Files" : "Enter opens · Ctrl+Enter shows it in Files · Shift+Enter looks at it"
				color: Theme.textFaint
				font.family: Theme.fontFamily
				font.pixelSize: Theme.size.tiny
				wrapMode: Text.WordWrap
			}
		}
	}
}
