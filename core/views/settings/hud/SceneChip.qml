import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services
import qs.core.views.settings

// A scene to pick, with its little picture; on: marked (muted), live: the
// game shows it now.
Clickable {
	id: root

	property var scene: ({})
	property bool on: false
	property bool live: false

	implicitHeight: 34
	implicitWidth: row.implicitWidth + 12
	radius: 17
	pressedScale: 0.93
	color: root.on ? Theme.secondary : (root.hovered ? Theme.layer3 : Theme.layer2)
	tint: root.on ? Theme.onPrimary : Theme.text

	Behavior on color {
		ColorAnim {}
	}

	RowLayout {
		id: row

		anchors.verticalCenter: parent.verticalCenter
		x: 4
		spacing: 7

		Item {
			Layout.preferredWidth: 38
			Layout.preferredHeight: 26

			// the picture, round
			RoundClip {
				anchors.fill: parent
				radius: 13

				Rectangle {
					anchors.fill: parent
					color: Theme.layer3
				}

				Image {
					anchors.fill: parent
					source: root.scene.picture ? `file://${root.scene.picture}?${Mouse.hudPictureRev}` : ""
					fillMode: Image.PreserveAspectCrop
					sourceSize.width: 96
					asynchronous: true
					cache: false
				}
			}

			Rectangle {
				anchors.fill: parent
				radius: 13
				color: Qt.alpha(Theme.secondary, 0.65)
				opacity: root.on ? 1 : 0

				Behavior on opacity {
					Anim {}
				}

				Glyph {
					anchors.centerIn: parent
					icon: "volume_off"
					size: 13
					color: Theme.onPrimary
				}
			}
		}

		StyledText {
			text: root.scene.name ?? ""
			font.pixelSize: Theme.size.label
			font.weight: root.on ? Font.DemiBold : Font.Medium
			tone: root.on ? Theme.onPrimary : Theme.text
		}

		Rectangle {
			visible: root.live
			Layout.preferredWidth: 6
			Layout.preferredHeight: 6
			Layout.rightMargin: 6
			radius: 3
			color: root.on ? Theme.onPrimary : Theme.primary
		}

		Item {
			visible: !root.live
			Layout.preferredWidth: 4
		}
	}
}
