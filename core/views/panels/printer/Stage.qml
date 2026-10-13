pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.core.services
import qs.style.widgets

// A job's part as far as it is printed: the frame of the layer, the whole
// part faint behind it, the layer itself from above in the corner. While the
// printer works the layer follows it; otherwise the part builds itself up
// once and a drag across it scrubs through the layers.
Item {
	id: root

	property var job: null
	// the printer's layer while it prints, -1 otherwise
	property int liveLayer: -1
	readonly property bool live: root.liveLayer >= 0
	readonly property int layers: root.job?.meta?.layers ?? 0
	readonly property bool ready: (root.job?.frames ?? 0) > 0
	readonly property var render: root.job ? (Printer.renders[root.job.id] ?? null) : null

	property real scrub: 1
	readonly property int shownLayer: root.live ? root.liveLayer : Math.max(1, Math.round(root.scrub * root.layers))
	readonly property int frame: Printer.frameIndex(root.job, root.shownLayer)

	function build() {
		if (root.live || !root.ready) return;
		root.scrub = 0;
		grow.restart();
	}

	onJobChanged: root.build()
	onReadyChanged: root.build()

	NumberAnimation {
		id: grow

		target: root
		property: "scrub"
		from: 0
		to: 1
		duration: 2600
		easing.type: Easing.BezierSpline
		easing.bezierCurve: Motion.decel
	}

	Rectangle {
		anchors.fill: parent
		radius: Theme.radius.huge
		color: Theme.layer1
		border.width: 1
		border.color: Theme.outline
	}

	Image {
		id: ghost

		// room on the right for the layer from above
		anchors.fill: parent
		anchors.leftMargin: 30
		anchors.rightMargin: 120
		anchors.topMargin: 12
		anchors.bottomMargin: 12
		fillMode: Image.PreserveAspectFit
		source: root.ready ? `file://${root.job.preview}/model.png` : ""
		opacity: 0.16
		smooth: true
		mipmap: true
	}

	Image {
		anchors.fill: ghost
		fillMode: Image.PreserveAspectFit
		source: root.ready ? Printer.frameUrl(root.job, "frame", root.frame) : ""
		smooth: true
		mipmap: true
	}

	// the slicer's own picture until the layers are drawn
	Image {
		anchors.centerIn: parent
		width: parent.width * 0.6
		height: parent.height * 0.6
		fillMode: Image.PreserveAspectFit
		source: root.render !== null && !root.ready ? `file://${root.job.preview}/thumb.png` : ""
		visible: status === Image.Ready
		opacity: 0.55
	}

	Column {
		anchors.horizontalCenter: parent.horizontalCenter
		anchors.bottom: parent.bottom
		anchors.bottomMargin: 26
		spacing: 10
		visible: root.job !== null && !root.ready

		Spinner {
			anchors.horizontalCenter: parent.horizontalCenter
			width: 34
			height: 34
		}

		StyledText {
			anchors.horizontalCenter: parent.horizontalCenter
			text: root.render ? `Drawing the layers · ${Math.round(100 * root.render.done / Math.max(1, root.render.total))} %` : "Reading the file"
			tone: Theme.textMuted
			font.pixelSize: Theme.size.label
		}
	}

	EmptyState {
		anchors.centerIn: parent
		visible: root.job === null
		icon: "printer_3d"
		title: Printer.printing ? "A print from elsewhere" : "Nothing to print"
		subtitle: Printer.printing ? "Its layers are not known here" : `Export from OrcaSlicer into ${Printer.inbox}`
	}

	// scrubbing through the layers of a job that is not printing
	MouseArea {
		anchors.fill: parent
		enabled: root.ready && !root.live
		cursorShape: enabled ? Qt.SizeHorCursor : Qt.ArrowCursor
		onPressed: mouse => {
			grow.stop();
			root.scrub = Math.max(0, Math.min(1, mouse.x / width));
		}
		onPositionChanged: mouse => {
			if (pressed) root.scrub = Math.max(0, Math.min(1, mouse.x / width));
		}
		onDoubleClicked: root.build()
	}

	// the layer from above
	Rectangle {
		anchors.right: parent.right
		anchors.bottom: parent.bottom
		anchors.margins: 12
		width: 112
		height: 112 + 22
		radius: Theme.radius.large
		color: Qt.alpha(Theme.bg, 0.72)
		border.width: 1
		border.color: Theme.outline
		visible: root.ready

		Image {
			anchors.top: parent.top
			anchors.horizontalCenter: parent.horizontalCenter
			anchors.topMargin: 6
			width: 100
			height: 100
			fillMode: Image.PreserveAspectFit
			source: root.ready ? Printer.frameUrl(root.job, "top", root.frame) : ""
			smooth: true
			mipmap: true
		}

		StyledText {
			anchors.bottom: parent.bottom
			anchors.bottomMargin: 6
			anchors.horizontalCenter: parent.horizontalCenter
			text: `Layer ${root.shownLayer} / ${root.layers}`
			tone: Theme.textMuted
			font.pixelSize: Theme.size.tiny
			tabular: true
		}
	}

	// how high the cut is: a thin gauge on the left
	Item {
		anchors.left: parent.left
		anchors.top: parent.top
		anchors.bottom: parent.bottom
		anchors.margins: 18
		width: 4
		visible: root.ready

		Rectangle {
			anchors.fill: parent
			radius: 2
			color: Qt.alpha(Theme.fg, 0.08)
		}

		Rectangle {
			anchors.bottom: parent.bottom
			width: parent.width
			height: parent.height * root.shownLayer / Math.max(1, root.layers)
			radius: 2
			color: Printer.hot
		}
	}
}
