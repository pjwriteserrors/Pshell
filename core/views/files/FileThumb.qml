pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import Quickshell.Widgets
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "FileKinds.js" as Kinds

// The picture of a file: its thumbnail where there is one (pictures,
// videos, PDFs, album covers, office documents), a folder drawn with what
// is inside it peeking out, the first lines of a text, else a glyph in the
// colour of its kind. Thumbnails are asked for when the card is shown.
Item {
	id: root

	property string path: ""
	property string name: ""
	property string mime: ""
	property bool dir: false
	property string kind: "other"
	property string thumb: ""
	property bool canThumb: false
	// when the file last changed: a folder's count and a text's lines are read again after
	property real mtime: 0
	property bool isText: false
	property bool hovered: false
	property bool selected: false
	property bool dropTarget: false
	// the cards use the 256 px thumbnails, bigger pictures the 512 px ones
	property string size: root.width > 260 ? "x-large" : "large"
	// lists draw a small version without the folder art
	property bool compact: false
	property real radius: Theme.radius.medium

	readonly property color tone: {
		switch (Kinds.toneOf({ dir: root.dir, mime: root.mime, name: root.name })) {
		case "primary": return Theme.primary;
		case "secondary": return Theme.secondary;
		case "tertiary": return Theme.tertiary;
		case "danger": return Theme.danger;
		case "warning": return Theme.warning;
		case "success": return Theme.success;
		default: return Theme.textMuted;
		}
	}
	readonly property string picture: {
		Files.thumbTick;
		const made = Files.thumbOf(root.path);
		return made !== "" ? made : root.thumb;
	}
	readonly property var peek: {
		Files.peekTick;
		return Files.peekOf(root.path);
	}
	readonly property bool pictured: root.picture !== "" && !root.dir
	readonly property bool photo: root.kind === "image" || root.kind === "video"

	// the file's size, for the settings' limit on thumbnails
	property real bytes: 0
	readonly property bool remote: root.path.startsWith("/run/user/") && root.path.includes("/gvfs/")
	readonly property bool thumbAllowed: (!root.remote || FileLibrary.setting("remoteThumbs"))
		&& (Number(FileLibrary.setting("thumbLimit")) === 0 || root.bytes <= Number(FileLibrary.setting("thumbLimit")) * 1e6)
	readonly property bool textShown: FileLibrary.setting("textPreviews")

	function ask() {
		if (root.path === "") return;
		if (!root.dir && root.canThumb && root.picture === "" && root.thumbAllowed) Files.wantThumb(root.path, root.mime, root.size);
		if (!root.compact && (root.dir || (root.isText && !root.pictured && root.textShown))) Files.checkPeek(root.path, root.dir ? "inode/directory" : root.mime, root.mtime);
	}

	onThumbAllowedChanged: Qt.callLater(root.ask)
	onTextShownChanged: Qt.callLater(root.ask)

	onPathChanged: Qt.callLater(root.ask)
	onMtimeChanged: Qt.callLater(root.ask)
	onHoveredChanged: {
		if (root.hovered && paper.visible) sweep.restart();
		if (root.hovered) back.stop();
		else if (lines.y !== 6) back.restart();
	}
	Component.onCompleted: root.ask()

	// ── a picture ──────────────────────────────────────────────────────────
	ClippingRectangle {
		id: photoFrame

		visible: root.pictured && (root.photo || root.kind === "audio" || root.compact)
		anchors.fill: parent
		radius: root.radius
		color: Theme.layer2

		Image {
			id: photoImage

			anchors.fill: parent
			source: photoFrame.visible ? root.picture : ""
			asynchronous: true
			// a photo fills the frame; an icon or a drawing of another shape is
			// shown whole. The shape is taken once it is loaded: the image's own
			// size follows its fill mode, a binding would go round in circles.
			property real ratio: 0
			readonly property bool fills: root.kind === "video" || root.compact || photoImage.ratio === 0 || Math.abs(Math.log(photoImage.ratio / Math.max(0.01, photoFrame.width / Math.max(1, photoFrame.height)))) < 0.22
			fillMode: photoImage.fills ? Image.PreserveAspectCrop : Image.PreserveAspectFit
			onStatusChanged: if (status === Image.Ready && sourceSize.height > 0) photoImage.ratio = sourceSize.width / sourceSize.height
			onSourceChanged: photoImage.ratio = 0
			sourceSize.width: root.compact ? 64 : 0
			smooth: true
			mipmap: !root.compact
			opacity: status === Image.Ready ? 1 : 0
			scale: root.hovered && !root.compact ? 1.05 : 1

			Behavior on opacity {
				Anim {
					duration: Motion.short
				}
			}
			Behavior on scale {
				SpatialAnim {
					duration: Motion.long
				}
			}
		}

		// a video says it plays
		Rectangle {
			visible: root.kind === "video" && !root.compact
			anchors.centerIn: parent
			width: Math.min(44, parent.width * 0.32)
			height: width
			radius: width / 2
			color: Qt.rgba(0, 0, 0, root.hovered ? 0.55 : 0.38)
			scale: root.hovered ? 1.12 : 1

			Behavior on scale {
				SpatialAnim {
					duration: Motion.medium
				}
			}
			Behavior on color {
				ColorAnim {}
			}

			Glyph {
				anchors.centerIn: parent
				anchors.horizontalCenterOffset: 1
				icon: "play"
				size: parent.width * 0.55
				color: "white"
				surface: "transparent"
			}
		}
	}

	// ── a page: PDFs, office documents, other thumbnails ───────────────────
	Item {
		id: paper

		visible: root.pictured && !photoFrame.visible
		anchors.fill: parent

		// under the pointer the page lifts towards the eye: its shadow grows soft
		// and wide below it, and a sheen of light runs once over the paper
		property real lift: root.hovered ? 1 : 0

		Behavior on lift {
			SpatialAnim {
				duration: Motion.long
			}
		}

		// at rest a plain shadow close under the page (cheap for a folder of
		// hundreds of PDFs); lifted, a blurred one further down takes over
		Rectangle {
			x: sheet.x + 1
			y: sheet.y + 3
			width: sheet.width
			height: sheet.height + 1
			radius: 5
			color: Theme.shadow
			opacity: 0.4 * (1 - Math.min(1, Math.max(0, paper.lift)))
		}

		Rectangle {
			id: shade

			visible: paper.lift > 0.01
			x: sheet.x + 3
			y: sheet.y + 4 + 8 * Math.max(0, paper.lift)
			width: sheet.width - 6
			height: sheet.height - 4
			radius: 6
			color: Theme.shadow
			opacity: 0.6 * Math.min(1, Math.max(0, paper.lift))
			layer.enabled: shade.visible
			layer.effect: MultiEffect {
				blurEnabled: true
				blurMax: 32
				blur: 0.85
			}
		}

		Rectangle {
			id: sheet

			readonly property real ratio: pageImage.implicitWidth > 0 ? pageImage.implicitHeight / pageImage.implicitWidth : 1.3
			x: (parent.width - width) / 2
			y: (parent.height - height) / 2 - 5 * paper.lift
			height: Math.min(parent.height * 0.9, parent.width * 0.84 * sheet.ratio)
			width: height / sheet.ratio
			radius: 4
			color: "white"
			scale: 1 + 0.035 * paper.lift
			antialiasing: true
			clip: true

			Image {
				id: pageImage

				anchors.fill: parent
				anchors.margins: 1
				source: paper.visible ? root.picture : ""
				asynchronous: true
				fillMode: Image.PreserveAspectFit
				mipmap: true
				opacity: status === Image.Ready ? 1 : 0

				Behavior on opacity {
					Anim {
						duration: Motion.short
					}
				}
			}

			// the sheen: a soft band of light that crosses the page once
			Rectangle {
				id: sheen

				property real travel: -1
				width: sheet.width * 0.7
				height: sheet.height * 2
				x: sheet.width * sheen.travel - width / 2
				y: -sheet.height / 2
				rotation: 24
				opacity: 0.55
				gradient: Gradient {
					orientation: Gradient.Horizontal

					GradientStop {
						position: 0
						color: Qt.rgba(1, 1, 1, 0)
					}
					GradientStop {
						position: 0.5
						color: Qt.rgba(1, 1, 1, 0.55)
					}
					GradientStop {
						position: 1
						color: Qt.rgba(1, 1, 1, 0)
					}
				}
			}

			NumberAnimation {
				id: sweep

				target: sheen
				property: "travel"
				from: -0.6
				to: 1.6
				duration: 900
				easing.type: Easing.InOutCubic
			}

			// the paper's edge catches the light a little when it is up
			Rectangle {
				anchors.fill: parent
				radius: parent.radius
				color: "transparent"
				border.width: 1
				border.color: Qt.rgba(0, 0, 0, 0.08 + 0.04 * Math.max(0, paper.lift))
			}
		}
	}

	// ── a folder ───────────────────────────────────────────────────────────
	Item {
		id: folderArt

		visible: root.dir && !root.compact
		anchors.fill: parent

		readonly property var pictures: FileLibrary.setting("folderPeeks") ? (root.peek?.pictures ?? []) : []
		readonly property color body: Qt.tint(Theme.layer2, Qt.alpha(root.tone, root.selected || root.dropTarget ? 0.5 : 0.32))
		readonly property color back: Qt.tint(Theme.layer1, Qt.alpha(root.tone, root.selected || root.dropTarget ? 0.38 : 0.22))
		property real lift: root.dropTarget ? 1 : (root.hovered ? 0.55 : 0)

		Behavior on lift {
			SpatialAnim {
				duration: Motion.medium
			}
		}

		Rectangle {
			x: parent.width * 0.1
			y: parent.height * 0.08
			width: parent.width * 0.34
			height: parent.height * 0.2
			radius: 7
			color: folderArt.back

			Behavior on color {
				ColorAnim {}
			}
		}

		Rectangle {
			x: parent.width * 0.1
			y: parent.height * 0.15
			width: parent.width * 0.8
			height: parent.height * 0.74
			radius: 11
			color: folderArt.back

			Behavior on color {
				ColorAnim {}
			}
		}

		// what is inside peeks out, and rises when the pointer comes
		Repeater {
			model: folderArt.pictures.slice(0, 3)

			// drawn through a layer with a clear rim, so its edges stay smooth when turned
			delegate: Item {
				id: card

				required property string modelData
				required property int index
				readonly property int count: Math.min(3, folderArt.pictures.length)
				readonly property real spread: card.count === 1 ? 0 : (card.index - (card.count - 1) / 2)

				width: folderArt.width * 0.5 + 4
				height: (folderArt.width * 0.5) * 0.74 + 4
				x: folderArt.width / 2 - width / 2 + card.spread * folderArt.width * (0.17 + 0.06 * folderArt.lift)
				y: folderArt.height * (0.1 - 0.1 * folderArt.lift) + Math.abs(card.spread) * folderArt.height * 0.05 - 2
				rotation: card.spread * (7 + 6 * folderArt.lift)
				antialiasing: true
				layer.enabled: true
				layer.smooth: true
				layer.mipmap: true

				ClippingRectangle {
					anchors.fill: parent
					anchors.margins: 2
					radius: 6
					color: Theme.layer3

					Image {
						anchors.fill: parent
						source: card.modelData
						asynchronous: true
						fillMode: Image.PreserveAspectCrop
						sourceSize.width: 200
						smooth: true
						mipmap: true
						opacity: status === Image.Ready ? 1 : 0

						Behavior on opacity {
							Anim {}
						}
					}
				}
			}
		}

		// the front, tipping open a little for a drop
		Rectangle {
			id: front

			x: parent.width * 0.06
			y: parent.height * 0.44
			width: parent.width * 0.88
			height: parent.height * 0.5
			radius: 11
			color: folderArt.body
			antialiasing: true

			transform: Rotation {
				origin.x: front.width / 2
				origin.y: front.height
				axis { x: 1; y: 0; z: 0 }
				angle: -18 * (root.dropTarget ? 1 : (root.hovered ? 0.35 : 0))

				Behavior on angle {
					SpatialAnim {
						duration: Motion.medium
					}
				}
			}

			Behavior on color {
				ColorAnim {}
			}

			// a bright edge on top
			Rectangle {
				anchors.left: parent.left
				anchors.right: parent.right
				anchors.top: parent.top
				anchors.margins: 6
				anchors.topMargin: 1
				height: 1
				color: Qt.alpha("white", Theme.dark ? 0.14 : 0.5)
			}

			Glyph {
				anchors.centerIn: parent
				anchors.verticalCenterOffset: 2
				visible: root.special !== ""
				icon: root.special
				size: Math.min(parent.height * 0.42, 30)
				color: Qt.alpha(root.tone, 0.85)
				surface: front.color
			}
		}
	}

	// the folders everyone has get their sign on the front
	readonly property string special: {
		if (!root.dir) return "";
		const name = root.path.slice(root.path.lastIndexOf("/") + 1);
		if (Files.parentOf(root.path) !== Files.home) return root.path.endsWith("/Screenshots") ? "monitor_screenshot" : "";
		switch (name) {
		case "Downloads": return "download";
		case "Documents": return "file_document_outline";
		case "Pictures": return "image_outline";
		case "Videos": return "filmstrip";
		case "Music": return "music_note";
		case "Desktop": return "monitor";
		case "Public": return "account_multiple_outline";
		case "Templates": return "file_document_edit_outline";
		case "Projects":
		case "Code":
		case "src": return "code_braces";
		default: return "";
		}
	}

	// ── text: its first lines ──────────────────────────────────────────────
	// under the pointer the page lifts and slowly reads on, down its lines
	Rectangle {
		id: textPage

		readonly property string snippet: String(root.peek?.snippet ?? "")
		property real lift: root.hovered ? 1 : 0
		visible: !root.dir && !root.pictured && !root.compact && root.isText && root.textShown && textPage.snippet !== ""
		anchors.centerIn: parent
		anchors.verticalCenterOffset: -3 * textPage.lift
		height: parent.height * 0.94
		width: Math.min(parent.width * 0.86, height * 0.84)
		radius: 7
		color: Theme.layer2
		clip: true
		scale: 1 + 0.03 * textPage.lift
		border.width: 1
		border.color: Qt.alpha(root.tone, Math.max(0, 0.35 * textPage.lift))

		Behavior on lift {
			SpatialAnim {
				duration: Motion.medium
			}
		}

		Text {
			id: lines

			readonly property real overflow: Math.max(0, lines.implicitHeight - (textPage.height - 14))
			x: 7
			y: 6
			width: parent.width - 14
			text: textPage.visible ? (root.kind === "code" ? Peek.highlight(textPage.snippet, Peek.langOfPath(root.name), 2400) : textPage.snippet) : ""
			textFormat: root.kind === "code" ? Text.RichText : Text.PlainText
			color: Theme.textMuted
			font.family: Theme.monoFamily
			font.pixelSize: Math.max(5, Math.min(8, root.width / 22))
			lineHeight: 1.1
			wrapMode: Text.NoWrap
		}

		// reading on: as fast as an eye would, back up quickly when the pointer leaves
		SequentialAnimation {
			running: root.hovered && lines.overflow > 4 && textPage.visible

			PauseAnimation {
				duration: 350
			}
			NumberAnimation {
				target: lines
				property: "y"
				to: 6 - lines.overflow
				duration: Math.min(9000, lines.overflow * 28)
				easing.type: Easing.InOutSine
			}
		}

		NumberAnimation {
			id: back

			target: lines
			property: "y"
			to: 6
			duration: Motion.medium
			easing.type: Easing.BezierSpline
			easing.bezierCurve: Motion.decel
		}

		Rectangle {
			anchors.left: parent.left
			anchors.right: parent.right
			anchors.bottom: parent.bottom
			height: parent.height * 0.4
			gradient: Gradient {
				GradientStop {
					position: 0
					color: Qt.alpha(Theme.layer2, 0)
				}
				GradientStop {
					position: 1
					color: Theme.layer2
				}
			}
		}
	}

	// ── anything else: a glyph ─────────────────────────────────────────────
	Rectangle {
		id: plain

		visible: !folderArt.visible && !photoFrame.visible && !paper.visible && !textPage.visible
		anchors.centerIn: parent
		width: root.compact ? parent.width : Math.min(parent.width, parent.height) * 0.72
		height: width
		radius: root.compact ? root.radius : width * 0.3
		color: Qt.tint(Theme.layer1, Qt.alpha(root.tone, root.selected ? 0.3 : 0.16))
		scale: root.hovered && !root.compact ? 1.06 : 1

		Behavior on scale {
			SpatialAnim {}
		}
		Behavior on color {
			ColorAnim {}
		}

		Glyph {
			anchors.centerIn: parent
			anchors.verticalCenterOffset: root.compact || badge.text === "" ? 0 : -parent.height * 0.08
			icon: Kinds.glyphOf({ dir: root.dir, mime: root.mime, name: root.name })
			size: parent.width * (root.compact ? 0.62 : 0.42)
			color: root.tone
			surface: plain.color
			animated: false
		}

		Text {
			id: badge

			visible: !root.compact && text !== ""
			anchors.horizontalCenter: parent.horizontalCenter
			anchors.bottom: parent.bottom
			anchors.bottomMargin: parent.height * 0.12
			text: Kinds.badgeOf({ dir: root.dir, name: root.name })
			color: Qt.alpha(root.tone, 0.9)
			font.family: Theme.fontFamily
			font.pixelSize: Math.max(8, parent.height * 0.12)
			font.weight: Font.Bold
			font.letterSpacing: 0.6
		}
	}
}
