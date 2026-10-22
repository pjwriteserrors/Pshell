pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "../settings/mouse/Controls.js" as Controls

// What the swipes of a held mouse button do, in the middle of the focused
// screen: it comes after a moment of holding (a quick swipe never sees it),
// the dot follows the mouse, the way it heads for lights up, and the one that
// fires flashes as it all goes. Nothing to click – it only shows.
PanelWindow {
	id: root

	required property var modelData
	screen: modelData

	readonly property bool here: (Niri.workspaces.find(workspace => workspace.is_focused)?.output ?? root.modelData.name) === root.modelData.name
	property string control: ""
	property bool wanted: false
	property string firedWay: ""
	property real reveal: root.wanted ? 1 : 0

	readonly property real distance: Mouse.option("swipeDistance", 70)
	readonly property real nx: Mouse.moveControl === root.control ? Mouse.moveX / root.distance : 0
	readonly property real ny: Mouse.moveControl === root.control ? Mouse.moveY / root.distance : 0

	function way(trigger) {
		const rule = Mouse.effective(root.control, trigger, Mouse.focusApp);
		return rule ? Mouse.describe(rule.action, root.control) : null;
	}

	function hasSwipes(control) {
		return ["up", "down", "left", "right"].some(t => Mouse.effective(control, t, Mouse.focusApp));
	}

	Behavior on reveal {
		SpatialAnim {
			duration: root.wanted ? Motion.long : Motion.short
		}
	}

	Connections {
		target: Mouse

		function onPressedControl(control, down) {
			if (!Mouse.option("hud", true) || !root.here) return;
			if (down && root.hasSwipes(control)) {
				root.control = control;
				root.firedWay = "";
				showSoon.restart();
			} else if (!down && control === root.control) {
				showSoon.stop();
				root.wanted = false;
			}
		}
		function onFired(rule, control, trigger) {
			if (control !== root.control || !root.wanted) return;
			root.firedWay = trigger;
			goSoon.restart();
		}
	}

	Timer {
		id: showSoon

		interval: 230
		onTriggered: if (Mouse.pressed[root.control]) root.wanted = true
	}

	Timer {
		id: goSoon

		interval: 260
		onTriggered: root.wanted = false
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

		anchors.centerIn: parent
		width: 460
		height: 360
		opacity: Math.min(1, root.reveal)
		scale: 0.85 + 0.15 * root.reveal

		// a soft disc behind it all, so it reads on any window
		Rectangle {
			anchors.centerIn: parent
			width: 470
			height: 370
			radius: 185
			color: Qt.alpha(Theme.base, 0.72)
			border.width: 1
			border.color: Qt.alpha(Theme.text, 0.06)
			scale: 0.9 + 0.1 * root.reveal
		}

		// the middle: the button that is held
		Rectangle {
			id: middle

			anchors.centerIn: parent
			width: 86
			height: 86
			radius: 43
			color: Qt.alpha(Theme.base, 0.92)
			border.width: 1.5
			border.color: Qt.alpha(Theme.primary, 0.5)

			Glyph {
				anchors.centerIn: parent
				icon: Controls.byId(root.control)?.icon ?? "mouse"
				size: 30
				color: Theme.primary
			}

			// the mouse, as it moves
			Rectangle {
				width: 16
				height: 16
				radius: 8
				z: 3
				color: Theme.primary
				border.width: 3
				border.color: Qt.alpha(Theme.primary, 0.3)
				x: middle.width / 2 - 8 + Math.max(-1.3, Math.min(1.3, root.nx)) * 120
				y: middle.height / 2 - 8 + Math.max(-1.3, Math.min(1.3, root.ny)) * 105

				Behavior on x {
					SpatialAnim {
						duration: Motion.micro
					}
				}
				Behavior on y {
					SpatialAnim {
						duration: Motion.micro
					}
				}
			}
		}

		Repeater {
			model: [
				{ id: "up", dx: 0, dy: -1 }, { id: "down", dx: 0, dy: 1 },
				{ id: "left", dx: -1, dy: 0 }, { id: "right", dx: 1, dy: 0 }
			]

			delegate: Rectangle {
				id: pill

				required property var modelData
				required property int index
				// slides out from the middle, one after the other
				property real out: 0
				readonly property var info: root.way(pill.modelData.id)
				readonly property real toward: Math.max(0, Math.min(1, root.nx * pill.modelData.dx + root.ny * pill.modelData.dy))
				readonly property bool firing: root.firedWay === pill.modelData.id

				x: hud.width / 2 - width / 2 + pill.modelData.dx * 158 * pill.out
				y: hud.height / 2 - height / 2 + pill.modelData.dy * 128 * pill.out
				opacity: pill.out

				Connections {
					target: root

					function onWantedChanged() {
						if (root.wanted) {
							pill.out = 0;
							slide.restart();
						}
					}
				}

				SequentialAnimation {
					id: slide

					PauseAnimation {
						duration: pill.index * 35
					}
					NumberAnimation {
						target: pill
						property: "out"
						to: 1
						duration: Motion.long
						easing.type: Easing.BezierSpline
						easing.bezierCurve: Motion.spatial
					}
				}
				width: Math.max(120, label.implicitWidth + 58)
				height: 46
				radius: 23
				visible: pill.info !== null
				color: pill.firing ? Theme.primary : Qt.tint(Qt.alpha(Theme.base, 0.92), Qt.alpha(Theme.primary, pill.toward * 0.35))
				border.width: 1.5
				border.color: Qt.alpha(Theme.primary, 0.25 + pill.toward * 0.75)
				scale: pill.firing ? 1.15 : 1 + pill.toward * 0.08

				Behavior on scale {
					SpatialAnim {
						duration: Motion.short
					}
				}

				Row {
					anchors.centerIn: parent
					spacing: 8

					Glyph {
						anchors.verticalCenter: parent.verticalCenter
						icon: pill.info?.icon || ({ up: "arrow_up", down: "arrow_down", left: "arrow_left", right: "arrow_right" })[pill.modelData.id]
						size: 17
						color: pill.firing ? Theme.onPrimary : Theme.primary
					}

					StyledText {
						id: label

						anchors.verticalCenter: parent.verticalCenter
						text: pill.info?.label ?? ""
						tone: pill.firing ? Theme.onPrimary : Theme.text
						font.weight: Font.DemiBold
					}
				}
			}
		}
	}
}
