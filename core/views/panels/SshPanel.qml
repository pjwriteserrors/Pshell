pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.style.theme
import qs.core.services
import qs.style.widgets

// SSH logins. Saved hosts come first – one click connects in kitty. The add
// form folds out from the plus button.
Drawer {
	id: root

	property bool adding: false

	panelId: "ssh"
	panelWidth: 460
	contentHeight: layout.implicitHeight

	onPanelOpened: {
		root.adding = false;
		Ssh.refresh();
		Qt.callLater(() => search.focusInput());
	}

	Connections {
		target: Ssh
		function onEntriesChanged() {
			if (root.shown && Ssh.entries.length === 0 && !root.adding) {
				root.adding = true;
				Qt.callLater(() => nameField.focusInput());
			}
		}
		function onDraftNameChanged() {
			if (nameField.text !== Ssh.draftName) nameField.text = Ssh.draftName;
		}
		function onDraftPasswordChanged() {
			if (passwordField.text !== Ssh.draftPassword) passwordField.text = Ssh.draftPassword;
		}
		function onDraftKeyPathChanged() {
			if (keyField.text !== Ssh.draftKeyPath) keyField.text = Ssh.draftKeyPath;
		}
	}

	function submit() {
		if (Ssh.canAdd) Ssh.add();
	}

	ColumnLayout {
		id: layout

		anchors.left: parent.left
		anchors.right: parent.right
		spacing: 12

		RowLayout {
			Layout.fillWidth: true
			spacing: 8

			ColumnLayout {
				Layout.fillWidth: true
				spacing: 0

				StyledText {
					text: Words.of("ssh.title", "SSH")
					font.pixelSize: Theme.size.heading
					font.weight: Font.Bold
				}

				StyledText {
					Layout.fillWidth: true
					text: Ssh.statusMessage !== "" ? Ssh.statusMessage : (Ssh.entries.length === 1 ? "1 saved login" : `${Ssh.entries.length} saved logins`)
					tone: Theme.textMuted
					font.pixelSize: Theme.size.small
				}
			}

			IconButton {
				icon: "refresh"
				variant: "tonal"
				onClicked: Ssh.refresh()
			}

			IconButton {
				icon: "plus"
				checked: root.adding
				variant: "tonal"
				rotation: root.adding ? 45 : 0
				onClicked: {
					root.adding = !root.adding;
					if (root.adding) Qt.callLater(() => nameField.focusInput());
				}

				Behavior on rotation {
					SpatialAnim {
						duration: Motion.medium
					}
				}
			}
		}

		// add form
		Item {
			Layout.fillWidth: true
			implicitHeight: root.adding ? form.implicitHeight : 0
			clip: true
			opacity: root.adding ? 1 : 0

			Behavior on implicitHeight {
				SpatialAnim {
					duration: Motion.medium
				}
			}
			Behavior on opacity {
				Anim {}
			}

			Rectangle {
				id: formCard

				width: parent.width
				height: form.implicitHeight
				radius: Theme.radius.huge
				color: Theme.layer1
			}

			ColumnLayout {
				id: form

				width: parent.width
				spacing: 10

				Item {
					implicitHeight: 4
				}

				Segmented {
					Layout.fillWidth: true
					Layout.leftMargin: 14
					Layout.rightMargin: 14
					current: Ssh.draftAuthMode
					options: [
						{ value: "password", label: "Password", icon: "key" },
						{ value: "key", label: "SSH key", icon: "key_variant" }
					]
					onSelected: value => Ssh.draftAuthMode = value
				}

				Field {
					id: nameField

					Layout.fillWidth: true
					Layout.leftMargin: 14
					Layout.rightMargin: 14
					icon: "tag"
					placeholder: "Name (optional)"
					text: Ssh.draftName
					onEdited: text => Ssh.draftName = text
					onAccepted: hostField.focusInput()
				}

				RowLayout {
					Layout.fillWidth: true
					Layout.leftMargin: 14
					Layout.rightMargin: 14
					spacing: 8

					Field {
						id: hostField

						Layout.fillWidth: true
						Layout.preferredWidth: 3
						icon: "web"
						placeholder: "Host"
						text: Ssh.draftHost
						onEdited: text => Ssh.draftHost = text
						onAccepted: userField.focusInput()
					}

					Field {
						id: userField

						Layout.fillWidth: true
						Layout.preferredWidth: 2
						icon: "account"
						placeholder: "User"
						text: Ssh.draftUser
						onEdited: text => Ssh.draftUser = text
						onAccepted: Ssh.draftAuthMode === "key" ? keyField.focusInput() : passwordField.focusInput()
					}
				}

				Field {
					id: passwordField

					Layout.fillWidth: true
					Layout.leftMargin: 14
					Layout.rightMargin: 14
					visible: Ssh.draftAuthMode !== "key"
					icon: "lock"
					password: true
					placeholder: "Password"
					text: Ssh.draftPassword
					onEdited: text => Ssh.draftPassword = text
					onAccepted: root.submit()
				}

				Field {
					id: keyField

					Layout.fillWidth: true
					Layout.leftMargin: 14
					Layout.rightMargin: 14
					visible: Ssh.draftAuthMode === "key"
					icon: "key_variant"
					placeholder: "Private key, e.g. ~/.ssh/id_ed25519"
					text: Ssh.draftKeyPath
					onEdited: text => Ssh.draftKeyPath = text
					onAccepted: root.submit()
				}

				TextButton {
					Layout.fillWidth: true
					Layout.leftMargin: 14
					Layout.rightMargin: 14
					implicitHeight: 40
					text: "Save login"
					icon: "content_save"
					variant: "filled"
					enabled: Ssh.canAdd
					busy: Ssh.actionRunning
					onActivated: root.submit()
				}

				Item {
					implicitHeight: 4
				}
			}
		}

		Field {
			id: search

			Layout.fillWidth: true
			visible: Ssh.entries.length > 0
			icon: "magnify"
			placeholder: "Search logins"
			text: Ssh.searchText
			onEdited: text => Ssh.searchText = text
			onAccepted: if (Ssh.filtered.length > 0) Ssh.connect(Ssh.filtered[0].id)
		}

		EmptyState {
			Layout.fillWidth: true
			Layout.topMargin: 8
			Layout.bottomMargin: 8
			visible: Ssh.filtered.length === 0
			icon: "server_network"
			title: Ssh.entries.length === 0 ? "No saved logins" : "No matches"
			subtitle: Ssh.entries.length === 0 ? "Add a host with the plus button." : ""
		}

		ListView {
			Layout.fillWidth: true
			Layout.preferredHeight: Math.min(contentHeight, 320)
			visible: Ssh.filtered.length > 0
			clip: true
			spacing: 2
			model: Ssh.filtered
			boundsBehavior: Flickable.StopAtBounds
			ScrollBar.vertical: ThinScrollBar {}

			delegate: ListItem {
				id: login

				required property var modelData
				readonly property string display: String(login.modelData.display_name || login.modelData.name || login.modelData.target || `${login.modelData.user}@${login.modelData.host}`)
				readonly property bool usesKey: String(login.modelData.auth_type || "password") === "key"

				width: ListView.view.width
				title: login.display
				subtitle: String(login.modelData.target || `${login.modelData.user}@${login.modelData.host}`)
				onClicked: Ssh.connect(String(login.modelData.id || ""))
				leading: Component {
					Item {
						StyledText {
							anchors.centerIn: parent
							text: login.display.charAt(0).toUpperCase()
							font.weight: Font.Bold
							tone: Theme.primary
						}
					}
				}

				Rectangle {
					Layout.preferredHeight: 22
					Layout.preferredWidth: authLabel.implicitWidth + 16
					radius: 11
					color: Theme.layer2

					StyledText {
						id: authLabel
						anchors.centerIn: parent
						text: login.usesKey ? "key" : "password"
						tone: Theme.textMuted
						font.pixelSize: Theme.size.tiny
						font.weight: Font.Bold
					}
				}

				TextButton {
					implicitHeight: 30
					visible: !login.usesKey
					text: ""
					icon: "content_copy"
					variant: "ghost"
					opacity: login.hovered ? 1 : 0
					onActivated: Ssh.copyPassword(String(login.modelData.id || ""))

					Behavior on opacity {
						Anim {
							duration: Motion.short
						}
					}
				}

				TextButton {
					implicitHeight: 30
					text: ""
					icon: "delete_outline"
					variant: "danger"
					confirm: true
					confirmText: "Delete"
					opacity: login.hovered || armed ? 1 : 0
					onActivated: Ssh.remove(String(login.modelData.id || ""))

					Behavior on opacity {
						Anim {
							duration: Motion.short
						}
					}
				}

				Glyph {
					icon: "console"
					size: 18
					color: login.hovered ? Theme.primary : Theme.textSubtle
				}
			}
		}
	}
}
