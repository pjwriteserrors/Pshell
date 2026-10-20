pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.style.theme
import qs.core.services
import qs.style.widgets

// The saved identities, each with what it was for.
Item {
	id: root

	// the one whose bin was clicked once
	property string doomed: ""

	Timer {
		id: spare

		interval: 2600
		onTriggered: root.doomed = ""
	}

	ListView {
		id: list

		anchors.fill: parent
		clip: true
		spacing: 2
		model: Identities.saved
		boundsBehavior: Flickable.StopAtBounds
		ScrollBar.vertical: ThinScrollBar {}

		delegate: ListItem {
			id: entry

			required property var modelData
			readonly property bool lost: entry.modelData.mail?.gone === true || entry.modelData.phone?.gone === true

			width: list.width
			title: Identities.label(entry.modelData)
			subtitle: [entry.modelData.title ? Identities.name(entry.modelData) : "", entry.modelData.mail?.address ?? ""].filter(part => part !== "").join(" · ")
			selected: entry.modelData.id === Identities.currentId
			leading: Component {
				Portrait {
					source: entry.modelData.picture ?? ""
					name: Identities.name(entry.modelData)
				}
			}
			onClicked: Identities.show(entry.modelData.id)

			Glyph {
				visible: entry.lost
				icon: "alert_outline"
				size: 16
				color: Theme.danger
			}

			Badge {
				count: Identities.unread(entry.modelData)
			}

			IconButton {
				implicitWidth: 30
				implicitHeight: 30
				icon: "delete_outline"
				variant: "danger"
				checked: root.doomed === entry.modelData.id
				opacity: entry.hovered || checked ? 1 : 0
				onClicked: {
					if (checked) {
						Identities.remove(entry.modelData.id);
						return;
					}
					root.doomed = entry.modelData.id;
					spare.restart();
				}

				Behavior on opacity {
					Anim {
						duration: Motion.short
					}
				}
			}
		}
	}

	EmptyState {
		anchors.centerIn: parent
		visible: Identities.saved.length === 0
		icon: "account_multiple"
		title: "No saved identities"
	}
}
