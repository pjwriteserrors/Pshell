pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Widgets
import qs.style.theme
import qs.core.services
import qs.style.widgets

// Where a chat's messages stand: a rounded surface that wears the backdrop
// (Backdrop.qml), with the chat on it and, when asked for, what picks the
// look of the chats over its upper right corner. Emoji thrown into the air
// (burst) fly over it.
Item {
	id: root

	default property alias content: holder.data
	// how far down the chat is, 0 … 1
	property real scroll: 1
	property bool live: true
	property bool picking: false
	// the backdrop is one: what stands on it keeps a little away from its edge
	readonly property bool dressed: Messages.backdrop.kind !== "none" && !backdrop.missing
	property real inset: root.dressed ? 12 : 0

	Behavior on inset {
		SpatialAnim {
			duration: Motion.medium
		}
	}

	onVisibleChanged: if (!root.visible) root.picking = false

	// a handful of an emoji is thrown up from a place on the stage and falls out of it
	function burst(emoji, x, y) {
		if (!root.visible || !root.live) return;
		// one sign is a code point with what hangs on it: a variation, a skin tone, a joined sign
		const text = String(emoji).trim();
		const signs = [];
		for (let at = 0; at < text.length;) {
			const point = text.codePointAt(at);
			const piece = String.fromCodePoint(point);
			at += piece.length;
			const hangs = point === 0xfe0f || point === 0x200d || (point >= 0x1f3fb && point <= 0x1f3ff);
			const joined = signs.length > 0 && signs[signs.length - 1].endsWith("\u200d");
			if (signs.length > 0 && (hangs || joined)) signs[signs.length - 1] += piece;
			else if (!/\s/.test(piece)) signs.push(piece);
		}
		if (signs.length === 0) return;
		for (let i = 0; i < 14; i += 1) {
			flying.createObject(sky, {
				text: signs[i % signs.length],
				fromX: x,
				fromY: y,
				drift: (Math.random() - 0.5) * 2 * Math.min(260, root.width * 0.4),
				rise: 90 + Math.random() * 170,
				fall: root.height - y + 60,
				size: 18 + Math.random() * 16,
				turn: (Math.random() - 0.5) * 140,
				wait: Math.random() * 120
			});
		}
	}

	Component {
		id: flying

		Text {
			id: piece

			property real fromX: 0
			property real fromY: 0
			property real drift: 0
			property real rise: 0
			property real fall: 0
			property real size: 24
			property real turn: 0
			property int wait: 0

			x: fromX - width / 2
			y: fromY - height / 2
			font.family: Theme.fontFamily
			font.pixelSize: size
			opacity: 0

			SequentialAnimation {
				running: true
				onFinished: piece.destroy()

				PauseAnimation {
					duration: piece.wait
				}
				PropertyAction {
					target: piece
					property: "opacity"
					value: 1
				}
				ParallelAnimation {
					NumberAnimation {
						target: piece
						property: "x"
						to: piece.fromX + piece.drift - piece.width / 2
						duration: 1500
						easing.type: Easing.OutCubic
					}
					NumberAnimation {
						target: piece
						property: "rotation"
						to: piece.turn
						duration: 1500
					}
					SequentialAnimation {
						NumberAnimation {
							target: piece
							property: "y"
							to: piece.fromY - piece.rise
							duration: 480
							easing.type: Easing.OutQuad
						}
						NumberAnimation {
							target: piece
							property: "y"
							to: piece.fromY + piece.fall
							duration: 1020
							easing.type: Easing.InQuad
						}
					}
					SequentialAnimation {
						PauseAnimation {
							duration: 1050
						}
						NumberAnimation {
							target: piece
							property: "opacity"
							to: 0
							duration: 450
						}
					}
				}
			}
		}
	}

	ClippingRectangle {
		anchors.fill: parent
		radius: Theme.radius.large
		color: "transparent"

		Backdrop {
			id: backdrop

			anchors.fill: parent
			scroll: root.scroll
			live: root.live && root.visible
		}
	}

	Item {
		id: holder

		anchors.fill: parent
	}

	// what flies over the chat
	Item {
		id: sky

		anchors.fill: parent
		clip: true
	}

	// a click beside the picker puts it away
	MouseArea {
		anchors.fill: parent
		enabled: root.picking
		acceptedButtons: Qt.AllButtons
		onPressed: root.picking = false
		onWheel: wheel => wheel.accepted = true
	}

	LookPicker {
		anchors.top: parent.top
		anchors.right: parent.right
		anchors.margins: 10
		open: root.picking
		onDone: root.picking = false
	}
}
