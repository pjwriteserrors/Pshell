pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Pdf
import qs.style.theme
import qs.style.widgets
import qs.core.services

// Two versions side by side over the window: this file on the left, the
// other on the right, scrolled together. Where their pages look different
// is outlined on both (the helper's `compare`, picture against picture);
// the words that came and went are listed at the side, a click goes there.
Rectangle {
	id: root

	readonly property string other: Pdf.compareWith
	property var result: null
	property bool working: true
	readonly property var boxesOf: {
		const map = {};
		for (const p of root.result?.pages ?? []) map[p.page] = p;
		return map;
	}
	readonly property var changes: root.result?.changes?.changes ?? []
	readonly property real listWidth: Math.min(320, root.width * 0.26)
	readonly property real column: (root.width - root.listWidth - 48) / 2

	color: Theme.base
	opacity: 0
	Component.onCompleted: {
		root.opacity = 1;
		root.run();
	}

	Behavior on opacity {
		Anim {}
	}

	function run() {
		root.working = true;
		Pdf.startJob("compare", { a: Pdf.path, b: root.other, passwordA: Pdf.password, passwordB: "" }, "Comparing", result => {
			root.working = false;
			root.result = result;
			Pdf.compareBoxes = result?.pages ?? [];
		});
	}

	function close() {
		Pdf.compareWith = "";
		Pdf.compareBoxes = [];
	}

	function show(n) {
		const y = left.itemY(n);
		left.contentY = Math.max(0, Math.min(left.contentHeight - left.height, y - 20));
	}

	MouseArea {
		anchors.fill: parent
		acceptedButtons: Qt.AllButtons
		onWheel: wheel => wheel.accepted = true
	}

	PdfDocument {
		id: docA

		source: Pdf.fileUrl(Pdf.path)
		password: Pdf.password
	}

	PdfDocument {
		id: docB

		source: Pdf.fileUrl(root.other)
	}

	// ── above ──────────────────────────────────────────────────────────────
	Item {
		id: head

		width: parent.width
		height: 56

		IconButton {
			id: closeKey

			x: 12
			anchors.verticalCenter: parent.verticalCenter
			icon: "arrow_left"
			onClicked: root.close()
		}

		Row {
			anchors.left: closeKey.right
			anchors.leftMargin: 12
			anchors.verticalCenter: parent.verticalCenter
			spacing: 24

			StyledText {
				width: root.column - 40
				text: Pdf.nameOf(Pdf.path)
				font.weight: Font.Bold
				elide: Text.ElideMiddle
			}

			StyledText {
				width: root.column
				text: Pdf.nameOf(root.other)
				font.weight: Font.Bold
				elide: Text.ElideMiddle
			}
		}

		Row {
			anchors.right: parent.right
			anchors.rightMargin: 16
			anchors.verticalCenter: parent.verticalCenter
			spacing: 8

			Spinner {
				width: 18
				height: 18
				visible: root.working
				anchors.verticalCenter: parent.verticalCenter
			}

			StyledText {
				anchors.verticalCenter: parent.verticalCenter
				text: root.working ? "Comparing…" : `${(root.result?.pages ?? []).filter(p => p.boxes.length > 0).length} pages differ`
				tone: Theme.textMuted
			}
		}
	}

	// ── the pages ──────────────────────────────────────────────────────────
	component Side: ListView {
		id: side

		property var doc: null
		property bool leading: false

		// to the same place along as the other one
		function follow(from) {
			const ratio = from.contentHeight > from.height ? from.contentY / (from.contentHeight - from.height) : 0;
			side.contentY = Math.max(0, ratio * Math.max(0, side.contentHeight - side.height));
		}

		function itemY(n) {
			let y = 0;
			for (let i = 0; i < n; i += 1) y += side.heightOf(i) + side.spacing;
			return y;
		}

		function heightOf(i) {
			const size = side.doc?.pagePointSize(i) ?? Qt.size(595, 842);
			return root.column * size.height / Math.max(1, size.width);
		}

		width: root.column
		height: root.height - head.height
		y: head.height
		clip: true
		spacing: 14
		model: side.doc && side.doc.status === PdfDocument.Ready ? side.doc.pageCount : 0
		cacheBuffer: 1600
		boundsBehavior: Flickable.StopAtBounds
		ScrollBar.vertical: ThinScrollBar {}

		delegate: Rectangle {
			id: page

			required property int index
			readonly property size size: side.doc.pagePointSize(page.index)
			readonly property real k: root.column / Math.max(1, page.size.width)
			readonly property var diff: root.boxesOf[page.index] ?? null

			width: root.column
			height: side.heightOf(page.index)
			color: "white"
			radius: 3

			PdfPageImage {
				anchors.fill: parent
				document: side.doc
				currentFrame: page.index
				asynchronous: true
				sourceSize.width: root.column * 1.5
			}

			// what differs, outlined
			Repeater {
				model: page.diff?.boxes ?? []

				delegate: Rectangle {
					required property var modelData
					required property int index

					x: modelData[0] * page.k - 2
					y: modelData[1] * page.k - 2
					width: modelData[2] * page.k + 4
					height: modelData[3] * page.k + 4
					radius: 2
					color: side.leading ? Qt.rgba(0.9, 0.2, 0.2, 0.12) : Qt.rgba(0.2, 0.7, 0.3, 0.14)
					border.color: side.leading ? "#e53935" : "#43a047"
					border.width: 1.5
					opacity: 0
					Component.onCompleted: opacity = 1

					Behavior on opacity {
						NumberAnimation {
							duration: Motion.medium + index * 20
						}
					}
				}
			}

			Rectangle {
				anchors.right: parent.right
				anchors.top: parent.top
				anchors.margins: 8
				visible: !!page.diff && page.diff.boxes.length > 0
				width: changed.implicitWidth + 14
				height: 22
				radius: 11
				color: side.leading ? "#e53935" : "#43a047"

				Text {
					id: changed

					anchors.centerIn: parent
					text: page.diff?.missing ? "only here" : `${page.diff?.boxes.length ?? 0} changes`
					color: "white"
					font.pixelSize: 11
				}
			}
		}
	}

	Side {
		id: left

		x: 16
		doc: docA
		leading: true
		onContentYChanged: if (!right.moving && !right.dragging) right.follow(left)
	}

	Side {
		id: right

		x: left.x + root.column + 16
		doc: docB
		onContentYChanged: if (right.moving || right.dragging) left.follow(right)
	}

	// ── what the words say changed ─────────────────────────────────────────
	Rectangle {
		anchors.right: parent.right
		y: head.height
		width: root.listWidth
		height: parent.height - head.height
		color: Theme.layer1

		ListView {
			anchors.fill: parent
			anchors.margins: 12
			clip: true
			spacing: 10
			model: root.changes
			ScrollBar.vertical: ThinScrollBar {}

			header: StyledText {
				width: parent?.width ?? 280
				height: 32
				text: root.working ? "" : (root.changes.length === 0 ? "The words are the same" : "Words")
				font.weight: Font.Bold
			}

			delegate: Clickable {
				id: change

				required property var modelData

				width: ListView.view.width
				height: lines.implicitHeight + 16
				radius: Theme.radius.small
				color: change.hovered ? Theme.layer2 : "transparent"
				onClicked: root.show(change.modelData.page - 1)

				Column {
					id: lines

					x: 8
					y: 8
					width: parent.width - 16
					spacing: 3

					StyledText {
						text: `Page ${change.modelData.page}`
						font.pixelSize: Theme.size.small
						tone: Theme.textMuted
					}

					Repeater {
						model: (change.modelData.lines ?? []).slice(0, 12)

						delegate: StyledText {
							required property var modelData

							width: lines.width
							text: (modelData.kind === "added" ? "+ " : "− ") + modelData.text
							color: modelData.kind === "added" ? "#43a047" : "#e53935"
							wrapMode: Text.WordWrap
							font.pixelSize: Theme.size.small
							font.strikeout: modelData.kind === "removed"
						}
					}
				}
			}
		}
	}

	Keys.onEscapePressed: root.close()
}
