pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "FileKinds.js" as Kinds

// A file as a row of the list: picture, name, when, how big, what. Like
// the cards it only draws what the view tells it.
Item {
	id: root

	required property int index
	required property string path
	required property string name
	required property bool dir
	required property bool link
	required property real size
	required property real mtime
	required property string mime
	required property bool hidden
	required property string thumb
	required property bool canThumb
	required property bool text
	required property string kind
	required property string folder

	property var view: null
	property var pane: null
	property bool showFolder: false
	property bool entering: false
	// the width of the columns after the name
	property real whenWidth: 150
	property real sizeWidth: 86
	property real kindWidth: 128

	readonly property bool hovered: root.index >= 0 && root.view?.hoveredIndex === root.index
	readonly property bool selected: {
		root.pane?.selectionTick;
		return root.pane?.isSelected(root.path) ?? false;
	}
	readonly property bool current: root.index >= 0 && !!root.view?.keyboard && root.pane?.current === root.index
	readonly property bool dropTarget: root.index >= 0 && root.view?.dropIndex === root.index
	readonly property bool cut: Files.cutPaths.length > 0 && Files.cutPaths.includes(root.path)
	readonly property bool renaming: root.pane?.renaming === root.path
	readonly property var tags: {
		FileLibrary.tagged;
		return FileLibrary.tagsOf(root.path);
	}
	readonly property Item nameArea: nameBox

	opacity: (root.cut ? 0.45 : 1) * (root.hidden ? 0.6 : 1)

	function ask() {
		if (root.dir) Files.checkPeek(root.path, "inode/directory", root.mtime);
	}

	onPathChanged: Qt.callLater(root.ask)
	onMtimeChanged: Qt.callLater(root.ask)

	Component.onCompleted: {
		root.ask();
		if (!root.entering) return;
		body.opacity = 0;
		body.x = -10;
		entrance.start();
	}


	SequentialAnimation {
		id: entrance

		PauseAnimation {
			duration: Math.max(0, Math.min(root.index, 30)) * 9
		}
		ParallelAnimation {
			NumberAnimation {
				target: body
				property: "opacity"
				to: 1
				duration: Motion.medium
			}
			NumberAnimation {
				target: body
				property: "x"
				to: 0
				duration: Motion.long
				easing.type: Easing.BezierSpline
				easing.bezierCurve: Motion.decel
			}
		}
	}

	Item {
		id: body

		width: root.width
		height: root.height

		Rectangle {
			anchors.fill: parent
			anchors.topMargin: 1
			anchors.bottomMargin: 1
			radius: Theme.radius.medium
			color: root.selected ? Qt.tint(Theme.base, Qt.alpha(Theme.primary, root.hovered ? 0.2 : 0.15))
				: root.dropTarget ? Qt.tint(Theme.base, Qt.alpha(Theme.primary, 0.12))
				: root.hovered ? Theme.layer1 : Qt.alpha(Theme.layer1, root.index % 2 === 1 ? 0.45 : 0)
			border.width: root.dropTarget || root.current ? 1.5 : 0
			border.color: root.dropTarget ? Theme.primary : Qt.alpha(Theme.primary, 0.6)

			Behavior on color {
				ColorAnim {}
			}
		}

		FileThumb {
			id: picture

			x: 10
			anchors.verticalCenter: parent.verticalCenter
			width: Math.round(root.height * 0.7)
			height: width
			compact: true
			radius: 6
			path: root.path
			name: root.name
			mime: root.mime
			dir: root.dir
			kind: root.kind
			thumb: root.thumb
			canThumb: root.canThumb
			isText: root.text
			bytes: root.size
			selected: root.selected
		}

		Item {
			id: nameBox

			anchors.left: picture.right
			anchors.leftMargin: 10
			anchors.right: tagRow.left
			anchors.rightMargin: 8
			anchors.verticalCenter: parent.verticalCenter
			height: parent.height

			Text {
				visible: !root.renaming
				anchors.left: parent.left
				anchors.right: parent.right
				anchors.verticalCenter: parent.verticalCenter
				anchors.verticalCenterOffset: root.showFolder ? -7 : 0
				text: root.name
				color: Theme.text
				font.family: Theme.fontFamily
				font.pixelSize: Theme.size.body
				font.weight: root.selected ? Font.DemiBold : Font.Normal
				elide: Text.ElideMiddle
			}

			Text {
				visible: root.showFolder && !root.renaming
				anchors.left: parent.left
				anchors.right: parent.right
				anchors.verticalCenter: parent.verticalCenter
				anchors.verticalCenterOffset: 8
				text: root.folder
				color: Theme.textSubtle
				font.family: Theme.fontFamily
				font.pixelSize: Theme.size.small
				elide: Text.ElideLeft
			}

			RenameField {
				visible: root.renaming
				active: root.renaming
				anchors.left: parent.left
				anchors.right: parent.right
				anchors.verticalCenter: parent.verticalCenter
				path: root.path
				name: root.name
				dir: root.dir
				pane: root.pane
				fontSize: Theme.size.body
			}
		}

		Row {
			id: tagRow

			anchors.right: whenText.left
			anchors.rightMargin: 10
			anchors.verticalCenter: parent.verticalCenter
			spacing: 3

			Marks {
				anchors.verticalCenter: parent.verticalCenter
				pane: root.pane
				path: root.path
				name: root.name
				compact: true
			}

			Repeater {
				model: root.tags.slice(0, 5)

				delegate: Rectangle {
					required property string modelData

					width: 9
					height: 9
					radius: 5
					color: FileLibrary.colorOf(FileLibrary.tagById(modelData)?.color ?? "primary")
				}
			}
		}

		Text {
			id: whenText

			anchors.right: sizeText.left
			anchors.verticalCenter: parent.verticalCenter
			width: root.whenWidth
			visible: root.whenWidth > 0
			text: Files.whenText(root.mtime)
			color: Theme.textMuted
			font.family: Theme.fontFamily
			font.pixelSize: Theme.size.label
			elide: Text.ElideRight
		}

		Text {
			id: sizeText

			anchors.right: kindText.left
			anchors.verticalCenter: parent.verticalCenter
			width: root.sizeWidth
			visible: root.sizeWidth > 0
			rightPadding: 16
			horizontalAlignment: Text.AlignRight
			text: root.dir ? root.count : Files.sizeText(root.size)
			color: Theme.textMuted
			font.family: Theme.fontFamily
			font.pixelSize: Theme.size.label
			font.features: { "tnum": 1 }
		}

		Text {
			id: kindText

			anchors.right: parent.right
			anchors.rightMargin: 10
			anchors.verticalCenter: parent.verticalCenter
			width: root.kindWidth
			visible: root.kindWidth > 0
			text: root.dir ? "Folder" : (Kinds.badgeOf({ dir: false, name: root.name }) || Kinds.kindLabel(root.kind).replace(/s$/, ""))
			color: Theme.textSubtle
			font.family: Theme.fontFamily
			font.pixelSize: Theme.size.label
			elide: Text.ElideRight
		}
	}

	readonly property string count: {
		Files.peekTick;
		const count = Files.peekOf(root.path)?.count;
		return count === undefined || count < 0 ? "—" : `${count} item${count === 1 ? "" : "s"}`;
	}
}
