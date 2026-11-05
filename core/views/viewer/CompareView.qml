pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "Recipe.js" as Recipe

// Up to four marked pictures side by side, each with its own changes,
// zoomed and moved together: the wheel zooms all of them at the same spot,
// a drag moves all. A click on a name opens that one.
Item {
	id: root

	readonly property var paths: Viewer.marked.slice(0, 4)
	// zoom over fitting, and the spot in the middle (0..1 of each picture)
	property real zoom: 1
	property real cx: 0.5
	property real cy: 0.5
	property var infos: ({})

	function load() {
		for (const path of root.paths) Viewer.infoOf(path, info => root.infos = Object.assign({}, root.infos, { [path]: info }));
	}

	onPathsChanged: root.load()
	Component.onCompleted: root.load()

	Grid {
		id: grid

		anchors.fill: parent
		anchors.margins: 12
		columns: root.paths.length <= 2 ? root.paths.length : 2
		spacing: 10

		Repeater {
			model: root.paths

			delegate: Item {
				id: cell

				required property string modelData
				readonly property var info: root.infos[modelData] ?? null
				readonly property var recipe: Viewer.recipeOf(modelData)

				width: (grid.width - grid.spacing * (grid.columns - 1)) / grid.columns
				height: root.paths.length > 2 ? (grid.height - grid.spacing) / 2 : grid.height
				clip: true

				Rectangle {
					anchors.fill: parent
					radius: Theme.radius.large
					color: Theme.layer1
				}

				Develop {
					id: pic

					readonly property real fit: Math.min(cell.width / Math.max(1, width), cell.height / Math.max(1, height))
					readonly property real s: fit * root.zoom

					visible: !!cell.info
					source: cell.recipe.retouch?.base || cell.modelData
					sourceWidth: cell.info?.width ?? 1
					sourceHeight: cell.info?.height ?? 1
					recipe: cell.recipe
					full: root.zoom > 1.2
					transformOrigin: Item.TopLeft
					scale: s
					x: cell.width / 2 - root.cx * width * s
					y: cell.height / 2 - root.cy * height * s
				}

				Rectangle {
					anchors.left: parent.left
					anchors.top: parent.top
					anchors.margins: 10
					width: name.implicitWidth + 20
					height: 28
					radius: 14
					color: Theme.glass

					StyledText {
						id: name

						anchors.centerIn: parent
						text: cell.modelData.slice(cell.modelData.lastIndexOf("/") + 1) + (Recipe.isPlain(cell.recipe) ? "" : "  · edited")
						font.pixelSize: Theme.size.small
					}

					MouseArea {
						anchors.fill: parent
						cursorShape: Qt.PointingHandCursor
						onClicked: {
							const i = Viewer.files.findIndex(f => f.path === cell.modelData);
							Viewer.setMode("view");
							if (i >= 0) Viewer.show(i);
							else Viewer.open(cell.modelData);
						}
					}
				}
			}
		}
	}

	MouseArea {
		anchors.fill: grid
		z: -1
		property real lastX: 0
		property real lastY: 0
		cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
		onPressed: event => {
			lastX = event.x;
			lastY = event.y;
		}
		onPositionChanged: event => {
			if (!pressed) return;
			const cellW = grid.width / grid.columns;
			root.cx = Math.max(0, Math.min(1, root.cx - (event.x - lastX) / (cellW * root.zoom)));
			root.cy = Math.max(0, Math.min(1, root.cy - (event.y - lastY) / (grid.height / (root.paths.length > 2 ? 2 : 1) * root.zoom)));
			lastX = event.x;
			lastY = event.y;
		}
		onWheel: wheel => {
			const factor = Math.pow(1.18, (wheel.angleDelta.y || wheel.pixelDelta.y / 2) / 120);
			root.zoom = Math.max(1, Math.min(16, root.zoom * factor));
			if (root.zoom === 1) {
				root.cx = 0.5;
				root.cy = 0.5;
			}
		}
		onDoubleClicked: {
			root.zoom = root.zoom > 1 ? 1 : 3;
			root.cx = 0.5;
			root.cy = 0.5;
		}
	}

	Behavior on zoom {
		NumberAnimation {
			duration: Motion.medium
			easing.type: Easing.BezierSpline
			easing.bezierCurve: Motion.spatial
		}
	}
}
