pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.style.widgets
import qs.core.services

// What the file is: where it lies, how large, how long; the picture's
// codec, size, rate and range; its sound tracks and subtitles; its chapters
// (a click goes there).
PaneFrame {
	id: root

	readonly property var m: Video.meta ?? ({})

	title: "About the file"
	subtitle: Video.nameOf(Video.path) + String(Video.path).slice(String(Video.path).lastIndexOf("."))

	function size(bytes) {
		const b = Number(bytes) || 0;
		if (b >= 1e9) return `${(b / 1e9).toFixed(2)} GB`;
		if (b >= 1e6) return `${(b / 1e6).toFixed(1)} MB`;
		return `${Math.round(b / 1e3)} kB`;
	}

	function rate(bits) {
		const b = Number(bits) || 0;
		return b >= 1e6 ? `${(b / 1e6).toFixed(1)} Mbit/s` : `${Math.round(b / 1e3)} kbit/s`;
	}

	SectionLabel {
		text: "File"
	}

	Fact {
		label: "Folder"
		value: String(Video.path).slice(0, String(Video.path).lastIndexOf("/")).replace(Paths.home, "~")
	}
	Fact {
		label: "Size"
		value: root.size(root.m.size)
	}
	Fact {
		label: "Length"
		value: Video.formatTime(root.m.duration ?? Video.duration)
	}
	Fact {
		label: "Container"
		value: String(root.m.container ?? "").toUpperCase()
	}
	Fact {
		label: "Bit rate"
		value: root.m.bitrate ? root.rate(root.m.bitrate) : ""
	}

	SectionLabel {
		text: "Picture"
	}

	Fact {
		label: "Size"
		value: root.m.width ? `${root.m.width} × ${root.m.height}${root.m.rotation ? ` (turned ${root.m.rotation}°)` : ""}` : ""
	}
	Fact {
		label: "Codec"
		value: String(root.m.vcodec ?? "").toUpperCase()
	}
	Fact {
		label: "Frames"
		value: root.m.fps ? `${Math.round(root.m.fps * 100) / 100} per second` : ""
	}
	Fact {
		label: "Range"
		value: root.m.hdr ? "HDR – shown in standard range" : (root.m.pixfmt ? `Standard (${root.m.pixfmt})` : "")
	}

	SectionLabel {
		text: "Sound"
		visible: (root.m.audio ?? []).length > 0
	}

	Repeater {
		model: root.m.audio ?? []

		Fact {
			required property var modelData
			required property int index

			label: modelData.lang ? String(modelData.lang).toUpperCase() : `Track ${index + 1}`
			value: [String(modelData.codec ?? "").toUpperCase(), modelData.channels ? `${modelData.channels === 2 ? "stereo" : modelData.channels === 1 ? "mono" : modelData.channels + " channels"}` : "", modelData.title ?? ""].filter(x => x).join(" · ")
		}
	}

	SectionLabel {
		text: "Subtitles"
		visible: Video.subTracks.length > 0
	}

	Repeater {
		model: Video.subTracks

		Fact {
			required property var modelData

			label: modelData.lang ? String(modelData.lang).toUpperCase() : "—"
			value: [modelData.label, ({ embedded: "in the file", beside: "beside it", made: "by Whisper", downloaded: "online" })[modelData.source] ?? ""].filter(x => x).join(" · ")
		}
	}

	SectionLabel {
		text: `Chapters (${Video.chapters.length})`
		visible: Video.chapters.length > 0
	}

	Repeater {
		model: Video.chapters

		Clickable {
			id: chapter

			required property var modelData
			required property int index

			width: root.bodyWidth
			height: 34
			radius: Theme.radius.small
			color: Video.chapterNow === chapter.index ? Qt.alpha(root.accent, 0.16) : (chapter.hovered ? Theme.layer2 : "transparent")
			onClicked: Video.seek(chapter.modelData.t)

			StyledText {
				x: 10
				anchors.verticalCenter: parent.verticalCenter
				width: parent.width - 80
				text: chapter.modelData.title || `Chapter ${chapter.index + 1}`
			}

			StyledText {
				anchors.right: parent.right
				anchors.rightMargin: 10
				anchors.verticalCenter: parent.verticalCenter
				text: Video.formatTime(chapter.modelData.t)
				tabular: true
				tone: Theme.textMuted
				font.pixelSize: Theme.size.small
			}
		}
	}

	component Fact: Item {
		id: fact

		property string label: ""
		property string value: ""

		width: root.bodyWidth
		height: fact.value !== "" ? Math.max(22, valueText.implicitHeight) : 0
		visible: fact.value !== ""

		StyledText {
			width: 96
			text: fact.label
			tone: Theme.textMuted
			font.pixelSize: Theme.size.small
		}

		StyledText {
			id: valueText

			x: 104
			width: parent.width - 104
			text: fact.value
			wrapMode: Text.WrapAnywhere
			font.pixelSize: Theme.size.label
		}
	}
}
