import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.style.theme
import qs.style.widgets
import qs.core.services

// A strip one pixel wide on an edge that leads to another PC (Kvm.qml). It
// only says when the pointer is on it and where along it; the daemon counts
// the push from the mouse itself. Above windows, below fullscreen ones, so a
// game at the edge never sends the mouse away.
PanelWindow {
	id: root

	// "output|side|back"
	required property string modelData
	readonly property var parts: root.modelData.split("|")
	readonly property string output: root.parts[0]
	readonly property string side: root.parts[1]
	readonly property bool vertical: root.side === "left" || root.side === "right"
	readonly property bool hovered: area.containsMouse
	property real lastSent: 0

	screen: Quickshell.screens.find(screen => String(screen.name) === root.output) ?? null
	anchors.left: root.side !== "right"
	anchors.right: root.side !== "left"
	anchors.top: root.side !== "bottom"
	anchors.bottom: root.side !== "top"
	// wider than what takes the pointer, for the light; only the outermost
	// pixel is the strip (the mask), the rest lets clicks through
	readonly property int glow: 18
	// room for the pointer's badge while it is on the edge
	readonly property int room: root.hovered ? 200 : root.glow
	implicitWidth: root.room
	implicitHeight: root.room
	exclusiveZone: 0
	color: "transparent"
	mask: Region {
		item: line
	}
	WlrLayershell.namespace: "shell-kvm-edge"
	WlrLayershell.layer: WlrLayer.Top
	WlrLayershell.exclusionMode: ExclusionMode.Ignore
	WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

	function report(inside) {
		const pos = root.vertical ? area.mouseY / Math.max(1, area.height) : area.mouseX / Math.max(1, area.width);
		root.lastSent = Date.now();
		Kvm.edge(root.output, root.side, Math.min(1, Math.max(0, pos)), inside);
	}

	// the light of the edge: faint while it waits, bright while the pointer pushes on it
	Rectangle {
		x: root.side === "right" ? root.width - width : 0
		y: root.side === "bottom" ? root.height - height : 0
		width: root.vertical ? root.glow : root.width
		height: root.vertical ? root.height : root.glow
		opacity: root.hovered ? 0.9 : 0
		gradient: Gradient {
			orientation: root.vertical ? Gradient.Horizontal : Gradient.Vertical
			GradientStop {
				position: 0
				color: root.side === "left" || root.side === "top" ? Theme.primary : "transparent"
			}
			GradientStop {
				position: 1
				color: root.side === "left" || root.side === "top" ? "transparent" : Theme.primary
			}
		}

		Behavior on opacity {
			NumberAnimation {
				duration: 160
			}
		}
	}

	// the strip itself: one pixel at the very edge, a thin line to be seen by
	Item {
		id: line

		x: root.side === "right" ? root.width - 1 : 0
		y: root.side === "bottom" ? root.height - 1 : 0
		width: root.vertical ? 1 : root.width
		height: root.vertical ? root.height : 1
	}

	Rectangle {
		x: root.side === "right" ? root.width - 2 : 0
		y: root.side === "bottom" ? root.height - 2 : 0
		width: root.vertical ? 2 : root.width
		height: root.vertical ? root.height : 2
		color: Theme.primary
		opacity: root.hovered ? 1 : 0.35
	}

	MouseArea {
		id: area

		anchors.fill: line
		hoverEnabled: true
		acceptedButtons: Qt.NoButton
		onEntered: root.report(true)
		onExited: root.report(false)
		onPositionChanged: if (Date.now() - root.lastSent > 80) root.report(true)
	}

	// the pointer says where it leads: the other PC's name beside it, on the
	// side that is still this screen
	PshellCursor {
		visible: root.hovered && CursorStyle.ready
		x: line.x + area.mouseX
		y: line.y + area.mouseY
		shape: ""

		CursorBadge {
			id: leads

			x: root.side === "right" ? -width - 6 * CursorStyle.unit : CursorStyle.badgeAt.x - height / 2
			y: root.side === "bottom" ? -height - 6 * CursorStyle.unit : CursorStyle.badgeAt.y - height / 2
			icon: "monitor_share"
			text: Pcs.nameOf(Kvm.edgeAt(root.output, root.side)?.pc ?? "")
			transformOrigin: root.side === "right" ? Item.Right : Item.Left
		}
	}

	SequentialAnimation {
		running: root.hovered

		NumberAnimation {
			target: leads
			property: "pop"
			from: 0
			to: 1
			duration: Motion.short
			easing.type: Easing.OutCubic
		}
		NumberAnimation {
			target: leads
			property: "pop"
			to: 0
			duration: Motion.medium
			easing.type: Easing.InOutCubic
		}
	}

	Component.onDestruction: if (root.hovered) Kvm.edge(root.output, root.side, 0.5, false)
}
