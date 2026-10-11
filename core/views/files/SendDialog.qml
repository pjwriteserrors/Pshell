pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// Files to a server of the SSH plugin (or any host ssh reaches with its
// keys). The destination is typed like a path for scp: what is in the
// folder typed so far shows below, Tab completes as far as the names agree
// and, pressed again, goes through them one by one; ↑ ↓ pick, Enter goes
// into a picked folder, Enter with nothing picked sends.
DialogFrame {
	id: root

	property var rows: []
	property var servers: []
	property var server: null
	property string address: ""
	property bool typingAddress: false
	property string path: "~/"
	// the folder the path is in, as the server answered: { path, home, entries }
	property var listing: null
	property string listedFolder: ""
	property string error: ""
	property bool loading: false
	property var cache: ({})
	property int picked: -1
	// Tab pressed twice in a row goes through the matches
	property bool cycling: false

	readonly property string folderPart: {
		const slash = root.path.lastIndexOf("/");
		return slash >= 0 ? root.path.slice(0, slash + 1) : "";
	}
	readonly property string leaf: root.path.slice(root.folderPart.length)
	readonly property var matches: {
		const entries = root.listing?.entries ?? [];
		const shown = entries.filter(entry => !entry.name.startsWith(".") || root.leaf.startsWith("."));
		if (root.leaf === "") return shown;
		const exact = shown.filter(entry => entry.name.startsWith(root.leaf));
		return exact.length > 0 ? exact : shown.filter(entry => entry.name.toLowerCase().startsWith(root.leaf.toLowerCase()));
	}
	readonly property var spec: root.server?.kind === "entry" ? { entry: root.server.id } : { address: root.typingAddress ? root.address.trim() : String(root.server?.address ?? "") }
	readonly property string serverKey: JSON.stringify(root.spec)
	readonly property string serverName: root.typingAddress ? root.address.trim() : String(root.server?.name ?? "")

	function open(rows) {
		root.rows = rows;
		root.error = "";
		root.listing = null;
		root.picked = -1;
		root.show();
		Files.request("servers", {}, data => {
			root.servers = (data?.servers ?? []).sort((a, b) => (b.used - a.used) || (a.kind === "entry" ? -1 : 0));
			const last = String(FileLibrary.setting("sshServer") || "");
			const remembered = root.servers.find(server => server.address === last || server.id === last);
			if (remembered) root.pick(remembered);
			else if (last !== "") {
				root.typingAddress = true;
				root.address = last;
				root.pick(null);
			} else if (root.servers.length > 0 && root.servers[0].kind === "entry") root.pick(root.servers[0]);
			else root.typingAddress = root.servers.length === 0;
			Qt.callLater(() => (root.typingAddress && root.address === "" ? addressField : pathField).focusInput());
		});
	}

	function pick(server) {
		root.server = server;
		if (server) root.typingAddress = false;
		const dests = FileLibrary.setting("sshDest") || {};
		root.cache = {};
		root.path = String(dests[server ? server.address : root.address.trim()] ?? "~/");
		root.listing = null;
		root.listedFolder = "";
		root.list();
		Qt.callLater(() => {
			pathField.focusInput();
			pathField.input.cursorPosition = pathField.text.length;
		});
	}

	// what is in the folder of the path typed so far
	function list() {
		if (root.serverName === "") return;
		const folder = root.folderPart === "" ? "~/" : root.folderPart;
		const key = `${root.serverKey}|${folder}`;
		if (root.cache[key]) {
			root.listing = root.cache[key];
			root.listedFolder = folder;
			root.error = "";
			return;
		}
		root.loading = true;
		Files.request("remotels", { server: root.spec, path: folder }, (data, error) => {
			const now = root.folderPart === "" ? "~/" : root.folderPart;
			if (`${root.serverKey}|${now}` !== key) return;
			root.loading = false;
			if (error) {
				root.error = error;
				root.listing = null;
				return;
			}
			root.cache[key] = data;
			root.listing = data;
			root.listedFolder = folder;
			root.error = "";
		});
	}

	Timer {
		id: listTimer

		interval: 110
		onTriggered: root.list()
	}

	onFolderPartChanged: {
		root.picked = -1;
		listTimer.restart();
	}
	onLeafChanged: if (!root.cycling) root.picked = -1

	function setPath(value) {
		root.path = value;
		pathField.text = value;
		pathField.input.cursorPosition = value.length;
	}

	// zsh's Tab: as far as the names agree, then one by one
	function complete() {
		const matches = root.matches;
		if (matches.length === 0) {
			Sounds.play("error");
			return;
		}
		if (matches.length === 1) {
			root.cycling = false;
			root.setPath(root.folderPart + matches[0].name + (matches[0].dir ? "/" : ""));
			return;
		}
		let common = matches[0].name;
		for (const match of matches) while (!match.name.startsWith(common)) common = common.slice(0, -1);
		if (common.length > root.leaf.length && !root.cycling) {
			root.setPath(root.folderPart + common);
			return;
		}
		root.cycling = true;
		root.picked = (root.picked + 1) % matches.length;
		root.setPath(root.folderPart + matches[root.picked].name);
	}

	function enter() {
		const match = root.picked >= 0 ? root.matches[root.picked] : null;
		if (match?.dir) {
			root.cycling = false;
			root.setPath(root.folderPart + match.name + "/");
			return;
		}
		if (root.leaf !== "" && root.matches.length === 1 && root.matches[0].dir && root.matches[0].name === root.leaf) {
			root.setPath(root.path + "/");
			return;
		}
		root.send();
	}

	function send() {
		if (root.serverName === "") {
			Sounds.play("error");
			return;
		}
		// a name typed after the last slash is a folder that is (or will be) there
		const dest = root.path.trim() === "" ? "~/" : root.path.trim();
		const remembered = Object.assign({}, FileLibrary.setting("sshDest") || {});
		const key = root.server && !root.typingAddress ? root.server.address : root.address.trim();
		remembered[key] = dest.endsWith("/") ? dest : dest + "/";
		FileLibrary.set("sshDest", remembered);
		FileLibrary.set("sshServer", key);
		Files.sendToServer(root.rows.map(row => row.path), root.spec, root.serverName, dest);
		root.hide();
	}

	cardWidth: 620
	onDismissed: root.hide()

	ColumnLayout {
		width: parent.width
		spacing: 14

		RowLayout {
			spacing: 12

			Rectangle {
				width: 40
				height: 40
				radius: 13
				color: Theme.primarySoft

				Glyph {
					anchors.centerIn: parent
					icon: "server_network"
					size: 20
					color: Theme.primary
				}
			}

			ColumnLayout {
				Layout.fillWidth: true
				spacing: 1

				StyledText {
					text: "Send to a server"
					font.pixelSize: Theme.size.title
					font.weight: Font.DemiBold
				}

				StyledText {
					Layout.fillWidth: true
					text: root.rows.length === 1 ? root.rows[0].name : `${root.rows.length} items`
					tone: Theme.textSubtle
					font.pixelSize: Theme.size.small
					elide: Text.ElideMiddle
				}
			}
		}

		// ── which server ───────────────────────────────────────────────────
		Flow {
			Layout.fillWidth: true
			spacing: 6

			Repeater {
				model: root.servers.slice(0, 12)

				delegate: Chip {
					required property var modelData

					height: 30
					text: modelData.name
					icon: modelData.kind === "entry" ? "key_variant" : (modelData.kind === "alias" ? "console_network_outline" : "server_network")
					selected: !root.typingAddress && root.server?.id === modelData.id
					onClicked: root.pick(modelData)
				}
			}

			Chip {
				height: 30
				text: "Another…"
				icon: "plus"
				selected: root.typingAddress
				onClicked: {
					root.typingAddress = true;
					root.server = null;
					root.listing = null;
					Qt.callLater(() => addressField.focusInput());
				}
			}
		}

		Field {
			id: addressField

			Layout.fillWidth: true
			visible: root.typingAddress
			placeholder: "user@host or user@host:port"
			text: root.address
			onEdited: text => root.address = text
			onAccepted: root.pick(null)
			onEscapePressed: root.hide()
		}

		// ── where on it ────────────────────────────────────────────────────
		ColumnLayout {
			Layout.fillWidth: true
			spacing: 6

			RowLayout {
				Layout.fillWidth: true

				StyledText {
					text: "Into"
					tone: Theme.textMuted
					font.pixelSize: Theme.size.small
					font.weight: Font.DemiBold
				}

				Item {
					Layout.fillWidth: true
				}

				Spinner {
					visible: root.loading
					width: 12
					height: 12
				}

				StyledText {
					text: "Tab completes · ↑↓ pick · Enter opens or sends"
					tone: Theme.textFaint
					font.pixelSize: Theme.size.tiny
				}
			}

			Field {
				id: pathField

				Layout.fillWidth: true
				icon: "folder_outline"
				fontSize: Theme.size.body
				placeholder: "~/"
				text: root.path
				clearable: false
				onEdited: text => {
					root.cycling = false;
					root.path = text;
				}
				keepTab: true
				onTabPressed: root.complete()
				onUpPressed: {
					if (root.matches.length === 0) return;
					root.picked = root.picked <= 0 ? root.matches.length - 1 : root.picked - 1;
				}
				onDownPressed: {
					if (root.matches.length === 0) return;
					root.picked = (root.picked + 1) % root.matches.length;
				}
				onAccepted: root.enter()
				onEscapePressed: root.hide()
			}
		}

		// what is in the folder, the matches of what is typed
		Rectangle {
			Layout.fillWidth: true
			Layout.preferredHeight: 240
			radius: Theme.radius.large
			color: Theme.layer2
			clip: true

			StyledText {
				id: where

				x: 12
				y: 9
				width: parent.width - 24
				text: !root.listing ? "" : (root.listing.path === root.listing.home || root.listing.path.startsWith(root.listing.home + "/") ? "~" + root.listing.path.slice(root.listing.home.length) : root.listing.path)
				tone: Theme.textSubtle
				font.family: Theme.monoFamily
				font.pixelSize: Theme.size.small
				elide: Text.ElideLeft
			}

			ListView {
				id: list

				anchors.fill: parent
				anchors.topMargin: 30
				anchors.margins: 6
				model: root.matches
				currentIndex: root.picked
				clip: true
				boundsBehavior: Flickable.StopAtBounds
				highlightMoveDuration: Motion.short
				visible: root.error === "" && !!root.listing

				ScrollBar.vertical: ThinScrollBar {}

				onCurrentIndexChanged: if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain)

				highlight: Rectangle {
					radius: Theme.radius.small
					color: Theme.primarySoft
				}

				delegate: Item {
					id: entryRow

					required property var modelData
					required property int index

					width: list.width
					height: 28
					opacity: entryRow.modelData.dir ? 1 : 0.55

					Glyph {
						id: entryIcon

						x: 8
						anchors.verticalCenter: parent.verticalCenter
						icon: entryRow.modelData.dir ? "folder" : "file_outline"
						size: 15
						color: entryRow.modelData.dir ? Theme.primary : Theme.textMuted
						animated: false
					}

					Text {
						anchors.left: entryIcon.right
						anchors.leftMargin: 8
						anchors.right: parent.right
						anchors.rightMargin: 8
						anchors.verticalCenter: parent.verticalCenter
						textFormat: Text.StyledText
						// what is typed already in bold
						text: {
							const name = entryRow.modelData.name;
							const typed = Math.min(root.leaf.length, name.length);
							const esc = value => value.replace(/&/g, "&amp;").replace(/</g, "&lt;");
							return `<b>${esc(name.slice(0, typed))}</b>${esc(name.slice(typed))}${entryRow.modelData.dir ? "/" : ""}`;
						}
						color: Theme.text
						font.family: Theme.monoFamily
						font.pixelSize: Theme.size.small
						elide: Text.ElideRight
					}

					MouseArea {
						anchors.fill: parent
						cursorShape: entryRow.modelData.dir ? Qt.PointingHandCursor : Qt.ArrowCursor
						onClicked: {
							root.picked = entryRow.index;
							if (entryRow.modelData.dir) root.enter();
						}
					}
				}
			}

			StyledText {
				anchors.centerIn: parent
				visible: root.error === "" && !!root.listing && root.matches.length === 0
				text: root.leaf === "" ? "The folder is empty" : `No name starts with “${root.leaf}” – it becomes a new folder`
				tone: Theme.textSubtle
				font.pixelSize: Theme.size.small
			}

			ColumnLayout {
				anchors.centerIn: parent
				width: parent.width - 60
				visible: root.error !== ""
				spacing: 6

				Glyph {
					Layout.alignment: Qt.AlignHCenter
					icon: "alert_circle_outline"
					size: 26
					color: Theme.warning
				}

				StyledText {
					Layout.fillWidth: true
					horizontalAlignment: Text.AlignHCenter
					text: root.error
					tone: Theme.textMuted
					wrapMode: Text.WordWrap
				}
			}

			StyledText {
				anchors.centerIn: parent
				visible: root.serverName === ""
				text: "Pick a server above"
				tone: Theme.textSubtle
			}
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 8

			StyledText {
				Layout.fillWidth: true
				text: root.serverName !== "" ? `${root.serverName}:${root.path || "~/"}` : ""
				tone: Theme.textSubtle
				font.family: Theme.monoFamily
				font.pixelSize: Theme.size.small
				elide: Text.ElideMiddle
			}

			TextButton {
				text: "Cancel"
				variant: "ghost"
				onClicked: root.hide()
			}

			TextButton {
				text: "Send"
				variant: "filled"
				icon: "send"
				enabled: root.serverName !== "" && root.error === ""
				opacity: enabled ? 1 : 0.5
				onClicked: root.send()
			}
		}
	}
}
