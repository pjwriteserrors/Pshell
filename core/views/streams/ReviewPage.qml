pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// A year of watching: how much, when, what most.
Flickable {
	id: root

	property int year: new Date().getFullYear()
	property var review: null
	readonly property real peak: Math.max(1, ...(root.review?.months ?? [1]))
	property real grow: 0

	function load() {
		Streams.call("review", { year: root.year }, data => {
			if (!data) return;
			root.review = data;
			root.grow = 0;
			growIn.restart();
		});
	}

	onVisibleChanged: if (visible) load()
	onYearChanged: load()
	Component.onCompleted: load()

	NumberAnimation {
		id: growIn

		target: root
		property: "grow"
		from: 0
		to: 1
		duration: 900
		easing.type: Easing.OutCubic
	}

	contentHeight: column.implicitHeight + 40
	boundsBehavior: Flickable.StopAtBounds
	clip: true
	ScrollBar.vertical: ThinScrollBar {}

	ColumnLayout {
		id: column

		x: 44
		width: root.width - 88
		spacing: 22

		Item {
			Layout.preferredHeight: 64
		}

		RowLayout {
			spacing: 6

			IconButton {
				width: 30
				height: 30
				icon: "chevron_left"
				visible: root.year > (root.review?.firstYear ?? root.year)
				onClicked: root.year -= 1
			}
			StyledText {
				text: `Your ${root.year}`
				font.pixelSize: 40
				font.weight: Font.Black
				tabular: true
			}
			IconButton {
				width: 30
				height: 30
				icon: "chevron_right"
				visible: root.year < new Date().getFullYear()
				onClicked: root.year += 1
			}
		}

		// the one big figure
		ColumnLayout {
			spacing: 0

			Text {
				text: `${Math.round((root.review?.seconds ?? 0) / 3600 * root.grow)}`
				color: Theme.primary
				font.family: Theme.fontFamily
				font.pixelSize: 130
				font.weight: Font.Black
				font.features: { "tnum": 1 }
				lineHeight: 0.9
			}
			StyledText {
				text: "hours watched"
				font.pixelSize: Theme.size.heading + 2
				font.weight: Font.Bold
			}
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 44

			Repeater {
				model: [
					{ value: String(Math.round((root.review?.episodes ?? 0) * root.grow)), label: "episodes finished" },
					{ value: String(root.review?.activeDays ?? 0), label: "days with something on" },
					{ value: root.review?.longest ? Streams.span(root.review.longest.seconds) : "–", label: root.review?.longest ? `longest evening, ${Qt.formatDate(new Date(root.review.longest.day), "d MMMM")}` : "longest evening" }
				]

				ColumnLayout {
					required property var modelData

					spacing: 0

					StyledText {
						text: parent.modelData.value
						font.pixelSize: 34
						font.weight: Font.Black
						tabular: true
					}
					StyledText {
						text: parent.modelData.label
						font.pixelSize: Theme.size.body
						tone: Theme.textMuted
					}
				}
			}
		}

		// the months
		Item {
			Layout.fillWidth: true
			Layout.preferredHeight: 190

			Row {
				anchors.fill: parent
				spacing: 8

				Repeater {
					model: root.review?.months ?? []

					Item {
						id: month

						required property real modelData
						required property int index

						width: (parent.width - 88) / 12
						height: parent.height

						Rectangle {
							anchors.left: parent.left
							anchors.right: parent.right
							anchors.bottom: label.top
							anchors.bottomMargin: 6
							height: Math.max(month.modelData > 0 ? 4 : 2, (parent.height - 26) * month.modelData / root.peak * Math.max(0, Math.min(1, root.grow * 1.6 - month.index * 0.05)))
							radius: 5
							color: month.modelData > 0 ? Theme.primary : Theme.layer2
						}
						StyledText {
							id: label

							anchors.bottom: parent.bottom
							anchors.horizontalCenter: parent.horizontalCenter
							text: root.review?.monthNames?.[month.index] ?? ""
							font.pixelSize: Theme.size.small
							tone: Theme.textMuted
						}
					}
				}
			}
		}

		SectionHeading {
			visible: (root.review?.series ?? []).length > 0
			text: "Most watched"
		}

		Repeater {
			model: root.review?.series ?? []

			RowLayout {
				id: favourite

				required property var modelData
				required property int index

				Layout.fillWidth: true
				spacing: 12

				StyledText {
					Layout.preferredWidth: 180
					text: favourite.modelData.name
					font.weight: favourite.index === 0 ? Font.Bold : Font.Medium
					elide: Text.ElideRight
				}
				Item {
					Layout.fillWidth: true
					Layout.preferredHeight: 12

					Rectangle {
						height: parent.height
						radius: 6
						color: Streams.accent(favourite.modelData.colors)
						width: parent.width * favourite.modelData.seconds / Math.max(1, root.review.series[0].seconds) * root.grow
					}
				}
				StyledText {
					text: Streams.span(favourite.modelData.seconds)
					font.pixelSize: Theme.size.small
					tone: Theme.textMuted
					tabular: true
				}
			}
		}

		StyledText {
			Layout.fillWidth: true
			visible: (root.review?.seconds ?? 0) === 0
			text: "Nothing watched yet this year, as far as the shell can tell. It counts what plays in mpv and what the browser extension reports."
			tone: Theme.textMuted
			wrapMode: Text.Wrap
		}
	}
}
