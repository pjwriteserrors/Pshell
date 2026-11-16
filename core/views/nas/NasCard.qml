import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// The NAS in the control centre: how full it is, how it is reached, what
// goes over and what the PC computes for it, the last backup; a click opens
// it in Files, the buttons sync, back up and open its settings. Files
// dropped on it go to the NAS.
Clickable {
	id: root

	signal done

	implicitHeight: column.implicitHeight + 24
	radius: Theme.radius.large
	color: Theme.layer1
	pressedScale: 0.98
	onClicked: {
		root.done();
		if (Nas.mounted && Plugins.on("filemanager")) Files.open(Nas.mountPath);
		else Nas.openSettings();
	}

	ColumnLayout {
		id: column

		x: 14
		y: 12
		width: parent.width - 28
		spacing: 8

		RowLayout {
			Layout.fillWidth: true
			spacing: 12

			Ring {
				Layout.preferredWidth: 44
				Layout.preferredHeight: 44
				value: Nas.online ? Math.max(0, Nas.transferring && Nas.jobProgress >= 0 ? Nas.jobProgress : Nas.fill) : 0
				thickness: 5
				sweep: 270
				color: !Nas.online ? Theme.textFaint : (Nas.fill > 0.9 ? Theme.warning : Theme.primary)

				Glyph {
					anchors.centerIn: parent
					icon: Nas.transferring ? "cloud_upload" : (Nas.computing ? "chip" : "server_network")
					size: 16
					color: Nas.online ? Theme.text : Theme.textSubtle
				}
			}

			ColumnLayout {
				Layout.fillWidth: true
				spacing: 1

				StyledText {
					Layout.fillWidth: true
					text: Nas.online && Nas.total > 0 ? `NAS · ${Format.bytes(Nas.free)} free` : `NAS · ${Nas.summary}`
					font.weight: Font.DemiBold
					elide: Text.ElideRight
				}

				StyledText {
					Layout.fillWidth: true
					text: {
						if (!Nas.online) return Nas.configured ? "Neither at home nor over the VPN" : "Pshell settings › NAS";
						const parts = [Nas.viaText];
						if (Nas.activeJobs.length > 0) parts.push(`${Nas.activeJobs.length} ${Nas.activeJobs.length === 1 ? "transfer" : "transfers"}`);
						if (Nas.computing) parts.push(`computing ${Nas.current.length}`);
						if (Plugins.on("nas-backup")) parts.push(Nas.backup.running ? "backing up" : (Nas.backupLast > 0 ? `backup ${Format.ago(Nas.backupLast * 1000)} ago` : "no backup yet"));
						return parts.filter(p => p).join(" · ");
					}
					tone: Nas.online && !Nas.backupOk ? Theme.warning : Theme.textMuted
					font.pixelSize: Theme.size.small
					elide: Text.ElideRight
				}
			}

			IconButton {
				visible: Nas.online && Plugins.on("nas-sync")
				implicitWidth: 32
				implicitHeight: 32
				icon: "folder_sync_outline"
				onClicked: Nas.syncNow("")
			}

			IconButton {
				visible: Nas.online && Plugins.on("nas-backup")
				implicitWidth: 32
				implicitHeight: 32
				icon: "backup_restore"
				onClicked: Nas.backupNow("")
			}

			IconButton {
				implicitWidth: 32
				implicitHeight: 32
				icon: "cog_outline"
				onClicked: {
					root.done();
					Nas.openSettings();
				}
			}
		}

		Repeater {
			model: Nas.warnings.slice(0, 2)

			delegate: StyledText {
				required property var modelData

				Layout.fillWidth: true
				text: `⚠ ${modelData}`
				tone: Theme.warning
				font.pixelSize: Theme.size.small
				elide: Text.ElideRight
			}
		}
	}

	DropArea {
		id: drop

		anchors.fill: parent
		enabled: Nas.online
		keys: ["text/uri-list"]
		onDropped: event => {
			if (Nas.sendDrop(event) > 0) event.accept(Qt.CopyAction);
		}

		Rectangle {
			anchors.fill: parent
			radius: root.radius
			color: Qt.alpha(Theme.base, 0.86)
			border.width: 2
			border.color: Theme.primary
			opacity: drop.containsDrag ? 1 : 0
			visible: opacity > 0.01

			Behavior on opacity {
				Anim {}
			}

			Glyph {
				anchors.centerIn: parent
				icon: "cloud_upload"
				size: 30
				color: Theme.primary
			}
		}
	}
}
