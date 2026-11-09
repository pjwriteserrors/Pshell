pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.style.theme
import qs.style.widgets
import qs.core.services

// The mouse capture coming and going (core/services/MouseCapture.qml), on
// the screen of its window: four corners fly in from the screen's edges and
// close around the window, a ring pulses on it and a card with a lock
// springs up in its middle. Let go, the corners fly back out and the lock
// opens. Nothing here takes the pointer.
PanelWindow {
	id: root

	required property var modelData

	screen: root.modelData
	anchors {
		top: true
		bottom: true
		left: true
		right: true
	}
	exclusiveZone: 0
	color: "transparent"
	WlrLayershell.namespace: "shell-mouse-capture"
	WlrLayershell.layer: WlrLayer.Overlay
	WlrLayershell.exclusionMode: ExclusionMode.Ignore
	WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
	mask: Region {}

	property string kind: ""
	// the window in this screen's coordinates
	property rect cage: Qt.rect(0, 0, width, height)
	// 0: the corners at the screen's edges, 1: around the window
	property real close: 0
	property real shown: 0
	property real pulse: 0

	readonly property bool captured: root.kind === "captured"
	readonly property color tint: root.kind === "none" ? Theme.warning : Theme.primary

	function play() {
		const r = MouseCapture.flashRect;
		root.kind = MouseCapture.flashKind;
		root.cage = r ? Qt.rect(r.x - root.modelData.x, r.y - root.modelData.y, r.w, r.h) : Qt.rect(0, 0, root.width, root.height);
		show.restart();
	}

	Component.onCompleted: root.play()

	Connections {
		target: MouseCapture

		function onFlashesChanged() {
			root.play();
		}
	}

	SequentialAnimation {
		id: show

		ScriptAction {
			script: {
				root.close = root.captured ? 0 : 1;
				root.pulse = 0;
				card.wobble = 0;
			}
		}
		ParallelAnimation {
			NumberAnimation {
				target: root
				property: "shown"
				to: 1
				duration: Motion.short
			}
			NumberAnimation {
				target: root
				property: "close"
				to: root.captured ? 1 : (root.kind === "none" ? 1 : 0)
				duration: root.captured ? 520 : 460
				easing.type: root.captured ? Easing.OutBack : Easing.InCubic
				easing.overshoot: 1.3
			}
			SequentialAnimation {
				PauseAnimation {
					duration: root.captured ? 300 : 0
				}
				NumberAnimation {
					target: root
					property: "pulse"
					from: 0
					to: 1
					duration: 700
					easing.type: Easing.OutCubic
				}
			}
			SequentialAnimation {
				PauseAnimation {
					duration: 120
				}
				NumberAnimation {
					target: card
					property: "pop"
					from: 0
					to: 1
					duration: 460
					easing.type: Easing.OutBack
					easing.overshoot: 2.2
				}
			}
			// no window: the card shakes its head
			SequentialAnimation {
				PauseAnimation {
					duration: 300
				}
				NumberAnimation {
					target: card
					property: "wobble"
					from: 0
					to: root.kind === "none" ? 1 : 0
					duration: 520
				}
			}
		}
		PauseAnimation {
			duration: 1250
		}
		ParallelAnimation {
			NumberAnimation {
				target: root
				property: "shown"
				to: 0
				duration: 380
				easing.type: Easing.InCubic
			}
			NumberAnimation {
				target: card
				property: "pop"
				to: 0.85
				duration: 380
				easing.type: Easing.InCubic
			}
		}
	}

	Item {
		anchors.fill: parent
		opacity: root.shown

		// the window's outline, glowing up once
		Rectangle {
			readonly property real grow: 14 * (1 - root.pulse)

			visible: root.kind !== "none"
			x: root.cage.x - grow
			y: root.cage.y - grow
			width: root.cage.width + 2 * grow
			height: root.cage.height + 2 * grow
			radius: Theme.radius.large
			color: "transparent"
			border.width: 2
			border.color: root.tint
			opacity: root.captured ? 0.75 * Math.sin(Math.PI * root.pulse) : 0.5 * (1 - root.pulse)
		}

		// a dim wash outside the window while the corners close
		Rectangle {
			anchors.fill: parent
			visible: root.captured
			color: Theme.shadow
			opacity: 0.18 * root.close * (1 - root.pulse)
		}

		Repeater {
			model: [[0, 0], [1, 0], [0, 1], [1, 1]]

			delegate: Item {
				id: corner

				required property var modelData
				readonly property real sx: corner.modelData[0]
				readonly property real sy: corner.modelData[1]
				readonly property real inset: 24
				// from the screen's corner to the window's
				readonly property real fromX: corner.sx ? root.width - corner.inset : corner.inset
				readonly property real fromY: corner.sy ? root.height - corner.inset : corner.inset
				readonly property real toX: root.cage.x + corner.sx * root.cage.width
				readonly property real toY: root.cage.y + corner.sy * root.cage.height
				readonly property real arm: 44 + 36 * Math.max(0, 1 - Math.abs(root.close - 1) * 3)

				x: corner.fromX + (corner.toX - corner.fromX) * root.close
				y: corner.fromY + (corner.toY - corner.fromY) * root.close
				rotation: (1 - root.close) * (corner.sx === corner.sy ? -25 : 25)
				opacity: root.kind === "none" ? 0.5 : 1

				Repeater {
					// a wide soft stroke under the sharp one: the glow
					model: [{ w: 16, o: 0.2 }, { w: 6, o: 1 }]

					delegate: Item {
						id: stroke

						required property var modelData

						Rectangle {
							x: corner.sx ? -corner.arm : -stroke.modelData.w / 2
							y: -stroke.modelData.w / 2
							width: corner.arm + stroke.modelData.w / 2
							height: stroke.modelData.w
							radius: height / 2
							color: root.tint
							opacity: stroke.modelData.o
						}

						Rectangle {
							x: -stroke.modelData.w / 2
							y: corner.sy ? -corner.arm : -stroke.modelData.w / 2
							width: stroke.modelData.w
							height: corner.arm + stroke.modelData.w / 2
							radius: width / 2
							color: root.tint
							opacity: stroke.modelData.o
						}
					}
				}
			}
		}

		Rectangle {
			id: card

			property real pop: 0
			property real wobble: 0

			x: Math.max(16, Math.min(root.width - width - 16, root.cage.x + root.cage.width / 2 - width / 2)) + 14 * Math.sin(card.wobble * Math.PI * 4) * (1 - card.wobble)
			y: Math.max(16, Math.min(root.height - height - 16, root.cage.y + root.cage.height / 2 - height / 2))
			width: row.implicitWidth + 44
			height: 92
			radius: height / 2
			color: Theme.layer3
			border.width: 1
			border.color: Qt.alpha(root.tint, 0.45)
			scale: 0.6 + 0.4 * card.pop
			opacity: Math.min(1, card.pop * 1.4)

			Row {
				id: row

				anchors.centerIn: parent
				spacing: 14

				Rectangle {
					id: badge

					anchors.verticalCenter: parent.verticalCenter
					width: 58
					height: 58
					radius: 29
					color: Qt.alpha(root.tint, 0.18)

					// a ring sent out from the lock
					Rectangle {
						anchors.centerIn: parent
						width: parent.width * (1 + 0.9 * root.pulse)
						height: width
						radius: width / 2
						color: "transparent"
						border.width: 2
						border.color: root.tint
						opacity: 0.8 * (1 - root.pulse)
					}

					Glyph {
						anchors.centerIn: parent
						icon: root.kind === "none" ? "cursor_default_outline" : (root.captured ? "lock" : "lock_open_variant_outline")
						size: 30
						color: root.tint
						rotation: root.captured ? -18 * (1 - card.pop) : 0
					}
				}

				Column {
					anchors.verticalCenter: parent.verticalCenter
					spacing: 2

					StyledText {
						text: root.kind === "none" ? "No window to hold the mouse in" : (root.captured ? "Mouse captured" : "Mouse free")
						font.weight: Font.DemiBold
						font.pixelSize: Theme.size.heading + 2
					}

					StyledText {
						width: Math.min(implicitWidth, 520)
						elide: Text.ElideRight
						text: root.kind === "none" ? "Focus a window first" : (root.captured ? `${MouseCapture.scope === "screen" ? "On this screen" : MouseCapture.title || "In this window"} · the key again lets go` : "It goes anywhere again")
						tone: Theme.textMuted
						font.pixelSize: Theme.size.body
					}
				}
			}
		}
	}
}
