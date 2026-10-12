pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.core.services
import qs.style.widgets

// The WhatsApp account. Not linked yet, it shows the QR code the phone scans
// (WhatsApp › Linked devices), as WhatsApp Web does, or gives a code to type
// on the phone instead. Linked, it says who is signed in and unlinks.
Item {
	id: root

	// the view is on the screen
	property bool active: false
	// the codes ran out once: the next ones are asked for
	property bool expired: false
	readonly property bool waiting: WhatsApp.state === "starting" || WhatsApp.state === "connecting" || WhatsApp.state === "building"

	signal done

	// a code was shown since the sign-in began
	property bool shown: false

	function begin() {
		root.expired = false;
		root.shown = false;
		WhatsApp.signIn();
	}

	onActiveChanged: {
		if (root.active && WhatsApp.state === "signedOut" && !root.expired) root.begin();
		else if (!root.active && WhatsApp.state === "qr") {
			WhatsApp.cancelSignIn();
			root.expired = false;
		}
	}

	Connections {
		target: WhatsApp
		function onStateChanged() {
			if (WhatsApp.state === "qr") root.shown = true;
			if (WhatsApp.state !== "signedOut" || !root.active) return;
			// the bridge came up while the view was waiting for it
			if (!root.shown && WhatsApp.error === "" && !once.running) {
				once.start();
				root.begin();
			} else {
				root.expired = true;
			}
		}
	}

	// a sign-in that ends at once is not started over and over
	Timer {
		id: once

		interval: 15000
	}

	ColumnLayout {
		anchors.centerIn: parent
		width: Math.min(360, parent.width - 24)
		spacing: 14

		// ── not linked ─────────────────────────────────────────────────────
		Spinner {
			visible: root.waiting && !WhatsApp.linked
			Layout.alignment: Qt.AlignHCenter
			Layout.preferredWidth: 28
			Layout.preferredHeight: 28
		}

		StyledText {
			visible: WhatsApp.state === "building"
			Layout.alignment: Qt.AlignHCenter
			text: "Building the WhatsApp bridge"
			tone: Theme.textMuted
			font.pixelSize: Theme.size.label
		}

		Rectangle {
			visible: WhatsApp.state === "qr" && WhatsApp.code === ""
			Layout.alignment: Qt.AlignHCenter
			implicitWidth: 264
			implicitHeight: 264
			radius: Theme.radius.large
			color: "white"

			Image {
				anchors.fill: parent
				anchors.margins: 12
				source: WhatsApp.qr !== "" ? `file://${WhatsApp.qr}` : ""
				smooth: false
				cache: false
				fillMode: Image.PreserveAspectFit
			}
		}

		StyledText {
			visible: WhatsApp.state === "qr" && WhatsApp.code !== ""
			Layout.alignment: Qt.AlignHCenter
			text: `${WhatsApp.code.slice(0, 4)}-${WhatsApp.code.slice(4)}`
			font.family: Theme.monoFamily
			font.pixelSize: Theme.size.display
			font.weight: Font.Bold
			font.letterSpacing: 3
		}

		StyledText {
			visible: WhatsApp.state === "qr"
			Layout.alignment: Qt.AlignHCenter
			text: WhatsApp.code !== "" ? "WhatsApp › Linked devices › Link with phone number" : "WhatsApp › Linked devices › Link a device"
			tone: Theme.textMuted
			font.pixelSize: Theme.size.label
		}

		TextButton {
			visible: WhatsApp.state === "signedOut"
			Layout.alignment: Qt.AlignHCenter
			icon: "qrcode"
			text: "Show QR code"
			variant: "filled"
			onActivated: root.begin()
		}

		RowLayout {
			visible: (WhatsApp.state === "signedOut" || WhatsApp.state === "qr") && WhatsApp.code === ""
			Layout.fillWidth: true
			spacing: 6

			Field {
				id: phone

				Layout.fillWidth: true
				icon: "cellphone"
				placeholder: "+49 … link with a code instead"
				onAccepted: if (phone.text.trim() !== "") WhatsApp.pairWith(phone.text)
			}

			IconButton {
				implicitWidth: 40
				implicitHeight: 40
				icon: "check"
				variant: "filled"
				enabled: phone.text.replace(/\D/g, "").length >= 7
				onClicked: WhatsApp.pairWith(phone.text)
			}
		}

		// ── linked ─────────────────────────────────────────────────────────
		WaAvatar {
			visible: WhatsApp.linked
			Layout.alignment: Qt.AlignHCenter
			size: 72
			name: WhatsApp.me?.name ?? ""
			key: WhatsApp.me?.id ?? ""
			picture: WhatsApp.chats.find(chat => chat.id === WhatsApp.me?.id)?.avatar ?? ""
		}

		StyledText {
			visible: WhatsApp.linked
			Layout.alignment: Qt.AlignHCenter
			text: WhatsApp.me?.name || (WhatsApp.me?.phone ?? "")
			font.pixelSize: Theme.size.heading
			font.weight: Font.DemiBold
		}

		RowLayout {
			visible: WhatsApp.linked
			Layout.alignment: Qt.AlignHCenter
			spacing: 6

			Rectangle {
				implicitWidth: 8
				implicitHeight: 8
				radius: 4
				color: WhatsApp.state === "online" ? Theme.success : Theme.warning
			}

			StyledText {
				text: `${WhatsApp.me?.phone ?? ""} · ${WhatsApp.state === "online" ? "connected" : (WhatsApp.state === "connecting" ? "connecting" : "offline")}`
				tone: Theme.textMuted
				font.pixelSize: Theme.size.label
			}
		}

		StyledText {
			visible: WhatsApp.error !== ""
			Layout.fillWidth: true
			text: WhatsApp.error
			tone: Theme.danger
			wrapMode: Text.Wrap
			horizontalAlignment: Text.AlignHCenter
			font.pixelSize: Theme.size.label
		}

		RowLayout {
			visible: WhatsApp.linked
			Layout.fillWidth: true
			spacing: 6

			Field {
				id: key

				Layout.fillWidth: true
				icon: "file_gif_box"
				placeholder: WhatsApp.gifsReady ? "Klipy API key (set)" : "Klipy API key"
				onAccepted: save.clicked(null)
			}

			IconButton {
				implicitWidth: 40
				implicitHeight: 40
				icon: "open_in_new"
				variant: "tonal"
				onClicked: Qt.openUrlExternally("https://partner.klipy.com")
			}

			IconButton {
				id: save

				implicitWidth: 40
				implicitHeight: 40
				icon: "check"
				variant: "filled"
				enabled: key.text.trim() !== ""
				onClicked: {
					if (!enabled) return;
					WhatsApp.command("settings", { key: key.text.trim() });
					key.text = "";
				}
			}
		}

		RowLayout {
			visible: WhatsApp.linked
			Layout.alignment: Qt.AlignHCenter
			spacing: 8

			TextButton {
				text: "Unlink"
				icon: "logout"
				variant: "danger"
				confirm: true
				onActivated: WhatsApp.signOut()
			}

			TextButton {
				text: "Done"
				onActivated: root.done()
			}
		}
	}
}
