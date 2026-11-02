pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services
import qs.core.views

// The series inside a series, the newest first. Each one can be followed on its
// own; a suggestion can still be followed as one.
Rectangle {
	id: root

	property var what: null
	property var followed: []
	readonly property var parts: root.what?.parts ?? []
	readonly property var first: root.parts[0] ?? null

	signal close
	signal openSeries(string id)

	color: Streams.pageColor

	function show(what) {
		root.what = what;
		root.followed = [];
	}

	// the newest part's picture, large behind everything
	Thumb {
		anchors.left: parent.left
		anchors.right: parent.right
		height: parent.height * 0.5
		radius: 0
		source: root.first?.pictures?.[0] ?? ""
		large: Streams.large(/\/([\w-]{11})\.jpg$/.exec(root.first?.pictures?.[0] ?? "")?.[1] ?? "")
		colors: root.what?.whole?.colors ?? null

		Rectangle {
			anchors.fill: parent
			gradient: Gradient {
				orientation: Gradient.Horizontal
				GradientStop {
					position: 0
					color: Qt.rgba(0, 0, 0, 0.85)
				}
				GradientStop {
					position: 0.85
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

	Flickable {
		anchors.fill: parent
		contentHeight: column.implicitHeight + 40
		boundsBehavior: Flickable.StopAtBounds
		clip: true
		ScrollBar.vertical: ThinScrollBar {}

		ColumnLayout {
			id: column

			x: 44
			width: root.width - 88
			spacing: 14

			Rectangle {
				Layout.topMargin: 16
				Layout.leftMargin: -24
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
				Layout.preferredHeight: Math.max(30, root.height * 0.13)
			}

			Text {
				text: `${root.parts.length} series inside`
				color: Qt.rgba(1, 1, 1, 0.82)
				font.family: Theme.fontFamily
				font.pixelSize: Theme.size.heading
				font.weight: Font.Medium
			}
			Text {
				Layout.fillWidth: true
				text: root.what?.name ?? ""
				color: "white"
				font.family: Theme.fontFamily
				font.pixelSize: 58
				font.weight: Font.Black
				elide: Text.ElideRight
			}
			BigButton {
				visible: !!root.what?.whole
				text: `Follow all ${root.what?.whole?.count ?? ""} as one series`
				icon: "plus"
				main: false
				onClicked: Streams.followDiscovery(root.what.whole.key, data => {
					if (data) root.openSeries(data.id);
				})
			}

			GridLayout {
				Layout.fillWidth: true
				Layout.topMargin: 20
				columns: Math.max(2, Math.min(4, Math.floor(column.width / 320)))
				columnSpacing: 16
				rowSpacing: 18

				Repeater {
					model: root.parts

					CardFrame {
						id: part

						required property var modelData
						readonly property bool done: part.modelData.followed || root.followed.includes(part.modelData.name)
						property int shown: 0

						Layout.fillWidth: true
						Layout.preferredHeight: Math.round(width * 9 / 16) + 66
						source: part.modelData.pictures[part.shown % Math.max(1, part.modelData.pictures.length)] ?? ""
						colors: root.what?.whole?.colors ?? null
						accent: Streams.accent(root.what?.whole?.colors)
						dimmed: part.done
						onHoveredChanged: if (!part.hovered) part.shown = 0

						Timer {
							interval: 1100
							repeat: true
							running: part.hovered && part.modelData.pictures.length > 1
							onTriggered: part.shown += 1
						}

						overlay: [
							Rectangle {
								anchors.left: parent.left
								anchors.right: parent.right
								anchors.bottom: parent.bottom
								height: parent.height * 0.6
								bottomLeftRadius: Theme.radius.large
								bottomRightRadius: Theme.radius.large
								gradient: Gradient {
									GradientStop {
										position: 0
										color: Qt.rgba(0, 0, 0, 0)
									}
									GradientStop {
										position: 1
										color: Qt.rgba(0, 0, 0, 0.88)
									}
								}
							},
							ColumnLayout {
								anchors.left: parent.left
								anchors.right: parent.right
								anchors.bottom: parent.bottom
								anchors.margins: 12
								spacing: 0

								Text {
									Layout.fillWidth: true
									text: part.modelData.name
									color: "white"
									font.family: Theme.fontFamily
									font.pixelSize: Theme.size.heading + 2
									font.weight: Font.Black
									wrapMode: Text.Wrap
									maximumLineCount: 2
									elide: Text.ElideRight
								}
								Text {
									text: [`${part.modelData.count} episodes`, part.modelData.seconds ? Streams.span(part.modelData.seconds) : ""].filter(word => !!word).join(" · ")
									color: Qt.rgba(1, 1, 1, 0.82)
									font.family: Theme.fontFamily
									font.pixelSize: Theme.size.small
									font.weight: Font.Medium
								}
							}
						]

						RowLayout {
							anchors.left: parent.left
							anchors.right: parent.right
							spacing: 8

							ColumnLayout {
								Layout.fillWidth: true
								spacing: 0

								StyledText {
									Layout.fillWidth: true
									text: part.modelData.newest ? `Newest ${Streams.ago(part.modelData.newest)}` : ""
									font.pixelSize: Theme.size.label
									font.weight: Font.DemiBold
									elide: Text.ElideRight
								}
								StyledText {
									Layout.fillWidth: true
									text: part.modelData.why
									font.pixelSize: Theme.size.small
									tone: Theme.textMuted
									elide: Text.ElideRight
								}
							}
							BigButton {
								implicitHeight: 34
								main: !part.done
								enabled: !part.done
								text: part.done ? "Following" : "Follow"
								icon: part.done ? "check" : "plus"
								onClicked: Streams.followPart(part.modelData, data => {
									if (data) root.followed = root.followed.concat([part.modelData.name]);
								})
							}
						}
					}
				}
			}
		}
	}
}
