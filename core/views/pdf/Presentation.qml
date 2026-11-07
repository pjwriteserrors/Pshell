pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.style.widgets
import qs.core.services

// The pages as slides: the window fullscreen, one page as large as it goes
// on black, the next one sliding, fading or growing in. A click, Space, the
// arrows or the wheel go on and back; B and W make the screen black or
// white for a moment; L is the laser pointer; at the bottom, on hover, the
// pages in a strip to jump to; top left the time since it began. The phone
// can be the remote (a page opened from a code, helper `bridge`).
FocusScope {
	id: root

	property var reader: null
	signal leave()

	readonly property real fitK: {
		const p = Pdf.pages[root.shown];
		const s = Pdf.sizeOf(p);
		return Math.min(root.width / Math.max(1, s.width), root.height / Math.max(1, s.height));
	}
	// "slide" | "fade" | "zoom"
	readonly property string style: Pdf.setting("presentTransition", "slide")

	property int shown: Pdf.page
	property int before: -1
	property int direction: 1
	property real t: 1
	// "" | "black" | "white"
	property string blank: ""
	property real started: Date.now()
	property real now: Date.now()

	focus: true
	Component.onCompleted: root.forceActiveFocus()
	Component.onDestruction: root.stopRemote()

	Connections {
		target: Pdf

		function onPageChanged() {
			if (Pdf.page === root.shown) return;
			root.before = root.shown;
			root.direction = Pdf.page > root.shown ? 1 : -1;
			root.shown = Pdf.page;
			turn.restart();
		}

		function onBridged(m) {
			if (m.token !== root.token || m.kind !== "remote") return;
			if (m.closed) {
				root.token = "";
				return;
			}
			switch (m.command) {
			case "next": return root.go(1);
			case "previous": return root.go(-1);
			case "end": return root.leave();
			case "laser": return root.laser();
			case "move":
				root.laserX = Math.max(0, Math.min(root.width, root.laserX + (m.dx || 0) * 2));
				root.laserY = Math.max(0, Math.min(root.height, root.laserY + (m.dy || 0) * 2));
				if (typeof Laser !== "undefined" && Laser.active) Laser.at(root.Window.window?.screen?.name ?? "", root.laserX, root.laserY);
			}
		}
	}

	NumberAnimation {
		id: turn

		target: root
		property: "t"
		from: 0
		to: 1
		duration: root.style === "fade" ? Motion.long : Motion.long + 120
		easing.type: Easing.BezierSpline
		easing.bezierCurve: Motion.emphasized
	}

	function go(delta) {
		root.blank = "";
		const next = Math.max(0, Math.min(Pdf.pageCount - 1, Pdf.page + delta));
		if (next !== Pdf.page) Pdf.page = next;
	}

	Rectangle {
		anchors.fill: parent
		color: "black"
	}

	// ── the slides: the one before leaving, the one now coming ────────────
	Slide {
		index: turn.running ? root.before : -1
		visible: turn.running && root.before >= 0
		x: root.style === "slide" ? (root.width - width) / 2 - root.direction * root.width * root.t : (root.width - width) / 2
		opacity: root.style === "slide" ? 1 : 1 - root.t
		scale: root.style === "zoom" ? 1 + 0.08 * root.t : 1
	}

	Slide {
		index: root.shown
		x: root.style === "slide" ? (root.width - width) / 2 + root.direction * root.width * (1 - root.t) : (root.width - width) / 2
		opacity: root.style === "slide" ? 1 : root.t
		scale: root.style === "zoom" ? 0.9 + 0.1 * root.t : 1
	}

	// black or white for a moment
	Rectangle {
		anchors.fill: parent
		color: root.blank === "white" ? "white" : "black"
		opacity: root.blank !== "" ? 1 : 0
		visible: opacity > 0.01

		Behavior on opacity {
			Anim {
				duration: Motion.long
			}
		}
	}

	MouseArea {
		id: pointer

		anchors.fill: parent
		hoverEnabled: true
		acceptedButtons: Qt.LeftButton | Qt.RightButton
		cursorShape: root.awake ? Qt.ArrowCursor : Qt.BlankCursor
		onClicked: mouse => root.go(mouse.button === Qt.RightButton ? -1 : 1)
		onWheel: wheel => {
			if (wheelGuard.running) return;
			wheelGuard.start();
			root.go(wheel.angleDelta.y < 0 ? 1 : -1);
		}
		onPositionChanged: mouse => {
			root.wake();
			root.laserX = mouse.x;
			root.laserY = mouse.y;
		}
	}

	Timer {
		id: wheelGuard

		interval: 320
	}

	// ── the pointer shows the ways, then they go ───────────────────────────
	property bool awake: true
	property real laserX: root.width / 2
	property real laserY: root.height / 2

	function wake() {
		root.awake = true;
		sleep.restart();
	}

	Timer {
		id: sleep

		interval: 2200
		running: true
		onTriggered: root.awake = false
	}

	Timer {
		interval: 1000
		running: true
		repeat: true
		onTriggered: root.now = Date.now()
	}

	// top left: the time, the page, the ways
	Rectangle {
		x: 18
		y: 18
		width: info.implicitWidth + 20
		height: 42
		radius: 21
		color: Qt.rgba(0.08, 0.08, 0.09, 0.85)
		opacity: root.awake ? 1 : 0
		visible: opacity > 0.01

		Behavior on opacity {
			Anim {
				duration: Motion.long
			}
		}

		Row {
			id: info

			anchors.centerIn: parent
			spacing: 8

			StyledText {
				anchors.verticalCenter: parent.verticalCenter
				text: {
					const s = Math.floor((root.now - root.started) / 1000);
					const m = Math.floor(s / 60);
					return `${m}:${String(s % 60).padStart(2, "0")}  ·  ${Pdf.page + 1} / ${Pdf.pageCount}`;
				}
				tone: "white"
				surface: "transparent"
				tabular: true
				font.weight: Font.DemiBold
			}

			SlideKey {
				icon: root.style === "slide" ? "transition" : (root.style === "fade" ? "blur" : "magnify_plus_outline")
				onClicked: Pdf.setSetting("presentTransition", root.style === "slide" ? "fade" : (root.style === "fade" ? "zoom" : "slide"))
			}
			SlideKey {
				visible: typeof Laser !== "undefined" && Plugins.on("laser-pointer")
				icon: "target"
				onClicked: root.laser()
			}
			SlideKey {
				icon: "cellphone_wireless"
				checked: root.token !== ""
				onClicked: root.token !== "" ? root.stopRemote() : root.startRemote()
			}
			SlideKey {
				icon: "close"
				onClicked: root.leave()
			}
		}
	}

	// the phone as the remote: its code to scan
	Rectangle {
		anchors.right: parent.right
		anchors.top: parent.top
		anchors.margins: 18
		width: 220
		height: 260
		radius: Theme.radius.large
		color: "white"
		visible: root.qr !== "" && root.token !== "" && root.showCode
		opacity: visible ? 1 : 0

		Behavior on opacity {
			Anim {}
		}

		Column {
			anchors.centerIn: parent
			spacing: 8

			Image {
				anchors.horizontalCenter: parent.horizontalCenter
				width: 180
				height: 180
				source: root.qr ? Pdf.fileUrl(root.qr) : ""
				smooth: false
				fillMode: Image.PreserveAspectFit
			}
			Text {
				anchors.horizontalCenter: parent.horizontalCenter
				width: 190
				horizontalAlignment: Text.AlignHCenter
				wrapMode: Text.WordWrap
				text: "Scan with the phone – it becomes the remote"
				color: "#222"
				font.pixelSize: 12
			}
		}

		TapHandler {
			onTapped: root.showCode = false
		}
	}

	property string token: ""
	property string qr: ""
	property bool showCode: true

	function startRemote() {
		Pdf.request("bridge", { kind: "remote", title: Pdf.title }, data => {
			if (!data?.token) return Pdf.say("The phone could not be reached", "alert_circle_outline");
			root.token = data.token;
			root.qr = data.qr || "";
			root.showCode = true;
		});
	}

	function stopRemote() {
		if (root.token) Pdf.request("bridgestop", { token: root.token });
		root.token = "";
	}

	function laser() {
		if (typeof Laser === "undefined" || !Plugins.on("laser-pointer")) return;
		Laser.toggle();
	}

	// the pages in a strip along the bottom, on hover
	Item {
		id: stripArea

		anchors.left: parent.left
		anchors.right: parent.right
		anchors.bottom: parent.bottom
		height: 150

		HoverHandler {
			id: stripHover
		}

		Rectangle {
			anchors.fill: parent
			opacity: strip.opacity
			gradient: Gradient {
				GradientStop {
					position: 0
					color: "transparent"
				}
				GradientStop {
					position: 1
					color: Qt.rgba(0, 0, 0, 0.8)
				}
			}
		}

		ListView {
			id: strip

			anchors.fill: parent
			anchors.margins: 16
			anchors.topMargin: 30
			orientation: ListView.Horizontal
			spacing: 10
			clip: true
			model: stripHover.hovered ? Pdf.pageCount : 0
			currentIndex: Pdf.page
			opacity: stripHover.hovered ? 1 : 0
			visible: opacity > 0.01
			highlightMoveDuration: Motion.medium
			preferredHighlightBegin: width / 2 - 50
			preferredHighlightEnd: width / 2 + 50
			highlightRangeMode: ListView.ApplyRange

			Behavior on opacity {
				Anim {}
			}

			delegate: Item {
				id: cell

				required property int index
				readonly property var page: Pdf.pages[cell.index]
				readonly property var size: Pdf.sizeOf(cell.page)
				readonly property real tk: (strip.height - 6) / Math.max(1, cell.size.height)

				width: thumb.width
				height: strip.height

				PdfPage {
					id: thumb

					anchors.verticalCenter: parent.verticalCenter
					pageId: cell.page?.id ?? ""
					reader: root.reader
					k: cell.tk
					renderK: cell.tk
					interactive: false
					thumbnail: true
					night: false
				}

				Rectangle {
					anchors.fill: thumb
					anchors.margins: -3
					radius: 4
					color: "transparent"
					border.color: Theme.primary
					border.width: 2
					visible: cell.index === Pdf.page
				}

				TapHandler {
					onTapped: Pdf.page = cell.index
				}
			}
		}
	}

	Keys.onPressed: event => {
		root.wake();
		let handled = true;
		switch (event.key) {
		case Qt.Key_Right:
		case Qt.Key_Down:
		case Qt.Key_Space:
		case Qt.Key_PageDown:
		case Qt.Key_Return:
		case Qt.Key_Enter:
		case Qt.Key_N:
			root.go(1);
			break;
		case Qt.Key_Left:
		case Qt.Key_Up:
		case Qt.Key_PageUp:
		case Qt.Key_Backspace:
		case Qt.Key_P:
			root.go(-1);
			break;
		case Qt.Key_Home:
			Pdf.page = 0;
			break;
		case Qt.Key_End:
			Pdf.page = Pdf.pageCount - 1;
			break;
		case Qt.Key_B:
		case Qt.Key_Period:
			root.blank = root.blank === "black" ? "" : "black";
			break;
		case Qt.Key_W:
		case Qt.Key_Comma:
			root.blank = root.blank === "white" ? "" : "white";
			break;
		case Qt.Key_L:
			root.laser();
			break;
		case Qt.Key_T:
			root.started = Date.now();
			break;
		case Qt.Key_Escape:
		case Qt.Key_F5:
			root.leave();
			break;
		default:
			handled = false;
		}
		event.accepted = handled;
	}

	component Slide: PdfPage {
		property int index: -1

		pageId: index >= 0 ? (Pdf.pages[index]?.id ?? "") : ""
		reader: root.reader
		k: root.fitK
		renderK: root.fitK
		interactive: false
		shadow: false
		night: false
		y: (root.height - height) / 2
	}

	component SlideKey: IconButton {
		width: 30
		height: 30
		iconSize: 17
		iconColor: "white"
		anchors.verticalCenter: parent?.verticalCenter
	}
}
