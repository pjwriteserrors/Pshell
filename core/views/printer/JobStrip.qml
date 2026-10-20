pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.style.theme
import qs.core.services
import qs.style.widgets

// The jobs that came in, newest first, after a card for the inbox: the
// part, its name, a dot for one that is new or on the printer. A card lifts
// under the pointer and its part leans toward it; a click shows the job
// (again on the one shown: back to what prints).
ListView {
	id: root

	implicitHeight: 104
	orientation: ListView.Horizontal
	spacing: 8
	clip: true
	boundsBehavior: Flickable.StopAtBounds
	model: Printer.jobs
	topMargin: 6

	// the wheel scrolls it sideways
	WheelHandler {
		acceptedDevices: PointerDevice.Mouse
		onWheel: event => {
			const end = root.originX + Math.max(0, root.contentWidth - root.width);
			root.contentX = Math.max(root.originX, Math.min(end, root.contentX - event.angleDelta.y));
		}
	}

	Behavior on contentX {
		enabled: !root.moving
		SpatialAnim {}
	}

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
				from: 0.6
				to: 1
				duration: 520
				easing.type: Easing.OutBack
			}
		}
	}
	displaced: Transition {
		NumberAnimation {
			property: "x"
			duration: 420
			easing.type: Easing.BezierSpline
			easing.bezierCurve: Motion.spatial
		}
	}
	remove: Transition {
		ParallelAnimation {
			NumberAnimation {
				property: "opacity"
				to: 0
				duration: 200
			}
			NumberAnimation {
				property: "scale"
				to: 0.6
				duration: 240
			}
		}
	}

	// the inbox: where files come from
	header: Item {
		width: 100
		height: 92

		Clickable {
			id: inbox

			width: 92
			height: 92
			y: inbox.hovered ? -5 : 0
			radius: Theme.radius.large
			color: inbox.hovered ? Theme.primaryContainer : "transparent"
			onClicked: Quickshell.execDetached(["xdg-open", Printer.inbox.replace(/^~/, Quickshell.env("HOME"))])

			Behavior on y {
				SpatialAnim {}
			}

			Rectangle {
				anchors.fill: parent
				radius: inbox.radius
				color: "transparent"
				border.width: 1.5
				border.color: inbox.hovered ? Theme.primary : Qt.alpha(Theme.fg, 0.14)

				Behavior on border.color {
					ColorAnim {}
				}
			}

			Column {
				anchors.centerIn: parent
				spacing: 6

				Rectangle {
					anchors.horizontalCenter: parent.horizontalCenter
					width: 34
					height: 34
					radius: 17
					color: inbox.hovered ? Theme.primary : Theme.layer2

					Behavior on color {
						ColorAnim {}
					}

					Glyph {
						anchors.centerIn: parent
						icon: "plus"
						size: 18
						color: inbox.hovered ? Theme.onPrimary : Theme.text
						rotation: inbox.hovered ? 90 : 0

						Behavior on rotation {
							SpatialAnim {}
						}
					}
				}

				StyledText {
					anchors.horizontalCenter: parent.horizontalCenter
					text: "Inbox"
					font.pixelSize: Theme.size.small
					font.weight: Font.DemiBold
					tone: inbox.hovered ? Theme.primary : Theme.textMuted
				}
			}
		}
	}

	delegate: Clickable {
		id: card

		required property var modelData
		required property int index
		readonly property var shown: Printer.job(Printer.selected) ?? Printer.printingJob
		readonly property bool current: card.shown !== null && card.shown.id === card.modelData.id
		readonly property bool onPrinter: Printer.printingJob !== null && Printer.printingJob.id === card.modelData.id

		width: 140
		height: 92
		y: card.hovered ? -5 : 0
		radius: Theme.radius.large
		color: card.current ? Theme.primaryContainer : (card.hovered ? Theme.layer2 : Theme.layer1)
		onClicked: Printer.selected = card.current && Printer.printing ? "" : card.modelData.id

		Behavior on y {
			SpatialAnim {}
		}

		// the one shown, ringed
		Rectangle {
			anchors.fill: parent
			radius: card.radius
			color: "transparent"
			border.width: 2
			border.color: Theme.primary
			opacity: card.current ? 1 : 0
			scale: card.current ? 1 : 1.06

			Behavior on opacity {
				Anim {}
			}
			Behavior on scale {
				SpatialAnim {}
			}
		}

		// a glow behind the part
		Rectangle {
			anchors.horizontalCenter: parent.horizontalCenter
			y: 10
			width: 64
			height: 40
			radius: 20
			color: card.onPrinter ? Printer.hot : Theme.primary
			opacity: card.hovered || card.current ? 0.18 : 0
			scale: card.hovered ? 1.2 : 0.8

			Behavior on opacity {
				Anim {}
			}
			Behavior on scale {
				SpatialAnim {}
			}
		}

		Image {
			id: thumb

			anchors.top: parent.top
			anchors.horizontalCenter: parent.horizontalCenter
			anchors.topMargin: 8
			width: parent.width - 20
			height: 50
			fillMode: Image.PreserveAspectFit
			source: card.modelData.frames > 0 ? `file://${card.modelData.preview}/model.png` : ""
			sourceSize.height: 112
			smooth: true
			mipmap: true
			asynchronous: true
			opacity: status === Image.Ready ? 1 : 0
			scale: card.hovered ? 1.12 : 1
			rotation: card.hovered ? -4 : 0

			Behavior on opacity {
				Anim {}
			}
			Behavior on scale {
				SpatialAnim {}
			}
			Behavior on rotation {
				SpatialAnim {}
			}
		}

		Spinner {
			anchors.centerIn: thumb
			width: 20
			height: 20
			visible: !!card.modelData.rendering || !!card.modelData.slicing
		}

		// what came in: a model to slice, a sliced 3MF
		Rectangle {
			anchors.top: parent.top
			anchors.left: parent.left
			anchors.margins: 7
			width: kindText.implicitWidth + 10
			height: 16
			radius: 8
			visible: card.modelData.kind === "model" || card.modelData.kind === "sliced"
			color: Qt.alpha(Theme.primary, 0.2)

			StyledText {
				id: kindText

				anchors.centerIn: parent
				text: String(card.modelData.format || "3mf").toUpperCase()
				font.pixelSize: 9
				font.weight: Font.Bold
				tone: Theme.primary
			}
		}

		StyledText {
			anchors.left: parent.left
			anchors.right: parent.right
			anchors.bottom: parent.bottom
			anchors.margins: 8
			anchors.bottomMargin: card.onPrinter && Printer.printing ? 12 : 9
			text: Printer.title(card.modelData)
			elide: Text.ElideRight
			font.pixelSize: Theme.size.tiny
			font.weight: card.current ? Font.DemiBold : Font.Normal
			horizontalAlignment: Text.AlignHCenter
		}

		// new, or on the printer: a dot that sends out rings
		Rectangle {
			id: mark

			anchors.top: parent.top
			anchors.right: parent.right
			anchors.margins: 9
			width: 8
			height: 8
			radius: 4
			visible: card.onPrinter || card.modelData.status === "new"
			color: card.onPrinter ? Printer.hot : Theme.primary

			Rectangle {
				id: halo

				anchors.centerIn: parent
				width: 8
				height: 8
				radius: 4
				color: "transparent"
				border.width: 1.5
				border.color: mark.color
				opacity: 0

				ParallelAnimation {
					running: mark.visible && root.visible
					loops: Animation.Infinite
					NumberAnimation { target: halo; property: "scale"; from: 1; to: 2.6; duration: 1400; easing.type: Easing.OutCubic }
					NumberAnimation { target: halo; property: "opacity"; from: 0.9; to: 0; duration: 1400; easing.type: Easing.OutCubic }
				}
			}
		}

		// the print on it, as a line along the bottom
		Rectangle {
			anchors.left: parent.left
			anchors.right: parent.right
			anchors.bottom: parent.bottom
			anchors.margins: 12
			anchors.bottomMargin: 5
			height: 3
			radius: 1.5
			visible: card.onPrinter && Printer.printing
			color: Qt.alpha(Theme.fg, 0.1)

			Rectangle {
				width: parent.width * Printer.progress
				height: parent.height
				radius: parent.radius
				color: Printer.hot

				Behavior on width {
					SpatialAnim {}
				}
			}
		}
	}
}
