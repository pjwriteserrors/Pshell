import QtQuick
import qs.style.theme
import qs.style.widgets

// What an icon of a tray has to say, over it: a count in the corner (or a
// dot), a short text under it (playtime, battery), and a ring around it
// for what is under way (a download, a print) that glows while it runs.
Item {
	id: root

	// AppTray.badgeOf(): { count, text, progress, dot, urgent }
	property var badge: ({ count: 0, text: "", progress: -1, dot: false, urgent: false })
	property color accent: Theme.primary
	property bool lively: true
	readonly property color tone: root.badge.urgent ? Theme.danger : root.accent

	// the ring of what is under way
	Canvas {
		id: ring

		property real progress: Math.max(0, Math.min(1, Number(root.badge.progress)))

		anchors.fill: parent
		anchors.margins: -4
		visible: Number(root.badge.progress) >= 0
		opacity: glow.value
		onProgressChanged: requestPaint()
		onVisibleChanged: requestPaint()
		onPaint: {
			const ctx = getContext("2d");
			ctx.reset();
			const r = Math.min(width, height) / 2 - 2;
			ctx.lineWidth = 3;
			ctx.lineCap = "round";
			ctx.strokeStyle = Qt.alpha(Theme.text, 0.18);
			ctx.beginPath();
			ctx.arc(width / 2, height / 2, r, 0, Math.PI * 2);
			ctx.stroke();
			ctx.strokeStyle = root.tone;
			ctx.beginPath();
			ctx.arc(width / 2, height / 2, r, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * ring.progress);
			ctx.stroke();
		}

		Behavior on progress {
			Anim {}
		}
	}

	// glows while something runs
	QtObject {
		id: glow

		property real value: 1
	}

	SequentialAnimation {
		running: ring.visible && root.lively
		loops: Animation.Infinite
		onStopped: glow.value = 1

		NumberAnimation {
			target: glow
			property: "value"
			to: 0.55
			duration: 900
			easing.type: Easing.InOutSine
		}
		NumberAnimation {
			target: glow
			property: "value"
			to: 1
			duration: 900
			easing.type: Easing.InOutSine
		}
	}

	// a higher count makes the bubble jump
	QtObject {
		id: bump

		property real value: 1
	}

	property int lastCount: 0
	onBadgeChanged: {
		const count = Number(root.badge.count) || 0;
		if (count > root.lastCount && root.lively) bumpAnim.restart();
		root.lastCount = count;
	}

	SequentialAnimation {
		id: bumpAnim

		NumberAnimation {
			target: bump
			property: "value"
			to: 1.45
			duration: 120
			easing.type: Easing.OutQuad
		}
		NumberAnimation {
			target: bump
			property: "value"
			to: 1
			duration: 420
			easing.type: Easing.BezierSpline
			easing.bezierCurve: Motion.spatial
		}
	}

	// a count, or just a dot
	Rectangle {
		readonly property bool counting: root.badge.count > 0

		visible: counting || root.badge.dot
		anchors.right: parent.right
		anchors.top: parent.top
		anchors.rightMargin: counting ? -width * 0.3 : 0
		anchors.topMargin: counting ? -height * 0.3 : 0
		width: counting ? Math.max(height, countText.implicitWidth + 8) : Math.max(7, parent.width * 0.16)
		height: counting ? Math.max(14, parent.height * 0.32) : width
		radius: height / 2
		color: root.tone
		border.width: 1.5
		border.color: Theme.base
		scale: bump.value

		Behavior on width {
			SpatialAnim {
				duration: Motion.medium
			}
		}
		Behavior on color {
			ColorAnim {}
		}

		StyledText {
			id: countText

			anchors.centerIn: parent
			visible: parent.counting
			text: root.badge.count > 99 ? "99+" : String(root.badge.count)
			tone: Theme.onPrimary
			surface: root.tone
			font.pixelSize: Math.max(8, parent.height * 0.62)
			font.weight: Font.Bold
			tabular: true
		}
	}

	// a short text under it
	Rectangle {
		visible: String(root.badge.text) !== ""
		anchors.horizontalCenter: parent.horizontalCenter
		anchors.bottom: parent.bottom
		anchors.bottomMargin: -height * 0.35
		width: label.implicitWidth + 8
		height: Math.max(12, parent.height * 0.26)
		radius: height / 2
		color: root.badge.urgent ? Theme.danger : Theme.layer3
		border.width: 1
		border.color: Theme.outline

		StyledText {
			id: label

			anchors.centerIn: parent
			text: String(root.badge.text)
			font.pixelSize: Math.max(7, parent.height * 0.64)
			font.weight: Font.DemiBold
			tabular: true
		}
	}
}
