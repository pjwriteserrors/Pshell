import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.core.services
import qs.style.widgets

// One thing a profile holds, named, with a button that copies it (a click
// anywhere on it does too). A mailbox or number that is no longer there is
// struck through, with a button for a new one instead.
Clickable {
	id: root

	property string label: ""
	property string value: ""
	property bool pending: false
	property bool mono: false
	// it can be replaced (mailbox, number): `gone` says the old one is lost
	property bool renewable: false
	property bool gone: false
	property bool renewing: false
	property bool copied: false
	signal renew

	readonly property bool lost: root.renewable && !root.pending && (root.gone || root.value === "")

	implicitHeight: 50
	radius: Theme.radius.medium
	pressedScale: 0.98
	interactive: !root.lost && !root.pending && root.value !== ""
	color: root.lost ? Qt.alpha(Theme.danger, 0.1) : (root.hovered ? Theme.layer2 : Theme.layer1)

	onClicked: root.copy()

	function copy() {
		Identities.copy(root.value);
		root.copied = true;
		forget.restart();
	}

	Timer {
		id: forget

		interval: 1300
		onTriggered: root.copied = false
	}

	RowLayout {
		anchors.fill: parent
		anchors.leftMargin: 12
		anchors.rightMargin: 6
		spacing: 6

		ColumnLayout {
			Layout.fillWidth: true
			spacing: 3

			RowLayout {
				spacing: 4

				Glyph {
					visible: root.lost
					icon: "alert_outline"
					size: 11
					color: Theme.danger
				}

				SectionLabel {
					text: root.label
					tone: root.lost ? Theme.danger : Theme.textSubtle
					font.letterSpacing: 0.8
				}
			}

			Reveal {
				Layout.fillWidth: true
				text: root.value
				pending: root.pending
				placeholder: 90
				tone: root.lost ? Theme.textSubtle : Theme.text
				font.family: root.mono ? Theme.monoFamily : Theme.fontFamily
				font.weight: Font.Medium
				font.strikeout: root.lost && root.value !== ""
			}
		}

		IconButton {
			visible: !root.lost
			implicitWidth: 28
			implicitHeight: 28
			icon: root.copied ? "check" : "content_copy"
			iconSize: 14
			iconColor: root.copied ? Theme.success : Theme.textMuted
			enabled: root.interactive
			onClicked: root.copy()
		}

		TextButton {
			visible: root.lost
			implicitHeight: 30
			text: "New"
			icon: "refresh"
			variant: "danger"
			busy: root.renewing
			enabled: root.renewing || !Identities.renewBusy
			onActivated: root.renew()
		}
	}
}
