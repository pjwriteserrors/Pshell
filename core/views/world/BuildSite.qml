import QtQuick
import qs.core.services

// What the running timer is building, in world units: rises out of the ground
// behind its scaffold while two people work on it.
Item {
	id: root

	required property var site
	required property real progress
	required property real clock
	required property string sprites

	readonly property bool tree: root.site?.kind === "tree"

	x: (root.site?.x ?? 0) - (root.site?.ax ?? 0)
	y: (root.site?.z ?? 0) - (root.site?.ay ?? 0)
	width: root.site?.w ?? 0
	height: root.site?.h ?? 0

	Image {
		visible: !root.tree
		x: root.site ? root.site.ax - width / 2 : 0
		y: root.site ? root.site.ay - 14 : 0
		width: 30
		height: 26
		source: `file://${root.sprites}/_foundation.png`
	}

	Item {
		y: root.height * (1 - root.progress)
		width: root.width
		height: root.height * root.progress
		clip: !root.tree
		scale: root.tree ? Math.max(0.2, root.progress) : 1
		transformOrigin: Item.Bottom

		Image {
			y: root.tree ? 0 : -root.height * (1 - root.progress)
			width: root.width
			height: root.height
			source: root.site ? `file://${root.site.file}` : ""
			smooth: true
		}
	}

	Image {
		visible: !root.tree && root.progress < 0.97
		x: root.site ? root.site.ax - width / 2 : 0
		y: root.site ? root.site.ay - height + 2 : 0
		width: 26
		height: 22
		source: `file://${root.sprites}/_scaffold.png`
		opacity: 0.9
	}

	Repeater {
		model: root.tree ? 1 : 2

		Image {
			id: worker

			required property int index
			readonly property real pace: root.clock * 0.35 + worker.index * 2

			x: (root.site?.ax ?? 0) - 3 + Math.sin(worker.pace) * (9 + worker.index * 3)
			y: (root.site?.ay ?? 0) - 5 + worker.index * 2
			width: 6
			height: 8
			source: `file://${root.sprites}/person${(worker.index * 3) % 8}.png`
			sourceClipRect: Math.sin(root.clock * 7 + worker.index) > 0 ? Qt.rect(0, 0, 36, 48) : Qt.rect(36, 0, 36, 48)
		}
	}

	Repeater {
		model: root.tree ? 0 : 4

		Image {
			id: spark

			required property int index
			readonly property real life: (root.clock * 1.5 + spark.index * 0.27) % 1

			x: (root.site?.ax ?? 0) + (spark.index - 1.5) * 3 * spark.life
			y: (root.site?.ay ?? 0) - root.height * root.progress * 0.8 - spark.life * 4
			width: 1.8
			height: 1.8
			source: `file://${root.sprites}/_ember.png`
			opacity: 1 - spark.life
		}
	}
}
