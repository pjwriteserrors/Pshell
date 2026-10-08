pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.style.widgets

// A strip of columns where the focus walks right: the view follows the way
// center-focused-column says (never, on-overflow, always).
Item {
	id: root

	property string mode: "never"
	property bool playing: true
	property int at: 0
	readonly property var widths: [0.45, 0.3, 0.55, 0.35]
	readonly property real gap: 4
	readonly property var xs: {
		const out = [];
		let x = root.gap;
		for (const w of root.widths) {
			out.push(x);
			x += w * root.width + root.gap;
		}
		return out;
	}
	property real view: 0

	// where the view goes when the focus moves to `index`
	function follow(index) {
		const x = root.xs[index];
		const w = root.widths[index] * root.width;
		const center = x + w / 2 - root.width / 2;
		if (root.mode === "always") return center;
		if (index === 0) return 0;
		if (root.mode === "on-overflow") {
			const px = root.xs[index - 1];
			if (x + w - px + root.gap * 2 > root.width) return center;
		}
		let v = root.view;
		if (x - root.gap < v) v = x - root.gap;
		if (x + w + root.gap > v + root.width) v = x + w + root.gap - root.width;
		return v;
	}

	onModeChanged: root.view = root.follow(root.at)
	Component.onCompleted: root.view = root.follow(root.at)

	Timer {
		interval: 1300
		repeat: true
		running: root.playing && root.visible
		onTriggered: {
			root.at = (root.at + 1) % root.widths.length;
			root.view = root.follow(root.at);
		}
	}

	Rectangle {
		anchors.fill: parent
		radius: 8
		color: Qt.alpha(Theme.text, 0.05)
		border.width: 1
		border.color: Theme.outline
	}

	Item {
		anchors.fill: parent
		clip: true

		Item {
			x: -strip.shown
			height: parent.height

			QtObject {
				id: strip

				property real shown: root.view

				Behavior on shown {
					SpatialAnim {
						duration: Motion.long
					}
				}
			}

			Repeater {
				model: root.widths.length

				delegate: Rectangle {
					required property int index

					x: root.xs[index]
					y: root.gap
					width: root.widths[index] * root.width
					height: root.height - root.gap * 2
					radius: 5
					color: index === root.at ? Theme.primary : Theme.layer3
					opacity: index === root.at ? 0.85 : 1

					Behavior on color {
						ColorAnim {}
					}
				}
			}
		}
	}
}
