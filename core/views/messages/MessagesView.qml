pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.style.theme
import qs.core.services
import qs.style.widgets

// What Messages shows, wherever it is shown – in the panel under the bar or
// in a window of its own: on the left the providers and the chats of the one
// that is picked; on the right the chat that is open, a new one being
// written, or the provider's settings. Where there is no room for both, one
// of the two is shown and the other is a step away. The newsletters are a
// list and nothing beside it.
Item {
	id: root

	// "chat" | "new" | "settings" | "customer"
	property string view: "chat"
	// the customer that is looked at
	property string customerId: ""
	readonly property bool empty: Mail.known && Mail.accounts.length === 0
	readonly property string shownView: root.empty ? "settings" : root.view
	// the newsletters are looked at, not mail
	readonly property bool news: Messages.provider?.id === "mail-unsubscribe"
	// WhatsApp is looked at: its chats on the left, its chat on the right
	readonly property bool wa: Messages.provider?.id === "whatsapp"
	property bool waListed: true
	// too narrow for list and chat side by side: `listed` says which of them shows
	readonly property bool narrow: root.width < 760
	property bool listed: true
	readonly property bool showsList: root.news || !root.narrow || (root.wa ? root.waListed : root.listed && !root.empty)
	// the chat is on the screen and the keyboard is here: what arrives in it is read
	readonly property bool looking: Messages.shown && Window.active && root.shownView === "chat" && !root.news && !root.wa && (!root.narrow || !root.showsList)
	readonly property bool waLooking: Messages.shown && Window.active && root.wa && waPane.shown === "chat" && WhatsApp.openId !== "" && (!root.narrow || !root.showsList)

	onLookingChanged: root.see()
	onWaLookingChanged: root.waSee()
	onWaChanged: if (root.wa && !WhatsApp.linked) root.waListed = false
	onShowsListChanged: (root.showsList && root.narrow ? listIn : paneIn).restart()

	function see() {
		if (root.looking && (Mail.openChat?.unread ?? 0) > 0) Mail.open(Mail.openId);
	}

	// what arrives in the WhatsApp chat on the screen is seen
	function waSee() {
		if (root.waLooking && (WhatsApp.openChat?.unread ?? 0) > 0) WhatsApp.read(WhatsApp.openId);
	}

	function waPick(id, message) {
		Messages.current = "whatsapp";
		waPane.view = "chat";
		root.waListed = false;
		WhatsApp.open(id, message);
		WhatsApp.read(id);
		Qt.callLater(waPane.write);
	}

	function compose(recipient) {
		Messages.current = "mail";
		root.view = "new";
		root.listed = false;
		newMail.start(recipient ?? "");
	}

	// the surface came up; `page`: "new" or "new:<address>" starts a chat, "settings" opens them, "chat" shows the open one,
	// "newsletters" the newsletters
	function entered(page) {
		const wanted = String(page || "");
		if (wanted === "newsletters") Messages.current = "mail-unsubscribe";
		else if (wanted === "whatsapp") Messages.current = "whatsapp";
		else if (wanted !== "") Messages.current = "mail";
		chats.entered();
		if (root.wa) {
			waChats.entered();
			if (!WhatsApp.linked || (wanted === "whatsapp" && WhatsApp.openId !== "")) root.waListed = false;
			if (!root.narrow || root.waListed) Qt.callLater(waChats.focusSearch);
			else Qt.callLater(waPane.write);
			return;
		}
		if (root.news) {
			news.entered();
			return;
		}
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
		if (on) Messages.current = "mail";
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
				Messages.current = "mail";
				root.view = "chat";
				root.listed = false;
			} else {
				root.listed = true;
			}
		}
		function onChatsChanged() {
			root.see();
		}
		// another mailbox: the customer that was looked at is not its own
		function onShownChanged() {
			if (root.view === "customer") root.leave();
		}
		// a new mail was taken back: it is written on
		function onUndone(key) {
			if (key === "new" && Messages.shown) root.compose("");
		}
	}

	Connections {
		target: WhatsApp
		function onOpenIdChanged() {
			if (WhatsApp.openId === "") root.waListed = true;
		}
		function onChatsChanged() {
			root.waSee();
		}
		function onLinkedChanged() {
			root.waListed = WhatsApp.linked;
		}
	}

	// Ctrl+K: the customers. Alt+Down and Alt+Up: the next chat and the one before, from anywhere.
	Shortcut {
		sequence: "Ctrl+K"
		enabled: Messages.shown && root.visible && !root.empty && !root.news && !root.wa
		onActivated: {
			root.listed = true;
			chats.showCustomers();
		}
	}

	Shortcut {
		sequence: "Alt+Down"
		enabled: Messages.shown && root.visible && !root.news
		onActivated: root.wa ? waChats.step(1) : chats.step(1)
	}

	Shortcut {
		sequence: "Alt+Up"
		enabled: Messages.shown && root.visible && !root.news
		onActivated: root.wa ? waChats.step(-1) : chats.step(-1)
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

	// one of the views on the right: it comes up over the one that leaves
	component Faded: Item {
		id: faded

		property bool active: false

		anchors.fill: parent
		enabled: active
		opacity: active ? 1 : 0
		visible: opacity > 0.01
		transform: Translate {
			y: faded.active ? 0 : 12

			Behavior on y {
				SpatialAnim {
					duration: Motion.medium
				}
			}
		}

		Behavior on opacity {
			Anim {
				duration: faded.active ? Motion.medium : Motion.short
			}
		}
	}

	RowLayout {
		anchors.fill: parent
		spacing: 14

		ColumnLayout {
			id: left

			visible: root.showsList
			transform: Translate {
				id: leftShift
			}
			Layout.preferredWidth: 340
			Layout.maximumWidth: root.narrow || root.news ? Number.POSITIVE_INFINITY : 340
			Layout.fillWidth: root.narrow || root.news
			Layout.fillHeight: true
			spacing: 12

			RowLayout {
				Layout.fillWidth: true
				spacing: 4

				Repeater {
					model: ScriptModel {
						values: Messages.providers.map(provider => provider.id)
					}

					delegate: ProviderTab {
						id: tab

						required property string modelData

						provider: Messages.providers.find(provider => provider.id === tab.modelData) ?? null
						selected: Messages.provider?.id === tab.modelData
						// with more than two providers only the one that is looked at spells its name: the row is as wide as the list
						short: Messages.providers.length > 2 && !tab.selected
						onClicked: {
							Messages.current = tab.modelData;
							if (root.news) news.entered();
							else if (root.wa) waChats.entered();
						}
					}
				}

				Item {
					Layout.fillWidth: true
				}

				Spinner {
					visible: Mail.syncing && Mail.trouble === "" && !root.news && !root.wa
					Layout.preferredWidth: 14
					Layout.preferredHeight: 14
				}

				// the mailbox is not in step: the settings say why
				IconButton {
					visible: Mail.trouble !== "" && !root.wa
					icon: "alert_circle"
					variant: "danger"
					onClicked: root.settings(true)
				}

				IconButton {
					visible: root.wa && WhatsApp.linked
					icon: "message_text_outline"
					checked: waPane.shown === "new"
					onClicked: {
						waPane.show(waPane.shown === "new" ? "chat" : "new");
						root.waListed = waPane.shown !== "new" && WhatsApp.openChat === null;
					}
				}

				IconButton {
					visible: !root.news && !root.wa
					icon: "email_plus_outline"
					checked: root.shownView === "new"
					enabled: !root.empty
					onClicked: root.shownView === "new" ? root.leave() : root.compose("")
				}

				// into a window of its own, and back under the bar
				IconButton {
					icon: Messages.windowed ? "arrow_collapse_all" : "open_in_new"
					onClicked: Messages.windowed ? Messages.dock() : Messages.popOut()
				}

				IconButton {
					visible: !root.news && !root.wa
					icon: "cog"
					checked: root.shownView === "settings"
					onClicked: root.settings(root.view !== "settings")
				}

				IconButton {
					visible: root.wa && WhatsApp.linked
					icon: "cog"
					checked: waPane.shown === "account"
					onClicked: {
						waPane.show(waPane.shown === "account" ? "chat" : "account");
						root.waListed = waPane.shown !== "account" && WhatsApp.openChat === null;
					}
				}
			}

			NewsletterList {
				id: news

				visible: root.news
				Layout.fillWidth: true
				Layout.fillHeight: true
			}

			WaChatList {
				id: waChats

				visible: root.wa
				Layout.fillWidth: true
				Layout.fillHeight: true
				onPicked: (id, message) => root.waPick(id, message)
			}

			ChatList {
				id: chats

				visible: !root.news && !root.wa
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
				visible: Mail.trouble !== "" && !root.wa
				text: Mail.trouble
				tone: Theme.danger
				wrapMode: Text.Wrap
				maximumLineCount: 2
				elide: Text.ElideRight
				font.pixelSize: Theme.size.small
			}
		}

		Rectangle {
			visible: !root.narrow && !root.news
			Layout.fillHeight: true
			Layout.preferredWidth: 1
			color: Theme.outline
		}

		Item {
			id: right

			visible: !root.news && (!root.showsList || !root.narrow)
			transform: Translate {
				id: rightShift
			}
			Layout.fillWidth: true
			Layout.fillHeight: true

			Faded {
				active: !root.wa && root.shownView === "chat" && Mail.openChat !== null

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
				active: !root.wa && root.shownView === "chat" && Mail.openChat === null

				IdleStage {
					anchors.fill: parent
					live: Messages.shown
				}
			}

			Faded {
				active: !root.wa && root.shownView === "new"

				NewMail {
					id: newMail

					anchors.fill: parent
					onDone: root.leave()
				}
			}

			Faded {
				active: !root.wa && root.shownView === "customer"

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
				active: root.wa

				WaPane {
					id: waPane

					anchors.fill: parent
					narrow: root.narrow
					active: root.wa && Messages.shown && (!root.narrow || !root.showsList)
					onBack: root.waListed = true
					onPicked: id => root.waPick(id, "")
				}
			}

			Faded {
				active: !root.wa && root.shownView === "settings"

				MailSettings {
					anchors.fill: parent
					onDone: root.leave()
				}
			}
		}
	}

	// a picture of a mail, large
	PictureView {
		anchors.fill: parent
		radius: Theme.radius.large
	}
}
