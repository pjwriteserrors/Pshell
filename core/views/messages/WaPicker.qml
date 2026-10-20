pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.style.theme
import qs.core.services
import qs.style.widgets

// What goes into a message besides words: emoji, stickers and GIFs, each
// with a search. The stickers are one's own – kept from chats, made from a
// picture, or the ones sent last – and those the search finds; GIFs and
// found stickers come from Giphy.
Rectangle {
	id: root

	// "emoji" | "sticker" | "gif"
	property string tab: "emoji"
	property string query: ""
	readonly property string needle: root.query.trim().toLowerCase()
	// [{ name, emoji: [[sign, name]] }]
	property var groups: []
	property int group: -1
	readonly property var signs: {
		if (root.needle !== "") {
			const found = [];
			for (const group of root.groups)
				for (const entry of group.emoji)
					if (entry[1].includes(root.needle)) found.push(entry[0]);
			return found;
		}
		if (root.group < 0) return WhatsApp.recentEmoji;
		return (root.groups[root.group]?.emoji ?? []).map(entry => entry[0]);
	}
	readonly property var own: WhatsApp.stickers.slice().sort((a, b) => (b.favorite ? 1 : 0) - (a.favorite ? 1 : 0) || b.used - a.used)
	readonly property var results: WhatsApp.gifs.kind === root.tab && WhatsApp.gifs.query === root.asked ? (WhatsApp.gifs.results ?? []) : []
	// what was last searched for online
	property string asked: ""

	signal emoji(string sign)
	signal sticker(string file)
	// a GIF or sticker the search found
	signal found(string url, string kind)

	function show(tab) {
		root.tab = tab;
		root.query = "";
		search.text = "";
		if (tab === "emoji") root.group = WhatsApp.recentEmoji.length > 0 ? -1 : 0;
		else if (tab === "sticker") WhatsApp.command("stickers");
		root.seek();
		search.focusInput();
	}

	function seek() {
		if (root.tab === "emoji" || !WhatsApp.gifsReady) return;
		// one's own stickers show until something is searched for
		if (root.tab === "sticker" && root.needle === "") return;
		root.asked = root.query.trim();
		WhatsApp.searchGifs(root.asked, root.tab);
	}

	radius: Theme.radius.large
	color: Theme.layer1
	clip: true

	FileView {
		path: `${Paths.assets}/emoji/emoji.json`
		blockLoading: true
		printErrors: false
		onLoaded: {
			try {
				root.groups = JSON.parse(text());
			} catch (error) {}
		}
	}

	Timer {
		id: wait

		interval: 350
		onTriggered: root.seek()
	}

	Connections {
		target: WhatsApp
		function onGifsReadyChanged() {
			root.seek();
		}
	}

	ColumnLayout {
		anchors.fill: parent
		anchors.margins: 8
		spacing: 6

		RowLayout {
			Layout.fillWidth: true
			spacing: 6

			Repeater {
				model: [
					{ id: "emoji", icon: "emoticon_happy_outline" },
					{ id: "sticker", icon: "sticker_emoji" },
					{ id: "gif", icon: "file_gif_box" }
				]

				delegate: IconButton {
					required property var modelData

					implicitWidth: 36
					implicitHeight: 36
					icon: modelData.icon
					variant: "tonal"
					checked: root.tab === modelData.id
					onClicked: root.show(modelData.id)
				}
			}

			Field {
				id: search

				Layout.fillWidth: true
				implicitHeight: 36
				icon: "magnify"
				placeholder: root.tab === "emoji" ? "Emoji" : (root.tab === "sticker" ? "Stickers" : "GIFs")
				onEdited: text => {
					root.query = text;
					wait.restart();
				}
			}
		}

		// ── emoji ──────────────────────────────────────────────────────────
		RowLayout {
			visible: root.tab === "emoji" && root.needle === ""
			Layout.fillWidth: true
			spacing: 2

			Clickable {
				visible: WhatsApp.recentEmoji.length > 0
				implicitWidth: 30
				implicitHeight: 28
				radius: Theme.radius.small
				color: root.group === -1 ? Theme.layer3 : "transparent"
				onClicked: root.group = -1

				Glyph {
					anchors.centerIn: parent
					icon: "clock_outline"
					size: 15
					color: Theme.textMuted
				}
			}

			Repeater {
				model: root.groups

				delegate: Clickable {
					id: section

					required property var modelData
					required property int index

					implicitWidth: 30
					implicitHeight: 28
					radius: Theme.radius.small
					color: root.group === section.index ? Theme.layer3 : "transparent"
					onClicked: root.group = section.index

					StyledText {
						anchors.centerIn: parent
						text: section.modelData.emoji[0][0]
						font.pixelSize: 15
					}
				}
			}
		}

		GridView {
			visible: root.tab === "emoji"
			Layout.fillWidth: true
			Layout.fillHeight: true
			clip: true
			cellWidth: Math.floor(width / Math.max(1, Math.floor(width / 38)))
			cellHeight: 36
			boundsBehavior: Flickable.StopAtBounds
			ScrollBar.vertical: ThinScrollBar {}
			model: root.tab === "emoji" ? root.signs : []

			delegate: Clickable {
				id: sign

				required property string modelData

				width: GridView.view.cellWidth
				height: 36
				radius: Theme.radius.small
				pressedScale: 0.85
				onClicked: {
					WhatsApp.usedEmoji(sign.modelData);
					root.emoji(sign.modelData);
				}

				StyledText {
					anchors.centerIn: parent
					text: sign.modelData
					font.pixelSize: 21
				}
			}
		}

		// ── the key the search needs ───────────────────────────────────────
		RowLayout {
			visible: root.tab !== "emoji" && !WhatsApp.gifsReady && (root.tab === "gif" || root.needle !== "")
			Layout.fillWidth: true
			spacing: 6

			Field {
				id: key

				Layout.fillWidth: true
				implicitHeight: 36
				icon: "key"
				placeholder: "Giphy API key"
				onAccepted: if (key.text.trim() !== "") WhatsApp.command("settings", { key: key.text.trim() })
			}

			IconButton {
				implicitWidth: 36
				implicitHeight: 36
				icon: "open_in_new"
				variant: "tonal"
				onClicked: Qt.openUrlExternally("https://developers.giphy.com/dashboard/")
			}

			IconButton {
				implicitWidth: 36
				implicitHeight: 36
				icon: "check"
				variant: "filled"
				enabled: key.text.trim() !== ""
				onClicked: WhatsApp.command("settings", { key: key.text.trim() })
			}
		}

		// ── one's own stickers ─────────────────────────────────────────────
		GridView {
			id: kept

			visible: root.tab === "sticker" && root.needle === ""
			Layout.fillWidth: true
			Layout.fillHeight: true
			clip: true
			cellWidth: Math.floor(width / Math.max(1, Math.floor(width / 84)))
			cellHeight: cellWidth
			boundsBehavior: Flickable.StopAtBounds
			ScrollBar.vertical: ThinScrollBar {}
			model: ScriptModel {
				values: ["+"].concat(root.own.map(sticker => sticker.key))
			}

			delegate: Clickable {
				id: tile

				required property string modelData
				readonly property var entry: root.own.find(sticker => sticker.key === tile.modelData) ?? null

				width: GridView.view.cellWidth
				height: width
				radius: Theme.radius.medium
				pressedScale: 0.92
				onClicked: {
					if (tile.entry) root.sticker(tile.entry.file);
					else Files.pick({ title: "A sticker of your own", filters: ["*.png", "*.jpg", "*.jpeg", "*.webp", "*.gif"] }, paths => paths.forEach(path => WhatsApp.command("keepSticker", { path: path })));
				}

				Glyph {
					anchors.centerIn: parent
					visible: tile.entry === null
					icon: "image_plus"
					size: 26
					color: Theme.textMuted
				}

				Image {
					anchors.fill: parent
					anchors.margins: 6
					visible: tile.entry !== null
					source: tile.entry ? `file://${tile.entry.path}` : ""
					sourceSize.width: 160
					sourceSize.height: 160
					fillMode: Image.PreserveAspectFit
					asynchronous: true
				}

				Row {
					anchors.right: parent.right
					anchors.top: parent.top
					visible: tile.hovered && tile.entry !== null

					IconButton {
						implicitWidth: 24
						implicitHeight: 24
						icon: tile.entry?.favorite ? "heart" : "heart_outline"
						iconColor: tile.entry?.favorite ? Theme.danger : Theme.text
						onClicked: WhatsApp.command("favorite", { key: tile.modelData, value: !tile.entry.favorite })
					}

					IconButton {
						implicitWidth: 24
						implicitHeight: 24
						icon: "close"
						onClicked: WhatsApp.command("dropSticker", { key: tile.modelData })
					}
				}
			}
		}

		// ── what the search found ──────────────────────────────────────────
		GridView {
			id: grid

			visible: root.tab !== "emoji" && WhatsApp.gifsReady && (root.tab === "gif" || root.needle !== "")
			Layout.fillWidth: true
			Layout.fillHeight: true
			clip: true
			cellWidth: Math.floor(width / Math.max(1, Math.floor(width / (root.tab === "gif" ? 150 : 84))))
			cellHeight: root.tab === "gif" ? 104 : cellWidth
			boundsBehavior: Flickable.StopAtBounds
			ScrollBar.vertical: ThinScrollBar {}
			model: ScriptModel {
				values: grid.visible ? root.results.map(result => result.url) : []
			}

			delegate: Clickable {
				id: result

				required property string modelData
				readonly property var entry: root.results.find(entry => entry.url === result.modelData) ?? null

				width: GridView.view.cellWidth
				height: GridView.view.cellHeight
				radius: Theme.radius.medium
				pressedScale: 0.94
				clip: true
				onClicked: root.found(result.modelData, root.tab)

				AnimatedImage {
					anchors.fill: parent
					anchors.margins: root.tab === "gif" ? 2 : 6
					source: result.entry?.preview ?? ""
					fillMode: root.tab === "gif" ? Image.PreserveAspectCrop : Image.PreserveAspectFit
					asynchronous: true
					cache: true
				}
			}

			Spinner {
				anchors.centerIn: parent
				visible: WhatsApp.gifsLoading && grid.count === 0
				width: 22
				height: 22
			}

			EmptyState {
				anchors.centerIn: parent
				visible: !WhatsApp.gifsLoading && grid.count === 0
				icon: WhatsApp.gifs.error ? "alert_circle" : "magnify"
				title: WhatsApp.gifs.error === "key" ? "" : (WhatsApp.gifs.error ?? "Nothing found")
			}
		}
	}

}
