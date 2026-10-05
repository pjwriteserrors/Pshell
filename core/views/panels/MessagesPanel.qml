pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.core.services
import qs.style.widgets
import qs.core.views.panels.messages

// Messages: what reaches the user, provider by provider, as chats. On the
// left the providers and the chats of the one that is picked; on the right
// the chat that is open, a new one being written, or the provider's settings.
Drawer {
	id: root

	// "chat" | "new" | "settings"
	property string view: "chat"
	readonly property bool empty: Mail.known && Mail.accounts.length === 0
	readonly property string shownView: root.empty ? "settings" : root.view

	panelId: "messages"
	panelWidth: Math.min(1120, (root.screen?.width ?? 1920) - 80)
	contentHeight: 740

	function compose(recipient) {
		root.view = "new";
		newMail.start(recipient ?? "");
	}

	onPanelOpened: {
		// "new" or "new:<address>" starts a chat, "settings" opens them
		const page = String(Popups.page || "");
		if (page.startsWith("new")) root.compose(page.slice(4));
		else if (page === "settings") root.view = "settings";
		else if (root.view !== "chat" && Mail.openId !== "") root.view = "chat";
		if (root.shownView === "settings") Mail.loadSettings();
		if (Mail.openId !== "") Mail.open(Mail.openId);
		else if (root.shownView === "chat") Qt.callLater(chats.focusSearch);
		Mail.refresh();
	}

	Connections {
		target: Mail
		function onOpenIdChanged() {
			if (Mail.openId !== "") root.view = "chat";
		}
	}

	RowLayout {
		anchors.fill: parent
		spacing: 16

		ColumnLayout {
			Layout.preferredWidth: 340
			Layout.maximumWidth: 340
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
					visible: Mail.syncing
					Layout.preferredWidth: 14
					Layout.preferredHeight: 14
				}

				IconButton {
					icon: "email_plus_outline"
					variant: "tonal"
					checked: root.shownView === "new"
					enabled: !root.empty
					onClicked: root.shownView === "new" ? root.view = "chat" : root.compose("")
				}

				IconButton {
					icon: "cog"
					variant: "tonal"
					checked: root.shownView === "settings"
					onClicked: {
						root.view = root.view === "settings" ? "chat" : "settings";
						if (root.view === "settings") Mail.loadSettings();
					}
				}
			}

			ChatList {
				id: chats

				Layout.fillWidth: true
				Layout.fillHeight: true
				onPicked: id => {
					root.view = "chat";
					Mail.open(id);
				}
			}
		}

		Rectangle {
			Layout.fillHeight: true
			Layout.preferredWidth: 1
			color: Theme.outline
		}

		Item {
			Layout.fillWidth: true
			Layout.fillHeight: true

			ChatPane {
				anchors.fill: parent
				visible: root.shownView === "chat" && Mail.openChat !== null
				onPerson: email => chats.pickPerson(email)
			}

			EmptyState {
				anchors.centerIn: parent
				visible: root.shownView === "chat" && Mail.openChat === null
				icon: "forum_outline"
				title: "No chat selected"
			}

			NewMail {
				id: newMail

				anchors.fill: parent
				visible: root.shownView === "new"
				onDone: root.view = "chat"
			}

			MailSettings {
				anchors.fill: parent
				visible: root.shownView === "settings"
				onDone: root.view = "chat"
			}
		}
	}
}
