pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Shapes
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "Edit.js" as Edit

// One mark of the recipe on its page, drawn as the helper will write it:
// in page space times `s` (pixels per point), on the overlay's page plane.
// Only the picture – choosing, moving and the handles are the overlay's.
Item {
	id: root

	property var item: ({})
	property real s: 1
	property bool editable: false
	property bool selected: false
	// a copy of one just removed, fading away
	property bool ghost: false
	// shown while its words are typed (the overlay's editor lies on top)
	property bool typing: false

	readonly property string kind: root.item?.kind ?? ""
	readonly property color color: root.item?.color || "#ffd54f"
	readonly property real alpha: root.item?.opacity ?? 1
	readonly property var box: Pdf.boundsOf(root.item)

	anchors.fill: parent

	// a new one pops in, a removed one fades
	opacity: 0
	scale: 1
	Component.onCompleted: {
		if (root.ghost) {
			root.opacity = 1;
			leave.start();
		} else arrive.start();
	}

	ParallelAnimation {
		id: arrive

		NumberAnimation {
			target: root
			property: "opacity"
			from: 0
			to: 1
			duration: Motion.short
		}
	}

	NumberAnimation {
		id: leave

		target: root
		property: "opacity"
		to: 0
		duration: Motion.medium
		easing.type: Easing.InQuad
	}

	// ── marks on text ──────────────────────────────────────────────────────
	Repeater {
		model: ["highlight", "underline", "strike", "squiggly", "redact"].includes(root.kind) ? (root.item.quads ?? []) : []

		delegate: Item {
			id: quad

			required property var modelData
			readonly property real h: quad.modelData[3] * root.s

			x: quad.modelData[0] * root.s
			y: quad.modelData[1] * root.s
			width: quad.modelData[2] * root.s
			height: quad.h

			Rectangle {
				anchors.fill: parent
				visible: root.kind === "highlight"
				color: root.color
				opacity: root.item.opacity ?? 0.45
				radius: Math.min(2, quad.h * 0.1)
			}

			Rectangle {
				visible: root.kind === "underline"
				width: parent.width
				height: Math.max(1, quad.h * 0.07)
				y: quad.h * 0.93 - height / 2
				color: root.color
				opacity: root.alpha
			}

			Rectangle {
				visible: root.kind === "strike"
				width: parent.width
				height: Math.max(1, quad.h * 0.07)
				y: quad.h * 0.52 - height / 2
				color: root.color
				opacity: root.alpha
			}

			Shape {
				visible: root.kind === "squiggly"
				anchors.fill: parent
				preferredRendererType: Shape.CurveRenderer

				ShapePath {
					strokeColor: root.color
					strokeWidth: Math.max(1, quad.h * 0.06)
					fillColor: "transparent"

					PathPolyline {
						path: {
							const pts = [];
							const step = Math.max(2, quad.h * 0.16);
							const top = quad.h * 0.86, low = quad.h * 0.98;
							for (let x = 0, i = 0; x <= quad.width + 0.1; x += step, i += 1) pts.push(Qt.point(x, i % 2 === 0 ? top : low));
							return pts;
						}
					}
				}
			}

			Rectangle {
				anchors.fill: parent
				visible: root.kind === "redact"
				color: "black"
			}
		}
	}

	// ── the pen ────────────────────────────────────────────────────────────
	// one shape a stroke (a drawing is mostly one); a marker's strokes overlap without darkening each other
	Item {
		anchors.fill: parent
		visible: root.kind === "ink"
		opacity: root.alpha
		layer.enabled: root.kind === "ink" && root.alpha < 0.99

		Repeater {
			model: root.kind === "ink" ? (root.item.strokes ?? []) : []

			delegate: Shape {
				id: stroke

				required property var modelData

				anchors.fill: parent
				preferredRendererType: Shape.CurveRenderer

				ShapePath {
					strokeColor: root.color
					strokeWidth: Math.max(0.6, (root.item.width ?? 2) * root.s)
					fillColor: "transparent"
					capStyle: ShapePath.RoundCap
					joinStyle: ShapePath.RoundJoin

					PathPolyline {
						path: stroke.modelData.length === 1 ? [Qt.point(stroke.modelData[0][0] * root.s, stroke.modelData[0][1] * root.s), Qt.point(stroke.modelData[0][0] * root.s + 0.01, stroke.modelData[0][1] * root.s)] : stroke.modelData.map(p => Qt.point(p[0] * root.s, p[1] * root.s))
					}
				}
			}
		}
	}

	// ── shapes ─────────────────────────────────────────────────────────────
	Rectangle {
		visible: root.kind === "rect"
		x: root.box[0] * root.s
		y: root.box[1] * root.s
		width: root.box[2] * root.s
		height: root.box[3] * root.s
		color: root.item.fill || "transparent"
		border.color: root.color
		border.width: Math.max(0.6, (root.item.width ?? 2) * root.s)
		opacity: root.alpha
	}

	Loader {
		anchors.fill: parent
		active: root.kind === "ellipse" || root.kind === "line" || root.kind === "arrow"
		sourceComponent: Shape {
			id: shape

			readonly property real w: Math.max(0.6, (root.item.width ?? 2) * root.s)

			preferredRendererType: Shape.CurveRenderer
			opacity: root.alpha

			ShapePath {
				strokeColor: root.color
				strokeWidth: shape.w
				fillColor: root.kind === "ellipse" ? (root.item.fill || "transparent") : "transparent"
				capStyle: ShapePath.RoundCap
				joinStyle: ShapePath.RoundJoin

				PathAngleArc {
					centerX: (root.box[0] + root.box[2] / 2) * root.s
					centerY: (root.box[1] + root.box[3] / 2) * root.s
					radiusX: Math.max(0.5, root.box[2] / 2 * root.s - shape.w / 2)
					radiusY: Math.max(0.5, root.box[3] / 2 * root.s - shape.w / 2)
					startAngle: 0
					sweepAngle: root.kind === "ellipse" ? 360 : 0
				}
			}

			ShapePath {
				strokeColor: root.kind === "ellipse" ? "transparent" : root.color
				strokeWidth: shape.w
				fillColor: "transparent"
				capStyle: ShapePath.RoundCap
				joinStyle: ShapePath.RoundJoin

				PathPolyline {
					path: {
						const p = root.item.points ?? [[0, 0], [0, 0]];
						const a = Qt.point(p[0][0] * root.s, p[0][1] * root.s), b = Qt.point(p[1][0] * root.s, p[1][1] * root.s);
						if (root.kind !== "arrow") return [a, b];
						// an open arrow at the end, as /LE OpenArrow draws it
						const angle = Math.atan2(b.y - a.y, b.x - a.x);
						const len = Math.max(6 * root.s, (root.item.width ?? 2) * 4.5 * root.s);
						const l = Qt.point(b.x - len * Math.cos(angle - 0.45), b.y - len * Math.sin(angle - 0.45));
						const r = Qt.point(b.x - len * Math.cos(angle + 0.45), b.y - len * Math.sin(angle + 0.45));
						return [a, b, l, b, r];
					}
				}
			}
		}
	}

	// ── a sticky note ──────────────────────────────────────────────────────
	Item {
		id: note

		visible: root.kind === "note"
		x: (root.item.at?.[0] ?? 0) * root.s
		y: (root.item.at?.[1] ?? 0) * root.s
		width: Math.max(16, 20 * root.s)
		height: width

		Rectangle {
			anchors.fill: parent
			radius: width * 0.18
			color: root.item.color || "#ffd54f"
			border.color: Qt.darker(color, 1.4)
			border.width: 1

			Glyph {
				anchors.centerIn: parent
				icon: "note_text_outline"
				size: parent.width * 0.66
				color: "#3a3000"
				surface: "transparent"
				animated: false
			}
		}

		// what it says, unfolded while chosen
		Rectangle {
			x: note.width + 6
			y: 0
			width: Math.min(260, Math.max(140, noteText.implicitWidth + 20))
			height: noteText.implicitHeight + 16
			radius: Theme.radius.small
			color: "#fff8d6"
			border.color: "#e0c860"
			visible: root.kind === "note" && root.selected && !root.typing && (root.item.text ?? "") !== ""
			opacity: visible ? 1 : 0
			transformOrigin: Item.TopLeft
			scale: visible ? 1 : 0.85

			Behavior on scale {
				SpatialAnim {}
			}

			Text {
				id: noteText

				x: 10
				y: 8
				width: Math.min(240, implicitWidth)
				text: root.item.text ?? ""
				wrapMode: Text.WordWrap
				color: "#3a3000"
				font.family: Theme.fontFamily
				font.pixelSize: 12
			}
		}
	}

	// ── boxes with words or pictures ───────────────────────────────────────
	Item {
		id: boxItem

		visible: ["textbox", "stamp", "link", "field", "text", "whiteout", "image", "signature"].includes(root.kind) || (root.kind === "redact" && !!root.item.rect)
		x: root.box[0] * root.s
		y: root.box[1] * root.s
		width: root.box[2] * root.s
		height: root.box[3] * root.s
		opacity: root.kind === "image" ? root.alpha : 1

		// the cover of a text correction lies where the old words were
		Rectangle {
			visible: root.kind === "text" && !!root.item.cover
			x: ((root.item.cover?.[0] ?? 0) - root.box[0]) * root.s
			y: ((root.item.cover?.[1] ?? 0) - root.box[1]) * root.s
			width: (root.item.cover?.[2] ?? 0) * root.s
			height: (root.item.cover?.[3] ?? 0) * root.s
			color: root.item.coverColor || "#ffffff"
		}

		Rectangle {
			anchors.fill: parent
			visible: root.kind === "whiteout" || root.kind === "redact" || (root.kind === "textbox" && !!root.item.fill)
			color: root.kind === "redact" ? "black" : (root.kind === "whiteout" ? (root.item.color || "#ffffff") : root.item.fill)
		}

		// blacked out while editing: still black, the stripes say it is not done yet
		Glyph {
			anchors.centerIn: parent
			visible: root.kind === "redact" && root.editable && parent.height > 14
			icon: "eye_off_outline"
			size: Math.min(parent.height * 0.6, 18)
			color: "#bbbbbb"
			surface: "transparent"
			animated: false
		}

		EditText {
			anchors.fill: parent
			visible: (root.kind === "textbox" || root.kind === "text") && !root.typing
			text: root.item.text ?? ""
			color: root.item.color || "#000000"
			s: root.s
			size: root.item.size ?? 12
			font: root.item.font || "Helvetica"
			bold: !!root.item.bold
			italic: !!root.item.italic
			align: root.item.align || "left"
			pad: root.item.pad ?? (root.kind === "textbox" ? 2 : 0)
			single: false
		}

		// a stamp: its word framed, the day beneath
		Rectangle {
			anchors.fill: parent
			visible: root.kind === "stamp" && !root.item.image
			color: "transparent"
			radius: height * 0.12
			border.color: root.item.color || "#c62828"
			border.width: Math.max(1, Math.min(parent.width, parent.height) * 0.05)
			rotation: 0

			Column {
				anchors.centerIn: parent

				Text {
					anchors.horizontalCenter: parent.horizontalCenter
					text: String(root.item.label ?? "").toUpperCase()
					color: root.item.color || "#c62828"
					font.family: "Nimbus Sans"
					font.bold: true
					font.pixelSize: Math.max(1, boxItem.height * (root.item.date ? 0.42 : 0.56))
					fontSizeMode: Text.HorizontalFit
					width: boxItem.width * 0.9
					horizontalAlignment: Text.AlignHCenter
				}

				Text {
					anchors.horizontalCenter: parent.horizontalCenter
					visible: !!root.item.date
					text: typeof root.item.date === "string" ? root.item.date : Edit.today()
					color: root.item.color || "#c62828"
					font.family: "Nimbus Sans"
					font.pixelSize: Math.max(1, boxItem.height * 0.2)
				}
			}
		}

		Image {
			anchors.fill: parent
			visible: ["image", "signature"].includes(root.kind) || (root.kind === "stamp" && !!root.item.image)
			source: visible ? Pdf.fileUrl(root.item.path || root.item.image || "") : ""
			fillMode: Image.Stretch
			asynchronous: true
			smooth: true
			mipmap: true
			sourceSize.width: Math.min(2048, Math.max(64, boxItem.width * 2))
		}

		// links and new fields only show while editing
		Rectangle {
			anchors.fill: parent
			visible: (root.kind === "link" || root.kind === "field") && root.editable
			color: root.kind === "link" ? Qt.rgba(0.12, 0.53, 0.9, 0.12) : Qt.rgba(0.4, 0.3, 0.9, 0.1)
			border.color: root.kind === "link" ? "#1e88e5" : "#7e57c2"
			border.width: 1
			radius: 2

			Row {
				anchors.left: parent.left
				anchors.leftMargin: 4
				anchors.verticalCenter: parent.verticalCenter
				spacing: 4
				visible: parent.height > 12

				Glyph {
					anchors.verticalCenter: parent.verticalCenter
					icon: root.kind === "link" ? "link_variant" : ({ check: "checkbox_marked_outline", choice: "form_dropdown", signature: "draw_pen" })[root.item.type] ?? "form_textbox"
					size: Math.min(14, boxItem.height * 0.7)
					color: root.kind === "link" ? "#1e88e5" : "#7e57c2"
					surface: "transparent"
					animated: false
				}

				Text {
					anchors.verticalCenter: parent.verticalCenter
					text: root.kind === "link" ? (root.item.url || (root.item.target ? `Page ${Pdf.indexOf(root.item.target) + 1}` : "Where to?")) : (root.item.name || "field")
					color: root.kind === "link" ? "#1565c0" : "#5e35b1"
					font.pixelSize: Math.max(8, Math.min(11, boxItem.height * 0.55))
					elide: Text.ElideRight
					width: Math.max(0, boxItem.width - 26)
				}
			}
		}
	}
}
