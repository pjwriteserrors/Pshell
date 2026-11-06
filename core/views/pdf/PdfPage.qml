pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
import QtQuick.Pdf
import qs.style.theme
import qs.style.widgets
import qs.core.services

// One page of the recipe as it is read: a white sheet with a soft shadow,
// the source page drawn by PDFium (a small picture at once, the sharp one
// faded over it when it is ready, a tile of the part looked at when it is
// shown larger than a picture can be), cropped and turned as the recipe
// says – the turn glides. Above it what the reader does with it: the text
// selected, the words found, the links (a page they lead to peeks out on
// hover), the marks of the recipe (PageOverlay.qml, the editor's) and how
// the whole file will look (watermark, numbers, header and footer).
// Night turns the sheet dark by a shader that keeps the colours.
Item {
	id: root

	// the recipe page's id; `reader` holds the documents, the search and the viewport
	required property string pageId
	property var reader: null
	// px per point now, and the scale the sharp picture is drawn at (follows `k` once it rests)
	property real k: 1
	property real renderK: root.k
	// links, selection, the marks: off for thumbnails, the peek and the slides' strip
	property bool interactive: true
	// the small picture only (thumbnails)
	property bool thumbnail: false
	property bool shadow: true
	property bool night: Pdf.night
	// the reader's viewport (for deep zoom tiles), and whether the page is looked at
	property Item viewport: null
	property bool active: true

	readonly property var page: Pdf.pageById(root.pageId)
	readonly property string src: root.page?.src ?? ""
	readonly property int n: root.page?.n ?? 0
	readonly property var doc: root.src !== "" && root.reader ? (root.reader.docs[root.src] ?? null) : null
	readonly property bool ready: !!root.doc && root.doc.status === PdfDocument.Ready
	readonly property size base: Pdf.baseSize(root.page)
	readonly property var crop: root.page?.crop ?? null
	readonly property int rot: root.page?.rot ?? 0
	// the cropped page, before its turn
	readonly property real cw: (root.crop ? root.crop[2] : root.base.width) * root.k
	readonly property real ch: (root.crop ? root.crop[3] : root.base.height) * root.k
	readonly property bool sideways: root.rot % 180 === 90
	readonly property int index: Pdf.indexOf(root.pageId)
	readonly property real dpr: Screen.devicePixelRatio || 1
	// what the sharp picture would need; above this a tile of the visible part is drawn instead
	readonly property real fullPx: Math.max(root.base.width, root.base.height) * root.renderK * root.dpr
	readonly property int capPx: 4096

	// the item a point of the page space is drawn in (the overlay and the reader map through it)
	readonly property alias space: space

	implicitWidth: root.sideways ? root.ch : root.cw
	implicitHeight: root.sideways ? root.cw : root.ch
	width: root.implicitWidth
	height: root.implicitHeight

	signal pressedText()

	RectangularShadow {
		anchors.fill: card
		visible: root.shadow
		radius: card.radius
		blur: root.thumbnail ? 8 : 22
		spread: 0
		offset.y: root.thumbnail ? 1 : 4
		color: Qt.rgba(0, 0, 0, root.night ? 0.6 : 0.32)
	}

	Rectangle {
		id: card

		anchors.fill: parent
		radius: root.thumbnail ? 2 : 3
		color: root.night ? "#1b1c20" : "white"
		clip: true

		Behavior on color {
			ColorAnimation {
				duration: Motion.long
			}
		}

		// the cropped page, turned about its middle
		Item {
			id: turner

			anchors.centerIn: parent
			width: root.cw
			height: root.ch
			rotation: root.rot > 270 ? root.rot - 360 : root.rot

			Behavior on rotation {
				enabled: root.interactive
				SpatialAnim {
					duration: Motion.long
				}
			}

			// the page space: points × k, its corner at the crop's
			Item {
				id: space

				x: root.crop ? -root.crop[0] * root.k : 0
				y: root.crop ? -root.crop[1] * root.k : 0
				width: root.base.width * root.k
				height: root.base.height * root.k

				// ── the picture ────────────────────────────────────────
				// built only while the document is read: a page image without one loads the whole file again
				readonly property bool drawn: root.ready && !root.page?.blank && !root.page?.image

				// a small one first, at once
				Loader {
					id: lowLoader

					anchors.fill: parent
					active: space.drawn
					visible: !shade.on

					sourceComponent: PdfPageImage {
						document: root.doc
						currentFrame: root.n
						asynchronous: true
						cache: true
						smooth: true
						sourceSize.width: root.thumbnail ? Math.max(48, Math.round(root.base.width * root.renderK * root.dpr)) : 260
						opacity: sharp.ready && sharp.shownOnce ? 0 : 1
					}
				}

				// the sharp one, faded over it the first time; later renders swap under it
				Loader {
					id: sharp

					readonly property bool ready: !!sharp.item && sharp.item.status === Image.Ready
					property bool shownOnce: false

					anchors.fill: parent
					active: space.drawn && !root.thumbnail && root.active
					visible: !shade.on

					sourceComponent: PdfPageImage {
						id: sharpImage

						document: root.doc
						currentFrame: root.n
						asynchronous: true
						cache: false
						smooth: true
						mipmap: false
						sourceSize.width: Math.round(root.base.width * root.renderK * root.dpr * Math.min(1, root.capPx / Math.max(1, root.fullPx)))
						sourceSize.height: Math.round(root.base.height * root.renderK * root.dpr * Math.min(1, root.capPx / Math.max(1, root.fullPx)))
						opacity: sharpImage.status === Image.Ready ? 1 : 0
						onStatusChanged: if (sharpImage.status === Image.Ready) sharp.shownOnce = true

						Behavior on opacity {
							enabled: !sharp.shownOnce
							Anim {
								duration: Motion.medium
							}
						}
					}
				}

				// a picture as a page: fitted on the sheet
				Image {
					anchors.fill: parent
					visible: !!root.page?.image && !shade.on
					source: root.page?.image ? Pdf.fileUrl(root.page.image) : ""
					fillMode: Image.PreserveAspectFit
					asynchronous: true
					sourceSize.width: Math.min(root.capPx, Math.round(parent.width * root.dpr))
				}

				// night and grey: the pictures above through the page shader (no copy of them)
				Item {
					id: shade

					readonly property bool on: root.night || !!Pdf.recipe.finish?.grayscale

					anchors.fill: parent
					visible: shade.on

					Repeater {
						model: shade.on ? [lowLoader.item, sharp.item].filter(x => !!x) : []

						ShaderEffect {
							required property var modelData

							anchors.fill: parent
							visible: modelData.status === Image.Ready && (modelData === sharp.item || !sharp.ready)
							property var source: modelData
							property real night: root.night ? 1 : 0
							property real gray: Pdf.recipe.finish?.grayscale ? 1 : 0
							fragmentShader: Qt.resolvedUrl("shaders/page.frag.qsb")
						}
					}
				}

				// deep zoom: the part looked at, drawn by the helper at the size it is shown
				Image {
					id: tile

					property var rect: null
					property string key: ""

					visible: !!tile.rect && tile.status === Image.Ready && !root.night
					x: (tile.rect?.[0] ?? 0) * root.k
					y: (tile.rect?.[1] ?? 0) * root.k
					width: (tile.rect?.[2] ?? 0) * root.k
					height: (tile.rect?.[3] ?? 0) * root.k
					asynchronous: true
					cache: false
					smooth: true
				}

				// ── what the reader does with it ───────────────────────
				// the words found: every one, the current one pulsing
				Shape {
					id: hitShape

					anchors.fill: parent
					visible: root.interactive && Pdf.searchText !== "" && hitPath.paths.length > 0
					preferredRendererType: Shape.CurveRenderer

					ShapePath {
						fillColor: Qt.alpha("#ffb300", 0.38)
						strokeColor: Qt.alpha("#ff8f00", 0.7)
						strokeWidth: 1
						scale: Qt.size(root.k, root.k)

						PathMultiline {
							id: hitPath

							paths: {
								const model = root.interactive && root.reader ? root.reader.searchModelOf(root.src) : null;
								// the hits are read for the binding to follow new results
								return model && root.reader.hits.length >= 0 && Pdf.searchText !== "" ? model.boundingPolygonsOnPage(root.n) : [];
							}
						}
					}
				}

				Rectangle {
					id: currentHit

					readonly property var hit: root.reader?.currentHit ?? null
					readonly property var box: currentHit.hit && currentHit.hit.pageId === root.pageId ? root.reader.boxOfHit(currentHit.hit, hitPath.paths) : null

					visible: !!currentHit.box
					x: (currentHit.box?.x ?? 0) * root.k - 3
					y: (currentHit.box?.y ?? 0) * root.k - 3
					width: (currentHit.box?.width ?? 0) * root.k + 6
					height: (currentHit.box?.height ?? 0) * root.k + 6
					radius: 4
					color: "transparent"
					border.color: "#ff6d00"
					border.width: 2

					SequentialAnimation on scale {
						running: currentHit.visible
						loops: Animation.Infinite
						NumberAnimation {
							to: 1.12
							duration: 520
							easing.type: Easing.OutCubic
						}
						NumberAnimation {
							to: 1
							duration: 520
							easing.type: Easing.InOutCubic
						}
					}
				}

				// the text selected (PDFium finds it between the two points)
				PdfSelection {
					id: selection

					anchors.fill: parent
					document: root.interactive ? root.doc : null
					page: root.n
					renderScale: Math.max(0.01, root.k)
					hold: !textDrag.pressed && !root.selecting
				}

				Shape {
					anchors.fill: parent
					visible: root.interactive && selection.text !== ""
					preferredRendererType: Shape.CurveRenderer

					ShapePath {
						fillColor: Qt.alpha(Theme.primary, 0.32)
						strokeColor: "transparent"
						scale: Qt.size(root.k, root.k)

						PathMultiline {
							paths: selection.geometry
						}
					}
				}

				// a press and drag on the page selects text; a double click looks closer there
				MouseArea {
					id: textDrag

					property point start: Qt.point(0, 0)
					property bool moved: false

					anchors.fill: parent
					enabled: root.interactive && !root.page?.blank && !root.page?.image
					acceptedButtons: Qt.LeftButton | Qt.RightButton
					preventStealing: true
					cursorShape: Qt.IBeamCursor
					onPressed: mouse => {
						if (mouse.button === Qt.RightButton) return;
						textDrag.start = Qt.point(mouse.x, mouse.y);
						textDrag.moved = false;
						root.reader?.pressedOn(root);
						selection.from = textDrag.start;
						selection.to = textDrag.start;
					}
					onPositionChanged: mouse => {
						if (!textDrag.pressed) return;
						if (Math.abs(mouse.x - textDrag.start.x) + Math.abs(mouse.y - textDrag.start.y) > 3) textDrag.moved = true;
						selection.to = Qt.point(mouse.x, mouse.y);
					}
					onReleased: mouse => {
						if (mouse.button === Qt.RightButton) return;
						if (!textDrag.moved) {
							selection.clear();
							root.reader?.selectionMade(root, null);
							return;
						}
						root.takeSelection();
					}
					onClicked: mouse => {
						if (mouse.button === Qt.RightButton) root.reader?.pageMenu(root, mouse.x / root.k, mouse.y / root.k, textDrag);
					}
					onDoubleClicked: mouse => root.reader?.zoomAt(root, mouse.x, mouse.y)
				}

				// the links: a page fades to where they lead, a page they lead to peeks out
				Repeater {
					model: root.interactive && root.active && root.ready && !root.page?.blank ? linkModel : null

					MouseArea {
						id: link

						required property rect rectangle
						required property url url
						required property int page
						required property point location

						x: link.rectangle.x * root.k
						y: link.rectangle.y * root.k
						width: link.rectangle.width * root.k
						height: link.rectangle.height * root.k
						hoverEnabled: true
						cursorShape: Qt.PointingHandCursor
						onEntered: hoverTimer.restart()
						onExited: {
							hoverTimer.stop();
							root.reader?.unpeek();
						}
						onClicked: {
							hoverTimer.stop();
							root.reader?.unpeek();
							root.reader?.follow(root.src, link.page, link.location, String(link.url));
						}

						Timer {
							id: hoverTimer

							interval: 380
							onTriggered: {
								const at = link.mapToItem(root.reader, link.width / 2, link.height);
								root.reader?.peek(root.src, link.page, link.location, String(link.url), at.x, at.y, link.mapToItem(root.reader, 0, 0).y);
							}
						}

						Rectangle {
							anchors.fill: parent
							anchors.margins: -2
							radius: 3
							color: Qt.alpha(Theme.primary, link.containsMouse ? 0.16 : 0)

							Behavior on color {
								ColorAnimation {
									duration: Motion.short
								}
							}
						}
					}
				}

				PdfLinkModel {
					id: linkModel

					document: root.interactive && root.active && root.ready ? root.doc : null
					page: root.n
				}

				// the recipe's marks of this page: drawn and edited by the editor (PageOverlay.qml)
				Loader {
					id: overlay

					anchors.fill: parent
					// slides show the marks too, but take no pointer
					active: !root.thumbnail && ((root.interactive && Pdf.editing) || root.hasItems || root.hasFields)
					enabled: root.interactive
					source: overlay.active ? Qt.resolvedUrl("PageOverlay.qml") : ""
				}

				Binding {
					target: overlay.item
					property: "pageId"
					value: root.pageId
					when: overlay.status === Loader.Ready
				}
				Binding {
					target: overlay.item
					property: "pageScale"
					value: root.k
					when: overlay.status === Loader.Ready
				}
				Binding {
					target: overlay.item
					property: "editable"
					value: Pdf.editing && root.interactive
					when: overlay.status === Loader.Ready
				}
			}
		}

		// ── the whole file as it will be: drawn on the page as it is shown ──
		Loader {
			anchors.fill: parent
			active: !root.thumbnail && root.hasDoc
			sourceComponent: DocMarks {}
		}

		// thumbnails of marked pages carry their marks as small coloured ticks
		Row {
			anchors.right: parent.right
			anchors.top: parent.top
			anchors.margins: 3
			spacing: 2
			visible: root.thumbnail && root.hasItems

			Repeater {
				model: root.thumbnail ? Pdf.itemsOf(root.pageId).slice(0, 4) : []

				Rectangle {
					required property var modelData

					width: 5
					height: 5
					radius: 2.5
					color: modelData.color || (modelData.kind === "redact" ? "black" : Theme.primary)
				}
			}
		}
	}

	readonly property bool hasItems: Pdf.items.length > 0 && Pdf.items.some(item => item.page === root.pageId)
	// PDFium draws no form widgets: the overlay shows the file's fields, to be filled while reading too
	readonly property bool hasFields: root.src === "a" && Pdf.fields.length > 0 && Pdf.fields.some(field => field.page === root.n)
	readonly property var docRecipe: Pdf.recipe.doc ?? ({})
	readonly property bool hasDoc: !!(root.docRecipe.watermark || root.docRecipe.numbers || root.docRecipe.header || root.docRecipe.footer || root.docRecipe.bates)

	// the selection as the service keeps it: its page, its text, its lines in page space
	function takeSelection() {
		const text = selection.text;
		if (!text) {
			root.reader?.selectionMade(root, null);
			return;
		}
		const quads = [];
		const geometry = selection.geometry || [];
		for (let i = 0; i < geometry.length; i += 1) {
			const box = root.reader ? root.reader.polyBox(geometry[i]) : null;
			if (box && box.width > 0 && box.height > 0) quads.push([box.x, box.y, box.width, box.height]);
		}
		Pdf.selection = { page: root.pageId, text: text, quads: quads };
		// a marking pen on: the selection is marked at once
		if (Pdf.editing && ["highlight", "underline", "strike", "squiggly", "redact"].includes(Pdf.draw)) {
			Pdf.markSelection(Pdf.draw);
			return;
		}
		root.reader?.selectionMade(root, quads);
	}

	function clearSelection() {
		selection.clear();
	}

	// the page's whole text selected (Ctrl+A)
	function selectAll() {
		root.selecting = true;
		selection.selectAll();
		Qt.callLater(() => {
			root.takeSelection();
			root.selecting = false;
		});
	}

	// text between two points of the page space selected as a drag would (keys, tests)
	property bool selecting: false

	function selectBetween(x0, y0, x1, y1) {
		root.selecting = true;
		selection.from = Qt.point(x0 * root.k, y0 * root.k);
		selection.to = Qt.point(x1 * root.k, y1 * root.k);
		Qt.callLater(() => {
			root.takeSelection();
			root.selecting = false;
		});
	}

	// the pages the reader built, by id: it finds them for the selection and the keys
	Component.onCompleted: if (root.interactive && root.reader?.pageItems) root.reader.pageItems[root.pageId] = root
	Component.onDestruction: if (root.reader?.pageItems && root.reader.pageItems[root.pageId] === root) delete root.reader.pageItems[root.pageId]

	// the bounds of the selection in this item's coordinates (for the menu above it)
	function selectionBounds(quads) {
		let x0 = 1e9, y0 = 1e9, x1 = -1e9, y1 = -1e9;
		for (const q of quads || []) {
			x0 = Math.min(x0, q[0]);
			y0 = Math.min(y0, q[1]);
			x1 = Math.max(x1, q[0] + q[2]);
			y1 = Math.max(y1, q[1] + q[3]);
		}
		if (x1 < x0) return null;
		const a = space.mapToItem(root, x0 * root.k, y0 * root.k);
		const b = space.mapToItem(root, x1 * root.k, y1 * root.k);
		return Qt.rect(Math.min(a.x, b.x), Math.min(a.y, b.y), Math.abs(b.x - a.x), Math.abs(b.y - a.y));
	}

	// a point of the page space in this item (turned and cropped)
	function pointOf(x, y) {
		return space.mapToItem(root, x * root.k, y * root.k);
	}

	Connections {
		target: Pdf

		function onClearSelection() {
			selection.clear();
		}

		function onSelectionChanged() {
			if (!Pdf.selection || Pdf.selection.page !== root.pageId) selection.clear();
		}
	}

	// ── deep zoom ──────────────────────────────────────────────────────────
	readonly property bool deep: !root.thumbnail && root.interactive && root.active && root.fullPx > root.capPx && !root.page?.blank && !root.page?.image

	function askTile() {
		if (!root.deep || !root.viewport || !root.ready) {
			tile.rect = null;
			return;
		}
		const r = root.viewport.mapToItem(space, 0, 0, root.viewport.width, root.viewport.height);
		const x0 = Math.max(0, r.x / root.k), y0 = Math.max(0, r.y / root.k);
		const x1 = Math.min(root.base.width, (r.x + r.width) / root.k), y1 = Math.min(root.base.height, (r.y + r.height) / root.k);
		if (x1 - x0 < 1 || y1 - y0 < 1) return;
		const clip = [Math.floor(x0), Math.floor(y0), Math.ceil(x1 - x0), Math.ceil(y1 - y0)];
		const dpi = Math.round(72 * root.renderK * root.dpr);
		const key = clip.join(",") + "@" + dpi;
		if (tile.key === key) return;
		tile.key = key;
		const source = Pdf.recipe.sources?.[root.src];
		Pdf.request("render", { path: Pdf.sourcePath(root.src), page: root.n, dpi: dpi, clip: clip, password: source?.password ?? "" }, data => {
			if (!data?.image || tile.key !== key) return;
			tile.source = "";
			tile.source = Pdf.fileUrl(data.image);
			tile.rect = data.clip || clip;
		});
	}

	Timer {
		id: tileTimer

		interval: 260
		onTriggered: root.askTile()
	}

	onRenderKChanged: if (root.deep) tileTimer.restart(); else tile.rect = null
	onDeepChanged: if (root.deep) tileTimer.restart(); else tile.rect = null

	Connections {
		target: root.reader
		enabled: root.deep
		ignoreUnknownSignals: true

		function onSettled() {
			tileTimer.restart();
		}
	}

	// ── watermark, numbers, header, footer, Bates: the preview of `doc` ────
	component DocMarks: Item {
		id: marks

		readonly property var d: root.docRecipe
		readonly property real pk: root.k
		readonly property int total: Pdf.pageCount
		readonly property int number: root.index + 1

		function fill(text) {
			const date = new Date().toLocaleDateString(Qt.locale(), Locale.ShortFormat);
			return String(text || "").replace(/\{n\}/g, String(marks.number)).replace(/\{total\}/g, String(marks.total))
				.replace(/\{date\}/g, date).replace(/\{title\}/g, Pdf.title).replace(/\{file\}/g, Pdf.nameOf(Pdf.path));
		}

		// the watermark: across the middle
		Text {
			anchors.centerIn: parent
			visible: !!marks.d.watermark && !marks.d.watermark.image && marks.inPages(marks.d.watermark.pages)
			text: marks.d.watermark?.text ?? ""
			color: marks.d.watermark?.color ?? "#888888"
			opacity: marks.d.watermark?.opacity ?? 0.15
			rotation: -(marks.d.watermark?.angle ?? 45)
			font.pixelSize: Math.max(4, (marks.d.watermark?.size ?? 48) * marks.pk)
			font.family: "Helvetica"
			font.bold: true
		}

		Image {
			anchors.centerIn: parent
			visible: !!marks.d.watermark?.image
			source: marks.d.watermark?.image ? Pdf.fileUrl(marks.d.watermark.image) : ""
			width: parent.width * 0.5
			height: parent.height * 0.5
			fillMode: Image.PreserveAspectFit
			opacity: marks.d.watermark?.opacity ?? 0.15
			rotation: -(marks.d.watermark?.angle ?? 0)
		}

		function inPages(text) {
			if (!text) return true;
			for (const part of String(text).split(",")) {
				const m = part.trim().match(/^(\d+)?\s*[-–]?\s*(\d+)?$/);
				if (!m) continue;
				const a = m[1] ? Number(m[1]) : 1, b = part.includes("-") || part.includes("–") ? (m[2] ? Number(m[2]) : 1e9) : a;
				if (marks.number >= a && marks.number <= b) return true;
			}
			return false;
		}

		// page numbers where asked
		Text {
			readonly property var o: marks.d.numbers
			readonly property string where: o?.position ?? "bottom"

			visible: !!o && marks.number >= (o.from ?? 1)
			text: o ? marks.fill(o.format || "{n}").replace(String(marks.number), String(marks.number - (o.from ?? 1) + (o.start ?? 1))) : ""
			font.pixelSize: Math.max(3, (o?.size ?? 10) * marks.pk)
			font.family: "Helvetica"
			color: "#222222"
			x: where.endsWith("left") ? 36 * marks.pk : (where.endsWith("right") ? parent.width - width - 36 * marks.pk : (parent.width - width) / 2)
			y: where.startsWith("top") ? 22 * marks.pk : parent.height - height - 22 * marks.pk
		}

		Repeater {
			model: [["header", false], ["footer", true]]

			Item {
				id: band

				required property var modelData
				readonly property var o: marks.d[band.modelData[0]]

				anchors.left: parent.left
				anchors.right: parent.right
				anchors.leftMargin: 36 * marks.pk
				anchors.rightMargin: 36 * marks.pk
				y: band.modelData[1] ? parent.height - height - 14 * marks.pk : 14 * marks.pk
				height: Math.max(4, (band.o?.size ?? 9) * marks.pk * 1.4)
				visible: !!band.o

				Text {
					anchors.left: parent.left
					text: marks.fill(band.o?.left)
					font.pixelSize: Math.max(3, (band.o?.size ?? 9) * marks.pk)
					font.family: "Helvetica"
					color: "#333333"
				}
				Text {
					anchors.horizontalCenter: parent.horizontalCenter
					text: marks.fill(band.o?.center)
					font.pixelSize: Math.max(3, (band.o?.size ?? 9) * marks.pk)
					font.family: "Helvetica"
					color: "#333333"
				}
				Text {
					anchors.right: parent.right
					text: marks.fill(band.o?.right)
					font.pixelSize: Math.max(3, (band.o?.size ?? 9) * marks.pk)
					font.family: "Helvetica"
					color: "#333333"
				}
			}
		}

		Text {
			readonly property var o: marks.d.bates
			readonly property string where: o?.position ?? "bottom-right"

			visible: !!o
			text: o ? `${o.prefix ?? ""}${String((o.start ?? 1) + marks.number - 1).padStart(o.digits ?? 6, "0")}` : ""
			font.pixelSize: Math.max(3, 9 * marks.pk)
			font.family: "Helvetica"
			font.bold: true
			color: "#111111"
			x: where.endsWith("left") ? 24 * marks.pk : (where.endsWith("right") ? parent.width - width - 24 * marks.pk : (parent.width - width) / 2)
			y: where.startsWith("top") ? 12 * marks.pk : parent.height - height - 12 * marks.pk
		}
	}
}
