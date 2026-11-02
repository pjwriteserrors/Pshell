pragma ComponentBehavior: Bound

import QtQuick

// What moves in a town while one looks at it: the fountain, chimney smoke, mill
// sails, the banners over the stronghold. All in world units on the map's clock.
Item {
	id: root

	required property var city
	required property real clock
	required property string sprites
	required property real night

	Repeater {
		model: 10

		Image {
			id: drop

			required property int index
			readonly property real life: (root.clock * 0.9 + drop.index * 0.1) % 1
			readonly property real angle: drop.index * 2.4

			x: root.city.x + Math.cos(drop.angle) * drop.life * 5.5
			y: root.city.z - 7 + Math.sin(drop.angle) * drop.life * 2.5 + (drop.life - 0.45) * (drop.life - 0.45) * 26 - 5
			width: 1.6
			height: 1.6
			source: root.sprites ? `file://${root.sprites}/_drop.png` : ""
			opacity: 1 - drop.life * 0.6
		}
	}

	// the glow of what is enchanted
	Repeater {
		model: root.city.glows ?? []

		Image {
			id: glow

			required property var modelData
			required property int index
			readonly property real radiusNow: 16 + Math.sin(root.clock * 1.4 + glow.index) * 3

			x: glow.modelData[0] - glow.radiusNow
			y: glow.modelData[1] - glow.radiusNow
			width: glow.radiusNow * 2
			height: glow.radiusNow * 2
			source: root.sprites ? `file://${root.sprites}/_glow.png` : ""
			opacity: 0.35 + (Math.sin(root.clock * 1.4 + glow.index) + 1) * 0.2
		}
	}

	// fireflies in the groves, sparks over the forges, motes round the spires
	Repeater {
		model: root.city.kind === "grove" || root.city.kind === "isles" || root.city.kind === "crag" || root.city.kind === "arcane" ? 26 : 0

		Image {
			id: mote

			required property int index
			readonly property var anchorAt: root.city.spokes[mote.index % root.city.spokes.length]
			readonly property bool sparks: root.city.kind === "crag"
			readonly property real life: (root.clock * (mote.sparks ? 0.4 : 0.12) + mote.index * 0.137) % 1

			x: mote.anchorAt[0] + Math.sin(root.clock * 0.7 + mote.index * 2) * 8
			y: mote.anchorAt[1] - 4 - (mote.sparks ? mote.life * 22 : Math.cos(root.clock * 0.5 + mote.index) * 4 + 3)
			width: 2
			height: 2
			source: root.sprites ? `file://${root.sprites}/_${mote.sparks ? "spark" : root.city.kind === "grove" ? "firefly" : "mote"}.png` : ""
			opacity: mote.sparks ? 1 - mote.life : 0.4 + 0.6 * Math.abs(Math.sin(root.clock * 2.2 + mote.index))
		}
	}

	Repeater {
		model: (root.city.smoke ?? []).slice(0, 14)

		Image {
			id: puff

			required property var modelData
			required property int index
			readonly property real life: (root.clock * 0.16 + puff.index * 0.137) % 1

			x: puff.modelData[0] - 5 + Math.sin(puff.life * 5 + puff.index) * 2 + puff.life * 5
			y: puff.modelData[1] - 5 - puff.life * 18
			width: 10
			height: 10
			scale: 0.4 + puff.life * 1.5
			opacity: Math.min(puff.life * 7, 1) * (1 - puff.life) * 0.75
			source: root.sprites ? `file://${root.sprites}/_smoke.png` : ""
		}
	}

	Repeater {
		model: root.city.flag ? 2 : 0

		Image {
			id: flag

			required property int index

			x: root.city.flag[0] + (flag.index ? 11 : -11)
			y: root.city.flag[1] + flag.index * 2
			width: 8
			height: 5
			source: root.sprites ? `file://${root.sprites}/_flag.png` : ""
			transform: Matrix4x4 {
				matrix: Qt.matrix4x4(1, 0, 0, 0, Math.sin(root.clock * 2.6 + flag.index) * 0.18, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1)
			}
		}
	}
}
