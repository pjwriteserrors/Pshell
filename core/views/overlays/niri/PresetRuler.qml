pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import "Nodes.js" as Nodes

// The sizes Mod+R steps through, as marks on a screen: drag one to change
// it (it clicks onto ¼ ⅓ ½ ⅔ ¾), drag it off the screen to drop it, click
// the screen to add one. A mark is a share of the screen or – clicking its
// unit – fixed pixels. The star makes it the size new windows open with.
Item {
	id: root

	// [{ kind: "proportion" | "fixed", value }]
	property var presets: []
	property var defaultSize: null
	property bool defaultEmpty: false
	property bool showDefault: true
	property bool vertical: false
	property real logicalLength: 1600
	property string unitName: "width"

	signal presetsEdited(var presets)
	signal defaultPicked(var size, bool empty)

	readonly property real length: root.vertical ? track.height : track.width
	readonly property var snaps: [0.25, 1 / 3, 0.5, 2 / 3, 0.75, 1]

	function share(p) {
		return p.kind === "fixed" ? Math.min(1, p.value / root.logicalLength) : Math.min(1, p.value);
	}

	function sorted(list) {
		return list.slice().sort((a, b) => root.share(a) - root.share(b));
	}

	function snapShare(v) {
		for (const s of root.snaps)
			if (Math.abs(s - v) < 0.018) return s;
		return Math.round(v * 100) / 100;
	}

	function label(p) {
		return p.kind === "fixed" ? `${Math.round(p.value)} px` : Nodes.fraction(p.value);
	}

	function same(a, b) {
		return !!a && !!b && a.kind === b.kind && Math.abs(a.value - b.value) < 0.0005;
	}

	function at(index, changes) {
		const list = root.presets.map(p => Object.assign({}, p));
		Object.assign(list[index], changes);
		return list;
	}

	implicitWidth: root.vertical ? 260 : 560
	implicitHeight: root.vertical ? 300 : 150

	// the screen
	Rectangle {
		id: track

		x: root.vertical ? 70 : 0
		y: root.vertical ? 0 : 36
		width: root.vertical ? 110 : parent.width
		height: root.vertical ? parent.height : 74
		radius: Theme.radius.medium
		color: Theme.layer2
		border.width: 1
		border.color: Theme.outline

		// the window a hovered or dragged mark would make
		Rectangle {
			id: ghost

			property real share: 0
			property bool shown: false

			x: root.vertical ? 6 : 6
			y: 6
			width: root.vertical ? parent.width - 12 : Math.max(0, (parent.width - 12) * ghost.share)
			height: root.vertical ? Math.max(0, (parent.height - 12) * ghost.share) : parent.height - 12
			radius: Theme.radius.small
			color: Qt.alpha(Theme.primary, 0.18)
			border.width: 1.5
			border.color: Qt.alpha(Theme.primary, 0.6)
			opacity: ghost.shown ? 1 : 0

			Behavior on width {
				enabled: !root.vertical
				SpatialAnim {
					duration: Motion.medium
				}
			}
			Behavior on height {
				enabled: root.vertical
				SpatialAnim {
					duration: Motion.medium
				}
			}
			Behavior on opacity {
				Anim {
					duration: Motion.short
				}
			}
		}

		// quarter lines
		Repeater {
			model: [0.25, 0.5, 0.75]

			delegate: Rectangle {
				required property real modelData

				x: root.vertical ? 0 : modelData * track.width
				y: root.vertical ? modelData * track.height : 0
				width: root.vertical ? track.width : 1
				height: root.vertical ? 1 : track.height
				color: Theme.outline
			}
		}

		MouseArea {
			id: trackMouse

			anchors.fill: parent
			hoverEnabled: true
			cursorShape: Qt.CrossCursor
			onPositionChanged: event => {
				ghost.share = root.snapShare((root.vertical ? event.y : event.x) / root.length);
				ghost.shown = true;
			}
			onExited: ghost.shown = false
			onClicked: event => {
				const v = root.snapShare((root.vertical ? event.y : event.x) / root.length);
				if (root.presets.some(p => Math.abs(root.share(p) - v) < 0.01)) return;
				root.presetsEdited(root.sorted(root.presets.concat([{ kind: "proportion", value: v }])));
			}

			StyledText {
				anchors.centerIn: parent
				visible: root.presets.length === 0
				text: "Click to add a size"
				tone: Theme.textSubtle
				font.pixelSize: Theme.size.small
			}
		}
	}

	// the marks
	Repeater {
		model: root.presets

		delegate: Item {
			id: mark

			required property var modelData
			required property int index
			readonly property real share: root.share(mark.modelData)
			readonly property bool isDefault: root.showDefault && root.same(mark.modelData, root.defaultSize)
			property bool held: false
			property real heldShare: 0
			property real pull: 0
			readonly property bool dropping: mark.pull > 46
			readonly property real pos: (mark.held ? mark.heldShare : mark.share) * root.length

			x: root.vertical ? 0 : track.x + mark.pos - width / 2
			y: root.vertical ? track.y + mark.pos - height / 2 : 0
			width: root.vertical ? track.x + track.width + 70 : 70
			height: root.vertical ? 30 : track.y + track.height + 38
			z: mark.held ? 3 : 1
			opacity: mark.dropping ? 0.5 : 1

			Behavior on x {
				enabled: !mark.held && !root.vertical
				SpatialAnim {
					duration: Motion.medium
				}
			}
			Behavior on y {
				enabled: !mark.held && root.vertical
				SpatialAnim {
					duration: Motion.medium
				}
			}

			// the line on the screen
			Rectangle {
				x: root.vertical ? track.x : mark.width / 2 - 1
				y: root.vertical ? mark.height / 2 - 1 : track.y
				width: root.vertical ? track.width : 2
				height: root.vertical ? 2 : track.height
				color: mark.dropping ? Theme.danger : (mark.modelData.kind === "fixed" ? Theme.tertiary : Theme.primary)
				transform: Translate {
					x: root.vertical ? mark.pull : 0
					y: root.vertical ? 0 : mark.pull
				}
			}

			// its pill: the size, the unit to switch, the star
			Rectangle {
				id: pill

				x: root.vertical ? 0 : (mark.width - width) / 2
				y: root.vertical ? (mark.height - height) / 2 : 0
				width: pillRow.implicitWidth + 16
				height: 28
				radius: 14
				color: mark.dropping ? Theme.danger : (mark.isDefault ? (mark.modelData.kind === "fixed" ? Theme.tertiary : Theme.primary) : Theme.layer3)
				scale: markMouse.pressed ? 1.08 : (markMouse.containsMouse ? 1.04 : 1)
				transform: Translate {
					x: root.vertical ? mark.pull : 0
					y: root.vertical ? 0 : mark.pull
				}

				Behavior on color {
					ColorAnim {}
				}
				Behavior on scale {
					SpatialAnim {
						duration: Motion.short
					}
				}

				RowLayout {
					id: pillRow

					anchors.centerIn: parent
					spacing: 4

					Glyph {
						visible: mark.dropping
						icon: "delete_outline"
						size: 13
						color: Theme.bg
					}

					StyledText {
						text: root.label(mark.held ? Object.assign({}, mark.modelData, { value: mark.modelData.kind === "fixed" ? mark.heldShare * root.logicalLength : mark.heldShare }) : mark.modelData)
						tabular: true
						tone: mark.isDefault || mark.dropping ? Theme.onPrimary : Theme.text
						font.pixelSize: Theme.size.label
						font.weight: Font.DemiBold
					}
				}
			}

			MouseArea {
				id: markMouse

				property point start
				property bool moved: false

				x: pill.x - 4
				y: pill.y - 4
				width: pill.width + 8
				height: pill.height + 8
				hoverEnabled: true
				preventStealing: true
				acceptedButtons: Qt.LeftButton | Qt.RightButton
				cursorShape: mark.held ? Qt.ClosedHandCursor : Qt.OpenHandCursor
				onEntered: {
					ghost.share = mark.share;
					ghost.shown = true;
				}
				onExited: if (!mark.held) ghost.shown = false
				onPressed: event => {
					if (event.button === Qt.RightButton) return;
					markMouse.start = mapToItem(root, event.x, event.y);
					markMouse.moved = false;
					mark.heldShare = mark.share;
					mark.held = true;
				}
				onPositionChanged: event => {
					if (!mark.held) return;
					const p = mapToItem(root, event.x, event.y);
					const along = root.vertical ? p.y - markMouse.start.y : p.x - markMouse.start.x;
					const across = root.vertical ? p.x - markMouse.start.x : p.y - markMouse.start.y;
					if (Math.abs(along) + Math.abs(across) > 3) markMouse.moved = true;
					mark.heldShare = Math.max(0.05, Math.min(1, root.snapShare(mark.share + along / root.length)));
					mark.pull = Math.max(0, across);
					ghost.share = mark.heldShare;
				}
				onReleased: event => {
					if (event.button === Qt.RightButton) return;
					mark.held = false;
					ghost.shown = false;
					const pulled = mark.dropping;
					mark.pull = 0;
					if (pulled) {
						root.presetsEdited(root.presets.filter((p, i) => i !== mark.index));
						return;
					}
					if (!markMouse.moved) return;
					const value = mark.modelData.kind === "fixed" ? Math.round(mark.heldShare * root.logicalLength) : mark.heldShare;
					const list = root.at(mark.index, { value: value });
					if (mark.isDefault) root.defaultPicked(list[mark.index], false);
					root.presetsEdited(root.sorted(list));
				}
				onClicked: event => {
					// right click: share ⇄ pixels
					if (event.button === Qt.RightButton) {
						const p = mark.modelData;
						const next = p.kind === "fixed" ? { kind: "proportion", value: root.snapShare(p.value / root.logicalLength) } : { kind: "fixed", value: Math.round(p.value * root.logicalLength) };
						if (mark.isDefault) root.defaultPicked(next, false);
						root.presetsEdited(root.sorted(root.at(mark.index, next)));
					} else if (!markMouse.moved && root.showDefault) {
						root.defaultPicked(mark.modelData, false);
					}
				}
			}

			Behavior on opacity {
				Anim {
					duration: Motion.short
				}
			}
		}
	}

	// what to do here
	StyledText {
		x: root.vertical ? track.x + track.width + 16 : 0
		y: root.vertical ? track.height - height : track.y + track.height + 10
		width: root.vertical ? root.width - x : root.width
		text: root.showDefault ? "Drag to change · drag off to remove · click a mark to open new windows with it · right click: % ⇄ px" : "Drag to change · drag off to remove · click the screen to add · right click: % ⇄ px"
		tone: Theme.textSubtle
		font.pixelSize: Theme.size.small
		wrapMode: Text.WordWrap
	}
}
