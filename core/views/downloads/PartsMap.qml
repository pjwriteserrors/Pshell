pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.style.widgets

// An accelerated download's bar: the file in its parts, each filling from
// its own start as its connection brings it in. A part with a connection
// on it glows at its edge; when one is split, the halves slide apart.
// parts: [[from, to, how far, has a connection]] in shares of the file.
Item {
	id: root

	property var parts: []
	property bool running: false
	property color accent: Theme.primary
	readonly property int most: 48

	implicitHeight: 8

	// the track
	Rectangle {
		anchors.fill: parent
		radius: height / 2
		color: Qt.alpha(root.accent, 0.14)

		Behavior on color {
			ColorAnim {}
		}
	}

	Item {
		id: lane

		anchors.fill: parent

		Repeater {
			model: root.most

			delegate: Item {
				id: part

				required property int index
				readonly property var data_: index < root.parts.length ? root.parts[index] : null
				readonly property bool active: part.data_ !== null && part.data_[3] === 1 && root.running

				visible: part.data_ !== null
				x: (part.data_ ? part.data_[0] : 1) * lane.width
				width: Math.max(0, (part.data_ ? part.data_[1] - part.data_[0] : 0) * lane.width)
				height: lane.height

				Behavior on x {
					NumberAnimation {
						duration: 700
						easing.type: Easing.OutCubic
					}
				}
				Behavior on width {
					NumberAnimation {
						duration: 700
						easing.type: Easing.OutCubic
					}
				}

				Rectangle {
					id: done

					height: parent.height
					width: Math.max(0, Math.min(parent.width, (part.data_ ? part.data_[2] - part.data_[0] : 0) * lane.width))
					color: root.accent
					// the bar's round ends: the first part's start, the last one's end
					radius: 0
					topLeftRadius: part.data_ && part.data_[0] <= 0.0001 ? height / 2 : 1.5
					bottomLeftRadius: topLeftRadius
					topRightRadius: part.data_ && part.data_[1] >= 0.9999 && width >= part.width - 0.5 ? height / 2 : 1.5
					bottomRightRadius: topRightRadius

					Behavior on width {
						NumberAnimation {
							duration: 950
							easing.type: Easing.OutCubic
						}
					}
					Behavior on color {
						ColorAnim {}
					}
				}

				// where its connection is writing
				Rectangle {
					visible: part.active && done.width < part.width - 1
					x: Math.max(0, done.width - width)
					width: Math.min(14, done.width)
					height: parent.height
					opacity: glow.value
					gradient: Gradient {
						orientation: Gradient.Horizontal
						GradientStop { position: 0; color: Qt.alpha("white", 0) }
						GradientStop { position: 1; color: Qt.alpha("white", 0.65) }
					}

					QtObject {
						id: glow

						property real value: 1

						SequentialAnimation on value {
							running: part.active && root.visible
							loops: Animation.Infinite
							NumberAnimation { to: 0.35; duration: 520; easing.type: Easing.InOutSine }
							NumberAnimation { to: 1; duration: 520; easing.type: Easing.InOutSine }
						}
					}
				}

				// a hair between the parts
				Rectangle {
					visible: part.index > 0
					width: 1
					height: parent.height
					color: Theme.layer1
					opacity: 0.85
				}
			}
		}
	}
}
