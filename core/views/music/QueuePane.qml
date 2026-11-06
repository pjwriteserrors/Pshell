pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import qs.style.theme
import qs.style.widgets
import qs.core.services

// What plays and what comes: a row per song with its cover, the one that
// plays lit and moving. A click plays it, the handle drags it elsewhere,
// the cross takes it out. The rows are a ListModel kept in step with the
// queue by small edits, so moving one song does not rebuild the list.
Item {
	id: root

	property color accent: Theme.primary

	ListModel {
		id: rows
	}

	// the queue as the fewest moves, inserts and removals
	function sync() {
		const want = Music.queue;
		for (let i = 0; i < want.length; i += 1) {
			if (i < rows.count && rows.get(i).path === want[i]) continue;
			let found = -1;
			for (let j = i + 1; j < rows.count; j += 1) {
				if (rows.get(j).path === want[i]) {
					found = j;
					break;
				}
			}
			if (found >= 0) rows.move(found, i, 1);
			else rows.insert(i, { path: want[i] });
		}
		if (rows.count > want.length) rows.remove(want.length, rows.count - want.length);
	}

	Connections {
		target: Music

		function onQueueChanged() {
			root.sync();
		}

		function onIndexChanged() {
			if (!list.dragging && Music.index >= 0) list.positionViewAtIndex(Music.index, ListView.Contain);
		}
	}

	Component.onCompleted: {
		root.sync();
		if (Music.index >= 0) list.positionViewAtIndex(Music.index, ListView.Center);
	}

	readonly property real totalLeft: {
		let sum = 0;
		for (let i = Math.max(0, Music.index); i < Music.queue.length; i += 1) sum += Number(Music.tags[Music.queue[i]]?.duration || 0);
		return Math.max(0, sum - Music.position);
	}

	StyledText {
		id: heading

		x: 4
		text: "Queue"
		font.pixelSize: Theme.size.heading
		font.weight: Font.Bold
	}

	StyledText {
		anchors.left: heading.right
		anchors.leftMargin: 10
		anchors.baseline: heading.baseline
		tone: Theme.textMuted
		tabular: true
		font.pixelSize: Theme.size.small
		text: Music.queue.length === 0 ? "" : `${Music.queue.length} ${Music.queue.length === 1 ? "song" : "songs"} · ${Music.formatTime(root.totalLeft)} left`
	}

	ListView {
		id: list

		property bool dragging: false
		property int dragFrom: -1
		property int dragTo: -1

		anchors.fill: parent
		anchors.topMargin: heading.height + 14
		model: rows
		clip: true
		spacing: 2
		interactive: !list.dragging
		boundsBehavior: Flickable.StopAtBounds
		cacheBuffer: 400
		reuseItems: true

		add: Transition {
			ParallelAnimation {
				NumberAnimation {
					property: "opacity"
					from: 0
					to: 1
					duration: Motion.long
				}
				NumberAnimation {
					property: "x"
					from: 24
					to: 0
					duration: Motion.long
					easing.type: Easing.BezierSpline
					easing.bezierCurve: Motion.spatial
				}
			}
		}
		remove: Transition {
			ParallelAnimation {
				NumberAnimation {
					property: "opacity"
					to: 0
					duration: Motion.medium
				}
				NumberAnimation {
					property: "x"
					to: -24
					duration: Motion.medium
				}
			}
		}
		displaced: Transition {
			NumberAnimation {
				properties: "y"
				duration: Motion.long
				easing.type: Easing.BezierSpline
				easing.bezierCurve: Motion.spatial
			}
		}
		move: Transition {
			NumberAnimation {
				properties: "y"
				duration: Motion.long
				easing.type: Easing.BezierSpline
				easing.bezierCurve: Motion.spatial
			}
		}

		ScrollBar.vertical: ThinScrollBar {}

		delegate: Item {
			id: row

			required property string path
			required property int index
			readonly property bool playing: row.index === Music.index
			readonly property bool past: Music.index >= 0 && row.index < Music.index
			readonly property bool lifted: list.dragging && list.dragFrom === row.index
			property real dragY: 0

			width: list.width
			height: 56
			z: row.lifted ? 10 : 1

			onPathChanged: Music.wantCover(row.path)
			Component.onCompleted: Music.wantCover(row.path)

			// where a dragged song would land
			Rectangle {
				visible: list.dragging && list.dragTo === row.index && list.dragFrom !== row.index
				y: list.dragTo > list.dragFrom ? parent.height - 1 : -1
				width: parent.width
				height: 2
				radius: 1
				color: root.accent
			}

			Rectangle {
				id: card

				y: row.lifted ? row.dragY : 0
				width: parent.width
				height: parent.height
				radius: Theme.radius.medium
				scale: row.lifted ? 1.02 : 1
				color: row.playing ? Qt.alpha(root.accent, 0.16) : (rowMouse.containsMouse || row.lifted ? Theme.layer2 : "transparent")
				border.width: row.lifted ? 1 : 0
				border.color: Theme.outline

				Behavior on color {
					ColorAnimation {
						duration: Motion.medium
					}
				}

				Behavior on scale {
					Anim {}
				}

				MouseArea {
					id: rowMouse

					anchors.fill: parent
					hoverEnabled: true
					cursorShape: Qt.PointingHandCursor
					acceptedButtons: Qt.LeftButton | Qt.MiddleButton
					onClicked: mouse => {
						if (mouse.button === Qt.MiddleButton) Music.remove(row.index);
						else if (!row.playing) Music.jump(row.index);
						else Music.toggle();
					}
				}

				// the number, or bars that move while it plays
				Item {
					id: lead

					x: 6
					width: 26
					height: parent.height

					StyledText {
						anchors.centerIn: parent
						visible: !row.playing
						text: String(row.index + 1)
						tabular: true
						tone: row.past ? Theme.textFaint : Theme.textSubtle
						font.pixelSize: Theme.size.small
					}

					Row {
						anchors.centerIn: parent
						visible: row.playing
						spacing: 2
						height: 14

						Repeater {
							model: 3

							delegate: Rectangle {
								id: bar

								required property int index

								anchors.bottom: parent.bottom
								width: 3
								radius: 1.5
								color: root.accent
								height: 4

								SequentialAnimation on height {
									running: row.playing && Music.playing && Music.watching
									loops: Animation.Infinite
									alwaysRunToEnd: true

									PauseAnimation {
										duration: bar.index * 110
									}
									NumberAnimation {
										to: 14
										duration: 260 + bar.index * 40
										easing.type: Easing.OutQuad
									}
									NumberAnimation {
										to: 4
										duration: 300 + bar.index * 50
										easing.type: Easing.InOutQuad
									}
								}
							}
						}
					}
				}

				Rectangle {
					id: thumb

					anchors.left: lead.right
					anchors.leftMargin: 6
					anchors.verticalCenter: parent.verticalCenter
					width: 40
					height: 40
					radius: Theme.radius.small
					color: Theme.layer2
					clip: true

					Glyph {
						anchors.centerIn: parent
						icon: "music_note"
						size: 18
						color: Theme.textSubtle
						visible: thumbImage.status !== Image.Ready
					}

					Image {
						id: thumbImage

						anchors.fill: parent
						source: Music.covers[row.path]?.art ? "file://" + Music.covers[row.path].art : ""
						sourceSize: Qt.size(80, 80)
						fillMode: Image.PreserveAspectCrop
						asynchronous: true
						opacity: status === Image.Ready ? (row.past ? 0.55 : 1) : 0

						Behavior on opacity {
							Anim {}
						}
					}
				}

				Column {
					anchors.left: thumb.right
					anchors.leftMargin: 12
					anchors.right: tail.left
					anchors.rightMargin: 8
					anchors.verticalCenter: parent.verticalCenter
					spacing: 2

					StyledText {
						width: parent.width
						text: Music.titleOf(row.path)
						elide: Text.ElideRight
						tone: row.playing ? root.accent : (row.past ? Theme.textSubtle : Theme.text)
						font.weight: row.playing ? Font.Bold : Font.Medium
					}

					StyledText {
						width: parent.width
						visible: text !== ""
						text: [Music.tags[row.path]?.artist, Music.tags[row.path]?.album].filter(t => t).join(" · ")
						elide: Text.ElideRight
						tone: row.past ? Theme.textFaint : Theme.textMuted
						font.pixelSize: Theme.size.small
					}
				}

				Item {
					id: tail

					anchors.right: parent.right
					anchors.rightMargin: 6
					width: 76
					height: parent.height

					StyledText {
						anchors.right: parent.right
						anchors.rightMargin: 4
						anchors.verticalCenter: parent.verticalCenter
						visible: !rowMouse.containsMouse && !handle.containsMouse && !removeButton.hovered
						text: Music.tags[row.path]?.duration ? Music.formatTime(Music.tags[row.path].duration) : ""
						tabular: true
						tone: Theme.textSubtle
						font.pixelSize: Theme.size.small
					}

					IconButton {
						id: removeButton

						anchors.right: dragHandle.left
						anchors.verticalCenter: parent.verticalCenter
						width: 30
						height: 30
						icon: "close"
						visible: rowMouse.containsMouse || hovered || handle.containsMouse
						onClicked: Music.remove(row.index)
					}

					Item {
						id: dragHandle

						anchors.right: parent.right
						anchors.verticalCenter: parent.verticalCenter
						width: 30
						height: 30
						visible: rowMouse.containsMouse || removeButton.hovered || handle.containsMouse || row.lifted

						Glyph {
							anchors.centerIn: parent
							icon: "drag_horizontal_variant"
							size: 18
							color: Theme.textMuted
						}

						MouseArea {
							id: handle

							property real startY: 0

							anchors.fill: parent
							hoverEnabled: true
							cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
							preventStealing: true
							onPressed: mouse => {
								handle.startY = handle.mapToItem(list.contentItem, mouse.x, mouse.y).y;
								row.dragY = 0;
								list.dragFrom = row.index;
								list.dragTo = row.index;
								list.dragging = true;
							}
							onPositionChanged: mouse => {
								if (!pressed) return;
								const y = handle.mapToItem(list.contentItem, mouse.x, mouse.y).y;
								row.dragY = y - handle.startY;
								const step = row.height + list.spacing;
								list.dragTo = Math.max(0, Math.min(rows.count - 1, row.index + Math.round(row.dragY / step)));
							}
							onReleased: {
								const from = list.dragFrom, to = list.dragTo;
								list.dragging = false;
								row.dragY = 0;
								if (from >= 0 && to >= 0 && from !== to) Music.move(from, to);
							}
							onCanceled: {
								list.dragging = false;
								row.dragY = 0;
							}
						}
					}
				}
			}
		}

		EmptyState {
			anchors.centerIn: parent
			visible: rows.count === 0
			icon: "playlist_music"
			title: "Nothing queued"
			subtitle: "Drop songs here, or open some from Files"
		}
	}
}
