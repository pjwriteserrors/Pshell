pragma ComponentBehavior: Bound

import QtQuick
import QtQml.Models
import qs.style.theme
import qs.style.widgets

// A list whose entries are put in order by dragging them by their grip; the
// others make room as it passes. `cell` is the entry: it gets `modelData`,
// `index` and `dragSource` (hand that to a DragGrip). When an entry is let
// go, reordered(order) says where the old entries went (old indices in the
// new order).
ListView {
	id: root

	property var items: []
	property Component cell: null
	property bool horizontal: false
	property bool dragging: false

	signal reordered(var order)

	orientation: root.horizontal ? ListView.Horizontal : ListView.Vertical
	interactive: false
	implicitHeight: root.horizontal ? (root.contentItem.childrenRect.height || 40) : root.contentHeight
	implicitWidth: root.horizontal ? root.contentWidth : 200
	boundsBehavior: Flickable.StopAtBounds
	spacing: 8
	cacheBuffer: 4000

	function finish() {
		const order = [];
		for (let i = 0; i < visual.items.count; i++)
			order.push(visual.items.get(i).model.index);
		if (order.some((value, i) => value !== i)) root.reordered(order);
	}

	displaced: Transition {
		NumberAnimation {
			properties: "x,y"
			duration: Motion.long
			easing.type: Easing.BezierSpline
			easing.bezierCurve: Motion.spatial
		}
	}

	model: DelegateModel {
		id: visual

		model: root.items

		delegate: DropArea {
			id: slot

			required property var modelData
			required property int index
			readonly property int visualIndex: DelegateModel.itemsIndex

			width: root.horizontal ? content.implicitWidth : root.width
			height: root.horizontal ? Math.max(content.implicitHeight, 1) : content.implicitHeight
			keys: [`draglist-${root}`]
			onEntered: drag => visual.items.move(drag.source.visualIndex, slot.visualIndex)

			Item {
				id: content

				property bool held: false
				readonly property int visualIndex: slot.visualIndex

				function finish() {
					content.held = false;
					root.dragging = false;
					Qt.callLater(root.finish);
				}

				width: slot.width
				height: slot.height
				implicitWidth: loader.item ? loader.item.implicitWidth : 0
				implicitHeight: loader.item ? loader.item.implicitHeight : 0
				Drag.active: content.held
				Drag.source: content
				Drag.keys: [`draglist-${root}`]
				Drag.hotSpot.x: width / 2
				Drag.hotSpot.y: height / 2
				z: content.held ? 10 : 0
				scale: content.held ? 1.02 : 1
				opacity: content.held ? 0.92 : 1
				onHeldChanged: if (content.held) root.dragging = true

				Behavior on scale {
					SpatialAnim {
						duration: Motion.short
					}
				}

				states: State {
					when: content.held

					ParentChange {
						target: content
						parent: root
					}
				}

				// a lifted entry casts a shadow
				Rectangle {
					anchors.fill: parent
					anchors.topMargin: 6
					radius: Theme.radius.large
					color: Theme.shadow
					opacity: content.held ? 0.6 : 0
					z: -1

					Behavior on opacity {
						Anim {
							duration: Motion.short
						}
					}
				}

				Loader {
					id: loader

					width: parent.width
					sourceComponent: root.cell
					onLoaded: {
						if ("modelData" in loader.item) loader.item.modelData = Qt.binding(() => slot.modelData);
						if ("index" in loader.item) loader.item.index = Qt.binding(() => slot.index);
						if ("dragSource" in loader.item) loader.item.dragSource = content;
					}
				}
			}
		}
	}
}
