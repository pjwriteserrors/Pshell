pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.style.theme
import qs.core.services
import qs.style.widgets

// The WhatsApp chats: what is pinned first, then who wrote last. The field
// above them narrows them down by name and finds messages by their words; a
// chat under the pointer can be pinned, muted, marked and archived.
ColumnLayout {
	id: root

	property string query: ""
	// "all" | "unread" | "groups" | "archived"
	property string mode: "all"
	readonly property string needle: root.query.trim().toLowerCase()
	readonly property int archived: WhatsApp.chats.reduce((sum, chat) => sum + (chat.archived ? 1 : 0), 0)
	readonly property var byId: {
		const map = {};
		for (const chat of WhatsApp.chats) map[chat.id] = chat;
		return map;
	}
	readonly property var shown: WhatsApp.chats.filter(chat => {
		if (root.needle !== "") return String(chat.name).toLowerCase().includes(root.needle) || String(chat.phone ?? "").includes(root.needle);
		if (root.mode === "archived") return chat.archived;
		if (chat.archived) return false;
		if (root.mode === "unread") return chat.unread > 0 || chat.marked;
		if (root.mode === "groups") return chat.group;
		return true;
	}).sort((a, b) => (b.pinned ? 1 : 0) - (a.pinned ? 1 : 0) || b.date - a.date).map(chat => chat.id)
	// messages whose words match what is searched for
	readonly property var hits: root.needle.length >= 2 && WhatsApp.found.query === root.query.trim() ? WhatsApp.found.hits : []

	signal picked(string id, string message)

	function entered() {
		if (root.query !== "") return;
		root.mode = root.mode === "archived" && root.archived === 0 ? "all" : root.mode;
	}

	function focusSearch() {
		search.focusInput();
	}

	function step(by) {
		const at = root.shown.indexOf(WhatsApp.openId);
		const next = root.shown[Math.max(0, Math.min(root.shown.length - 1, at + by))];
		if (next !== undefined && next !== WhatsApp.openId) root.picked(next, "");
	}

	spacing: 10

	Field {
		id: search

		Layout.fillWidth: true
		icon: "magnify"
		placeholder: "Search"
		onEdited: text => {
			root.query = text;
			seek.restart();
		}
		onEscapePressed: {
			search.text = "";
			root.query = "";
		}
	}

	Timer {
		id: seek

		interval: 250
		onTriggered: WhatsApp.search(root.query.trim())
	}

	RowLayout {
		Layout.fillWidth: true
		visible: root.needle === ""
		spacing: 6

		Repeater {
			model: [
				{ id: "all", label: "All" },
				{ id: "unread", label: "Unread" },
				{ id: "groups", label: "Groups" },
				{ id: "archived", label: "Archived" }
			].filter(entry => entry.id !== "archived" || root.archived > 0)

			delegate: Chip {
				required property var modelData

				implicitHeight: 30
				text: modelData.label
				selected: root.mode === modelData.id
				onClicked: root.mode = modelData.id
			}
		}

		Item {
			Layout.fillWidth: true
		}

		Spinner {
			visible: WhatsApp.syncing || WhatsApp.state === "connecting"
			Layout.preferredWidth: 14
			Layout.preferredHeight: 14
		}
	}

	ListView {
		id: list

		Layout.fillWidth: true
		Layout.fillHeight: true
		clip: true
		spacing: 2
		boundsBehavior: Flickable.StopAtBounds
		ScrollBar.vertical: ThinScrollBar {}
		model: ScriptModel {
			values: root.shown
		}

		// a chat someone wrote in moves up, the others make room
		move: Transition {
			SpatialAnim {
				property: "y"
				duration: Motion.medium
			}
		}
		displaced: Transition {
			SpatialAnim {
				property: "y"
				duration: Motion.medium
			}
		}

		delegate: Clickable {
			id: item

			required property string modelData
			readonly property var chat: root.byId[item.modelData] ?? null
			readonly property bool current: item.modelData === WhatsApp.openId
			readonly property bool fresh: (item.chat?.unread ?? 0) > 0 || (item.chat?.marked ?? false)
			readonly property var draft: WhatsApp.drafts[item.modelData] ?? null

			width: ListView.view.width
			implicitHeight: 66
			radius: Theme.radius.large
			pressedScale: 0.98
			showHover: false
			color: item.current ? Theme.primaryContainer : (item.hovered ? Theme.layer1 : "transparent")
			onClicked: root.picked(item.modelData, "")

			RowLayout {
				anchors.fill: parent
				anchors.leftMargin: 12
				anchors.rightMargin: 12
				spacing: 12

				WaAvatar {
					size: 42
					name: item.chat?.name ?? ""
					key: item.modelData
					picture: item.chat?.avatar ?? ""
					group: item.chat?.group ?? false
				}

				ColumnLayout {
					Layout.fillWidth: true
					spacing: 3

					RowLayout {
						Layout.fillWidth: true
						spacing: 6

						StyledText {
							Layout.fillWidth: true
							text: item.chat?.self ? `${item.chat.name} (You)` : (item.chat?.name ?? "")
							elide: Text.ElideRight
							font.pixelSize: Theme.size.body
							font.weight: item.fresh ? Font.Bold : Font.DemiBold
						}

						Glyph {
							visible: item.chat?.pinned ?? false
							icon: "pin"
							size: 12
							color: Theme.textSubtle
						}

						Glyph {
							visible: item.chat?.muted ?? false
							icon: "bell_off"
							size: 12
							color: Theme.textSubtle
						}

						StyledText {
							opacity: tools.shown ? 0 : 1
							text: item.chat && item.chat.date > 0 ? WhatsApp.stamp(item.chat.date) : ""
							tone: item.fresh ? Theme.primary : Theme.textSubtle
							font.pixelSize: Theme.size.small
							font.weight: item.fresh ? Font.Bold : Font.Normal

							Behavior on opacity {
								Anim {
									duration: Motion.short
								}
							}
						}
					}

					RowLayout {
						Layout.fillWidth: true
						spacing: 4

						WaTicks {
							visible: item.draft === null && !item.chat?.typing && (item.chat?.mine ?? false) && item.chat?.kind !== "system" && item.chat?.kind !== "deleted"
							status: item.chat?.status ?? 0
							size: 13
						}

						StyledText {
							Layout.fillWidth: true
							text: {
								if (!item.chat) return "";
								if (item.chat.typing) return item.chat.group ? `${item.chat.typing} is typing…` : "typing…";
								if (item.draft !== null && !item.current) return `Draft: ${item.draft.text}`;
								return `${item.chat.sender ? item.chat.sender + ": " : ""}${item.chat.preview}`;
							}
							elide: Text.ElideRight
							tone: item.chat?.typing ? Theme.primary : (item.fresh ? Theme.text : Theme.textMuted)
							font.pixelSize: Theme.size.label
						}

						Badge {
							count: item.chat?.unread ?? 0
							accent: item.chat?.muted ? Theme.textSubtle : Theme.primary
						}

						Rectangle {
							visible: (item.chat?.marked ?? false) && (item.chat?.unread ?? 0) === 0
							implicitWidth: 10
							implicitHeight: 10
							radius: 5
							color: Theme.primary
						}
					}
				}
			}

			// what can be done with the chat, while the pointer is on it
			Rectangle {
				id: tools

				readonly property bool shown: item.hovered && item.chat !== null

				anchors.right: parent.right
				anchors.top: parent.top
				anchors.rightMargin: 8
				anchors.topMargin: 5
				width: strip.width + 8
				height: 30
				radius: 15
				color: Theme.layer3
				transformOrigin: Item.Right
				opacity: tools.shown ? 1 : 0
				scale: tools.shown ? 1 : 0.86
				visible: opacity > 0.01

				Behavior on opacity {
					Anim {
						duration: Motion.short
					}
				}
				Behavior on scale {
					SpatialAnim {
						duration: Motion.short
					}
				}

				Row {
					id: strip

					anchors.centerIn: parent

					IconButton {
						implicitWidth: 24
						implicitHeight: 24
						icon: item.chat?.pinned ? "pin_off" : "pin_outline"
						onClicked: WhatsApp.chatDo("pin", item.modelData, { value: !item.chat.pinned })
					}

					IconButton {
						implicitWidth: 24
						implicitHeight: 24
						icon: item.chat?.muted ? "bell_outline" : "bell_off"
						onClicked: WhatsApp.chatDo("mute", item.modelData, { seconds: item.chat.muted ? 0 : -1 })
					}

					IconButton {
						implicitWidth: 24
						implicitHeight: 24
						icon: "email_mark_as_unread"
						checked: item.fresh
						onClicked: WhatsApp.chatDo("markUnread", item.modelData, { value: !item.fresh })
					}

					IconButton {
						implicitWidth: 24
						implicitHeight: 24
						icon: "archive_outline"
						checked: item.chat?.archived ?? false
						onClicked: WhatsApp.chatDo("archive", item.modelData, { value: !item.chat.archived })
					}
				}
			}
		}

		// the messages a search found, below the chats
		footer: Column {
			width: list.width
			visible: root.hits.length > 0
			height: visible ? implicitHeight : 0
			spacing: 2

			SectionLabel {
				text: "Messages"
				topPadding: 10
				leftPadding: 10
			}

			Repeater {
				model: root.hits.slice(0, 60)

				delegate: Clickable {
					id: hit

					required property var modelData

					width: list.width
					implicitHeight: 56
					radius: Theme.radius.large
					pressedScale: 0.98
					showHover: false
					color: hit.hovered ? Theme.layer1 : "transparent"
					onClicked: root.picked(hit.modelData.chat, hit.modelData.id)

					ColumnLayout {
						anchors.fill: parent
						anchors.leftMargin: 12
						anchors.rightMargin: 12
						anchors.topMargin: 7
						anchors.bottomMargin: 7
						spacing: 2

						RowLayout {
							Layout.fillWidth: true
							spacing: 6

							StyledText {
								Layout.fillWidth: true
								text: hit.modelData.chatName
								elide: Text.ElideRight
								font.pixelSize: Theme.size.label
								font.weight: Font.DemiBold
							}

							StyledText {
								text: WhatsApp.stamp(hit.modelData.date)
								tone: Theme.textSubtle
								font.pixelSize: Theme.size.tiny
							}
						}

						StyledText {
							Layout.fillWidth: true
							text: `${hit.modelData.mine ? "You" : hit.modelData.name}: ${hit.modelData.text}`
							elide: Text.ElideRight
							tone: Theme.textMuted
							font.pixelSize: Theme.size.label
						}
					}
				}
			}
		}

		EmptyState {
			anchors.centerIn: parent
			visible: list.count === 0 && root.hits.length === 0
			icon: WhatsApp.syncing ? "sync" : "forum_outline"
			title: WhatsApp.syncing ? "Loading" : "No chats"
		}
	}
}
