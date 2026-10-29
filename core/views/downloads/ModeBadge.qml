import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets

// How a download comes in: accelerated over n connections (the accent, a
// bolt that flickers while it runs), checked by the accelerator, the normal
// way, or a torrent.
Rectangle {
	id: root

	// "boost" | "checking" | "normal" | "torrent"
	property string mode: "normal"
	property string text: ""
	property bool live: false

	readonly property color accent: root.mode === "boost" ? Theme.primary : (root.mode === "torrent" ? Theme.tertiary : (root.mode === "checking" ? Theme.secondary : Theme.textMuted))

	implicitWidth: row.implicitWidth + 16
	implicitHeight: 22
	radius: height / 2
	color: root.mode === "normal" ? Theme.layer2 : Qt.alpha(root.accent, 0.16)
	border.width: root.mode === "boost" ? 1 : 0
	border.color: Qt.alpha(root.accent, 0.35)

	Behavior on color {
		ColorAnim {}
	}
	Behavior on implicitWidth {
		SpatialAnim {
			duration: Motion.medium
		}
	}

	RowLayout {
		id: row

		anchors.centerIn: parent
		spacing: 4

		Spinner {
			visible: root.mode === "checking"
			Layout.preferredWidth: 11
			Layout.preferredHeight: 11
			color: root.accent
		}

		Glyph {
			id: bolt

			visible: root.mode !== "checking"
			icon: ({ boost: "lightning_bolt", torrent: "magnet", normal: "download" })[root.mode] ?? "download"
			size: 12
			color: root.accent

			SequentialAnimation on opacity {
				running: root.live && root.mode === "boost"
				loops: Animation.Infinite
				onRunningChanged: if (!running) bolt.opacity = 1
				NumberAnimation { to: 0.45; duration: 900; easing.type: Easing.InOutSine }
				NumberAnimation { to: 1; duration: 900; easing.type: Easing.InOutSine }
			}
		}

		StyledText {
			text: root.text
			tone: root.accent
			font.pixelSize: Theme.size.small
			font.weight: Font.DemiBold
			tabular: true
		}
	}
}
