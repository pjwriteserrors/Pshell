import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets

// A provider of Messages as a tab: the one that is looked at spells its
// name, the others are their sign with what is unread on its corner.
Clickable {
	id: tab

	property var provider
	property bool selected: false
	property bool short: false
	readonly property int unread: tab.provider?.unread ?? 0
	Layout.preferredWidth: Math.max(40, content.implicitWidth + 26)
	implicitHeight: 36
	radius: height / 2
	pressedScale: 0.94
	tint: tab.selected ? Theme.onPrimary : Theme.text
	color: tab.selected ? Theme.primary : Theme.layer2

	Row {
		id: content

		anchors.centerIn: parent
		spacing: 0

		Glyph {
			anchors.verticalCenter: parent.verticalCenter
			icon: tab.provider?.icon ?? ""
			size: 16
			color: tab.selected ? Theme.onPrimary : Theme.textMuted
			surface: tab.color
		}

		Item {
			anchors.verticalCenter: parent.verticalCenter
			width: tab.short ? 0 : name.implicitWidth + 7
			height: name.implicitHeight
			clip: true
			opacity: tab.short ? 0 : 1

			Behavior on width {
				SpatialAnim {
					duration: Motion.medium
				}
			}
			Behavior on opacity {
				Anim {
					duration: Motion.short
				}
			}

			StyledText {
				id: name

				x: 7
				text: tab.provider?.name ?? ""
				tone: tab.selected ? Theme.onPrimary : Theme.text
				surface: tab.color
				font.pixelSize: Theme.size.label
				font.weight: Font.DemiBold
			}
		}

		Item {
			anchors.verticalCenter: parent.verticalCenter
			visible: !tab.short
			width: tab.unread > 0 ? count.width + 7 : 0
			height: count.height

			Rectangle {
				id: count

				x: 7
				width: Math.max(18, number.implicitWidth + 10)
				height: 18
				radius: 9
				color: tab.selected ? Qt.alpha(Theme.onPrimary, 0.2) : Theme.primary
				scale: tab.unread > 0 ? 1 : 0

				Behavior on scale {
					SpatialAnim {
						duration: Motion.medium
					}
				}

				StyledText {
					id: number

					anchors.centerIn: parent
					text: tab.unread > 99 ? "99+" : tab.unread
					tone: Theme.onPrimary
					surface: "transparent"
					tabular: true
					font.pixelSize: Theme.size.tiny
					font.weight: Font.Bold
				}
			}
		}
	}

	// what is unread in one that is only its sign
	Badge {
		anchors.right: parent.right
		anchors.top: parent.top
		anchors.rightMargin: -2
		anchors.topMargin: -2
		count: tab.short ? tab.unread : 0
	}
}
