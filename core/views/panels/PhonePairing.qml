pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// The phones paired with this PC, and the code to pair another: a QR code
// the app scans. It names this PC's certificate and carries a secret that
// works once, for two minutes.
ColumnLayout {
	id: root

	spacing: 8

	property real now: Date.now()
	readonly property bool pairing: !!Phone.pairing.active
	readonly property int secondsLeft: Math.max(0, Math.round((Number(Phone.pairing.expires || 0) - root.now) / 1000))

	Timer {
		running: root.pairing
		repeat: true
		interval: 1000
		triggeredOnStart: true
		onTriggered: root.now = Date.now()
	}

	SectionLabel {
		text: "Phones"
	}

	StyledText {
		Layout.fillWidth: true
		visible: !Phone.connected
		text: "The phone daemon is not running (systemctl --user start pshell-phone)."
		tone: Theme.textMuted
		font.pixelSize: Theme.size.small
		wrapMode: Text.WordWrap
	}

	Repeater {
		model: Phone.devices

		delegate: ListItem {
			id: device

			required property var modelData

			Layout.fillWidth: true
			icon: device.modelData.connected ? "cellphone" : "cellphone_off"
			title: device.modelData.name
			subtitle: device.modelData.connected ? `Connected · ${device.modelData.address}` : "Not connected"
			selected: device.modelData.connected

			TextButton {
				text: "Remove"
				variant: "ghost"
				confirm: true
				onActivated: Phone.unpair(device.modelData.id)
			}
		}
	}

	Rectangle {
		Layout.fillWidth: true
		visible: root.pairing
		implicitHeight: code.implicitHeight + 28
		radius: Theme.radius.large
		color: Theme.layer1

		ColumnLayout {
			id: code

			x: 14
			y: 14
			width: parent.width - 28
			spacing: 10

			// dark modules on white: what a camera reads best
			Rectangle {
				Layout.alignment: Qt.AlignHCenter
				implicitWidth: 236
				implicitHeight: 236
				radius: Theme.radius.medium
				color: "white"

				Image {
					anchors.fill: parent
					anchors.margins: 8
					// the file is rewritten for every code; the expiry makes the URL new
					source: root.pairing ? `file://${Phone.pairing.qr}?${Phone.pairing.expires}` : ""
					cache: false
					smooth: false
					fillMode: Image.PreserveAspectFit
				}
			}

			StyledText {
				Layout.fillWidth: true
				horizontalAlignment: Text.AlignHCenter
				text: `Scan it with the app · ${root.secondsLeft} s`
				tone: Theme.textMuted
				font.pixelSize: Theme.size.small
			}
		}
	}

	TextButton {
		Layout.fillWidth: true
		enabled: Phone.connected
		icon: root.pairing ? "close" : "qrcode_scan"
		text: root.pairing ? "Cancel" : "Pair a phone"
		onActivated: root.pairing ? Phone.stopPairing() : Phone.startPairing()
	}
}
