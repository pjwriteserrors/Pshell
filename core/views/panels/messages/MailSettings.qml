pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.style.theme
import qs.core.services
import qs.style.widgets

// Mail's settings: whether new mail notifies, the accounts with their
// signature and automatic reply, and adding one – Outlook by Microsoft's
// sign-in, Gmail by app password, anything else by its servers.
ColumnLayout {
	id: root

	// "" | "outlook" | "gmail" | "imap"
	property string adding: Mail.accounts.length === 0 ? "outlook" : ""
	readonly property bool hasOutlook: Mail.accounts.some(account => account.kind === "outlook")
	readonly property var kinds: [
		{ value: "outlook", label: "Outlook", icon: "microsoft_outlook" },
		{ value: "gmail", label: "Gmail", icon: "gmail" },
		{ value: "imap", label: "Other", icon: "email_outline" }
	].filter(kind => kind.value !== "outlook" || !root.hasOutlook)

	signal done

	function icon(kind) {
		return kind === "outlook" ? "microsoft_outlook" : (kind === "gmail" ? "gmail" : "email_outline");
	}

	function add() {
		if (root.adding === "outlook") {
			Mail.addAccount({ kind: "outlook" });
			return;
		}
		const fields = { kind: root.adding, address: address.text.trim(), name: name.text.trim(), password: password.text };
		if (root.adding === "imap") {
			fields.user = user.text.trim();
			fields.imapHost = imapHost.text.trim();
			fields.imapPort = Number(imapPort.text) || 993;
			fields.smtpHost = smtpHost.text.trim();
			fields.smtpPort = Number(smtpPort.text) || 465;
		}
		Mail.addAccount(fields);
	}

	spacing: 12

	Connections {
		target: Mail
		function onAccountAdded(id) {
			root.adding = "";
			password.text = "";
			address.text = "";
		}
	}

	RowLayout {
		Layout.fillWidth: true
		spacing: 8

		IconButton {
			visible: Mail.accounts.length > 0
			icon: "arrow_left"
			variant: "tonal"
			onClicked: root.done()
		}

		StyledText {
			Layout.fillWidth: true
			text: "Mail"
			font.pixelSize: Theme.size.title
			font.weight: Font.Bold
		}

		StyledText {
			text: "Notifications"
			tone: Theme.textMuted
			font.pixelSize: Theme.size.label
		}

		Toggle {
			checked: Plugins.wanted("mail-notifications")
			onToggled: checked => Plugins.set("mail-notifications", checked)
		}
	}

	Flickable {
		Layout.fillWidth: true
		Layout.fillHeight: true
		clip: true
		contentWidth: width
		contentHeight: content.implicitHeight
		boundsBehavior: Flickable.StopAtBounds
		ScrollBar.vertical: ThinScrollBar {}

		ColumnLayout {
			id: content

			width: parent.width - 12
			spacing: 12

			Repeater {
				model: Mail.accounts

				delegate: Rectangle {
					id: card

					required property var modelData
					readonly property var account: card.modelData
					readonly property var reply: card.account.autoReply
					property string signature: card.account.signature
					// a signature with a layout of its own: the one kept, or one just found and not kept yet
					property var found: null
					property bool dropped: false
					// { rich, page }
					readonly property var rich: card.dropped ? null : (card.found ?? card.account.signatureRich ?? null)
					readonly property bool laidOut: !!card.rich && (card.rich.rich !== "" || !!card.rich.page)
					property bool replyOn: card.reply?.enabled ?? false
					property string replyText: card.reply?.text ?? ""

					Layout.fillWidth: true
					implicitHeight: body.implicitHeight + 28
					radius: Theme.radius.large
					color: "transparent"
					border.width: 1
					border.color: Theme.outline

					Connections {
						target: Mail
						function onSignatureFound(account, text, rich) {
							if (account !== card.account.id) return;
							card.signature = text;
							signatureField.text = text;
							card.found = rich.rich !== "" || rich.page ? rich : null;
							card.dropped = false;
						}
					}

					ColumnLayout {
						id: body

						x: 14
						y: 14
						width: parent.width - 28
						spacing: 10

						RowLayout {
							Layout.fillWidth: true
							spacing: 10

							Glyph {
								icon: root.icon(card.account.kind)
								size: 22
								color: Theme.primary
							}

							ColumnLayout {
								Layout.fillWidth: true
								spacing: 0

								StyledText {
									Layout.fillWidth: true
									text: card.account.address || card.account.name
									elide: Text.ElideRight
									font.pixelSize: Theme.size.body
									font.weight: Font.DemiBold
								}

								StyledText {
									Layout.fillWidth: true
									visible: text !== ""
									text: card.account.state === "error" ? card.account.error : (card.account.state === "signedOut" ? "Signed out" : "")
									tone: Theme.danger
									wrapMode: Text.Wrap
									font.pixelSize: Theme.size.small
								}
							}

							Spinner {
								visible: card.account.state === "connecting" || card.account.state === "syncing"
								Layout.preferredWidth: 16
								Layout.preferredHeight: 16
							}

							TextButton {
								visible: card.account.state === "signedOut"
								text: "Sign in"
								icon: "login"
								variant: "filled"
								onActivated: Mail.command("login")
							}

							TextButton {
								text: ""
								icon: "delete_outline"
								variant: "danger"
								confirm: true
								confirmText: "Remove"
								onActivated: Mail.removeAccount(card.account.id)
							}
						}

						SectionLabel {
							text: "Signature"
						}

						AreaField {
							id: signatureField

							Layout.fillWidth: true
							Layout.preferredHeight: 92
							visible: !card.laidOut
							text: card.account.signature
							onEdited: text => card.signature = text
						}

						Sheet {
							Layout.fillWidth: true
							visible: card.laidOut && !!card.rich.page
							page: card.rich?.page ?? null

							IconButton {
								anchors.right: parent.right
								anchors.top: parent.top
								anchors.margins: 6
								implicitWidth: 28
								implicitHeight: 28
								icon: "close"
								iconColor: "#1b1b1b"
								onClicked: card.dropped = true
							}
						}

						Rectangle {
							Layout.fillWidth: true
							visible: card.laidOut && !card.rich.page
							implicitHeight: richSignature.implicitHeight + 24
							radius: Theme.radius.medium
							color: "white"
							clip: true

							Text {
								id: richSignature

								x: 12
								y: 12
								width: parent.width - 24
								textFormat: Text.RichText
								wrapMode: Text.Wrap
								color: "#1b1b1b"
								linkColor: "#0b57d0"
								font.family: Theme.fontFamily
								font.pixelSize: Theme.size.body
								text: card.rich?.rich ?? ""
							}

							IconButton {
								anchors.right: parent.right
								anchors.top: parent.top
								anchors.margins: 6
								implicitWidth: 28
								implicitHeight: 28
								icon: "close"
								iconColor: "#1b1b1b"
								onClicked: card.dropped = true
							}
						}

						RowLayout {
							Layout.fillWidth: true
							spacing: 8

							TextButton {
								text: "From my last mails"
								icon: "history"
								variant: "ghost"
								onActivated: Mail.suggestSignature(card.account.id)
							}

							Item {
								Layout.fillWidth: true
							}

							TextButton {
								text: "Save"
								icon: "check"
								variant: "filled"
								enabled: card.signature !== card.account.signature || card.found !== null || card.dropped
								onActivated: {
									Mail.setSignature(card.account.id, card.signature, card.dropped ? "none" : (card.found !== null ? "found" : ""));
									card.found = null;
									card.dropped = false;
								}
							}
						}

						RowLayout {
							Layout.fillWidth: true
							visible: card.reply?.available ?? false
							spacing: 8

							SectionLabel {
								Layout.fillWidth: true
								text: "Automatic reply"
							}

							Toggle {
								checked: card.replyOn
								onToggled: checked => {
									card.replyOn = checked;
									Mail.setAutoReply(card.account.id, checked, card.replyText);
								}
							}
						}

						AreaField {
							Layout.fillWidth: true
							Layout.preferredHeight: 92
							visible: card.reply?.available ?? false
							autocorrect: true
							text: card.reply?.text ?? ""
							onEdited: text => card.replyText = text
						}

						TextButton {
							Layout.alignment: Qt.AlignRight
							visible: (card.reply?.available ?? false) && card.replyText !== (card.reply?.text ?? "")
							text: "Save"
							icon: "check"
							variant: "filled"
							onActivated: Mail.setAutoReply(card.account.id, card.replyOn, card.replyText)
						}
					}
				}
			}

			TextButton {
				visible: root.adding === "" && root.kinds.length > 0
				text: "Add account"
				icon: "plus"
				onActivated: root.adding = root.kinds[0].value
			}

			// a new account
			Rectangle {
				Layout.fillWidth: true
				visible: root.adding !== ""
				implicitHeight: form.implicitHeight + 28
				radius: Theme.radius.large
				color: "transparent"
				border.width: 1
				border.color: Theme.outline

				ColumnLayout {
					id: form

					x: 14
					y: 14
					width: parent.width - 28
					spacing: 10

					Segmented {
						Layout.fillWidth: true
						current: root.adding
						options: root.kinds
						onSelected: value => {
							root.adding = value;
							Mail.accountError = "";
						}
					}

					// Outlook: Microsoft's sign-in with a code
					StyledText {
						visible: root.adding === "outlook" && Mail.loginCode !== ""
						Layout.alignment: Qt.AlignHCenter
						text: Mail.loginCode
						font.family: Theme.monoFamily
						font.pixelSize: Theme.size.display
						font.weight: Font.Bold
						font.letterSpacing: 3
					}

					Field {
						id: address

						Layout.fillWidth: true
						visible: root.adding !== "outlook"
						icon: "email_outline"
						placeholder: "Address"
						onAccepted: password.focusInput()
					}

					Field {
						id: name

						Layout.fillWidth: true
						visible: root.adding !== "outlook"
						icon: "account"
						placeholder: "Name"
					}

					Field {
						id: password

						Layout.fillWidth: true
						visible: root.adding !== "outlook"
						icon: "key"
						password: true
						placeholder: root.adding === "gmail" ? "App password" : "Password"
						onAccepted: root.add()
					}

					Field {
						id: user

						Layout.fillWidth: true
						visible: root.adding === "imap"
						icon: "login"
						placeholder: address.text.trim() || "User"
					}

					RowLayout {
						Layout.fillWidth: true
						visible: root.adding === "imap"
						spacing: 8

						Field {
							id: imapHost

							Layout.fillWidth: true
							icon: "tray_arrow_down"
							placeholder: `imap.${address.text.split("@")[1] || "example.org"}`
						}

						Field {
							id: imapPort

							Layout.preferredWidth: 90
							clearable: false
							placeholder: "993"
						}
					}

					RowLayout {
						Layout.fillWidth: true
						visible: root.adding === "imap"
						spacing: 8

						Field {
							id: smtpHost

							Layout.fillWidth: true
							icon: "send"
							placeholder: `smtp.${address.text.split("@")[1] || "example.org"}`
						}

						Field {
							id: smtpPort

							Layout.preferredWidth: 90
							clearable: false
							placeholder: "465"
						}
					}

					StyledText {
						Layout.fillWidth: true
						visible: text !== ""
						text: root.adding === "outlook" ? Mail.loginError : Mail.accountError
						tone: Theme.danger
						wrapMode: Text.Wrap
						font.pixelSize: Theme.size.small
					}

					RowLayout {
						Layout.fillWidth: true
						spacing: 8

						Item {
							Layout.fillWidth: true
						}

						TextButton {
							visible: Mail.accounts.length > 0 || Mail.loginCode !== ""
							text: "Cancel"
							variant: "ghost"
							onActivated: {
								if (Mail.loginCode !== "") Mail.cancelSignIn();
								else root.adding = "";
							}
						}

						TextButton {
							visible: root.adding === "outlook" && Mail.loginCode !== ""
							text: "Copy code and open sign-in"
							icon: "open_in_new"
							variant: "filled"
							onActivated: Mail.openSignInPage()
						}

						TextButton {
							visible: !(root.adding === "outlook" && Mail.loginCode !== "")
							text: root.adding === "outlook" ? "Sign in" : "Add"
							icon: root.adding === "outlook" ? "login" : "plus"
							variant: "filled"
							busy: Mail.adding
							enabled: root.adding === "outlook" || (address.text.includes("@") && password.text !== "")
							onActivated: root.add()
						}
					}
				}
			}
		}
	}
}
