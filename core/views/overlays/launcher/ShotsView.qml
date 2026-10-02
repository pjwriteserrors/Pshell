pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Widgets
import qs.style.theme
import qs.core.services
import qs.style.widgets

// Launcher >shots: the captures of this session (Screenshot.shots, tmpfs).
// Enter / click copies; hover actions pin, edit, save and delete.
// Keys: arrows move, Delete removes, Ctrl+P pin, Ctrl+E edit, Ctrl+S save.
Item {
	id: root

	property string argument: ""
	property bool active: false
	property int currentIndex: 0
	readonly property var shots: Screenshot.shots
	readonly property int columns: 4

	signal closeRequested

	onActiveChanged: if (root.active) root.currentIndex = 0
	onShotsChanged: root.currentIndex = Math.max(0, Math.min(root.currentIndex, root.shots.length - 1))

	// up/down from the launcher move by rows
	function move(delta) {
		root.select(root.currentIndex + delta * root.columns);
	}

	function select(index) {
		if (root.shots.length === 0) return;
		root.currentIndex = Math.max(0, Math.min(root.shots.length - 1, index));
		grid.positionViewAtIndex(root.currentIndex, GridView.Contain);
	}

	function handleKey(event) {
		const shot = root.shots[root.currentIndex];
		const ctrl = event.modifiers & Qt.ControlModifier;
		if (event.key === Qt.Key_Left) root.select(root.currentIndex - 1);
		else if (event.key === Qt.Key_Right) root.select(root.currentIndex + 1);
		else if (event.key === Qt.Key_Delete && shot) Screenshot.forgetShot(shot.id);
		else if (ctrl && event.key === Qt.Key_P && shot) root.run("pin", shot);
		else if (ctrl && event.key === Qt.Key_E && shot) root.run("edit", shot);
		else if (ctrl && event.key === Qt.Key_S && shot) root.run("save", shot);
		else return false;
		return true;
	}

	function cancel() {
		return false;
	}

	function activate(modifiers) {
		const shot = root.shots[root.currentIndex];
		if (shot) root.run("copy", shot);
	}

	function run(action, shot) {
		if (!shot) return;
		const path = shot.path;
		switch (action) {
		case "copy":
			root.closeRequested();
			Screenshot.copyShot(path);
			break;
		case "pin":
			if (!Plugins.on("pins")) return;
			root.closeRequested();
			Screenshot.pinShot(path);
			break;
		case "edit":
			root.closeRequested();
			// once the launcher has left, the editor takes the keyboard
			editLater.path = path;
			editLater.restart();
			break;
		case "save":
			Screenshot.saveShot(path);
			break;
		case "delete":
			Screenshot.forgetShot(shot.id);
			break;
		}
	}

	Timer {
		id: editLater

		property string path: ""
		interval: Motion.medium
		onTriggered: Screenshot.editShot(editLater.path)
	}

	EmptyState {
		anchors.centerIn: parent
		visible: root.shots.length === 0
		icon: "image_multiple"
		title: "No screenshots yet"
	}

	GridView {
		id: grid

		anchors.fill: parent
		visible: root.shots.length > 0
		clip: true
		model: root.shots
		cellWidth: Math.floor(width / root.columns)
		cellHeight: Math.round(grid.cellWidth * 0.72)
		currentIndex: root.currentIndex
		boundsBehavior: Flickable.StopAtBounds
		ScrollBar.vertical: ThinScrollBar {}

		delegate: Item {
			id: cell

			required property var modelData
			required property int index
			readonly property bool selected: root.currentIndex === cell.index
			readonly property bool hovered: cellHover.hovered

			width: grid.cellWidth
			height: grid.cellHeight

			HoverHandler {
				id: cellHover

				onHoveredChanged: if (cellHover.hovered) root.currentIndex = cell.index
			}

			ClippingRectangle {
				id: card

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
					anchors.margins: 6
					source: Screenshot.fileUrl(cell.modelData.path)
					sourceSize.width: 360
					asynchronous: true
					cache: false
					fillMode: Image.PreserveAspectFit
					smooth: true
					mipmap: true
				}

				MouseArea {
					id: cardArea

					anchors.fill: parent
					cursorShape: Qt.PointingHandCursor
					onClicked: root.run("copy", cell.modelData)
				}

				Row {
					anchors.right: parent.right
					anchors.bottom: parent.bottom
					anchors.margins: 6
					spacing: 2
					opacity: cell.hovered || cell.selected ? 1 : 0

					Behavior on opacity {
						Anim {
							duration: Motion.short
						}
					}

					Repeater {
						model: [
							{ action: "pin", icon: "pin_outline" },
							{ action: "edit", icon: "pencil" },
							{ action: "save", icon: "content_save" },
							{ action: "delete", icon: "delete_outline" }
						].filter(entry => entry.action !== "pin" || Plugins.on("pins"))

						delegate: IconButton {
							required property var modelData

							width: 28
							height: 28
							variant: "tonal"
							icon: modelData.icon
							iconColor: modelData.action === "delete" ? Theme.danger : Theme.text
							onClicked: root.run(modelData.action, cell.modelData)
						}
					}
				}
			}
		}
	}
}
