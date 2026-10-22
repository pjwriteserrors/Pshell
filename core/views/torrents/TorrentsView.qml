pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services
import qs.core.views.launcher
import qs.core.views

// The torrent client: the session's rates along the top, the torrents on the
// left, the one picked (or all of them) on the right; the add sheet over it
// when a link arrives. .torrent files can be dropped anywhere on it.
Item {
	id: root

	// in a window of its own, or under the bar
	property bool windowed: true
	// "all" | "active" | "done"
	property string filter: "all"
	readonly property var shownList: Torrents.torrents.filter(item => {
		const complete = item.phase === "seeding" || item.phase === "done";
		return root.filter === "all" || (root.filter === "done" ? complete : !complete);
	})

	function takeFocus() {
		keys.forceActiveFocus();
	}

	onShownListChanged: rows.sync(root.shownList.map(item => ({ key: item.hash })))
	Component.onCompleted: rows.sync(root.shownList.map(item => ({ key: item.hash })))

	SyncedModel {
		id: rows
	}

	Item {
		id: keys

		anchors.fill: parent
		focus: true
		Keys.onEscapePressed: {
			if (settings.shown) settings.shown = false;
			else if (Torrents.pending.length > 0) addSheet.dismiss();
			else if (Torrents.selected !== "") Torrents.select("");
			else Torrents.close();
		}
		Keys.onReturnPressed: if (Torrents.pending.length > 0) addSheet.accept()
		Keys.onPressed: event => {
			if (event.key === Qt.Key_V && event.modifiers & Qt.ControlModifier) {
				linkField.input.forceActiveFocus();
				linkField.input.paste();
				event.accepted = true;
			}
		}
	}

	ColumnLayout {
		anchors.fill: parent
		spacing: 0

		// ── the session ─────────────────────────────────────────────────
		RowLayout {
			Layout.fillWidth: true
			Layout.preferredHeight: 64
			Layout.leftMargin: 20
			Layout.rightMargin: 14
			spacing: 14

			Image {
				Layout.preferredWidth: 30
				Layout.preferredHeight: 30
				source: `${Paths.assets}/icons/pshell-torrents.svg`
				sourceSize: Qt.size(60, 60)
			}

			StyledText {
				text: "Torrents"
				font.pixelSize: Theme.size.heading
				font.weight: Font.DemiBold
			}

			Item {
				Layout.preferredWidth: 6
			}

			Repeater {
				model: [
					{ icon: "arrow_down_bold", value: Torrents.down, color: Theme.primary },
					{ icon: "arrow_up_bold", value: Torrents.up, color: Torrents.upColor }
				]

				RowLayout {
					id: rate

					required property var modelData

					spacing: 4

					Glyph {
						icon: rate.modelData.icon
						size: 15
						color: rate.modelData.color
					}

					StyledText {
						Layout.preferredWidth: 78
						text: Format.rate(rate.modelData.value)
						font.pixelSize: Theme.size.body
						tabular: true
					}
				}
			}

			Sparkline {
				Layout.preferredWidth: 140
				Layout.preferredHeight: 28
				values: Torrents.live.slice(-60).map(sample => sample[0])
				color: Theme.primary
				lineWidth: 1.5
			}

			Item {
				Layout.fillWidth: true
			}

			StyledText {
				visible: !Torrents.connected
				text: "Starting…"
				font.pixelSize: Theme.size.small
				tone: Theme.textSubtle
			}

			IconButton {
				icon: "cog_outline"
				onClicked: settings.shown = true
			}

			// under the bar ↔ a window of its own
			IconButton {
				visible: Plugins.on("torrents-bar")
				icon: root.windowed ? "dock_window" : "open_in_new"
				onClicked: root.windowed ? Torrents.dock() : Torrents.popOut()
			}
		}

		Rectangle {
			Layout.fillWidth: true
			Layout.preferredHeight: 1
			color: Theme.outline
		}

		RowLayout {
			Layout.fillWidth: true
			Layout.fillHeight: true
			spacing: 0

			// ── the list ────────────────────────────────────────────────
			ColumnLayout {
				Layout.preferredWidth: Math.min(420, Math.max(320, root.width * 0.34))
				Layout.maximumWidth: Layout.preferredWidth
				Layout.fillWidth: false
				Layout.fillHeight: true
				Layout.margins: 14
				spacing: 10

				RowLayout {
					Layout.fillWidth: true
					spacing: 6

					Field {
						id: linkField

						Layout.fillWidth: true
						icon: "magnet"
						placeholder: "Paste a magnet link or .torrent URL"
						onAccepted: {
							const text = linkField.text.trim();
							if (text === "") return;
							Torrents.add(text);
							linkField.text = "";
							keys.forceActiveFocus();
						}
						onEscapePressed: keys.forceActiveFocus()
					}

					IconButton {
						icon: "file_download_outline"
						variant: "tonal"
						onClicked: Torrents.pickFile()
					}
				}

				Segmented {
					Layout.fillWidth: true
					options: {
						const complete = Torrents.torrents.filter(item => item.phase === "seeding" || item.phase === "done").length;
						return [
							{ value: "all", label: `All ${Torrents.torrents.length}` },
							{ value: "active", label: `Active ${Torrents.torrents.length - complete}` },
							{ value: "done", label: `Complete ${complete}` }
						];
					}
					current: root.filter
					onSelected: value => root.filter = value
				}

				ListView {
					id: list

					Layout.fillWidth: true
					Layout.fillHeight: true
					clip: true
					spacing: 6
					model: rows
					boundsBehavior: Flickable.StopAtBounds
					ScrollBar.vertical: ThinScrollBar {}

					add: Transition {
						ParallelAnimation {
							NumberAnimation {
								property: "opacity"
								from: 0
								to: 1
								duration: Motion.medium
							}
							NumberAnimation {
								property: "scale"
								from: 0.92
								to: 1
								duration: Motion.long
								easing.type: Easing.BezierSpline
								easing.bezierCurve: Motion.spatial
							}
						}
					}
					remove: Transition {
						NumberAnimation {
							property: "opacity"
							to: 0
							duration: Motion.short
						}
					}
					displaced: Transition {
						NumberAnimation {
							property: "y"
							duration: Motion.long
							easing.type: Easing.BezierSpline
							easing.bezierCurve: Motion.standard
						}
					}

					delegate: TorrentRow {
						required property string key

						width: list.width
						hash: key
						picked: Torrents.selected === key
						onClicked: {
							Torrents.select(Torrents.selected === key ? "" : key);
							keys.forceActiveFocus();
						}
					}

					EmptyState {
						anchors.centerIn: parent
						visible: list.count === 0
						icon: "magnet"
						title: Torrents.torrents.length === 0 ? "No torrents yet" : "Nothing here"
						subtitle: Torrents.torrents.length === 0 ? "Click a magnet link or mirror in your browser, paste one above or drop a .torrent file here" : "Nothing in this list right now"
					}
				}
			}

			Rectangle {
				Layout.fillHeight: true
				Layout.preferredWidth: 1
				color: Theme.outline
			}

			// ── the one picked, or all ──────────────────────────────────
			Item {
				Layout.fillWidth: true
				Layout.fillHeight: true

				DetailPane {
					anchors.fill: parent
					visible: Torrents.selected !== ""
					hash: Torrents.selected
				}

				Overview {
					anchors.fill: parent
					visible: Torrents.selected === ""
				}
			}
		}
	}

	DropArea {
		id: drop

		anchors.fill: parent
		keys: ["text/uri-list"]
		onDropped: event => {
			for (const url of event.urls) {
				const text = String(url);
				if (text.endsWith(".torrent") || text.startsWith("magnet:")) Torrents.add(text);
			}
		}

		Rectangle {
			anchors.fill: parent
			anchors.margins: 10
			radius: Theme.radius.huge
			color: Qt.alpha(Theme.primary, 0.08)
			border.width: 2
			border.color: Theme.primary
			visible: drop.containsDrag

			EmptyState {
				anchors.centerIn: parent
				icon: "file_download_outline"
				title: "Drop to add"
			}
		}
	}

	AddSheet {
		id: addSheet

		anchors.fill: parent
		onShownChanged: if (addSheet.shown) addSheet.forceActiveFocus(); else keys.forceActiveFocus()
	}

	SettingsSheet {
		id: settings

		anchors.fill: parent
		onShownChanged: if (settings.shown) settings.forceActiveFocus(); else keys.forceActiveFocus()
	}
}
