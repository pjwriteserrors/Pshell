pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.core.services
import qs.style.widgets
import qs.core.views.watches
import qs.core.views.messages

// What pshell-core watches (Watches.qml): parcels until delivered (each a
// card with its stages), parts of
// pages, wishes with their prices and whom they are for. The tune page holds
// the 17TRACK key (UPS, GLS, Hermes and other carriers).
Drawer {
	id: root

	function trackNumber() {
		const text = number.text.trim().replace(/\s+/g, "");
		if (text === "") return;
		Watches.track({ number: text });
		number.text = "";
	}

	panelId: "watches"
	panelWidth: 560
	centered: true
	contentHeight: layout.implicitHeight

	property bool keysPage: false
	property string forId: ""

	onPanelOpened: {
		root.keysPage = false;
		Watches.load();
	}

	Component {
		id: watchRow

		ListItem {
			id: row

			required property var modelData

			Layout.fillWidth: true
			icon: Watches.glyph(row.modelData)
			selected: Watches.focusId === row.modelData.id
			accent: row.modelData.state === "problem" || row.modelData.status === "error" || row.modelData.status === "blocked" || row.modelData.status === "missing" ? Theme.warning : Theme.primary
			title: Watches.title(row.modelData)
			subtitle: Watches.line(row.modelData)
			opacity: row.modelData.paused || row.modelData.done ? 0.55 : 1

			IconButton {
				implicitWidth: 30
				implicitHeight: 30
				icon: "refresh"
				onClicked: Watches.check(row.modelData.id)
			}

			IconButton {
				implicitWidth: 30
				implicitHeight: 30
				icon: "open_in_new"
				onClicked: Watches.open(row.modelData)
			}

			IconButton {
				implicitWidth: 30
				implicitHeight: 30
				icon: "delete_outline"
				onClicked: Watches.remove(row.modelData.id)
			}
		}
	}

	PickList {
		id: people

		placeholder: "Person"
		entries: [{ value: "", label: "Nobody", icon: "close" }].concat(Watches.people().map(p => ({ value: p.name, label: p.name, detail: p.birthday ? p.birthday.slice(-5).split("-").reverse().join(".") + "." : "", icon: "account_outline" })))
		onPicked: value => {
			const person = Watches.people().find(p => p.name === value);
			Watches.update(root.forId, { for: person ? { name: person.name, birthday: person.birthday } : null });
		}
	}

	ColumnLayout {
		id: layout

		anchors.left: parent.left
		anchors.right: parent.right
		spacing: 14

		RowLayout {
			Layout.fillWidth: true
			spacing: 10

			StyledText {
				Layout.fillWidth: true
				text: root.keysPage ? "Carriers" : "Watches"
				font.pixelSize: Theme.size.heading
				font.weight: Font.Bold
			}

			Glyph {
				visible: Watches.enabled && !Watches.online
				icon: "cloud_off_outline"
				size: 16
				color: Theme.textMuted
			}

			IconButton {
				implicitWidth: 32
				implicitHeight: 32
				icon: root.keysPage ? "arrow_left" : "tune"
				onClicked: root.keysPage = !root.keysPage
			}
		}

		// ── parcel by number ──────────────────────────────────────────────
		RowLayout {
			Layout.fillWidth: true
			visible: !root.keysPage
			spacing: 10

			Field {
				id: number

				Layout.fillWidth: true
				enabled: Watches.online
				icon: "package_variant_closed"
				placeholder: "Tracking number"
				onAccepted: root.trackNumber()
			}

			TextButton {
				text: "Track"
				icon: "truck_outline"
				variant: "filled"
				enabled: Watches.online && number.text.trim() !== ""
				onActivated: root.trackNumber()
			}
		}

		SectionLabel {
			visible: !root.keysPage && Watches.parcels.length > 0
			text: "Parcels"
		}

		Repeater {
			model: root.keysPage ? [] : Watches.parcels

			delegate: ParcelCard {
				required property var modelData

				Layout.fillWidth: true
				parcel: modelData
				opacity: modelData.done ? 0.6 : 1
			}
		}

		SectionLabel {
			visible: !root.keysPage && Watches.pages.length > 0
			text: "Pages"
		}

		Repeater {
			model: root.keysPage ? [] : Watches.pages

			delegate: watchRow
		}

		SectionLabel {
			visible: !root.keysPage && Watches.wishes.length > 0
			text: "Wishes"
		}

		// own wishes first, then each person's, theirs under their name
		Repeater {
			model: root.keysPage ? [] : Watches.wishGroups

			delegate: ColumnLayout {
				id: group

				required property var modelData

				Layout.fillWidth: true
				spacing: 8

				RowLayout {
					Layout.fillWidth: true
					Layout.topMargin: 4
					visible: group.modelData.name !== ""
					spacing: 10

					WaAvatar {
						name: group.modelData.name
						size: 28
					}

					StyledText {
						text: group.modelData.name
						font.pixelSize: Theme.size.body
						font.weight: Font.DemiBold
					}

					StyledText {
						Layout.fillWidth: true
						text: Watches.birthdayText(group.modelData.birthday)
						font.pixelSize: Theme.size.small
						tone: Watches.birthdayIn(group.modelData.birthday) >= 0 && Watches.birthdayIn(group.modelData.birthday) <= 14 ? Theme.primary : Theme.textSubtle
					}
				}

				Repeater {
					model: group.modelData.wishes

					delegate: WishCard {
						required property var modelData

						Layout.fillWidth: true
						wish: modelData
						onPickPerson: wish => {
							root.forId = wish.id;
							people.current = wish.for?.name ?? "";
							people.open();
						}
					}
				}
			}
		}

		EmptyState {
			Layout.fillWidth: true
			Layout.preferredHeight: 120
			visible: !root.keysPage && Watches.list.length === 0
			icon: "eye_outline"
			title: "Nothing watched"
		}

		// ── carriers ──────────────────────────────────────────────────────
		RowLayout {
			Layout.fillWidth: true
			visible: root.keysPage
			spacing: 10

			Field {
				id: key

				Layout.fillWidth: true
				enabled: Watches.online
				password: true
				icon: "key_outline"
				placeholder: Watches.keys.track17 ? "17TRACK key saved" : "17TRACK key"
				onAccepted: {
					Watches.setTrack17(key.text.trim());
					key.text = "";
				}
			}

			IconButton {
				visible: Watches.keys.track17 === true
				implicitWidth: 32
				implicitHeight: 32
				icon: "delete_outline"
				onClicked: Watches.setTrack17("")
			}
		}
	}
}
