pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.style.theme
import qs.core.services
import qs.style.widgets

// The Teamwork ticket of an entry. A click unfolds a searchable list of the
// tickets qtrack knows; Enter takes the first match.
ColumnLayout {
	id: root

	required property var entry
	property bool expanded: false
	property string search: ""
	signal picked(var task)

	readonly property string currentId: String(root.entry.teamwork_task_id || "")
	readonly property var tasks: Array.isArray(Tmpo.teamworkTasks) ? Tmpo.teamworkTasks : []
	readonly property var matches: root.tasks.filter(task => root.haystack(task).includes(root.search.trim().toLowerCase())).slice(0, 80)

	function taskId(task) {
		return String(task?.task_id || task?.id || "");
	}

	function label(task) {
		return String(task?.label || task?.task_name || task?.name || "Teamwork ticket");
	}

	// "project / ticket" as two lines
	function kicker(task) {
		const text = root.label(task);
		const slash = text.indexOf("/");
		return slash >= 0 ? text.slice(0, slash).trim() : String(task?.project_name || "Teamwork");
	}

	function title(task) {
		const text = root.label(task);
		const slash = text.indexOf("/");
		return slash >= 0 ? text.slice(slash + 1).trim() : String(task?.task_name || task?.name || text);
	}

	function haystack(task) {
		return [root.label(task), task?.project_name, task?.tasklist_name, task?.task_name, root.taskId(task)].filter(Boolean).join(" ").toLowerCase();
	}

	function pick(task) {
		if (!task) return;
		root.expanded = false;
		root.picked(task);
	}

	spacing: 6
	opacity: enabled ? 1 : 0.6
	onExpandedChanged: {
		root.search = "";
		query.text = "";
		if (root.expanded) Qt.callLater(() => query.focusInput());
	}

	Clickable {
		id: button

		Layout.fillWidth: true
		implicitHeight: 40
		radius: Theme.radius.large
		pressedScale: 0.99
		color: button.hovered || root.expanded ? Theme.layer2 : Theme.layer1
		interactive: root.tasks.length > 0
		onClicked: root.expanded = !root.expanded

		RowLayout {
			anchors.fill: parent
			anchors.leftMargin: 14
			anchors.rightMargin: 10
			spacing: 8

			StyledText {
				Layout.fillWidth: true
				text: {
					if (root.currentId === "") return root.tasks.length > 0 ? "Choose a ticket …" : Tmpo.teamworkStatus;
					const known = root.tasks.find(task => root.taskId(task) === root.currentId);
					return known ? root.title(known) : String(root.entry.teamwork_task_name || `Ticket ${root.currentId}`);
				}
				tone: root.currentId === "" ? Theme.textSubtle : Theme.text
			}

			Glyph {
				icon: "chevron_down"
				size: 18
				color: Theme.textSubtle
				animated: false
				rotation: root.expanded ? 180 : 0

				Behavior on rotation {
					SpatialAnim {
						duration: Motion.short
					}
				}
			}
		}
	}

	Field {
		id: query

		Layout.fillWidth: true
		visible: root.expanded
		icon: "magnify"
		placeholder: "Search tickets"
		text: root.search
		onEdited: text => root.search = text
		onDownPressed: list.incrementCurrentIndex()
		onUpPressed: list.decrementCurrentIndex()
		onAccepted: root.pick(root.matches[Math.max(0, list.currentIndex)])
		onEscapePressed: root.expanded = false
	}

	Rectangle {
		Layout.fillWidth: true
		Layout.preferredHeight: Math.min(list.contentHeight + 12, 224)
		visible: root.expanded && root.matches.length > 0
		radius: Theme.radius.large
		color: Theme.layer1

		ListView {
			id: list

			anchors.fill: parent
			anchors.margins: 6
			clip: true
			spacing: 2
			model: root.expanded ? root.matches : []
			highlightMoveDuration: Motion.short
			boundsBehavior: Flickable.StopAtBounds
			ScrollBar.vertical: ThinScrollBar {}

			delegate: Clickable {
				id: option

				required property var modelData
				required property int index
				readonly property bool current: root.taskId(option.modelData) === root.currentId

				width: ListView.view.width
				implicitHeight: 44
				radius: Theme.radius.medium
				pressedScale: 0.98
				color: option.current ? Theme.primaryContainer : (option.hovered || list.currentIndex === option.index ? Theme.layer2 : "transparent")
				onClicked: root.pick(option.modelData)

				ColumnLayout {
					anchors.fill: parent
					anchors.leftMargin: 12
					anchors.rightMargin: 12
					spacing: 0

					Item {
						Layout.fillHeight: true
					}

					StyledText {
						Layout.fillWidth: true
						text: root.kicker(option.modelData)
						tone: Theme.textSubtle
						font.pixelSize: Theme.size.tiny
						font.weight: Font.Bold
					}

					StyledText {
						Layout.fillWidth: true
						text: root.title(option.modelData)
						font.pixelSize: Theme.size.label
						font.weight: option.current ? Font.Bold : Font.Medium
					}

					Item {
						Layout.fillHeight: true
					}
				}
			}
		}
	}

	StyledText {
		Layout.leftMargin: 4
		visible: root.expanded && root.matches.length === 0
		text: "No ticket found"
		tone: Theme.textSubtle
		font.pixelSize: Theme.size.small
	}
}
