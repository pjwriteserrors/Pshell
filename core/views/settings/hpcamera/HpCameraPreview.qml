import QtQuick
import qs.style.theme
import qs.style.widgets
import qs.core.services

// The colour camera's whole picture, live, with the virtual camera's cut-out
// (dragged it pans, the wheel zooms) and the spot the exposure aims at; while
// `aiming`, a click puts that spot there instead.
Item {
	id: root

	property bool aiming: false
	readonly property var frame: HpCamera.frame
	readonly property var crop: root.frame?.crop ?? [0, 0, 1, 1]
	readonly property bool live: !!root.frame && HpCamera.streamState.streaming === true
	readonly property bool mirror: HpCamera.view.mirror
	// the exposure's spot in fractions, null while it is the whole picture
	readonly property var spot: {
		const r = HpCamera.shown("roi", "rect", null);
		const max = HpCamera.roi?.max;
		if (!r || !max || (r[0] <= 0 && r[1] <= 0 && r[2] >= max[2] && r[3] >= max[3])) return null;
		return [r[0] / max[2], r[1] / max[3], r[2] / max[2], r[3] / max[3]];
	}

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
			mirror: root.mirror
			retainWhileLoading: true
		}

		// outside the virtual camera's cut-out, dimmed
		Item {
			anchors.fill: parent
			visible: HpCamera.view.zoom > 1.01 || HpCamera.view.follow || root.crop[2] < 0.999 || root.crop[3] < 0.999

			readonly property real cx: (root.mirror ? 1 - root.crop[0] - root.crop[2] : root.crop[0]) * width
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

		// the followed face
		Rectangle {
			readonly property var f: root.frame?.face ?? null
			visible: !!f && HpCamera.view.follow
			x: f ? (root.mirror ? 1 - f[0] - f[2] : f[0]) * parent.width : 0
			y: f ? f[1] * parent.height : 0
			width: f ? f[2] * parent.width : 0
			height: f ? f[3] * parent.height : 0
			color: "transparent"
			border.width: 1.5
			border.color: Theme.warning
			radius: width / 3
			opacity: 0.8
		}

		// the exposure's spot
		Rectangle {
			readonly property var s: root.spot
			visible: !!s
			x: s ? (root.mirror ? 1 - s[0] - s[2] : s[0]) * parent.width : 0
			y: s ? s[1] * parent.height : 0
			width: s ? s[2] * parent.width : 0
			height: s ? s[3] * parent.height : 0
			color: "transparent"
			border.width: 1.5
			border.color: Theme.text
			radius: 6
			opacity: root.aiming ? 0.95 : 0.55

			Glyph {
				anchors.centerIn: parent
				icon: "camera_iris"
				size: 16
				color: Theme.text
			}
		}
	}

	Column {
		anchors.centerIn: parent
		spacing: 8
		visible: !root.live

		Glyph {
			anchors.horizontalCenter: parent.horizontalCenter
			icon: HpCamera.busyElsewhere ? "video" : "video_off"
			size: 34
			color: Theme.textMuted
		}

		StyledText {
			anchors.horizontalCenter: parent.horizontalCenter
			text: !HpCamera.online ? "Not connected"
				: HpCamera.busyElsewhere ? `In use by ${(HpCamera.streamState.busyBy ?? []).join(", ")}`
				: (HpCamera.previewOn ? "Starting …" : "")
			tone: Theme.textMuted
		}
	}

	MouseArea {
		anchors.fill: parent
		enabled: root.live
		cursorShape: root.aiming ? Qt.CrossCursor : (pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor)

		property real startX: 0
		property real startY: 0
		property real fromX: 0.5
		property real fromY: 0.5

		onPressed: mouse => {
			if (root.aiming) {
				// a quarter of the picture around the click
				const fx = (root.mirror ? width - mouse.x : mouse.x) / width;
				const fy = mouse.y / height;
				HpCamera.setSpot(Math.max(0, Math.min(0.75, fx - 0.125)), Math.max(0, Math.min(0.75, fy - 0.125)), 0.25, 0.25);
				return;
			}
			startX = mouse.x;
			startY = mouse.y;
			fromX = HpCamera.view.cx;
			fromY = HpCamera.view.cy;
			if (HpCamera.view.follow) HpCamera.setView({ follow: false });
		}
		onPositionChanged: mouse => {
			if (!pressed || root.aiming) return;
			const dx = (mouse.x - startX) / width * (root.mirror ? -1 : 1);
			const dy = (mouse.y - startY) / height;
			HpCamera.setView({ cx: Math.max(0, Math.min(1, fromX + dx)), cy: Math.max(0, Math.min(1, fromY + dy)) });
		}
		onDoubleClicked: {
			if (root.aiming) HpCamera.setSpot(null);
			else HpCamera.setView({ zoom: 1, cx: 0.5, cy: 0.5 });
		}
		onWheel: wheel => {
			const z = Math.max(1, Math.min(4, HpCamera.view.zoom * (wheel.angleDelta.y > 0 ? 1.1 : 1 / 1.1)));
			HpCamera.setView({ zoom: Math.round(z * 100) / 100 });
		}
	}
}
