pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.style.theme
import qs.core.services
import qs.style.widgets

// The chat that is open: who it is with, its mails as bubbles and the field
// that answers them. An answer goes to everyone in the chat unless it is
// narrowed to the sender, and refers to the last mail unless another one was
// picked.
ColumnLayout {
	id: root

	readonly property var chat: Mail.openChat
	readonly property var byId: {
		const map = {};
		for (let i = 0; i < Mail.messages.length; i += 1) map[Mail.messages[i].id] = i;
		return map;
	}
	// the mail an answer refers to: the one picked, else the last one from someone else
	property var picked: null
	property bool forwarding: false
	// "replyAll" | "reply"
	property string scope: "replyAll"
	readonly property var target: {
		if (root.picked) return root.picked;
		for (let i = Mail.messages.length - 1; i >= 0; i -= 1)
			if (!Mail.messages[i].mine && !Mail.messages[i].auto) return Mail.messages[i];
		return Mail.messages[Mail.messages.length - 1] ?? null;
	}
	readonly property var away: (root.chat?.people ?? []).filter(person => Mail.tips[person.email])
	property string flashId: ""
	// what a bubble shows for the moment its mail has left the chat
	readonly property var blank: ({
		id: "", from: { name: "", email: "" }, to: [], cc: [], date: 0, mine: false, read: true, flagged: false, subject: "",
		html: "", text: "", signature: "", quote: "", attachments: [], loaded: true, auto: false, invite: false,
		importance: "normal", link: "", forward: false, ref: null, signatureRich: false, signaturePage: null, designed: false, drawable: false, page: null
	})
	property string error: ""
	property int pending: 0

	signal person(string email)

	function reset() {
		root.picked = null;
		root.forwarding = false;
		root.error = "";
		root.scope = "replyAll";
		forwardTo.text = "";
	}

	function jump(id) {
		const index = root.byId[id];
		if (index === undefined) return;
		list.positionViewAtIndex(index, ListView.Center);
		root.flashId = id;
		unflash.restart();
	}

	function addresses(text) {
		return String(text).split(/[\s,;]+/).map(entry => entry.replace(/^<|>$/g, "")).filter(entry => entry.includes("@"));
	}

	function send() {
		if (!root.chat || !root.target) return;
		const draft = {
			account: root.chat.account,
			mode: root.forwarding ? "forward" : root.scope,
			reply: root.target.id,
			text: composer.text,
			files: composer.files
		};
		if (root.forwarding) {
			draft.to = root.addresses(forwardTo.text);
			if (draft.to.length === 0) {
				root.error = "No recipient";
				return;
			}
		}
		root.error = "";
		root.pending = Mail.send(draft);
	}

	spacing: 10

	Connections {
		target: Mail
		function onOpenIdChanged() {
			root.reset();
			composer.clear();
			list.stick = true;
		}
		function onSent(request, ok, error) {
			if (request !== root.pending) return;
			root.pending = 0;
			if (ok) {
				composer.clear();
				root.reset();
				list.stick = true;
			} else {
				root.error = error;
			}
		}
	}

	Timer {
		id: unflash

		interval: 1400
		onTriggered: root.flashId = ""
	}

	// who the chat is with
	RowLayout {
		Layout.fillWidth: true
		spacing: 10

		ChatAvatar {
			people: root.chat?.people ?? []
			size: 40
		}

		ColumnLayout {
			Layout.fillWidth: true
			spacing: 1

			StyledText {
				Layout.fillWidth: true
				text: root.chat?.subject ?? ""
				elide: Text.ElideRight
				font.pixelSize: Theme.size.title
				font.weight: Font.Bold
			}

			// a click on a name keeps the list to the chats with them
			Row {
				Layout.fillWidth: true
				spacing: 0
				clip: true

				Repeater {
					model: (root.chat?.people ?? []).slice(0, 6)

					delegate: StyledText {
						id: name

						required property var modelData
						required property int index

						text: `${modelData.name}${index < Math.min(6, root.chat.people.length) - 1 ? ", " : ""}`
						tone: nameArea.containsMouse ? Theme.primary : Theme.textMuted
						font.pixelSize: Theme.size.small

						MouseArea {
							id: nameArea

							anchors.fill: parent
							hoverEnabled: true
							cursorShape: Qt.PointingHandCursor
							onClicked: root.person(name.modelData.email)
						}
					}
				}

				StyledText {
					visible: (root.chat?.people.length ?? 0) > 6
					text: ` +${(root.chat?.people.length ?? 0) - 6}`
					tone: Theme.textSubtle
					font.pixelSize: Theme.size.small
				}
			}
		}

		Spinner {
			visible: Mail.loading
			Layout.preferredWidth: 16
			Layout.preferredHeight: 16
		}

		IconButton {
			icon: root.chat?.flagged ? "star" : "star_outline"
			iconColor: root.chat?.flagged ? Theme.warning : Theme.text
			onClicked: Mail.setFlag(root.chat.id, !root.chat.flagged)
		}

		IconButton {
			icon: "email_mark_as_unread"
			onClicked: {
				const id = root.chat.id;
				Mail.close();
				Mail.setRead(id, false);
			}
		}

		IconButton {
			icon: "archive_outline"
			onClicked: Mail.archive(root.chat.id)
		}

		TextButton {
			text: ""
			icon: "delete_outline"
			variant: "danger"
			confirm: true
			confirmText: "Delete chat"
			onActivated: Mail.remove(root.chat.id)
		}
	}

	ListView {
		id: list

		// at the newest mail, and staying there as mails load and arrive
		property bool stick: true

		Layout.fillWidth: true
		Layout.fillHeight: true
		clip: true
		spacing: 3
		boundsBehavior: Flickable.StopAtBounds
		ScrollBar.vertical: ThinScrollBar {}
		// tall mails must not be thrown away while they are scrolled through
		cacheBuffer: 2000
		model: ScriptModel {
			values: Mail.messages.map(message => message.id)
		}
		onContentHeightChanged: if (list.stick) Qt.callLater(list.positionViewAtEnd)
		onCountChanged: if (list.stick) Qt.callLater(list.positionViewAtEnd)
		onMovingChanged: if (!list.moving) list.stick = list.atYEnd
		onHeightChanged: if (list.stick) Qt.callLater(list.positionViewAtEnd)

		delegate: Bubble {
			required property string modelData
			required property int index

			width: ListView.view.width - 12
			message: Mail.messages[root.byId[modelData]] ?? root.blank
			previous: index > 0 ? (Mail.messages[index - 1] ?? null) : null
			group: root.chat?.group ?? false
			flash: root.flashId === modelData
			onJump: id => root.jump(id)
			onReply: {
				root.forwarding = false;
				root.picked = message;
				composer.focusInput();
			}
			onForward: {
				root.picked = message;
				root.forwarding = true;
				forwardTo.focusInput();
			}
		}
	}

	// who of them is away
	Repeater {
		model: root.away

		delegate: Rectangle {
			id: tip

			required property var modelData

			Layout.fillWidth: true
			implicitHeight: 34
			radius: Theme.radius.medium
			color: Qt.tint(Theme.bg, Qt.alpha(Theme.warning, 0.14))

			RowLayout {
				anchors.fill: parent
				anchors.leftMargin: 12
				anchors.rightMargin: 12
				spacing: 8

				Glyph {
					icon: "beach"
					size: 15
					color: Theme.warning
				}

				StyledText {
					text: `${tip.modelData.name} is away`
					font.pixelSize: Theme.size.small
					font.weight: Font.DemiBold
				}

				StyledText {
					Layout.fillWidth: true
					text: String(Mail.tips[tip.modelData.email] ?? "").replace(/\s+/g, " ")
					tone: Theme.textMuted
					elide: Text.ElideRight
					font.pixelSize: Theme.size.small
				}
			}
		}
	}

	// the mail the answer refers to, when one was picked
	Rectangle {
		Layout.fillWidth: true
		visible: root.picked !== null
		implicitHeight: 40
		radius: Theme.radius.medium
		color: Theme.layer1

		Rectangle {
			width: 3
			height: parent.height
			radius: 1.5
			color: Theme.primary
		}

		RowLayout {
			anchors.fill: parent
			anchors.leftMargin: 12
			anchors.rightMargin: 4
			spacing: 8

			Glyph {
				icon: root.forwarding ? "share" : "reply"
				size: 15
				color: Theme.primary
			}

			ColumnLayout {
				Layout.fillWidth: true
				spacing: 0

				StyledText {
					Layout.fillWidth: true
					text: root.picked ? (root.picked.mine ? "You" : root.picked.from.name) : ""
					tone: Theme.primary
					elide: Text.ElideRight
					font.pixelSize: Theme.size.small
					font.weight: Font.DemiBold
				}

				StyledText {
					Layout.fillWidth: true
					text: String(root.picked?.text ?? "").replace(/\s+/g, " ").slice(0, 200)
					tone: Theme.textMuted
					elide: Text.ElideRight
					font.pixelSize: Theme.size.small
				}
			}

			IconButton {
				implicitWidth: 30
				implicitHeight: 30
				icon: "close"
				onClicked: {
					root.picked = null;
					root.forwarding = false;
				}
			}
		}
	}

	Field {
		id: forwardTo

		Layout.fillWidth: true
		visible: root.forwarding
		icon: "account"
		placeholder: "To"
		onAccepted: composer.focusInput()
	}

	StyledText {
		Layout.fillWidth: true
		visible: root.error !== ""
		text: root.error
		tone: Theme.danger
		wrapMode: Text.Wrap
		font.pixelSize: Theme.size.small
	}

	RowLayout {
		Layout.fillWidth: true
		spacing: 8

		// a group can be answered as a whole or only to who wrote
		Segmented {
			Layout.alignment: Qt.AlignBottom
			Layout.preferredWidth: 150
			implicitHeight: 40
			visible: (root.chat?.group ?? false) && !root.forwarding && root.target !== null && !root.target.mine
			current: root.scope
			options: [
				{ value: "replyAll", label: "All", icon: "account_multiple" },
				{ value: "reply", label: String(root.target?.from.name ?? "").split(" ")[0], icon: "account" }
			]
			onSelected: value => root.scope = value
		}

		Composer {
			id: composer

			Layout.fillWidth: true
			busy: Mail.sending
			allowEmpty: root.forwarding
			placeholder: root.forwarding ? "Add a message" : "Message"
			onSubmit: root.send()
		}
	}
}
