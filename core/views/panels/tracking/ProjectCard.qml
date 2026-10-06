pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.style.theme
import qs.core.services
import qs.style.widgets

// A project of the day: its name, how many entries are queued, its time,
// and the entries themselves. A click on the head folds them away. On a day
// that comes in, the cards rise one after the other.
Rectangle {
	id: root

	required property string project
	required property int index
	// the panel, which remembers what is open and folded
	required property var board

	readonly property var entries: Tracking.entries.filter(entry => String(entry.project || "") === root.project)
	readonly property bool folded: root.board.folded[root.project] === true
	readonly property bool pending: Tracking.isPending(root.project)
	readonly property int queued: root.entries.filter(entry => entry.checked).length
	readonly property int split: root.project.indexOf(" / ")
	// only a fold runs the height; an entry that opens runs its own
	property bool folding: false

	onFoldedChanged: {
		root.folding = true;
		settle.restart();
	}

	Timer {
		id: settle

		interval: Motion.long + 60
		onTriggered: root.folding = false
	}

	implicitHeight: column.implicitHeight + 12
	radius: Theme.radius.large
	color: Theme.layer1
	opacity: root.pending ? 0.55 : 1
	enabled: !root.pending
	transform: Translate {
		id: rise
	}

	Behavior on opacity {
		enabled: !enter.running

		Anim {
			duration: Motion.short
		}
	}

	Component.onCompleted: {
		wait.duration = root.board.arriving ? Math.min(root.index, 8) * 45 : 0;
		enter.start();
	}

	SequentialAnimation {
		id: enter

		PropertyAction { target: root; property: "opacity"; value: 0 }
		PropertyAction { target: rise; property: "y"; value: 14 }
		PauseAnimation { id: wait }
		ParallelAnimation {
			Anim { target: root; property: "opacity"; to: 1 }
			SpatialAnim { target: rise; property: "y"; to: 0 }
		}
	}

	ColumnLayout {
		id: column

		x: 6
		y: 6
		width: parent.width - 12
		spacing: 0

		Clickable {
			id: head

			Layout.fillWidth: true
			implicitHeight: 52
			radius: Theme.radius.medium
			pressedScale: 0.99
			color: head.hovered ? Theme.layer2 : "transparent"
			onClicked: root.board.flip("folded", root.project)

			RowLayout {
				anchors.fill: parent
				anchors.leftMargin: 10
				anchors.rightMargin: 12
				spacing: 12

				Rectangle {
					implicitWidth: 34
					implicitHeight: 34
					radius: Theme.radius.medium
					color: Theme.layer2

					Glyph {
						anchors.centerIn: parent
						icon: root.folded ? "folder_outline" : "folder_open"
						size: 17
						color: Theme.textMuted
					}
				}

				ColumnLayout {
					Layout.fillWidth: true
					spacing: 0

					StyledText {
						Layout.fillWidth: true
						visible: root.split >= 0
						text: root.project.slice(0, Math.max(0, root.split))
						tone: Theme.textSubtle
						font.pixelSize: Theme.size.small
					}

					StyledText {
						Layout.fillWidth: true
						text: root.split >= 0 ? root.project.slice(root.split + 3) : (root.project || "No project")
						font.pixelSize: Theme.size.title
						font.weight: Font.Bold
					}
				}

				TextButton {
					implicitHeight: 28
					opacity: head.hovered || armed ? 1 : 0
					scale: head.hovered || armed ? 1 : 0.9
					visible: opacity > 0
					icon: "trash_can_outline"
					text: "Delete"
					variant: "danger"
					confirm: true
					confirmText: `Delete ${root.entries.length} entries?`
					onActivated: Tracking.removeProject({ project: root.project })

					Behavior on opacity {
						Anim {
							duration: Motion.short
						}
					}
				}

				Rectangle {
					implicitHeight: 22
					implicitWidth: pill.implicitWidth + 18
					radius: 11
					color: root.queued > 0 ? Theme.primarySoft : Theme.layer2

					Behavior on color {
						ColorAnim {
							duration: Motion.medium
						}
					}
					Behavior on implicitWidth {
						SpatialAnim {
							duration: Motion.medium
						}
					}

					StyledText {
						id: pill

						anchors.centerIn: parent
						text: `${root.queued}/${root.entries.length} queued`
						tone: root.queued > 0 ? Theme.primary : Theme.textMuted
						tabular: true
						font.pixelSize: Theme.size.small
						font.weight: Font.DemiBold
					}
				}

				StyledText {
					Layout.minimumWidth: 64
					horizontalAlignment: Text.AlignRight
					text: Tracking.formatMinutes(root.entries.reduce((sum, entry) => sum + Tracking.entryMinutes(entry), 0))
					tabular: true
					font.pixelSize: Theme.size.title
					font.weight: Font.Bold
				}

				Glyph {
					icon: "chevron_right"
					size: 18
					color: Theme.textSubtle
					animated: false
					rotation: root.folded ? 0 : 90

					Behavior on rotation {
						SpatialAnim {
							duration: Motion.medium
						}
					}
				}
			}
		}

		Item {
			id: fold

			property real shown: root.folded ? 0 : list.implicitHeight + 4

			Layout.fillWidth: true
			Layout.preferredHeight: fold.shown
			visible: fold.shown > 0.5
			clip: root.folding

			Behavior on shown {
				enabled: root.folding

				SpatialAnim {
					duration: root.folded ? Motion.medium : Motion.long
				}
			}

			ColumnLayout {
				id: list

				y: 4
				width: parent.width
				spacing: 0
				opacity: root.folded ? 0 : 1

				Behavior on opacity {
					Anim {
						duration: root.folded ? Motion.short : Motion.long
					}
				}

				Repeater {
					// by key, so an entry that stays keeps its row and what is typed in it
					model: ScriptModel {
						values: root.entries.map(entry => Tracking.key(entry))
					}

					delegate: EntryRow {
						required property string modelData

						Layout.fillWidth: true
						entryKey: modelData
						board: root.board
					}
				}
			}
		}
	}
}
