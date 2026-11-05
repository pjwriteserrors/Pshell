pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Quickshell.Widgets
import qs.style.theme
import qs.core.services
import qs.style.widgets

// Launcher >pictures (>img): the pictures opened lately in the picture
// viewer and this session's screenshots, the words typed after it filter
// them by name. Enter / click opens; hover actions adjust, crop and draw.
// Ctrl+V opens the clipboard's picture. Keys: arrows move, Ctrl+E adjusts.
Item {
	id: root

	property string argument: ""
	property bool active: false
	property int currentIndex: 0
	readonly property int columns: 4
	readonly property var pictures: {
		const words = root.argument.trim().toLowerCase().split(/\s+/).filter(w => w);
		const seen = {};
		const all = Viewer.recent.concat(Screenshot.shots.map(shot => shot.path)).filter(p => {
			if (seen[p]) return false;
			seen[p] = true;
			return true;
		});
		return all.filter(p => words.every(w => p.toLowerCase().includes(w)));
	}

	signal closeRequested

	onActiveChanged: if (root.active) root.currentIndex = 0
	onPicturesChanged: root.currentIndex = Math.max(0, Math.min(root.currentIndex, root.pictures.length - 1))

	function move(delta) {
		root.select(root.currentIndex + delta * root.columns);
	}

	function select(index) {
		if (root.pictures.length === 0) return;
		root.currentIndex = Math.max(0, Math.min(root.pictures.length - 1, index));
		grid.positionViewAtIndex(root.currentIndex, GridView.Contain);
	}

	function handleKey(event) {
		const path = root.pictures[root.currentIndex];
		const ctrl = event.modifiers & Qt.ControlModifier;
		if (event.key === Qt.Key_Left) root.select(root.currentIndex - 1);
		else if (event.key === Qt.Key_Right) root.select(root.currentIndex + 1);
		else if (ctrl && event.key === Qt.Key_E && path) root.run("adjust", path);
		else if (ctrl && event.key === Qt.Key_V) root.run("paste", "");
		else return false;
		return true;
	}

	function cancel() {
		return false;
	}

	function activate(modifiers) {
		const path = root.pictures[root.currentIndex];
		if (path) root.run("view", path);
	}

	function run(mode, path) {
		root.closeRequested();
		// once the launcher has left, the window takes the keyboard
		later.mode = mode;
		later.path = path;
		later.restart();
	}

	Timer {
		id: later

		property string mode: ""
		property string path: ""
		interval: Motion.medium
		onTriggered: later.mode === "paste" ? Viewer.paste() : Viewer.open(later.path, { mode: later.mode, list: root.pictures })
	}

	EmptyState {
		anchors.centerIn: parent
		visible: root.pictures.length === 0
		icon: "image_edit_outline"
		title: root.argument ? "No picture by that name" : "No pictures opened yet"
	}

	GridView {
		id: grid

		anchors.fill: parent
		visible: root.pictures.length > 0
		clip: true
		model: root.pictures
		cellWidth: Math.floor(width / root.columns)
		cellHeight: Math.round(grid.cellWidth * 0.78)
		currentIndex: root.currentIndex
		boundsBehavior: Flickable.StopAtBounds
		ScrollBar.vertical: ThinScrollBar {}

		delegate: Item {
			id: cell

			required property string modelData
			required property int index
			readonly property bool selected: root.currentIndex === cell.index
			readonly property bool hovered: cellHover.hovered

			width: grid.cellWidth
			height: grid.cellHeight

			HoverHandler {
				id: cellHover

				onPointChanged: if (cellHover.hovered && Pointer.moved(cell, point.position.x, point.position.y)) root.currentIndex = cell.index
			}

			ClippingRectangle {
				anchors.fill: parent
				anchors.margins: 5
				radius: Theme.radius.medium
				color: Theme.layer1
				border.width: cell.selected ? 2 : 0
				border.color: Theme.primary
				scale: cardArea.pressed ? 0.97 : 1

				Behavior on scale {
					SpatialAnim {
						duration: Motion.short
					}
				}

				Image {
					anchors.fill: parent
					anchors.bottomMargin: 22
					source: "file://" + cell.modelData
					sourceSize.width: 360
					asynchronous: true
					autoTransform: true
					cache: false
					fillMode: Image.PreserveAspectCrop
					smooth: true
				}

				StyledText {
					anchors.left: parent.left
					anchors.right: parent.right
					anchors.bottom: parent.bottom
					anchors.margins: 6
					text: cell.modelData.slice(cell.modelData.lastIndexOf("/") + 1)
					elide: Text.ElideMiddle
					font.pixelSize: Theme.size.small
					tone: Theme.textMuted
				}

				MouseArea {
					id: cardArea

					anchors.fill: parent
					cursorShape: Qt.PointingHandCursor
					onClicked: root.run("view", cell.modelData)
				}

				Row {
					anchors.right: parent.right
					anchors.top: parent.top
					anchors.margins: 6
					spacing: 2
					opacity: cell.hovered || cell.selected ? 1 : 0

					Behavior on opacity {
						Anim {
							duration: Motion.short
						}
					}

					Repeater {
						model: [{ mode: "adjust", icon: "tune_variant" }, { mode: "crop", icon: "crop_rotate" }, { mode: "markup", icon: "draw" }]

						delegate: IconButton {
							required property var modelData

							width: 28
							height: 28
							variant: "tonal"
							icon: modelData.icon
							onClicked: root.run(modelData.mode, cell.modelData)
						}
					}
				}
			}
		}
	}
}
