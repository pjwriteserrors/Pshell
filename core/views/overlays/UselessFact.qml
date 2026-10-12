pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.style.theme
import qs.style.widgets
import qs.core.services

// The useless fact of the day (Facts) as a card on the desktop. One
// transparent layer on the primary screen between wallpaper and windows;
// only the card takes input. It is dragged anywhere on it and stays where it
// was put; until then it lies in the upper right corner.
PanelWindow {
	id: root

	// The wallpaper's player shares this layer, and whichever surface comes
	// up last lies on top: after a player was started anew the card is
	// taken down and put up again.
	property bool raised: true

	Connections {
		target: Popups
		function onWallpaperPainted() {
			raise.restart();
		}
	}

	Timer {
		id: raise

		interval: 1200
		onTriggered: {
			root.raised = false;
			Qt.callLater(() => root.raised = true);
		}
	}

	screen: Popups.primaryScreen
	visible: Facts.text !== "" && root.raised
	anchors.top: true
	anchors.bottom: true
	anchors.left: true
	anchors.right: true
	exclusionMode: ExclusionMode.Ignore
	color: "transparent"
	WlrLayershell.namespace: "shell-useless-fact"
	WlrLayershell.layer: WlrLayer.Bottom
	WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
	mask: Region {
		x: card.x
		y: card.y
		width: card.width
		height: card.height
		radius: Theme.radius.huge
	}

	FontLoader {
		id: serif

		source: `${Paths.assets}/fonts/InstrumentSerif-Regular.ttf`
	}

	Item {
		id: card

		readonly property real restX: Math.max(0, Math.min(root.width - card.width, Facts.x < 0 ? root.width - card.width - 80 : Facts.x))
		readonly property real restY: Math.max(0, Math.min(root.height - card.height, Facts.y < 0 ? 90 : Facts.y))

		x: card.restX
		y: card.restY
		width: 340
		height: column.implicitHeight + 40

		RectangularShadow {
			anchors.fill: surface
			radius: surface.radius
			blur: 26
			spread: -4
			offset.y: 8
			color: Qt.alpha(Theme.shadow, 0.35)
		}

		Rectangle {
			id: surface

			anchors.fill: parent
			radius: Theme.radius.huge
			color: Qt.alpha(Theme.base, 0.9)
		}

		MouseArea {
			id: dragArea

			anchors.fill: parent
			cursorShape: dragArea.drag.active ? Qt.ClosedHandCursor : Qt.OpenHandCursor
			drag.target: card
			drag.minimumX: 0
			drag.minimumY: 0
			drag.maximumX: root.width - card.width
			drag.maximumY: root.height - card.height
			drag.threshold: 2
			onReleased: {
				if (card.x === card.restX && card.y === card.restY) return;
				Facts.move(card.x, card.y);
				card.x = Qt.binding(() => card.restX);
				card.y = Qt.binding(() => card.restY);
			}
		}

		ColumnLayout {
			id: column

			x: 22
			y: 20
			width: card.width - 44
			spacing: 14

			Glyph {
				icon: "lightbulb"
				size: 18
				color: Theme.primary
			}

			Text {
				Layout.fillWidth: true
				text: Facts.text
				color: Theme.text
				wrapMode: Text.WordWrap
				font.family: serif.name
				font.pixelSize: 24
				lineHeight: 1.08
			}

			StyledText {
				id: source

				Layout.fillWidth: true
				visible: Facts.source !== ""
				text: Facts.source
				tone: sourceArea.containsMouse ? Theme.primary : Theme.textSubtle
				font.pixelSize: Theme.size.tiny

				MouseArea {
					id: sourceArea

					width: Math.min(source.implicitWidth, source.width)
					height: source.height
					enabled: Facts.sourceUrl !== ""
					hoverEnabled: true
					cursorShape: Qt.PointingHandCursor
					onClicked: Qt.openUrlExternally(Facts.sourceUrl)
				}
			}
		}
	}
}
