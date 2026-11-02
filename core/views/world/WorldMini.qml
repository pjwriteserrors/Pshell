import QtQuick
import qs.style.theme
import qs.style.widgets
import qs.core.services

// A day or a ticket as its own little land, floating slowly on its water.
Rectangle {
	id: root

	required property string source

	radius: Theme.radius.medium
	color: WorldPalette.deep
	clip: true

	Image {
		id: land

		anchors.centerIn: parent
		width: parent.width
		height: parent.height
		fillMode: Image.PreserveAspectFit
		source: root.source
		asynchronous: true
		smooth: true
		opacity: land.status === Image.Ready ? 1 : 0

		Behavior on opacity {
			Anim {}
		}

		SequentialAnimation on scale {
			running: root.visible
			loops: Animation.Infinite
			NumberAnimation { from: 1; to: 1.05; duration: 9000; easing.type: Easing.InOutSine }
			NumberAnimation { from: 1.05; to: 1; duration: 9000; easing.type: Easing.InOutSine }
		}
		SequentialAnimation on anchors.verticalCenterOffset {
			running: root.visible
			loops: Animation.Infinite
			NumberAnimation { from: -3; to: 3; duration: 5000; easing.type: Easing.InOutSine }
			NumberAnimation { from: 3; to: -3; duration: 5000; easing.type: Easing.InOutSine }
		}
	}
}
