import QtQuick
import QtQuick.Effects
import qs.style.theme
import qs.style.widgets
import "NiriColor.js" as NiriColor

// A window and its shadow, as niri draws it (CSS box-shadow). Grab the
// shadow and drag it: that is its offset. The crosshair marks no offset.
Item {
	id: root

	property real offsetX: 0
	property real offsetY: 5
	property real softness: 30
	property real spread: 5
	property string color: "#00000070"
	property real radius: 12
	property real range: 40
	// logical pixels → pixels of this preview
	property real zoom: 1.4

	signal moved(real x, real y)

	implicitWidth: 260
	implicitHeight: 190
	clip: true

	property real shownX: root.offsetX
	property real shownY: root.offsetY

	Behavior on shownX {
		enabled: !mouse.pressed
		SpatialAnim {
			duration: Motion.medium
		}
	}
	Behavior on shownY {
		enabled: !mouse.pressed
		SpatialAnim {
			duration: Motion.medium
		}
	}

	Rectangle {
		anchors.fill: parent
		radius: Theme.radius.large
		color: Qt.tint(Theme.layer2, Qt.alpha("white", Theme.dark ? 0.02 : 0.4))
	}

	// the crosshair: where the shadow sits without offset
	Rectangle {
		anchors.horizontalCenter: parent.horizontalCenter
		width: 1
		height: parent.height
		color: Theme.outline
	}

	Rectangle {
		anchors.verticalCenter: parent.verticalCenter
		width: parent.width
		height: 1
		color: Theme.outline
	}

	RectangularShadow {
		anchors.fill: win
		offset.x: root.shownX * root.zoom
		offset.y: root.shownY * root.zoom
		blur: root.softness * root.zoom
		spread: root.spread * root.zoom
		radius: win.radius
		color: NiriColor.qt(root.color)
		cached: false
	}

	Rectangle {
		id: win

		anchors.centerIn: parent
		width: parent.width * 0.42
		height: parent.height * 0.42
		radius: root.radius
		color: Theme.base
		border.width: 1
		border.color: Theme.outline

		Column {
			anchors.left: parent.left
			anchors.top: parent.top
			anchors.margins: 10
			spacing: 5

			Repeater {
				model: [0.7, 0.5, 0.6]

				delegate: Rectangle {
					required property real modelData

					width: win.width * modelData - 10
					height: 5
					radius: 2.5
					color: Theme.layer3
				}
			}
		}
	}

	// the handle on the shadow
	Rectangle {
		x: win.x + win.width / 2 + root.shownX * root.zoom - width / 2
		y: win.y + win.height / 2 + root.shownY * root.zoom - height / 2
		width: mouse.pressed ? 26 : 20
		height: width
		radius: width / 2
		color: Qt.alpha(Theme.primary, 0.25)
		border.width: 2
		border.color: Theme.primary
		visible: mouse.containsMouse || mouse.pressed

		Behavior on width {
			SpatialAnim {
				duration: Motion.short
			}
		}
	}

	StyledText {
		anchors.right: parent.right
		anchors.bottom: parent.bottom
		anchors.margins: 10
		text: `x ${Math.round(root.offsetX)}  y ${Math.round(root.offsetY)}`
		tabular: true
		tone: Theme.textSubtle
		font.family: Theme.monoFamily
		font.pixelSize: Theme.size.small
	}

	MouseArea {
		id: mouse

		property point start
		property real startX
		property real startY

		anchors.fill: parent
		hoverEnabled: true
		preventStealing: true
		cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
		onPressed: event => {
			mouse.start = Qt.point(event.x, event.y);
			mouse.startX = root.offsetX;
			mouse.startY = root.offsetY;
		}
		onPositionChanged: event => {
			if (!pressed) return;
			const clampRange = v => Math.max(-root.range, Math.min(root.range, Math.round(v)));
			root.moved(clampRange(mouse.startX + (event.x - mouse.start.x) / root.zoom), clampRange(mouse.startY + (event.y - mouse.start.y) / root.zoom));
		}
		onDoubleClicked: root.moved(0, 0)
	}
}
