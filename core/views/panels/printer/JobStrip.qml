pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.core.services
import qs.style.widgets

// The jobs that came in, newest first: the part, its name, a dot for one
// that is new or on the printer. A card lifts under the pointer; a click
// shows the job (again on the one shown: back to what prints).
ListView {
	id: root

	implicitHeight: 96
	orientation: ListView.Horizontal
	spacing: 8
	clip: true
	boundsBehavior: Flickable.StopAtBounds
	model: Printer.jobs

	add: Transition {
		ParallelAnimation {
			NumberAnimation {
				property: "opacity"
				from: 0
				to: 1
				duration: 300
			}
			NumberAnimation {
				property: "scale"
				from: 0.7
				to: 1
				duration: 450
				easing.type: Easing.OutBack
			}
		}
	}
	displaced: Transition {
		NumberAnimation {
			property: "x"
			duration: 350
			easing.type: Easing.OutCubic
		}
	}

	delegate: Clickable {
		id: card

		required property var modelData
		readonly property var shown: Printer.job(Printer.selected) ?? Printer.printingJob
		readonly property bool current: card.shown !== null && card.shown.id === card.modelData.id
		readonly property bool onPrinter: Printer.printingJob !== null && Printer.printingJob.id === card.modelData.id

		width: 136
		height: 90
		y: card.hovered ? 0 : 4
		radius: Theme.radius.large
		color: card.current ? Theme.primarySoft : Theme.layer1
		border.width: 1
		border.color: card.current ? Qt.alpha(Theme.primary, 0.5) : Theme.outline
		onClicked: Printer.selected = card.current && Printer.printing ? "" : card.modelData.id

		Behavior on y {
			SpatialAnim {}
		}

		Image {
			anchors.top: parent.top
			anchors.horizontalCenter: parent.horizontalCenter
			anchors.topMargin: 6
			width: parent.width - 16
			height: 52
			fillMode: Image.PreserveAspectFit
			source: card.modelData.frames > 0 ? `file://${card.modelData.preview}/model.png` : ""
			sourceSize.height: 104
			smooth: true
			asynchronous: true
			opacity: status === Image.Ready ? 1 : 0

			Behavior on opacity {
				Anim {}
			}
		}

		Spinner {
			anchors.centerIn: parent
			anchors.verticalCenterOffset: -10
			width: 20
			height: 20
			visible: !!card.modelData.rendering
		}

		StyledText {
			anchors.left: parent.left
			anchors.right: parent.right
			anchors.bottom: parent.bottom
			anchors.margins: 8
			text: Printer.title(card.modelData)
			font.pixelSize: Theme.size.tiny
			horizontalAlignment: Text.AlignHCenter
		}

		Rectangle {
			anchors.top: parent.top
			anchors.right: parent.right
			anchors.margins: 8
			width: 8
			height: 8
			radius: 4
			visible: card.onPrinter || card.modelData.status === "new"
			color: card.onPrinter ? Printer.hot : Theme.primary
		}
	}
}
