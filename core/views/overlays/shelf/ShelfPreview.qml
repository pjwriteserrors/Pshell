pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io
import qs.style.theme
import qs.core.services
import qs.style.widgets

// What an item looks like: images and GIFs themselves, the first page of a
// PDF, a frame of a video, an album cover, the start of a text file, code
// highlighted, a colour as its swatch, a sum with its result, a LaTeX
// formula set. `mode` is "row" (a small square), "tile" (the grid) or
// "large" (the space bar preview, which sizes itself by preferredWidth and
// preferredHeight within maxWidth × maxHeight).
Item {
	id: root

	property var item: null
	property string mode: "tile"
	property real maxWidth: 800
	property real maxHeight: 600

	readonly property bool large: root.mode === "large"
	readonly property bool row: root.mode === "row"
	readonly property var textKind: root.item?.kind === "text" ? Peek.kindOfText(root.item.text) : ({ type: "" })
	readonly property string fileKind: Peek.kindOfFile(root.item)
	readonly property string lang: root.textKind.type === "code" ? root.textKind.lang : (root.fileKind === "code" ? Peek.langOfPath(root.item.path) : "")
	property string thumbImage: ""
	property string thumbText: ""
	property string result: ""

	readonly property bool pictured: root.fileKind === "image" || root.fileKind === "gif" || root.thumbImage !== ""
	readonly property bool coded: root.textKind.type === "code" || root.thumbText !== ""
	readonly property string shown: {
		if (root.pictured) return "picture";
		if (root.textKind.type === "color") return "color";
		if (root.textKind.type === "math" && root.result !== "") return "math";
		if (root.textKind.type === "latex") return "latex";
		if (root.coded) return "code";
		if (root.item?.kind === "text") return "text";
		return "glyph";
	}

	readonly property real preferredWidth: {
		if (root.shown === "picture") return Math.max(200, (root.fileKind === "gif" ? gif.paintedWidth : picture.paintedWidth));
		if (root.shown === "color") return 360;
		if (root.shown === "math" || root.shown === "latex") return Math.min(root.maxWidth, Math.max(320, formula.implicitWidth + 48));
		if (root.shown === "glyph") return 260;
		return Math.min(root.maxWidth, 680);
	}
	readonly property real preferredHeight: {
		if (root.shown === "picture") return Math.max(120, (root.fileKind === "gif" ? gif.paintedHeight : picture.paintedHeight));
		if (root.shown === "color") return 300;
		if (root.shown === "math" || root.shown === "latex") return Math.max(140, formula.implicitHeight + (expression.visible ? expression.implicitHeight : 0) + 64);
		if (root.shown === "glyph") return 200;
		return Math.min(root.maxHeight, body.implicitHeight + 24);
	}

	// ── pictures ─────────────────────────────────────────────────────────
	Image {
		id: picture

		anchors.centerIn: root.large ? parent : undefined
		anchors.fill: root.large ? undefined : parent
		width: root.large ? root.maxWidth : undefined
		height: root.large ? root.maxHeight : undefined
		visible: root.shown === "picture" && root.fileKind !== "gif"
		source: !visible ? "" : (root.fileKind === "image" ? Shelf.fileUri(root.item.path) : Shelf.fileUri(root.thumbImage))
		sourceSize: root.large ? Qt.size(root.maxWidth * 1.5, root.maxHeight * 1.5) : Qt.size(root.row ? 96 : 256, root.row ? 96 : 256)
		fillMode: root.large ? Image.PreserveAspectFit : Image.PreserveAspectCrop
		// a page reads from its top
		verticalAlignment: root.fileKind === "pdf" && !root.large ? Image.AlignTop : Image.AlignVCenter
		asynchronous: true
		cache: false
	}

	AnimatedImage {
		id: gif

		anchors.centerIn: root.large ? parent : undefined
		anchors.fill: root.large ? undefined : parent
		width: root.large ? Math.min(root.maxWidth, sourceSize.width || root.maxWidth) : undefined
		height: root.large ? Math.min(root.maxHeight, sourceSize.height || root.maxHeight) : undefined
		visible: root.fileKind === "gif"
		source: visible ? Shelf.fileUri(root.item.path) : ""
		fillMode: root.large ? Image.PreserveAspectFit : Image.PreserveAspectCrop
		playing: visible
		asynchronous: true
		cache: false
	}

	// what kind of file the picture stands for
	Rectangle {
		anchors.centerIn: parent
		visible: root.shown === "picture" && root.fileKind === "video" && !root.large
		width: root.row ? 18 : 36
		height: width
		radius: width / 2
		color: Qt.rgba(0, 0, 0, 0.55)

		Glyph {
			anchors.centerIn: parent
			icon: "play"
			size: root.row ? 12 : 22
			color: "white"
			surface: "transparent"
		}
	}

	// ── colour ───────────────────────────────────────────────────────────
	Rectangle {
		id: swatch

		readonly property color value: root.textKind.color ?? "transparent"
		readonly property color ink: swatch.value.hslLightness > 0.6 || swatch.value.a < 0.4 ? "#161616" : "#ffffff"

		anchors.fill: parent
		anchors.bottomMargin: root.large ? 110 : 0
		visible: root.shown === "color"
		radius: root.large ? Theme.radius.large : 0
		color: swatch.value

		StyledText {
			anchors.centerIn: parent
			visible: !root.row
			text: root.large ? "" : Peek.hexOf(swatch.value)
			tone: swatch.ink
			surface: "transparent"
			font.family: Theme.monoFamily
			font.pixelSize: Theme.size.label
			font.weight: Font.DemiBold
		}
	}

	Column {
		anchors.left: parent.left
		anchors.right: parent.right
		anchors.bottom: parent.bottom
		anchors.margins: 4
		visible: root.shown === "color" && root.large
		spacing: 6

		Repeater {
			model: root.shown === "color" && root.large ? Peek.notationsOf(swatch.value) : []

			delegate: StyledText {
				required property string modelData

				text: modelData
				font.family: Theme.monoFamily
				font.pixelSize: Theme.size.body
			}
		}
	}

	// ── sums and formulas ────────────────────────────────────────────────
	Column {
		anchors.centerIn: parent
		width: parent.width - (root.row ? 4 : 20)
		visible: root.shown === "math" || root.shown === "latex" && !root.row
		spacing: root.large ? 10 : 2

		StyledText {
			id: expression

			width: parent.width
			visible: root.shown === "math" && !root.row
			text: root.item?.text?.trim() ?? ""
			tone: Theme.textMuted
			horizontalAlignment: Text.AlignHCenter
			elide: Text.ElideMiddle
			font.family: Theme.monoFamily
			font.pixelSize: root.large ? Theme.size.heading : Theme.size.small
		}

		StyledText {
			id: formula

			width: parent.width
			text: root.shown === "math" ? (root.result.startsWith("≈") ? root.result : `= ${root.result}`) : (root.shown === "latex" ? Peek.latex(root.item.text) : "")
			textFormat: root.shown === "latex" ? Text.RichText : Text.PlainText
			horizontalAlignment: Text.AlignHCenter
			wrapMode: root.large || root.shown === "latex" ? Text.Wrap : Text.NoWrap
			elide: Text.ElideRight
			maximumLineCount: root.large ? 1000 : (root.row ? 1 : 4)
			fontSizeMode: root.large || root.shown === "latex" ? Text.FixedSize : Text.HorizontalFit
			minimumPixelSize: 8
			font.family: root.shown === "latex" ? "serif" : Theme.fontFamily
			font.pixelSize: root.large ? Theme.size.display : (root.row ? Theme.size.label : (root.shown === "latex" ? Theme.size.body : Theme.size.heading))
			font.weight: root.shown === "math" ? Font.DemiBold : Font.Normal
		}
	}

	// ── text and code ────────────────────────────────────────────────────
	Flickable {
		anchors.fill: parent
		anchors.margins: root.large ? 12 : (root.row ? 6 : 10)
		visible: root.shown === "text" || root.shown === "code" && !root.row
		interactive: root.large
		contentHeight: body.implicitHeight
		clip: true

		StyledText {
			id: body

			readonly property string source: root.item?.kind === "text" ? root.item.text : root.thumbText

			width: parent.width
			text: {
				if (root.row && root.shown === "text") return "Aa";
				if (root.shown === "code") return Peek.highlight(body.source, root.lang, root.large ? 40000 : 1500);
				return root.large ? body.source : body.source.slice(0, 1500);
			}
			textFormat: root.shown === "code" && !root.row ? Text.RichText : Text.PlainText
			tone: root.large || root.shown === "code" ? Theme.text : Theme.textMuted
			wrapMode: Text.Wrap
			elide: Text.ElideNone
			horizontalAlignment: root.row && root.shown === "text" ? Text.AlignHCenter : Text.AlignLeft
			verticalAlignment: Text.AlignTop
			font.family: root.shown === "code" || root.large ? Theme.monoFamily : Theme.fontFamily
			font.pixelSize: root.large ? Theme.size.body : (root.shown === "code" ? Theme.size.tiny : (root.row ? Theme.size.label : Theme.size.small))
		}
	}

	// row: code and formulas are too small to read, a sign says what it is
	Glyph {
		anchors.centerIn: parent
		visible: root.row && (root.shown === "code" || root.shown === "latex")
		icon: root.shown === "latex" ? "sigma" : "code_braces"
		size: 20
		color: Theme.primary
	}

	// ── everything else ──────────────────────────────────────────────────
	Glyph {
		anchors.centerIn: parent
		visible: root.shown === "glyph"
		icon: root.item ? (root.fileKind === "pdf" ? "file_pdf_box" : (root.textKind.type === "math" ? "calculator" : Shelf.iconFor(root.item))) : "file"
		size: root.large ? 64 : (root.row ? 20 : 40)
		color: root.item?.kind === "file" ? Theme.primary : Theme.text
	}

	// what kind of file or text it is
	Rectangle {
		anchors.left: parent.left
		anchors.bottom: parent.bottom
		anchors.margins: root.large ? 0 : 5
		visible: !root.row && !root.large && kindLabel.text !== ""
		width: kindLabel.implicitWidth + 10
		height: 16
		radius: 5
		color: Qt.alpha(Theme.base, 0.85)

		StyledText {
			id: kindLabel

			anchors.centerIn: parent
			text: {
				if (root.shown === "code") return root.lang !== "" && root.lang !== "code" ? Peek.langName(root.lang) : "";
				if (root.fileKind === "pdf" && root.shown === "picture") return "PDF";
				if (root.fileKind === "gif") return "GIF";
				if (root.shown === "latex") return "LaTeX";
				return "";
			}
			tone: Theme.textMuted
			font.pixelSize: Theme.size.tiny
			font.weight: Font.DemiBold
		}
	}

	// ── work ─────────────────────────────────────────────────────────────
	Process {
		id: thumbProc

		command: ["python3", Shelf.helper, "thumb", root.item?.path ?? "", root.large ? "1400" : "512", `${Paths.cache}/shelf-previews`]
		stdout: StdioCollector {
			onStreamFinished: {
				try {
					const found = JSON.parse(text);
					root.thumbImage = found.image ?? "";
					root.thumbText = found.text ?? "";
				} catch (error) {}
			}
		}
	}

	Process {
		id: mathProc

		command: ["qalc", "-t", `(${String(root.item?.text ?? "").trim().replace(/\*\*/g, "^")})`]
		stdout: StdioCollector {
			onStreamFinished: {
				const value = String(text).trim();
				root.result = value.length > 0 && value.length < 60 && !/error|warning/i.test(value) ? value : "";
			}
		}
	}

	// items are replaced whenever the shelf learns more about them
	readonly property string key: `${root.fileKind}|${root.item?.path ?? ""}|${root.item?.text ?? ""}|${root.mode}`

	function load() {
		root.thumbImage = "";
		root.thumbText = "";
		root.result = "";
		if (["pdf", "video", "audio", "code", "thumb"].includes(root.fileKind)) thumbProc.running = true;
		if (root.textKind.type === "math") mathProc.running = true;
	}

	onKeyChanged: Qt.callLater(root.load)
	Component.onCompleted: root.load()
}
