pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Widgets
import qs.style.theme
import qs.core.services
import qs.style.widgets

// Launcher >tab (plugin browser-launcher, docs/browser.md): the browser's open
// tabs, most recent first, then its bookmarks and history for what is typed.
// Enter brings a tab to the front (and its window in niri) or opens a page;
// Ctrl+W closes the selected tab, Ctrl+M mutes it. Typing also finds tabs
// from the archive and commands for the tab in front (Spur, Hints, Pin …);
// with a query, hosts usually opened around this hour come first
// (WebPage.habit). As >ws (kind
// "workspaces", plugin browser-workspaces) it lists Floorp's workspaces.
ColumnLayout {
	id: root

	property string argument: ""
	property bool active: false
	property string kind: "tabs"
	readonly property string query: String(root.argument || "").trim()
	readonly property var words: root.query.toLowerCase().split(/\s+/).filter(word => word !== "")

	property var found: ({ bookmarks: [], history: [] })
	property string foundQuery: ""

	readonly property var workspaceRows: {
		if (root.kind !== "workspaces") return [];
		return FloorpWorkspaces.workspaces
			.filter(ws => root.words.every(word => String(ws.name).toLowerCase().includes(word)))
			.map(ws => ({ kind: "workspace", section: "Workspaces", title: ws.name, url: "", host: ws.isSelected ? "Now" : "", favicon: "", tab: null, workspace: ws }));
	}

	// with a query, what is usually opened around this hour first (stable otherwise)
	function byHabit(rows) {
		if (root.query === "") return rows;
		return rows.map((row, index) => ({ row: row, index: index, habit: WebPage.habit(row.url) }))
			.sort((a, b) => (b.habit > 0.25 ? b.habit : 0) - (a.habit > 0.25 ? a.habit : 0) || a.index - b.index)
			.map(item => item.row);
	}

	readonly property var tabRows: {
		if (root.kind !== "tabs") return [];
		const rows = [];
		for (const tab of WebLink.recentTabs) {
			const text = [tab.title, tab.host, tab.url, tab.group?.title, tab.container?.name].join(" ").toLowerCase();
			if (root.words.every(word => text.includes(word)))
				rows.push({ kind: "tab", section: "Tabs", title: tab.title || tab.url, url: tab.url, host: tab.host, favicon: tab.favicon || "", tab: tab });
		}
		return root.byHabit(rows);
	}

	// commands for the tab in front, only while typing
	readonly property var commandRows: {
		if (root.kind !== "tabs" || root.query === "" || !WebLink.connected) return [];
		const tab = WebLink.activeTab;
		if (!tab) return [];
		const tabsSet = WebPage.tabs;
		const list = [];
		if (tabsSet.spur.on) list.push({ id: "spur", title: "Spur", icon: "view_column_outline" });
		if (tabsSet.hints.on) list.push({ id: "hints", title: "Hints", icon: "keyboard_outline" });
		list.push({ id: "close", title: "Close tab", icon: "close" });
		list.push({ id: "mute", title: tab.muted ? "Unmute" : "Mute", icon: tab.muted ? "volume_high" : "volume_off" });
		list.push({ id: "pdf", title: "Save as PDF", icon: "file_pdf_box" });
		if (!tab.pinned) {
			const pinned = WebLink.tabs.filter(other => other.source === tab.source && other.windowId === tab.windowId && other.pinned).length;
			if (pinned < 6) list.push({ id: "pin", title: `Pin to ${pinned + 1}`, icon: "pin_outline", slot: pinned + 1 });
		}
		if (tabsSet.envs.on) list.push({ id: "env", title: "Other environment", icon: "swap_horizontal" });
		return list
			.filter(command => root.words.every(word => `${command.title} ${command.id}`.toLowerCase().includes(word)))
			.map(command => ({ kind: "command", section: "Commands", title: command.title, url: "", host: tab.title || tab.host, favicon: "", tab: null, command: command, target: tab }));
	}

	// archived tabs (WebPage.archive), only while typing
	readonly property var archiveRows: {
		if (root.kind !== "tabs" || root.query === "") return [];
		const open = new Set(WebLink.tabs.map(tab => tab.url));
		const rows = [];
		for (const entry of WebPage.archive) {
			if (open.has(entry.url)) continue;
			const text = `${entry.title} ${entry.host} ${entry.url}`.toLowerCase();
			if (root.words.every(word => text.includes(word)))
				rows.push({ kind: "archive", section: "Archive", title: entry.title || entry.url, url: entry.url, host: `${entry.host} · ${Qt.formatDate(new Date(entry.closedAt), "d MMM")}`, favicon: entry.favicon || "", tab: null, entry: entry });
		}
		return rows.slice(0, 20);
	}

	readonly property var pageRows: {
		if (root.kind !== "tabs" || root.foundQuery === "" || root.foundQuery !== root.query) return [];
		const open = new Set(WebLink.tabs.map(tab => tab.url));
		const seen = new Set();
		const rows = [];
		for (const [list, kind, section] of [[root.found.bookmarks, "bookmark", "Bookmarks"], [root.found.history, "history", "History"]]) {
			for (const page of list || []) {
				if (!page.url || open.has(page.url) || seen.has(page.url)) continue;
				seen.add(page.url);
				rows.push({ kind: kind, section: section, title: page.title || page.url, url: page.url, host: page.host || "", favicon: "", tab: null });
			}
		}
		return root.byHabit(rows);
	}

	readonly property var rows: root.kind === "workspaces" ? root.workspaceRows : root.commandRows.concat(root.tabRows, root.archiveRows, root.pageRows)
	readonly property var selected: list.currentIndex >= 0 && list.currentIndex < root.rows.length ? root.rows[list.currentIndex] : null

	signal closeRequested

	spacing: 10

	onQueryChanged: {
		list.currentIndex = 0;
		if (root.query === "" || root.kind !== "tabs") {
			root.found = { bookmarks: [], history: [] };
			root.foundQuery = "";
		} else {
			searchDelay.restart();
		}
	}
	onActiveChanged: {
		if (!root.active) return;
		list.currentIndex = 0;
		if (root.kind === "workspaces") FloorpWorkspaces.refresh();
	}
	onRowsChanged: if (list.currentIndex >= root.rows.length || list.currentIndex < 0) list.currentIndex = root.rows.length > 0 ? 0 : -1

	Timer {
		id: searchDelay

		interval: 140
		onTriggered: {
			const query = root.query;
			if (query === "" || !WebLink.connected) return;
			WebLink.search(query, 8, data => {
				if (query !== root.query) return;
				root.found = data || { bookmarks: [], history: [] };
				root.foundQuery = query;
			});
		}
	}

	function move(delta) {
		if (root.rows.length === 0) return;
		list.currentIndex = Math.max(0, Math.min(root.rows.length - 1, list.currentIndex + delta));
		list.positionViewAtIndex(list.currentIndex, ListView.Contain);
	}

	function handleKey(event) {
		if (!(event.modifiers & Qt.ControlModifier) || !root.selected?.tab) return false;
		if (event.key === Qt.Key_W) {
			WebLink.close(root.selected.tab);
			return true;
		}
		if (event.key === Qt.Key_M) {
			WebLink.mute(root.selected.tab, !root.selected.tab.muted);
			return true;
		}
		return false;
	}

	function cancel() {
		return false;
	}

	function activate(modifiers) {
		if (root.selected) root.pick(root.selected);
	}

	function pick(row) {
		root.closeRequested();
		if (row.workspace) return FloorpWorkspaces.switchTo(row.workspace.id);
		if (row.command) return root.run(row.command, row.target);
		if (row.url) WebPage.noteHabit(row.url);
		if (row.entry) WebPage.reopenArchived(row.entry);
		else if (row.tab) WebLink.activate(row.tab);
		else WebLink.open(row.url);
	}

	function run(command, tab) {
		switch (command.id) {
		case "close": return WebLink.close(tab);
		case "mute": return WebLink.mute(tab, !tab.muted);
		case "pin": return WebLink.command("pin", { tabId: tab.id, slot: command.slot }, null, tab.source);
		case "hints":
			// the page needs the keyboard: the browser in front first
			return WebLink.activate(tab, ok => {
				if (ok) WebLink.command("hints", { mode: "open" }, null, tab.source);
			});
		default:
			return WebLink.activate(tab, ok => {
				if (ok) WebLink.command(command.id, { tabId: tab.id }, null, tab.source);
			});
		}
	}

	function groupColor(name) {
		switch (String(name || "")) {
		case "red": return Theme.danger;
		case "orange":
		case "yellow": return Theme.warning;
		case "green": return Theme.success;
		case "purple":
		case "pink": return Theme.tertiary;
		case "cyan":
		case "blue": return Theme.secondary;
		default: return Theme.primary;
		}
	}

	Item {
		Layout.fillWidth: true
		Layout.fillHeight: true

		ListView {
			id: list

			anchors.fill: parent
			clip: true
			spacing: 2
			model: root.rows
			currentIndex: 0
			boundsBehavior: Flickable.StopAtBounds
			ScrollBar.vertical: ThinScrollBar {}

			section.property: "section"
			section.delegate: StyledText {
				required property string section

				width: list.width
				leftPadding: 12
				topPadding: 8
				bottomPadding: 4
				text: section
				tone: Theme.textMuted
				font.pixelSize: Theme.size.small
				font.weight: Font.DemiBold
			}

			delegate: Clickable {
				id: row

				required property var modelData
				required property int index
				readonly property bool picked: list.currentIndex === row.index
				readonly property var tab: row.modelData.tab

				width: list.width
				implicitHeight: 52
				radius: Theme.radius.large
				pressedScale: 0.98
				showHover: false
				color: row.picked ? Theme.primaryContainer : (row.hovered ? Theme.layer1 : "transparent")
				onPointed: list.currentIndex = row.index
				onClicked: root.pick(row.modelData)

				RowLayout {
					anchors.fill: parent
					anchors.leftMargin: 12
					anchors.rightMargin: 14
					spacing: 12

					ClippingRectangle {
						Layout.preferredWidth: 30
						Layout.preferredHeight: 30
						radius: Theme.radius.small
						color: Theme.layer2

						Glyph {
							anchors.centerIn: parent
							visible: favicon.status !== Image.Ready
							icon: row.modelData.command ? row.modelData.command.icon : row.modelData.kind === "workspace" ? "monitor_dashboard" : row.modelData.kind === "bookmark" ? "bookmark_outline" : row.modelData.kind === "history" ? "history" : row.modelData.kind === "archive" ? "archive_outline" : "tab"
							size: 16
							color: Theme.textMuted
						}

						Image {
							id: favicon

							anchors.centerIn: parent
							width: 18
							height: 18
							source: row.modelData.favicon
							sourceSize: Qt.size(36, 36)
							asynchronous: true
						}
					}

					ColumnLayout {
						Layout.fillWidth: true
						spacing: 1

						StyledText {
							Layout.fillWidth: true
							text: row.modelData.title
							tone: row.tab && row.tab.hidden ? Theme.textMuted : Theme.text
							font.pixelSize: Theme.size.body
							font.weight: row.tab && row.tab.active ? Font.DemiBold : Font.Normal
						}

						StyledText {
							Layout.fillWidth: true
							text: row.modelData.host || row.modelData.url
							tone: Theme.textMuted
							font.pixelSize: Theme.size.small
						}
					}

					Rectangle {
						visible: !!(row.tab && row.tab.group)
						Layout.preferredHeight: 20
						Layout.preferredWidth: groupLabel.implicitWidth + 16
						radius: 10
						color: Qt.alpha(root.groupColor(row.tab?.group?.color), 0.18)

						StyledText {
							id: groupLabel

							anchors.centerIn: parent
							text: row.tab?.group?.title || "Group"
							tone: root.groupColor(row.tab?.group?.color)
							font.pixelSize: Theme.size.small
						}
					}

					StyledText {
						visible: !!(row.tab && row.tab.container)
						Layout.maximumWidth: 120
						text: row.tab?.container?.name || ""
						tone: Theme.secondary
						font.pixelSize: Theme.size.small
					}

					Glyph {
						visible: !!(row.tab && (row.tab.audible || row.tab.muted))
						icon: row.tab && row.tab.muted ? "volume_off" : "volume_high"
						size: 16
						color: Theme.textMuted
					}

					Glyph {
						visible: !!(row.tab && row.tab.pinned)
						icon: "pin"
						size: 15
						color: Theme.textMuted
					}
				}
			}
		}

		EmptyState {
			anchors.centerIn: parent
			visible: root.rows.length === 0
			icon: root.kind === "workspaces" ? (FloorpWorkspaces.error !== "" ? "link_off" : "monitor_dashboard") : (WebLink.connected ? "tab" : "link_off")
			title: root.kind === "workspaces" ? FloorpWorkspaces.error : (WebLink.connected ? "" : "Browser not connected")
		}
	}
}
