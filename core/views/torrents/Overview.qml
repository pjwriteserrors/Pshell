import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// All torrents at once, while none is picked: the session's rate over the
// last minutes, what runs and when the last of it is through.
Item {
	id: root

	readonly property var running: Torrents.running
	readonly property var seeding: Torrents.torrents.filter(item => item.phase === "seeding")
	// when everything under way is through: the slowest one
	readonly property real eta: root.running.length > 0 && root.running.every(item => item.eta >= 0) ? Math.max(...root.running.map(item => item.eta)) : -1
	readonly property real remaining: root.running.reduce((sum, item) => sum + Math.max(0, item.size - item.done), 0)

	ColumnLayout {
		anchors.fill: parent
		anchors.margins: 20
		spacing: 14

		StyledText {
			text: root.running.length > 0 ? (root.eta >= 0 ? `Everything done at ${Torrents.finishTime(root.eta)}` : `${root.running.length} downloading`) : (Torrents.torrents.length > 0 ? "Nothing downloading" : "Ready")
			font.pixelSize: Theme.size.heading + 2
			font.weight: Font.DemiBold
		}

		StyledText {
			text: root.running.length > 0 ? `${Torrents.size(root.remaining)} to go${root.eta >= 0 ? ` · ${Torrents.duration(root.eta)}` : ""}` : "Pick a torrent on the left to see it up close"
			font.pixelSize: Theme.size.body
			tone: Theme.textMuted
		}

		Rectangle {
			Layout.fillWidth: true
			Layout.preferredHeight: 280
			radius: Theme.radius.huge
			color: Theme.layer1

			StyledText {
				id: graphTitle

				anchors.left: parent.left
				anchors.top: parent.top
				anchors.margins: 16
				text: "All torrents · last 3 minutes"
				font.pixelSize: Theme.size.small
				tone: Theme.textMuted
			}

			RateGraph {
				anchors.fill: parent
				anchors.margins: 14
				anchors.topMargin: 56
				samples: Torrents.live
			}
		}

		GridLayout {
			Layout.fillWidth: true
			columns: root.width > 640 ? 4 : 2
			columnSpacing: 10
			rowSpacing: 10

			StatTile {
				Layout.fillWidth: true
				icon: "arrow_down_bold"
				label: "Downloading"
				value: `${root.running.length}`
				note: Torrents.rate(Torrents.down)
			}

			StatTile {
				Layout.fillWidth: true
				icon: "arrow_up_bold"
				accent: Torrents.upColor
				label: "Seeding"
				value: `${root.seeding.length}`
				note: Torrents.rate(Torrents.up)
			}

			StatTile {
				Layout.fillWidth: true
				icon: "check_bold"
				accent: Theme.success
				label: "Complete"
				value: `${Torrents.torrents.filter(item => item.finished > 0).length}`
				note: Torrents.size(Torrents.torrents.filter(item => item.finished > 0).reduce((sum, item) => sum + Math.max(0, item.size), 0))
			}

			StatTile {
				Layout.fillWidth: true
				icon: "swap_vertical"
				accent: Theme.secondary
				label: "Shared"
				value: Torrents.size(Torrents.torrents.reduce((sum, item) => sum + item.uploaded, 0))
				note: `${Torrents.size(Torrents.torrents.reduce((sum, item) => sum + item.downloaded, 0))} received`
			}
		}

		Item {
			Layout.fillHeight: true
		}
	}
}
