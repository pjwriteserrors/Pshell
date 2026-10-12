pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.style.theme
import qs.core.services
import qs.style.widgets

// A new WhatsApp chat: with a contact, with a number that is typed, or –
// with several people ticked and a name – a new group. A link joins a group.
Item {
	id: root

	// the people of a group that is being made
	property var chosen: []
	property bool grouping: false
	readonly property string needle: search.text.trim().toLowerCase()
	readonly property string digits: search.text.replace(/\D/g, "")
	readonly property bool link: /chat\.whatsapp\.com\//.test(search.text)
	readonly property var shown: WhatsApp.contacts.filter(contact => root.needle === ""
		|| String(contact.name).toLowerCase().includes(root.needle) || (root.digits !== "" && contact.phone.includes(root.digits))).slice(0, 200)

	signal done
	signal open(string id)

	function entered() {
		root.chosen = [];
		root.grouping = false;
		search.text = "";
		title.text = "";
		WhatsApp.command("contacts");
		search.focusInput();
	}

	Connections {
		target: WhatsApp
		function onMade(chat) {
			if (root.visible) root.open(chat);
		}
	}

	ColumnLayout {
		anchors.fill: parent
		spacing: 8

		RowLayout {
			Layout.fillWidth: true
			spacing: 8

			IconButton {
				icon: "arrow_left"
				onClicked: root.done()
			}

			Field {
				id: search

				Layout.fillWidth: true
				icon: "magnify"
				placeholder: "Name, number or group link"
				onAccepted: {
					if (root.link) WhatsApp.command("join", { link: search.text.trim() });
					else if (root.shown.length === 0 && root.digits.length >= 7) WhatsApp.startChat(search.text);
					else if (root.shown.length > 0 && !root.grouping) root.open(root.shown[0].id);
				}
			}

			Chip {
				implicitHeight: 36
				icon: "account_multiple_plus"
				text: "Group"
				selected: root.grouping
				onClicked: root.grouping = !root.grouping
			}
		}

		RowLayout {
			visible: root.grouping
			Layout.fillWidth: true
			spacing: 6

			Field {
				id: title

				Layout.fillWidth: true
				icon: "account_group"
				placeholder: "Group name"
			}

			TextButton {
				text: root.chosen.length > 0 ? `Create (${root.chosen.length})` : "Create"
				variant: "filled"
				enabled: title.text.trim() !== "" && root.chosen.length > 0
				onActivated: WhatsApp.command("createGroup", { name: title.text.trim(), people: root.chosen })
			}
		}

		ListItem {
			visible: root.link
			Layout.fillWidth: true
			icon: "link_variant"
			title: "Join the group"
			onClicked: WhatsApp.command("join", { link: search.text.trim() })
		}

		ListItem {
			visible: !root.link && !root.grouping && root.digits.length >= 7 && /^[\d\s+()\/-]+$/.test(search.text.trim())
			Layout.fillWidth: true
			icon: "phone"
			title: search.text.trim()
			onClicked: WhatsApp.startChat(search.text)
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
				values: root.shown.map(contact => contact.id)
			}

			delegate: Clickable {
				id: row

				required property string modelData
				readonly property var contact: root.shown.find(contact => contact.id === row.modelData) ?? null
				readonly property bool picked: root.chosen.includes(row.modelData)

				width: ListView.view.width
				implicitHeight: 50
				radius: Theme.radius.medium
				pressedScale: 0.98
				showHover: false
				color: row.picked ? Theme.primaryContainer : (row.hovered ? Theme.layer1 : "transparent")
				onClicked: {
					if (!root.grouping) root.open(row.modelData);
					else root.chosen = row.picked ? root.chosen.filter(id => id !== row.modelData) : root.chosen.concat([row.modelData]);
				}

				RowLayout {
					anchors.fill: parent
					anchors.leftMargin: 10
					anchors.rightMargin: 12
					spacing: 10

					WaAvatar {
						size: 34
						name: row.contact?.name ?? ""
						key: row.modelData
						picture: row.contact?.avatar ?? ""
					}

					ColumnLayout {
						Layout.fillWidth: true
						spacing: 0

						StyledText {
							Layout.fillWidth: true
							text: row.contact?.name ?? ""
							elide: Text.ElideRight
							font.pixelSize: Theme.size.body
							font.weight: Font.DemiBold
						}

						StyledText {
							text: row.contact?.phone ?? ""
							tone: Theme.textSubtle
							font.pixelSize: Theme.size.tiny
						}
					}

					Glyph {
						visible: row.picked
						icon: "check_circle"
						size: 18
						color: Theme.primary
					}
				}
			}

			EmptyState {
				anchors.centerIn: parent
				visible: list.count === 0 && root.digits.length < 7 && !root.link
				icon: "account_multiple"
				title: "No contacts"
			}
		}
	}
}
