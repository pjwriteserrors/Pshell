pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Wayland
import qs.style.theme
import qs.core.services
import qs.style.widgets

// Radial menu at the pointer. The direction of the pointer picks an entry,
// so nothing has to be hit exactly; a bead slides along the ring to it and
// a click commits. Entries with a submenu carry a chevron and a dot on the
// rim. Opening a submenu fans its entries out of the one that was picked
// while the old ring flies past; going back pulls it in again. The hub goes
// one level up, a click beyond the labels closes.
PanelWindow {
	id: root

	readonly property bool shown: Radial.open
	property real reveal: root.shown ? 1 : 0
	property var targetScreen: Popups.primaryScreen

	readonly property real hubRadius: 46
	readonly property real innerRadius: 58
	readonly property real outerRadius: 126
	readonly property real midRadius: (root.innerRadius + root.outerRadius) / 2
	readonly property real thickness: root.outerRadius - root.innerRadius
	readonly property real labelRadius: root.outerRadius + 14
	// how far out the pointer still picks an entry
	readonly property real reach: root.outerRadius + 130

	// the pointer decides where the menu opens; until it reports, nothing shows
	property bool placed: false
	property real cx: 0
	property real cy: 0
	property real pointerX: 0
	property real pointerY: 0
	property real pointerAngle: -90
	property bool hubHovered: false
	property bool outside: false
	property bool byKeyboard: false
	property bool pressed: false

	// what the ring shows; follows Radial.items only while open
	property var items: []
	property string levelKey: ""
	property int levelDepth: 0
	property int index: -1
	readonly property var entry: root.index >= 0 && root.index < root.items.length ? root.items[root.index] : null

	// the bead
	property real beadAngle: -90
	property bool beadJump: false
	property real beadShown: root.entry ? 1 : 0
	readonly property real beadWidth: root.thickness - 14
	readonly property real beadSweep: {
		const step = 360 / Math.max(1, root.items.length);
		const cap = root.beadWidth / 2 / root.midRadius * 180 / Math.PI;
		return Math.max(0.5, Math.min(step, 80) - 6 - 2 * cap);
	}

	property real bloom: 0
	property real bump: 1
	property real hold: 0

	function angleOf(position, count) {
		return -90 + position * 360 / Math.max(1, count);
	}

	function shortest(delta) {
		return ((delta % 360) + 540) % 360 - 180;
	}

	// ease out with a soft overshoot, for the staggered entries
	function backOut(t) {
		const c = 1.4;
		return 1 + (c + 1) * Math.pow(t - 1, 3) + c * Math.pow(t - 1, 2);
	}

	function levelKeyNow() {
		return Radial.trail.map(parent => parent.id).join("/");
	}

	function place(x, y) {
		const marginX = Math.min(root.width / 2, root.outerRadius + 190);
		const marginY = Math.min(root.height / 2, root.outerRadius + 56);
		root.cx = Math.max(marginX, Math.min(root.width - marginX, x));
		root.cy = Math.max(marginY, Math.min(root.height - marginY, y));
		root.placed = true;
		fallbackPlace.stop();
		root.items = Radial.items;
		root.levelKey = root.levelKeyNow();
		root.levelDepth = Radial.trail.length;
		root.index = -1;
		ghost.items = [];
		live.fan = true;
		live.origin = -90;
		live.fromRadius = root.hubRadius * 0.4;
		enterAnim.restart();
		bloomAnim.restart();
	}

	function pointer(x, y) {
		if (!root.shown) return;
		root.pointerX = x;
		root.pointerY = y;
		if (!root.placed) root.place(x, y);
		root.byKeyboard = false;
		root.pick();
	}

	function pick() {
		const dx = root.pointerX - root.cx;
		const dy = root.pointerY - root.cy;
		const distance = Math.hypot(dx, dy);
		const count = root.items.length;
		root.hubHovered = distance <= root.hubRadius + 5;
		root.outside = distance > root.reach;
		if (distance > 1) root.pointerAngle = Math.atan2(dy, dx) * 180 / Math.PI;
		if (root.hubHovered || root.outside || count === 0) {
			root.index = -1;
			return;
		}
		const position = Math.round((((root.pointerAngle + 90) % 360) + 360) % 360 / (360 / count)) % count;
		root.index = Radial.usable(root.items[position]) ? position : -1;
	}

	function step(delta) {
		const count = root.items.length;
		root.byKeyboard = true;
		root.hubHovered = false;
		for (let i = 1, at = root.index; i <= count; i += 1) {
			at = ((at < 0 ? (delta > 0 ? -1 : 0) : at) + delta + count) % count;
			if (Radial.usable(root.items[at])) {
				root.index = at;
				return;
			}
		}
	}

	function press() {
		root.pressed = true;
		if (root.entry?.hold && !root.hubHovered) {
			releaseAnim.stop();
			holdAnim.restart();
		}
	}

	function release() {
		const wasPressed = root.pressed;
		root.pressed = false;
		if (!wasPressed) return;
		if (root.hubHovered) {
			Radial.back();
		} else if (root.entry?.hold) {
			if (root.hold < 1) {
				holdAnim.stop();
				releaseAnim.restart();
			}
		} else if (root.entry) {
			Radial.activate(root.entry);
		} else if (root.outside) {
			Popups.closeModal();
		}
	}

	// a level was entered or left: the old ring leaves, the new one arrives
	function sync() {
		if (!root.shown || !root.placed) return;
		const key = root.levelKeyNow();
		if (key === root.levelKey) {
			root.items = Radial.items;
			if (root.index >= root.items.length) root.index = -1;
			return;
		}
		const deeper = Radial.trail.length > root.levelDepth;
		ghost.items = root.items;
		ghost.outward = deeper;
		live.fan = deeper;
		live.origin = root.index >= 0 ? root.angleOf(root.index, root.items.length) : root.pointerAngle;
		live.fromRadius = deeper ? root.hubRadius * 0.4 : root.midRadius * 1.45;
		root.items = Radial.items;
		root.levelKey = key;
		root.levelDepth = Radial.trail.length;
		root.index = -1;
		holdAnim.stop();
		root.hold = 0;
		leaveAnim.restart();
		enterAnim.restart();
		bumpAnim.restart();
		if (!root.byKeyboard) root.pick();
	}

	onShownChanged: {
		holdAnim.stop();
		root.hold = 0;
		root.pressed = false;
		if (!root.shown) return;
		root.targetScreen = Popups.modalScreen || Popups.primaryScreen;
		root.placed = false;
		root.byKeyboard = false;
		Qt.callLater(() => keys.forceActiveFocus());
		if (area.containsMouse) root.pointer(area.mouseX, area.mouseY);
		else fallbackPlace.restart();
	}

	onIndexChanged: {
		if (root.hold > 0 && root.hold < 1) {
			holdAnim.stop();
			releaseAnim.restart();
		}
		if (root.index < 0) return;
		const target = root.angleOf(root.index, root.items.length);
		// a bead that was hidden appears in place instead of travelling
		root.beadJump = root.beadShown < 0.05;
		root.beadAngle += root.shortest(target - root.beadAngle);
		root.beadJump = false;
	}

	Connections {
		target: Radial

		function onItemsChanged() {
			root.sync();
		}
	}

	// the pointer is on another output or has not moved onto the surface yet
	Timer {
		id: fallbackPlace

		interval: 140
		onTriggered: if (root.shown && !root.placed) root.place(root.width / 2, root.height / 2)
	}

	Behavior on reveal {
		NumberAnimation {
			duration: root.shown ? Motion.long : Motion.medium
			easing.type: Easing.BezierSpline
			easing.bezierCurve: root.shown ? Motion.decel : Motion.accel
		}
	}

	Behavior on beadAngle {
		enabled: !root.beadJump

		SpatialAnim {
			duration: Motion.medium
		}
	}

	Behavior on beadShown {
		Anim {
			duration: Motion.short
		}
	}

	SpatialAnim {
		id: bloomAnim

		target: root
		property: "bloom"
		from: 0
		to: 1
		duration: Motion.extraLong
	}

	SequentialAnimation {
		id: bumpAnim

		Anim {
			target: root
			property: "bump"
			to: 0.94
			duration: Motion.micro
		}
		SpatialAnim {
			target: root
			property: "bump"
			to: 1
			easing.bezierCurve: Motion.spatialFast
		}
	}

	NumberAnimation {
		id: enterAnim

		target: live
		property: "enter"
		from: 0
		to: 1
		duration: live.span
	}

	NumberAnimation {
		id: leaveAnim

		target: ghost
		property: "leave"
		from: 0
		to: 1
		duration: Motion.medium
		easing.type: Easing.BezierSpline
		easing.bezierCurve: Motion.standard
	}

	NumberAnimation {
		id: holdAnim

		target: root
		property: "hold"
		to: 1
		duration: 750 * (1 - root.hold)
		onFinished: if (root.hold >= 1 && root.entry?.hold) Radial.activate(root.entry)
	}

	NumberAnimation {
		id: releaseAnim

		target: root
		property: "hold"
		to: 0
		duration: Motion.medium
		easing.type: Easing.OutCubic
	}

	screen: root.targetScreen
	visible: root.shown || root.reveal > 0.002
	color: "transparent"
	anchors {
		left: true
		right: true
		top: true
		bottom: true
	}
	exclusiveZone: 0
	WlrLayershell.namespace: "shell-radial"
	WlrLayershell.layer: WlrLayer.Overlay
	WlrLayershell.exclusionMode: ExclusionMode.Ignore
	WlrLayershell.keyboardFocus: root.shown ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

	// one ring of entries; `live` is the current level, `ghost` the one leaving
	component RingLayer: Item {
		id: layer

		property var items: []
		property bool current: false
		// linear clock of the arrival; every entry takes its own slice of it
		property real enter: 1
		property real leave: 0
		property bool fan: true
		property real origin: -90
		property real fromRadius: 0
		property bool outward: true
		readonly property int count: layer.items.length
		readonly property real stagger: 26
		readonly property real itemTime: 320
		readonly property real span: layer.itemTime + Math.max(0, layer.count - 1) * layer.stagger

		visible: layer.leave < 1
		opacity: 1 - layer.leave
		scale: layer.outward ? 1 + 0.3 * layer.leave : 1 - 0.5 * layer.leave

		Repeater {
			model: layer.items

			delegate: Item {
				id: slot

				required property var modelData
				required property int index
				readonly property bool selected: layer.current && root.index === slot.index
				readonly property bool usable: Radial.usable(slot.modelData)
				readonly property bool opens: slot.modelData.children !== undefined
				readonly property real target: root.angleOf(slot.index, layer.count)
				readonly property real t: Math.max(0, Math.min(1, (layer.enter * layer.span - slot.index * layer.stagger) / layer.itemTime))
				readonly property real e: root.backOut(slot.t)
				readonly property real angle: (slot.target - (layer.fan ? (1 - slot.e) * root.shortest(slot.target - layer.origin) : 0)) * Math.PI / 180
				readonly property real radius: layer.fromRadius + (root.midRadius - layer.fromRadius) * slot.e
				readonly property color accent: slot.modelData.danger ? Theme.danger : Theme.primary
				readonly property color onAccent: slot.modelData.danger ? Theme.bg : Theme.onPrimary
				readonly property color ink: slot.selected ? slot.onAccent : !slot.usable ? Theme.textFaint : slot.modelData.active ? Theme.primary : Theme.text

				opacity: Math.min(1, slot.t * 3)

				Glyph {
					x: Math.cos(slot.angle) * slot.radius - width / 2
					y: Math.sin(slot.angle) * slot.radius - height / 2
					icon: slot.modelData.icon
					size: 22
					surface: "transparent"
					color: slot.ink
					scale: (0.4 + 0.6 * slot.e) * (slot.selected ? (root.pressed ? 1.05 : 1.2) : 1)

					Behavior on scale {
						enabled: layer.enter >= 1

						SpatialAnim {
							duration: Motion.medium
							easing.bezierCurve: Motion.spatialFast
						}
					}

					// a toggle that is on
					Rectangle {
						anchors.horizontalCenter: parent.horizontalCenter
						anchors.top: parent.bottom
						anchors.topMargin: 4
						width: 5
						height: 5
						radius: 2.5
						visible: !!slot.modelData.active
						color: slot.selected ? slot.onAccent : Theme.primary
					}
				}

				// a submenu behind it: a dot on the rim
				Rectangle {
					readonly property real rim: slot.radius + root.thickness / 2 - 9

					x: Math.cos(slot.angle) * rim - width / 2
					y: Math.sin(slot.angle) * rim - height / 2
					width: 6
					height: 6
					radius: 3
					visible: slot.opens
					color: slot.selected ? slot.accent : slot.usable ? Theme.textSubtle : Theme.textFaint
					scale: slot.selected ? 0 : 1

					Behavior on scale {
						SpatialAnim {
							duration: Motion.short
						}
					}
				}

				Rectangle {
					id: tag

					property real reachOut: root.labelRadius + (slot.selected ? 6 : 0) - (1 - slot.e) * 26

					x: Math.cos(slot.angle) * tag.reachOut - width * (1 - Math.cos(slot.angle)) / 2
					y: Math.sin(slot.angle) * tag.reachOut - height * (1 - Math.sin(slot.angle)) / 2
					width: content.implicitWidth + 22
					height: 28
					radius: height / 2
					color: slot.selected ? slot.accent : Qt.alpha(Theme.base, 0.94)
					opacity: slot.usable ? 1 : 0.5

					Behavior on reachOut {
						enabled: layer.enter >= 1

						SpatialAnim {
							duration: Motion.medium
						}
					}
					Behavior on color {
						ColorAnim {}
					}

					Row {
						id: content

						anchors.centerIn: parent
						spacing: 2

						StyledText {
							anchors.verticalCenter: parent.verticalCenter
							width: Math.min(implicitWidth, 170)
							text: slot.modelData.label
							tone: slot.selected ? slot.onAccent : Theme.text
							surface: "transparent"
							font.pixelSize: Theme.size.label
							font.weight: slot.selected ? Font.Bold : Font.Medium
						}

						Glyph {
							anchors.verticalCenter: parent.verticalCenter
							visible: slot.opens
							icon: "chevron_right"
							size: 15
							surface: "transparent"
							color: slot.selected ? slot.onAccent : Theme.textMuted
						}
					}
				}
			}
		}
	}

	Rectangle {
		anchors.fill: parent
		color: Theme.scrim
		opacity: root.reveal * 0.6
	}

	MouseArea {
		id: area

		anchors.fill: parent
		hoverEnabled: true
		acceptedButtons: Qt.LeftButton | Qt.RightButton
		onEntered: root.pointer(area.mouseX, area.mouseY)
		onPositionChanged: mouse => root.pointer(mouse.x, mouse.y)
		onPressed: mouse => {
			root.pointer(mouse.x, mouse.y);
			if (mouse.button === Qt.LeftButton) root.press();
		}
		onReleased: mouse => {
			if (mouse.button === Qt.RightButton) Radial.back();
			else root.release();
		}
	}

	FocusScope {
		id: keys

		anchors.fill: parent
		focus: true

		Keys.onPressed: event => {
			event.accepted = true;
			switch (event.key) {
			case Qt.Key_Escape:
				Popups.closeModal();
				break;
			case Qt.Key_Backspace:
				Radial.back();
				break;
			case Qt.Key_Right:
			case Qt.Key_Down:
			case Qt.Key_Tab:
				root.step(1);
				break;
			case Qt.Key_Left:
			case Qt.Key_Up:
			case Qt.Key_Backtab:
				root.step(-1);
				break;
			case Qt.Key_Return:
			case Qt.Key_Enter:
			case Qt.Key_Space:
				root.byKeyboard = true;
				if (root.entry) Radial.activate(root.entry);
				break;
			default:
				if (event.key >= Qt.Key_0 && event.key <= Qt.Key_9) {
					const position = (event.key - Qt.Key_0 + 9) % 10;
					root.byKeyboard = true;
					if (position < root.items.length) Radial.activate(root.items[position]);
				} else {
					event.accepted = false;
				}
			}
		}

		Item {
			id: stage

			x: root.cx
			y: root.cy
			visible: root.placed
			opacity: root.reveal
			scale: 0.84 + 0.16 * root.reveal

			Shape {
				id: track

				readonly property real half: root.outerRadius + 4

				x: -track.half
				y: -track.half
				width: track.half * 2
				height: track.half * 2
				scale: (0.5 + 0.5 * root.bloom) * root.bump
				preferredRendererType: Shape.CurveRenderer

				ShapePath {
					strokeColor: Qt.alpha(Theme.base, 0.96)
					strokeWidth: root.thickness
					fillColor: "transparent"

					PathAngleArc {
						centerX: track.half
						centerY: track.half
						radiusX: root.midRadius
						radiusY: root.midRadius
						startAngle: 0
						sweepAngle: 360
					}
				}

				ShapePath {
					id: bead

					property real sweep: root.beadSweep
					property real thick: root.beadWidth * (root.pressed ? 0.88 : 1)

					strokeColor: Qt.alpha(root.entry?.danger ? Theme.danger : Theme.primary, root.beadShown)
					strokeWidth: bead.thick
					fillColor: "transparent"
					capStyle: ShapePath.RoundCap

					Behavior on sweep {
						SpatialAnim {
							duration: Motion.medium
						}
					}
					Behavior on thick {
						SpatialAnim {
							duration: Motion.short
							easing.bezierCurve: Motion.spatialFast
						}
					}
					Behavior on strokeColor {
						ColorAnim {}
					}

					PathAngleArc {
						centerX: track.half
						centerY: track.half
						radiusX: root.midRadius
						radiusY: root.midRadius
						startAngle: root.beadAngle - bead.sweep / 2
						sweepAngle: bead.sweep
					}
				}
			}

			RingLayer {
				id: ghost

				leave: 1
			}

			RingLayer {
				id: live

				items: root.items
				current: true
			}

			// follows the pointer around the hub
			Rectangle {
				readonly property real orbit: (root.hubRadius + root.innerRadius) / 2

				x: Math.cos(root.pointerAngle * Math.PI / 180) * orbit - width / 2
				y: Math.sin(root.pointerAngle * Math.PI / 180) * orbit - height / 2
				width: 6
				height: 6
				radius: 3
				color: root.entry?.danger ? Theme.danger : Theme.primary
				opacity: root.hubHovered || root.outside || root.byKeyboard ? 0 : 1
				scale: root.entry ? 1 : 0.6

				Behavior on opacity {
					Anim {
						duration: Motion.short
					}
				}
				Behavior on scale {
					SpatialAnim {
						duration: Motion.medium
					}
				}
			}

			Rectangle {
				id: hub

				x: -root.hubRadius
				y: -root.hubRadius
				width: root.hubRadius * 2
				height: root.hubRadius * 2
				radius: root.hubRadius
				color: root.hubHovered ? Theme.layer3 : Theme.base
				scale: (0.3 + 0.7 * root.bloom) * (root.hubHovered ? (root.pressed ? 0.94 : 1.07) : 1)

				Behavior on color {
					ColorAnim {}
				}
				Behavior on scale {
					enabled: root.bloom >= 1

					SpatialAnim {
						duration: Motion.medium
						easing.bezierCurve: Motion.spatialFast
					}
				}

				Column {
					anchors.centerIn: parent
					spacing: 3

					Glyph {
						anchors.horizontalCenter: parent.horizontalCenter
						icon: Radial.current ? "arrow_left" : "close"
						size: 20
						color: root.hubHovered ? Theme.text : Theme.textMuted
					}

					StyledText {
						anchors.horizontalCenter: parent.horizontalCenter
						width: Math.min(implicitWidth, root.hubRadius * 2 - 18)
						visible: text !== ""
						text: Radial.current?.label ?? ""
						tone: Theme.textMuted
						font.pixelSize: Theme.size.small
						font.weight: Font.Medium
					}
				}
			}

			Ring {
				x: -width / 2
				y: -height / 2
				width: (root.hubRadius + 7) * 2
				height: width
				visible: root.hold > 0
				value: root.hold
				animated: false
				thickness: 4
				color: Theme.danger
				trackColor: "transparent"
			}
		}
	}
}
