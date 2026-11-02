pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// One followed channel on the wall of faces (SourcesPage).
Item {
	id: cell

	required property string key
	// the page: who waits to be merged
	required property var page
	readonly property var item: Streams.sourceById[cell.key] ?? null
	readonly property bool canTake: cell.page.mergingFrom !== "" && cell.page.mergingFrom !== cell.key

	HoverHandler {
		id: cellHover
	}

	Rectangle {
		anchors.fill: parent
		anchors.margins: 6
		radius: Theme.radius.huge
		color: cell.page.mergingFrom === cell.key ? Theme.primaryContainer : (cellHover.hovered ? Theme.layer2 : Theme.layer1)
		opacity: cell.page.mergingFrom !== "" && cell.page.mergingFrom !== cell.key && !cell.canTake ? 0.4 : 1
		border.width: cell.canTake && cellHover.hovered ? 2 : 0
		border.color: Theme.primary

		Behavior on color {
			ColorAnim {}
		}
		Behavior on opacity {
			Anim {}
		}

		ColumnLayout {
			anchors.fill: parent
			anchors.margins: 14
			spacing: 6

			Avatar {
				Layout.alignment: Qt.AlignHCenter
				Layout.preferredWidth: 84
				Layout.preferredHeight: 84
				source: cell.item?.avatar ?? ""
				name: cell.item?.name ?? ""
				colors: cell.item?.colors ?? null
				live: cell.item?.live ?? false
				scale: cellHover.hovered ? 1.08 : 1

				Behavior on scale {
					SpatialAnim {
						duration: Motion.long
					}
				}
			}
			StyledText {
				Layout.fillWidth: true
				Layout.topMargin: 4
				horizontalAlignment: Text.AlignHCenter
				text: cell.item?.name ?? ""
				font.pixelSize: Theme.size.title
				font.weight: Font.Bold
				elide: Text.ElideRight
			}
			StyledText {
				Layout.fillWidth: true
				horizontalAlignment: Text.AlignHCenter
				text: {
					const item = cell.item;
					if (!item) return "";
					if (item.error) return item.error;
					if (item.loading) return item.loading;
					return item.pattern || Streams.sourceKind(item);
				}
				font.pixelSize: Theme.size.small
				color: cell.item?.error ? Theme.warning : Theme.textMuted
				elide: Text.ElideRight
			}
			Item {
				Layout.fillHeight: true
			}
			Segmented {
				Layout.fillWidth: true
				Layout.preferredHeight: 28
				options: [{ value: "all", label: "All" }, { value: "live", label: "Live" }, { value: "silent", label: "Silent" }]
				current: cell.item?.notify ?? "live"
				onSelected: value => Streams.updateSource(cell.key, { notify: value })
			}
		}

		IconButton {
			anchors.left: parent.left
			anchors.top: parent.top
			anchors.margins: 8
			width: 30
			height: 30
			icon: cell.item?.favorite ? "star" : "star_outline"
			checked: cell.item?.favorite ?? false
			visible: cell.item?.kind !== "rss" && (cellHover.hovered || (cell.item?.favorite ?? false))
			onClicked: Streams.updateSource(cell.key, { favorite: !cell.item.favorite })
		}
		TextButton {
			anchors.right: parent.right
			anchors.top: parent.top
			anchors.margins: 8
			visible: cellHover.hovered && cell.page.mergingFrom === ""
			text: ""
			icon: "delete_outline"
			variant: "ghost"
			confirm: true
			confirmText: "Remove?"
			onActivated: Streams.call("removeSource", { id: cell.key })
		}
		IconButton {
			anchors.left: parent.left
			anchors.bottom: parent.bottom
			anchors.margins: 8
			anchors.bottomMargin: 44
			width: 30
			height: 30
			visible: cellHover.hovered && cell.page.mergingFrom === "" && cell.item?.kind !== "rss"
			icon: "call_merge"
			onClicked: cell.page.mergingFrom = cell.key
		}
		MouseArea {
			anchors.fill: parent
			visible: cell.canTake
			cursorShape: Qt.PointingHandCursor
			onClicked: cell.page.mergeInto(cell.key)
		}
	}
}
