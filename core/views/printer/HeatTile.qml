import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.core.services
import qs.style.widgets

// A heater (nozzle or bed): what it is at and what it is meant to be, the
// last ten minutes as a curve behind. Heating up, its badge flickers and a
// bar fills toward the target; a cold one stays grey.
Card {
	id: root

	property string icon: "printer_3d_nozzle"
	property string label: ""
	property real now: 0
	property real target: 0
	property var log: []
	readonly property bool on: root.target > 0
	readonly property bool heating: root.on && root.target - root.now > 3
	// the number counts instead of jumping
	property real shown: root.now

	Behavior on shown {
		NumberAnimation {
			duration: 900
			easing.type: Easing.OutCubic
		}
	}

	radius: Theme.radius.large
	color: root.on ? Qt.tint(Theme.layer1, Qt.alpha(Printer.hot, 0.07)) : Theme.layer1
	clip: true

	Behavior on color {
		ColorAnim {
			duration: Motion.long
		}
	}

	Sparkline {
		anchors.left: parent.left
		anchors.right: parent.right
		anchors.bottom: parent.bottom
		height: parent.height * 0.62
		values: root.log
		maximum: Math.max(root.target * 1.15, 60)
		color: root.on ? Printer.hot : Theme.textFaint
		lineWidth: 1.6
		opacity: 0.85
	}

	RowLayout {
		anchors.left: parent.left
		anchors.right: parent.right
		anchors.top: parent.top
		anchors.margins: 12
		spacing: 10

		Rectangle {
			id: badge

			Layout.preferredWidth: 34
			Layout.preferredHeight: 34
			radius: 17
			color: root.on ? Printer.hot : Theme.layer3

			Behavior on color {
				ColorAnim {}
			}

			// the heat breathing out of it while it climbs
			Rectangle {
				anchors.centerIn: parent
				width: parent.width
				height: width
				radius: width / 2
				z: -1
				color: Printer.hot
				opacity: 0
				visible: root.heating

				SequentialAnimation on scale {
					running: root.heating && root.visible
					loops: Animation.Infinite
					NumberAnimation { from: 1; to: 1.7; duration: 1200; easing.type: Easing.OutCubic }
				}
				SequentialAnimation on opacity {
					running: root.heating && root.visible
					loops: Animation.Infinite
					NumberAnimation { from: 0.45; to: 0; duration: 1200; easing.type: Easing.OutCubic }
				}
			}

			Glyph {
				id: flame

				anchors.centerIn: parent
				icon: root.icon
				size: 17
				color: root.on ? Theme.bg : Theme.textMuted

				SequentialAnimation on anchors.verticalCenterOffset {
					running: root.heating && root.visible
					loops: Animation.Infinite
					onRunningChanged: if (!running) flame.anchors.verticalCenterOffset = 0
					NumberAnimation { to: -1.5; duration: 380; easing.type: Easing.InOutSine }
					NumberAnimation { to: 0.5; duration: 420; easing.type: Easing.InOutSine }
				}
			}
		}

		ColumnLayout {
			Layout.fillWidth: true
			spacing: -2

			StyledText {
				text: root.heating ? `${root.label} · heating` : root.label
				tone: Theme.textMuted
				font.pixelSize: Theme.size.small
			}

			RowLayout {
				spacing: 4

				StyledText {
					Layout.alignment: Qt.AlignBaseline
					text: `${Math.round(root.shown)}°`
					font.pixelSize: Theme.size.heading + 2
					font.weight: Font.Bold
					tabular: true
				}

				StyledText {
					Layout.alignment: Qt.AlignBaseline
					visible: root.on
					text: `/ ${Math.round(root.target)}°`
					tone: Theme.textMuted
					font.pixelSize: Theme.size.label
					tabular: true
				}
			}
		}
	}

	// how far it is to the target
	Rectangle {
		anchors.left: parent.left
		anchors.right: parent.right
		anchors.bottom: parent.bottom
		height: 3
		color: "transparent"
		visible: root.heating

		Rectangle {
			height: parent.height
			width: parent.width * Math.max(0, Math.min(1, root.shown / Math.max(1, root.target)))
			radius: 1.5
			color: Printer.hot
		}
	}
}
