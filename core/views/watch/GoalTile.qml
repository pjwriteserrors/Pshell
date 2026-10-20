import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets

// One of the day's goals: a ring that winds up to how far it got (`wind`
// runs 0…1 when the panel opens), the icon in it, the number counting up
// below. A goal reached closes the ring and lights it.
Tile {
	id: root

	property string icon: ""
	property string label: ""
	property real value: 0
	property real goal: 0
	property color tone: Theme.primary
	property real wind: 1

	readonly property real share: root.goal > 0 ? root.value / root.goal : 0
	readonly property bool reached: root.goal > 0 && root.value >= root.goal

	Layout.fillWidth: true
	Layout.preferredWidth: 1
	implicitHeight: 150

	ColumnLayout {
		anchors.centerIn: parent
		spacing: 8

		Item {
			Layout.alignment: Qt.AlignHCenter
			Layout.preferredWidth: 72
			Layout.preferredHeight: 72

			// a glow behind a goal reached
			Rectangle {
				anchors.centerIn: parent
				width: 72
				height: 72
				radius: 36
				color: Qt.alpha(root.tone, 0.16)
				opacity: root.reached ? root.wind : 0
				scale: root.reached ? 1 + 0.12 * root.wind : 0.8
			}

			Ring {
				anchors.fill: parent
				value: Math.min(1, root.share) * root.wind
				thickness: 7
				color: root.tone
				trackColor: Theme.layer2
				animated: false
			}

			Glyph {
				anchors.centerIn: parent
				icon: root.icon
				size: 24
				color: root.tone
			}
		}

		StyledText {
			Layout.alignment: Qt.AlignHCenter
			text: Math.round(root.value * root.wind).toLocaleString(Qt.locale("de_DE"), "f", 0)
			font.pixelSize: Theme.size.title + 2
			font.weight: Font.Bold
			tabular: true
		}

		StyledText {
			Layout.alignment: Qt.AlignHCenter
			text: root.goal > 0 ? `${root.label} · ${Math.round(root.share * 100)} %` : root.label
			tone: Theme.textMuted
			font.pixelSize: Theme.size.small
		}
	}
}
