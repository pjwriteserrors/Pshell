pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.style.theme
import qs.style.widgets
import qs.core.services

// When an episode ended and the next one is about to start: a card in the
// corner of the focused screen with a ring running down. It takes no keys and
// lets every click beside it through.
PanelWindow {
	id: root

	readonly property var item: Streams.upNext
	property real shown: root.item ? 1 : 0
	property var kept: null
	readonly property var card: root.item ?? root.kept

	onItemChanged: {
		if (root.item) {
			root.kept = root.item;
			countdown.restart();
		} else {
			countdown.stop();
		}
	}

	Behavior on shown {
		NumberAnimation {
			duration: root.item ? Motion.extraLong : Motion.medium
			easing.type: Easing.BezierSpline
			easing.bezierCurve: root.item ? Motion.spatial : Motion.accel
		}
	}

	screen: Popups.focusedScreen()
	anchors {
		top: true
		right: true
	}
	margins {
		top: Theme.barHeight + 12
		right: 16
	}
	// as large on a big screen as on a small one
	readonly property real ui: Math.max(1, (root.screen?.width ?? 1536) / 1920)

	implicitWidth: Math.round(380 * root.ui)
	implicitHeight: Math.round(110 * root.ui)
	exclusiveZone: 0
	color: "transparent"
	visible: root.shown > 0.002
	WlrLayershell.namespace: "shell-streams-next"
	WlrLayershell.layer: WlrLayer.Overlay
	WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

	property real left: 1

	NumberAnimation {
		id: countdown

		target: root
		property: "left"
		from: 1
		to: 0
		duration: (root.item?.seconds ?? 10) * 1000
	}

	Rectangle {
		width: 380
		height: 110
		transformOrigin: Item.TopLeft
		scale: root.ui
		radius: Theme.radius.huge
		color: Theme.layer2
		border.width: 1
		border.color: Theme.outline
		opacity: Math.min(1, root.shown * 1.4)
		transform: Translate {
			x: (1 - root.shown) * 60
		}

		RowLayout {
			anchors.fill: parent
			anchors.margins: 10
			spacing: 12

			Thumb {
				Layout.preferredWidth: 130
				Layout.fillHeight: true
				source: root.card?.thumb ?? ""
				radius: Theme.radius.large

				Rectangle {
					anchors.fill: parent
					radius: Theme.radius.large
					color: Qt.alpha("black", 0.35)
				}

				Ring {
					anchors.centerIn: parent
					width: 44
					height: 44
					value: root.left
					color: "white"
					thickness: 3
				}

				StyledText {
					anchors.centerIn: parent
					text: Math.ceil(root.left * (root.card?.seconds ?? 10))
					color: "white"
					font.pixelSize: Theme.size.title
					font.weight: Font.Bold
					tabular: true
				}
			}

			ColumnLayout {
				Layout.fillWidth: true
				spacing: 2

				StyledText {
					text: "Up next"
					font.pixelSize: Theme.size.small
					tone: Theme.textMuted
				}
				StyledText {
					Layout.fillWidth: true
					text: root.card?.title ?? ""
					font.pixelSize: Theme.size.label
					font.weight: Font.DemiBold
					wrapMode: Text.Wrap
					maximumLineCount: 2
					elide: Text.ElideRight
				}
				RowLayout {
					spacing: 4
					Layout.topMargin: 2

					TextButton {
						text: "Play now"
						variant: "filled"
						onActivated: Streams.answerNext(true)
					}
					TextButton {
						text: "Stop"
						variant: "ghost"
						onActivated: Streams.answerNext(false)
					}
				}
			}
		}
	}
}
