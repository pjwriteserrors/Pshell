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
PanelWindow {
	id: root

	required property var modelData
	screen: modelData


	// Space budget of this bar: the side rows stay clear of the centred
	// cluster. Texts give way first on the sides (media title, note tabs),
	// then in the centre (timer project); the hover date only slides out
	// when there is room for it.
	readonly property real edge: 8
	readonly property real gap: 12

	// width of a row with its flexible element at its narrowest
	function rowMin(row, flexible) {
		let sum = 0;
		let shown = 0;
		for (let i = 0; i < row.children.length; i += 1) {
			const child = row.children[i];
			if (!child.visible) continue;
			sum += child === flexible ? flexible.fixedWidth : child.width;
			shown += 1;
		}
		return sum + row.spacing * Math.max(0, shown - 1);
	}

	readonly property real leftMin: root.rowMin(left, media)
	readonly property real rightMin: root.rowMin(right, notes)
	readonly property real centerRoom: barBody.width - 2 * (root.edge + root.gap) - 2 * Math.max(root.leftMin, root.rightMin) - center.fixedWidth
	readonly property real centerWidth: center.fixedWidth + Math.max(0, Math.min(root.centerRoom, center.textWant))
	readonly property real sideRoom: (barBody.width - root.centerWidth) / 2 - root.edge - root.gap
	readonly property real sideSlack: root.sideRoom - Math.max(
		root.leftMin + Math.max(0, Math.min(media.room, media.textWant)),
		root.rightMin + (notes.visible ? Math.max(0, Math.min(notes.room, notes.textWant)) : 0))

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
	implicitHeight: Theme.barHeight + Theme.screenCorner
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
		height: Theme.barHeight
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

		Row {
			id: left

			anchors.left: parent.left
			anchors.leftMargin: root.edge
			anchors.verticalCenter: parent.verticalCenter
			spacing: 2

			LauncherButton {
				bar: root
			}

			Workspaces {
				bar: root
			}

			TrayButton {
				bar: root
			}

			Taskbar {
				bar: root
			}

			MediaChip {
				id: media

				bar: root
				room: root.sideRoom - root.leftMin
			}
		}

		CenterCluster {
			id: center

			anchors.centerIn: parent
			bar: root
			room: Math.max(0, root.centerRoom)
			dateFits: root.sideSlack >= center.dateWidth / 2
		}

		Row {
			id: right

			anchors.right: parent.right
			anchors.rightMargin: root.edge
			anchors.verticalCenter: parent.verticalCenter
			spacing: 2
			layoutDirection: Qt.LeftToRight

			NotesStrip {
				id: notes

				bar: root
				visible: Host.has("notes")
				room: root.sideRoom - root.rightMin
			}

			BarIcon {
				bar: root
				panelId: "clipboard"
				icon: "clipboard_text_multiple_outline"
				tooltip: "Clipboard history"
				onClicked: toggle()
			}

			BarIcon {
				bar: root
				panelId: "ssh"
				visible: Host.has("ssh")
				icon: "server_network"
				tooltip: "SSH logins"
				onClicked: toggle()
			}

			StatusCluster {
				bar: root
			}

			BellButton {
				bar: root
			}

			BarIcon {
				bar: root
				icon: "power"
				tooltip: "Session"
				iconColor: hovered ? Theme.danger : Theme.textMuted
				onClicked: Popups.toggleModal("power", root.screen)
			}
		}
	}

	// rounded screen corners under the bar
	Shape {
		x: 0
		y: Theme.barHeight
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
		x: root.width - Theme.screenCorner
		y: Theme.barHeight
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
