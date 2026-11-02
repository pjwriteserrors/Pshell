pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services
import qs.core.views

// Every series as a wall of pictures: what runs, what rests, what is finished.
Flickable {
	id: root

	signal openSeries(string id, var from)
	signal newSeries(var preset)

	// current | resting | archive
	property string filter: "current"
	readonly property var shown: Streams.series.filter(item => root.filter === "current" ? item.status === "active" : (root.filter === "resting" ? item.status === "paused" : (item.status === "ended" || item.status === "archived")))
	readonly property var counts: ({
		current: Streams.series.filter(item => item.status === "active").length,
		resting: Streams.series.filter(item => item.status === "paused").length,
		archive: Streams.series.filter(item => item.status === "ended" || item.status === "archived").length
	})

	contentHeight: column.implicitHeight + 40
	boundsBehavior: Flickable.StopAtBounds
	clip: true
	ScrollBar.vertical: ThinScrollBar {}

	onShownChanged: model.sync(root.shown.map(item => ({ key: item.id })))
	Component.onCompleted: model.sync(root.shown.map(item => ({ key: item.id })))

	SyncedModel {
		id: model
	}

	ColumnLayout {
		id: column

		x: 44
		width: root.width - 88
		spacing: 18

		Item {
			Layout.preferredHeight: 64
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 22

			Text {
				text: "Series"
				color: Theme.text
				font.family: Theme.fontFamily
				font.pixelSize: 40
				font.weight: Font.Black
			}

			Repeater {
				model: [{ id: "current", label: "Running" }, { id: "resting", label: "Resting" }, { id: "archive", label: "Finished" }]

				Item {
					id: tab

					required property var modelData
					readonly property bool active: root.filter === tab.modelData.id

					visible: tab.active || root.counts[tab.modelData.id] > 0
					implicitWidth: tabWord.implicitWidth
					implicitHeight: 40

					StyledText {
						id: tabWord

						anchors.centerIn: parent
						text: tab.modelData.label
						font.pixelSize: Theme.size.title
						font.weight: tab.active ? Font.Bold : Font.Medium
						tone: tab.active ? Theme.text : Theme.textMuted
					}
					Rectangle {
						anchors.bottom: parent.bottom
						anchors.horizontalCenter: parent.horizontalCenter
						height: 3
						radius: 2
						width: tab.active ? parent.width : 0
						color: Theme.text

						Behavior on width {
							SpatialAnim {
								duration: Motion.long
							}
						}
					}
					MouseArea {
						anchors.fill: parent
						cursorShape: Qt.PointingHandCursor
						onClicked: root.filter = tab.modelData.id
					}
				}
			}

			Item {
				Layout.fillWidth: true
			}
		}

		// a series that went quiet: over?
		Repeater {
			model: Streams.series.filter(item => item.quiet)

			Rectangle {
				id: quiet

				required property var modelData

				Layout.fillWidth: true
				implicitHeight: 56
				radius: Theme.radius.large
				color: Theme.layer1

				RowLayout {
					anchors.fill: parent
					anchors.leftMargin: 16
					anchors.rightMargin: 10
					spacing: 8

					StyledText {
						Layout.fillWidth: true
						text: `${quiet.modelData.name} has been quiet since ${Streams.ago(quiet.modelData.lastEpisode)}. Is it over?`
						font.pixelSize: Theme.size.body
						elide: Text.ElideRight
					}
					TextButton {
						text: "It's over"
						variant: "tonal"
						onActivated: Streams.updateSeries(quiet.modelData.id, { status: "ended" })
					}
					TextButton {
						text: "Keep waiting"
						variant: "ghost"
						onActivated: Streams.updateSeries(quiet.modelData.id, { keepGoing: true })
					}
				}
			}
		}

		GridView {
			id: grid

			// few series get large cards rather than a mostly empty page
			readonly property int columns: Math.max(1, Math.min(Math.floor((width + 16) / 300), Math.max(3, model.count)))

			Layout.fillWidth: true
			Layout.preferredHeight: Math.ceil(model.count / grid.columns) * grid.cellHeight
			interactive: false
			cellWidth: Math.floor(width / grid.columns)
			cellHeight: Math.round((grid.cellWidth - 16) * 9 / 16) + 86
			model: model

			add: Transition {
				ParallelAnimation {
					SpatialAnim {
						property: "scale"
						from: 0.85
						to: 1
						duration: Motion.extraLong
					}
					Anim {
						property: "opacity"
						from: 0
						to: 1
						duration: Motion.long
					}
				}
			}
			displaced: Transition {
				SpatialAnim {
					properties: "x,y"
					duration: Motion.long
				}
			}

			delegate: Item {
				id: cell

				required property string key

				width: grid.cellWidth
				height: grid.cellHeight
				z: card.lifted ? 10 : 0

				SeriesCard {
					id: card

					anchors.fill: parent
					anchors.rightMargin: 16
					anchors.bottomMargin: 20
					seriesId: cell.key
					onOpened: from => root.openSeries(cell.key, from)
				}
			}
		}

		// nothing in this tab
		ColumnLayout {
			Layout.alignment: Qt.AlignHCenter
			Layout.topMargin: 80
			visible: model.count === 0
			spacing: 12

			Text {
				Layout.alignment: Qt.AlignHCenter
				text: root.filter === "current" ? "No series yet" : (root.filter === "resting" ? "Nothing is resting" : "Nothing finished yet")
				color: Theme.text
				font.family: Theme.fontFamily
				font.pixelSize: 30
				font.weight: Font.Black
			}
			StyledText {
				Layout.alignment: Qt.AlignHCenter
				visible: root.filter === "current"
				text: "Collect what belongs together, from a playlist or by keywords."
				tone: Theme.textMuted
				font.pixelSize: Theme.size.title
			}
			BigButton {
				Layout.alignment: Qt.AlignHCenter
				Layout.topMargin: 6
				visible: root.filter === "current"
				text: "New series"
				icon: "plus"
				onClicked: root.newSeries(null)
			}
		}
	}
}
