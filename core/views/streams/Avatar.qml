import QtQuick
import qs.style.theme
import qs.style.widgets
import qs.core.services
import qs.core.views.games

// A channel's picture in a circle; its first letter while there is none.
Item {
	id: root

	property string source: ""
	property string name: ""
	property var colors: null
	property bool live: false

	implicitWidth: 36
	implicitHeight: 36

	// a ring that breathes while it is live
	Rectangle {
		anchors.centerIn: parent
		width: parent.width + 6
		height: width
		radius: width / 2
		color: "transparent"
		border.width: 2
		border.color: Theme.danger
		visible: root.live
		SequentialAnimation on scale {
			running: root.live
			loops: Animation.Infinite
			NumberAnimation {
				from: 1
				to: 1.08
				duration: 900
				easing.type: Easing.InOutSine
			}
			NumberAnimation {
				from: 1.08
				to: 1
				duration: 900
				easing.type: Easing.InOutSine
			}
		}
	}

	Rounded {
		anchors.fill: parent
		radius: width / 2

		Rectangle {
			anchors.fill: parent
			color: root.colors?.deep ?? Theme.layer3

			StyledText {
				anchors.centerIn: parent
				text: root.name.slice(0, 1).toUpperCase()
				font.pixelSize: parent.height * 0.42
				font.weight: Font.DemiBold
				tone: Theme.text
			}
		}

		Image {
			anchors.fill: parent
			source: Streams.picture(root.source)
			fillMode: Image.PreserveAspectCrop
			asynchronous: true
			sourceSize.width: 256
			opacity: status === Image.Ready ? 1 : 0

			Behavior on opacity {
				NumberAnimation {
					duration: Motion.medium
				}
			}
		}
	}
}
