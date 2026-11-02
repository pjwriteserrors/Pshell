import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// How a series behaves. Unfolds under its top.
Item {
	id: root

	property bool shown: false
	property var item: null
	signal editRule
	signal deleted

	implicitHeight: root.shown ? box.implicitHeight : 0
	clip: true
	opacity: root.shown ? 1 : 0

	Behavior on implicitHeight {
		SpatialAnim {
			duration: Motion.long
		}
	}
	Behavior on opacity {
		Anim {}
	}

	Rectangle {
		id: box

		width: parent.width
		implicitHeight: column.implicitHeight + 28
		radius: Theme.radius.large
		color: Theme.layer1

		ColumnLayout {
			id: column

			anchors.left: parent.left
			anchors.right: parent.right
			anchors.top: parent.top
			anchors.margins: 14
			spacing: 12

			RowLayout {
				Layout.fillWidth: true

				StyledText {
					Layout.fillWidth: true
					text: "Tell me about new episodes"
				}
				Segmented {
					Layout.preferredWidth: 200
					Layout.preferredHeight: 30
					options: [{ value: "all", label: "Always" }, { value: "silent", label: "Never" }]
					current: root.item?.notify === "silent" ? "silent" : "all"
					onSelected: value => Streams.updateSeries(root.item.id, { notify: value })
				}
			}

			RowLayout {
				Layout.fillWidth: true

				StyledText {
					Layout.fillWidth: true
					text: "Order of the episodes"
				}
				Segmented {
					Layout.preferredWidth: 200
					Layout.preferredHeight: 30
					options: [{ value: "auto", label: "By number" }, { value: "date", label: "By date" }]
					current: root.item?.orderMode ?? "auto"
					onSelected: value => Streams.updateSeries(root.item.id, { orderMode: value })
				}
			}

			RowLayout {
				Layout.fillWidth: true

				ColumnLayout {
					Layout.fillWidth: true
					spacing: 0
					StyledText {
						Layout.fillWidth: true
						text: "Keep the next two on this PC"
					}
					StyledText {
						Layout.fillWidth: true
						wrapMode: Text.Wrap
						text: "Downloaded with yt-dlp, deleted once watched. mpv plays them from here."
						font.pixelSize: Theme.size.small
						tone: Theme.textMuted
					}
				}
				Toggle {
					checked: root.item?.offline ?? false
					onToggled: checked => Streams.updateSeries(root.item.id, { offline: checked })
				}
			}

			Flow {
				Layout.fillWidth: true
				spacing: 8

				TextButton {
					text: "Change the rule"
					icon: "tune"
					variant: "tonal"
					onActivated: root.editRule()
				}
				TextButton {
					visible: root.item?.status === "active"
					text: "Rest for a month"
					icon: "sleep"
					variant: "tonal"
					onActivated: Streams.updateSeries(root.item.id, { pauseDays: 30 })
				}
				TextButton {
					visible: root.item?.status === "paused"
					text: "Wake it up"
					icon: "bell_ring_outline"
					variant: "tonal"
					onActivated: Streams.updateSeries(root.item.id, { resume: true })
				}
				TextButton {
					visible: root.item?.status === "active" || root.item?.status === "paused"
					text: "It's over"
					icon: "archive"
					variant: "tonal"
					onActivated: Streams.updateSeries(root.item.id, { status: "ended" })
				}
				TextButton {
					visible: root.item?.status === "ended" || root.item?.status === "archived"
					text: "It's back"
					icon: "restart"
					variant: "tonal"
					onActivated: Streams.updateSeries(root.item.id, { status: "active", keepGoing: true })
				}
				TextButton {
					text: "Delete series"
					icon: "delete_outline"
					variant: "ghost"
					confirm: true
					confirmText: "Delete it?"
					onActivated: {
						Streams.call("deleteSeries", { id: root.item.id });
						root.deleted();
					}
				}
			}
		}
	}
}
