pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.style.theme
import qs.core.services
import qs.style.widgets

// The chat that is open: who it is with, its mails as bubbles and the field
// that answers them. An answer refers to the last mail unless another one
// was picked, and goes to everyone that mail went to; who gets it is shown
// above the field, where people are taken out, others put in and a click
// turns To into Cc into Bcc. What is written stays with its chat while
// another one is looked at. A mail that was sent waits a moment below the
// others, where it can be taken back; one that did not go out stays there.
// The chat can be searched (Ctrl+F) and put away until later. With the
// assistant (plugin mail-ai) a local model writes an answer from notes, in a
// panel of its own beside the chat, or frames what was written with a
// greeting, thanks and a last sentence; both are proposals that are taken.
Item {
	id: root

	readonly property var chat: Mail.openChat
	// one pane at a time: the way back to the list is shown
	property bool narrow: false
	readonly property var byId: {
		const map = {};
		for (let i = 0; i < Mail.messages.length; i += 1) map[Mail.messages[i].id] = i;
		return map;
	}
	// the mail an answer refers to: the one picked, else the last one from someone else
	property var picked: null
	property bool forwarding: false
	readonly property var target: {
		if (root.picked) return Mail.messages[root.byId[root.picked.id]] ?? root.picked;
		for (let i = Mail.messages.length - 1; i >= 0; i -= 1)
			if (!Mail.messages[i].mine && !Mail.messages[i].auto) return Mail.messages[i];
		return Mail.messages[Mail.messages.length - 1] ?? null;
	}
	// who an answer to the target goes to when nobody was picked: [{ email, name, kind: "to" | "cc" | "bcc" }]
	readonly property var everyone: {
		const target = root.target;
		const out = [];
		if (!target || !root.chat) return out;
		const seen = {};
		const add = (person, kind) => {
			if (!person.email || seen[person.email] || Mail.own(root.chat.account, person.email)) return;
			seen[person.email] = true;
			out.push({ email: person.email, name: person.name, kind: kind });
		};
		if (!target.mine) add(target.from, "to");
		for (const person of target.to) add(person, "to");
		for (const person of target.cc) add(person, "cc");
		return out;
	}
	// who was picked instead, or null
	property var chosen: null
	readonly property var recipients: root.chosen ?? (root.forwarding ? [] : root.everyone)
	// people of the chat the answer does not go to
	readonly property var others: (root.chat?.people ?? []).filter(person => !root.recipients.some(entry => entry.email === person.email)).slice(0, 4)
	property bool adding: false
	readonly property string token: adder.text.trim().toLowerCase()
	readonly property var offers: !root.adding || root.token.length < 2 ? [] : Mail.people.filter(person => !root.recipients.some(entry => entry.email === person.email)
		&& (person.name.toLowerCase().includes(root.token) || person.email.includes(root.token))).slice(0, 5)
	readonly property var away: (root.chat?.people ?? []).filter(person => Mail.tips[person.email])
	property string flashId: ""
	// what a bubble shows for the moment its mail has left the chat
	readonly property var blank: ({
		id: "", from: { name: "", email: "" }, to: [], cc: [], date: 0, mine: false, read: true, flagged: false, subject: "",
		html: "", text: "", signature: "", quote: "", attachments: [], loaded: true, auto: false, invite: false,
		importance: "normal", link: "", forward: false, ref: null, signatureRich: false, signaturePage: null, designed: false, drawable: false, page: null
	})
	property string error: ""
	// the chat whose mails are shown
	property string shownId: ""
	// what was sent from here and is on its way
	readonly property var outgoing: Mail.outbox.filter(entry => entry.key === Mail.openId)

	// the chat is being searched: the mails that say it, and the one that is shown
	property bool finding: false
	readonly property string sought: finder.text.trim().toLowerCase()
	readonly property var found: !root.finding || root.sought.length < 2 ? [] : Mail.messages.filter(message =>
		String(message.text).toLowerCase().includes(root.sought) || String(message.subject).toLowerCase().includes(root.sought)
		|| message.from.name.toLowerCase().includes(root.sought)).map(message => message.id)
	property int foundAt: -1
	// when to bring the chat back is being picked
	property bool snoozing: false
	readonly property bool snoozed: root.chat !== null && Mail.snoozed[root.chat.id] !== undefined
	// someone in the chat who seems to belong to a customer: { person, customer }
	readonly property var offer: {
		if (!root.chat) return null;
		const account = Mail.account(root.chat.account);
		const own = [account?.address ?? ""].concat(account?.own ?? []).map(address => address.split("@")[1] ?? "");
		for (const person of root.chat.people) {
			const customer = Customers.suggest(person.email, own);
			if (customer) return { person: person, customer: customer };
		}
		return null;
	}

	signal person(string email)
	signal back

	onFoundChanged: {
		root.foundAt = root.found.length > 0 ? root.found.length - 1 : -1;
		if (root.foundAt >= 0) root.jump(root.found[root.foundAt]);
	}

	// the assistant's panel is up, and beside the chat where there is room for both
	property bool assisting: false
	readonly property bool beside: root.assisting && root.width >= 860
	// the frame the assistant proposes for this chat, and which of its sentences are wanted
	readonly property var framed: MailAssist.framed !== null && MailAssist.framed.key === Mail.openId ? MailAssist.framed : null
	property bool withThanks: true
	property bool withClosing: true

	// what the assistant is told about the chat
	function context() {
		const account = Mail.account(root.chat.account);
		return {
			me: account?.name || account?.address || "",
			to: root.recipients.filter(entry => entry.kind === "to").map(entry => ({ name: entry.name, email: entry.email })),
			thread: Mail.messages.filter(message => !message.auto).slice(-4).map(message => ({
				from: message.from.name, email: message.from.email, mine: message.mine, date: message.date,
				text: String(message.text).slice(0, 1500), signature: String(message.signature).slice(0, 400)
			})),
			draft: composer.words()
		};
	}

	function applyFrame() {
		const frame = root.framed;
		if (!frame) return;
		composer.wrap(`${frame.greeting}\n\n${root.withThanks && frame.thanks ? frame.thanks + "\n\n" : ""}`, root.withClosing && frame.closing ? `\n\n${frame.closing}` : "");
		MailAssist.framed = null;
	}

	// the field the answer is written in
	function write() {
		composer.focusInput();
	}

	function find() {
		root.finding = true;
		finder.focusInput();
	}

	// the match before (-1) or after (1) the one shown
	function step(by) {
		if (root.found.length === 0) return;
		root.foundAt = (root.foundAt + by + root.found.length) % root.found.length;
		root.jump(root.found[root.foundAt]);
	}

	// a time of day on a day from now
	function at(days, hour) {
		const date = new Date();
		date.setDate(date.getDate() + days);
		date.setHours(hour, 0, 0, 0);
		return date.getTime();
	}

	function cycle(email) {
		const next = { to: "cc", cc: "bcc", bcc: "to" };
		root.chosen = root.recipients.map(entry => entry.email === email ? Object.assign({}, entry, { kind: next[entry.kind] ?? "to" }) : entry);
	}

	function reset() {
		root.picked = null;
		root.forwarding = false;
		root.chosen = null;
		root.adding = false;
		root.error = "";
		adder.text = "";
	}

	function jump(id) {
		const index = root.byId[id];
		if (index === undefined) return;
		list.positionViewAtIndex(index, ListView.Center);
		root.flashId = id;
		unflash.restart();
	}

	function label(entry) {
		const name = String(entry.name || entry.email);
		return name.length > 24 ? `${name.slice(0, 23)}…` : name;
	}

	function include(email, name) {
		if (root.recipients.some(entry => entry.email === email)) return;
		root.chosen = root.recipients.concat([{ email: email, name: name || Mail.nameOf(email), kind: "to" }]);
	}

	function exclude(email) {
		root.chosen = root.recipients.filter(entry => entry.email !== email);
	}

	// what the field for another recipient holds is taken: addresses, or the first one offered
	function take() {
		const typed = String(adder.text).split(/[\s,;]+/).map(entry => entry.replace(/^<|>$/g, "").toLowerCase()).filter(entry => entry.includes("@"));
		if (typed.length > 0) typed.forEach(email => root.include(email, ""));
		else if (root.offers.length > 0) root.include(root.offers[0].email, root.offers[0].name);
		else return;
		adder.text = "";
	}

	function draft() {
		root.take();
		const of = kind => root.recipients.filter(entry => entry.kind === kind).map(entry => entry.email);
		const direct = of("to");
		return {
			account: root.chat.account,
			mode: root.forwarding ? "forward" : "replyAll",
			reply: root.target.id,
			// someone has to be written to
			to: direct.length > 0 ? direct : of("cc"),
			cc: direct.length > 0 ? of("cc") : [],
			bcc: of("bcc"),
			text: composer.words(),
			html: composer.markup(),
			files: composer.files
		};
	}

	function ready() {
		if (!root.chat || !root.target) return false;
		root.take();
		if (!root.recipients.some(entry => entry.kind !== "bcc")) {
			root.error = "No recipient";
			root.adding = true;
			adder.focusInput();
			return false;
		}
		root.error = "";
		return true;
	}

	// into the outbox: it leaves after a moment in which it can be taken back
	function send() {
		if (!root.ready()) return;
		Mail.post(root.chat.id, root.draft(), composer.written(), composer.words().slice(0, 400));
		preview.close();
		composer.clear();
		root.reset();
		list.stick = true;
		Qt.callLater(list.positionViewAtEnd);
	}

	Connections {
		target: Mail
		function onOpenIdChanged() {
			// what is being written waits in its chat
			if (root.shownId !== "") Mail.keep(root.shownId, composer.written());
			root.shownId = Mail.openId;
			root.reset();
			root.finding = false;
			root.snoozing = false;
			root.withThanks = true;
			root.withClosing = true;
			finder.text = "";
			preview.close();
			composer.restore(Mail.drafts[Mail.openId] ?? null);
			list.stick = true;
			arrive.restart();
		}
		// a mail of this chat was taken back
		function onUndone(key) {
			if (key !== Mail.openId) return;
			composer.restore(Mail.drafts[key] ?? null);
			composer.focusInput();
		}
	}

	Component.onCompleted: {
		root.shownId = Mail.openId;
		if (Mail.openId !== "") composer.restore(Mail.drafts[Mail.openId] ?? null);
	}

	// what is written is kept once the typing rests
	Timer {
		id: keeping

		interval: 700
		onTriggered: if (root.shownId !== "" && root.shownId === Mail.openId) Mail.keep(root.shownId, composer.written())
	}

	Timer {
		id: unflash

		interval: 1400
		onTriggered: root.flashId = ""
	}

	ColumnLayout {
		anchors.fill: parent
		anchors.rightMargin: root.beside ? assistant.width + 12 : 0
		spacing: 10

		Behavior on anchors.rightMargin {
			SpatialAnim {
				duration: Motion.medium
			}
		}

		// who the chat is with
		RowLayout {
			Layout.fillWidth: true
			spacing: 10

			IconButton {
				visible: root.narrow
				icon: "arrow_left"
				variant: "tonal"
				onClicked: root.back()
			}

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

							text: `${modelData.name}${index < Math.min(6, root.chat?.people.length ?? 0) - 1 ? ", " : ""}`
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
				visible: MailAssist.enabled
				icon: "creation"
				iconColor: checked ? Theme.onPrimary : Theme.tertiary
				checked: root.assisting
				onClicked: {
					root.assisting = !root.assisting;
					if (root.assisting) assistant.focusInput();
				}
			}

			IconButton {
				icon: "magnify"
				checked: root.finding
				onClicked: {
					if (root.finding) root.finding = false;
					else root.find();
				}
			}

			// until later, or back from there
			IconButton {
				icon: "bell_sleep_outline"
				checked: root.snoozing || root.snoozed
				onClicked: {
					if (root.snoozed) Mail.wake(root.chat.id, false);
					else root.snoozing = !root.snoozing;
				}
			}

			IconButton {
				icon: root.chat?.flagged ? "star" : "star_outline"
				iconColor: root.chat?.flagged ? Theme.warning : Theme.text
				onClicked: if (root.chat) Mail.setFlag(root.chat.id, !root.chat.flagged)
			}

			IconButton {
				icon: "email_mark_as_unread"
				onClicked: {
					if (!root.chat) return;
					const id = root.chat.id;
					Mail.close();
					Mail.setRead(id, false);
				}
			}

			IconButton {
				icon: "archive_outline"
				onClicked: if (root.chat) Mail.archive(root.chat.id)
			}

			TextButton {
				text: ""
				icon: "delete_outline"
				variant: "danger"
				confirm: true
				confirmText: "Delete chat"
				onActivated: if (root.chat) Mail.remove(root.chat.id)
			}
		}

		Flow {
			Layout.fillWidth: true
			visible: root.snoozing
			spacing: 6

			Repeater {
				model: [
					{ label: "In 3 hours", until: () => Date.now() + 3 * 3600 * 1000 },
					{ label: "Tomorrow", until: () => root.at(1, 8) },
					{ label: "Monday", until: () => root.at(((8 - new Date().getDay()) % 7) || 7, 8) }
				]

				delegate: Chip {
					required property var modelData

					icon: "bell_sleep_outline"
					text: modelData.label
					onClicked: Mail.snooze(root.chat.id, modelData.until())
				}
			}
		}

		RowLayout {
			Layout.fillWidth: true
			visible: root.finding
			spacing: 6

			Field {
				id: finder

				Layout.fillWidth: true
				icon: "magnify"
				placeholder: "Search in chat"
				onAccepted: root.step(-1)
				onUpPressed: root.step(-1)
				onDownPressed: root.step(1)
				onEscapePressed: root.finding = false
			}

			StyledText {
				visible: root.sought.length >= 2
				text: root.found.length > 0 ? `${root.foundAt + 1}/${root.found.length}` : "0"
				tone: Theme.textMuted
				font.pixelSize: Theme.size.label
				tabular: true
			}

			IconButton {
				icon: "chevron_down"
				rotation: 180
				enabled: root.found.length > 1
				onClicked: root.step(-1)
			}

			IconButton {
				icon: "chevron_down"
				enabled: root.found.length > 1
				onClicked: root.step(1)
			}
		}

		// someone here seems to belong to a customer
		Rectangle {
			Layout.fillWidth: true
			visible: root.offer !== null
			implicitHeight: 38
			radius: Theme.radius.medium
			color: Theme.layer1

			RowLayout {
				anchors.fill: parent
				anchors.leftMargin: 12
				anchors.rightMargin: 4
				spacing: 8

				Glyph {
					icon: "office_building"
					size: 15
					color: Theme.primary
				}

				StyledText {
					Layout.fillWidth: true
					text: root.offer ? `Add ${root.offer.person.name} to ${root.offer.customer.name}?` : ""
					elide: Text.ElideRight
					font.pixelSize: Theme.size.label
				}

				IconButton {
					implicitWidth: 30
					implicitHeight: 30
					icon: "check"
					onClicked: Customers.toggle(root.offer.customer.id, root.offer.person.email)
				}

				IconButton {
					implicitWidth: 30
					implicitHeight: 30
					icon: "close"
					onClicked: Customers.decline(root.offer.customer.id, root.offer.person.email)
				}
			}
		}

		Item {
			Layout.fillWidth: true
			Layout.fillHeight: true

			ListView {
				id: list

				// at the newest mail, and staying there as mails load and arrive
				property bool stick: true

				anchors.fill: parent
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

				// another chat comes up from a little below
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
						duration: Motion.long
					}
				}

				add: Transition {
					Anim {
						property: "opacity"
						from: 0
						to: 1
						duration: Motion.medium
					}
				}

				delegate: Bubble {
					required property string modelData
					required property int index

					width: ListView.view.width - 12
					message: Mail.messages[root.byId[modelData]] ?? root.blank
					previous: index > 0 ? (Mail.messages[index - 1] ?? null) : null
					group: root.chat?.group ?? false
					flash: root.flashId === modelData
					picked: (root.picked !== null && root.picked.id === modelData) || (root.finding && root.found[root.foundAt] === modelData)
					onJump: id => root.jump(id)
					onReply: {
						root.forwarding = false;
						root.chosen = null;
						root.adding = false;
						root.picked = message;
						composer.focusInput();
					}
					onForward: {
						root.picked = message;
						root.forwarding = true;
						root.chosen = null;
						root.adding = true;
						adder.focusInput();
					}
				}

				// what was sent from here: waiting to be taken back, on its way, or held up
				footer: Column {
					width: list.width - 12
					topPadding: root.outgoing.length > 0 ? 6 : 0
					spacing: 4

					Repeater {
						model: ScriptModel {
							values: root.outgoing.map(entry => entry.id)
						}

						delegate: Item {
							id: leaving

							required property string modelData
							readonly property var entry: root.outgoing.find(entry => entry.id === leaving.modelData) ?? { id: "", text: "", state: "sent", error: "", at: 0, draft: {} }
							readonly property bool failed: leaving.entry.state === "failed"

							width: list.width - 12
							height: sentBubble.height

							Rectangle {
								id: sentBubble

								anchors.right: parent.right
								width: Math.min(parent.width * 0.74, Math.max(sentText.implicitWidth, status.implicitWidth, 60) + 24)
								height: sentColumn.implicitHeight + 16
								radius: Theme.radius.large
								color: leaving.failed ? Theme.dangerContainer : Theme.primaryContainer
								opacity: leaving.entry.state === "sent" || leaving.failed ? 1 : 0.7

								Behavior on opacity {
									Anim {
										duration: Motion.medium
									}
								}

								Column {
									id: sentColumn

									x: 12
									y: 8
									width: parent.width - 24
									spacing: 6

									StyledText {
										id: sentText

										width: Math.min(implicitWidth, parent.width)
										text: leaving.entry.text || (leaving.entry.draft.files ?? []).map(path => String(path).split("/").pop()).join(", ") || "…"
										wrapMode: Text.Wrap
										maximumLineCount: 6
										elide: Text.ElideRight
										font.pixelSize: Theme.size.body
									}

									StyledText {
										visible: leaving.failed
										width: parent.width
										text: leaving.entry.error
										tone: Theme.danger
										wrapMode: Text.Wrap
										font.pixelSize: Theme.size.small
									}

									Row {
										id: status

										anchors.right: parent.right
										spacing: 4

										// what is left of the moment it can be taken back in
										Rectangle {
											visible: leaving.entry.state === "waiting"
											anchors.verticalCenter: parent.verticalCenter
											width: 48
											height: 3
											radius: 1.5
											color: Qt.alpha(Theme.fg, 0.14)

											Rectangle {
												width: parent.width * Math.max(0, Math.min(1, 1 - (Mail.now - leaving.entry.at) / Mail.grace))
												height: parent.height
												radius: 1.5
												color: Theme.primary
											}
										}

										TextButton {
											visible: leaving.entry.state === "waiting"
											implicitHeight: 26
											text: "Undo"
											icon: "undo"
											variant: "ghost"
											onActivated: Mail.undo(leaving.modelData)
										}

										Spinner {
											visible: leaving.entry.state === "sending"
											anchors.verticalCenter: parent.verticalCenter
											width: 12
											height: 12
											color: Theme.textMuted
										}

										IconButton {
											visible: leaving.failed
											implicitWidth: 28
											implicitHeight: 28
											icon: "refresh"
											onClicked: Mail.dispatch(leaving.modelData)
										}

										// back into the field
										IconButton {
											visible: leaving.failed
											implicitWidth: 28
											implicitHeight: 28
											icon: "pencil"
											onClicked: Mail.undo(leaving.modelData)
										}
									}
								}
							}
						}
					}
				}
			}

			// back to the newest mail
			IconButton {
				readonly property bool wanted: !list.atYEnd && list.contentHeight > list.height

				anchors.right: parent.right
				anchors.bottom: parent.bottom
				anchors.rightMargin: 14
				anchors.bottomMargin: 8
				implicitWidth: 36
				implicitHeight: 36
				icon: "arrow_down"
				color: Theme.layer3
				scale: wanted ? 1 : 0
				visible: scale > 0.01
				onClicked: {
					list.stick = true;
					list.positionViewAtEnd();
				}

				Behavior on scale {
					SpatialAnim {
						duration: Motion.medium
					}
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
			id: quoted

			readonly property bool shown: root.picked !== null

			Layout.fillWidth: true
			Layout.preferredHeight: shown ? 40 : 0
			visible: Layout.preferredHeight > 0.5
			opacity: shown ? 1 : 0
			radius: Theme.radius.medium
			color: Theme.layer1
			clip: true

			Behavior on Layout.preferredHeight {
				SpatialAnim {
					duration: Motion.medium
				}
			}
			Behavior on opacity {
				Anim {
					duration: Motion.short
				}
			}

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
					onClicked: root.reset()
				}
			}
		}

		// what the assistant proposes around the answer; the sentences that are not wanted are unticked
		Rectangle {
			Layout.fillWidth: true
			visible: root.framed !== null || MailAssist.frameError !== ""
			implicitHeight: frameColumn.implicitHeight + 20
			radius: Theme.radius.medium
			color: Qt.tint(Theme.bg, Qt.alpha(Theme.tertiary, 0.08))
			border.width: 1
			border.color: Qt.alpha(Theme.tertiary, 0.45)

			ColumnLayout {
				id: frameColumn

				x: 12
				y: 10
				width: parent.width - 20
				spacing: 4

				StyledText {
					Layout.fillWidth: true
					visible: root.framed === null
					text: MailAssist.frameError
					tone: Theme.danger
					wrapMode: Text.Wrap
					font.pixelSize: Theme.size.small
				}

				RowLayout {
					Layout.fillWidth: true
					visible: root.framed !== null
					spacing: 8

					Glyph {
						Layout.preferredWidth: 22
						icon: "creation"
						size: 15
						color: Theme.tertiary
					}

					StyledText {
						Layout.fillWidth: true
						text: root.framed?.greeting ?? ""
						wrapMode: Text.Wrap
						font.pixelSize: Theme.size.body
					}

					IconButton {
						implicitWidth: 28
						implicitHeight: 28
						icon: "refresh"
						enabled: MailAssist.framing === ""
						onClicked: MailAssist.frame(Mail.openId, root.context())
					}

					IconButton {
						implicitWidth: 28
						implicitHeight: 28
						icon: "close"
						onClicked: MailAssist.framed = null
					}
				}

				Repeater {
					model: root.framed ? [
						{ text: root.framed.thanks, on: root.withThanks, flip: () => root.withThanks = !root.withThanks },
						{ text: root.framed.closing, on: root.withClosing, flip: () => root.withClosing = !root.withClosing }
					].filter(line => line.text !== "") : []

					delegate: RowLayout {
						id: sentence

						required property var modelData

						Layout.fillWidth: true
						spacing: 8

						IconButton {
							implicitWidth: 22
							implicitHeight: 22
							icon: sentence.modelData.on ? "check" : ""
							variant: "tonal"
							checked: sentence.modelData.on
							onClicked: sentence.modelData.flip()
						}

						StyledText {
							Layout.fillWidth: true
							text: sentence.modelData.text
							tone: sentence.modelData.on ? Theme.text : Theme.textSubtle
							wrapMode: Text.Wrap
							font.pixelSize: Theme.size.body
							font.strikeout: !sentence.modelData.on
						}
					}
				}

				TextButton {
					Layout.alignment: Qt.AlignRight
					visible: root.framed !== null
					implicitHeight: 30
					text: "Use"
					icon: "check"
					variant: "filled"
					onActivated: root.applyFrame()
				}
			}
		}

		// who the answer goes to: a click takes someone out, the dimmed ones and the plus put someone in
		Flow {
			Layout.fillWidth: true
			visible: root.target !== null
			spacing: 6

			Item {
				width: 20
				height: 28

				Glyph {
					anchors.centerIn: parent
					icon: root.forwarding ? "share" : "reply"
					size: 15
					color: Theme.textSubtle
				}
			}

			Repeater {
				model: ScriptModel {
					values: root.recipients.map(entry => entry.email)
				}

				delegate: Clickable {
					id: who

					required property string modelData
					readonly property var entry: root.recipients.find(entry => entry.email === who.modelData) ?? { email: who.modelData, name: who.modelData, kind: "to" }

					implicitHeight: 28
					implicitWidth: whoRow.implicitWidth + 16
					radius: 14
					color: Theme.primaryContainer
					// To, Cc, Bcc and round again
					onClicked: root.cycle(who.modelData)

					Row {
						id: whoRow

						x: 11
						anchors.verticalCenter: parent.verticalCenter
						spacing: 5

						StyledText {
							visible: who.entry.kind !== "to"
							anchors.verticalCenter: parent.verticalCenter
							text: who.entry.kind === "cc" ? "Cc" : "Bcc"
							tone: Theme.primary
							font.pixelSize: Theme.size.small
							font.weight: Font.Bold
						}

						StyledText {
							anchors.verticalCenter: parent.verticalCenter
							text: root.label(who.entry)
							font.pixelSize: Theme.size.label
							font.weight: Font.Medium
						}

						IconButton {
							anchors.verticalCenter: parent.verticalCenter
							implicitWidth: 20
							implicitHeight: 20
							icon: "close"
							iconSize: 12
							onClicked: root.exclude(who.modelData)
						}
					}
				}
			}

			Repeater {
				model: ScriptModel {
					values: root.others.map(person => person.email)
				}

				delegate: Chip {
					id: other

					required property string modelData
					readonly property var entry: root.others.find(person => person.email === other.modelData) ?? { email: other.modelData, name: other.modelData }

					implicitHeight: 28
					icon: "plus"
					color: Theme.layer1
					opacity: other.hovered ? 1 : 0.7
					text: root.label(other.entry)
					onClicked: root.include(other.modelData, other.entry.name)
				}
			}

			// only who wrote the mail
			Chip {
				visible: root.chosen === null && !root.forwarding && root.everyone.length > 2 && root.target !== null && !root.target.mine
				implicitHeight: 28
				icon: "account"
				color: Theme.layer1
				text: root.target ? root.label(root.target.from) : ""
				onClicked: root.chosen = root.everyone.slice(0, 1)
			}

			// everyone again
			Chip {
				visible: root.chosen !== null && !root.forwarding
				implicitHeight: 28
				implicitWidth: 34
				icon: "account_multiple"
				color: Theme.layer1
				onClicked: root.chosen = null
			}

			Chip {
				implicitHeight: 28
				implicitWidth: 34
				icon: root.adding ? "close" : "plus"
				selected: root.adding
				onClicked: {
					root.adding = !root.adding;
					adder.text = "";
					if (root.adding) adder.focusInput();
					else composer.focusInput();
				}
			}
		}

		Field {
			id: adder

			Layout.fillWidth: true
			visible: root.adding
			icon: "account"
			placeholder: "To"
			onAccepted: {
				if (adder.text.trim() === "") composer.focusInput();
				else root.take();
			}
		}

		Flow {
			Layout.fillWidth: true
			visible: root.offers.length > 0
			spacing: 6

			Repeater {
				model: root.offers

				delegate: Chip {
					required property var modelData

					icon: "account"
					text: modelData.name === modelData.email ? modelData.email : `${modelData.name} · ${modelData.email}`
					onClicked: {
						root.include(modelData.email, modelData.name);
						adder.text = "";
						adder.focusInput();
					}
				}
			}
		}

		StyledText {
			Layout.fillWidth: true
			visible: root.error !== ""
			text: root.error
			tone: Theme.danger
			wrapMode: Text.Wrap
			font.pixelSize: Theme.size.small
		}

		Composer {
			id: composer

			Layout.fillWidth: true
			allowEmpty: root.forwarding
			placeholder: root.forwarding ? "Add a message" : "Message"
			people: root.recipients
			assist: MailAssist.enabled
			framing: MailAssist.framing !== "" && MailAssist.framing === Mail.openId
			onFrame: if (root.chat && root.target) MailAssist.frame(Mail.openId, root.context())
			onEdited: keeping.restart()
			onSubmit: root.send()
			onPreview: if (root.ready()) preview.show(root.draft())
		}
	}

	DropZone {
		anchors.fill: parent
		enabled: root.chat !== null && !preview.open
		onFiles: paths => {
			composer.add(paths);
			composer.focusInput();
		}
	}

	// the assistant: beside the chat, or over it where the pane is narrow
	AssistPanel {
		id: assistant

		anchors.top: parent.top
		anchors.bottom: parent.bottom
		anchors.right: parent.right
		width: root.width >= 860 ? Math.min(400, root.width * 0.42) : root.width
		chat: Mail.openId
		opacity: root.assisting && MailAssist.enabled ? 1 : 0
		visible: opacity > 0.01
		transform: Translate {
			x: root.assisting ? 0 : 24

			Behavior on x {
				SpatialAnim {
					duration: Motion.medium
				}
			}
		}
		onAsk: text => MailAssist.ask(Mail.openId, root.context(), text)
		onUse: text => {
			composer.fill(text);
			if (!root.beside) root.assisting = false;
		}
		onDone: root.assisting = false

		Behavior on opacity {
			Anim {
				duration: Motion.short
			}
		}
	}

	Shortcut {
		sequence: "Ctrl+F"
		enabled: root.visible && root.chat !== null && Messages.shown
		onActivated: root.find()
	}

	Preview {
		id: preview

		anchors.fill: parent
		onSend: root.send()
	}
}
