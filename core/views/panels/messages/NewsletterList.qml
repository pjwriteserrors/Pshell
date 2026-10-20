pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.style.theme
import qs.core.services
import qs.style.widgets

// The newsletters of the private mailboxes, who sends most first. The ones
// that are ticked are left with the button below; who was left is the
// second list, from where a sender is taken back.
ColumnLayout {
	id: root

	// "senders" | "left"
	property string mode: "senders"
	property string query: ""
	// { id: true } of the senders that are ticked
	property var ticked: ({})
	readonly property string needle: root.query.trim().toLowerCase()
	readonly property var entries: root.mode === "left" ? Newsletters.left : Newsletters.senders
	readonly property var byId: {
		const map = {};
		for (const entry of root.entries) map[entry.id] = entry;
		return map;
	}
	readonly property var shown: root.entries.filter(entry => root.needle === "" || entry.name.toLowerCase().includes(root.needle)
		|| entry.domain.includes(root.needle) || String(entry.subject ?? "").toLowerCase().includes(root.needle)).map(entry => entry.id)
	// what is ticked and still on the list
	readonly property var picked: Newsletters.senders.filter(sender => root.ticked[sender.id] === true).map(sender => sender.id)
	readonly property bool busy: Newsletters.working.length > 0

	// the surface came up
	function entered() {
		Newsletters.load();
	}

	function tick(id) {
		const next = Object.assign({}, root.ticked);
		if (next[id]) delete next[id];
		else next[id] = true;
		root.ticked = next;
	}

	// every sender that is shown, or none of them once all are ticked
	function tickAll() {
		const all = root.shown.every(id => root.ticked[id] === true);
		const next = Object.assign({}, root.ticked);
		for (const id of root.shown) {
			if (all) delete next[id];
			else next[id] = true;
		}
		root.ticked = next;
	}

	function how(entry) {
		if (entry.status === "needs-you") return "Confirm in the browser";
		return { "one-click": "One click", "email": "By mail", "page": "On its page" }[entry.method] ?? "";
	}

	spacing: 8

	Segmented {
		Layout.fillWidth: true
		implicitHeight: 34
		current: root.mode
		options: [
			{ value: "senders", label: Newsletters.senders.length > 0 ? `Subscribed  ${Newsletters.senders.length}` : "Subscribed" },
			{ value: "left", label: Newsletters.left.length > 0 ? `Unsubscribed  ${Newsletters.left.length}` : "Unsubscribed" }
		]
		onSelected: value => root.mode = value
	}

	RowLayout {
		Layout.fillWidth: true
		spacing: 6

		Field {
			id: search

			Layout.fillWidth: true
			icon: "magnify"
			placeholder: "Search"
			onEdited: text => root.query = text
		}

		Spinner {
			visible: Newsletters.scanning
			Layout.preferredWidth: 16
			Layout.preferredHeight: 16
			Layout.leftMargin: 9
			Layout.rightMargin: 9
		}

		IconButton {
			visible: !Newsletters.scanning
			icon: "refresh"
			variant: "tonal"
			enabled: !root.busy
			onClicked: Newsletters.scan()
		}
	}

	Item {
		Layout.fillWidth: true
		Layout.fillHeight: true

		EmptyState {
			anchors.centerIn: parent
			visible: root.shown.length === 0 && !(Newsletters.scanning && root.mode === "senders")
			icon: root.mode === "left" ? "email_open_outline" : "newspaper_variant_outline"
			title: root.needle !== "" ? "Nothing found" : (root.mode === "left" ? "Nothing unsubscribed" : "No newsletters")
		}

		ListView {
			id: list

			anchors.fill: parent
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
			displaced: Transition {
				SpatialAnim {
					property: "y"
					duration: Motion.medium
				}
			}

			delegate: Clickable {
				id: row

				required property string modelData
				readonly property var entry: root.byId[row.modelData] ?? ({})
				readonly property bool gone: root.mode === "left"
				readonly property bool on: root.ticked[row.modelData] === true
				readonly property bool leaving: Newsletters.working.includes(row.modelData)
				readonly property string mailbox: {
					const account = Newsletters.accounts.length > 1 ? Mail.account(row.entry.account ?? "") : null;
					return account ? `${Mail.label(account)} · ` : "";
				}

				width: ListView.view.width
				implicitHeight: 54
				radius: Theme.radius.medium
				pressedScale: 0.99
				showHover: false
				interactive: !row.gone && !root.busy
				color: row.on && !row.gone ? Theme.primaryContainer : (row.hovered ? Theme.layer1 : "transparent")
				onClicked: root.tick(row.modelData)

				RowLayout {
					anchors.fill: parent
					anchors.leftMargin: 12
					anchors.rightMargin: 10
					spacing: 12

					Glyph {
						visible: !row.gone && !row.leaving
						icon: row.on ? "checkbox_marked" : "checkbox_blank_outline"
						size: 19
						color: row.on ? Theme.primary : Theme.textSubtle
					}

					Spinner {
						visible: row.leaving
						Layout.preferredWidth: 17
						Layout.preferredHeight: 17
						Layout.leftMargin: 1
						Layout.rightMargin: 1
					}

					Avatar {
						size: 34
						name: row.entry.name ?? ""
						email: `news@${row.entry.domain ?? ""}`
					}

					ColumnLayout {
						Layout.fillWidth: true
						spacing: 0

						RowLayout {
							Layout.fillWidth: true
							spacing: 8

							StyledText {
								Layout.maximumWidth: Math.max(80, row.width * 0.5)
								text: row.entry.name ?? ""
								elide: Text.ElideRight
								font.pixelSize: Theme.size.body
								font.weight: Font.DemiBold
							}

							StyledText {
								Layout.fillWidth: true
								text: row.mailbox + (row.entry.domain ?? "")
								tone: Theme.textSubtle
								elide: Text.ElideRight
								font.pixelSize: Theme.size.small
							}
						}

						StyledText {
							Layout.fillWidth: true
							text: row.gone ? root.how(row.entry) : (row.entry.subject ?? "")
							tone: row.entry.status === "needs-you" ? Theme.danger : Theme.textMuted
							elide: Text.ElideRight
							font.pixelSize: Theme.size.small
						}
					}

					ColumnLayout {
						visible: !row.gone
						spacing: 0

						StyledText {
							Layout.alignment: Qt.AlignRight
							text: String(row.entry.count ?? "")
							font.pixelSize: Theme.size.body
							font.weight: Font.DemiBold
						}

						StyledText {
							Layout.alignment: Qt.AlignRight
							text: row.entry.last > 0 ? Format.day(row.entry.last) : ""
							tone: Theme.textSubtle
							font.pixelSize: Theme.size.small
						}
					}

					TextButton {
						visible: row.gone && row.entry.status === "needs-you"
						icon: "open_in_new"
						text: "Open page"
						variant: "filled"
						onActivated: Newsletters.openPage(row.modelData)
					}

					TextButton {
						visible: row.gone
						icon: "undo"
						text: row.entry.status === "needs-you" ? "Back to list" : "Resubscribe"
						onActivated: Newsletters.resubscribe(row.modelData)
					}
				}
			}
		}
	}

	// a mailbox that could not be looked at, in words
	StyledText {
		Layout.fillWidth: true
		visible: Newsletters.error !== ""
		text: Newsletters.error
		tone: Theme.danger
		wrapMode: Text.Wrap
		maximumLineCount: 2
		elide: Text.ElideRight
		font.pixelSize: Theme.size.small
	}

	RowLayout {
		Layout.fillWidth: true
		visible: root.mode === "senders" && Newsletters.senders.length > 0
		spacing: 8

		IconButton {
			icon: "select_all"
			variant: "tonal"
			enabled: !root.busy && root.shown.length > 0
			onClicked: root.tickAll()
		}

		Item {
			Layout.fillWidth: true
		}

		TextButton {
			icon: "email_open_outline"
			text: root.busy ? `Unsubscribing  ${Newsletters.working.length}` : (root.picked.length > 0 ? `Unsubscribe  ${root.picked.length}` : "Unsubscribe")
			variant: "filled"
			enabled: root.picked.length > 0 || root.busy
			busy: root.busy
			onActivated: {
				Newsletters.unsubscribe(root.picked);
				root.ticked = {};
			}
		}
	}
}
