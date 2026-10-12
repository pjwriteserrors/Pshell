pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.style.theme
import qs.core.services
import qs.style.widgets

// The WhatsApp chat that is open: who it is with and what they are doing
// above, the messages, and the field an answer is written in. Files dropped
// on it go with the next message; a message that is forwarded picks its
// chats over the pane.
Item {
	id: root

	readonly property var chat: WhatsApp.openChat
	// there is room for either the list or the chat
	property bool narrow: false
	property string flashId: ""
	// the message that is forwarded, and the chats it goes to
	property var forwarding: null
	property var targets: []
	property string shownId: ""
	// the message that was the oldest before older ones were asked for
	property string anchor: ""
	readonly property var byId: {
		const map = {};
		WhatsApp.messages.forEach((message, index) => map[message.id] = index);
		return map;
	}
	readonly property string status: {
		if (!root.chat) return "";
		if (WhatsApp.typing.length > 0) return root.chat.group ? `${WhatsApp.typing.join(", ")} typing…` : "typing…";
		if (root.chat.group) return "";
		if (WhatsApp.online) return "online";
		if (WhatsApp.seen > 0) return `last seen ${WhatsApp.stamp(WhatsApp.seen)}`;
		return root.chat.phone ?? "";
	}

	signal back
	signal details

	function write() {
		composer.focusInput();
	}

	function jump(id) {
		const index = root.byId[id];
		if (index === undefined) {
			// further back than what is shown
			WhatsApp.open(WhatsApp.openId, id);
			return;
		}
		list.stick = false;
		list.positionViewAtIndex(index, ListView.Center);
		root.flashId = id;
		unflash.restart();
	}

	Timer {
		id: unflash

		interval: 1600
		onTriggered: root.flashId = ""
	}

	Connections {
		target: WhatsApp
		function onOpenIdChanged() {
			composer.swap(root.shownId, WhatsApp.openId);
			root.shownId = WhatsApp.openId;
			root.forwarding = null;
			list.stick = true;
			if (WhatsApp.openId !== "") {
				arrive.restart();
				if (WhatsApp.openChat?.group) WhatsApp.askInfo(WhatsApp.openId);
			}
		}
		function onMessagesChanged() {
			// a search led to a message: it is shown once it is among the ones loaded
			if (WhatsApp.target !== "" && root.byId[WhatsApp.target] !== undefined) {
				const id = WhatsApp.target;
				WhatsApp.target = "";
				Qt.callLater(() => root.jump(id));
			} else if (root.anchor !== "" && root.byId[root.anchor] !== undefined && root.byId[root.anchor] > 0) {
				// older messages came: the one that was on top stays where it was
				const index = root.byId[root.anchor];
				root.anchor = "";
				Qt.callLater(() => list.positionViewAtIndex(index, ListView.Beginning));
			}
		}
	}

	ColumnLayout {
		anchors.fill: parent
		spacing: 10

		RowLayout {
			Layout.fillWidth: true
			spacing: 6

			IconButton {
				visible: root.narrow
				icon: "arrow_left"
				onClicked: root.back()
			}

			Clickable {
				Layout.fillWidth: true
				implicitHeight: 48
				radius: Theme.radius.large
				pressedScale: 0.99
				onClicked: root.details()

				RowLayout {
					anchors.fill: parent
					anchors.leftMargin: 6
					anchors.rightMargin: 10
					spacing: 12

					WaAvatar {
						size: 38
						name: root.chat?.name ?? ""
						key: root.chat?.id ?? ""
						picture: root.chat?.avatar ?? ""
						group: root.chat?.group ?? false
					}

					ColumnLayout {
						Layout.fillWidth: true
						spacing: 1

						StyledText {
							Layout.fillWidth: true
							text: String(root.chat?.name ?? "").replace(/^~/, "")
							elide: Text.ElideRight
							font.pixelSize: Theme.size.title
							font.weight: Font.DemiBold
						}

						StyledText {
							visible: text !== ""
							Layout.fillWidth: true
							text: root.status
							tone: WhatsApp.typing.length > 0 || WhatsApp.online ? Theme.primary : Theme.textMuted
							elide: Text.ElideRight
							font.pixelSize: Theme.size.label
						}
					}
				}
			}

			Glyph {
				visible: (root.chat?.ephemeral ?? 0) > 0
				icon: "timer_outline"
				size: 16
				color: Theme.textSubtle
			}

			IconButton {
				icon: "palette_outline"
				checked: stage.picking
				onClicked: stage.picking = !stage.picking
			}

			IconButton {
				icon: "information_outline"
				onClicked: root.details()
			}
		}

		ChatStage {
			id: stage

			Layout.fillWidth: true
			Layout.fillHeight: true
			scroll: list.contentHeight > list.height ? Math.max(0, Math.min(1, (list.contentY - list.originY) / (list.contentHeight - list.height))) : 1
			live: Messages.shown

			ListView {
				id: list

				// at the newest message, and staying there as messages load and arrive
				property bool stick: true

				anchors.fill: parent
				anchors.leftMargin: stage.inset
				anchors.rightMargin: Math.max(2, stage.inset - 8)
				clip: true
				spacing: 2
				boundsBehavior: Flickable.StopAtBounds
				ScrollBar.vertical: ThinScrollBar {}
				cacheBuffer: 1200
				model: ScriptModel {
					values: WhatsApp.messages.map(message => message.id)
				}
				onContentHeightChanged: if (list.stick) Qt.callLater(list.positionViewAtEnd)
				onCountChanged: if (list.stick) Qt.callLater(list.positionViewAtEnd)
				onMovingChanged: if (!list.moving) list.stick = list.atYEnd
				onHeightChanged: if (list.stick) Qt.callLater(list.positionViewAtEnd)

				transform: Translate {
					id: shift
				}

				ParallelAnimation {
					id: arrive

					Anim {
						target: list
						property: "opacity"
						from: 0
						to: 1
						duration: Motion.medium
					}
					SpatialAnim {
						target: shift
						property: "y"
						from: 14
						to: 0
						duration: Motion.medium
					}
				}

				header: Item {
					width: list.width
					height: WhatsApp.more && WhatsApp.messages.length > 0 ? 48 : 10

					Chip {
						anchors.centerIn: parent
						visible: WhatsApp.more && WhatsApp.messages.length > 0
						icon: WhatsApp.loadingOlder ? "" : "chevron_up"
						text: WhatsApp.loadingOlder ? "Loading" : "Earlier messages"
						onClicked: {
							root.anchor = WhatsApp.messages[0]?.id ?? "";
							list.stick = false;
							WhatsApp.older();
						}
					}
				}

				delegate: WaBubble {
					id: bubble

					required property string modelData
					readonly property int at: root.byId[bubble.modelData] ?? -1

					// the one that just arrived or was sent comes up out of its corner
					ListView.onAdd: if (!arrive.running && bubble.at === WhatsApp.messages.length - 1) bubble.appear()

					width: ListView.view.width - 10
					message: WhatsApp.messages[bubble.at] ?? { id: "", sender: "", name: "", mine: false, date: 0, kind: "system", text: "", html: "", status: 0 }
					previous: bubble.at > 0 ? WhatsApp.messages[bubble.at - 1] : null
					group: root.chat?.group ?? false
					flash: root.flashId === bubble.modelData
					onReply: composer.answer(bubble.message)
					onEdit: composer.change(bubble.message)
					onJump: id => root.jump(id)
					onBurst: (emoji, x, y) => stage.burst(emoji, list.x + x, list.y + y - list.contentY)
					onForward: {
						root.targets = [];
						root.forwarding = bubble.message;
					}
				}

				// someone is writing
				footer: Item {
					readonly property bool shown: WhatsApp.typing.length > 0

					width: list.width
					height: shown ? 46 : 12

					Behavior on height {
						SpatialAnim {
							duration: Motion.medium
						}
					}

					Rectangle {
						y: 6
						width: 54
						height: 30
						radius: 15
						color: Messages.theirs
						transformOrigin: Item.BottomLeft
						scale: parent.shown ? 1 : 0.6
						opacity: parent.shown ? 1 : 0

						Behavior on scale {
							SpatialAnim {
								duration: Motion.medium
							}
						}
						Behavior on opacity {
							Anim {
								duration: Motion.short
							}
						}

						TypingDots {
							anchors.centerIn: parent
							running: parent.opacity > 0.01
						}
					}
				}
			}

			// back down to the newest
			IconButton {
				readonly property bool wanted: !list.stick && !list.atYEnd

				anchors.right: parent.right
				anchors.bottom: parent.bottom
				anchors.margins: 12
				implicitWidth: 38
				implicitHeight: 38
				scale: wanted ? 1 : 0
				opacity: wanted ? 1 : 0
				visible: scale > 0.01
				icon: "arrow_down"
				color: Theme.layer3
				onClicked: {
					list.stick = true;
					flick.stop();
					const from = list.contentY;
					list.positionViewAtEnd();
					// a long way is not gone in full
					flick.from = Math.max(from, list.contentY - 900);
					flick.to = list.contentY;
					flick.start();
				}

				Behavior on scale {
					SpatialAnim {
						duration: Motion.medium
					}
				}
				Behavior on opacity {
					Anim {
						duration: Motion.short
					}
				}

				// the way down is seen
				NumberAnimation {
					id: flick

					target: list
					property: "contentY"
					duration: Motion.long
					easing.type: Easing.BezierSpline
					easing.bezierCurve: Motion.decel
				}

				Badge {
					anchors.right: parent.right
					anchors.top: parent.top
					count: root.chat?.unread ?? 0
				}
			}

			EmptyState {
				anchors.centerIn: parent
				visible: list.count === 0
				icon: "message_text_outline"
				title: "No messages"
			}
		}

		WaComposer {
			id: composer

			objectName: "waComposer"
			Layout.fillWidth: true
			chat: WhatsApp.openId
			group: root.chat?.group ?? false
		}
	}

	DropZone {
		anchors.fill: parent
		onFiles: paths => composer.add(paths)
	}

	// who a message is forwarded to
	Rectangle {
		anchors.fill: parent
		visible: root.forwarding !== null
		radius: Theme.radius.large
		color: Theme.base

		MouseArea {
			anchors.fill: parent
			acceptedButtons: Qt.AllButtons
			onWheel: wheel => wheel.accepted = true
		}

		ColumnLayout {
			anchors.fill: parent
			spacing: 8

			RowLayout {
				Layout.fillWidth: true
				spacing: 8

				IconButton {
					icon: "close"
					onClicked: root.forwarding = null
				}

				StyledText {
					Layout.fillWidth: true
					text: "Forward to"
					font.pixelSize: Theme.size.title
					font.weight: Font.DemiBold
				}

				TextButton {
					text: root.targets.length > 0 ? `Send (${root.targets.length})` : "Send"
					icon: "send"
					variant: "filled"
					enabled: root.targets.length > 0
					onActivated: {
						WhatsApp.act("forward", root.forwarding.id, { to: root.targets });
						root.forwarding = null;
					}
				}
			}

			Field {
				id: whom

				Layout.fillWidth: true
				icon: "magnify"
				placeholder: "Search"
			}

			ListView {
				Layout.fillWidth: true
				Layout.fillHeight: true
				clip: true
				spacing: 2
				boundsBehavior: Flickable.StopAtBounds
				ScrollBar.vertical: ThinScrollBar {}
				model: ScriptModel {
					values: root.forwarding === null ? [] : WhatsApp.chats.filter(chat => String(chat.name).toLowerCase().includes(whom.text.trim().toLowerCase()))
						.sort((a, b) => b.date - a.date).slice(0, 80).map(chat => chat.id)
				}

				delegate: Clickable {
					id: target

					required property string modelData
					readonly property var chat: WhatsApp.chats.find(chat => chat.id === target.modelData) ?? null
					readonly property bool chosen: root.targets.includes(target.modelData)

					width: ListView.view.width
					implicitHeight: 48
					radius: Theme.radius.medium
					pressedScale: 0.98
					showHover: false
					color: target.chosen ? Theme.primaryContainer : (target.hovered ? Theme.layer1 : "transparent")
					onClicked: root.targets = target.chosen ? root.targets.filter(id => id !== target.modelData) : root.targets.concat([target.modelData])

					RowLayout {
						anchors.fill: parent
						anchors.leftMargin: 10
						anchors.rightMargin: 12
						spacing: 10

						WaAvatar {
							size: 32
							name: target.chat?.name ?? ""
							key: target.modelData
							picture: target.chat?.avatar ?? ""
							group: target.chat?.group ?? false
						}

						StyledText {
							Layout.fillWidth: true
							text: target.chat?.name ?? ""
							elide: Text.ElideRight
							font.pixelSize: Theme.size.body
						}

						Glyph {
							visible: target.chosen
							icon: "check_circle"
							size: 18
							color: Theme.primary
						}
					}
				}
			}
		}
	}
}
