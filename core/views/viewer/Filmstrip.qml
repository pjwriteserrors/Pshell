pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.style.widgets
import qs.core.services

// The folder's pictures in a row: the one shown grows and stays in the
// middle, the wheel walks them. Thumbnails come from the desktop's cache
// (~/.cache/thumbnails) when they are there, otherwise from a small decode.
Item {
	id: root

	readonly property string thumbs: `${Paths.home}/.cache/thumbnails`

	implicitHeight: 84

	function thumbFor(path) {
		const uri = "file://" + encodeURI(path).replace(/\?/g, "%3F").replace(/#/g, "%23");
		return `${root.thumbs}/large/${Qt.md5(uri)}.png`;
	}

	ListView {
		id: list

		anchors.fill: parent
		orientation: ListView.Horizontal
		spacing: 6
		model: Viewer.files
		currentIndex: Viewer.index
		highlightRangeMode: ListView.ApplyRange
		preferredHighlightBegin: width / 2 - 40
		preferredHighlightEnd: width / 2 + 40
		highlightMoveDuration: Motion.long
		boundsBehavior: Flickable.StopAtBounds
		cacheBuffer: 600
		leftMargin: Math.max(0, width / 2 - 40)
		rightMargin: Math.max(0, width / 2 - 40)

		delegate: Item {
			id: tile

			required property var modelData
			required property int index
			readonly property bool current: tile.index === Viewer.index

			width: tile.current ? 84 : 58
			height: list.height

			Behavior on width {
				SpatialAnim {}
			}

			Rectangle {
				id: frame

				anchors.centerIn: parent
				width: tile.width
				height: tile.current ? 72 : 52
				radius: Theme.radius.medium
				color: Theme.layer2
				clip: true
				border.width: tile.current ? 2 : 0
				border.color: Theme.primary
				opacity: tile.current || tileMouse.containsMouse ? 1 : 0.62

				Behavior on height {
					SpatialAnim {}
				}
				Behavior on opacity {
					Anim {}
				}

				Image {
					id: thumb

					anchors.fill: parent
					anchors.margins: tile.current ? 2 : 0
					source: "file://" + root.thumbFor(tile.modelData.path)
					sourceSize: Qt.size(160, 160)
					fillMode: Image.PreserveAspectCrop
					asynchronous: true
					cache: true
					smooth: true
					// not in the cache: a small decode of the picture itself
					onStatusChanged: if (status === Image.Error && !source.toString().endsWith(tile.modelData.path)) source = "file://" + tile.modelData.path
				}
			}

			MouseArea {
				id: tileMouse

				anchors.fill: parent
				hoverEnabled: true
				cursorShape: Qt.PointingHandCursor
				onClicked: {
					Viewer.direction = tile.index >= Viewer.index ? 1 : -1;
					Viewer.show(tile.index);
				}
			}
		}

		MouseArea {
			anchors.fill: parent
			acceptedButtons: Qt.NoButton
			onWheel: wheel => Viewer.step((wheel.angleDelta.y || wheel.angleDelta.x) > 0 ? -1 : 1)
		}
	}
}
