pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// The moments kept of a series, X in the player. Two numbers each until a file is asked for.
ColumnLayout {
	id: root

	property string seriesId: ""
	property bool shown: false
	property var clips: []

	spacing: 10

	function load() {
		Streams.call("clips", { series: root.seriesId }, data => root.clips = data ?? []);
	}

	onShownChanged: if (root.shown) root.load()

	StyledText {
		Layout.fillWidth: true
		visible: root.clips.length === 0
		horizontalAlignment: Text.AlignHCenter
		tone: Theme.textMuted
		font.pixelSize: Theme.size.title
		text: "Press X while watching to keep the last 30 seconds."
	}
	ListView {
		id: list

		Layout.fillWidth: true
		Layout.fillHeight: true
		clip: true
		spacing: 8
		boundsBehavior: Flickable.StopAtBounds
		model: root.clips
		ScrollBar.vertical: ThinScrollBar {}

		delegate: RowLayout {
			id: row

			required property var modelData
			property bool cutting: false

			width: list.width - 12
			spacing: 12

			Thumb {
				Layout.preferredWidth: 128
				Layout.preferredHeight: 72
				source: row.modelData.thumb
			}
			ColumnLayout {
				Layout.fillWidth: true
				spacing: 2

				StyledText {
					Layout.fillWidth: true
					text: row.modelData.title
					elide: Text.ElideRight
				}
				StyledText {
					text: `${Streams.clock(row.modelData.at)} – ${Streams.clock(row.modelData.end)}`
					tone: Theme.textMuted
					font.pixelSize: Theme.size.small
					tabular: true
				}
			}
			TextButton {
				text: "Watch"
				onActivated: Streams.call("play", { video: row.modelData.video, player: "app", at: row.modelData.at })
			}
			TextButton {
				text: row.cutting ? "Cutting…" : "Save file"
				enabled: !row.cutting
				onActivated: {
					row.cutting = true;
					Streams.call("clipExport", { id: row.modelData.id }, Streams.report(data => {
						row.cutting = false;
						if (data?.file) Notifs.pushInternal("done", "Clip saved", data.file, { icon: "check" });
					}));
				}
			}
			TextButton {
				text: "Remove"
				onActivated: Streams.call("clipRemove", { id: row.modelData.id }, () => root.load())
			}
		}
	}
}
