pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.core.services
import qs.style.widgets

// What Messages shows, wherever it is shown – in the panel under the bar or
// in a window of its own: on the left the providers and the chats of the one
// that is picked; on the right the chat that is open, a new one being
// written, or the provider's settings. Where there is no room for both, one
// of the two is shown and the other is a step away.
Item {
	id: root

	// "chat" | "new" | "settings" | "customer"
	property string view: "chat"
	// the customer that is looked at
	property string customerId: ""
	readonly property bool empty: Mail.known && Mail.accounts.length === 0
	readonly property string shownView: root.empty ? "settings" : root.view
	// too narrow for list and chat side by side: `listed` says which of them shows
	readonly property bool narrow: root.width < 760
	property bool listed: true
	readonly property bool showsList: !root.narrow || (root.listed && !root.empty)
	// the chat is on the screen and the keyboard is here: what arrives in it is read
	readonly property bool looking: Messages.shown && Window.active && root.shownView === "chat" && (!root.narrow || !root.showsList)

	onLookingChanged: root.see()
	onShowsListChanged: (root.showsList && root.narrow ? listIn : paneIn).restart()

	function see() {
		if (root.looking && (Mail.openChat?.unread ?? 0) > 0) Mail.open(Mail.openId);
	}

	function compose(recipient) {
		root.view = "new";
		root.listed = false;
		newMail.start(recipient ?? "");
	}

	// the surface came up; `page`: "new" or "new:<address>" starts a chat, "settings" opens them, "chat" shows the open one
	function entered(page) {
		const wanted = String(page || "");
		chats.entered();
		if (wanted.startsWith("new")) root.compose(wanted.slice(4));
		else if (wanted === "settings") root.settings(true);
		else if (wanted === "chat") root.listed = false;
		else if (root.view !== "chat" && Mail.openId !== "") root.view = "chat";
		if (root.shownView === "settings") Mail.loadSettings();
		if (Mail.openId !== "" && !(root.narrow && root.listed)) Mail.open(Mail.openId);
		else if (root.shownView === "chat") Qt.callLater(chats.focusSearch);
		Mail.refresh();
	}

	function settings(on) {
		root.view = on ? "settings" : "chat";
		root.listed = !on && Mail.openChat === null;
		if (on) Mail.loadSettings();
	}

	// a new chat or the settings were left
	function leave() {
		root.view = "chat";
		if (Mail.openChat === null) root.listed = true;
	}

	Connections {
		target: Mail
		function onOpenIdChanged() {
			if (Mail.openId !== "") {
				root.view = "chat";
				root.listed = false;
			} else {
				root.listed = true;
			}
		}
		function onChatsChanged() {
			root.see();
		}
		// a new mail was taken back: it is written on
		function onUndone(key) {
			if (key === "new" && Messages.shown) root.compose("");
		}
	}

	// Ctrl+K: the customers. Alt+Down and Alt+Up: the next chat and the one before, from anywhere.
	Shortcut {
		sequence: "Ctrl+K"
		enabled: Messages.shown && root.visible && !root.empty
		onActivated: {
			root.listed = true;
			chats.showCustomers();
		}
	}

	Shortcut {
		sequence: "Alt+Down"
		enabled: Messages.shown && root.visible
		onActivated: chats.step(1)
	}

	Shortcut {
		sequence: "Alt+Up"
		enabled: Messages.shown && root.visible
		onActivated: chats.step(-1)
	}

	// the pane that comes up slides in from its side
	component SlideIn: ParallelAnimation {
		id: slide

		property Item pane
		property Translate shift
		property real from: 0

		Anim {
			target: slide.pane
			property: "opacity"
			from: 0
			to: 1
			duration: Motion.medium
		}
		SpatialAnim {
			target: slide.shift
			property: "x"
			from: slide.from
			to: 0
			duration: Motion.medium
		}
	}

	SlideIn {
		id: listIn

		pane: left
		shift: leftShift
		from: -24
	}

	SlideIn {
		id: paneIn

		pane: right
		shift: rightShift
		from: root.narrow ? 24 : 0
	}

	// one of the views on the right: it fades in over the one that leaves
	component Faded: Item {
		property bool active: false

		anchors.fill: parent
		enabled: active
		opacity: active ? 1 : 0
		visible: opacity > 0.01

		Behavior on opacity {
			Anim {
				duration: Motion.short
			}
		}
	}

	RowLayout {
		anchors.fill: parent
		spacing: 16

		ColumnLayout {
			id: left

			visible: root.showsList
			transform: Translate {
				id: leftShift
			}
			Layout.preferredWidth: 340
			Layout.maximumWidth: root.narrow ? Number.POSITIVE_INFINITY : 340
			Layout.fillWidth: root.narrow
			Layout.fillHeight: true
			spacing: 10

			RowLayout {
				Layout.fillWidth: true
				spacing: 6

				Repeater {
					model: Messages.providers

					delegate: Chip {
						id: tab

						required property var modelData

						implicitHeight: 34
						selected: Messages.provider?.id === tab.modelData.id
						icon: tab.modelData.icon
						text: tab.modelData.unread > 0 ? `${tab.modelData.name}  ${tab.modelData.unread}` : tab.modelData.name
						onClicked: Messages.current = tab.modelData.id
					}
				}

				Item {
					Layout.fillWidth: true
				}

				Spinner {
					visible: Mail.syncing && Mail.trouble === ""
					Layout.preferredWidth: 14
					Layout.preferredHeight: 14
				}

				// the mailbox is not in step: the settings say why
				IconButton {
					visible: Mail.trouble !== ""
					icon: "alert_circle"
					variant: "danger"
					onClicked: root.settings(true)
				}

				IconButton {
					icon: "email_plus_outline"
					variant: "tonal"
					checked: root.shownView === "new"
					enabled: !root.empty
					onClicked: root.shownView === "new" ? root.leave() : root.compose("")
				}

				// into a window of its own, and back under the bar
				IconButton {
					icon: Messages.windowed ? "arrow_collapse_all" : "open_in_new"
					variant: "tonal"
					onClicked: Messages.windowed ? Messages.dock() : Messages.popOut()
				}

				IconButton {
					icon: "cog"
					variant: "tonal"
					checked: root.shownView === "settings"
					onClicked: root.settings(root.view !== "settings")
				}
			}

			ChatList {
				id: chats

				Layout.fillWidth: true
				Layout.fillHeight: true
				onPicked: id => {
					root.view = "chat";
					root.listed = false;
					Mail.open(id);
				}
				onCompose: recipients => root.compose(recipients)
				onOverview: id => {
					if (root.narrow) return;
					root.customerId = id;
					root.view = "customer";
				}
				onKey: name => {
					if (root.shownView !== "chat" || Mail.openChat === null) return;
					if (name === "reply") pane.write();
					else if (name === "archive") Mail.archive(Mail.openId);
				}
			}

			// what is wrong, in words
			StyledText {
				Layout.fillWidth: true
				visible: Mail.trouble !== ""
				text: Mail.trouble
				tone: Theme.danger
				wrapMode: Text.Wrap
				maximumLineCount: 2
				elide: Text.ElideRight
				font.pixelSize: Theme.size.small
			}
		}

		Rectangle {
			visible: !root.narrow
			Layout.fillHeight: true
			Layout.preferredWidth: 1
			color: Theme.outline
		}

		Item {
			id: right

			visible: !root.showsList || !root.narrow
			transform: Translate {
				id: rightShift
			}
			Layout.fillWidth: true
			Layout.fillHeight: true

			Faded {
				active: root.shownView === "chat" && Mail.openChat !== null

				ChatPane {
					id: pane

					anchors.fill: parent
					narrow: root.narrow
					onBack: root.listed = true
					onPerson: email => {
						chats.pickPerson(email);
						root.listed = true;
					}
				}
			}

			Faded {
				active: root.shownView === "chat" && Mail.openChat === null

				EmptyState {
					anchors.centerIn: parent
					icon: "forum_outline"
					title: "No chat selected"
				}
			}

			Faded {
				active: root.shownView === "new"

				NewMail {
					id: newMail

					anchors.fill: parent
					onDone: root.leave()
				}
			}

			Faded {
				active: root.shownView === "customer"

				CustomerOverview {
					anchors.fill: parent
					customerId: root.customerId
					onOpen: id => {
						root.view = "chat";
						root.listed = false;
						Mail.open(id);
					}
					onCompose: recipients => root.compose(recipients)
					onDone: root.leave()
				}
			}

			Faded {
				active: root.shownView === "settings"

				MailSettings {
					anchors.fill: parent
					onDone: root.leave()
				}
			}
		}
	}
}
