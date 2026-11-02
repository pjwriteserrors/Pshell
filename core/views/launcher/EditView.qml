pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Quickshell.Io
import qs.style.theme
import qs.core.services
import qs.style.widgets

// Launcher >edit: recent files, notes, what holds the words; Enter opens in
// the editor, at the line it was found.
Item {
	id: root

	property string argument: ""
	property bool active: false
	signal closeRequested

	property var rows: []
	property int currentIndex: 0
	readonly property var current: root.rows[root.currentIndex] ?? null

	onArgumentChanged: searchTimer.restart()
	onActiveChanged: if (root.active) searchTimer.restart()

	Timer {
		id: searchTimer

		interval: 90
		onTriggered: {
			finder.running = false;
			finder.command = ["python3", `${Paths.scripts}/editor/find.py`, root.argument];
			finder.running = true;
		}
	}
	Process {
		id: finder

		stdout: StdioCollector {
			onStreamFinished: {
				try {
					root.rows = JSON.parse(text);
					root.currentIndex = 0;
				} catch (error) {
					root.rows = [];
				}
			}
		}
	}

	function move(delta) {
		if (root.rows.length === 0) return;
		root.currentIndex = Math.max(0, Math.min(root.rows.length - 1, root.currentIndex + delta));
		list.positionViewAtIndex(root.currentIndex, ListView.Contain);
	}
	function handleKey(event) {
		return false;
	}
	function cancel() {
		return false;
	}
	function activate(modifiers) {
		root.closeRequested();
		if (root.current) Editor.open(root.current.path, root.current.line);
		else if (root.argument.startsWith("/") || root.argument.startsWith("~")) Editor.open(root.argument.replace(/^~/, Paths.home), 0);
		else Editor.open("", 0);
	}

	ListView {
		id: list

		anchors.fill: parent
		clip: true
		model: root.rows
		currentIndex: root.currentIndex
		boundsBehavior: Flickable.StopAtBounds
		highlightMoveDuration: Motion.short
		ScrollBar.vertical: ThinScrollBar {}

		add: Transition {
			Anim {
				property: "opacity"
				from: 0
				to: 1
				duration: Motion.short
			}
		}

		delegate: Item {
			id: holder

			required property var modelData
			required property int index
			readonly property bool head: holder.index === 0 || root.rows[holder.index - 1].group !== holder.modelData.group

			width: list.width - 6
			height: row.height + (holder.head ? 28 : 0)

			Text {
				visible: holder.head
				x: 12
				y: 8
				text: holder.modelData.group
				color: Theme.textSubtle
				font.family: Theme.fontFamily
				font.pixelSize: Theme.size.small
				font.weight: Font.DemiBold
			}
			Rectangle {
				id: row

				readonly property bool selected: holder.index === root.currentIndex

				y: holder.head ? 28 : 0
				width: holder.width
				height: 46
				radius: Theme.radius.medium
				color: Qt.alpha(Theme.primary, row.selected ? 0.16 : (rowHover.hovered ? 0.07 : 0))

				Behavior on color {
					ColorAnim {}
				}
				HoverHandler {
					id: rowHover
				}
				TapHandler {
					onTapped: {
						root.currentIndex = holder.index;
						root.activate(0);
					}
				}
				Glyph {
					id: rowIcon

					x: 14
					anchors.verticalCenter: parent.verticalCenter
					icon: holder.modelData.line > 0 ? "magnify" : "file_document_outline"
					color: row.selected ? Theme.primary : Theme.textMuted
				}
				Column {
					anchors.left: rowIcon.right
					anchors.leftMargin: 12
					anchors.right: parent.right
					anchors.rightMargin: 12
					anchors.verticalCenter: parent.verticalCenter

					StyledText {
						width: parent.width
						elide: Text.ElideRight
						text: holder.modelData.line > 0 ? holder.modelData.text : holder.modelData.name
					}
					StyledText {
						width: parent.width
						elide: Text.ElideMiddle
						text: holder.modelData.line > 0 ? `${holder.modelData.dir}/${holder.modelData.name}:${holder.modelData.line}` : holder.modelData.dir
						tone: Theme.textSubtle
						font.pixelSize: Theme.size.small
					}
				}
			}
		}
	}
}
