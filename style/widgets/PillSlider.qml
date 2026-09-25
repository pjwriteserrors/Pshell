import QtQuick
import qs.style.theme

// Chunky slider where the fill *is* the handle. The track swells while the
// pointer is over it, a click glides the fill to the spot, dragging tracks
// the pointer 1:1 and the wheel nudges in steps. The leading glyph can act
// as its own button (e.g. mute). An optional label names what it controls.
Item {
	id: root

	property real value: 0
	property real stepSize: 0.05
	property string icon: ""
	property string label: ""
	property bool iconInteractive: false
	property bool dimmed: false
	property bool showValue: true
	property string valueText: `${Math.round(root.display * 100)}%`
	property color accent: Theme.primary

	signal moved(real value)
	signal iconClicked

	readonly property bool engaged: mouse.pressed || mouse.containsMouse || iconMouse.containsMouse
	property bool dragging: false
	property real dragValue: 0
	readonly property real display: Math.max(0, Math.min(1, root.dragging || mouse.pressed ? root.dragValue : root.value))
	property real visual: display

	Behavior on visual {
		enabled: !root.dragging
		Anim {
			duration: Motion.medium
			easing.bezierCurve: Motion.decel
		}
	}

	implicitWidth: 240
	implicitHeight: 40

	function valueAt(x) {
		const span = Math.max(1, track.width - track.height);
		return Math.max(0, Math.min(1, (x - track.height / 2) / span));
	}

	Rectangle {
		id: track

		anchors.left: parent.left
		anchors.right: parent.right
		anchors.verticalCenter: parent.verticalCenter
		height: root.engaged ? root.height : root.height - 6
		radius: height / 2
		color: Theme.layer2

		Behavior on height {
			SpatialAnim {
				duration: Motion.medium
			}
		}

		Rectangle {
			id: fill

			height: parent.height
			width: parent.height + (parent.width - parent.height) * root.visual
			radius: height / 2
			color: root.dimmed ? Theme.textSubtle : root.accent

			Behavior on color {
				ColorAnim {}
			}

			Rectangle {
				anchors.right: parent.right
				anchors.rightMargin: parent.height * 0.36
				anchors.verticalCenter: parent.verticalCenter
				visible: fill.width > parent.height * 1.6
				width: 3
				height: root.dragging ? parent.height * 0.56 : parent.height * 0.36
				radius: 1.5
				color: Qt.alpha(Theme.onPrimary, 0.72)

				Behavior on height {
					SpatialAnim {
						duration: Motion.short
					}
				}
			}
		}

		Glyph {
			x: (track.height - width) / 2
			anchors.verticalCenter: parent.verticalCenter
			visible: root.icon !== ""
			icon: root.icon
			size: Math.round(track.height * 0.46)
			color: root.dimmed ? Theme.bg : Theme.onPrimary
			surface: fill.color
			scale: iconMouse.pressed ? 0.8 : (iconMouse.containsMouse ? 1.12 : 1)

			Behavior on scale {
				SpatialAnim {
					duration: Motion.short
				}
			}
		}

		StyledText {
			id: labelText

			x: root.icon !== "" ? track.height * 0.92 : track.height * 0.42
			anchors.verticalCenter: parent.verticalCenter
			width: Math.min(implicitWidth, track.width - x - track.height * 1.6)
			visible: root.label !== ""
			text: root.label
			elide: Text.ElideRight
			font.pixelSize: Theme.size.label
			font.weight: Font.DemiBold
			tone: fill.width > labelText.x + labelText.width + 6 ? Theme.onPrimary : Theme.textMuted
			surface: fill.width > labelText.x + labelText.width + 6 ? fill.color : Theme.surfaceBehind(fill)

			Behavior on color {
				ColorAnim {}
			}
		}

		StyledText {
			anchors.right: parent.right
			anchors.rightMargin: track.height * 0.42
			anchors.verticalCenter: parent.verticalCenter
			visible: root.showValue
			text: root.valueText
			tabular: true
			font.pixelSize: Theme.size.label
			font.weight: root.dragging ? Font.Bold : Font.DemiBold
			tone: fill.width > track.width - track.height * 1.1 ? Theme.onPrimary : Theme.textMuted
			surface: fill.width > track.width - track.height * 1.1 ? fill.color : Theme.surfaceBehind(fill)
			scale: root.dragging ? 1.12 : 1

			Behavior on scale {
				SpatialAnim {
					duration: Motion.short
				}
			}
		}
	}

	MouseArea {
		id: mouse

		anchors.fill: parent
		hoverEnabled: true
		cursorShape: Qt.PointingHandCursor
		preventStealing: true

		onPressed: event => {
			root.dragging = false;
			root.dragValue = root.valueAt(event.x);
			root.moved(root.dragValue);
		}
		onPositionChanged: event => {
			if (!pressed)
				return;
			root.dragging = true;
			root.dragValue = root.valueAt(event.x);
			root.moved(root.dragValue);
		}
		onReleased: {
			root.dragging = false;
		}
		onWheel: wheel => {
			const direction = (wheel.angleDelta.y || -wheel.angleDelta.x) > 0 ? 1 : -1;
			root.moved(Math.max(0, Math.min(1, root.value + direction * root.stepSize)));
		}
	}

	MouseArea {
		id: iconMouse

		enabled: root.iconInteractive
		visible: root.iconInteractive
		x: 0
		y: (root.height - track.height) / 2
		width: track.height
		height: track.height
		hoverEnabled: true
		cursorShape: Qt.PointingHandCursor
		onClicked: root.iconClicked()
	}
}
