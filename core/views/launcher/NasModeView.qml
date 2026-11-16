pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.style.theme
import qs.core.services
import qs.style.widgets

// Launcher >nas: looks through the NAS (Nas.search, the server's file
// index; with "By meaning" its semantic index too). Enter opens a result
// through the mount, Shift+Enter shows it in its folder, Ctrl+Enter
// downloads it to ~/Downloads, Alt+Enter copies a share link; Ctrl+M
// switches the meaning search. With nothing typed: what the NAS does now
// and the few things done with it.
Item {
	id: root

	property string argument: ""
	property bool active: false
	property int currentIndex: 0
	property bool semantic: false

	property var found: []
	property bool searching: false
	property string error: ""
	property string asked: ""

	readonly property string words: root.argument.trim()

	readonly property var actions: [
		{ kind: "action", id: "files", title: Nas.mounted ? "Open the NAS in Files" : "Open the NAS", subtitle: Nas.mounted ? Nas.mountPath.replace(Paths.home, "~") : "Not mounted: the web interface", icon: "folder_open" },
		{ kind: "action", id: "web", title: "Web interface", subtitle: Nas.webUrl(), icon: "web" },
		{ kind: "action", id: "sync", title: "Sync now", subtitle: Nas.pairs.length > 0 ? `${Nas.pairs.length} folder pairs` : "No folder pairs yet", icon: "folder_sync_outline", shown: Plugins.on("nas-sync") },
		{ kind: "action", id: "backup", title: "Back up now", subtitle: Nas.backupLast > 0 ? `Last ${Format.ago(Nas.backupLast * 1000)} ago` : "Never backed up", icon: "backup_restore", shown: Plugins.on("nas-backup") },
		{ kind: "action", id: "settings", title: "NAS settings", subtitle: Nas.summary, icon: "cog_outline" }
	].filter(entry => entry.shown !== false)

	readonly property var rows: root.words === "" ? root.actions : root.found.map(entry => Object.assign({ kind: "file" }, entry))

	signal closeRequested

	onActiveChanged: if (root.active) root.currentIndex = 0
	onRowsChanged: root.currentIndex = Math.max(0, Math.min(root.currentIndex, root.rows.length - 1))
	onWordsChanged: {
		if (root.words === "") {
			root.found = [];
			root.error = "";
			return;
		}
		look.restart();
	}
	onSemanticChanged: if (root.words !== "") look.restart()

	Timer {
		id: look

		interval: 300
		onTriggered: {
			const words = root.words;
			const semantic = root.semantic;
			root.searching = true;
			root.asked = words;
			Nas.search(words, semantic, (entries, error) => {
				if (words !== root.words || semantic !== root.semantic) return;
				root.searching = false;
				root.error = error;
				root.found = entries.slice(0, 80);
			});
		}
	}

	function iconOf(entry) {
		if (entry.dir) return "folder_outline";
		switch (entry.kind) {
		case "image": return "image_outline";
		case "video": return "movie_open_outline";
		case "audio": return "music_note";
		case "pdf": return "file_pdf_box";
		case "archive": return "zip_box_outline";
		case "code": return "code_braces";
		case "text": return "file_document_outline";
		default: return "file_outline";
		}
	}

	function folderOf(path) {
		const value = String(path);
		return value.slice(0, value.lastIndexOf("/")) || "/";
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
		if (event.key === Qt.Key_M && (event.modifiers & Qt.ControlModifier)) {
			root.semantic = !root.semantic;
			return true;
		}
		return false;
	}

	function cancel() {
		return false;
	}

	function activate(modifiers) {
		const row = root.rows[root.currentIndex];
		if (!row) return;
		if (row.kind === "action") return root.run("action", row);
		if (modifiers & Qt.ShiftModifier) root.run("reveal", row);
		else if (modifiers & Qt.ControlModifier) root.run("download", row);
		else if (modifiers & Qt.AltModifier) root.run("share", row);
		else root.run("open", row);
	}

	function run(how, row) {
		if (how === "download") return Nas.fetch([row.path], `${Paths.home}/Downloads`);
		if (how === "share") return Nas.share([row.path], "download", 168);
		root.closeRequested();
		later.how = how;
		later.row = row;
		later.restart();
	}

	// once the launcher has gone, the window that opens takes the keyboard
	Timer {
		id: later

		property string how: ""
		property var row: null
		interval: Motion.medium
		onTriggered: {
			const row = later.row;
			if (!row) return;
			if (later.how === "reveal") return Nas.reveal(row.path);
			if (later.how === "open") return Nas.open(row.path);
			switch (row.id) {
			case "files":
				if (Nas.mounted && Plugins.on("filemanager")) Files.open(Nas.mountPath);
				else Nas.openWeb();
				break;
			case "web":
				Nas.openWeb();
				break;
			case "sync":
				Nas.syncNow("");
				break;
			case "backup":
				Nas.backupNow("");
				break;
			case "settings":
				Nas.openSettings();
				break;
			}
		}
	}

	ColumnLayout {
		anchors.fill: parent
		spacing: 8

		RowLayout {
			Layout.fillWidth: true
			Layout.leftMargin: 6
			Layout.rightMargin: 6
			spacing: 8

			Glyph {
				icon: Nas.online ? "server_network" : "lan"
				size: 16
				color: Nas.online ? Theme.primary : Theme.textSubtle
			}

			StyledText {
				Layout.fillWidth: true
				text: Nas.online ? `${Nas.viaText} · ${Nas.summary}` : Nas.summary
				tone: Theme.textMuted
				font.pixelSize: Theme.size.small
				elide: Text.ElideRight
			}

			Spinner {
				visible: root.searching
				Layout.preferredWidth: 14
				Layout.preferredHeight: 14
			}

			Chip {
				text: "By meaning"
				icon: "creation"
				selected: root.semantic
				onClicked: root.semantic = !root.semantic
			}
		}

		Item {
			Layout.fillWidth: true
			Layout.fillHeight: true

			EmptyState {
				anchors.centerIn: parent
				visible: root.rows.length === 0 && !root.searching
				icon: root.error !== "" ? "alert_outline" : "magnify"
				title: root.error !== "" ? "The NAS did not answer" : "Nothing on the NAS is called that"
				subtitle: root.error !== "" ? root.error : (root.semantic ? "Searched by name and by meaning" : "Ctrl+M searches by meaning as well")
			}

			ListView {
				id: list

				anchors.fill: parent
				visible: root.rows.length > 0
				clip: true
				spacing: 2
				model: root.rows
				currentIndex: root.currentIndex
				boundsBehavior: Flickable.StopAtBounds
				ScrollBar.vertical: ThinScrollBar {}

				delegate: ListItem {
					id: row

					required property var modelData
					required property int index

					width: list.width
					selected: root.currentIndex === row.index
					icon: row.modelData.kind === "action" ? row.modelData.icon : root.iconOf(row.modelData)
					title: row.modelData.kind === "action" ? row.modelData.title : String(row.modelData.name || String(row.modelData.path).split("/").pop())
					subtitle: row.modelData.kind === "action" ? row.modelData.subtitle : [root.folderOf(row.modelData.path), row.modelData.dir ? "" : Format.bytes(row.modelData.size, ""), row.modelData.mtime ? Format.day(Nas.seconds(row.modelData.mtime)) : ""].filter(s => s).join(" · ")
					onPointed: root.currentIndex = row.index
					onClicked: root.run(row.modelData.kind === "action" ? "action" : "open", row.modelData)

					IconButton {
						visible: row.modelData.kind === "file" && (row.selected || row.hovered)
						implicitWidth: 28
						implicitHeight: 28
						icon: "folder_search_outline"
						onClicked: root.run("reveal", row.modelData)
					}

					IconButton {
						visible: row.modelData.kind === "file" && !row.modelData.dir && (row.selected || row.hovered)
						implicitWidth: 28
						implicitHeight: 28
						icon: "download"
						onClicked: root.run("download", row.modelData)
					}

					IconButton {
						visible: row.modelData.kind === "file" && (row.selected || row.hovered)
						implicitWidth: 28
						implicitHeight: 28
						icon: "link_variant"
						onClicked: root.run("share", row.modelData)
					}
				}
			}
		}
	}
}
