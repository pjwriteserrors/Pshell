pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import qs.style.theme
import qs.style.widgets
import qs.core.services

// One way a panel can open, playing over and over on a small bar: the same
// PopupMotion.shape() the real panels use, so what it shows is what you get.
Rectangle {
	id: root

	required property var entry
	property bool playing: true
	readonly property bool chosen: PopupMotion.style === root.entry.id
	property real t: 0
	property bool opening: true
	readonly property var open: PopupMotion.opening(root.entry.id)
	readonly property var close: PopupMotion.closing(root.entry.id)
	readonly property var form: PopupMotion.shape(root.entry.id, root.t, stage.width * 0.62, stage.height - bar.height - 10, 16, root.opening)

	signal picked

	radius: Theme.radius.medium
	color: root.chosen ? Theme.primaryContainer : Theme.layer1
	border.width: root.chosen ? 2 : 1
	border.color: root.chosen ? Theme.primary : Theme.outline

	Behavior on color {
		ColorAnim {}
	}

	SequentialAnimation {
		running: root.playing && root.visible
		loops: Animation.Infinite
		onStopped: root.t = 1

		ScriptAction {
			script: root.opening = true
		}
		NumberAnimation {
			target: root
			property: "t"
			from: 0
			to: 1
			duration: root.open.duration
			easing.type: root.open.type
			easing.bezierCurve: root.open.curve
			easing.amplitude: root.open.amplitude ?? 1
			easing.period: root.open.period ?? 0.3
			easing.overshoot: root.open.overshoot ?? 1.70158
		}
		PauseAnimation {
			duration: 1100
		}
		ScriptAction {
			script: root.opening = false
		}
		NumberAnimation {
			target: root
			property: "t"
			to: 0
			duration: root.close.duration
			easing.type: root.close.type
			easing.bezierCurve: root.close.curve
		}
		PauseAnimation {
			duration: 450
		}
	}

	Item {
		id: stage

		anchors.left: parent.left
		anchors.right: parent.right
		anchors.top: parent.top
		anchors.margins: 8
		height: 92
		clip: true

		// a sliver of desktop with its bar
		Rectangle {
			anchors.fill: parent
			radius: 6
			color: Qt.alpha(Theme.fg, 0.04)
		}

		Rectangle {
			id: bar

			width: parent.width
			height: 12
			radius: 6
			color: Qt.alpha(Theme.fg, 0.12)

			Rectangle {
				x: (parent.width - width) / 2
				y: 2
				width: 16
				height: 8
				radius: 4
				color: root.t > 0.02 ? Theme.primary : Qt.alpha(Theme.fg, 0.3)
			}
		}

		Item {
			id: body

			x: (parent.width - width) / 2
			y: bar.height
			width: root.form.w
			height: Math.max(0, root.form.h)
			scale: root.form.scale
			opacity: root.form.opacity
			transformOrigin: Item.Top

			Rectangle {
				id: panel

				anchors.fill: parent
				radius: 7
				color: Theme.layer3

				// square where it meets the bar
				Rectangle {
					width: parent.width
					height: Math.min(parent.height, 8)
					color: parent.color
				}
			}

			Item {
				id: inside

				readonly property bool effected: root.form.blur > 0.01 || root.form.wipe < 0.999

				anchors.fill: parent
				clip: true
				layer.enabled: inside.effected
				layer.effect: MultiEffect {
					blurEnabled: root.form.blur > 0.01
					blur: root.form.blur
					blurMax: 12
					maskEnabled: root.form.wipe < 0.999
					maskSource: curtain
					maskThresholdMin: 1 - root.form.wipe * 1.35
					maskSpreadAtMin: 0.35
				}

				Column {
					x: 8
					y: 8 + root.form.y * 0.5
					width: parent.width - 16
					spacing: 5
					opacity: root.form.co
					scale: root.form.cs
					transformOrigin: Item.Top

					Repeater {
						model: [0.55, 0.9, 0.75, 0.85]

						delegate: Rectangle {
							required property real modelData
							required property int index

							width: (parent.width) * modelData
							height: index === 0 ? 7 : 5
							radius: 3
							color: index === 0 ? Theme.primary : Qt.alpha(Theme.fg, 0.22)
						}
					}
				}
			}

			Rectangle {
				id: curtain

				anchors.fill: parent
				visible: false
				layer.enabled: inside.effected && root.form.wipe < 0.999
				gradient: Gradient {
					GradientStop {
						position: 0
						color: "white"
					}
					GradientStop {
						position: 1
						color: "transparent"
					}
				}
			}

			Item {
				anchors.fill: parent
				clip: true
				visible: root.form.sheen >= 0

				Rectangle {
					x: -parent.width * 0.7 + parent.width * 1.9 * Math.max(0, root.form.sheen)
					y: -parent.height * 0.25
					width: parent.width * 0.35
					height: parent.height * 1.5
					rotation: 18
					opacity: 0.3 * Math.sin(Math.PI * Math.max(0, root.form.sheen))
					gradient: Gradient {
						orientation: Gradient.Horizontal

						GradientStop {
							position: 0
							color: "transparent"
						}
						GradientStop {
							position: 0.5
							color: "white"
						}
						GradientStop {
							position: 1
							color: "transparent"
						}
					}
				}
			}
		}
	}

	Column {
		anchors.left: parent.left
		anchors.right: parent.right
		anchors.bottom: parent.bottom
		anchors.margins: 8
		spacing: 1

		StyledText {
			text: root.entry.label
			font.weight: Font.DemiBold
			tone: root.chosen ? Theme.primary : Theme.text
		}

		StyledText {
			width: parent.width
			text: root.entry.about
			elide: Text.ElideRight
			font.pixelSize: Theme.size.tiny
			tone: Theme.textSubtle
		}
	}

	MouseArea {
		anchors.fill: parent
		cursorShape: Qt.PointingHandCursor
		onClicked: root.picked()
	}
}
