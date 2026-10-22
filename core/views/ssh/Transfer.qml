pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.core.services
import qs.style.widgets

// Sending files to a login: this machine on the left, where the files are
// picked, the server on the right, where the open folder is the destination.
ColumnLayout {
	id: root

	readonly property var entry: Ssh.transferEntry
	readonly property string display: root.entry ? String(root.entry.display_name || root.entry.target || "") : ""

	function focusPath() {
		local.focusPath();
	}

	spacing: 12

	RowLayout {
		Layout.fillWidth: true
		spacing: 8

		IconButton {
			icon: "arrow_left"
			variant: "tonal"
			onClicked: Ssh.closeTransfer()
		}

		StyledText {
			Layout.fillWidth: true
			text: root.display
			font.pixelSize: Theme.size.heading
			font.weight: Font.Bold
		}

		IconButton {
			icon: Ssh.showHidden ? "eye" : "eye_off"
			variant: "tonal"
			checked: Ssh.showHidden
			onClicked: Ssh.showHidden = !Ssh.showHidden
		}
	}

	RowLayout {
		Layout.fillWidth: true
		Layout.preferredHeight: 420
		spacing: 12

		FileBrowser {
			id: local

			Layout.fillWidth: true
			Layout.fillHeight: true
			Layout.preferredWidth: 1
			icon: "laptop"
			path: Ssh.localPath
			entries: Ssh.localEntries
			error: Ssh.localError
			loading: Ssh.localLoading
			showHidden: Ssh.showHidden
			picking: true
			picked: Ssh.picked
			onOpened: path => Ssh.browseLocal(path)
			onToggled: path => Ssh.togglePicked(path)
		}

		FileBrowser {
			Layout.fillWidth: true
			Layout.fillHeight: true
			Layout.preferredWidth: 1
			icon: "server"
			path: Ssh.remotePath
			entries: Ssh.remoteEntries
			error: Ssh.remoteError
			loading: Ssh.remoteLoading
			showHidden: Ssh.showHidden
			onOpened: path => Ssh.browseRemote(path)
		}
	}

	RowLayout {
		Layout.fillWidth: true
		spacing: 8

		IconButton {
			visible: Ssh.picked.length > 0
			icon: "close"
			onClicked: Ssh.picked = []
		}

		StyledText {
			Layout.fillWidth: true
			text: Ssh.picked.length > 0 ? Ssh.picked.map(path => Ssh.baseName(path)).join(", ") : Ssh.transferMessage
			tone: Ssh.picked.length === 0 && Ssh.transferFailed ? Theme.danger : Theme.textMuted
			font.pixelSize: Theme.size.small
			elide: Text.ElideMiddle
		}

		TextButton {
			implicitHeight: 40
			text: Ssh.picked.length > 1 ? `Send ${Ssh.picked.length} files` : "Send"
			icon: "upload"
			variant: "filled"
			enabled: Ssh.canSend
			busy: Ssh.sending
			confirm: Ssh.overwrites
			confirmText: "Overwrite"
			onActivated: Ssh.send()
		}
	}
}
