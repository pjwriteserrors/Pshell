import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// A file of a torrent: whether it is wanted, its name and folder, how much
// of it is there. A complete one opens on a click.
Clickable {
	id: root

	required property var file
	required property string hash
	readonly property bool wanted: root.file.wanted !== false
	readonly property real share: root.file.size > 0 ? Math.min(1, (root.file.done ?? 0) / root.file.size) : 1
	readonly property string name: String(root.file.path).split("/").pop()
	readonly property string folder: String(root.file.path).split("/").slice(1, -1).join("/")

	implicitHeight: 44
	radius: Theme.radius.medium
	sound: ""
	onClicked: if (root.share >= 1) Torrents.openFile(root.hash, root.file.path)

	RowLayout {
		anchors.fill: parent
		anchors.leftMargin: 6
		anchors.rightMargin: 12
		spacing: 10

		// wanted or left out
		IconButton {
			Layout.preferredWidth: 28
			Layout.preferredHeight: 28
			icon: root.wanted ? "checkbox_marked" : "checkbox_blank_outline"
			iconColor: root.wanted ? Theme.primary : Theme.textSubtle
			iconSize: 18
			onClicked: Torrents.setWanted(root.hash, root.file.index, !root.wanted)
		}

		ColumnLayout {
			Layout.fillWidth: true
			spacing: 1

			StyledText {
				Layout.fillWidth: true
				text: root.name
				font.pixelSize: Theme.size.body
				tone: root.wanted ? Theme.text : Theme.textSubtle
				elide: Text.ElideMiddle
			}

			StyledText {
				Layout.fillWidth: true
				visible: root.folder !== ""
				text: root.folder
				font.pixelSize: Theme.size.tiny
				tone: Theme.textSubtle
				elide: Text.ElideMiddle
			}
		}

		Rectangle {
			Layout.preferredWidth: 80
			Layout.preferredHeight: 4
			radius: 2
			color: Theme.layer3
			visible: root.wanted

			Rectangle {
				width: parent.width * root.share
				height: parent.height
				radius: 2
				color: root.share >= 1 ? Theme.success : Theme.primary

				Behavior on width {
					Anim {
						duration: 800
					}
				}
			}
		}

		StyledText {
			Layout.preferredWidth: 70
			horizontalAlignment: Text.AlignRight
			text: Format.bytes(root.file.size)
			font.pixelSize: Theme.size.small
			tone: Theme.textMuted
			tabular: true
		}
	}
}
