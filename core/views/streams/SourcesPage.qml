pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services
import qs.core.views

// What is followed, as a wall of faces. A link of any kind goes in the one field.
Flickable {
	id: root

	property string adding: ""
	property string addError: ""
	property bool showKeys: false
	// the channel waiting for the one to be merged with
	property string mergingFrom: ""

	function add(text) {
		const value = String(text ?? field.text).trim();
		if (!value || root.adding) return;
		root.adding = value;
		root.addError = "";
		field.text = value;
		Streams.call("add", { input: value }, (data, error) => {
			root.adding = "";
			root.addError = error;
			if (!error) field.text = "";
		});
	}

	contentHeight: column.implicitHeight + 40
	boundsBehavior: Flickable.StopAtBounds
	clip: true
	ScrollBar.vertical: ThinScrollBar {}

	onVisibleChanged: if (visible) sync()
	Component.onCompleted: sync()

	function sync() {
		// merged channels stand next to each other
		const place = item => (item.group ? Streams.groupOf(item.id)[0].name : item.name).toLowerCase();
		const sorted = Streams.ownSources.slice().sort((a, b) => (b.favorite - a.favorite) || place(a).localeCompare(place(b)) || a.name.localeCompare(b.name));
		rows.sync(sorted.map(item => ({ key: item.id })));
	}

	Connections {
		target: Streams

		function onSourcesChanged() {
			root.sync();
		}
	}

	SyncedModel {
		id: rows
	}

	ColumnLayout {
		id: column

		x: 44
		width: root.width - 88
		spacing: 16

		Item {
			Layout.preferredHeight: 64
		}

		Text {
			text: "Channels"
			color: Theme.text
			font.family: Theme.fontFamily
			font.pixelSize: 40
			font.weight: Font.Black
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 8

			Field {
				id: field

				Layout.fillWidth: true
				Layout.preferredHeight: 46
				icon: "plus"
				fontSize: Theme.size.title
				placeholder: "youtube.com/@channel, a playlist, a Twitch name or a feed"
				onAccepted: root.add()
			}
			BigButton {
				text: root.adding !== "" ? "Looking…" : "Follow"
				onClicked: root.add()
			}
			BigButton {
				implicitWidth: 46
				icon: "key_outline"
				main: false
				onClicked: root.showKeys = !root.showKeys
			}
			BigButton {
				implicitWidth: 46
				icon: "refresh"
				main: false
				onClicked: Streams.call("refresh", {})
			}
		}

		StyledText {
			Layout.fillWidth: true
			visible: root.addError !== ""
			text: root.addError
			color: Theme.danger
			font.pixelSize: Theme.size.body
			wrapMode: Text.Wrap
		}

		KeysBox {
			Layout.fillWidth: true
			shown: root.showKeys || (!Streams.keys.twitch && root.addError.includes("Twitch"))
		}

		RowLayout {
			Layout.fillWidth: true
			visible: root.mergingFrom !== ""
			spacing: 12

			StyledText {
				Layout.fillWidth: true
				text: `Pick the channel to merge with ${Streams.sourceById[root.mergingFrom]?.name ?? ""}. Series can then come from both.`
				font.pixelSize: Theme.size.title
				font.weight: Font.Bold
				elide: Text.ElideRight
			}
			TextButton {
				text: "Cancel"
				variant: "ghost"
				onActivated: root.mergingFrom = ""
			}
		}

		GridView {
			id: wall

			readonly property int columns: Math.max(2, Math.min(Math.floor(width / 230), Math.max(4, rows.count)))

			Layout.fillWidth: true
			Layout.preferredHeight: Math.ceil(rows.count / wall.columns) * wall.cellHeight
			interactive: false
			cellWidth: Math.floor(width / wall.columns)
			cellHeight: 244
			model: rows

			add: Transition {
				ParallelAnimation {
					SpatialAnim {
						property: "scale"
						from: 0.7
						to: 1
						duration: Motion.extraLong
					}
					Anim {
						property: "opacity"
						from: 0
						to: 1
					}
				}
			}
			remove: Transition {
				Anim {
					property: "opacity"
					to: 0
					duration: Motion.short
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

				required property string key
				readonly property var item: Streams.sourceById[cell.key] ?? null
				readonly property var together: Streams.groupOf(cell.key).filter(other => other.id !== cell.key)
				readonly property bool canTake: root.mergingFrom !== "" && root.mergingFrom !== cell.key && !cell.together.some(other => other.id === root.mergingFrom)

				width: wall.cellWidth
				height: wall.cellHeight

				HoverHandler {
					id: cellHover
				}

				Rectangle {
					anchors.fill: parent
					anchors.margins: 6
					radius: Theme.radius.huge
					color: root.mergingFrom === cell.key ? Theme.primaryContainer : (cellHover.hovered ? Theme.layer2 : Theme.layer1)
					opacity: root.mergingFrom !== "" && root.mergingFrom !== cell.key && !cell.canTake ? 0.4 : 1
					border.width: cell.canTake && cellHover.hovered ? 2 : 0
					border.color: Theme.primary

					Behavior on color {
						ColorAnim {}
					}
					Behavior on opacity {
						Anim {}
					}

					ColumnLayout {
						anchors.fill: parent
						anchors.margins: 14
						spacing: 6

						Avatar {
							Layout.alignment: Qt.AlignHCenter
							Layout.preferredWidth: 84
							Layout.preferredHeight: 84
							source: cell.item?.avatar ?? ""
							name: cell.item?.name ?? ""
							colors: cell.item?.colors ?? null
							live: cell.item?.live ?? false
							scale: cellHover.hovered ? 1.08 : 1

							Behavior on scale {
								SpatialAnim {
									duration: Motion.long
								}
							}
						}
						StyledText {
							Layout.fillWidth: true
							Layout.topMargin: 4
							horizontalAlignment: Text.AlignHCenter
							text: cell.item?.name ?? ""
							font.pixelSize: Theme.size.title
							font.weight: Font.Bold
							elide: Text.ElideRight
						}
						StyledText {
							Layout.fillWidth: true
							horizontalAlignment: Text.AlignHCenter
							text: {
								const item = cell.item;
								if (!item) return "";
								if (item.error) return item.error;
								if (item.loading) return item.loading;
								if (cell.together.length > 0) return `Merged with ${cell.together.map(other => other.name).join(", ")}`;
								const kind = ({ youtube: "YouTube", playlist: "Playlist", twitch: "Twitch", rss: "Feed" })[item.kind] ?? "";
								return item.pattern || (item.kind === "twitch" ? kind : `${kind} · ${item.videos} videos`);
							}
							font.pixelSize: Theme.size.small
							color: cell.item?.error ? Theme.warning : Theme.textMuted
							elide: Text.ElideRight
						}
						Item {
							Layout.fillHeight: true
						}
						Segmented {
							Layout.fillWidth: true
							Layout.preferredHeight: 28
							options: [{ value: "all", label: "All" }, { value: "live", label: "Live" }, { value: "silent", label: "Silent" }]
							current: cell.item?.notify ?? "live"
							onSelected: value => Streams.updateSource(cell.key, { notify: value })
						}
					}

					IconButton {
						anchors.left: parent.left
						anchors.top: parent.top
						anchors.margins: 8
						width: 30
						height: 30
						icon: cell.item?.favorite ? "star" : "star_outline"
						checked: cell.item?.favorite ?? false
						visible: cell.item?.kind !== "rss" && (cellHover.hovered || (cell.item?.favorite ?? false))
						onClicked: Streams.updateSource(cell.key, { favorite: !cell.item.favorite })
					}
					TextButton {
						anchors.right: parent.right
						anchors.top: parent.top
						anchors.margins: 8
						visible: cellHover.hovered && root.mergingFrom === ""
						text: ""
						icon: "delete_outline"
						variant: "ghost"
						confirm: true
						confirmText: "Remove?"
						onActivated: Streams.call("removeSource", { id: cell.key })
					}
					IconButton {
						anchors.left: parent.left
						anchors.bottom: parent.bottom
						anchors.margins: 8
						anchors.bottomMargin: 44
						width: 30
						height: 30
						visible: cellHover.hovered && root.mergingFrom === ""
						icon: cell.together.length > 0 ? "call_split" : "call_merge"
						onClicked: {
							if (cell.together.length > 0) Streams.call("unmergeSource", { id: cell.key });
							else root.mergingFrom = cell.key;
						}
					}
					MouseArea {
						anchors.fill: parent
						visible: cell.canTake
						cursorShape: Qt.PointingHandCursor
						onClicked: {
							Streams.call("mergeSources", { ids: [root.mergingFrom, cell.key] });
							root.mergingFrom = "";
						}
					}
				}
			}
		}

		AiBox {
			Layout.fillWidth: true
			Layout.topMargin: 20
		}

		// ── how it plays ────────────────────────────────────────────────
		ColumnLayout {
			Layout.fillWidth: true
			Layout.topMargin: 20
			spacing: 12

			SectionHeading {
				text: "Watching"
			}
			RowLayout {
				Layout.fillWidth: true
				StyledText {
					Layout.fillWidth: true
					text: "Play videos in"
				}
				Segmented {
					Layout.preferredWidth: 330
					Layout.preferredHeight: 32
					options: [{ value: "app", label: "This app" }, { value: "mpv", label: "mpv" }, { value: "browser", label: "The browser" }]
					current: Streams.settings.player ?? "app"
					onSelected: value => Streams.setSetting("player", value)
				}
			}
			RowLayout {
				Layout.fillWidth: true
				StyledText {
					Layout.fillWidth: true
					text: "Go on to the next episode after a countdown"
				}
				Toggle {
					checked: Streams.settings.autoNext ?? true
					onToggled: checked => Streams.setSetting("autoNext", checked)
				}
			}
			RowLayout {
				Layout.fillWidth: true
				ColumnLayout {
					Layout.fillWidth: true
					spacing: 0
					StyledText {
						Layout.fillWidth: true
						text: "Load the next episodes at night"
					}
					StyledText {
						Layout.fillWidth: true
						wrapMode: Text.Wrap
						text: "Between 2 and 7, what you watched in the last three weeks, up to 20 GB. A copy goes once watched, or after a week."
						tone: Theme.textMuted
						font.pixelSize: Theme.size.small
					}
				}
				Toggle {
					checked: Streams.settings.nightLoad ?? false
					onToggled: checked => Streams.setSetting("nightLoad", checked)
				}
			}
			RowLayout {
				Layout.fillWidth: true
				StyledText {
					Layout.fillWidth: true
					text: "Are picture and sound on time?"
				}
				TextButton {
					text: "Test with flash and beep"
					onActivated: Streams.call("syncTest", {})
				}
			}
			RowLayout {
				Layout.fillWidth: true
				ColumnLayout {
					Layout.fillWidth: true
					spacing: 0
					StyledText {
						Layout.fillWidth: true
						text: "Skip sponsor segments"
					}
					StyledText {
						Layout.fillWidth: true
						wrapMode: Text.Wrap
						text: "SponsorBlock's list. It is asked in a way that does not tell which video it is."
						font.pixelSize: Theme.size.small
						tone: Theme.textMuted
					}
				}
				Toggle {
					checked: Streams.settings.sponsorBlock ?? true
					onToggled: checked => Streams.setSetting("sponsorBlock", checked)
				}
			}
		}
	}
}
