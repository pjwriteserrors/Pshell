pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// The story so far: what happened, episode by episode, as far as it was seen. A
// point that was found in the subtitles jumps to its moment.
ColumnLayout {
	id: root

	property string seriesId: ""
	property bool shown: false
	property var episodes: []
	property int missing: 0
	readonly property var job: Streams.storyJob?.series === root.seriesId ? Streams.storyJob : null

	spacing: 10

	function load() {
		Streams.call("timeline", { series: root.seriesId }, data => {
			root.episodes = (data?.episodes ?? []).slice().reverse();
			root.missing = data?.missing ?? 0;
		});
	}

	onShownChanged: if (root.shown) root.load()
	onJobChanged: if (root.shown) root.load()

	RowLayout {
		Layout.fillWidth: true

		StyledText {
			Layout.fillWidth: true
			wrapMode: Text.Wrap
			tone: Theme.textMuted
			font.pixelSize: Theme.size.small
			text: {
				if (root.job) return `Writing recaps: ${root.job.done} of ${root.job.total}. The newest come first.`;
				if (root.missing > 0) return `${root.missing} seen ${root.missing === 1 ? "episode has" : "episodes have"} no recap yet. Written by the AI from the subtitles; it can be wrong.`;
				return "Written by the AI from the subtitles; it can be wrong.";
			}
		}
		TextButton {
			visible: root.missing > 0 && !root.job
			text: "Write the next recaps"
			onActivated: Streams.call("timelineFill", { series: root.seriesId }, Streams.report())
		}
	}
	ListView {
		id: list

		Layout.fillWidth: true
		Layout.fillHeight: true
		clip: true
		spacing: 14
		boundsBehavior: Flickable.StopAtBounds
		model: root.episodes
		ScrollBar.vertical: ThinScrollBar {}

		delegate: ColumnLayout {
			id: episode

			required property var modelData

			width: list.width - 12
			spacing: 3

			StyledText {
				Layout.fillWidth: true
				text: `${episode.modelData.n}. ${episode.modelData.title}`
				font.weight: Font.Bold
				elide: Text.ElideRight
			}
			StyledText {
				visible: episode.modelData.points.length === 0 && episode.modelData.notes.length === 0
				text: "No recap yet"
				tone: Theme.textSubtle
				font.pixelSize: Theme.size.small
			}
			Repeater {
				model: episode.modelData.points

				Clickable {
					id: point

					required property var modelData

					Layout.fillWidth: true
					implicitHeight: pointWord.implicitHeight + 8
					radius: Theme.radius.small
					enabled: point.modelData.at >= 0
					onClicked: Streams.call("play", { video: episode.modelData.video, player: "app", at: point.modelData.at })

					StyledText {
						id: pointWord

						anchors.left: parent.left
						anchors.right: parent.right
						anchors.verticalCenter: parent.verticalCenter
						anchors.leftMargin: 6
						wrapMode: Text.Wrap
						text: point.modelData.at >= 0 ? `${Streams.clock(point.modelData.at)}  ${point.modelData.text}` : point.modelData.text
					}
				}
			}
			Repeater {
				model: episode.modelData.notes

				StyledText {
					required property var modelData

					Layout.fillWidth: true
					Layout.leftMargin: 6
					wrapMode: Text.Wrap
					tone: Theme.primary
					text: `${Streams.clock(modelData.at)}  ${modelData.text}`
				}
			}
		}
	}
}
