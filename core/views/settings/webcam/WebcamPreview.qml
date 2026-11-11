import QtQuick
import qs.style.theme
import qs.style.widgets
import qs.core.services

// The camera's whole picture, live, with the virtual camera's cut-out on it:
// dragged it pans, the wheel zooms; a followed face is outlined.
Item {
	id: root

	property bool showCut: true
	readonly property var frame: Webcam.frame
	readonly property var crop: root.frame?.crop ?? [0, 0, 1, 1]
	readonly property bool live: !!root.frame && Webcam.streamState.streaming === true
	readonly property real aspect: 4 / 3

	implicitHeight: width / root.aspect

	Rectangle {
		anchors.fill: parent
		radius: 12
		color: Theme.layer2
	}

	Item {
		id: pic

		anchors.fill: parent
		visible: root.live
		clip: true

		Image {
			id: image

			anchors.fill: parent
			source: root.frame ? `file://${root.frame.path}?${root.frame.n}` : ""
			cache: false
			asynchronous: false
			fillMode: Image.PreserveAspectFit
			mirror: Webcam.view.mirror
			retainWhileLoading: true
		}

		// outside the cut-out, dimmed
		Item {
			anchors.fill: parent
			visible: root.showCut && (Webcam.view.zoom > 1.01 || Webcam.view.follow || root.crop[2] < 0.999 || root.crop[3] < 0.999)

			readonly property real cx: (Webcam.view.mirror ? 1 - root.crop[0] - root.crop[2] : root.crop[0]) * width
			readonly property real cy: root.crop[1] * height
			readonly property real cw: root.crop[2] * width
			readonly property real ch: root.crop[3] * height

			Rectangle { x: 0; y: 0; width: parent.width; height: parent.cy; color: "#80000000" }
			Rectangle { x: 0; y: parent.cy + parent.ch; width: parent.width; height: parent.height - parent.cy - parent.ch; color: "#80000000" }
			Rectangle { x: 0; y: parent.cy; width: parent.cx; height: parent.ch; color: "#80000000" }
			Rectangle { x: parent.cx + parent.cw; y: parent.cy; width: parent.width - parent.cx - parent.cw; height: parent.ch; color: "#80000000" }

			Rectangle {
				x: parent.cx
				y: parent.cy
				width: parent.cw
				height: parent.ch
				color: "transparent"
				border.width: 2
				border.color: Theme.primary
				radius: 4

				Behavior on x { Anim { duration: 120 } }
				Behavior on y { Anim { duration: 120 } }
				Behavior on width { Anim { duration: 120 } }
				Behavior on height { Anim { duration: 120 } }
			}
		}

		Rectangle {
			readonly property var f: root.frame?.face ?? null
			visible: !!f && Webcam.view.follow
			x: f ? (Webcam.view.mirror ? 1 - f[0] - f[2] : f[0]) * parent.width : 0
			y: f ? f[1] * parent.height : 0
			width: f ? f[2] * parent.width : 0
			height: f ? f[3] * parent.height : 0
			color: "transparent"
			border.width: 1.5
			border.color: Theme.warning
			radius: width / 3
			opacity: 0.8
		}
	}

	Column {
		anchors.centerIn: parent
		spacing: 8
		visible: !root.live

		Glyph {
			anchors.horizontalCenter: parent.horizontalCenter
			icon: Webcam.busyElsewhere ? "video" : "video_off"
			size: 34
			color: Theme.textMuted
		}

		StyledText {
			anchors.horizontalCenter: parent.horizontalCenter
			text: !Webcam.online ? "Not connected"
				: Webcam.busyElsewhere ? `In use by ${(Webcam.streamState.busyBy ?? []).join(", ")}`
				: (Webcam.previewOn ? "Starting …" : "")
			tone: Theme.textMuted
		}
	}

	MouseArea {
		anchors.fill: parent
		enabled: root.live && root.showCut
		cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor

		property real startX: 0
		property real startY: 0
		property real fromX: 0.5
		property real fromY: 0.5

		onPressed: mouse => {
			startX = mouse.x;
			startY = mouse.y;
			fromX = Webcam.view.cx;
			fromY = Webcam.view.cy;
			if (Webcam.view.follow) Webcam.setView({ follow: false });
		}
		onPositionChanged: mouse => {
			if (!pressed) return;
			const dx = (mouse.x - startX) / width * (Webcam.view.mirror ? -1 : 1);
			const dy = (mouse.y - startY) / height;
			Webcam.setView({ cx: Math.max(0, Math.min(1, fromX + dx)), cy: Math.max(0, Math.min(1, fromY + dy)) });
		}
		onDoubleClicked: Webcam.setView({ zoom: 1, cx: 0.5, cy: 0.5 })
		onWheel: wheel => {
			const z = Math.max(1, Math.min(4, Webcam.view.zoom * (wheel.angleDelta.y > 0 ? 1.1 : 1 / 1.1)));
			Webcam.setView({ zoom: Math.round(z * 100) / 100 });
		}
	}
}
