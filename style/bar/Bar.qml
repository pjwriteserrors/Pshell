pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Wayland
import qs.style.theme
import qs.core.services
import qs.style.widgets

// One top bar per screen. Flush with the screen edge; the lower screen
// corners are rounded off by concave fillets so the bar reads as part of
// the display frame. A single highlight glides between hovered elements.
// Its three zones show what BarLayout says, in that order.
PanelWindow {
	id: root

	required property var modelData
	screen: modelData


	// Space budget of this bar: the side rows stay clear of the centred
	// cluster. Texts give way first on the sides (media title, note tabs),
	// then in the centre (timer project); the hover date only slides out
	// when there is room for it.
	// the bar's height on whole pixels of this screen: at 125 % its 38 points
	// are 47.5 pixels, and the half row left between the bar and a panel
	// hanging from it (niri puts the panel at pixel 48) let the wallpaper
	// through as a bright seam
	readonly property real dpr: root.devicePixelRatio || 1
	readonly property real body: Math.ceil(Theme.barHeight * root.dpr - 0.01) / root.dpr

	readonly property real edge: 8
	readonly property real gap: 12

	// what the zones need at their narrowest, the centre first: it gets
	// what is left between the wider side twice, the sides share the rest
	readonly property real leftMin: left.fixedWidth
	readonly property real rightMin: right.fixedWidth
	readonly property real centerRoom: barBody.width - 2 * (root.edge + root.gap) - 2 * Math.max(root.leftMin, root.rightMin) - center.fixedWidth
	readonly property real centerWidth: center.fixedWidth + Math.max(0, Math.min(root.centerRoom, center.textWant))
	readonly property real sideRoom: (barBody.width - root.centerWidth) / 2 - root.edge - root.gap
	// what the sides do not use: the clock's date slides out only into this
	readonly property real sideSlack: root.sideRoom - Math.max(
		root.leftMin + Math.max(0, Math.min(left.room, left.textWant)),
		root.rightMin + Math.max(0, Math.min(right.room, right.textWant)))

	property Item hoverItem: null
	property Item tooltipItem: null

	function setHover(item, on) {
		if (on) {
			root.hoverItem = item;
			tooltipTimer.restart();
		} else if (root.hoverItem === item) {
			root.hoverItem = null;
			root.tooltipItem = null;
			tooltipTimer.stop();
		}
	}

	anchors {
		top: true
		left: true
		right: true
	}
	implicitHeight: Math.ceil(root.body + Theme.screenCorner)
	exclusiveZone: Theme.barHeight
	color: "transparent"
	WlrLayershell.namespace: "shell-bar"
	mask: Region {
		item: barBody
	}

	// keep awake (quick settings)
	IdleInhibitor {
		window: root
		enabled: KeepAwake.active
	}

	Timer {
		id: tooltipTimer
		interval: 650
		onTriggered: root.tooltipItem = root.hoverItem
	}

	Rectangle {
		id: barBody

		anchors.left: parent.left
		anchors.right: parent.right
		anchors.top: parent.top
		height: root.body
		color: Theme.glass

		// gliding hover highlight
		Rectangle {
			id: pill

			property rect target: Qt.rect(0, 0, 0, 0)

			x: target.x
			y: 5
			width: target.width
			height: Theme.barHeight - 10
			radius: height / 2
			color: Qt.alpha(Theme.fg, 0.1)
			opacity: root.hoverItem ? 1 : 0

			Behavior on x {
				enabled: pill.opacity > 0.05
				SpatialAnim {
					duration: Motion.short + 30
				}
			}
			Behavior on width {
				enabled: pill.opacity > 0.05
				SpatialAnim {
					duration: Motion.short + 30
				}
			}
			Behavior on opacity {
				Anim {
					duration: Motion.short
				}
			}

			FrameAnimation {
				running: root.hoverItem !== null
				onTriggered: {
					const item = root.hoverItem;
					if (!item) return;
					const p = item.mapToItem(barBody, 0, 0);
					pill.target = Qt.rect(p.x + 2, 0, Math.max(0, item.width - 4), 0);
				}
			}
		}

		// a click on the bar itself (between elements) dismisses everything
		MouseArea {
			anchors.fill: parent
			acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
			onPressed: Popups.closeAll()
		}

		// what goes where: BarLayout (Pshell settings › Bar)
		BarZone {
			id: left

			anchors.left: parent.left
			anchors.leftMargin: root.edge
			anchors.verticalCenter: parent.verticalCenter
			bar: root
			ids: BarLayout.left
			room: root.sideRoom - root.leftMin
		}

		BarZone {
			id: center

			anchors.centerIn: parent
			spacing: 4
			bar: root
			ids: BarLayout.center
			room: Math.max(0, root.centerRoom)
		}

		BarZone {
			id: right

			anchors.right: parent.right
			anchors.rightMargin: root.edge
			anchors.verticalCenter: parent.verticalCenter
			bar: root
			ids: BarLayout.right
			room: root.sideRoom - root.rightMin
		}
	}

	// rounded screen corners under the bar
	Shape {
		// the frame around the screen has its own
		visible: !Corners.all
		x: 0
		y: root.body
		width: Theme.screenCorner
		height: Theme.screenCorner
		preferredRendererType: Shape.CurveRenderer

		ShapePath {
			fillColor: Theme.glass
			strokeColor: "transparent"
			startX: 0
			startY: 0
			PathLine {
				x: Theme.screenCorner
				y: 0
			}
			PathArc {
				x: 0
				y: Theme.screenCorner
				radiusX: Theme.screenCorner
				radiusY: Theme.screenCorner
				direction: PathArc.Counterclockwise
			}
		}
	}

	Shape {
		visible: !Corners.all
		x: root.width - Theme.screenCorner
		y: root.body
		width: Theme.screenCorner
		height: Theme.screenCorner
		preferredRendererType: Shape.CurveRenderer

		ShapePath {
			fillColor: Theme.glass
			strokeColor: "transparent"
			startX: 0
			startY: 0
			PathLine {
				x: Theme.screenCorner
				y: 0
			}
			PathLine {
				x: Theme.screenCorner
				y: Theme.screenCorner
			}
			PathArc {
				x: 0
				y: 0
				radiusX: Theme.screenCorner
				radiusY: Theme.screenCorner
				direction: PathArc.Counterclockwise
			}
		}
	}

	BarTooltip {
		bar: root
	}
}
