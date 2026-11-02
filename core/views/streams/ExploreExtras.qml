pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// Below the suggestions: where two followed channels meet, and channels the
// followed ones keep naming.
ColumnLayout {
	id: root

	property var meets: []
	property var people: []

	spacing: 12

	Component.onCompleted: Streams.call("exploreExtras", {}, data => {
		root.meets = data?.meets ?? [];
		root.people = data?.people ?? [];
	})

	StyledText {
		Layout.topMargin: 24
		visible: root.meets.length > 0
		text: "Your channels together"
		font.pixelSize: Theme.size.title
		font.weight: Font.Bold
	}
	Flow {
		Layout.fillWidth: true
		spacing: 12
		visible: root.meets.length > 0

		Repeater {
			model: root.meets.slice(0, 12)

			Clickable {
				id: meet

				required property var modelData

				width: 300
				height: 214
				radius: Theme.radius.medium
				onClicked: Streams.play(meet.modelData.id)

				ColumnLayout {
					anchors.fill: parent
					anchors.margins: 6
					spacing: 4

					Thumb {
						Layout.fillWidth: true
						Layout.preferredHeight: 156
						source: meet.modelData.thumb
					}
					StyledText {
						Layout.fillWidth: true
						text: meet.modelData.title
						elide: Text.ElideRight
					}
					StyledText {
						Layout.fillWidth: true
						text: `With ${meet.modelData.with}`
						tone: Theme.textMuted
						font.pixelSize: Theme.size.small
						elide: Text.ElideRight
					}
				}
			}
		}
	}
	StyledText {
		Layout.topMargin: 24
		visible: root.people.length > 0
		text: "Your channels keep naming"
		font.pixelSize: Theme.size.title
		font.weight: Font.Bold
	}
	Flow {
		Layout.fillWidth: true
		spacing: 8
		visible: root.people.length > 0

		Repeater {
			model: root.people

			RowLayout {
				id: person

				required property var modelData

				width: 420
				spacing: 10

				ColumnLayout {
					Layout.fillWidth: true
					spacing: 0

					StyledText {
						text: `@${person.modelData.handle}`
						font.weight: Font.DemiBold
					}
					StyledText {
						Layout.fillWidth: true
						text: `${person.modelData.videos} videos · ${person.modelData.names.join(", ")}`
						tone: Theme.textMuted
						font.pixelSize: Theme.size.small
						elide: Text.ElideRight
					}
				}
				TextButton {
					text: "Follow"
					onActivated: Streams.follow(`https://www.youtube.com/@${person.modelData.handle}`)
				}
			}
		}
	}
}
