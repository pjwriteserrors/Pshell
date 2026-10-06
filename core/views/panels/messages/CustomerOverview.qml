pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.style.theme
import qs.core.services
import qs.style.widgets

// A customer at a glance: how much is going on with it, its people – each to
// be written to – and the chats with them, the unread ones first.
Item {
	id: root

	property string customerId: ""
	readonly property var customer: Customers.find(root.customerId)
	readonly property var people: {
		const known = {};
		for (const entry of Mail.people) known[entry.email] = entry;
		return (root.customer?.people ?? []).map(email => known[email] ?? { email: email, name: email, chats: 0, unread: 0, date: 0 });
	}
	readonly property var chats: {
		const members = root.customer?.people ?? [];
		const theirs = Mail.chats.filter(chat => chat.people.some(entry => members.includes(entry.email)));
		// what is unread comes first, the rest stays newest first
		return theirs.filter(chat => chat.unread > 0).concat(theirs.filter(chat => chat.unread === 0));
	}
	readonly property int unread: root.chats.reduce((sum, chat) => sum + chat.unread, 0)

	signal open(string id)
	signal compose(string recipients)
	signal done

	function stamp(seconds) {
		if (!seconds) return "–";
		const date = new Date(seconds * 1000);
		const now = new Date();
		if (date.toDateString() === now.toDateString()) return Qt.formatTime(date, "HH:mm");
		if (now - date < 6 * 86400 * 1000) return Qt.formatDate(date, "dddd");
		return Qt.formatDate(date, date.getFullYear() === now.getFullYear() ? "d MMM" : "d MMM yy");
	}

	ColumnLayout {
		anchors.fill: parent
		spacing: 12

		RowLayout {
			Layout.fillWidth: true
			spacing: 10

			IconButton {
				icon: "arrow_left"
				variant: "tonal"
				onClicked: root.done()
			}

			StyledText {
				Layout.fillWidth: true
				text: root.customer?.name || "Customer"
				elide: Text.ElideRight
				font.pixelSize: Theme.size.title
				font.weight: Font.Bold
			}

			TextButton {
				visible: root.people.length > 0
				text: "Write to all"
				icon: "email_plus_outline"
				onActivated: root.compose(root.customer.people.join(", "))
			}
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 8

			Repeater {
				model: [
					{ label: "Chats", value: String(root.chats.length) },
					{ label: "Unread", value: String(root.unread) },
					{ label: "Last", value: root.stamp(root.chats.reduce((last, chat) => Math.max(last, chat.date), 0)) }
				]

				delegate: Rectangle {
					id: tile

					required property var modelData

					Layout.fillWidth: true
					implicitHeight: 62
					radius: Theme.radius.large
					color: Theme.layer1

					Column {
						anchors.centerIn: parent
						spacing: 2

						StyledText {
							anchors.horizontalCenter: parent.horizontalCenter
							text: tile.modelData.value
							font.pixelSize: Theme.size.heading
							font.weight: Font.Bold
							tabular: true
						}

						StyledText {
							anchors.horizontalCenter: parent.horizontalCenter
							text: tile.modelData.label
							tone: Theme.textSubtle
							font.pixelSize: Theme.size.small
						}
					}
				}
			}
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
				values: root.chats.map(chat => chat.id)
			}

			header: Column {
				width: list.width
				spacing: 2
				bottomPadding: 10

				Repeater {
					model: ScriptModel {
						values: root.people.map(entry => entry.email)
					}

					delegate: Clickable {
						id: member

						required property string modelData
						readonly property var who: root.people.find(entry => entry.email === member.modelData) ?? { email: member.modelData, name: member.modelData, chats: 0, unread: 0, date: 0 }

						width: list.width
						implicitHeight: 48
						radius: Theme.radius.medium
						pressedScale: 0.98
						showHover: false
						color: member.hovered ? Theme.layer1 : "transparent"
						onClicked: root.compose(member.modelData)

						RowLayout {
							anchors.fill: parent
							anchors.leftMargin: 10
							anchors.rightMargin: 12
							spacing: 10

							Avatar {
								size: 32
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
									font.pixelSize: Theme.size.body
									font.weight: Font.DemiBold
								}

								StyledText {
									Layout.fillWidth: true
									text: member.who.email
									tone: Theme.textMuted
									elide: Text.ElideRight
									font.pixelSize: Theme.size.small
								}
							}

							Badge {
								count: member.who.unread ?? 0
							}

							StyledText {
								text: root.stamp(member.who.date ?? 0)
								tone: Theme.textSubtle
								font.pixelSize: Theme.size.small
							}

							Glyph {
								icon: "email_plus_outline"
								size: 16
								color: member.hovered ? Theme.primary : Theme.textSubtle
							}
						}
					}
				}
			}

			delegate: Clickable {
				id: item

				required property string modelData
				readonly property var chat: root.chats.find(chat => chat.id === item.modelData) ?? null
				readonly property bool fresh: (item.chat?.unread ?? 0) > 0

				width: ListView.view.width
				implicitHeight: 52
				radius: Theme.radius.medium
				pressedScale: 0.98
				showHover: false
				color: item.hovered ? Theme.layer1 : "transparent"
				onClicked: root.open(item.modelData)

				RowLayout {
					anchors.fill: parent
					anchors.leftMargin: 10
					anchors.rightMargin: 12
					spacing: 10

					ChatAvatar {
						people: item.chat?.people ?? []
						size: 32
						surface: item.hovered ? Theme.layer1 : Theme.base
					}

					ColumnLayout {
						Layout.fillWidth: true
						spacing: 1

						StyledText {
							Layout.fillWidth: true
							text: item.chat?.subject ?? ""
							elide: Text.ElideRight
							font.pixelSize: Theme.size.body
							font.weight: item.fresh ? Font.Bold : Font.DemiBold
						}

						StyledText {
							Layout.fillWidth: true
							text: item.chat?.preview ?? ""
							tone: item.fresh ? Theme.text : Theme.textMuted
							elide: Text.ElideRight
							font.pixelSize: Theme.size.small
						}
					}

					Badge {
						count: item.chat?.unread ?? 0
					}

					StyledText {
						text: item.chat ? root.stamp(item.chat.date) : ""
						tone: item.fresh ? Theme.primary : Theme.textSubtle
						font.pixelSize: Theme.size.small
					}
				}
			}
		}
	}
}
