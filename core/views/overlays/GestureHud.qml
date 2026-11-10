pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Wayland
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "../settings/mouse/Controls.js" as Controls

// What the swipes of a held mouse button do, small in the middle of the
// focused screen. It only comes when the button is held still for a moment
// (a swipe made at once never sees it, it fires on the way); then the mouse
// only points, the arc it heads for fills, and letting go there runs it –
// back in the middle nothing. The daemon decides when (event "aim").
PanelWindow {
	id: root

	required property var modelData
	screen: modelData

	readonly property bool here: (Niri.workspaces.find(workspace => workspace.is_focused)?.output ?? root.modelData.name) === root.modelData.name
	property string control: ""
	property bool wanted: false
	property string firedWay: ""
	property real reveal: root.wanted ? 1 : 0

	readonly property bool tracking: Mouse.moveControl === root.control
	readonly property real nx: root.tracking ? Mouse.moveX / Math.max(1, Mouse.moveReach) : 0
	readonly property real ny: root.tracking ? Mouse.moveY / Math.max(1, Mouse.moveReach) : 0

	// the dot, eased toward the mouse every frame instead of re-animated per report
	property real dotX: 0
	property real dotY: 0

	readonly property var ways: [
		{ id: "up", dx: 0, dy: -1, angle: -90 },
		{ id: "right", dx: 1, dy: 0, angle: 0 },
		{ id: "down", dx: 0, dy: 1, angle: 90 },
		{ id: "left", dx: -1, dy: 0, angle: 180 }
	]

	function way(trigger) {
		const rule = Mouse.effective(root.control, trigger, Mouse.focusApp);
		return rule ? Mouse.describe(rule.action, root.control) : null;
	}

	function hasSwipes(control) {
		return ["up", "down", "left", "right"].some(t => Mouse.effective(control, t, Mouse.focusApp));
	}

	// 0..1 along one way; only the axis the mouse mostly goes counts
	function toward(entry) {
		const along = root.nx * entry.dx + root.ny * entry.dy;
		const across = Math.abs(entry.dx !== 0 ? root.ny : root.nx);
		return along > across ? Math.max(0, Math.min(1, along)) : 0;
	}

	readonly property var heading: {
		if (root.firedWay !== "") return root.ways.find(entry => entry.id === root.firedWay) ?? null;
		let best = null, value = 0.99;
		for (const entry of root.ways) {
			const t = root.toward(entry);
			if (t > value && root.way(entry.id)) {
				best = entry;
				value = t;
			}
		}
		return best;
	}
	readonly property var headingInfo: root.heading ? root.way(root.heading.id) : null

	Behavior on reveal {
		Anim {
			duration: root.wanted ? Motion.short : Motion.micro
		}
	}

	Connections {
		target: Mouse

		function onPressedControl(control, down) {
			if (!Mouse.option("hud", true) || !root.here) return;
			if (down && root.hasSwipes(control)) {
				root.control = control;
				root.firedWay = "";
				root.dotX = 0;
				root.dotY = 0;
				goSoon.stop();
				root.wanted = false;
			} else if (!down && control === root.control && root.wanted) {
				// the swipe it pointed at fires right after the release
				goSoon.restart();
			}
		}
		function onAiming(control) {
			if (!Mouse.option("hud", true) || !root.here || control !== root.control) return;
			root.wanted = true;
		}
		function onFired(rule, control, trigger) {
			if (control !== root.control || !root.wanted) return;
			root.firedWay = trigger;
			goSoon.restart();
		}
	}

	Timer {
		id: goSoon

		interval: 220
		onTriggered: root.wanted = false
	}

	FrameAnimation {
		running: root.visible
		onTriggered: {
			const k = Math.min(1, frameTime * 22);
			root.dotX += (Math.max(-1, Math.min(1, root.nx)) - root.dotX) * k;
			root.dotY += (Math.max(-1, Math.min(1, root.ny)) - root.dotY) * k;
		}
	}

	anchors.top: true
	anchors.bottom: true
	anchors.left: true
	anchors.right: true
	exclusiveZone: 0
	color: "transparent"
	visible: root.reveal > 0.002
	WlrLayershell.namespace: "shell-gestures"
	WlrLayershell.layer: WlrLayer.Overlay
	WlrLayershell.exclusionMode: ExclusionMode.Ignore
	WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
	mask: Region {}

	Item {
		id: hud

		readonly property real size: 132
		readonly property real rim: 56
		readonly property real sweep: 58

		anchors.centerIn: parent
		width: hud.size
		height: hud.size
		opacity: root.reveal
		scale: 0.92 + 0.08 * root.reveal

		Rectangle {
			anchors.fill: parent
			radius: width / 2
			color: Qt.alpha(Theme.base, 0.88)
			border.width: 1
			border.color: Qt.alpha(Theme.text, 0.08)
		}

		Repeater {
			model: root.ways

			delegate: Item {
				id: slot

				required property var modelData
				readonly property var info: root.way(slot.modelData.id)
				readonly property bool fired: root.firedWay === slot.modelData.id
				readonly property real fill: slot.fired ? 1 : root.toward(slot.modelData)
				readonly property real rad: slot.modelData.angle * Math.PI / 180

				anchors.fill: parent
				visible: slot.info !== null

				Shape {
					anchors.fill: parent
					preferredRendererType: Shape.CurveRenderer

					ShapePath {
						strokeColor: Qt.alpha(Theme.text, 0.12)
						strokeWidth: 3
						fillColor: "transparent"
						capStyle: ShapePath.RoundCap

						PathAngleArc {
							centerX: hud.size / 2
							centerY: hud.size / 2
							radiusX: hud.rim
							radiusY: hud.rim
							startAngle: slot.modelData.angle - hud.sweep / 2
							sweepAngle: hud.sweep
						}
					}

					ShapePath {
						strokeColor: Qt.alpha(Theme.primary, slot.fill > 0.01 ? 1 : 0)
						strokeWidth: slot.fired ? 5 : 3
						fillColor: "transparent"
						capStyle: ShapePath.RoundCap

						PathAngleArc {
							centerX: hud.size / 2
							centerY: hud.size / 2
							radiusX: hud.rim
							radiusY: hud.rim
							startAngle: slot.modelData.angle - hud.sweep * slot.fill / 2
							sweepAngle: hud.sweep * slot.fill
						}
					}
				}

				Glyph {
					x: hud.size / 2 + Math.cos(slot.rad) * 34 - width / 2
					y: hud.size / 2 + Math.sin(slot.rad) * 34 - height / 2
					icon: slot.info?.icon || ({ up: "arrow_up", down: "arrow_down", left: "arrow_left", right: "arrow_right" })[slot.modelData.id]
					size: 18
					surface: "transparent"
					color: slot.fill > 0.99 ? Theme.primary : Theme.textMuted
					scale: 1 + 0.15 * slot.fill
				}
			}
		}

		// the held button, and the mouse as it moves
		Glyph {
			anchors.centerIn: parent
			icon: Controls.byId(root.control)?.icon ?? "mouse"
			size: 16
			surface: "transparent"
			color: Theme.textFaint
			opacity: 1 - Math.min(1, Math.hypot(root.dotX, root.dotY) * 3)
		}

		Rectangle {
			x: hud.size / 2 + root.dotX * 18 - width / 2
			y: hud.size / 2 + root.dotY * 18 - height / 2
			width: 8
			height: 8
			radius: 4
			color: Theme.primary
			opacity: Math.min(1, Math.hypot(root.dotX, root.dotY) * 4)
		}

		// what the way headed for does
		Rectangle {
			anchors.horizontalCenter: parent.horizontalCenter
			anchors.top: parent.bottom
			anchors.topMargin: 10
			width: label.implicitWidth + 24
			height: 28
			radius: height / 2
			color: root.firedWay !== "" ? Theme.primary : Qt.alpha(Theme.base, 0.88)
			opacity: root.headingInfo ? 1 : 0

			Behavior on opacity {
				Anim {
					duration: Motion.micro
				}
			}

			StyledText {
				id: label

				anchors.centerIn: parent
				text: root.headingInfo?.label ?? ""
				tone: root.firedWay !== "" ? Theme.onPrimary : Theme.text
				surface: "transparent"
				font.pixelSize: Theme.size.label
				font.weight: Font.DemiBold
			}
		}
	}
}
