import QtQuick
import qs.style.theme
import qs.style.widgets
import qs.core.services

// The IR camera's picture, live: a lit frame, a dark one, or lit minus dark
// (only what the emitter lights); a found face outlined.
Item {
	id: root

	readonly property var frame: HpCamera.irFrame
	readonly property bool live: !!root.frame && HpCamera.irState.streaming === true

	implicitHeight: width * 9 / 16

	Rectangle {
		anchors.fill: parent
		radius: 12
		color: Theme.layer2
	}

	Item {
		anchors.fill: parent
		visible: root.live
		clip: true

		Image {
			anchors.fill: parent
			source: root.frame ? `file://${root.frame.path}?${root.frame.n}` : ""
			cache: false
			asynchronous: false
			fillMode: Image.PreserveAspectFit
			retainWhileLoading: true
		}

		Rectangle {
			readonly property var f: root.frame?.face ?? null
			visible: !!f
			x: f ? f[0] * parent.width : 0
			y: f ? f[1] * parent.height : 0
			width: f ? f[2] * parent.width : 0
			height: f ? f[3] * parent.height : 0
			color: "transparent"
			border.width: 1.5
			border.color: Theme.warning
			radius: width / 3
		}

		StyledText {
			anchors.right: parent.right
			anchors.bottom: parent.bottom
			anchors.margins: 10
			text: root.frame ? `${Math.round(root.frame.lit)} / ${Math.round(root.frame.dark)}` : ""
			tone: Theme.textMuted
			tabular: true
		}
	}

	Column {
		anchors.centerIn: parent
		spacing: 8
		visible: !root.live

		Glyph {
			anchors.horizontalCenter: parent.horizontalCenter
			icon: "video_off"
			size: 34
			color: Theme.textMuted
		}

		StyledText {
			anchors.horizontalCenter: parent.horizontalCenter
			text: !HpCamera.online ? "Not connected"
				: (HpCamera.irState.busyBy ?? []).length ? `In use by ${HpCamera.irState.busyBy.join(", ")}`
				: "Starting …"
			tone: Theme.textMuted
		}
	}
}
