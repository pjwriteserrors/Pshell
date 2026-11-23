pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.style.widgets
import qs.core.services

// The song to rap along to: the line whose time has come large in the
// middle, filling with the accent until the next one, the next ones below.
FocusScope {
	id: stage

	signal closed

	readonly property var rows: {
		void Rhymes.analysis;
		const out = [];
		for (let i = 0; i < Rhymes.lines.count; i += 1) {
			const line = Rhymes.lines.get(i);
			if (line.text.trim() === "") continue;
			out.push({ row: i, text: line.text, t: line.t, header: /^\s*\[[^\]]+\]\s*$/.test(line.text) });
		}
		return out;
	}
	readonly property int current: {
		// a hook sung again shows the hook's line
		const row = Rhymes.playingMark ? Rhymes.playingMark.shows : Rhymes.row;
		let found = 0;
		for (let i = 0; i < stage.rows.length; i += 1)
			if (stage.rows[i].row <= row) found = i;
		return found;
	}

	Keys.onPressed: event => {
		if (event.key === Qt.Key_Escape) {
			stage.closed();
			event.accepted = true;
		} else if (event.key === Qt.Key_Space) {
			Rhymes.playPause();
			event.accepted = true;
		} else if (event.key === Qt.Key_Up || event.key === Qt.Key_Down) {
			const next = stage.rows[Math.max(0, Math.min(stage.rows.length - 1, stage.current + (event.key === Qt.Key_Up ? -1 : 1)))];
			if (next) {
				Rhymes.row = next.row;
				if (next.t >= 0) Rhymes.play(Math.max(0, next.t - 0.15));
			}
			event.accepted = true;
		}
	}

	Rectangle {
		anchors.fill: parent
		color: Theme.base
	}

	// the accent rises softly from below
	Rectangle {
		anchors.fill: parent
		gradient: Gradient {
			GradientStop {
				position: 0.55
				color: "transparent"
			}

			GradientStop {
				position: 1
				color: Qt.alpha(Theme.primary, 0.14)
			}
		}
	}

	ListView {
		id: list

		anchors.fill: parent
		anchors.leftMargin: 60
		anchors.rightMargin: 60
		model: stage.rows
		currentIndex: stage.current
		interactive: false
		highlightRangeMode: ListView.StrictlyEnforceRange
		preferredHighlightBegin: list.height * 0.42
		preferredHighlightEnd: list.height * 0.42 + 80
		highlightMoveDuration: 520
		spacing: 14

		delegate: Item {
			id: line

			required property var modelData
			required property int index
			readonly property bool now: line.index === stage.current
			// this time of the line (a hook sung again has its own) and when the next line comes
			readonly property real from: line.now && Rhymes.playingMark ? Rhymes.playingMark.t : line.modelData.t
			readonly property real next: line.now && Rhymes.playingMark ? Rhymes.nextMark : Rhymes.beatDuration
			// how far into the line the music is
			readonly property real filled: line.now && line.from >= 0 && line.next > line.from ? Math.max(0, Math.min(1, (Rhymes.position - line.from) / (line.next - line.from))) : (line.index < stage.current ? 1 : 0)

			width: list.width
			height: line.modelData.header ? 40 : 66
			opacity: line.now ? 1 : Math.max(0.12, 0.5 - Math.abs(line.index - stage.current) * 0.1)
			scale: line.now ? 1 : 0.82

			Behavior on opacity {
				Anim {
					duration: Motion.long
				}
			}

			Behavior on scale {
				SpatialAnim {}
			}

			Text {
				id: words

				anchors.centerIn: parent
				width: parent.width
				horizontalAlignment: Text.AlignHCenter
				text: line.modelData.header ? line.modelData.text.replace(/[\[\]]/g, "").toUpperCase() : line.modelData.text
				color: line.modelData.header ? Theme.primary : Theme.textMuted
				font.family: Theme.fontFamily
				font.pixelSize: line.modelData.header ? Theme.size.title : 42
				font.weight: line.modelData.header ? Font.Bold : Font.DemiBold
				font.letterSpacing: line.modelData.header ? 3 : 0
				fontSizeMode: Text.HorizontalFit
				minimumPixelSize: 18
				elide: Text.ElideNone
			}

			// the sung part, in the accent
			Item {
				x: words.x + (words.width - words.contentWidth) / 2
				y: words.y
				width: words.contentWidth * line.filled
				height: words.height
				clip: true
				visible: !line.modelData.header

				Text {
					x: -(words.width - words.contentWidth) / 2
					width: words.width
					height: words.height
					horizontalAlignment: Text.AlignHCenter
					text: words.text
					color: Theme.text
					font: words.font
					fontSizeMode: Text.HorizontalFit
					minimumPixelSize: 18
				}
			}
		}
	}

	IconButton {
		anchors.right: parent.right
		anchors.top: parent.top
		anchors.margins: 14
		width: 36
		height: 36
		icon: "close"
		onClicked: stage.closed()
	}
}
