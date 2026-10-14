import QtQuick
import qs.style.theme
import qs.core.services
import qs.style.widgets

// Asks the ACE again what it holds – after a spool was changed. The arrows
// turn until it answers; then it says when.
Clickable {
	id: root

	readonly property bool busy: Printer.aceSyncing
	// "12:03" a moment ago, nothing before the first answer
	readonly property string when: Printer.aceSyncedAt > 0 ? Qt.formatTime(new Date(Printer.aceSyncedAt), "HH:mm") : ""

	implicitWidth: row.implicitWidth + 18
	implicitHeight: 26
	radius: 13
	color: root.busy ? Theme.primarySoft : Theme.layer2
	interactive: Printer.online && !root.busy
	opacity: Printer.online ? 1 : 0.5
	onClicked: Printer.syncAce()

	Behavior on color {
		ColorAnim {}
	}

	Row {
		id: row

		anchors.centerIn: parent
		spacing: 5

		Glyph {
			id: arrows

			anchors.verticalCenter: parent.verticalCenter
			icon: "sync"
			size: 13
			color: root.busy ? Theme.primary : Theme.textMuted
			animated: false

			RotationAnimation on rotation {
				running: root.busy
				from: 0
				to: -360
				duration: 900
				loops: Animation.Infinite
				onRunningChanged: if (!running) arrows.rotation = 0
			}
		}

		StyledText {
			anchors.verticalCenter: parent.verticalCenter
			text: root.busy ? "Syncing…" : (root.when !== "" ? `Sync ACE · ${root.when}` : "Sync ACE")
			font.pixelSize: Theme.size.small
			tone: root.busy ? Theme.primary : Theme.text
		}
	}
}
