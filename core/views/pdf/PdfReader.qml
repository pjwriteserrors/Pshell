pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Pdf
import qs.style.theme
import qs.style.widgets
import qs.core.services

// The pages of the recipe, read: one under the other, two side by side, or
// as a book whose leaves turn. Only the pages near what is looked at are
// built – the place of every other one is known from its size alone, so a
// file of five hundred pages scrolls as lightly as one of five. Zoom glides
// at the pointer (Ctrl+wheel, pinching, the touchpad) with the pictures
// stretched while it moves and drawn sharp once it rests. The documents
// (one per source of the recipe), the search and the links live here; the
// pages (PdfPage.qml) draw them. See core/services/Pdf.qml.
Item {
	id: root

	// room left free around the pages (the bars, the dock)
	property real padTop: 0
	property real padBottom: 0
	property real padLeft: 0
	property real padRight: 0
	readonly property real side: 28
	readonly property real gap: 18

	// px per point as shown (zoom 1 = 100 %, a point is 4/3 px)
	property real displayZoom: Pdf.zoom
	readonly property real k: root.displayZoom * 4 / 3
	// the scale the sharp pictures are drawn at: follows k once it rests
	property real renderK: root.k
	readonly property bool moving: flick.moving || zoomSettle.running
	readonly property alias flickable: flick
	readonly property alias viewport: viewportItem

	signal settled()
	// a link that leads somewhere hovered: where it leads, where the pointer is (reader coordinates)
	signal peekWanted(int index, point location, string url, real x, real y, real top)
	signal peekGone()
	// the text selected and where (reader coordinates), or nothing
	signal selectionShown(rect box)
	signal selectionHidden()
	// a right click on a page: its id, the point in page space, where in the reader
	signal menuWanted(string pageId, real px, real py, real x, real y)

	Behavior on displayZoom {
		enabled: root.smoothZoom
		NumberAnimation {
			duration: Motion.medium
			easing.type: Easing.OutCubic
		}
	}

	property bool smoothZoom: true

	// ── the documents: one per source of the recipe ───────────────────────
	property var docs: ({})
	// the keys as an array that changes only when the sources do (a new array would reload every document)
	property var keys: []

	function followKeys() {
		const next = Pdf.sourceKeys;
		if (next.join("|") !== root.keys.join("|")) root.keys = next.slice();
	}

	Instantiator {
		model: root.keys

		delegate: PdfDocument {
			id: doc

			required property string modelData
			property bool blank: false
			// how long the first sharp page took (PdfPage.qml), and whether one is drawn
			property real renderMs: -1
			property bool drawnOnce: false

			source: doc.blank || !Pdf.sourcePath(doc.modelData) ? "" : Pdf.fileUrl(Pdf.sourcePath(doc.modelData))
			password: Pdf.recipe.sources?.[doc.modelData]?.password ?? ""
		}

		onObjectAdded: (index, object) => root.docs = Object.assign({}, root.docs, { [object.modelData]: object })
		onObjectRemoved: (index, object) => {
			const next = Object.assign({}, root.docs);
			if (next[object.modelData] === object) delete next[object.modelData];
			root.docs = next;
		}
	}

	// the file under the window was written again: every document read anew
	Connections {
		target: Pdf

		function onGenerationChanged() {
			for (const key in root.docs) root.docs[key].blank = true;
			Qt.callLater(() => {
				for (const key in root.docs) root.docs[key].blank = false;
			});
			fadeIn.restart();
		}

		function onRecipeChanged() {
			root.followKeys();
			root.relayoutSoon();
		}

		function onLayoutChanged() {
			root.relayoutSoon();
		}

		function onJump(index, y) {
			root.jumpTo(index, y);
		}

		function onFitChanged() {
			root.applyFit();
		}

		function onSearchStep(delta) {
			root.step(delta);
		}

		function onSearchTextChanged() {
			hitsTimer.restart();
		}

		function onPathChanged() {
			root.back = [];
			flick.contentY = 0;
			flick.contentX = 0;
		}
	}

	Component.onCompleted: {
		root.followKeys();
		root.relayout();
	}

	// ── the layout: rows of one or two pages, their place known by size ──
	// rows: [{ key, ids, w, h }] in points; their y in px for the k now
	property var rows: []
	property var rowY: []
	property var rowOfPage: []
	property var rowIndex: ({})
	property string layoutKey: ""
	property real contentW: 0
	property real contentH: 0
	// grows on every new placement: the built rows follow it
	property int tick: 0
	// pages moved by an edit glide to their new place; zoom and scroll do not
	property bool glide: false

	readonly property bool book: Pdf.layout === "book"

	function relayoutSoon() {
		Qt.callLater(root.relayout);
	}

	function buildRows() {
		const pages = Pdf.pages;
		const rows = [];
		const two = Pdf.layout === "two";
		for (let i = 0; i < pages.length;) {
			const ids = two && i + 1 < pages.length ? [pages[i].id, pages[i + 1].id] : [pages[i].id];
			let w = 0, h = 0;
			for (const id of ids) {
				const s = Pdf.sizeOf(pages[i + ids.indexOf(id)]);
				w += s.width;
				h = Math.max(h, s.height);
			}
			rows.push({ key: ids.join("+"), ids: ids, w: w, h: h, first: i });
			i += ids.length;
		}
		return rows;
	}

	function relayout() {
		const pages = Pdf.pages;
		// what decides the places: the order, the turns, the crops, the sizes
		let key = Pdf.layout + ":";
		for (const p of pages) key += `${p.id},${p.rot || 0},${p.crop ? p.crop.join("/") : ""},${p.src || ""}${p.n ?? ""};`;
		key += JSON.stringify(Pdf.sizes).length;
		if (key !== root.layoutKey) {
			const structural = root.layoutKey !== "" && root.rows.length > 0 && Pdf.path === root.laidPath;
			root.layoutKey = key;
			root.laidPath = Pdf.path;
			root.rows = root.buildRows();
			const index = {};
			const ofPage = [];
			root.rows.forEach((row, r) => {
				index[row.key] = r;
				for (let j = 0; j < row.ids.length; j += 1) ofPage[row.first + j] = r;
			});
			root.rowIndex = index;
			root.rowOfPage = ofPage;
			if (structural) {
				root.glide = true;
				glideOff.restart();
			}
			root.applyFit();
		}
		root.place();
	}

	property string laidPath: ""

	Timer {
		id: glideOff

		interval: Motion.long + 80
		onTriggered: root.glide = false
	}

	// every row's y at the k now: a sum along the sizes, cheap even for long files
	function place() {
		const k = root.k;
		const ys = new Array(root.rows.length);
		let y = root.padTop + 16, w = 0;
		for (let i = 0; i < root.rows.length; i += 1) {
			ys[i] = y;
			const row = root.rows[i];
			y += row.h * k + root.gap;
			w = Math.max(w, row.w * k + (row.ids.length - 1) * root.gap);
		}
		root.rowY = ys;
		root.contentH = y - root.gap + 24 + root.padBottom;
		root.contentW = Math.max(flick.width, w + 2 * root.side + root.padLeft + root.padRight);
		root.tick += 1;
		root.syncLive();
	}

	function rowWidth(r) {
		const row = root.rows[r];
		return row ? row.w * root.k + (row.ids.length - 1) * root.gap : 0;
	}

	function rowHeight(r) {
		return (root.rows[r]?.h ?? 0) * root.k;
	}

	function rowX(r) {
		const free = flick.width - root.padLeft - root.padRight;
		const w = root.rowWidth(r);
		return w + 2 * root.side <= free ? root.padLeft + (free - w) / 2 : root.padLeft + root.side;
	}

	// the row at a content y
	function rowAt(y) {
		let lo = 0, hi = root.rowY.length - 1;
		if (hi < 0) return -1;
		while (lo < hi) {
			const mid = (lo + hi + 1) >> 1;
			if (root.rowY[mid] <= y) lo = mid;
			else hi = mid - 1;
		}
		return lo;
	}

	// ── only the rows near the view are built ─────────────────────────────
	ListModel {
		id: live
	}

	function syncLive() {
		if (root.rows.length === 0) {
			live.clear();
			return;
		}
		const buffer = flick.height * 0.9;
		const a = Math.max(0, root.rowAt(flick.contentY - buffer));
		const b = Math.min(root.rows.length - 1, root.rowAt(flick.contentY + flick.height + buffer));
		const want = {};
		for (let r = a; r <= b; r += 1) want[root.rows[r].key] = true;
		for (let i = live.count - 1; i >= 0; i -= 1) {
			const key = live.get(i).key;
			if (!want[key]) live.remove(i);
			else delete want[key];
		}
		for (const key in want) live.append({ key: key });
	}

	// ── fitting ────────────────────────────────────────────────────────────
	function applyFit() {
		if (Pdf.fit === "" || root.rows.length === 0 || flick.width < 50) return;
		const r = root.rowOfPage[Pdf.page] ?? 0;
		const row = root.rows[r];
		if (!row) return;
		const free = flick.width - root.padLeft - root.padRight - 2 * root.side - (row.ids.length - 1) * root.gap;
		let z = free / Math.max(1, row.w * 4 / 3);
		if (Pdf.fit === "page" || root.book) z = Math.min(z, (flick.height - root.padTop - root.padBottom - 40) / Math.max(1, row.h * 4 / 3));
		z = Math.max(0.1, Math.min(8, z));
		if (Math.abs(z - Pdf.zoom) > 0.002) {
			root.anchorAt(flick.width / 2, Math.max(root.padTop + 10, 0));
			Pdf.zoom = z;
		}
	}

	onWidthChanged: fitTimer.restart()
	onHeightChanged: fitTimer.restart()
	onPadLeftChanged: fitTimer.restart()
	onPadRightChanged: fitTimer.restart()

	Timer {
		id: fitTimer

		interval: 30
		onTriggered: {
			root.smoothZoom = false;
			root.place();
			root.applyFit();
			root.smoothZoom = true;
		}
	}

	// ── zoom at a point ────────────────────────────────────────────────────
	// the point under the pointer stays under it while the zoom glides
	property var anchor: null

	function anchorAt(px, py) {
		const y = flick.contentY + py;
		const r = Math.max(0, root.rowAt(y));
		const h = Math.max(1, root.rowHeight(r));
		const x0 = root.rowX(r), w = Math.max(1, root.rowWidth(r));
		root.anchor = { row: r, fy: (y - (root.rowY[r] ?? 0)) / h, fx: (flick.contentX + px - x0) / w, px: px, py: py };
		zoomSettle.restart();
	}

	function zoomAtPoint(factor, px, py) {
		root.anchorAt(px, py);
		Pdf.setZoom(Pdf.zoom * factor);
	}

	function zoomCentre(factor) {
		root.zoomAtPoint(factor, flick.width / 2, flick.height / 3);
	}

	onKChanged: {
		root.place();
		const a = root.anchor;
		if (a && root.rows[a.row]) {
			flick.contentX = Math.max(0, Math.min(root.contentW - flick.width, root.rowX(a.row) + a.fx * root.rowWidth(a.row) - a.px));
			flick.contentY = Math.max(0, Math.min(root.contentH - flick.height, root.rowY[a.row] + a.fy * root.rowHeight(a.row) - a.py));
		}
		renderTimer.restart();
	}

	// zoom has rested: the anchor goes, the pictures are drawn sharp
	Timer {
		id: zoomSettle

		interval: Motion.medium + 160
		onTriggered: {
			root.anchor = null;
			root.settled();
		}
	}

	Timer {
		id: renderTimer

		interval: 220
		onTriggered: root.renderK = root.k
	}

	// a double click: closer there, or back to the width
	function zoomAt(page, x, y) {
		const p = page.space.mapToItem(root, x, y);
		if (Pdf.fit === "width" || Pdf.fit === "page") {
			root.anchorAt(p.x, p.y);
			Pdf.setZoom(Pdf.zoom * 2);
		} else {
			root.anchorAt(p.x, p.y);
			Pdf.fit = "width";
		}
	}

	// ── moving around ──────────────────────────────────────────────────────
	property bool jumping: false
	// where a link was followed from (Alt+Left goes back)
	property var back: []

	function jumpTo(index, y) {
		if (root.book) return;
		const r = root.rowOfPage[index];
		if (r === undefined) return;
		let target = root.rowY[r] - 12 - root.padTop;
		if (y !== undefined && y >= 0) {
			const row = root.rows[r];
			const p = Pdf.pageById(row.ids[0]);
			target = root.rowY[r] + Math.max(0, y - (p?.crop?.[1] ?? 0)) * root.k - flick.height * 0.22;
		}
		target = Math.max(0, Math.min(Math.max(0, root.contentH - flick.height), target));
		root.jumping = true;
		const far = Math.abs(target - flick.contentY) > flick.height * 5;
		if (far) {
			// a long way: there at once, the pages fading in
			flick.contentY = target;
			fadeIn.restart();
			root.jumping = false;
		} else {
			jumpAnim.to = target;
			jumpAnim.restart();
		}
	}

	NumberAnimation {
		id: jumpAnim

		target: flick
		property: "contentY"
		duration: Motion.long + 80
		easing.type: Easing.BezierSpline
		easing.bezierCurve: Motion.emphasized
		onFinished: root.jumping = false
	}

	function track() {
		if (root.jumping || root.rows.length === 0 || root.book) return;
		const r = Math.max(0, root.rowAt(flick.contentY + flick.height * 0.33));
		const first = root.rows[r]?.first ?? 0;
		if (first !== Pdf.page) Pdf.page = first;
	}

	function afterScroll() {
		root.syncLive();
		root.track();
		settleTimer.restart();
	}

	Timer {
		id: settleTimer

		interval: 180
		onTriggered: {
			root.settled();
			root.showSelection();
		}
	}

	// a link followed: within the file the page flies there, outside it opens
	function follow(src, page, location, url) {
		if (url && !/^#/.test(url)) {
			Qt.openUrlExternally(url);
			return;
		}
		const index = root.indexOfSource(src, page);
		if (index < 0) return;
		root.back = root.back.concat([{ page: Pdf.page, y: flick.contentY }]).slice(-30);
		Pdf.goTo(index, location ? location.y : -1);
	}

	function goBack() {
		if (root.back.length === 0) return;
		const last = root.back[root.back.length - 1];
		root.back = root.back.slice(0, -1);
		Pdf.page = last.page;
		jumpAnim.to = last.y;
		root.jumping = true;
		jumpAnim.restart();
	}

	// the first recipe page that shows page n of a source
	function indexOfSource(src, n) {
		const pages = Pdf.pages;
		for (let i = 0; i < pages.length; i += 1)
			if (pages[i].src === src && pages[i].n === n) return i;
		return -1;
	}

	function peek(src, page, location, url, x, y, top) {
		const index = url && !/^#/.test(url) ? -1 : root.indexOfSource(src, page);
		root.peekWanted(index, location, url, x, y, top);
	}

	function unpeek() {
		root.peekGone();
	}

	// ── the selection ──────────────────────────────────────────────────────
	// the built pages by id (they register themselves)
	property var pageItems: ({})

	// the whole text of the page looked at, selected (Ctrl+A)
	function selectPage() {
		const p = Pdf.pages[Pdf.page];
		const item = p ? root.pageItems[p.id] : null;
		if (!item) return;
		item.selectAll();
	}

	property Item selectionPage: null
	property var selectionQuads: null

	function pressedOn(page) {
		if (Pdf.selection) Pdf.selection = null;
		root.selectionPage = null;
		root.selectionHidden();
	}

	function selectionMade(page, quads) {
		root.selectionPage = quads ? page : null;
		root.selectionQuads = quads;
		root.showSelection();
	}

	function showSelection() {
		const page = root.selectionPage;
		if (!page || !Pdf.selection || Pdf.selection.page !== page.pageId) {
			root.selectionHidden();
			return;
		}
		const box = page.selectionBounds(root.selectionQuads);
		if (!box) return root.selectionHidden();
		const p = page.mapToItem(root, box.x, box.y);
		root.selectionShown(Qt.rect(p.x, p.y, box.width, box.height));
	}

	function pageMenu(page, px, py, item) {
		const p = page.space.mapToItem(root, px * root.k, py * root.k);
		root.menuWanted(page.pageId, px, py, p.x, p.y);
	}

	// ── search: a model per document, the hits in the recipe's order ──────
	property var searchModels: ({})
	property var hits: []
	readonly property var currentHit: Pdf.searchCurrent >= 0 ? (root.hits[Pdf.searchCurrent] ?? null) : null

	function searchModelOf(key) {
		return root.searchModels[key] ?? null;
	}

	Instantiator {
		id: searches

		model: root.keys

		delegate: QtObject {
			id: entry

			required property string modelData
			property PdfSearchModel search: PdfSearchModel {
				document: root.docs[entry.modelData] ?? null
				searchString: Pdf.searchText
			}
			// the results as objects: a PdfSearchModel row is only reachable through a delegate
			property Instantiator rows: Instantiator {
				model: Pdf.searchText !== "" ? entry.search : null
				onObjectAdded: hitsTimer.restart()
				onObjectRemoved: hitsTimer.restart()

				delegate: QtObject {
					required property int page
					required property int indexOnPage
					required property point location
					required property string contextBefore
					required property string contextAfter
				}
			}
		}

		onObjectAdded: (index, object) => root.searchModels = Object.assign({}, root.searchModels, { [object.modelData]: object.search })
		onObjectRemoved: (index, object) => {
			const next = Object.assign({}, root.searchModels);
			delete next[object.modelData];
			root.searchModels = next;
		}
	}

	Timer {
		id: hitsTimer

		interval: 120
		onTriggered: root.collectHits()
	}

	function collectHits() {
		if (Pdf.searchText === "") {
			root.hits = [];
			Pdf.searchCount = 0;
			Pdf.searchCurrent = -1;
			return;
		}
		// recipe pages by source page
		const where = {};
		Pdf.pages.forEach((p, i) => {
			if (!p.src) return;
			const key = `${p.src}:${p.n}`;
			(where[key] = where[key] || []).push(i);
		});
		const list = [];
		for (let s = 0; s < searches.count; s += 1) {
			const entry = searches.objectAt(s);
			if (!entry) continue;
			const rows = entry.rows;
			for (let i = 0; i < rows.count && list.length < 3000; i += 1) {
				const h = rows.objectAt(i);
				if (!h) continue;
				for (const index of where[`${entry.modelData}:${h.page}`] || [])
					list.push({ index: index, pageId: Pdf.pages[index].id, src: entry.modelData, n: h.page, at: h.indexOnPage, location: Qt.point(h.location.x, h.location.y), before: h.contextBefore, after: h.contextAfter });
			}
		}
		list.sort((a, b) => a.index - b.index || a.at - b.at);
		root.hits = list;
		Pdf.searchCount = list.length;
		// the first one from the page looked at on
		if (list.length === 0) Pdf.searchCurrent = -1;
		else if (Pdf.searchCurrent < 0 || Pdf.searchCurrent >= list.length) {
			const next = list.findIndex(h => h.index >= Pdf.page);
			Pdf.searchCurrent = next >= 0 ? next : 0;
			root.showHit();
		}
	}

	function step(delta) {
		if (root.hits.length === 0) return;
		Pdf.searchCurrent = ((Pdf.searchCurrent < 0 ? 0 : Pdf.searchCurrent + delta) % root.hits.length + root.hits.length) % root.hits.length;
		root.showHit();
	}

	function showHit() {
		const h = root.currentHit;
		if (!h) return;
		if (root.book) Pdf.page = h.index;
		else Pdf.goTo(h.index, h.location.y);
	}

	// the box of a hit among the polygons of its page: the one nearest to where PDFium says it starts
	function boxOfHit(hit, paths) {
		let best = null, bestD = 1e12;
		for (let i = 0; i < (paths?.length ?? 0); i += 1) {
			const box = root.polyBox(paths[i]);
			if (!box) continue;
			const x0 = box.x, y0 = box.y, x1 = box.x + box.width, y1 = box.y + box.height;
			const d = Math.pow(x0 - hit.location.x, 2) + Math.pow((y0 + y1) / 2 - hit.location.y, 2);
			if (d < bestD) {
				bestD = d;
				best = Qt.rect(x0, y0, x1 - x0, y1 - y0);
			}
		}
		return best;
	}

	// a polygon of PDFium (a QPolygonF, opaque to JS but printable) as its bounding box in points
	function polyBox(poly) {
		if (!poly) return null;
		let x0 = 1e9, y0 = 1e9, x1 = -1e9, y1 = -1e9;
		const points = poly.length !== undefined && typeof poly[0]?.x === "number" ? poly : null;
		if (points) {
			for (let j = 0; j < points.length; j += 1) {
				x0 = Math.min(x0, points[j].x);
				y0 = Math.min(y0, points[j].y);
				x1 = Math.max(x1, points[j].x);
				y1 = Math.max(y1, points[j].y);
			}
		} else {
			const text = "" + poly.toString();
			const pattern = /QPointF\(([-\d.e]+),\s*([-\d.e]+)\)/g;
			let m;
			while ((m = pattern.exec(text)) !== null) {
				const x = Number(m[1]), y = Number(m[2]);
				x0 = Math.min(x0, x);
				y0 = Math.min(y0, y);
				x1 = Math.max(x1, x);
				y1 = Math.max(y1, y);
			}
		}
		return x1 > x0 ? Qt.rect(x0, y0, x1 - x0, y1 - y0) : null;
	}

	// the rows with hits, for the marks along the scroll bar
	readonly property var hitRows: {
		const seen = {};
		const out = [];
		for (const h of root.hits) {
			const r = root.rowOfPage[h.index];
			if (r !== undefined && !seen[r]) {
				seen[r] = true;
				out.push(r);
			}
		}
		return out;
	}

	// ── the scroll ─────────────────────────────────────────────────────────
	Item {
		id: viewportItem

		anchors.fill: parent
	}

	Flickable {
		id: flick

		anchors.fill: parent
		visible: !root.book
		contentWidth: root.contentW
		contentHeight: root.contentH
		boundsBehavior: Flickable.StopAtBounds
		flickDeceleration: 2600
		maximumFlickVelocity: 6000
		pixelAligned: true
		clip: true
		opacity: 1
		onContentYChanged: Qt.callLater(root.afterScroll)
		onContentXChanged: settleTimer.restart()
		onHeightChanged: Qt.callLater(root.syncLive)

		ScrollBar.vertical: ThinScrollBar {}
		ScrollBar.horizontal: ThinScrollBar {}

		NumberAnimation on opacity {
			id: fadeIn

			running: false
			from: 0.25
			to: 1
			duration: Motion.long
			easing.type: Easing.OutCubic
		}

		Repeater {
			model: live

			Item {
				id: rowItem

				required property string key
				readonly property int r: root.rowIndex[rowItem.key] ?? -1
				readonly property var row: root.rows[rowItem.r] ?? null

				x: { root.tick; return rowItem.r >= 0 ? root.rowX(rowItem.r) : 0; }
				y: { root.tick; return rowItem.r >= 0 ? root.rowY[rowItem.r] : 0; }
				width: pageRow.width
				height: pageRow.height

				Behavior on y {
					enabled: root.glide
					SpatialAnim {
						duration: Motion.long
					}
				}
				Behavior on x {
					enabled: root.glide
					SpatialAnim {
						duration: Motion.long
					}
				}

				// a page added comes up gently
				opacity: 0
				scale: 0.985
				Component.onCompleted: {
					rowItem.opacity = 1;
					rowItem.scale = 1;
				}

				Behavior on opacity {
					Anim {
						duration: Motion.medium
					}
				}
				Behavior on scale {
					SpatialAnim {
						duration: Motion.long
					}
				}

				Row {
					id: pageRow

					spacing: root.gap
					layoutDirection: Qt.LeftToRight

					Repeater {
						model: rowItem.row ? rowItem.row.ids : []

						PdfPage {
							required property string modelData

							pageId: modelData
							reader: root
							k: root.k
							renderK: root.renderK
							viewport: viewportItem
							y: ((rowItem.row?.h ?? 0) * root.k - height) / 2
						}
					}
				}
			}
		}

		// the touchpad, Ctrl+wheel: closer and further at the pointer (the wheel alone scrolls)
		WheelHandler {
			target: null
			acceptedModifiers: Qt.ControlModifier
			onWheel: event => {
				const steps = event.angleDelta.y / 120;
				root.zoomAtPoint(Math.pow(1.18, steps), event.x - flick.contentX, event.y - flick.contentY);
			}
		}

		// the middle button drags the pages about
		DragHandler {
			target: null
			acceptedButtons: Qt.MiddleButton
			property real startX: 0
			property real startY: 0
			onActiveChanged: {
				startX = flick.contentX;
				startY = flick.contentY;
			}
			onTranslationChanged: {
				flick.contentX = Math.max(0, Math.min(root.contentW - flick.width, startX - translation.x));
				flick.contentY = Math.max(0, Math.min(root.contentH - flick.height, startY - translation.y));
			}
		}
	}

	PinchHandler {
		target: null
		enabled: !root.book
		property real last: 1
		onActiveChanged: {
			pinch.last = 1;
			root.smoothZoom = !active;
		}
		id: pinch
		onActiveScaleChanged: {
			const factor = pinch.activeScale / pinch.last;
			pinch.last = pinch.activeScale;
			root.zoomAtPoint(factor, pinch.centroid.position.x, pinch.centroid.position.y);
		}
	}

	// the hits along the scroll bar
	Item {
		anchors.right: parent.right
		anchors.top: parent.top
		anchors.bottom: parent.bottom
		anchors.topMargin: root.padTop
		anchors.bottomMargin: root.padBottom
		width: 6
		visible: !root.book && root.hitRows.length > 0

		Repeater {
			model: root.hitRows.length < 600 ? root.hitRows : []

			Rectangle {
				required property int modelData

				width: 6
				height: 3
				radius: 1.5
				color: root.currentHit && root.rowOfPage[root.currentHit.index] === modelData ? "#ff6d00" : Qt.alpha("#ffb300", 0.85)
				y: { root.tick; return (root.rowY[modelData] / Math.max(1, root.contentH)) * parent.height; }
			}
		}
	}

	// ── the book ───────────────────────────────────────────────────────────
	Loader {
		anchors.fill: parent
		anchors.topMargin: root.padTop
		anchors.bottomMargin: root.padBottom
		anchors.leftMargin: root.padLeft
		anchors.rightMargin: root.padRight
		active: root.book
		sourceComponent: bookView
	}

	Component {
		id: bookView

		Item {
			id: book

			// spreads: the first page alone (a cover), then pairs
			readonly property var spreads: {
				const pages = Pdf.pages;
				const out = pages.length > 0 ? [[pages[0].id]] : [];
				for (let i = 1; i < pages.length; i += 2) out.push(i + 1 < pages.length ? [pages[i].id, pages[i + 1].id] : [pages[i].id]);
				return out;
			}
			readonly property int spread: Pdf.page <= 0 ? 0 : Math.floor((Pdf.page + 1) / 2)
			property int shown: book.spread
			// the leaf in hand or turning: 1 a right one on, -1 a left one back, 0 none
			property int turning: 0
			readonly property int to: book.shown + book.turning
			// idle, peel (the pointer at its free edge), drag (held), settle (going over or back)
			property string phase: "idle"
			// in the leaf's space (u from the spine, v down from its top): the grabbed
			// point of its free edge (a corner, or the edge where it was taken), where
			// that point is now, and where it is drawn to
			property real cy: 0
			property point m: Qt.point(0, 0)
			property point aim: Qt.point(0, 0)
			// settling: from where, over or back, how far along
			property point settleFrom: Qt.point(0, 0)
			property bool settleOver: false
			property real p: 0
			// the pointer while held: whether it moved, how fast toward the spine (px/ms)
			property bool pressedLeaf: false
			property point pressAt: Qt.point(0, 0)
			property real lastU: 0
			property real lastT: 0
			property real speed: 0
			// the leaf's two sides; never emptied (a page image made again for a
			// page of the same document draws its first one), the next one on
			// laid ready while the book rests
			property string frontId: ""
			property string backId: ""
			onShownChanged: book.ready(1)
			Component.onCompleted: book.ready(1)

			// the scale: the widest spread fits the window
			readonly property real bk: {
				let w = 1, h = 1;
				for (const p of Pdf.pages) {
					const s = Pdf.sizeOf(p);
					w = Math.max(w, s.width);
					h = Math.max(h, s.height);
				}
				return Math.max(0.05, Math.min((book.width - 80) / (2 * w), (book.height - 40) / h));
			}

			// where the spine is, how big the leaf, where its top
			readonly property real spineX: book.width / 2
			readonly property real leafW: leafFront.width
			readonly property real leafH: leafFront.height
			readonly property real leafTop: (book.height - book.leafH) / 2

			// the roll, from where the grabbed point is: the axis (a point, its normal
			// toward the free edge) and the radius – wide while the leaf is in the
			// air, nothing where it lies flat; the spine edge never lifts
			readonly property var roll: {
				const W = book.leafW, H = book.leafH;
				const dx = W - book.m.x, dy = book.cy - book.m.y;
				const len = Math.hypot(dx, dy);
				if (len < 0.5) return { p: Qt.point(W + 1000, book.cy), n: Qt.point(1, 0), r: 0.5 };
				const nx = dx / len, ny = dy / len;
				const r = Math.max(0.5, Math.min(W * 0.085, len * 0.3, Math.max(0, 2 * W - len) * 0.3));
				const s = (len + Math.PI * r) / 2;
				let px = W - nx * s, py = book.cy - ny * s;
				for (const qy of [0, H]) {
					const d = -px * nx + (qy - py) * ny;
					if (d > -0.5) {
						px += nx * (d + 0.5);
						py += ny * (d + 0.5);
					}
				}
				return { p: Qt.point(px, py), n: Qt.point(nx, ny), r: r };
			}

			function ready(dir) {
				const front = book.idsOf(book.shown, dir === 1 ? "right" : "left");
				const back = book.idsOf(book.shown + dir, dir === 1 ? "left" : "right");
				if (front !== "") book.frontId = front;
				if (back !== "") book.backId = back;
			}

			function idsOf(s, side) {
				const ids = book.spreads[s] ?? [];
				if (s === 0) return side === "right" ? (ids[0] ?? "") : "";
				return side === "left" ? (ids[0] ?? "") : (ids[1] ?? "");
			}

			function canTurn(dir) {
				return dir === 1 ? book.shown + 1 < book.spreads.length && book.idsOf(book.shown, "right") !== "" : book.shown > 0;
			}

			// the free edge of a leaf under the pointer: 1 the right one's, -1 the left one's, 0 none
			function edgeAt(x, y) {
				for (const dir of [1, -1]) {
					if (book.turning !== 0 && book.turning !== dir) continue;
					if (book.turning === 0 && !book.canTurn(dir)) continue;
					const pg = book.turning === dir ? leafFront : (dir === 1 ? rightPage : leftPage);
					const u = (x - book.spineX) * dir, v = y - (book.height - pg.height) / 2;
					const hz = Math.max(36, pg.width * 0.13);
					if (u > pg.width - hz && u < pg.width + 24 && v > -24 && v < pg.height + 24) return dir;
				}
				return 0;
			}

			// the leaf hangs at the spine: what is grabbed gets no farther from either
			// end of it than it is lying flat
			function reach(u, v) {
				const W = book.leafW;
				for (const sy of [0, book.leafH]) {
					const most = Math.hypot(W, book.cy - sy), dx = u, dy = v - sy, len = Math.hypot(dx, dy);
					if (len > most) {
						u = dx * most / len;
						v = sy + dy * most / len;
					}
				}
				return Qt.point(u, v);
			}

			// near the top or the bottom a corner is taken, else the edge where the pointer is
			function grabAt(v) {
				const H = book.leafH;
				return v < H * 0.28 ? 0 : (v > H * 0.72 ? H : v);
			}

			function aimAt(x, y) {
				let u = (x - book.spineX) * book.turning;
				const v = y - book.leafTop;
				if (book.phase === "peel") {
					// hovered only, the edge just lifts toward the pointer, taken where the pointer is along it
					u = Math.min(u, book.leafW - 34);
					const cy = book.grabAt(v), shift = cy - book.cy;
					book.cy = cy;
					book.m = Qt.point(book.m.x, book.m.y + shift);
				}
				book.aim = book.reach(u, v);
			}

			function take(dir, x, y) {
				book.ready(dir);
				book.turning = dir;
				book.cy = book.grabAt(y - book.leafTop);
				book.m = Qt.point(book.leafW, book.cy);
				book.phase = "peel";
				book.aimAt(x, y);
			}

			function settle(over, duration, easing) {
				book.settleFrom = book.m;
				book.settleOver = over;
				book.phase = "settle";
				book.p = 0;
				settleAnim.duration = duration;
				settleAnim.easing.type = easing;
				settleAnim.restart();
			}

			// let the leaf go where the hand left it: over when past the middle or flung
			function release() {
				const moved = Math.hypot(book.m.x - book.pressAt.x, book.m.y - book.pressAt.y) > 6;
				const over = !moved || book.m.x < book.leafW * 0.45 || book.speed < -0.45;
				const left = over ? (book.m.x + book.leafW) / (2 * book.leafW) : (book.leafW - book.m.x) / (2 * book.leafW);
				book.settle(over, 220 + 520 * Math.max(0, Math.min(1, left)), Easing.OutCubic);
			}

			// a turn asked for elsewhere (keys, wheel, a click on a page): the lower corner goes over
			function turnOver(dir) {
				book.ready(dir);
				book.turning = dir;
				book.cy = book.leafH;
				book.m = Qt.point(book.leafW, book.cy);
				book.settle(true, Motion.extraLong + 300, Easing.InOutSine);
			}

			function done() {
				if (book.phase !== "settle") return;
				settleAnim.stop();
				const over = book.settleOver, target = book.to;
				book.turning = 0;
				book.phase = "idle";
				if (!over) return;
				book.shown = target;
				if (book.spread !== target) Pdf.page = target === 0 ? 0 : target * 2 - 1;
			}

			onPChanged: {
				if (book.phase !== "settle") return;
				const W = book.leafW, H = book.leafH, a = book.settleFrom;
				const ex = book.settleOver ? -W : W;
				// going over, a corner arcs up off its edge as it would in the hand
				const lift = !book.settleOver ? 0 : Math.sin(Math.PI * book.p) * H * 0.1 * (book.cy >= H * 0.72 ? -1 : (book.cy <= H * 0.28 ? 1 : 0));
				book.m = book.reach(a.x + (ex - a.x) * book.p, a.y + (book.cy - a.y) * book.p + lift);
			}

			onSpreadChanged: {
				if (book.spread === book.shown) return;
				const delta = book.spread - book.shown;
				// the leaf in hand goes over itself when the turn is its own
				if ((book.phase === "peel" || book.phase === "drag") && book.turning === delta) {
					book.pressedLeaf = false;
					book.settle(true, 220 + 420 * Math.max(0, Math.min(1, (book.m.x + book.leafW) / (2 * book.leafW))), Easing.InOutCubic);
					return;
				}
				if (book.phase === "settle") book.done();
				else if (book.phase !== "idle") {
					book.turning = 0;
					book.phase = "idle";
				}
				if (book.spread === book.shown) return;
				const d = book.spread - book.shown;
				if (Math.abs(d) === 1 && book.canTurn(d)) {
					book.turnOver(d);
				} else {
					book.shown = book.spread;
					bookFade.restart();
				}
			}

			NumberAnimation {
				id: settleAnim

				target: book
				property: "p"
				from: 0
				to: 1
				onFinished: book.done()
			}

			// the held or hovered corner follows the pointer softly, like paper does
			FrameAnimation {
				running: book.phase === "peel" || book.phase === "drag"
				onTriggered: {
					const a = 1 - Math.exp(-frameTime * (book.phase === "drag" ? 22 : 11));
					book.m = Qt.point(book.m.x + (book.aim.x - book.m.x) * a, book.m.y + (book.aim.y - book.m.y) * a);
				}
			}

			NumberAnimation {
				id: bookFade

				target: spreadItem
				property: "opacity"
				from: 0.2
				to: 1
				duration: Motion.long
			}

			// the leaf's two sides, drawn for the roll only
			PdfPage {
				id: leafFront

				pageId: book.frontId
				reader: root
				k: book.bk
				renderK: book.bk
				interactive: false
				shadow: false
			}

			PdfPage {
				id: leafBack

				pageId: book.backId
				reader: root
				k: book.bk
				renderK: book.bk
				interactive: false
				shadow: false
			}

			ShaderEffectSource {
				id: frontSrc

				sourceItem: leafFront
				hideSource: true
				live: book.turning !== 0
				textureSize: Qt.size(Math.ceil(leafFront.width * Screen.devicePixelRatio), Math.ceil(leafFront.height * Screen.devicePixelRatio))
				visible: false
			}

			ShaderEffectSource {
				id: backSrc

				sourceItem: leafBack
				hideSource: true
				live: book.turning !== 0
				textureSize: Qt.size(Math.ceil(leafFront.width * Screen.devicePixelRatio), Math.ceil(leafFront.height * Screen.devicePixelRatio))
				visible: false
			}

			Item {
				id: spreadItem

				anchors.fill: parent

				// the left: turning back, the one under the leaf
				PdfPage {
					id: leftPage

					anchors.right: parent.horizontalCenter
					anchors.verticalCenter: parent.verticalCenter
					pageId: book.turning === -1 ? book.idsOf(book.to, "left") : book.idsOf(book.shown, "left")
					reader: root
					k: book.bk
					renderK: book.bk
					visible: pageId !== ""
				}

				// the right: turning on, the one under the leaf
				PdfPage {
					id: rightPage

					anchors.left: parent.horizontalCenter
					anchors.verticalCenter: parent.verticalCenter
					pageId: book.turning === 1 ? book.idsOf(book.to, "right") : book.idsOf(book.shown, "right")
					reader: root
					k: book.bk
					renderK: book.bk
					visible: pageId !== ""
				}

				// the gutter: each page bending into the spine, over its whole height
				// (the leaf shader shades its sides the same, see shaders/leaf.frag)
				Rectangle {
					anchors.right: leftPage.right
					anchors.top: leftPage.top
					anchors.bottom: leftPage.bottom
					width: leftPage.width * 0.1
					visible: leftPage.visible
					gradient: Gradient {
						orientation: Gradient.Horizontal
						GradientStop {
							position: 0
							color: "transparent"
						}
						GradientStop {
							position: 0.7
							color: Qt.rgba(0, 0, 0, 0.08)
						}
						GradientStop {
							position: 1
							color: Qt.rgba(0, 0, 0, 0.22)
						}
					}
				}

				Rectangle {
					anchors.left: rightPage.left
					anchors.top: rightPage.top
					anchors.bottom: rightPage.bottom
					width: rightPage.width * 0.1
					// the cover alone has no gutter
					visible: rightPage.visible && (book.turning === 1 ? book.to : book.shown) > 0
					gradient: Gradient {
						orientation: Gradient.Horizontal
						GradientStop {
							position: 0
							color: Qt.rgba(0, 0, 0, 0.22)
						}
						GradientStop {
							position: 0.3
							color: Qt.rgba(0, 0, 0, 0.08)
						}
						GradientStop {
							position: 1
							color: "transparent"
						}
					}
				}

				// the leaf: soft paper rolled over toward where it is drawn
				ShaderEffect {
					visible: book.turning !== 0
					x: book.spineX - book.leafW - 2
					y: book.leafTop - book.leafH * 0.3
					width: 2 * book.leafW + 4
					height: book.leafH * 1.6
					property vector2d itemSize: Qt.vector2d(width, height)
					property vector2d origin: Qt.vector2d(book.spineX - x, book.leafTop - y)
					property vector2d leafSize: Qt.vector2d(book.leafW, book.leafH)
					property real dir: book.turning
					property vector2d axisP: Qt.vector2d(book.roll.p.x, book.roll.p.y)
					property vector2d axisN: Qt.vector2d(book.roll.n.x, book.roll.n.y)
					property real r: book.roll.r
					property real gutterFront: book.turning === 1 && book.shown === 0 ? 0 : 1
					property real gutterBack: book.turning === -1 && book.to === 0 ? 0 : 1
					property real shadow: Pdf.night ? 1 : 0.85
					property var front: frontSrc
					property var back: backSrc
					fragmentShader: Qt.resolvedUrl("shaders/leaf.frag.qsb")
				}
			}

			// a leaf's free edge peels toward the pointer, taken there it turns by
			// hand; a click elsewhere on a side turns that way, the wheel turns too
			MouseArea {
				anchors.fill: parent
				acceptedButtons: Qt.LeftButton
				hoverEnabled: true
				cursorShape: book.phase === "drag" ? Qt.ClosedHandCursor : (book.phase === "peel" ? Qt.OpenHandCursor : Qt.ArrowCursor)
				onPositionChanged: mouse => {
					if (book.phase === "drag") {
						book.aimAt(mouse.x, mouse.y);
						const u = (mouse.x - book.spineX) * book.turning, t = Date.now();
						const dt = Math.max(1, t - book.lastT);
						book.speed = 0.6 * book.speed + 0.4 * (u - book.lastU) / dt;
						book.lastU = u;
						book.lastT = t;
						return;
					}
					const edge = book.edgeAt(mouse.x, mouse.y);
					if (book.phase === "idle" && edge !== 0) {
						book.take(edge, mouse.x, mouse.y);
					} else if (book.phase === "settle" && !book.settleOver && edge === book.turning) {
						// back into the edge while it falls back: caught again
						settleAnim.stop();
						book.phase = "peel";
						book.aimAt(mouse.x, mouse.y);
					} else if (book.phase === "peel") {
						if (edge === book.turning) book.aimAt(mouse.x, mouse.y);
						else book.settle(false, 360, Easing.OutCubic);
					}
				}
				onExited: {
					if (book.phase === "peel") book.settle(false, 360, Easing.OutCubic);
				}
				onPressed: mouse => {
					book.pressedLeaf = false;
					if (book.phase === "idle") {
						const edge = book.edgeAt(mouse.x, mouse.y);
						if (edge !== 0) book.take(edge, mouse.x, mouse.y);
					}
					if (book.phase !== "peel") return;
					book.pressedLeaf = true;
					book.phase = "drag";
					book.aimAt(mouse.x, mouse.y);
					book.pressAt = book.aim;
					book.lastU = (mouse.x - book.spineX) * book.turning;
					book.lastT = Date.now();
					book.speed = 0;
				}
				onReleased: {
					if (book.phase === "drag") book.release();
				}
				onCanceled: {
					if (book.phase === "drag") book.settle(false, 360, Easing.OutCubic);
				}
				onClicked: mouse => {
					if (book.pressedLeaf) return;
					mouse.x > book.spineX ? root.bookStep(1) : root.bookStep(-1);
				}
				onWheel: wheel => {
					if (wheelGuard.running) return;
					wheelGuard.start();
					root.bookStep(wheel.angleDelta.y < 0 ? 1 : -1);
				}
			}

			Timer {
				id: wheelGuard

				interval: 380
			}
		}
	}

	function bookStep(delta) {
		const spread = Pdf.page <= 0 ? 0 : Math.floor((Pdf.page + 1) / 2);
		const next = Math.max(0, spread + delta);
		const index = next === 0 ? 0 : next * 2 - 1;
		if (index < Pdf.pageCount) Pdf.page = index;
	}
}
