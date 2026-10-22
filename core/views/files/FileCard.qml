pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.style.widgets
import qs.core.services

// A file as a card of the grid: its picture, its name and a line about it.
// The view does the pointer work (one handler for all cards); a card only
// shows what it is told: hovered, picked, under a drop, being renamed.
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
	// a search shows where each one is
	property bool showFolder: false
	property bool entering: false

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
	readonly property real art: Math.round(root.width * 0.74)
	// a note stuck to it shows instead of size and date
	readonly property string note: {
		FileLibrary.notes;
		return FileLibrary.noteOf(root.path);
	}
	// where the name field is, for the view to let clicks through while renaming
	readonly property Item nameArea: nameBox

	opacity: (root.cut ? 0.45 : 1) * (root.hidden ? 0.6 : 1)

	Behavior on opacity {
		Anim {}
	}

	// cards that come with a new folder rise in one after another
	Component.onCompleted: {
		if (!root.entering) return;
		root.opacity = 0;
		body.scale = 0.9;
		body.y = 14;
		entrance.start();
	}


	SequentialAnimation {
		id: entrance

		PauseAnimation {
			duration: Math.max(0, Math.min(root.index, 28)) * 11
		}
		ParallelAnimation {
			NumberAnimation {
				target: root
				property: "opacity"
				to: (root.cut ? 0.45 : 1) * (root.hidden ? 0.6 : 1)
				duration: Motion.medium
				easing.type: Easing.BezierSpline
				easing.bezierCurve: Motion.standard
			}
			NumberAnimation {
				target: body
				property: "scale"
				to: 1
				duration: Motion.long
				easing.type: Easing.BezierSpline
				easing.bezierCurve: Motion.spatial
			}
			NumberAnimation {
				target: body
				property: "y"
				to: 0
				duration: Motion.long
				easing.type: Easing.BezierSpline
				easing.bezierCurve: Motion.decel
			}
		}
		ScriptAction {
			script: root.opacity = Qt.binding(() => (root.cut ? 0.45 : 1) * (root.hidden ? 0.6 : 1))
		}
	}

	Item {
		id: body

		width: root.width
		height: root.height
		transformOrigin: Item.Center

		Rectangle {
			id: plate

			anchors.fill: parent
			anchors.margins: 4
			radius: Theme.radius.large
			color: root.selected ? Qt.tint(Theme.base, Qt.alpha(Theme.primary, root.hovered ? 0.2 : 0.15))
				: root.dropTarget ? Qt.tint(Theme.base, Qt.alpha(Theme.primary, 0.12))
				: Qt.alpha(Theme.layer1, root.hovered ? 1 : 0)
			border.width: root.dropTarget || root.current ? 2 : (root.selected ? 1.5 : 0)
			border.color: root.dropTarget ? Theme.primary : (root.current && !root.selected ? Qt.alpha(Theme.primary, 0.7) : Qt.alpha(Theme.primary, 0.55))
			scale: root.dropTarget ? 1.04 : 1

			Behavior on color {
				ColorAnim {}
			}
			Behavior on scale {
				SpatialAnim {
					duration: Motion.medium
				}
			}
		}

		FileThumb {
			id: picture

			x: (root.width - width) / 2
			y: 12
			width: root.art
			height: Math.round(root.art * 0.8)
			path: root.path
			name: root.name
			mime: root.mime
			dir: root.dir
			kind: root.kind
			thumb: root.thumb
			canThumb: root.canThumb
			isText: root.text
			mtime: root.mtime
			bytes: root.size
			hovered: root.hovered
			selected: root.selected
			dropTarget: root.dropTarget
		}

		// picked: a tick pops up in the corner
		Rectangle {
			x: picture.x - 4
			y: picture.y - 4
			width: 22
			height: 22
			radius: 11
			color: Theme.primary
			border.width: 2
			border.color: Theme.base
			scale: root.selected && (root.pane?.selectionCount ?? 0) > 1 ? 1 : 0
			opacity: scale

			Behavior on scale {
				SpatialAnim {
					duration: Motion.medium
					easing.bezierCurve: Motion.spatialFast
				}
			}

			Glyph {
				anchors.centerIn: parent
				icon: "check"
				size: 14
				color: Theme.onPrimary
				surface: Theme.primary
				animated: false
			}
		}

		// tags as dots in the other corner
		Row {
			anchors.right: picture.right
			anchors.rightMargin: -2
			y: picture.y - 3
			spacing: -4
			visible: root.tags.length > 0

			Repeater {
				model: root.tags.slice(0, 4)

				delegate: Rectangle {
					required property string modelData

					width: 12
					height: 12
					radius: 6
					color: FileLibrary.colorOf(FileLibrary.tagById(modelData)?.color ?? "primary")
					border.width: 2
					border.color: Theme.base
				}
			}
		}

		// git, a comparison, a note
		Marks {
			x: picture.x - 3
			y: picture.y + picture.height - 15
			pane: root.pane
			path: root.path
			name: root.name
			compact: root.width < 150
		}

		// a link says so
		Rectangle {
			visible: root.link
			x: picture.x + picture.width - 18
			y: picture.y + picture.height - 18
			width: 20
			height: 20
			radius: 10
			color: Theme.layer3

			Glyph {
				anchors.centerIn: parent
				icon: "arrow_top_right"
				size: 12
				color: Theme.textMuted
				surface: Theme.layer3
				animated: false
			}
		}

		Item {
			id: nameBox

			x: 10
			y: picture.y + picture.height + 8
			width: root.width - 20
			height: root.height - y - 6

			Text {
				id: label

				visible: !root.renaming
				width: parent.width
				horizontalAlignment: Text.AlignHCenter
				text: root.name
				color: root.selected ? Theme.text : Qt.alpha(Theme.text, 0.92)
				font.family: Theme.fontFamily
				font.pixelSize: Theme.size.label
				font.weight: root.selected ? Font.DemiBold : Font.Medium
				wrapMode: Text.WrapAtWordBoundaryOrAnywhere
				maximumLineCount: 2
				elide: Text.ElideRight
				lineHeight: 1.05
			}

			Text {
				visible: !root.renaming
				anchors.top: label.bottom
				anchors.topMargin: 2
				width: parent.width
				horizontalAlignment: Text.AlignHCenter
				text: root.showFolder ? root.folder : (root.note !== "" ? root.note.split("\n")[0] : root.meta)
				color: root.note !== "" && !root.showFolder ? Theme.warning : Theme.textSubtle
				font.family: Theme.fontFamily
				font.pixelSize: Theme.size.small
				elide: root.showFolder ? Text.ElideLeft : Text.ElideRight
			}

			RenameField {
				visible: root.renaming
				active: root.renaming
				width: parent.width
				path: root.path
				name: root.name
				dir: root.dir
				pane: root.pane
				centered: true
			}
		}
	}

	readonly property string meta: {
		if (root.dir) {
			Files.peekTick;
			const count = Files.peekOf(root.path)?.count;
			if (count === undefined) return " ";
			if (count < 0) return "No access";
			return count === 0 ? "Empty" : `${count} item${count === 1 ? "" : "s"}`;
		}
		return `${Format.bytes(root.size)} · ${Files.whenText(root.mtime)}`;
	}
}
