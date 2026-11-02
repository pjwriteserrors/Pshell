pragma ComponentBehavior: Bound

import QtQuick
import qs.core.services

// What only shows while it goes on: bards while music plays, stone golems while
// agents work.
Item {
	id: root

	required property var world
	required property real clock
	required property string sprites

	readonly property var tavern: root.world?.spots?.tavern ?? root.world?.spots?.capital ?? [0, 0]
	readonly property var capital: root.world?.spots?.capital ?? [0, 0]

	Repeater {
		model: World.liveMusic ? 3 : 0

		Item {
			id: bard

			required property int index

			x: root.tavern[0] + (bard.index - 1) * 7
			y: root.tavern[1] + 9 + Math.abs(Math.sin(root.clock * 3 + bard.index)) * -1

			Image {
				x: -3
				y: -7
				width: 6
				height: 8
				source: root.sprites ? `file://${root.sprites}/person${bard.index + 2}.png` : ""
				sourceClipRect: Qt.rect(0, 0, 36, 48)
			}
			Text {
				readonly property real life: (root.clock * 0.4 + bard.index * 0.33) % 1

				x: Math.sin(life * 6) * 2
				y: -9 - life * 12
				opacity: 1 - life
				text: "♪"
				color: "#fff3d2"
				font.pixelSize: 5
			}
		}
	}

	Repeater {
		model: World.liveAgents ? Math.min(6, Object.keys(Agents.busy).length) : 0

		Item {
			id: golem

			required property int index
			readonly property real pace: root.clock * 0.25 + golem.index * 1.4

			x: root.capital[0] + Math.sin(golem.pace) * 26
			y: root.capital[1] + 26 + Math.cos(golem.pace * 0.7) * 8

			Image {
				x: -6
				y: -15
				width: 12
				height: 16
				source: root.sprites ? `file://${root.sprites}/_golem.png` : ""
				sourceClipRect: Math.sin(root.clock * 4 + golem.index) > 0 ? Qt.rect(0, 0, 72, 96) : Qt.rect(72, 0, 72, 96)
				mirror: Math.cos(golem.pace) < 0
			}
		}
	}
}
