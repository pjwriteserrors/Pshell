pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services
import qs.core.views

// An evening's worth: how long there is, what fits. The list reshuffles as
// the time changes; episodes can be taken out and the rest runs back to back.
Rectangle {
	id: root

	property bool open: false
	property int minutes: 90
	property var items: []
	property var removed: []
	readonly property var kept: root.items.filter(item => !root.removed.includes(item.id))
	readonly property real seconds: root.kept.reduce((sum, item) => sum + item.seconds, 0)

	signal close

	function show() {
		root.removed = [];
		root.open = true;
		root.ask();
	}

	function ask() {
		Streams.call("tonight", { minutes: root.minutes }, data => {
			if (!data) return;
			root.items = data.items;
			model.sync(root.kept.map(item => ({ key: item.id })));
		});
	}

	function start() {
		if (root.kept.length === 0) return;
		Streams.play(root.kept[0].id, "", root.kept.map(item => item.id));
		root.close();
	}

	onMinutesChanged: debounce.restart()
	onKeptChanged: model.sync(root.kept.map(item => ({ key: item.id })))

	Timer {
		id: debounce

		interval: 120
		onTriggered: root.ask()
	}

	SyncedModel {
		id: model
	}

	color: Streams.pageColor

	// the first episode, large behind everything
	Thumb {
		anchors.left: parent.left
		anchors.right: parent.right
		height: parent.height * 0.62
		radius: 0
		source: root.kept[0]?.thumb ?? ""
		large: root.kept[0]?.spoiler ? "" : Streams.large(root.kept[0]?.id ?? "")
		colors: root.kept[0]?.colors ?? null
		spoiler: root.kept[0]?.spoiler ?? false

		Rectangle {
			anchors.fill: parent
			gradient: Gradient {
				orientation: Gradient.Horizontal
				GradientStop {
					position: 0
					color: Qt.rgba(0, 0, 0, 0.85)
				}
				GradientStop {
					position: 0.9
					color: Qt.rgba(0, 0, 0, 0.1)
				}
			}
		}
		Rectangle {
			anchors.fill: parent
			gradient: Gradient {
				GradientStop {
					position: 0.15
					color: Qt.alpha(Theme.base, 0)
				}
				GradientStop {
					position: 0.92
					color: Theme.base
				}
			}
		}
	}

	ColumnLayout {
		anchors.fill: parent
		spacing: 0

		Rectangle {
			Layout.leftMargin: 20
			Layout.topMargin: 16
			width: 44
			height: 44
			radius: 22
			color: Qt.rgba(0, 0, 0, backArea.containsMouse ? 0.75 : 0.45)

			Glyph {
				anchors.centerIn: parent
				icon: "arrow_left"
				size: 24
				color: "white"
				surface: "black"
			}
			MouseArea {
				id: backArea

				anchors.fill: parent
				hoverEnabled: true
				cursorShape: Qt.PointingHandCursor
				onClicked: root.close()
			}
		}

		Item {
			Layout.fillHeight: true
		}

		ColumnLayout {
			Layout.leftMargin: 44
			Layout.rightMargin: 44
			Layout.fillWidth: true
			spacing: 6

			Text {
				text: "Tonight you have"
				color: Qt.rgba(1, 1, 1, 0.8)
				font.family: Theme.fontFamily
				font.pixelSize: Theme.size.heading
				font.weight: Font.Medium
			}
			Text {
				text: Streams.span(root.minutes * 60)
				color: "white"
				font.family: Theme.fontFamily
				font.pixelSize: 72
				font.weight: Font.Black
				font.features: { "tnum": 1 }
			}

			RowLayout {
				Layout.fillWidth: true
				Layout.topMargin: 6
				spacing: 14

				PillSlider {
					Layout.fillWidth: true
					Layout.maximumWidth: 460
					Layout.preferredHeight: 26
					value: (root.minutes - 15) / 345
					stepSize: 15 / 345
					showValue: false
					onMoved: value => root.minutes = 15 + Math.round(value * 345 / 15) * 15
				}
				Row {
					spacing: 5
					Repeater {
						model: [20, 45, 60, 90, 120, 180]

						Chip {
							required property int modelData

							text: Streams.span(modelData * 60)
							selected: root.minutes === modelData
							onClicked: root.minutes = modelData
						}
					}
				}
				Item {
					Layout.fillWidth: true
				}
				BigButton {
					visible: root.kept.length > 0
					text: `Play ${root.kept.length} · ${Streams.span(root.seconds)}`
					icon: "play"
					onClicked: root.start()
				}
			}
		}

		// the strip
		ListView {
			id: strip

			Layout.fillWidth: true
			Layout.preferredHeight: Math.round(strip.cardWidth * 9 / 16) + 94
			Layout.topMargin: 20
			Layout.bottomMargin: 18
			readonly property real cardWidth: Math.max(250, Math.min(380, (root.width - 88 - 14 * Math.max(0, model.count - 1)) / Math.max(3.4, model.count)))

			orientation: ListView.Horizontal
			leftMargin: 44
			rightMargin: 44
			spacing: 14
			clip: true
			model: model
			boundsBehavior: Flickable.StopAtBounds

			add: Transition {
				ParallelAnimation {
					SpatialAnim {
						property: "scale"
						from: 0.75
						to: 1
						duration: Motion.extraLong
					}
					Anim {
						property: "opacity"
						from: 0
						to: 1
					}
				}
			}
			remove: Transition {
				ParallelAnimation {
					Anim {
						property: "opacity"
						to: 0
						duration: Motion.medium
					}
					Anim {
						property: "scale"
						to: 0.8
						duration: Motion.medium
					}
				}
			}
			displaced: Transition {
				SpatialAnim {
					property: "x"
					duration: Motion.long
				}
			}

			delegate: Item {
				id: row

				required property string key
				required property int index
				readonly property var item: root.items.find(entry => entry.id === row.key) ?? null

				width: strip.cardWidth
				height: strip.height
				z: card.lifted ? 10 : 0

				CardFrame {
					id: card

					anchors.fill: parent
					anchors.topMargin: 14
					anchors.bottomMargin: 8
					source: row.item?.thumb ?? ""
					colors: row.item?.colors ?? null
					spoiler: row.item?.spoiler ?? false
					accent: Streams.accent(row.item?.colors)
					onClicked: {
						Streams.play(row.key, "", root.kept.map(item => item.id).slice(row.index));
						root.close();
					}

					overlay: [
						Text {
							x: 12
							y: 4
							text: row.index + 1
							color: "white"
							font.family: Theme.fontFamily
							font.pixelSize: 44
							font.weight: Font.Black
							style: Text.Raised
							styleColor: Qt.rgba(0, 0, 0, 0.5)
						},
						Rectangle {
							anchors.right: parent.right
							anchors.top: parent.top
							anchors.margins: 8
							width: 30
							height: 30
							radius: 15
							color: Qt.rgba(0, 0, 0, 0.6)
							opacity: card.hovered ? 1 : 0
							visible: opacity > 0.01

							Behavior on opacity {
								Anim {
									duration: Motion.short
								}
							}

							Glyph {
								anchors.centerIn: parent
								icon: "close"
								size: 16
								color: "white"
								surface: "black"
							}
							MouseArea {
								anchors.fill: parent
								cursorShape: Qt.PointingHandCursor
								onClicked: root.removed = root.removed.concat([row.key])
							}
						},
						PlayMark {
							shown: card.hovered
							onClicked: {
								Streams.play(row.key, "", root.kept.map(item => item.id).slice(row.index));
								root.close();
							}
						}
					]

					ColumnLayout {
						anchors.left: parent.left
						anchors.right: parent.right
						spacing: 1

						StyledText {
							Layout.fillWidth: true
							text: row.item?.spoiler && !card.hovered ? `Episode ${row.item?.n}` : (row.item?.title ?? "")
							font.pixelSize: Theme.size.body
							font.weight: Font.DemiBold
							elide: Text.ElideRight
						}
						StyledText {
							Layout.fillWidth: true
							text: `${row.item?.seriesName ?? ""} · ${row.item?.known ? "" : "about "}${Streams.span(row.item?.seconds ?? 0)}`
							font.pixelSize: Theme.size.small
							tone: Theme.textMuted
							elide: Text.ElideRight
						}
					}
				}
			}
		}

		StyledText {
			Layout.alignment: Qt.AlignHCenter
			Layout.bottomMargin: 80
			visible: root.kept.length === 0
			text: Streams.openSeries.length === 0 ? "Every episode is watched." : "Nothing fits. Give it a little more time."
			tone: Theme.textMuted
			font.pixelSize: Theme.size.title
		}
	}
}
