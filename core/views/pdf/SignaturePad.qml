pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.style.theme
import qs.style.widgets
import qs.core.services

// A signature made in the window: drawn with the mouse or a pen – quick
// strokes thin, slow ones full, like ink – or typed in a hand-like font.
// It is kept as a picture trimmed to the ink, with a clear background, among
// the saved ones (pdf.json "signatures"), and handed to `done`.
Rectangle {
	id: root

	property Item dock: null
	// "draw" | "type"
	property string mode: "draw"
	property string purpose: "Signature"
	property var done: null
	property color ink: "#0d1b5e"

	width: Math.min(640, (root.Window.width || 900) - 60)
	height: 430
	radius: Theme.radius.huge
	color: Theme.layer1
	border.color: Theme.outline

	// strokes: [[{ x, y, w }]]
	property var strokes: []
	property var current: []
	property real lastT: 0
	property real lastW: 3

	onStrokesChanged: pad.requestPaint()
	onInkChanged: pad.requestPaint()

	readonly property bool empty: root.mode === "draw" ? root.strokes.length === 0 : typed.text.trim() === ""

	MouseArea {
		anchors.fill: parent
		onClicked: {}
	}

	StyledText {
		id: heading

		x: 22
		y: 18
		text: root.mode === "draw" ? `Draw your ${root.purpose.toLowerCase()}` : `Type your ${root.purpose.toLowerCase()}`
		font.pixelSize: Theme.size.heading
		font.weight: Font.Bold
	}

	Segmented {
		anchors.right: parent.right
		anchors.rightMargin: 18
		y: 14
		width: 180
		options: [{ value: "draw", label: "Draw", icon: "draw" }, { value: "type", label: "Type", icon: "keyboard_outline" }]
		current: root.mode
		onSelected: value => root.mode = value
	}

	// ── the paper ──────────────────────────────────────────────────────────
	Rectangle {
		id: paper

		x: 20
		y: 64
		width: parent.width - 40
		height: 250
		radius: Theme.radius.large
		color: "white"

		// the line to sign on
		Rectangle {
			x: 30
			width: parent.width - 60
			y: parent.height * 0.72
			height: 1
			color: "#c8c8c8"
		}

		Text {
			x: 30
			y: parent.height * 0.72 + 4
			text: "×"
			color: "#b0b0b0"
			font.pixelSize: 14
		}

		Canvas {
			id: pad

			anchors.fill: parent
			visible: root.mode === "draw"
			renderTarget: Canvas.Image
			onPaint: {
				const ctx = pad.getContext("2d");
				ctx.reset();
				root.paintStrokes(ctx, 0, 0, 1);
			}
		}

		MouseArea {
			anchors.fill: parent
			enabled: root.mode === "draw"
			cursorShape: Qt.CrossCursor
			preventStealing: true
			onPressed: mouse => {
				root.lastT = Date.now();
				root.lastW = 2.6;
				root.current = [{ x: mouse.x, y: mouse.y, w: 2.6 }];
				root.strokes = root.strokes.concat([root.current]);
				pad.requestPaint();
			}
			onPositionChanged: mouse => {
				if (!pressed) return;
				const last = root.current[root.current.length - 1];
				const d = Math.hypot(mouse.x - last.x, mouse.y - last.y);
				if (d < 1.2) return;
				const now = Date.now();
				const speed = d / Math.max(1, now - root.lastT);
				// fast is thin, slow is full; eased so the line does not jump
				const target = Math.max(1.0, Math.min(3.6, 3.8 - speed * 1.6));
				const w = root.lastW + (target - root.lastW) * 0.35;
				root.lastW = w;
				root.lastT = now;
				root.current.push({ x: mouse.x, y: mouse.y, w: w });
				pad.requestPaint();
			}
			onReleased: root.current = []
		}

		// typed: in the chosen hand
		Text {
			id: typedShown

			anchors.centerIn: parent
			anchors.verticalCenterOffset: -10
			visible: root.mode === "type"
			text: typed.text
			color: root.ink
			font.family: root.typeFont
			font.italic: root.typeFont !== "Z003"
			font.pixelSize: 64
			fontSizeMode: Text.HorizontalFit
			width: parent.width - 60
			horizontalAlignment: Text.AlignHCenter
		}
	}

	function paintStrokes(ctx, ox, oy, k) {
		ctx.lineCap = "round";
		ctx.lineJoin = "round";
		ctx.strokeStyle = String(root.ink);
		ctx.fillStyle = String(root.ink);
		for (const stroke of root.strokes) {
			if (stroke.length === 1) {
				ctx.beginPath();
				ctx.arc((stroke[0].x - ox) * k, (stroke[0].y - oy) * k, stroke[0].w * k / 2, 0, Math.PI * 2);
				ctx.fill();
				continue;
			}
			for (let i = 1; i < stroke.length; i += 1) {
				const a = stroke[i - 1], b = stroke[i];
				ctx.beginPath();
				ctx.lineWidth = (a.w + b.w) / 2 * k;
				// through the middle of the points: a smooth line
				if (i < stroke.length - 1) {
					const c = stroke[i + 1];
					ctx.moveTo((a.x + b.x) / 2 * k - ox * k, (a.y + b.y) / 2 * k - oy * k);
					ctx.quadraticCurveTo((b.x - ox) * k, (b.y - oy) * k, ((b.x + c.x) / 2 - ox) * k, ((b.y + c.y) / 2 - oy) * k);
				} else {
					ctx.moveTo((a.x - ox) * k, (a.y - oy) * k);
					ctx.lineTo((b.x - ox) * k, (b.y - oy) * k);
				}
				ctx.stroke();
			}
		}
	}

	// ── typing ─────────────────────────────────────────────────────────────
	property string typeFont: root.fonts[0] ?? "Z003"
	property var fonts: ["Z003", "Nimbus Roman", "P052", "C059", "URW Bookman"]

	// hands the machine has beyond those
	Process {
		running: true
		command: ["sh", "-c", "fc-list : family | grep -iE 'script|hand|caveat|vibes|satisfy|signature|dancing|pacifico|allura|sacramento|kalam|marck|homemade|indie|shadows|cursive|brush|z003' | cut -d, -f1 | sort -u | head -8"]
		stdout: StdioCollector {
			onStreamFinished: {
				const found = text.split("\n").map(s => s.trim()).filter(s => s);
				root.fonts = found.concat(root.fonts.filter(f => !found.includes(f)));
				root.typeFont = root.fonts[0];
			}
		}
	}

	Row {
		x: 20
		y: paper.y + paper.height + 12
		width: parent.width - 40
		spacing: 8
		visible: root.mode === "type"

		Field {
			id: typed

			width: parent.width * 0.42
			height: 36
			placeholder: "Your name"
		}

		Flickable {
			width: parent.width * 0.58 - 8
			height: 36
			contentWidth: fontRow.implicitWidth
			clip: true

			Row {
				id: fontRow

				spacing: 6

				Repeater {
					model: root.fonts

					delegate: Chip {
						required property string modelData

						text: typed.text.trim() ? typed.text.trim().split(" ")[0] : "Aa"
						selected: root.typeFont === modelData
						onClicked: root.typeFont = modelData
					}
				}
			}
		}
	}

	// ── what to do ─────────────────────────────────────────────────────────
	Row {
		anchors.right: parent.right
		anchors.rightMargin: 20
		anchors.bottom: parent.bottom
		anchors.bottomMargin: 16
		spacing: 8

		Row {
			spacing: 4
			anchors.verticalCenter: parent.verticalCenter

			Repeater {
				model: ["#0d1b5e", "#000000", "#1e88e5"]

				delegate: Rectangle {
					required property string modelData

					width: 22
					height: 22
					radius: 11
					color: modelData
					border.color: Theme.primary
					border.width: String(root.ink) === modelData ? 3 : 0

					MouseArea {
						anchors.fill: parent
						onClicked: {
							root.ink = parent.modelData;
							pad.requestPaint();
						}
					}
				}
			}
		}

		TextButton {
			text: "Clear"
			icon: "eraser"
			visible: root.mode === "draw"
			onActivated: {
				root.strokes = [];
				pad.requestPaint();
			}
		}

		TextButton {
			text: "Cancel"
			variant: "ghost"
			onActivated: root.dock?.closeSheet()
		}

		TextButton {
			text: "Keep and put it on"
			icon: "check"
			variant: "filled"
			enabled: !root.empty
			onActivated: root.finish()
		}
	}

	// ── a picture of it, trimmed to the ink ────────────────────────────────
	readonly property string stamp: String(Date.now())

	function finish() {
		const out = `${Paths.state}/pdf-signature-${Date.now()}.png`;
		if (root.mode === "type") {
			typedShown.grabToImage(result => {
				result.saveToFile(out);
				root.keep(out, typedShown.contentWidth || typedShown.width, typedShown.contentHeight || typedShown.height);
			}, Qt.size(typedShown.width * 2, typedShown.height * 2));
			return;
		}
		let x0 = 1e9, y0 = 1e9, x1 = -1e9, y1 = -1e9;
		for (const stroke of root.strokes) for (const p of stroke) {
			x0 = Math.min(x0, p.x - p.w);
			y0 = Math.min(y0, p.y - p.w);
			x1 = Math.max(x1, p.x + p.w);
			y1 = Math.max(y1, p.y + p.w);
		}
		trim.box = [x0 - 4, y0 - 4, x1 - x0 + 8, y1 - y0 + 8];
		trim.target = out;
		trim.requestPaint();
	}

	// drawn again at twice the size into a canvas of just the ink, then saved
	Canvas {
		id: trim

		property var box: [0, 0, 1, 1]
		property string target: ""

		x: 0
		y: 0
		z: -1
		opacity: 0.01
		width: Math.max(1, trim.box[2] * 2)
		height: Math.max(1, trim.box[3] * 2)
		onPaint: {
			if (!trim.target) return;
			const ctx = trim.getContext("2d");
			ctx.reset();
			root.paintStrokes(ctx, trim.box[0], trim.box[1], 2);
		}
		onPainted: {
			if (!trim.target) return;
			const out = trim.target;
			trim.target = "";
			if (trim.save(out)) root.keep(out, trim.box[2], trim.box[3]);
			else Pdf.say("The signature could not be kept", "alert_circle_outline");
		}
	}

	// saved among the signatures, and on the page with the next click
	function keep(path, w, h) {
		const list = (Pdf.setting("signatures", []) || []).concat([{ image: path, w: w, h: h, name: root.purpose, at: Date.now() }]);
		Pdf.setSetting("signatures", list);
		if (root.done) root.done(path, w, h);
		root.dock?.closeSheet();
	}
}
