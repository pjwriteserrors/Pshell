pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.core.services
import qs.style.widgets

// The day review in the Today panel (plugin browser-review): in the evening
// the articles read and the videos watched today (WebMemory.review); each
// can go on the shelf or come back tomorrow evening as a reminder. A click
// opens the page.
Rectangle {
	id: root

	visible: WebMemory.reviewOn && WebMemory.evening && WebMemory.review.length > 0
	implicitHeight: column.implicitHeight + 24
	radius: Theme.radius.huge
	color: Theme.layer1

	ColumnLayout {
		id: column

		anchors.fill: parent
		anchors.margins: 12
		spacing: 4

		RowLayout {
			Layout.fillWidth: true
			Layout.leftMargin: 4
			spacing: 8

			StyledText {
				text: "Read today"
				font.pixelSize: Theme.size.body
				font.weight: Font.DemiBold
			}

			Badge {
				count: WebMemory.review.length
			}
		}

		Repeater {
			model: WebMemory.review

			delegate: ListItem {
				id: item

				required property var modelData

				Layout.fillWidth: true
				implicitHeight: 48
				icon: item.modelData?.kind === "video" ? "play_circle_outline" : "text_box_outline"
				title: String(item.modelData?.title ?? "")
				subtitle: String(item.modelData?.host ?? "")
				onClicked: {
					WebMemory.open(item.modelData);
					Popups.close();
				}

				TextButton {
					Layout.preferredHeight: 30
					visible: Plugins.on("shelves")
					text: "Shelf"
					variant: "ghost"
					onActivated: WebMemory.shelve(item.modelData)
				}

				TextButton {
					Layout.preferredHeight: 30
					visible: Reminders.online
					text: "Later"
					variant: "ghost"
					onActivated: WebMemory.later(item.modelData)
				}
			}
		}
	}
}
