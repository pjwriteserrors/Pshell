pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.style.theme
import qs.core.services
import qs.style.widgets

// Every chat, newest first. The field searches chats and people; picking a
// person keeps only the chats with them. With more than one mailbox, one is
// shown at a time. The customer bar (groups, outside the mailbox of work) opens the list of
// customers; picking one keeps the chats with anyone who was put into it and
// shows its people on top, to be written to. The pencil turns the list into
// the customer's people, to put them in and take them out.
ColumnLayout {
	id: root

	property string query: ""
	// the address of the person the list is narrowed to
	property string person: ""
	// the mailbox that is looked at: its chats, its people, and what its groups are called
	readonly property var chats: Mail.shownChats
	readonly property var people: Mail.shownPeople
	readonly property var words: Mail.grouping(Mail.shown)
	readonly property int unread: root.chats.reduce((sum, chat) => sum + chat.unread, 0)

	// "all" | "unread" | "flagged" | "later" (the chats put away)
	property string mode: "all"
	readonly property int later: root.chats.reduce((sum, chat) => sum + (Mail.snoozed[chat.id] !== undefined ? 1 : 0), 0)
	// mails on their way that the open chat does not show
	readonly property var leaving: Mail.outbox.filter(entry => entry.state !== "sent" && (entry.key !== Mail.openId || entry.key === "new"))

	onLaterChanged: if (root.later === 0 && root.mode === "later") root.mode = "all"
	// the customer the list is narrowed to, and whether its people are being picked
	property string customer: ""
	property bool editing: false
	// the list of customers is up
	property bool picking: false
	// every one of the customer's people is listed, not only the first few
	property bool allPeople: false
	// the chat opened from the unread ones stays among them until another is
	property string kept: ""
	readonly property var customerEntry: Customers.find(root.customer)
	readonly property string needle: root.query.trim().toLowerCase()
	readonly property var personEntry: root.people.find(entry => entry.email === root.person) ?? null

	readonly property var byId: {
		const map = {};
		for (const chat of root.chats) map[chat.id] = chat;
		return map;
	}
	readonly property var shown: {
		const hits = {};
		for (const id of Mail.hits ?? []) hits[id] = true;
		const needle = root.needle;
		const members = root.customerEntry?.people ?? null;
		return root.chats.filter(chat => {
			if (members && !chat.people.some(entry => members.includes(entry.email))) return false;
			// what was put away shows under Later, and in a search
			if ((Mail.snoozed[chat.id] !== undefined) !== (root.mode === "later") && needle === "") return false;
			if (root.mode === "unread" && chat.unread === 0 && chat.id !== root.kept) return false;
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
		for (const entry of root.people) known[entry.email] = entry;
		const all = members.map(email => known[email] ?? { email: email, name: email }).concat(root.people.filter(entry => !members.includes(entry.email)));
		return all.filter(entry => root.needle === "" || entry.name.toLowerCase().includes(root.needle) || entry.email.includes(root.needle));
	}
	// the customer's people, as the mailbox knows them
	readonly property var members: {
		if (!root.customerEntry) return [];
		const known = {};
		for (const entry of root.people) known[entry.email] = entry;
		return root.customerEntry.people.map(email => known[email] ?? { email: email, name: email, chats: 0, unread: 0 });
	}
	readonly property var customers: Customers.of(Mail.shown).filter(customer => {
		if (root.needle === "") return true;
		return customer.name.toLowerCase().includes(root.needle) || customer.people.some(email => email.includes(root.needle) || Mail.nameOf(email).toLowerCase().includes(root.needle));
	})
	readonly property var matches: root.needle === "" || root.editing || root.picking ? [] : root.people.filter(entry => entry.email !== root.person
		&& (entry.name.toLowerCase().includes(root.needle) || entry.email.includes(root.needle))).slice(0, 4)

	signal picked(string id)
	// a new mail to these addresses
	signal compose(string recipients)
	// a customer was picked: what there is to know about it
	signal overview(string id)
	// keys the list does not use itself: "reply", "archive"
	signal key(string name)

	onModeChanged: root.kept = ""
	onCustomerChanged: root.allPeople = false

	// the surface came up
	function entered() {
		root.kept = "";
	}

	function pick(id) {
		root.kept = root.mode === "unread" ? id : "";
		root.picked(id);
	}

	function clearSearch() {
		root.query = "";
		search.text = "";
		Mail.search("");
	}

	function choose(id) {
		root.customer = id;
		root.picking = false;
		root.clearSearch();
		if (id !== "") root.overview(id);
	}

	// the list of customers, from the keyboard
	function showCustomers() {
		root.editing = false;
		root.picking = true;
		root.clearSearch();
		search.focusInput();
	}

	// the chat before (-1) or after (1) the open one
	function step(by) {
		if (root.shown.length === 0) return;
		const at = root.shown.indexOf(Mail.openId);
		const next = Math.max(0, Math.min(root.shown.length - 1, at < 0 ? 0 : at + by));
		list.currentIndex = next;
		list.positionViewAtIndex(next, ListView.Contain);
		if (root.shown[next] !== Mail.openId) root.pick(root.shown[next]);
	}

	function whose(entry) {
		if (entry.key === "new") return (entry.draft.to ?? []).map(email => Mail.nameOf(email)).join(", ");
		return Mail.chats.find(chat => chat.id === entry.key)?.subject ?? "";
	}

	// when a customer's people last wrote or were written to, and in how many chats
	function activity(customer) {
		let last = 0;
		let count = 0;
		for (const chat of root.chats) {
			if (!chat.people.some(entry => customer.people.includes(entry.email))) continue;
			count += 1;
			last = Math.max(last, chat.date);
		}
		return { last: last, count: count };
	}

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
		return root.chats.reduce((sum, chat) => sum + (chat.people.some(entry => customer.people.includes(entry.email)) ? chat.unread : 0), 0);
	}

	function edit(id) {
		root.customer = id;
		root.picking = false;
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

	// another mailbox shows nothing of this one's
	Connections {
		target: Mail
		function onShownChanged() {
			root.editing = false;
			root.picking = false;
			root.customer = "";
			root.person = "";
			root.clearSearch();
		}
	}

	// the mailboxes, one at a time
	Segmented {
		Layout.fillWidth: true
		visible: Mail.accounts.length > 1
		implicitHeight: 34
		current: Mail.shown
		options: Mail.accounts.map(account => {
			const unread = Mail.unreadOf(account.id);
			return { value: account.id, label: unread > 0 ? `${Mail.label(account)}  ${unread}` : Mail.label(account) };
		})
		onSelected: value => Mail.pick(value)
	}

	Field {
		id: search

		Layout.fillWidth: true
		icon: "magnify"
		placeholder: "Search"
		onEdited: text => {
			root.query = text;
			if (!root.editing && !root.picking) ask.restart();
		}
		onAccepted: {
			if (root.editing || root.picking) return;
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

		Chip {
			visible: root.person !== ""
			implicitWidth: 34
			icon: "email_plus_outline"
			onClicked: root.compose(root.person)
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

	// the customer the list is kept to; a click brings up all of them
	Clickable {
		id: bar

		Layout.fillWidth: true
		visible: !root.editing
		implicitHeight: 40
		radius: Theme.radius.large
		pressedScale: 0.98
		color: root.customerEntry && !root.picking ? Theme.primaryContainer : Theme.layer1
		onClicked: {
			root.picking = !root.picking;
			root.clearSearch();
			search.focusInput();
		}

		RowLayout {
			anchors.fill: parent
			anchors.leftMargin: 13
			anchors.rightMargin: 4
			spacing: 8

			Glyph {
				icon: root.words.icon
				size: 17
				color: root.customerEntry ? Theme.primary : Theme.textSubtle
			}

			StyledText {
				Layout.fillWidth: true
				text: root.customerEntry ? (root.customerEntry.name || root.words.one) : root.words.many
				tone: root.customerEntry ? Theme.text : Theme.textMuted
				elide: Text.ElideRight
				font.pixelSize: Theme.size.body
				font.weight: root.customerEntry ? Font.DemiBold : Font.Normal
			}

			Badge {
				count: root.customerEntry && !root.picking ? root.unreadOf(root.customerEntry) : 0
			}

			IconButton {
				visible: root.customerEntry !== null && !root.picking
				implicitWidth: 30
				implicitHeight: 30
				icon: "email_plus_outline"
				onClicked: root.compose(root.customerEntry.people.join(", "))
			}

			IconButton {
				visible: root.customerEntry !== null && !root.picking
				implicitWidth: 30
				implicitHeight: 30
				icon: "pencil"
				onClicked: root.edit(root.customer)
			}

			IconButton {
				visible: root.customerEntry !== null && !root.picking
				implicitWidth: 30
				implicitHeight: 30
				icon: "close"
				onClicked: root.choose("")
			}

			Item {
				visible: root.customerEntry === null || root.picking
				implicitWidth: 30
				implicitHeight: 30

				Glyph {
					anchors.centerIn: parent
					icon: "chevron_right"
					size: 18
					color: Theme.textSubtle
					rotation: root.picking ? 90 : 0

					Behavior on rotation {
						SpatialAnim {
							duration: Motion.medium
						}
					}
				}
			}
		}
	}

	// every customer, one to a row
	ListView {
		id: picker

		Layout.fillWidth: true
		Layout.fillHeight: true
		visible: root.picking && !root.editing
		clip: true
		spacing: 2
		boundsBehavior: Flickable.StopAtBounds
		ScrollBar.vertical: ThinScrollBar {}
		model: ScriptModel {
			values: root.customers.map(customer => customer.id)
		}

		displaced: Transition {
			SpatialAnim {
				property: "y"
				duration: Motion.medium
			}
		}

		header: Clickable {
			width: picker.width
			implicitHeight: 46
			radius: Theme.radius.medium
			pressedScale: 0.98
			showHover: false
			color: hovered ? Theme.layer1 : "transparent"
			onClicked: root.edit(Customers.create("", Mail.shown))

			RowLayout {
				anchors.fill: parent
				anchors.leftMargin: 10
				anchors.rightMargin: 12
				spacing: 10

				Rectangle {
					implicitWidth: 36
					implicitHeight: 36
					radius: 18
					color: Theme.layer2

					Glyph {
						anchors.centerIn: parent
						icon: "plus"
						size: 18
						color: Theme.primary
					}
				}

				StyledText {
					Layout.fillWidth: true
					text: root.words.fresh
					font.pixelSize: Theme.size.body
					font.weight: Font.DemiBold
				}
			}
		}

		delegate: Clickable {
			id: entry

			// fades in by itself: a transition of the list can be cut short and leave a row unseen
			ListView.onAdd: entryIn.restart()

			Anim {
				id: entryIn

				target: entry
				property: "opacity"
				from: 0
				to: 1
			}

			required property string modelData
			readonly property var customer: Customers.find(entry.modelData) ?? { id: entry.modelData, name: "", people: [] }
			readonly property bool current: root.customer === entry.modelData

			width: ListView.view.width
			implicitHeight: 54
			radius: Theme.radius.medium
			pressedScale: 0.98
			showHover: false
			color: entry.current ? Theme.primaryContainer : (entry.hovered ? Theme.layer1 : "transparent")
			onClicked: root.choose(entry.modelData)

			RowLayout {
				anchors.fill: parent
				anchors.leftMargin: 10
				anchors.rightMargin: 6
				spacing: 10

				ChatAvatar {
					visible: entry.customer.people.length > 0
					people: entry.customer.people.slice(0, 2).map(email => ({ email: email, name: Mail.nameOf(email) }))
					size: 36
					surface: entry.current ? Theme.primaryContainer : (entry.hovered ? Theme.layer1 : Theme.base)
				}

				Rectangle {
					visible: entry.customer.people.length === 0
					implicitWidth: 36
					implicitHeight: 36
					radius: 18
					color: Theme.layer2

					Glyph {
						anchors.centerIn: parent
						icon: root.words.icon
						size: 17
						color: Theme.textSubtle
					}
				}

				ColumnLayout {
					Layout.fillWidth: true
					spacing: 1

					StyledText {
						Layout.fillWidth: true
						text: entry.customer.name || root.words.one
						elide: Text.ElideRight
						font.pixelSize: Theme.size.body
						font.weight: Font.DemiBold
					}

					StyledText {
						readonly property var activity: root.activity(entry.customer)

						Layout.fillWidth: true
						text: activity.count > 0 ? `${activity.count} ${activity.count === 1 ? "chat" : "chats"} · ${root.stamp(activity.last)}` : entry.customer.people.map(email => Mail.nameOf(email)).join(", ")
						tone: Theme.textMuted
						elide: Text.ElideRight
						font.pixelSize: Theme.size.small
					}
				}

				Badge {
					count: root.unreadOf(entry.customer)
				}

				IconButton {
					implicitWidth: 30
					implicitHeight: 30
					icon: "pencil"
					opacity: entry.hovered ? 1 : 0
					onClicked: root.edit(entry.modelData)

					Behavior on opacity {
						Anim {
							duration: Motion.short
						}
					}
				}
			}
		}
	}

	RowLayout {
		Layout.fillWidth: true
		visible: root.editing
		spacing: 6

		Field {
			id: customerName

			Layout.fillWidth: true
			icon: root.words.icon
			placeholder: root.words.one
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
		visible: !root.editing && !root.picking
		implicitHeight: 32
		current: root.mode
		options: [
			{ value: "all", label: "All" },
			{ value: "unread", label: root.unread > 0 ? `Unread ${root.unread}` : "Unread" },
			{ value: "flagged", label: "Starred" }
		].concat(root.later > 0 ? [{ value: "later", label: `Later ${root.later}` }] : [])
		onSelected: value => root.mode = value
	}

	ListView {
		id: list

		Layout.fillWidth: true
		Layout.fillHeight: true
		visible: !root.editing && !root.picking
		clip: true
		spacing: 2
		boundsBehavior: Flickable.StopAtBounds
		ScrollBar.vertical: ThinScrollBar {}
		model: ScriptModel {
			values: root.shown
		}

		remove: Transition {
			Anim {
				property: "opacity"
				to: 0
				duration: Motion.short
			}
		}
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
			Anim {
				property: "opacity"
				to: 1
				duration: Motion.short
			}
		}

		// the customer's people: a click keeps the list to the chats with one, the letter writes to them
		header: Column {
			width: list.width
			visible: root.customerEntry !== null
			height: visible ? implicitHeight : 0
			spacing: 2

			Repeater {
				model: ScriptModel {
					values: (root.allPeople ? root.members : root.members.slice(0, 4)).map(entry => entry.email)
				}

				delegate: Clickable {
					id: member

					required property string modelData
					readonly property var who: root.members.find(entry => entry.email === member.modelData) ?? { email: member.modelData, name: member.modelData, unread: 0 }
					readonly property bool current: root.person === member.modelData

					width: list.width
					implicitHeight: 44
					radius: Theme.radius.medium
					pressedScale: 0.98
					showHover: false
					color: member.current ? Theme.primaryContainer : (member.hovered ? Theme.layer1 : "transparent")
					onClicked: {
						if (member.current) root.person = "";
						else root.pickPerson(member.modelData);
					}

					RowLayout {
						anchors.fill: parent
						anchors.leftMargin: 14
						anchors.rightMargin: 6
						spacing: 10

						Avatar {
							size: 30
							name: member.who.name
							email: member.who.email
						}

						ColumnLayout {
							Layout.fillWidth: true
							spacing: 0

							StyledText {
								Layout.fillWidth: true
								text: member.who.name
								elide: Text.ElideRight
								font.pixelSize: Theme.size.label
								font.weight: Font.DemiBold
							}

							StyledText {
								Layout.fillWidth: true
								visible: member.who.name !== member.who.email
								text: member.who.email
								tone: Theme.textMuted
								elide: Text.ElideRight
								font.pixelSize: Theme.size.small
							}
						}

						Badge {
							count: member.who.unread ?? 0
						}

						IconButton {
							implicitWidth: 30
							implicitHeight: 30
							icon: "email_plus_outline"
							onClicked: root.compose(member.modelData)
						}
					}
				}
			}

			Clickable {
				visible: root.members.length > 4
				width: list.width
				implicitHeight: 26
				radius: Theme.radius.medium
				showHover: false
				onClicked: root.allPeople = !root.allPeople

				Glyph {
					anchors.centerIn: parent
					icon: "chevron_down"
					size: 16
					color: Theme.textSubtle
					rotation: root.allPeople ? 180 : 0

					Behavior on rotation {
						SpatialAnim {
							duration: Motion.medium
						}
					}
				}
			}

			Item {
				width: list.width
				height: 9

				Rectangle {
					y: 4
					x: 10
					width: parent.width - 20
					height: 1
					color: Theme.outline
				}
			}
		}
		// older mail is fetched as the end comes near
		onAtYEndChanged: if (atYEnd && contentHeight > height && root.needle === "" && root.mode === "all") Mail.older()

		Keys.onReturnPressed: if (currentIndex >= 0 && currentIndex < root.shown.length) root.pick(root.shown[currentIndex])
		// with the keyboard in the list: j and k walk the chats, r answers, e archives, / searches
		Keys.onPressed: event => {
			if (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) return;
			if (event.key === Qt.Key_J) root.step(1);
			else if (event.key === Qt.Key_K) root.step(-1);
			else if (event.key === Qt.Key_R) root.key("reply");
			else if (event.key === Qt.Key_E) root.key("archive");
			else if (event.key === Qt.Key_Slash) search.focusInput();
			else return;
			event.accepted = true;
		}

		delegate: Clickable {
			id: item

			// fades in by itself: a transition of the list can be cut short and leave a row unseen
			ListView.onAdd: itemIn.restart()

			Anim {
				id: itemIn

				target: item
				property: "opacity"
				from: 0
				to: 1
			}

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
			// where the keyboard is
			border.width: list.activeFocus && ListView.isCurrentItem ? 1.5 : 0
			border.color: Qt.alpha(Theme.primary, 0.85)
			onClicked: {
				list.currentIndex = item.index;
				list.forceActiveFocus();
				root.pick(item.modelData);
			}

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
			anchors.verticalCenterOffset: (list.headerItem?.height ?? 0) / 2
			visible: list.count === 0 && Mail.known
			icon: Mail.searching || Mail.syncing ? "sync" : "forum_outline"
			title: Mail.searching ? "Searching" : (Mail.syncing ? "Loading" : "No chats")
		}
	}

	// mails on their way that no open chat shows: taken back, sent again
	Repeater {
		model: ScriptModel {
			values: root.leaving.map(entry => entry.id)
		}

		delegate: Rectangle {
			id: strip

			required property string modelData
			readonly property var entry: root.leaving.find(entry => entry.id === strip.modelData) ?? { id: "", key: "", state: "sending", error: "", at: 0, draft: {} }
			readonly property bool failed: strip.entry.state === "failed"

			Layout.fillWidth: true
			implicitHeight: 44
			radius: Theme.radius.medium
			color: strip.failed ? Theme.dangerContainer : Theme.layer1
			clip: true

			// what is left of the moment it can be taken back in
			Rectangle {
				visible: strip.entry.state === "waiting"
				anchors.bottom: parent.bottom
				width: parent.width * Math.max(0, Math.min(1, 1 - (Mail.now - strip.entry.at) / Mail.grace))
				height: 2
				color: Theme.primary
			}

			RowLayout {
				anchors.fill: parent
				anchors.leftMargin: 12
				anchors.rightMargin: 4
				spacing: 8

				Glyph {
					visible: strip.entry.state !== "sending"
					icon: strip.failed ? "alert_circle" : "send"
					size: 15
					color: strip.failed ? Theme.danger : Theme.primary
				}

				Spinner {
					visible: strip.entry.state === "sending"
					Layout.preferredWidth: 14
					Layout.preferredHeight: 14
				}

				ColumnLayout {
					Layout.fillWidth: true
					spacing: 0

					StyledText {
						Layout.fillWidth: true
						text: root.whose(strip.entry) || strip.entry.draft.subject || ""
						elide: Text.ElideRight
						font.pixelSize: Theme.size.label
						font.weight: Font.DemiBold
					}

					StyledText {
						Layout.fillWidth: true
						visible: text !== ""
						text: strip.failed ? strip.entry.error : (strip.entry.text ?? "")
						tone: strip.failed ? Theme.danger : Theme.textMuted
						elide: Text.ElideRight
						font.pixelSize: Theme.size.small
					}
				}

				IconButton {
					visible: strip.failed
					implicitWidth: 30
					implicitHeight: 30
					icon: "refresh"
					onClicked: Mail.dispatch(strip.modelData)
				}

				IconButton {
					visible: strip.failed
					implicitWidth: 30
					implicitHeight: 30
					icon: "pencil"
					onClicked: Mail.undo(strip.modelData)
				}

				TextButton {
					visible: strip.entry.state === "waiting"
					implicitHeight: 30
					text: "Undo"
					icon: "undo"
					variant: "ghost"
					onActivated: Mail.undo(strip.modelData)
				}
			}
		}
	}
}
