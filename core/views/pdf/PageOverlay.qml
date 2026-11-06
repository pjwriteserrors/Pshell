pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Shapes
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "Edit.js" as Edit

// The recipe's marks of one page, over its picture, in page space × pageScale
// (PdfPage lays it on its `space`, so the crop and the turn are already
// done). Drawn like the helper writes them; while editing they are chosen,
// moved and resized here, and the pens draw new ones. A drag is shown from a
// copy kept here (`live`) and becomes one step of the recipe when let go.
// The file's form fields are live inputs here as well, in reading too.
Item {
	id: root

	property string pageId: ""
	property real pageScale: 1
	property bool editable: Pdf.editing

	readonly property real s: root.pageScale
	readonly property var page: Pdf.pageById(root.pageId)
	readonly property size base: Pdf.baseSize(root.page)
	// the part of the page shown (page space)
	readonly property var shown: root.page?.crop ?? [0, 0, root.base.width, root.base.height]
	readonly property var items: Pdf.items.filter(item => item.page === root.pageId)
	readonly property var byId: {
		const map = {};
		for (const item of root.items) map[item.id] = item;
		return map;
	}
	readonly property var selectedHere: Pdf.selected.filter(id => !!root.byId[id])
	// the file's own fields on this page
	readonly property var fields: root.page && root.page.src === "a" ? Pdf.fields.filter(f => f.page === root.page.n) : []

	// what a press does here
	readonly property bool penTool: ["annotate", "text", "redact", "forms", "sign", "stamp", "crop"].includes(Pdf.tool)
	readonly property string pen: !root.editable ? "none" : (Pdf.placing ? "place" : (Pdf.tool === "crop" ? "crop" : (root.penTool ? Pdf.draw : "select")))
	// marks on text are the reader's: it selects the words and marks them (Pdf.markSelection)
	readonly property var readerPens: ["highlight", "underline", "strike", "squiggly", "redact"]
	readonly property bool drawing: root.pen !== "none" && root.pen !== "select" && !root.readerPens.includes(root.pen)

	anchors.fill: parent

	// items changed by a drag, not yet a step: id → the item as it is shown
	property var live: ({})
	// a new item while it is drawn
	property var draft: null
	// lines it snapped to: [{ vertical, at }]
	property var guides: []

	function itemOf(id) {
		return root.live[id] ?? root.byId[id] ?? null;
	}

	function pt(x, y) {
		return [Edit.round(x / root.s), Edit.round(y / root.s)];
	}

	// ── delegates kept by id, so a change redraws, not rebuilds ────────────
	ListModel {
		id: shownModel
	}

	// removed ones fade out as copies
	property var leaving: []
	property var known: ({})
	property string knownPage: ""

	function sync() {
		const want = root.items.map(item => item.id);
		const wanted = new Set(want);
		const gone = [];
		for (let i = shownModel.count - 1; i >= 0; i -= 1) {
			const id = shownModel.get(i).iid;
			if (!wanted.has(id)) {
				shownModel.remove(i);
				if (root.knownPage === root.pageId && root.known[id]) gone.push(root.known[id]);
			}
		}
		const have = new Set();
		for (let i = 0; i < shownModel.count; i += 1) have.add(shownModel.get(i).iid);
		for (const id of want)
			if (!have.has(id)) shownModel.append({ iid: id });
		if (gone.length > 0) {
			root.leaving = root.leaving.concat(gone);
			leaveTimer.restart();
		}
		root.known = root.byId;
		root.knownPage = root.pageId;
	}

	onItemsChanged: root.sync()
	Component.onCompleted: {
		root.sync();
		if ((Pdf.meta?.forms ?? 0) > 0 && Pdf.fields.length === 0) Pdf.readOutline();
	}

	Timer {
		id: leaveTimer

		interval: Motion.medium + 60
		onTriggered: root.leaving = []
	}

	// ── the form's own fields: typed in right on the page ──────────────────
	Repeater {
		model: root.fields

		delegate: Item {
			id: field

			required property var modelData
			readonly property var f: field.modelData
			readonly property var value: Pdf.recipe.forms?.[field.f.name] ?? field.f.value
			readonly property real fontPx: Math.max(6, (field.f.size > 0 ? field.f.size : Math.min(12, field.f.rect[3] * 0.7)) * root.s)

			x: field.f.rect[0] * root.s
			y: field.f.rect[1] * root.s
			width: field.f.rect[2] * root.s
			height: field.f.rect[3] * root.s
			visible: !["button", "signature"].includes(field.f.type)

			Rectangle {
				anchors.fill: parent
				radius: 2
				color: input.activeFocus ? Qt.rgba(1, 1, 1, 0.97) : (field.f.required && !field.value ? Qt.rgba(1, 0.92, 0.9, 0.9) : Qt.rgba(0.9, 0.94, 1, 0.9))
				border.color: input.activeFocus ? Theme.primary : Qt.rgba(0.3, 0.45, 0.8, 0.35)
				border.width: input.activeFocus ? 1.5 : 1

				Behavior on color {
					ColorAnim {}
				}
			}

			// text
			TextInput {
				id: input

				anchors.fill: parent
				anchors.leftMargin: 2 * root.s
				anchors.rightMargin: 2 * root.s
				visible: field.f.type === "text" || field.f.type === ""
				enabled: !field.f.readonly
				text: String(field.value ?? "")
				color: "black"
				font.family: "Nimbus Sans"
				font.pixelSize: field.f.multiline ? Math.min(field.fontPx, 12 * root.s) : Math.min(field.fontPx, field.height * 0.8)
				verticalAlignment: field.f.multiline ? TextInput.AlignTop : TextInput.AlignVCenter
				maximumLength: field.f.maxlen > 0 ? field.f.maxlen : 32767
				clip: true
				selectByMouse: true
				onEditingFinished: if (input.text !== String(field.value ?? "")) Pdf.setForm(field.f.name, input.text)
				Keys.onTabPressed: event => {
					input.editingFinished();
					event.accepted = false;
				}
			}

			// a box to tick
			MouseArea {
				anchors.fill: parent
				visible: field.f.type === "check" || field.f.type === "radio"
				enabled: !field.f.readonly
				cursorShape: Qt.PointingHandCursor
				onClicked: {
					if (field.f.type === "check") Pdf.setForm(field.f.name, !field.value);
					else Pdf.setForm(field.f.name, field.f.on);
				}
			}

			Glyph {
				anchors.centerIn: parent
				visible: field.f.type === "check" ? !!field.value : (field.f.type === "radio" && String(field.value) === String(field.f.on))
				icon: field.f.type === "radio" ? "circle" : "check_bold"
				size: Math.min(field.width, field.height) * (field.f.type === "radio" ? 0.5 : 0.85)
				color: "black"
				surface: "transparent"
			}

			// one of a list
			StyledText {
				anchors.fill: parent
				anchors.leftMargin: 3
				visible: field.f.type === "choice"
				text: String(field.value || "Choose…")
				color: "black"
				font.pixelSize: Math.min(field.fontPx, field.height * 0.8)
				verticalAlignment: Text.AlignVCenter
				elide: Text.ElideRight
			}

			MouseArea {
				anchors.fill: parent
				visible: field.f.type === "choice"
				enabled: !field.f.readonly
				cursorShape: Qt.PointingHandCursor
				onClicked: choices.visible = !choices.visible
			}

			Rectangle {
				id: choices

				visible: false
				y: field.height + 2
				z: 10
				width: Math.max(field.width, 140)
				height: Math.min(220, choiceColumn.implicitHeight + 8)
				radius: Theme.radius.small
				color: Theme.layer1
				border.color: Theme.outline
				clip: true

				Flickable {
					anchors.fill: parent
					anchors.margins: 4
					contentHeight: choiceColumn.implicitHeight

					Column {
						id: choiceColumn

						width: parent.width

						Repeater {
							model: field.f.options ?? []

							delegate: Clickable {
								id: choice

								required property var modelData

								width: choiceColumn.width
								height: 26
								radius: Theme.radius.small
								color: String(field.value) === String(choice.modelData) ? Theme.primarySoft : "transparent"
								onClicked: {
									Pdf.setForm(field.f.name, String(choice.modelData));
									choices.visible = false;
								}

								StyledText {
									anchors.verticalCenter: parent.verticalCenter
									x: 8
									text: String(choice.modelData)
								}
							}
						}
					}
				}
			}
		}
	}

	// ── the marks ──────────────────────────────────────────────────────────
	Repeater {
		model: shownModel

		delegate: EditItem {
			id: mark

			required property string iid

			item: root.itemOf(mark.iid) ?? ({})
			s: root.s
			editable: root.editable
			selected: Pdf.selected.includes(mark.iid)
			typing: Pdf.editingText === mark.iid
		}
	}

	Repeater {
		model: root.leaving

		delegate: EditItem {
			required property var modelData

			item: modelData
			s: root.s
			ghost: true
		}
	}

	// the one being drawn
	EditItem {
		visible: !!root.draft
		item: root.draft ?? ({})
		s: root.s
		editable: true
	}

	// ── hits of a search to black out: dashed until applied, a click leaves one out ──
	Repeater {
		model: Pdf.redactHits.map((hit, i) => Object.assign({ index: i }, hit)).filter(hit => hit.page === root.pageId)

		delegate: Repeater {
			id: hitGroup

			required property var modelData

			model: hitGroup.modelData.rects

			delegate: Rectangle {
				id: hitBox

				required property var modelData

				x: hitBox.modelData[0] * root.s - 1
				y: hitBox.modelData[1] * root.s - 1
				width: hitBox.modelData[2] * root.s + 2
				height: hitBox.modelData[3] * root.s + 2
				radius: 2
				color: hitGroup.modelData.on !== false ? Qt.rgba(0, 0, 0, 0.72) : Qt.rgba(0.9, 0.2, 0.2, 0.12)
				border.color: hitGroup.modelData.on !== false ? "black" : "#e53935"
				border.width: 1

				Behavior on color {
					ColorAnim {}
				}

				MouseArea {
					anchors.fill: parent
					cursorShape: Qt.PointingHandCursor
					onClicked: {
						const next = Pdf.redactHits.slice();
						const i = hitGroup.modelData.index;
						next[i] = Object.assign({}, next[i], { on: next[i].on === false });
						Pdf.redactHits = next;
					}
				}
			}
		}
	}

	// ── choosing and moving ────────────────────────────────────────────────
	// where a move started and what it moves
	property var moveFrom: null
	property var moveStart: null
	property bool moved: false

	function others(ids) {
		return root.items.filter(item => !ids.includes(item.id)).map(item => Pdf.boundsOf(item));
	}

	function beginMove(id, p, shift) {
		if (shift) {
			Pdf.selected = Pdf.selected.includes(id) ? Pdf.selected.filter(x => x !== id) : Pdf.selected.concat([id]);
		} else if (!Pdf.selected.includes(id)) Pdf.selected = [id];
		root.moveFrom = p;
		root.moved = false;
		const start = {};
		for (const sid of root.selectedHere.concat(Pdf.selected.includes(id) ? [] : [])) if (root.byId[sid]) start[sid] = root.byId[sid];
		root.moveStart = start;
	}

	function moveTo(p, free) {
		if (!root.moveFrom || !root.moveStart) return;
		let dx = p[0] - root.moveFrom[0], dy = p[1] - root.moveFrom[1];
		if (!root.moved && Math.hypot(dx, dy) * root.s < 3) return;
		root.moved = true;
		const ids = Object.keys(root.moveStart);
		if (ids.length === 0) return;
		// held to the page's edges and middle and to the other marks
		const boxes = ids.map(id => Pdf.boundsOf(root.moveStart[id]));
		const x0 = Math.min(...boxes.map(b => b[0])), y0 = Math.min(...boxes.map(b => b[1]));
		const x1 = Math.max(...boxes.map(b => b[0] + b[2])), y1 = Math.max(...boxes.map(b => b[1] + b[3]));
		if (!free) {
			const snapped = Edit.snapMove([x0, y0, x1 - x0, y1 - y0], dx, dy, root.shown, root.others(ids), 5 / root.s);
			dx = snapped.dx;
			dy = snapped.dy;
			root.guides = snapped.guides;
		} else root.guides = [];
		const next = {};
		for (const id of ids) {
			const copy = Edit.copy(root.moveStart[id]);
			Pdf.shiftItem(copy, Edit.round(dx), Edit.round(dy));
			next[id] = copy;
		}
		root.live = next;
	}

	// the shown copies become one step
	function endMove(label) {
		const ids = Object.keys(root.live);
		root.moveFrom = null;
		root.moveStart = null;
		root.guides = [];
		if (ids.length === 0) return;
		const next = Pdf.clone(Pdf.recipe);
		next.items = next.items.map(item => root.live[item.id] ? Edit.copy(root.live[item.id]) : item);
		root.live = {};
		Pdf.commit(next, label || (ids.length === 1 ? "Moved" : `${ids.length} moved`));
	}

	// a handle: "tl" … "l" for a box, "p0" / "p1" for a line's ends
	property var resizing: null

	function beginResize(id, handle, p) {
		root.resizing = { id: id, handle: handle, from: p, item: root.byId[id], box: Pdf.boundsOf(root.byId[id]) };
	}

	function resizeTo(p, shift) {
		const r = root.resizing;
		if (!r) return;
		let changed;
		if (r.handle === "p0" || r.handle === "p1") {
			changed = Edit.copy(r.item);
			const i = r.handle === "p0" ? 0 : 1;
			let to = p;
			if (shift) to = Edit.snapAngle(changed.points[1 - i], p);
			changed.points[i] = [Edit.round(to[0]), Edit.round(to[1])];
		} else {
			const keep = ["image", "signature"].includes(r.item.kind) || (r.item.kind === "stamp" && !!r.item.image) ? !shift : shift;
			const box = Edit.resize(r.box, r.handle, p[0] - r.from[0], p[1] - r.from[1], keep);
			changed = Edit.refit(r.item, r.box, box);
			// words keep their size when their box changes
			if (changed.kind === "textbox" || changed.kind === "text") changed.size = r.item.size;
		}
		root.live = { [r.id]: changed };
	}

	function endResize() {
		root.resizing = null;
		root.endMove("Resized");
	}

	// a click on a mark
	Repeater {
		model: shownModel

		delegate: MouseArea {
			id: hit

			required property string iid
			readonly property var item: root.itemOf(hit.iid) ?? ({})
			readonly property var box: Pdf.boundsOf(hit.item)
			readonly property real pad: 4

			x: hit.box[0] * root.s - hit.pad
			y: hit.box[1] * root.s - hit.pad
			width: Math.max(10, hit.box[2] * root.s + hit.pad * 2)
			height: Math.max(10, hit.box[3] * root.s + hit.pad * 2)
			// reading: notes unfold, links lead
			enabled: root.pen === "select" || (!root.editable && ["note", "link"].includes(hit.item.kind))
			hoverEnabled: true
			cursorShape: root.editable ? (Pdf.selected.includes(hit.iid) ? Qt.SizeAllCursor : Qt.PointingHandCursor) : Qt.PointingHandCursor
			acceptedButtons: Qt.LeftButton

			function at(mouse) {
				return root.pt(hit.x + mouse.x, hit.y + mouse.y);
			}

			onPressed: mouse => {
				if (!root.editable) return;
				root.beginMove(hit.iid, hit.at(mouse), (mouse.modifiers & Qt.ShiftModifier) !== 0);
			}
			onPositionChanged: mouse => {
				if (hit.pressed && root.editable) root.moveTo(hit.at(mouse), (mouse.modifiers & Qt.AltModifier) !== 0);
			}
			onReleased: {
				if (root.editable) root.endMove();
			}
			onClicked: {
				if (root.editable) return;
				if (hit.item.kind === "link") {
					if (hit.item.url) Qt.openUrlExternally(hit.item.url);
					else if (hit.item.target) Pdf.goTo(Pdf.indexOf(hit.item.target), hit.item.y ?? -1);
				} else Pdf.selected = Pdf.selected.includes(hit.iid) ? [] : [hit.iid];
			}
			onDoubleClicked: {
				if (root.editable && ["textbox", "text", "note", "link", "field"].includes(hit.item.kind)) Pdf.editingText = hit.iid;
			}
		}
	}

	// ── what is chosen: a frame, handles when it is one ────────────────────
	Repeater {
		model: root.editable ? root.selectedHere : []

		delegate: Item {
			id: frame

			required property string modelData
			readonly property var item: root.itemOf(frame.modelData) ?? ({})
			readonly property var box: Pdf.boundsOf(frame.item)
			readonly property bool single: root.selectedHere.length === 1 && Pdf.editingText !== frame.modelData
			readonly property bool line: frame.item.kind === "line" || frame.item.kind === "arrow"
			readonly property bool sizable: frame.single && !frame.line && (Edit.isBoxed(frame.item) || frame.item.kind === "ink")

			x: frame.box[0] * root.s - 3
			y: frame.box[1] * root.s - 3
			width: frame.box[2] * root.s + 6
			height: frame.box[3] * root.s + 6

			Rectangle {
				anchors.fill: parent
				visible: !frame.line
				color: "transparent"
				radius: 3
				border.color: Theme.primary
				border.width: 1.5
				opacity: 0.9
			}

			Repeater {
				model: frame.sizable ? ["tl", "t", "tr", "r", "br", "b", "bl", "l"] : (frame.single && frame.line ? ["p0", "p1"] : [])

				delegate: Rectangle {
					id: handle

					required property string modelData
					readonly property var at: {
						const h = handle.modelData;
						if (h === "p0" || h === "p1") {
							const p = frame.item.points?.[h === "p0" ? 0 : 1] ?? [0, 0];
							return [p[0] * root.s - frame.x, p[1] * root.s - frame.y];
						}
						const fx = h.includes("l") ? 0 : (h.includes("r") ? frame.width : frame.width / 2);
						const fy = h.includes("t") ? 0 : (h.includes("b") ? frame.height : frame.height / 2);
						return [fx, fy];
					}

					x: handle.at[0] - width / 2
					y: handle.at[1] - height / 2
					width: handleMouse.containsMouse || handleMouse.pressed ? 13 : 10
					height: width
					radius: handle.modelData.length === 1 ? 3 : width / 2
					color: "white"
					border.color: Theme.primary
					border.width: 2

					Behavior on width {
						Anim {
							duration: Motion.micro
						}
					}

					MouseArea {
						id: handleMouse

						anchors.fill: parent
						anchors.margins: -5
						hoverEnabled: true
						preventStealing: true
						cursorShape: {
							const h = handle.modelData;
							if (h === "t" || h === "b") return Qt.SizeVerCursor;
							if (h === "l" || h === "r") return Qt.SizeHorCursor;
							if (h === "tl" || h === "br") return Qt.SizeFDiagCursor;
							if (h === "tr" || h === "bl") return Qt.SizeBDiagCursor;
							return Qt.CrossCursor;
						}

						function at(mouse) {
							const q = handleMouse.mapToItem(root, mouse.x, mouse.y);
							return root.pt(q.x, q.y);
						}

						onPressed: mouse => root.beginResize(frame.modelData, handle.modelData, handleMouse.at(mouse))
						onPositionChanged: mouse => {
							if (handleMouse.pressed) root.resizeTo(handleMouse.at(mouse), (mouse.modifiers & Qt.ShiftModifier) !== 0);
						}
						onReleased: root.endResize()
					}
				}
			}
		}
	}

	// ── the box of a crop ──────────────────────────────────────────────────
	Item {
		id: cropView

		readonly property var box: Pdf.cropDraft[root.pageId] ?? null

		anchors.fill: parent
		visible: root.pen === "crop" && !!cropView.box

		// the part that goes, darker
		Rectangle {
			x: 0
			y: 0
			width: parent.width
			height: (cropView.box?.[1] ?? 0) * root.s
			color: Qt.rgba(0, 0, 0, 0.45)
		}

		Rectangle {
			x: 0
			y: ((cropView.box?.[1] ?? 0) + (cropView.box?.[3] ?? 0)) * root.s
			width: parent.width
			height: Math.max(0, parent.height - y)
			color: Qt.rgba(0, 0, 0, 0.45)
		}

		Rectangle {
			x: 0
			y: (cropView.box?.[1] ?? 0) * root.s
			width: (cropView.box?.[0] ?? 0) * root.s
			height: (cropView.box?.[3] ?? 0) * root.s
			color: Qt.rgba(0, 0, 0, 0.45)
		}

		Rectangle {
			x: ((cropView.box?.[0] ?? 0) + (cropView.box?.[2] ?? 0)) * root.s
			y: (cropView.box?.[1] ?? 0) * root.s
			width: Math.max(0, parent.width - x)
			height: (cropView.box?.[3] ?? 0) * root.s
			color: Qt.rgba(0, 0, 0, 0.45)
		}

		Rectangle {
			x: (cropView.box?.[0] ?? 0) * root.s
			y: (cropView.box?.[1] ?? 0) * root.s
			width: (cropView.box?.[2] ?? 0) * root.s
			height: (cropView.box?.[3] ?? 0) * root.s
			color: "transparent"
			border.color: "white"
			border.width: 2

			// thirds
			Repeater {
				model: 2

				Rectangle {
					required property int index

					x: parent.width * (index + 1) / 3
					width: 1
					height: parent.height
					color: Qt.rgba(1, 1, 1, 0.35)
				}
			}

			Repeater {
				model: 2

				Rectangle {
					required property int index

					y: parent.height * (index + 1) / 3
					height: 1
					width: parent.width
					color: Qt.rgba(1, 1, 1, 0.35)
				}
			}

			Repeater {
				model: ["tl", "tr", "br", "bl", "t", "r", "b", "l"]

				delegate: Rectangle {
					id: cropHandle

					required property string modelData
					readonly property real fx: cropHandle.modelData.includes("l") ? 0 : (cropHandle.modelData.includes("r") ? 1 : 0.5)
					readonly property real fy: cropHandle.modelData.includes("t") ? 0 : (cropHandle.modelData.includes("b") ? 1 : 0.5)

					x: parent.width * cropHandle.fx - width / 2
					y: parent.height * cropHandle.fy - height / 2
					width: cropHandle.modelData.length === 2 ? 14 : 10
					height: width
					radius: 3
					color: "white"

					MouseArea {
						anchors.fill: parent
						anchors.margins: -6
						preventStealing: true
						cursorShape: Qt.CrossCursor

						property var from: null
						property var start: null

						onPressed: mouse => {
							const q = mapToItem(root, mouse.x, mouse.y);
							from = root.pt(q.x, q.y);
							start = cropView.box.slice();
						}
						onPositionChanged: mouse => {
							if (!pressed || !start) return;
							const q = mapToItem(root, mouse.x, mouse.y);
							const p = root.pt(q.x, q.y);
							root.setCrop(Edit.resize(start, cropHandle.modelData, p[0] - from[0], p[1] - from[1], (mouse.modifiers & Qt.ShiftModifier) !== 0));
						}
					}
				}
			}
		}
	}

	function setCrop(box) {
		const b = [Math.max(0, box[0]), Math.max(0, box[1]), 0, 0];
		b[2] = Math.min(root.base.width - b[0], box[2]);
		b[3] = Math.min(root.base.height - b[1], box[3]);
		Pdf.cropDraft = Object.assign({}, Pdf.cropDraft, { [root.pageId]: Edit.roundRect(b) });
	}

	// ── the pens ───────────────────────────────────────────────────────────
	property var pressAt: null
	property var stroke: []
	property var erased: []
	property var words: null

	function styled(kind) {
		const st = Pdf.style || {};
		const color = st.color || "#ffd54f";
		switch (kind) {
		case "marker":
			return { color: color, width: Math.max(6, (st.width || 2) * 5), opacity: Math.min(st.opacity ?? 0.4, 0.6) };
		case "pen":
			return { color: color, width: st.width || 2, opacity: st.opacity ?? 1 };
		default:
			return { color: color, width: st.width || 2, opacity: st.opacity ?? 1, fill: st.fill || "" };
		}
	}

	// words chosen by a drag here (the reader's pens do the same through its selection)
	readonly property var textPens: ["redact-text"]

	function flowDraft(a, b) {
		return root.flowDraftFor(root.pen, a, b);
	}

	function flowDraftFor(pen, a, b) {
		const kind = pen === "redact-text" ? "redact" : pen;
		const st = root.styled(kind);
		const picked = root.words ? Edit.flowSelect(root.words.words, a, b) : null;
		const quads = picked ? picked.quads : [Edit.rectOf(a, b, false)];
		const base = { kind: kind, page: root.pageId, quads: quads, text: picked?.text ?? "" };
		if (kind === "redact") return base;
		return Object.assign(base, { color: st.color, opacity: kind === "highlight" ? Math.min(0.8, Pdf.style?.opacity ?? 0.45) : (Pdf.style?.opacity ?? 1) });
	}

	function boxDraft(kind, a, b, square) {
		const r = Edit.roundRect(Edit.rectOf(a, b, square));
		const st = root.styled(kind);
		switch (kind) {
		case "rect":
		case "ellipse":
			return { kind: kind, page: root.pageId, rect: r, color: st.color, width: st.width, fill: st.fill, opacity: st.opacity };
		case "whiteout":
			return { kind: "whiteout", page: root.pageId, rect: r, color: Pdf.style?.coverColor || "#ffffff" };
		case "redact-box":
			return { kind: "redact", page: root.pageId, rect: r };
		case "link":
			return { kind: "link", page: root.pageId, rect: r, url: "" };
		case "field":
			return { kind: "field", page: root.pageId, rect: r, type: Pdf.fieldType, name: "", options: [], value: "" };
		case "textbox":
			return { kind: "textbox", page: root.pageId, rect: r, text: "", size: Pdf.style?.size || 12, color: Pdf.style?.color || "#000000", fill: Pdf.style?.fill || "", font: Pdf.style?.font || "Helvetica", align: Pdf.style?.align || "left" };
		}
		return null;
	}

	function press(p, mouse) {
		root.pressAt = p;
		Pdf.selected = [];
		const square = (mouse.modifiers & Qt.ShiftModifier) !== 0;
		switch (root.pen) {
		case "pen":
		case "marker":
			root.stroke = [p];
			root.draft = Object.assign({ kind: "ink", page: root.pageId, strokes: [[p]] }, root.styled(root.pen));
			break;
		case "eraser":
			root.erased = [];
			root.eraseAt(p);
			break;
		case "line":
		case "arrow": {
			const st = root.styled(root.pen);
			root.draft = { kind: root.pen, page: root.pageId, points: [p, p], color: st.color, width: st.width, opacity: st.opacity };
			break;
		}
		case "crop":
			root.setCrop([p[0], p[1], 1, 1]);
			break;
		default:
			if (root.textPens.includes(root.pen)) {
				Pdf.wordsOf(root.pageId, found => {
					root.words = found;
					if (root.pressAt && root.draft) root.draft = root.flowDraft(root.pressAt, root.draftEnd);
				});
				root.draftEnd = p;
				root.draft = root.flowDraft(p, p);
			}
		}
	}

	property var draftEnd: null

	function drag(p, mouse) {
		if (!root.pressAt) return;
		const square = (mouse.modifiers & Qt.ShiftModifier) !== 0;
		switch (root.pen) {
		case "pen":
		case "marker": {
			const last = root.stroke[root.stroke.length - 1];
			if (Math.hypot(p[0] - last[0], p[1] - last[1]) * root.s < 1.5) return;
			// a little behind the pointer: the hand's shake goes
			const q = [Edit.round(last[0] + (p[0] - last[0]) * 0.6), Edit.round(last[1] + (p[1] - last[1]) * 0.6)];
			root.stroke.push(q);
			root.draft = Object.assign({}, root.draft, { strokes: [root.stroke.slice()] });
			break;
		}
		case "eraser":
			root.eraseAt(p);
			break;
		case "line":
		case "arrow":
			root.draft = Object.assign({}, root.draft, { points: [root.pressAt, square ? Edit.snapAngle(root.pressAt, p) : p] });
			break;
		case "crop":
			root.setCrop(Edit.rectOf(root.pressAt, p, square));
			break;
		case "rect":
		case "ellipse":
		case "whiteout":
		case "redact-box":
		case "link":
		case "field":
		case "textbox":
			root.draft = root.boxDraft(root.pen, root.pressAt, p, square);
			break;
		default:
			if (root.textPens.includes(root.pen)) {
				root.draftEnd = p;
				root.draft = root.flowDraft(root.pressAt, p);
			}
		}
	}

	function release(p, mouse) {
		const from = root.pressAt;
		root.pressAt = null;
		if (!from) return;
		const tiny = Math.hypot(p[0] - from[0], p[1] - from[1]) * root.s < 4;
		const draft = root.draft;
		root.draft = null;
		switch (root.pen) {
		case "pen":
		case "marker": {
			root.stroke.push(p);
			const points = Edit.smooth(Edit.simplify(root.stroke, 0.35 / Math.max(0.3, root.s / 1.33)));
			root.stroke = [];
			Pdf.addItem(Object.assign({}, draft, { strokes: [points] }), root.pen === "marker" ? "Marked by hand" : "Drawn");
			Pdf.selected = [];
			return;
		}
		case "eraser":
			if (root.erased.length > 0) Pdf.removeItems(root.erased);
			root.erased = [];
			root.live = {};
			return;
		case "line":
		case "arrow":
			if (!tiny) Pdf.addItem(draft);
			return;
		case "crop":
			if (tiny) Pdf.cropDraft = Object.assign({}, Pdf.cropDraft, { [root.pageId]: [root.shown[0], root.shown[1], root.shown[2], root.shown[3]] });
			return;
		case "note": {
			const id = Pdf.addItem({ kind: "note", page: root.pageId, at: [Edit.round(p[0] - 10), Edit.round(p[1] - 10)], text: "", color: Pdf.style?.color || "#ffd54f" });
			Pdf.editingText = id;
			return;
		}
		case "text":
			root.correctAt(p);
			return;
		case "place":
			Pdf.placeAt(root.pageId, p[0], p[1]);
			return;
		case "textbox":
		case "field":
		case "link": {
			let item = draft;
			if (tiny || !item) {
				const size = root.pen === "textbox" ? [180, 28] : (root.pen === "field" ? (Pdf.fieldType === "check" ? [14, 14] : [160, 20]) : [120, 16]);
				item = root.boxDraft(root.pen, p, [p[0] + size[0], p[1] + size[1]], false);
			}
			if (item.kind === "field") item.name = root.freeFieldName();
			const id = Pdf.addItem(item);
			if (item.kind !== "field" || item.type === "choice") Pdf.editingText = id;
			return;
		}
		default:
			if (root.textPens.includes(root.pen)) {
				// the words may still be on their way: the mark is made when they are here
				const pen = root.pen;
				Pdf.wordsOf(root.pageId, found => {
					root.words = found;
					const made = root.flowDraftFor(pen, from, p);
					if (tiny && !made.text) return;
					Pdf.addItem(made);
				});
				return;
			}
			if (!draft || tiny) return;
			Pdf.addItem(draft);
		}
	}

	function freeFieldName() {
		const taken = new Set(Pdf.fields.map(f => f.name).concat(Pdf.items.filter(i => i.kind === "field").map(i => i.name)));
		let n = 1;
		while (taken.has(`Field ${n}`)) n += 1;
		return `Field ${n}`;
	}

	// the eraser: ink and lines it touches go (hidden at once, removed when let go)
	function eraseAt(p) {
		const r = Math.max(3, (Pdf.style?.width || 2) * 2) / Math.max(0.5, root.s) * 1.2 + 2;
		const hidden = Object.assign({}, root.live);
		for (const item of root.items) {
			if (root.erased.includes(item.id)) continue;
			let hitIt = false;
			if (item.kind === "ink") hitIt = item.strokes.some(st => Edit.touchesStroke(st, p, r + (item.width || 2) / 2));
			else if (item.kind === "line" || item.kind === "arrow") hitIt = Edit.distToSegment(p, item.points[0], item.points[1]) <= r;
			else if (["rect", "ellipse", "highlight", "underline", "strike", "squiggly"].includes(item.kind)) hitIt = Edit.inside(Pdf.boundsOf(item), p, 1);
			if (hitIt) {
				root.erased = root.erased.concat([item.id]);
				hidden[item.id] = Object.assign({}, item, { opacity: 0.08 });
			}
		}
		root.live = hidden;
	}

	// the words under a click become a correction: covered and written anew
	function correctAt(p) {
		const pg = root.page;
		if (!pg || pg.blank || pg.image) {
			const id = Pdf.addItem({ kind: "text", page: root.pageId, rect: [p[0], p[1] - 8, 160, 16], text: "", size: 12, color: "#000000", font: "Helvetica", cover: null, coverColor: "#ffffff" });
			Pdf.editingText = id;
			return;
		}
		Pdf.request("textat", { path: Pdf.sourcePath(pg.src), page: pg.n, rect: [p[0] - 1, p[1] - 1, 2, 2], password: Pdf.recipe.sources[pg.src]?.password || "" }, data => {
			if (!data || !data.text) {
				const id = Pdf.addItem({ kind: "text", page: root.pageId, rect: [p[0], p[1] - 8, 160, 16], text: "", size: data?.size || 12, color: "#000000", font: "Helvetica", cover: null, coverColor: data?.background || "#ffffff" });
				Pdf.editingText = id;
				return;
			}
			const r = data.rect;
			const cover = [Edit.round(r[0] - 1), Edit.round(r[1] - 1), Edit.round(r[2] + 2), Edit.round(r[3] + 2)];
			const id = Pdf.addItem({ kind: "text", page: root.pageId, rect: [r[0], r[1], Edit.round(Math.max(r[2], 20)), r[3]], text: data.text, size: data.size || 11,
				color: data.color || "#000000", font: data.font || "Helvetica", bold: !!data.bold, italic: !!data.italic, cover: cover, coverColor: data.background || "#ffffff", was: data.text }, "Text changed");
			Pdf.editingText = id;
		});
	}

	MouseArea {
		id: drawArea

		anchors.fill: parent
		enabled: root.drawing
		hoverEnabled: root.pen === "place"
		preventStealing: true
		cursorShape: root.pen === "text" ? Qt.IBeamCursor : (root.pen === "place" ? Qt.PointingHandCursor : (root.pen === "eraser" ? Qt.ForbiddenCursor : Qt.CrossCursor))
		onPressed: mouse => root.press(root.pt(mouse.x, mouse.y), mouse)
		onPositionChanged: mouse => {
			if (drawArea.pressed) root.drag(root.pt(mouse.x, mouse.y), mouse);
			root.hoverAt = root.pt(mouse.x, mouse.y);
		}
		onReleased: mouse => root.release(root.pt(mouse.x, mouse.y), mouse)
		onExited: root.hoverAt = null
	}

	// clicking beside the marks lets them go (the text below still selects)
	TapHandler {
		enabled: root.editable && root.pen === "select" && Pdf.selected.length > 0
		gesturePolicy: TapHandler.DragThreshold
		grabPermissions: PointerHandler.ApprovesTakeOverByAnything
		onTapped: {
			if (!root.moved) Pdf.selected = [];
		}
	}

	// what will be put down, under the pointer
	property var hoverAt: null

	EditItem {
		visible: root.pen === "place" && !!root.hoverAt && !!Pdf.placing
		opacity: 0.6
		s: root.s
		item: {
			const what = Pdf.placing, at = root.hoverAt;
			if (!what || !at) return ({});
			const w = what.w || 160, h = what.h || 60;
			const rect = [at[0] - w / 2, at[1] - h / 2, w, h];
			if (what.kind === "stamp") return what.image ? { kind: "stamp", rect: rect, image: what.image } : { kind: "stamp", rect: rect, label: what.label, color: what.color, date: !!what.date };
			return { kind: what.kind === "signature" ? "signature" : "image", rect: rect, path: what.image };
		}
	}

	// ── lines it snapped to ────────────────────────────────────────────────
	Repeater {
		model: root.guides

		delegate: Rectangle {
			required property var modelData

			x: modelData.vertical ? modelData.at * root.s : 0
			y: modelData.vertical ? 0 : modelData.at * root.s
			width: modelData.vertical ? 1 : root.width
			height: modelData.vertical ? root.height : 1
			color: "#ff4081"
			opacity: 0.85
		}
	}

	// ── typing on the page ─────────────────────────────────────────────────
	Loader {
		id: typer

		readonly property var item: Pdf.editingText !== "" ? root.byId[Pdf.editingText] ?? null : null

		active: !!typer.item
		z: 20
		sourceComponent: ["textbox", "text"].includes(typer.item?.kind) ? boxTyper : (typer.item?.kind === "note" ? noteTyper : fieldTyper)
	}

	// words in their box, in the font and size they will have
	Component {
		id: boxTyper

		Item {
			id: boxEdit

			readonly property var item: typer.item
			readonly property var box: item.rect

			x: boxEdit.box[0] * root.s
			y: boxEdit.box[1] * root.s
			width: boxEdit.box[2] * root.s
			height: Math.max(boxEdit.box[3] * root.s, area.contentHeight + 4)

			function done() {
				if (Pdf.editingText !== boxEdit.item.id) return;
				Pdf.editingText = "";
				const text = area.text;
				if (text === (boxEdit.item.text ?? "")) {
					if (text === "" && boxEdit.item.kind === "textbox") Pdf.removeItems([boxEdit.item.id]);
					return;
				}
				const changes = { text: text };
				// a text box grows down with its words
				if (boxEdit.item.kind === "textbox") changes.rect = [boxEdit.box[0], boxEdit.box[1], boxEdit.box[2], Math.max(boxEdit.box[3], Edit.round((area.contentHeight + 6) / root.s))];
				else changes.rect = [boxEdit.box[0], boxEdit.box[1], Math.max(boxEdit.box[2], Edit.round((area.contentWidth + 4) / root.s)), boxEdit.box[3]];
				Pdf.updateItem(boxEdit.item.id, changes, "Text written");
			}

			Rectangle {
				anchors.fill: parent
				anchors.margins: -3
				color: boxEdit.item.kind === "text" ? (boxEdit.item.coverColor || "white") : (boxEdit.item.fill || Qt.rgba(1, 1, 1, 0.6))
				border.color: Theme.primary
				border.width: 1.5
				radius: 2
			}

			TextEdit {
				id: area

				anchors.fill: parent
				anchors.margins: boxEdit.item.kind === "textbox" ? 2 * root.s : 0
				text: boxEdit.item.text ?? ""
				color: boxEdit.item.color || "black"
				font.family: Edit.family(boxEdit.item.font)
				font.pixelSize: Math.max(1, (boxEdit.item.size ?? 12) * root.s)
				font.bold: !!boxEdit.item.bold
				font.italic: !!boxEdit.item.italic
				wrapMode: boxEdit.item.kind === "textbox" ? TextEdit.Wrap : TextEdit.NoWrap
				selectByMouse: true
				persistentSelection: true
				Component.onCompleted: {
					area.forceActiveFocus();
					area.selectAll();
				}
				onActiveFocusChanged: if (!area.activeFocus) boxEdit.done()
				Keys.onPressed: event => {
					if (event.key === Qt.Key_Escape || ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && (boxEdit.item.kind === "text" || (event.modifiers & Qt.ControlModifier)))) {
						event.accepted = true;
						boxEdit.done();
					}
				}
			}
		}
	}

	// a note's words, in its bubble
	Component {
		id: noteTyper

		Rectangle {
			id: noteEdit

			readonly property var item: typer.item

			x: ((noteEdit.item.at?.[0] ?? 0) + 24) * root.s
			y: (noteEdit.item.at?.[1] ?? 0) * root.s
			width: 240
			height: noteArea.implicitHeight + 40
			radius: Theme.radius.small
			color: "#fff8d6"
			border.color: "#e0c860"
			scale: 0.9
			opacity: 0
			Component.onCompleted: {
				noteEdit.scale = 1;
				noteEdit.opacity = 1;
			}

			Behavior on scale {
				SpatialAnim {}
			}

			Behavior on opacity {
				Anim {}
			}

			function done() {
				if (Pdf.editingText !== noteEdit.item.id) return;
				Pdf.editingText = "";
				if (noteArea.text !== (noteEdit.item.text ?? "")) Pdf.updateItem(noteEdit.item.id, { text: noteArea.text }, "Note written");
			}

			TextEdit {
				id: noteArea

				x: 10
				y: 8
				width: parent.width - 20
				text: noteEdit.item.text ?? ""
				wrapMode: TextEdit.Wrap
				color: "#3a3000"
				font.family: Theme.fontFamily
				font.pixelSize: 13
				selectByMouse: true
				Component.onCompleted: noteArea.forceActiveFocus()
				onActiveFocusChanged: if (!noteArea.activeFocus) noteEdit.done()
				Keys.onPressed: event => {
					if (event.key === Qt.Key_Escape || ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && (event.modifiers & Qt.ControlModifier))) {
						event.accepted = true;
						noteEdit.done();
					}
				}
			}

			Text {
				anchors.right: parent.right
				anchors.bottom: parent.bottom
				anchors.margins: 6
				text: "Ctrl+Enter"
				color: "#a08a30"
				font.pixelSize: 10
			}
		}
	}

	// where a link leads, a field's name
	Component {
		id: fieldTyper

		Rectangle {
			id: linkEdit

			readonly property var item: typer.item
			readonly property bool link: linkEdit.item?.kind === "link"

			x: (linkEdit.item?.rect?.[0] ?? 0) * root.s
			y: ((linkEdit.item?.rect?.[1] ?? 0) + (linkEdit.item?.rect?.[3] ?? 0)) * root.s + 6
			width: 280
			height: 76
			radius: Theme.radius.medium
			color: Theme.layer1
			border.color: Theme.outline

			function done(keep) {
				if (Pdf.editingText !== linkEdit.item.id) return;
				Pdf.editingText = "";
				const text = typed.text.trim();
				if (!keep) return;
				if (linkEdit.link) {
					if (/^\d+$/.test(text)) {
						const target = Pdf.pages[Math.max(0, Math.min(Pdf.pageCount - 1, Number(text) - 1))]?.id ?? "";
						Pdf.updateItem(linkEdit.item.id, { target: target, url: "", y: 0 }, "Link set");
					} else if (text !== "") Pdf.updateItem(linkEdit.item.id, { url: /^[a-z]+:/i.test(text) ? text : `https://${text}`, target: "" }, "Link set");
				} else {
					const options = linkEdit.item.type === "choice" ? choicesField.text.split(",").map(o => o.trim()).filter(o => o) : (linkEdit.item.options ?? []);
					if (text !== linkEdit.item.name || JSON.stringify(options) !== JSON.stringify(linkEdit.item.options ?? [])) Pdf.updateItem(linkEdit.item.id, { name: text || linkEdit.item.name, options: options }, "Field named");
				}
			}

			Column {
				anchors.fill: parent
				anchors.margins: 8
				spacing: 4

				StyledText {
					text: linkEdit.link ? "An address, or a page number" : (linkEdit.item.type === "choice" ? "The field's name · its choices, with commas" : "The field's name")
					font.pixelSize: Theme.size.small
					tone: Theme.textMuted
				}

				Row {
					spacing: 4
					width: parent.width

					Field {
						id: typed

						width: linkEdit.item.type === "choice" ? (parent.width - 4) / 2 : parent.width
						height: 34
						text: linkEdit.link ? (linkEdit.item.url || (linkEdit.item.target ? String(Pdf.indexOf(linkEdit.item.target) + 1) : "")) : (linkEdit.item.name ?? "")
						placeholder: linkEdit.link ? "https://… or 12" : "Name"
						Component.onCompleted: typed.focusInput()
						onAccepted: linkEdit.done(true)
						onEscapePressed: linkEdit.done(false)
					}

					Field {
						id: choicesField

						visible: linkEdit.item.type === "choice"
						width: (parent.width - 4) / 2
						height: 34
						text: (linkEdit.item.options ?? []).join(", ")
						placeholder: "Yes, No, Maybe"
						onAccepted: linkEdit.done(true)
						onEscapePressed: linkEdit.done(false)
					}
				}
			}
		}
	}
}
