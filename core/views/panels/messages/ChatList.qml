pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.style.theme
import qs.core.services
import qs.style.widgets

// Every chat, newest first. The field searches chats and people; picking a
// person keeps only the chats with them, picking a customer the chats with
// anyone who was put into it. The pencil turns the list into the customer's
// people, to put them in and take them out.
ColumnLayout {
	id: root

	property string query: ""
	// the address of the person the list is narrowed to
	property string person: ""
	// "all" | "unread" | "flagged"
	property string mode: "all"
	// the customer the list is narrowed to, and whether its people are being picked
	property string customer: ""
	property bool editing: false
	readonly property var customerEntry: Customers.find(root.customer)
	readonly property string needle: root.query.trim().toLowerCase()
	readonly property var personEntry: Mail.people.find(entry => entry.email === root.person) ?? null

	readonly property var byId: {
		const map = {};
		for (const chat of Mail.chats) map[chat.id] = chat;
		return map;
	}
	readonly property var shown: {
		const hits = {};
		for (const id of Mail.hits ?? []) hits[id] = true;
		const needle = root.needle;
		const members = root.customerEntry?.people ?? null;
		return Mail.chats.filter(chat => {
			if (members && !chat.people.some(entry => members.includes(entry.email))) return false;
			if (root.mode === "unread" && chat.unread === 0 && chat.id !== Mail.openId) return false;
			if (root.mode === "flagged" && !chat.flagged) return false;
			if (root.person !== "" && !chat.people.some(entry => entry.email === root.person)) return false;
			if (needle === "" || hits[chat.id]) return true;
			return chat.subject.toLowerCase().includes(needle) || String(chat.preview).toLowerCase().includes(needle)
				|| chat.people.some(entry => entry.name.toLowerCase().includes(needle) || entry.email.includes(needle));
		}).map(chat => chat.id);
	}
	// who can be put into the customer: its people first, then everyone known
	readonly property var candidates: {
		if (!root.editing || !root.customerEntry) return [];
		const members = root.customerEntry.people;
		const known = {};
		for (const entry of Mail.people) known[entry.email] = entry;
		const all = members.map(email => known[email] ?? { email: email, name: email }).concat(Mail.people.filter(entry => !members.includes(entry.email)));
		return all.filter(entry => root.needle === "" || entry.name.toLowerCase().includes(root.needle) || entry.email.includes(root.needle));
	}
	readonly property var matches: root.needle === "" || root.editing ? [] : Mail.people.filter(entry => entry.email !== root.person
		&& (entry.name.toLowerCase().includes(root.needle) || entry.email.includes(root.needle))).slice(0, 4)

	signal picked(string id)

	function focusSearch() {
		search.focusInput();
	}

	function pickPerson(email) {
		root.person = email;
		root.query = "";
		search.text = "";
		Mail.search("");
	}

	function unreadOf(customer) {
		return Mail.chats.reduce((sum, chat) => sum + (chat.people.some(entry => customer.people.includes(entry.email)) ? chat.unread : 0), 0);
	}

	function edit(id) {
		root.customer = id;
		root.editing = true;
		root.query = "";
		search.text = "";
		customerName.text = Customers.find(id)?.name ?? "";
		Qt.callLater(() => customerName.text === "" ? customerName.focusInput() : search.focusInput());
	}

	function finish() {
		root.editing = false;
		root.query = "";
		search.text = "";
		// a customer left without a name and without people was never one
		const entry = root.customerEntry;
		if (entry && entry.name === "" && entry.people.length === 0) {
			Customers.remove(entry.id);
			root.customer = "";
		}
	}

	function stamp(seconds) {
		const date = new Date(seconds * 1000);
		const now = new Date();
		if (date.toDateString() === now.toDateString()) return Qt.formatTime(date, "HH:mm");
		if (now - date < 6 * 86400 * 1000) return Qt.formatDate(date, "ddd");
		return Qt.formatDate(date, date.getFullYear() === now.getFullYear() ? "d MMM" : "d MMM yy");
	}

	spacing: 8

	Field {
		id: search

		Layout.fillWidth: true
		icon: "magnify"
		placeholder: "Search"
		onEdited: text => {
			root.query = text;
			if (!root.editing) ask.restart();
		}
		onAccepted: {
			if (root.editing) return;
			ask.stop();
			Mail.search(root.query);
		}
		onDownPressed: list.forceActiveFocus()
	}

	// the mailbox is asked once the typing rests
	Timer {
		id: ask

		interval: 700
		onTriggered: Mail.search(root.needle.length >= 3 ? root.query : "")
	}

	Flow {
		Layout.fillWidth: true
		visible: !root.editing && (root.person !== "" || root.matches.length > 0)
		spacing: 6

		Chip {
			visible: root.person !== ""
			selected: true
			icon: "close"
			text: root.personEntry?.name ?? root.person
			onClicked: root.person = ""
		}

		Repeater {
			model: root.matches

			delegate: Chip {
				required property var modelData

				icon: "account"
				text: modelData.name
				onClicked: root.pickPerson(modelData.email)
			}
		}
	}

	// customers
	Flow {
		Layout.fillWidth: true
		visible: !root.editing
		spacing: 6

		Repeater {
			model: Customers.list

			delegate: Chip {
				id: tag

				required property var modelData
				readonly property int unread: root.unreadOf(tag.modelData)

				selected: root.customer === tag.modelData.id
				icon: "office_building"
				text: tag.unread > 0 ? `${tag.modelData.name}  ${tag.unread}` : tag.modelData.name
				onClicked: root.customer = tag.selected ? "" : tag.modelData.id
			}
		}

		Chip {
			visible: root.customer !== ""
			icon: "pencil"
			implicitWidth: 34
			onClicked: root.edit(root.customer)
		}

		Chip {
			icon: "plus"
			implicitWidth: 34
			onClicked: root.edit(Customers.create(""))
		}
	}

	RowLayout {
		Layout.fillWidth: true
		visible: root.editing
		spacing: 6

		Field {
			id: customerName

			Layout.fillWidth: true
			icon: "office_building"
			placeholder: "Customer"
			onEdited: text => Customers.rename(root.customer, text)
			onAccepted: search.focusInput()
		}

		TextButton {
			text: ""
			icon: "delete_outline"
			variant: "danger"
			confirm: true
			confirmText: "Delete"
			onActivated: {
				Customers.remove(root.customer);
				root.customer = "";
				root.finish();
			}
		}

		IconButton {
			implicitWidth: 40
			implicitHeight: 40
			icon: "check"
			variant: "filled"
			onClicked: root.finish()
		}
	}

	ListView {
		Layout.fillWidth: true
		Layout.fillHeight: true
		visible: root.editing
		clip: true
		spacing: 2
		boundsBehavior: Flickable.StopAtBounds
		ScrollBar.vertical: ThinScrollBar {}
		model: ScriptModel {
			values: root.candidates.map(entry => entry.email)
		}

		delegate: Clickable {
			id: row

			required property string modelData
			readonly property var who: root.candidates.find(entry => entry.email === row.modelData) ?? { email: row.modelData, name: row.modelData }
			readonly property bool member: root.customerEntry?.people.includes(row.modelData) ?? false

			width: ListView.view.width
			implicitHeight: 48
			radius: Theme.radius.medium
			pressedScale: 0.98
			showHover: false
			color: row.member ? Theme.primaryContainer : (row.hovered ? Theme.layer1 : "transparent")
			onClicked: Customers.toggle(root.customer, row.modelData)

			RowLayout {
				anchors.fill: parent
				anchors.leftMargin: 10
				anchors.rightMargin: 12
				spacing: 10

				Avatar {
					size: 32
					name: row.who.name
					email: row.who.email
				}

				ColumnLayout {
					Layout.fillWidth: true
					spacing: 0

					StyledText {
						Layout.fillWidth: true
						text: row.who.name
						elide: Text.ElideRight
						font.pixelSize: Theme.size.body
						font.weight: Font.DemiBold
					}

					StyledText {
						Layout.fillWidth: true
						visible: row.who.name !== row.who.email
						text: row.who.email
						tone: Theme.textMuted
						elide: Text.ElideRight
						font.pixelSize: Theme.size.small
					}
				}

				Glyph {
					visible: row.member
					icon: "check"
					size: 16
					color: Theme.primary
				}
			}
		}
	}

	Segmented {
		Layout.fillWidth: true
		visible: !root.editing
		implicitHeight: 32
		current: root.mode
		options: [
			{ value: "all", label: "All" },
			{ value: "unread", label: Mail.unread > 0 ? `Unread ${Mail.unread}` : "Unread" },
			{ value: "flagged", label: "Starred" }
		]
		onSelected: value => root.mode = value
	}

	ListView {
		id: list

		Layout.fillWidth: true
		Layout.fillHeight: true
		visible: !root.editing
		clip: true
		spacing: 2
		boundsBehavior: Flickable.StopAtBounds
		ScrollBar.vertical: ThinScrollBar {}
		model: ScriptModel {
			values: root.shown
		}
		// older mail is fetched as the end comes near
		onAtYEndChanged: if (atYEnd && contentHeight > height && root.needle === "" && root.mode === "all") Mail.older()

		Keys.onReturnPressed: if (currentIndex >= 0 && currentIndex < root.shown.length) root.picked(root.shown[currentIndex])

		delegate: Clickable {
			id: item

			required property string modelData
			required property int index
			readonly property var chat: root.byId[item.modelData] ?? null
			readonly property bool current: item.modelData === Mail.openId
			readonly property bool fresh: (item.chat?.unread ?? 0) > 0

			width: ListView.view.width
			implicitHeight: 62
			radius: Theme.radius.medium
			pressedScale: 0.98
			showHover: false
			color: item.current ? Theme.primaryContainer : (item.hovered ? Theme.layer1 : "transparent")
			onClicked: root.picked(item.modelData)

			RowLayout {
				anchors.fill: parent
				anchors.leftMargin: 10
				anchors.rightMargin: 10
				spacing: 10

				ChatAvatar {
					people: item.chat?.people ?? []
					size: 40
					surface: item.current ? Theme.primaryContainer : (item.hovered ? Theme.layer1 : Theme.base)
				}

				ColumnLayout {
					Layout.fillWidth: true
					spacing: 2

					RowLayout {
						Layout.fillWidth: true
						spacing: 6

						StyledText {
							Layout.fillWidth: true
							text: item.chat?.subject ?? ""
							elide: Text.ElideRight
							font.pixelSize: Theme.size.body
							font.weight: item.fresh ? Font.Bold : Font.DemiBold
						}

						Glyph {
							visible: item.chat?.flagged ?? false
							icon: "star"
							size: 12
							color: Theme.warning
						}

						Glyph {
							visible: item.chat?.attachments ?? false
							icon: "paperclip"
							size: 12
							color: Theme.textSubtle
						}

						StyledText {
							text: item.chat ? root.stamp(item.chat.date) : ""
							tone: item.fresh ? Theme.primary : Theme.textSubtle
							font.pixelSize: Theme.size.tiny
							font.weight: item.fresh ? Font.Bold : Font.Normal
						}
					}

					RowLayout {
						Layout.fillWidth: true
						spacing: 6

						StyledText {
							Layout.fillWidth: true
							readonly property string who: {
								if (!item.chat) return "";
								if (item.chat.mine) return "You: ";
								return item.chat.sender ? `${String(item.chat.sender).split(/[\s,]+/)[0]}: ` : "";
							}
							text: `${who}${item.chat?.preview || (item.chat?.people ?? []).map(entry => entry.name).join(", ")}`
							elide: Text.ElideRight
							tone: item.fresh ? Theme.text : Theme.textMuted
							font.pixelSize: Theme.size.small
						}

						Badge {
							count: item.chat?.unread ?? 0
						}
					}
				}
			}
		}

		EmptyState {
			anchors.centerIn: parent
			visible: list.count === 0 && Mail.known
			icon: Mail.searching || Mail.syncing ? "sync" : "forum_outline"
			title: Mail.searching ? "Searching" : (Mail.syncing ? "Loading" : "No chats")
		}
	}
}
