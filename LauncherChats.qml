pragma ComponentBehavior: Bound

import QtQuick
import "components"

// The saved chats, hung from a thread newest first. The one that is open
// carries a chip; a chat that is still answering has a breathing knot.
// Enter or a click opens one; forgetting one is a hold.
Item {
	id: panel

	required property LauncherEngine engine
	property real reveal: 1

	readonly property var chats: engine.filteredAiChats

	Band {
		reveal: panel.reveal
		order: 1
		x: 0
		y: 0
		width: parent.width
		height: 32

		FText {
			x: 18
			anchors.verticalCenter: parent.verticalCenter
			text: panel.engine.chatsSearchQuery !== ""
				? `chats · ${panel.chats.length} of ${panel.engine.aiChats.length}`
				: `saved chats · ${panel.engine.aiChats.length}`
			tone: "faint"
			caps: true
			font.pixelSize: Filament.textXs
		}

		FButton {
			anchors.right: parent.right
			anchors.verticalCenter: parent.verticalCenter
			text: "New chat"
			icon: "chat-message-new-symbolic"
			kind: "charge"
			compact: true
			iconSize: 13
			enabled: !panel.engine.aiStreaming
			onClicked: panel.engine.startNewChat()
		}
	}

	Band {
		reveal: panel.reveal
		order: 2
		x: 0
		y: 40
		width: parent.width
		height: parent.height - 40 - (panel.engine.aiError !== "" ? 22 : 0)

		ListView {
			id: list
			x: 4
			y: 0
			width: parent.width - 4
			height: parent.height
			clip: true
			model: panel.chats
			currentIndex: panel.engine.chatIndex
			boundsBehavior: Flickable.StopAtBounds
			highlightFollowsCurrentItem: false
			onCurrentIndexChanged: if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain)

			ThreadLine {
				parent: list.contentItem
				x: 0
				y: 0
				height: Math.max(list.height, list.contentHeight)
				litY: list.currentItem ? list.currentItem.y + list.currentItem.height / 2 : -1
				litLength: 30
				z: -1
			}

			delegate: ThreadRow {
				id: row
				required property var modelData
				required property int index
				readonly property string chatId: String(modelData?.id || "")
				readonly property bool open: chatId !== "" && chatId === panel.engine.activeChatId && !panel.engine.aiTemporaryChatEnabled
				readonly property bool answering: panel.engine.aiStreaming && panel.engine.aiStreamingChatId === chatId
				width: list.width
				height: 46
				inset: 16
				selected: index === panel.engine.chatIndex
				onEntered: panel.engine.chatIndex = index
				onClicked: panel.engine.openPastChat(row.modelData)

				Column {
					anchors.left: parent.left
					anchors.right: verbs.left
					anchors.rightMargin: 10
					anchors.verticalCenter: parent.verticalCenter
					spacing: 2

					Row {
						width: parent.width
						spacing: 8
						FText {
							width: Math.min(implicitWidth, parent.width - 90)
							text: String(row.modelData?.title || "Untitled chat")
							font.pixelSize: Filament.textMd
							font.weight: row.selected ? Font.DemiBold : Font.Medium
							color: row.selected ? Filament.ink : Filament.inkSoft
						}
						Spark {
							visible: row.answering
							anchors.verticalCenter: parent.verticalCenter
							size: 5
							breathing: true
						}
						Chip {
							visible: row.open
							anchors.verticalCenter: parent.verticalCenter
							text: "open"
							lit: true
							mono: false
						}
					}

					FText {
						width: parent.width
						text: `${String(row.modelData?.model || "Unknown model")} · ${panel.engine.formatChatTime(row.modelData?.updatedAt)} · ${(row.modelData?.messages || []).length} messages`
						tone: "mute"
						mono: true
						font.pixelSize: Filament.textXs
					}
				}

				Item {
					id: verbs
					anchors.right: parent.right
					anchors.rightMargin: 6
					anchors.verticalCenter: parent.verticalCenter
					width: forget.implicitWidth
					height: parent.height
					opacity: row.selected || row.hovered ? 1 : 0
					Behavior on opacity { NumberAnimation { duration: Filament.quick } }

					HoldButton {
						id: forget
						anchors.verticalCenter: parent.verticalCenter
						text: "Forget"
						icon: "edit-delete-symbolic"
						enabled: !row.answering
						implicitHeight: 28
						onHeld: panel.engine.deleteChat(row.modelData)
					}
				}
			}
		}

		Item {
			x: 4
			y: 0
			width: parent.width - 4
			height: 48
			visible: panel.chats.length === 0

			Rectangle {
				x: -2
				y: 17
				width: 6; height: 6; radius: 3
				color: Filament.wireDim
			}
			FText {
				x: 20
				y: 6
				text: panel.engine.chatsSearchQuery !== "" ? "No matching chats" : "No saved chats"
				tone: "soft"
				font.pixelSize: Filament.textMd
			}
			FText {
				x: 20
				y: 26
				width: parent.width - 20
				text: panel.engine.chatsSearchQuery !== ""
					? "Every word has to appear in the title"
					: "Chats are temporary unless you switch Temporary off before sending"
				tone: "faint"
				font.pixelSize: Filament.textXs
			}
		}
	}

	FText {
		anchors.left: parent.left
		anchors.leftMargin: 18
		anchors.right: parent.right
		anchors.bottom: parent.bottom
		visible: panel.engine.aiError !== ""
		text: panel.engine.aiError
		tone: "alert"
		font.pixelSize: Filament.textXs
	}
}
