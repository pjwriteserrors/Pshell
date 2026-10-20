pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.style.theme
import qs.core.services
import qs.style.widgets

// Who a WhatsApp chat is with, and how it is set: muted, pinned, archived,
// with messages that disappear. A group shows its people – added, removed and
// made admin by who is admin – its description and its invitation link; a
// person can be blocked.
Item {
	id: root

	readonly property var chat: WhatsApp.openChat
	readonly property var info: WhatsApp.info !== null && WhatsApp.info.id === WhatsApp.openId ? WhatsApp.info : null
	readonly property bool group: root.chat?.group ?? false
	readonly property bool admin: root.info?.admin ?? false
	// "" | "subject" | "description" | "add"
	property string editing: ""

	signal done
	// another chat was picked from here
	signal open(string id)

	function entered() {
		root.editing = "";
		if (WhatsApp.openId !== "") WhatsApp.askInfo(WhatsApp.openId);
	}

	component Row2: RowLayout {
		property string label: ""
		default property alias content: holder.data

		Layout.fillWidth: true
		spacing: 8

		StyledText {
			Layout.fillWidth: true
			text: parent.label
			font.pixelSize: Theme.size.body
		}

		RowLayout {
			id: holder

			spacing: 6
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

			Item {
				Layout.fillWidth: true
			}

			Spinner {
				visible: root.info === null
				Layout.preferredWidth: 16
				Layout.preferredHeight: 16
			}
		}

		Flickable {
			Layout.fillWidth: true
			Layout.fillHeight: true
			clip: true
			contentHeight: body.implicitHeight
			boundsBehavior: Flickable.StopAtBounds
			ScrollBar.vertical: ThinScrollBar {}

			ColumnLayout {
				id: body

				width: Math.min(parent.width - 12, 520)
				x: Math.max(0, (parent.width - 12 - width) / 2)
				spacing: 10

				WaAvatar {
					Layout.alignment: Qt.AlignHCenter
					size: 96
					name: root.chat?.name ?? ""
					key: root.chat?.id ?? ""
					picture: root.chat?.avatar ?? ""
					group: root.group

					MouseArea {
						anchors.fill: parent
						enabled: (root.chat?.avatar ?? "") !== ""
						cursorShape: Qt.PointingHandCursor
						onClicked: Mail.view(root.chat.avatar)
					}
				}

				RowLayout {
					Layout.alignment: Qt.AlignHCenter
					spacing: 6

					StyledText {
						text: String(root.chat?.name ?? "").replace(/^~/, "")
						font.pixelSize: Theme.size.heading
						font.weight: Font.DemiBold
					}

					IconButton {
						visible: root.group && (root.admin || !(root.info?.locked ?? true))
						implicitWidth: 26
						implicitHeight: 26
						icon: "pencil"
						onClicked: {
							root.editing = root.editing === "subject" ? "" : "subject";
							edit.text = root.chat?.name ?? "";
						}
					}
				}

				StyledText {
					visible: text !== ""
					Layout.alignment: Qt.AlignHCenter
					text: root.group ? `${root.info?.people?.length ?? ""} members`.trim() : (root.info?.phone ?? root.chat?.phone ?? "")
					tone: Theme.textMuted
					font.pixelSize: Theme.size.label
				}

				StyledText {
					visible: text !== ""
					Layout.fillWidth: true
					text: root.group ? (root.info?.description ?? "") : (root.info?.about ?? "")
					tone: Theme.textMuted
					wrapMode: Text.Wrap
					horizontalAlignment: Text.AlignHCenter
					font.pixelSize: Theme.size.label
				}

				// a new name, a new description, someone's number
				RowLayout {
					visible: root.editing !== ""
					Layout.fillWidth: true
					spacing: 6

					Field {
						id: edit

						Layout.fillWidth: true
						placeholder: root.editing === "subject" ? "Group name" : (root.editing === "description" ? "Description" : "Name or number")
						onAccepted: confirm.clicked(null)
					}

					IconButton {
						id: confirm

						visible: root.editing !== "add"
						implicitWidth: 40
						implicitHeight: 40
						icon: "check"
						variant: "filled"
						onClicked: {
							WhatsApp.chatDo(root.editing, WhatsApp.openId, { text: edit.text });
							root.editing = "";
						}
					}
				}

				// who can be added
				Repeater {
					model: root.editing !== "add" || edit.text.trim().length < 2 ? [] : WhatsApp.contacts.filter(contact =>
						(String(contact.name).toLowerCase().includes(edit.text.trim().toLowerCase()) || contact.phone.includes(edit.text.trim()))
						&& !(root.info?.people ?? []).some(person => person.id === contact.id)).slice(0, 6)

					delegate: ListItem {
						required property var modelData

						Layout.fillWidth: true
						icon: "account_plus"
						title: modelData.name
						subtitle: modelData.phone
						onClicked: {
							WhatsApp.chatDo("group", WhatsApp.openId, { action: "add", people: [modelData.id] });
							root.editing = "";
						}
					}
				}

				Flow {
					Layout.fillWidth: true
					Layout.topMargin: 4
					spacing: 6

					Chip {
						icon: root.chat?.muted ? "bell_off" : "bell_outline"
						text: "Muted"
						selected: root.chat?.muted ?? false
						onClicked: WhatsApp.chatDo("mute", WhatsApp.openId, { seconds: root.chat.muted ? 0 : -1 })
					}

					Chip {
						icon: "pin_outline"
						text: "Pinned"
						selected: root.chat?.pinned ?? false
						onClicked: WhatsApp.chatDo("pin", WhatsApp.openId, { value: !root.chat.pinned })
					}

					Chip {
						icon: "archive_outline"
						text: "Archived"
						selected: root.chat?.archived ?? false
						onClicked: WhatsApp.chatDo("archive", WhatsApp.openId, { value: !root.chat.archived })
					}

					Chip {
						visible: !root.group && root.info !== null && !(root.chat?.self ?? false)
						icon: "block_helper"
						text: "Blocked"
						accent: Theme.danger
						selected: root.info?.blocked ?? false
						onClicked: WhatsApp.chatDo("block", WhatsApp.openId, { value: !root.info.blocked })
					}
				}

				Row2 {
					label: "Disappearing messages"

					Segmented {
						implicitWidth: 250
						options: [{ value: "0", label: "Off" }, { value: "86400", label: "24 h" }, { value: "604800", label: "7 d" }, { value: "7776000", label: "90 d" }]
						current: String(root.chat?.ephemeral ?? 0)
						onSelected: value => WhatsApp.chatDo("ephemeral", WhatsApp.openId, { seconds: Number(value) })
					}
				}

				// ── a group ──────────────────────────────────────────────────
				Flow {
					visible: root.group && root.info !== null
					Layout.fillWidth: true
					spacing: 6

					Chip {
						visible: root.admin || !(root.info?.locked ?? true)
						icon: "pencil"
						text: "Description"
						selected: root.editing === "description"
						onClicked: {
							root.editing = root.editing === "description" ? "" : "description";
							edit.text = root.info?.description ?? "";
						}
					}

					Chip {
						visible: root.admin
						icon: "account_plus"
						text: "Add"
						selected: root.editing === "add"
						onClicked: {
							root.editing = root.editing === "add" ? "" : "add";
							edit.text = "";
							if (WhatsApp.contacts.length === 0) WhatsApp.command("contacts");
							edit.focusInput();
						}
					}

					Chip {
						visible: root.admin
						icon: "link_variant"
						text: "Invitation link"
						onClicked: WhatsApp.chatDo("invite", WhatsApp.openId, { value: false })
					}
				}

				Clickable {
					visible: (root.info?.invite ?? "") !== ""
					Layout.fillWidth: true
					implicitHeight: 40
					radius: Theme.radius.medium
					color: Theme.layer1
					onClicked: Quickshell.execDetached(["wl-copy", "--", root.info.invite])

					RowLayout {
						anchors.fill: parent
						anchors.leftMargin: 12
						anchors.rightMargin: 12
						spacing: 8

						StyledText {
							Layout.fillWidth: true
							text: root.info?.invite ?? ""
							elide: Text.ElideMiddle
							font.pixelSize: Theme.size.label
						}

						Glyph {
							icon: "content_copy"
							size: 15
							color: Theme.textMuted
						}
					}
				}

				SectionLabel {
					visible: root.group && (root.info?.people ?? []).length > 0
					Layout.topMargin: 6
					text: "Members"
				}

				Repeater {
					model: root.group ? (root.info?.people ?? []) : []

					delegate: Clickable {
						id: member

						required property var modelData

						Layout.fillWidth: true
						implicitHeight: 46
						radius: Theme.radius.medium
						pressedScale: 0.99
						showHover: false
						color: member.hovered ? Theme.layer1 : "transparent"
						onClicked: if (!member.modelData.me) root.open(member.modelData.id)

						RowLayout {
							anchors.fill: parent
							anchors.leftMargin: 8
							anchors.rightMargin: 8
							spacing: 10

							WaAvatar {
								size: 32
								name: member.modelData.name
								key: member.modelData.id
								picture: member.modelData.avatar
							}

							StyledText {
								Layout.fillWidth: true
								text: member.modelData.me ? "You" : member.modelData.name
								elide: Text.ElideRight
								font.pixelSize: Theme.size.body
							}

							StyledText {
								visible: member.modelData.admin
								text: "Admin"
								tone: Theme.primary
								font.pixelSize: Theme.size.tiny
								font.weight: Font.DemiBold
							}

							IconButton {
								visible: root.admin && !member.modelData.me && member.hovered
								implicitWidth: 28
								implicitHeight: 28
								icon: member.modelData.admin ? "chevron_down" : "chevron_up"
								onClicked: WhatsApp.chatDo("group", WhatsApp.openId, { action: member.modelData.admin ? "demote" : "promote", people: [member.modelData.id] })
							}

							IconButton {
								visible: root.admin && !member.modelData.me && member.hovered
								implicitWidth: 28
								implicitHeight: 28
								icon: "close"
								variant: "danger"
								onClicked: WhatsApp.chatDo("group", WhatsApp.openId, { action: "remove", people: [member.modelData.id] })
							}
						}
					}
				}

				// ── a person ─────────────────────────────────────────────────
				SectionLabel {
					visible: !root.group && (root.info?.groups ?? []).length > 0
					Layout.topMargin: 6
					text: "Groups in common"
				}

				Repeater {
					model: root.group ? [] : (root.info?.groups ?? [])

					delegate: ListItem {
						required property var modelData

						Layout.fillWidth: true
						icon: "account_group"
						title: modelData.name
						onClicked: root.open(modelData.id)
					}
				}

				RowLayout {
					Layout.alignment: Qt.AlignHCenter
					Layout.topMargin: 10
					Layout.bottomMargin: 10
					spacing: 8

					TextButton {
						visible: root.group
						text: "Leave"
						icon: "exit_to_app"
						variant: "danger"
						confirm: true
						onActivated: WhatsApp.chatDo("leave", WhatsApp.openId)
					}

					TextButton {
						text: "Delete chat"
						icon: "delete_outline"
						variant: "danger"
						confirm: true
						onActivated: {
							const id = WhatsApp.openId;
							WhatsApp.close();
							WhatsApp.chatDo("deleteChat", id);
							root.done();
						}
					}
				}
			}
		}
	}
}
