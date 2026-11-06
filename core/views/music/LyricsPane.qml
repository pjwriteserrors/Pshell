pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import qs.style.theme
import qs.style.widgets
import qs.core.services

// The words of the song: from an .lrc beside it or its own tag, else from
// LRCLIB (scripts/lyrics.py). Timed words follow the song – the line that
// is sung large and lit, the ones around it fading – and a click on a line
// goes there. Scrolling by hand lets it be until the next line comes.
Item {
	id: root

	property color accent: Theme.primary

	readonly property var lines: Music.lyrics.lines ?? []
	readonly property bool synced: !!Music.lyrics.synced
	readonly property string state: Music.lyrics.state ?? ""

	StyledText {
		id: heading

		x: 4
		text: "Lyrics"
		font.pixelSize: Theme.size.heading
		font.weight: Font.Bold
	}

	StyledText {
		anchors.left: heading.right
		anchors.leftMargin: 10
		anchors.baseline: heading.baseline
		tone: Theme.textMuted
		font.pixelSize: Theme.size.small
		text: root.state !== "found" ? "" : (Music.lyrics.source === "file" ? "from the file" : "from LRCLIB") + (root.synced ? "" : " · not timed")
	}

	ListView {
		id: list

		// a hand on the wheel: the words wait for it a moment
		property bool held: false

		anchors.fill: parent
		anchors.topMargin: heading.height + 14
		visible: root.state === "found"
		model: root.lines
		clip: true
		spacing: 10
		boundsBehavior: Flickable.StopAtBounds
		highlightRangeMode: root.synced && !list.held ? ListView.ApplyRange : ListView.NoHighlightRange
		preferredHighlightBegin: height * 0.36
		preferredHighlightEnd: height * 0.46
		highlightMoveDuration: 600
		highlightMoveVelocity: -1
		currentIndex: Math.max(0, Music.lyricLine)
		header: Item {
			height: root.synced ? list.height * 0.3 : 8
		}
		footer: Item {
			height: root.synced ? list.height * 0.5 : 8
		}
		onMovementStarted: {
			list.held = true;
			release.restart();
		}

		Timer {
			id: release

			interval: 3500
			onTriggered: list.held = false
		}

		ScrollBar.vertical: ThinScrollBar {}

		delegate: Text {
			id: line

			required property var modelData
			required property int index
			readonly property int distance: Music.lyricLine < 0 ? 0 : Math.abs(line.index - Music.lyricLine)
			readonly property bool sung: root.synced && line.index === Music.lyricLine

			width: list.width - 12
			x: 4
			text: String(line.modelData.text || "♪")
			wrapMode: Text.WordWrap
			color: !root.synced ? Theme.text : (line.sung ? root.accent : Theme.text)
			opacity: !root.synced ? 0.92 : (line.sung ? 1 : Math.max(0.22, 0.62 - line.distance * 0.1))
			font.family: Theme.fontFamily
			font.pixelSize: root.synced ? 22 : Theme.size.title
			font.weight: line.sung ? Font.Black : Font.Bold
			scale: line.sung ? 1 : 0.94
			transformOrigin: Item.Left

			Behavior on opacity {
				Anim {
					duration: Motion.long
				}
			}

			Behavior on scale {
				SpatialAnim {}
			}

			Behavior on color {
				ColorAnimation {
					duration: Motion.long
				}
			}

			MouseArea {
				anchors.fill: parent
				enabled: root.synced && line.modelData.t >= 0
				cursorShape: Qt.PointingHandCursor
				onClicked: {
					list.held = false;
					Music.seek(line.modelData.t);
				}
			}
		}
	}

	Spinner {
		anchors.centerIn: parent
		width: 28
		height: 28
		color: root.accent
		visible: root.state === "loading"
	}

	EmptyState {
		anchors.centerIn: parent
		visible: root.state === "none" || root.state === "error" || (root.state === "" && !Music.current)
		icon: "text_box_outline"
		title: root.state === "error" ? "The lyrics could not be fetched" : (Music.current ? "No lyrics for this song" : "Nothing plays")
		subtitle: root.state === "error" ? "LRCLIB did not answer – try the song again later" : (Music.current ? "An .lrc file beside the song is found too" : "")
	}
}
