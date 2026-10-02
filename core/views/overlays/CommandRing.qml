pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
import Quickshell
import Quickshell.Wayland
import qs.style.theme
import qs.core.services
import qs.style.widgets

// The commands of DropCommands on one screen: bubbles in a ring around the
// spot where the drag was shaken. The direction of the drag picks one, the
// bubbles swell towards it, and letting go there runs it. A command with a
// page behind it opens when the drag rests on it; resting in the middle
// leads back. Only the disc takes the drag: next to it, things drop where
// they were going, and the ring leaves.
PanelWindow {
	id: root

	required property var modelData
	readonly property string name: String(root.modelData.name)
	readonly property bool waiting: DropCommands.active && DropCommands.output === ""
	readonly property bool shown: DropCommands.active && DropCommands.output === root.name
	property real reveal: root.shown ? 1 : 0
	// 0 → 1 while it leaves
	readonly property real leave: root.shown ? 0 : 1 - root.reveal

	readonly property real dead: 36
	readonly property real ringRadius: 108
	readonly property real bubble: 54
	readonly property real reach: 236

	property real cx: 0
	property real cy: 0
	property real pointerX: 0
	property real pointerY: 0
	property real pointerAngle: -90
	readonly property real pointerDistance: Math.hypot(root.pointerX - root.cx, root.pointerY - root.cy)
	readonly property bool aiming: root.pointerDistance > root.dead && root.pointerDistance <= root.reach
	readonly property bool resting: root.pointerDistance <= root.dead

	readonly property var commands: DropCommands.commands
	readonly property int count: root.commands.length
	property int index: -1
	readonly property var command: root.index >= 0 && root.index < root.count ? root.commands[root.index] : null
	// the one that was run: it pops while the others fall back
	property int chosen: -1

	// linear clock of the arrival; every bubble takes its own slice of it
	property real enter: 1
	property real origin: -90
	readonly property real stagger: 28
	readonly property real itemTime: 340
	readonly property real span: root.itemTime + Math.max(0, root.count - 1) * root.stagger
	// how long the drag has rested on a command that opens, or in the middle
	property real dwell: 0

	function angleOf(position) {
		return -90 + position * 360 / Math.max(1, root.count);
	}

	function shortest(delta) {
		return ((delta % 360) + 540) % 360 - 180;
	}

	function backOut(t) {
		const c = 1.5;
		return 1 + (c + 1) * Math.pow(t - 1, 3) + c * Math.pow(t - 1, 2);
	}

	// the middle of the ring, for commands that put something there
	function at() {
		return {
			output: root.name,
			x: Math.round(Math.max(8, Math.min(root.width - 348, root.cx - 170))),
			y: Math.round(Math.max(8, Math.min(root.height - 360, root.cy - 60)))
		};
	}

	function claim(x, y, formats) {
		DropCommands.claim(root.name, formats);
		const margin = root.ringRadius + root.bubble;
		root.cx = Math.max(margin + 60, Math.min(root.width - margin - 60, x));
		root.cy = Math.max(margin, Math.min(root.height - margin, y));
		root.chosen = -1;
		root.index = -1;
		root.origin = -90;
		gone.stop();
		heldIdle.stop();
		enterAnim.restart();
	}

	function pointer(x, y) {
		root.pointerX = x;
		root.pointerY = y;
		if (root.pointerDistance > 1) root.pointerAngle = Math.atan2(y - root.cy, x - root.cx) * 180 / Math.PI;
		root.pick();
	}

	function pick() {
		if (!root.aiming || root.count === 0) {
			root.index = -1;
			return;
		}
		root.index = Math.round((((root.pointerAngle + 90) % 360) + 360) % 360 / (360 / root.count)) % root.count;
	}

	function commit(items) {
		const command = root.command;
		if (!command) {
			DropCommands.dismiss();
			return;
		}
		if (command.opens) {
			// let go on a command with a page: the page is finished by click
			DropCommands.held = items;
			heldIdle.restart();
			DropCommands.run(command);
			return;
		}
		root.chosen = root.index;
		DropCommands.run(command, items, root.at());
	}

	onCommandsChanged: {
		if (!root.shown) return;
		root.origin = root.pointerAngle;
		root.index = -1;
		enterAnim.restart();
		root.pick();
	}

	// resting on a command that opens, or in the middle of a page, counts up
	readonly property string dwellOn: !root.shown ? "" : root.command?.opens ? `open:${root.index}` : (DropCommands.page !== "" && root.resting ? "back" : "")
	onDwellOnChanged: {
		dwellAnim.stop();
		root.dwell = 0;
		if (root.dwellOn === "") return;
		dwellAnim.duration = root.dwellOn === "back" ? 650 : 420;
		dwellAnim.start();
	}

	NumberAnimation {
		id: dwellAnim

		target: root
		property: "dwell"
		from: 0
		to: 1
		onFinished: {
			if (root.dwell < 1) return;
			if (root.dwellOn === "back") DropCommands.page = "";
			else if (root.command?.opens) DropCommands.run(root.command);
		}
	}

	NumberAnimation {
		id: enterAnim

		target: root
		property: "enter"
		from: 0
		to: 1
		duration: root.span
	}

	// the drag left the disc: it is going somewhere else
	Timer {
		id: gone

		interval: 600
		onTriggered: if (root.shown && !DropCommands.held) DropCommands.dismiss()
	}

	// a page waiting for a click does not wait for ever
	Timer {
		id: heldIdle

		interval: 8000
		onTriggered: if (root.shown) DropCommands.dismiss()
	}

	Behavior on reveal {
		NumberAnimation {
			duration: Motion.medium
			easing.type: Easing.BezierSpline
			easing.bezierCurve: root.shown ? Motion.decel : Motion.accel
		}
	}

	screen: root.modelData
	visible: root.waiting || root.shown || root.reveal > 0.002
	color: "transparent"
	anchors {
		left: true
		right: true
		top: true
		bottom: true
	}
	exclusiveZone: 0
	WlrLayershell.namespace: "shell-commands"
	WlrLayershell.layer: WlrLayer.Overlay
	WlrLayershell.exclusionMode: ExclusionMode.Ignore
	WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

	// every screen listens until one sees the drag; then only the disc does
	mask: Region {
		regions: root.waiting ? [everywhere] : root.shown ? [disc] : []
	}

	Region {
		id: everywhere

		item: catcher
	}

	Region {
		id: disc

		x: root.cx - root.reach
		y: root.cy - root.reach
		width: root.reach * 2
		height: root.reach * 2
		shape: RegionShape.Ellipse
	}

	// a new one for every summon: one that was hidden mid-drag never hears
	// the drag leave, and takes no other after that
	Loader {
		id: catcher

		anchors.fill: parent
		active: DropCommands.active
		sourceComponent: DropArea {
			onEntered: drag => {
				gone.stop();
				if (root.waiting) root.claim(drag.x, drag.y, drag.formats);
				root.pointer(drag.x, drag.y);
			}
			onPositionChanged: drag => root.pointer(drag.x, drag.y)
			onExited: gone.restart()
			onDropped: event => {
				const items = Shelf.itemsOfDrop(event);
				event.accept(Qt.CopyAction);
				root.commit(items);
			}
		}
	}

	// a page that was opened by letting go: its commands are clicked
	MouseArea {
		anchors.fill: parent
		enabled: root.shown && !!DropCommands.held
		hoverEnabled: true
		acceptedButtons: Qt.LeftButton | Qt.RightButton
		onPositionChanged: mouse => root.pointer(mouse.x, mouse.y)
		onClicked: mouse => {
			root.pointer(mouse.x, mouse.y);
			if (mouse.button === Qt.LeftButton && root.command) root.commit(DropCommands.held);
			else DropCommands.dismiss();
		}
	}

	Item {
		id: stage

		x: root.cx
		y: root.cy
		visible: root.reveal > 0.002

		// the disc that takes the drag
		Rectangle {
			readonly property real size: root.reach * 2 * (0.55 + 0.45 * root.reveal)

			x: -size / 2
			y: -size / 2
			width: size
			height: size
			radius: size / 2
			color: Theme.scrim
			opacity: root.reveal * 0.9
		}

		// from the middle to the drag
		Shape {
			readonly property real box: root.reach

			x: -box
			y: -box
			width: box * 2
			height: box * 2
			opacity: root.reveal * (root.aiming ? 1 : 0)
			preferredRendererType: Shape.CurveRenderer

			Behavior on opacity {
				Anim {
					duration: Motion.short
				}
			}

			ShapePath {
				strokeColor: Qt.alpha(Theme.primary, 0.45)
				strokeWidth: 2.5
				fillColor: "transparent"
				capStyle: ShapePath.RoundCap
				startX: root.reach
				startY: root.reach

				PathLine {
					x: root.reach + (root.pointerX - root.cx)
					y: root.reach + (root.pointerY - root.cy)
				}
			}
		}

		Repeater {
			model: root.commands

			delegate: Item {
				id: slot

				required property var modelData
				required property int index
				readonly property bool selected: root.index === slot.index
				readonly property bool popped: root.chosen === slot.index
				readonly property real target: root.angleOf(slot.index)
				readonly property real t: Math.max(0, Math.min(1, (root.enter * root.span - slot.index * root.stagger) / root.itemTime))
				readonly property real e: root.backOut(slot.t)
				// how close the drag points at this bubble, 0 … 1
				property real near: root.aiming ? Math.max(0, 1 - Math.abs(root.shortest(root.pointerAngle - slot.target)) / (360 / Math.max(2, root.count))) : 0
				readonly property real angle: (slot.target - (1 - slot.e) * root.shortest(slot.target - root.origin)) * Math.PI / 180
				readonly property real radius: (root.ringRadius * slot.e + 12 * slot.near) * (slot.popped ? 1 : 1 - root.leave)
				readonly property real size: root.bubble * (0.3 + 0.7 * slot.e) * (1 + 0.3 * slot.near) * (slot.popped ? 1 + 0.5 * root.leave : 1)

				x: Math.cos(slot.angle) * slot.radius
				y: Math.sin(slot.angle) * slot.radius
				z: slot.selected ? 1 : 0
				opacity: Math.min(1, slot.t * 3) * (1 - root.leave)

				Behavior on near {
					Anim {
						duration: Motion.micro
					}
				}

				RectangularShadow {
					anchors.fill: ball
					radius: ball.radius
					blur: 22
					offset.y: 6
					color: Theme.shadow
				}

				Rectangle {
					id: ball

					x: -slot.size / 2
					y: -slot.size / 2
					width: slot.size
					height: slot.size
					radius: slot.size / 2
					color: slot.selected ? Theme.primary : Theme.base

					Behavior on color {
						ColorAnim {}
					}

					Glyph {
						anchors.centerIn: parent
						icon: slot.modelData.icon
						size: 22 * (1 + 0.2 * slot.near)
						surface: "transparent"
						color: slot.selected ? Theme.onPrimary : Theme.text
					}
				}

				// a page behind it: filling while the drag rests there
				Ring {
					anchors.centerIn: ball
					width: slot.size + 12
					height: width
					visible: !!slot.modelData.opens
					value: slot.selected ? root.dwell : 0
					animated: false
					thickness: 3
					color: Theme.primary
					trackColor: Qt.alpha(Theme.text, 0.16)
				}

				Rectangle {
					id: tag

					readonly property real out: slot.size / 2 + 10

					x: Math.cos(slot.angle) * tag.out - width * (1 - Math.cos(slot.angle)) / 2
					y: Math.sin(slot.angle) * tag.out - height * (1 - Math.sin(slot.angle)) / 2
					width: caption.implicitWidth + 20
					height: 26
					radius: height / 2
					color: slot.selected ? Theme.primary : Qt.alpha(Theme.base, 0.94)
					opacity: 0.7 + 0.3 * slot.near

					Behavior on color {
						ColorAnim {}
					}

					StyledText {
						id: caption

						anchors.centerIn: parent
						text: slot.modelData.label
						tone: slot.selected ? Theme.onPrimary : Theme.text
						surface: "transparent"
						font.pixelSize: Theme.size.label
						font.weight: slot.selected ? Font.Bold : Font.Medium
					}
				}
			}
		}

		// the middle: where the drag started, and the way back out of a page
		Rectangle {
			id: hub

			readonly property bool page: DropCommands.page !== ""
			property real size: (hub.page ? 40 : 14) * root.reveal

			x: -hub.size / 2
			y: -hub.size / 2
			width: hub.size
			height: hub.size
			radius: hub.size / 2
			color: hub.page ? Theme.base : Theme.primary

			Behavior on size {
				SpatialAnim {
					duration: Motion.medium
					easing.bezierCurve: Motion.spatialFast
				}
			}
			Behavior on color {
				ColorAnim {}
			}

			Glyph {
				anchors.centerIn: parent
				visible: hub.page
				icon: "arrow_left"
				size: 18
				surface: "transparent"
				color: root.resting ? Theme.text : Theme.textMuted
			}
		}

		Ring {
			x: -width / 2
			y: -height / 2
			width: 52
			height: width
			visible: root.dwellOn === "back"
			value: root.dwell
			animated: false
			thickness: 3
			color: Theme.primary
			trackColor: "transparent"
		}
	}
}
