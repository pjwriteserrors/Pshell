pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import qs.style.theme
import qs.core.services
import qs.style.widgets

// The words of the song. With timing the line that is sung stands out and
// stays in the middle, and a click on a line jumps there; scrolling away is
// undone by the next line. Without timing the text drifts along with the
// song, as far through as the song is; scrolling holds it for a moment.
Rectangle {
	id: root

	readonly property bool found: Lyrics.state === "found"
	// how far an untimed text has drifted
	readonly property bool drifting: root.found && !Lyrics.synced && Media.hasProgress
	property real drift: root.drifting ? Media.position / Media.length : 0

	Behavior on drift {
		enabled: root.drifting && Media.playing
		NumberAnimation {
			duration: 1000
		}
	}

	onDriftChanged: root.place()

	function place() {
		if (!root.drifting || list.moving || hold.running) return;
		list.contentY = list.originY - list.topMargin + root.drift * Math.max(0, list.contentHeight + list.topMargin + list.bottomMargin - list.height);
	}

	Connections {
		target: Lyrics
		function onLinesChanged() {
			Qt.callLater(root.place);
		}
	}

	Timer {
		id: hold

		interval: 6000
		onTriggered: root.place()
	}

	implicitHeight: root.found ? 232 : 56
	radius: Theme.radius.large
	color: Theme.layer1

	ListView {
		id: list

		anchors.fill: parent
		anchors.leftMargin: 18
		anchors.rightMargin: 12
		clip: true
		visible: root.found
		model: root.found ? Lyrics.lines : []
		spacing: 10
		topMargin: Lyrics.synced ? height / 2 - 24 : 16
		bottomMargin: Lyrics.synced ? height / 2 - 24 : 16
		boundsBehavior: Flickable.StopAtBounds
		currentIndex: Lyrics.current
		highlightFollowsCurrentItem: true
		highlightRangeMode: ListView.ApplyRange
		preferredHighlightBegin: height / 2 - 24
		preferredHighlightEnd: height / 2 + 24
		highlightMoveDuration: Motion.long
		highlightMoveVelocity: -1
		// every line laid out, so the height of the text is known
		cacheBuffer: 8000
		onMovementEnded: hold.restart()

		ScrollBar.vertical: ThinScrollBar {}

		delegate: Item {
			id: line

			required property var modelData
			required property int index
			readonly property bool pause: line.modelData.text === ""
			readonly property bool sung: line.index === Lyrics.current
			readonly property bool jumps: Lyrics.synced && (Media.player?.canSeek ?? false)

			width: list.width - 10
			implicitHeight: line.pause ? (Lyrics.synced ? 18 : 6) : words.implicitHeight

			StyledText {
				id: words

				width: parent.width
				visible: !line.pause
				text: line.modelData.text
				tone: !Lyrics.synced || line.sung ? Theme.text : Theme.textMuted
				font.pixelSize: Lyrics.synced ? Theme.size.heading : Theme.size.body
				font.weight: Lyrics.synced ? Font.Bold : Font.Medium
				wrapMode: Text.WordWrap
				lineHeight: 1.1
				opacity: !Lyrics.synced || line.sung ? 1 : (lineMouse.containsMouse ? 0.8 : 0.5)
				scale: !Lyrics.synced || line.sung ? 1 : 0.94
				transformOrigin: Item.Left

				Behavior on scale {
					SpatialAnim {
						duration: Motion.medium
					}
				}
				Behavior on opacity {
					Anim {
						duration: Motion.medium
					}
				}
			}

			Glyph {
				anchors.verticalCenter: parent.verticalCenter
				visible: line.pause && Lyrics.synced
				icon: "music_note"
				size: 16
				color: line.sung ? Theme.primary : Theme.textSubtle
			}

			MouseArea {
				id: lineMouse

				anchors.fill: parent
				enabled: line.jumps
				hoverEnabled: true
				cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
				onClicked: Media.seekTo(line.modelData.t)
			}
		}
	}

	// lines come and go through the edges
	Repeater {
		model: root.found ? 2 : 0

		delegate: Rectangle {
			required property int index

			anchors.left: parent.left
			anchors.right: parent.right
			y: index === 0 ? 0 : parent.height - height
			height: 44
			topLeftRadius: index === 0 ? root.radius : 0
			topRightRadius: index === 0 ? root.radius : 0
			bottomLeftRadius: index === 0 ? 0 : root.radius
			bottomRightRadius: index === 0 ? 0 : root.radius
			gradient: Gradient {
				GradientStop { position: index === 0 ? 0 : 1; color: Theme.layer1 }
				GradientStop { position: index === 0 ? 1 : 0; color: Qt.alpha(Theme.layer1, 0) }
			}
		}
	}

	Spinner {
		anchors.centerIn: parent
		visible: Lyrics.state === "loading"
	}

	StyledText {
		anchors.centerIn: parent
		visible: Lyrics.state === "none" || Lyrics.state === "error"
		text: Lyrics.state === "none" ? "No lyrics" : "Lyrics unavailable"
		tone: Theme.textMuted
		font.pixelSize: Theme.size.label
	}
}
