import QtQuick
import qs.style.theme

// Which parts of the torrent are there: up to 160 strips, each as full as
// the share of its pieces that arrived.
Rectangle {
	id: root

	property var pieces: []
	property color accent: Theme.primary

	implicitHeight: 10
	radius: 3
	color: Theme.layer3
	clip: true

	Row {
		anchors.fill: parent

		Repeater {
			model: root.pieces.length

			Rectangle {
				required property int index

				width: root.width / Math.max(1, root.pieces.length)
				height: root.height
				color: root.accent
				opacity: 0.15 + 0.85 * (root.pieces[index] ?? 0)
				visible: (root.pieces[index] ?? 0) > 0

				Behavior on opacity {
					NumberAnimation {
						duration: 600
					}
				}
			}
		}
	}
}
