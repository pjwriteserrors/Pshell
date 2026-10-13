pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// Notifications (core/services/PhoneApps.qml): the programs that notified
// on this PC, each with a switch for showing them; the apps of the phone
// whose notifications came here, and the programs of the PC whose
// notifications went to the phone, each with a switch of its own.
SettingsPage {
	id: root

	title: "Notifications"
	description: "Who may notify here, and what the phone and this PC tell each other."

	function when(at) {
		const date = new Date(at);
		const today = new Date().toDateString() === date.toDateString();
		return Qt.formatDateTime(date, today ? "HH:mm" : "d MMM, HH:mm");
	}

	SettingCard {
		anchor: "notification-apps"
		title: "On this PC"
		icon: "bell_outline"
		modified: PhoneApps.localMuted.length > 0
		onReset: {
			for (const id of PhoneApps.localMuted.slice()) PhoneApps.setLocalMuted(id, false);
		}

		StyledText {
			Layout.fillWidth: true
			Layout.leftMargin: 12
			visible: PhoneApps.localList.length === 0
			text: "Nothing notified yet"
			tone: Theme.textMuted
		}

		Repeater {
			model: PhoneApps.localList

			delegate: AppRow {
				required property var modelData

				Layout.fillWidth: true
				app: modelData
				side: "local"
			}
		}
	}

	SettingCard {
		visible: Plugins.on("phone") && Plugins.on("phone-notifications")
		anchor: "phone-apps"
		title: "From the phone"
		icon: "cellphone_message"
		modified: PhoneApps.muted.length > 0
		onReset: {
			for (const id of PhoneApps.muted.slice()) PhoneApps.setMuted(id, false);
		}

		StyledText {
			Layout.fillWidth: true
			Layout.leftMargin: 12
			visible: PhoneApps.list.length === 0
			text: "Nothing came from the phone yet"
			tone: Theme.textMuted
		}

		Repeater {
			model: PhoneApps.list

			delegate: AppRow {
				required property var modelData

				Layout.fillWidth: true
				app: modelData
			}
		}
	}

	SettingCard {
		visible: Plugins.on("phone") && Plugins.on("phone-mirror")
		anchor: "phone-pc-apps"
		title: "To the phone"
		icon: "monitor"
		modified: PhoneApps.pcMuted.length > 0
		onReset: {
			for (const id of PhoneApps.pcMuted.slice()) PhoneApps.setPcMuted(id, false);
		}

		StyledText {
			Layout.fillWidth: true
			Layout.leftMargin: 12
			visible: PhoneApps.pcList.length === 0
			text: "Nothing went to the phone yet"
			tone: Theme.textMuted
		}

		Repeater {
			model: PhoneApps.pcList

			delegate: AppRow {
				required property var modelData

				Layout.fillWidth: true
				app: modelData
				side: "pc"
			}
		}
	}

	component AppRow: Rectangle {
		id: row

		property var app: ({})
		// "phone" (from it), "pc" (to it) or "local" (on this PC alone)
		property string side: "phone"

		implicitHeight: 56
		radius: Theme.radius.large
		color: Theme.layer2

		RowLayout {
			anchors.fill: parent
			anchors.leftMargin: 14
			anchors.rightMargin: 10
			spacing: 14

			Rectangle {
				Layout.preferredWidth: 34
				Layout.preferredHeight: 34
				radius: Theme.radius.medium
				color: row.app.muted ? Theme.layer3 : Theme.primarySoft

				Glyph {
					anchors.centerIn: parent
					icon: row.app.muted ? "bell_off_outline" : "bell_outline"
					size: 18
					color: row.app.muted ? Theme.textMuted : Theme.primary
				}
			}

			ColumnLayout {
				Layout.fillWidth: true
				spacing: 1
				opacity: row.app.muted ? 0.55 : 1

				StyledText {
					Layout.fillWidth: true
					text: row.app.name || row.app.id
					font.weight: Font.Medium
					elide: Text.ElideRight
				}

				StyledText {
					Layout.fillWidth: true
					text: row.app.count > 0 ? `${row.app.count} · ${root.when(row.app.last)}` : root.when(row.app.last)
					tone: Theme.textSubtle
					font.pixelSize: Theme.size.small
					elide: Text.ElideRight
				}
			}

			IconButton {
				implicitWidth: 30
				implicitHeight: 30
				iconSize: 16
				icon: "close"
				onClicked: row.side === "local" ? PhoneApps.forgetLocal(row.app.id) : (row.side === "pc" ? PhoneApps.forgetPc(row.app.id) : PhoneApps.forget(row.app.id))
			}

			Toggle {
				checked: !row.app.muted
				onToggled: on => row.side === "local" ? PhoneApps.setLocalMuted(row.app.id, !on) : (row.side === "pc" ? PhoneApps.setPcMuted(row.app.id, !on) : PhoneApps.setMuted(row.app.id, !on))
			}
		}
	}
}
