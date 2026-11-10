pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Pdf
import qs.style.theme
import qs.style.widgets
import qs.core.services

// The file's contents: its outline as a tree that folds, the chapter read
// now marked. The recipe's outline when it has one (the editor changes it),
// else the file's own – read by PDFium at once, the helper's copy later.
Item {
	id: root

	property var reader: null
	property var folded: ({})

	// the file's own, as PDFium reads it: a tree walked into the recipe's shape
	PdfBookmarkModel {
		id: bookmarks

		// read while PDFium is idle (it would hold the whole shell until a page is drawn)
		document: root.readFor === Pdf.docKey ? (root.reader?.docs?.a ?? null) : null
		onModelReset: root.tick += 1
		onRowsInserted: root.tick += 1
	}

	property string readFor: ""
	readonly property bool docReady: root.reader?.docs?.a?.status === PdfDocument.Ready

	function readOutline() {
		if (root.docReady && Pdf.rendering === 0) root.readFor = Pdf.docKey;
	}
	onDocReadyChanged: root.readOutline()
	Component.onCompleted: root.readOutline()

	Connections {
		target: Pdf
		enabled: root.readFor !== Pdf.docKey

		function onRenderingChanged() {
			root.readOutline();
		}
		function onDocKeyChanged() {
			root.readOutline();
		}
	}

	// grows when PDFium has read the outline (it comes after the document)
	property int tick: 0

	readonly property var tree: {
		if (Pdf.outlineNow && Pdf.outlineNow.length > 0) return Pdf.outlineNow;
		const walk = parent => {
			const out = [];
			const count = parent ? bookmarks.rowCount(parent) : bookmarks.rowCount();
			for (let i = 0; i < count; i += 1) {
				const index = parent ? bookmarks.index(i, 0, parent) : bookmarks.index(i, 0);
				const page = bookmarks.data(index, Qt.UserRole + 2);
				const location = bookmarks.data(index, Qt.UserRole + 3);
				const at = root.reader ? root.reader.indexOfSource("a", page) : page;
				out.push({ title: String(bookmarks.data(index, Qt.UserRole) ?? ""), page: Pdf.pages[at]?.id ?? "", y: location?.y ?? 0, children: walk(index) });
			}
			return out;
		};
		// the document's status and the model's changes are read for the tree to follow them
		return root.tick >= 0 && root.reader?.docs?.a?.status === PdfDocument.Ready ? walk(null) : [];
	}

	// flat, as rows: depth, whether it has children, whether those are folded away
	readonly property var rows: {
		const out = [];
		const walk = (list, depth, path) => {
			list.forEach((entry, i) => {
				const key = `${path}/${i}`;
				const kids = entry.children || [];
				out.push({ key: key, title: entry.title, page: entry.page, y: entry.y || 0, depth: depth, kids: kids.length > 0 });
				if (kids.length > 0 && !root.folded[key]) walk(kids, depth + 1, key);
			});
		};
		walk(root.tree, 0, "");
		return out;
	}

	// the entry the page looked at belongs to
	readonly property int currentRow: {
		let found = -1;
		for (let i = 0; i < root.rows.length; i += 1) {
			const at = Pdf.indexOf(root.rows[i].page);
			if (at >= 0 && at <= Pdf.page) found = i;
		}
		return found;
	}

	ListView {
		id: list

		anchors.fill: parent
		model: root.rows
		clip: true
		boundsBehavior: Flickable.StopAtBounds
		visible: root.rows.length > 0

		ScrollBar.vertical: ThinScrollBar {}

		delegate: Clickable {
			id: row

			required property var modelData
			required property int index
			readonly property bool current: row.index === root.currentRow

			width: list.width - 12
			x: 6
			height: 32
			radius: Theme.radius.small
			color: row.current ? Theme.primarySoft : (row.hovered ? Theme.layer1 : "transparent")
			onClicked: {
				const at = Pdf.indexOf(row.modelData.page);
				if (at >= 0) Pdf.goTo(at, row.modelData.y);
			}

			Glyph {
				id: fold

				x: 6 + row.modelData.depth * 14
				anchors.verticalCenter: parent.verticalCenter
				icon: "chevron_right"
				size: 16
				color: Theme.textMuted
				visible: row.modelData.kids
				rotation: root.folded[row.modelData.key] ? 0 : 90

				Behavior on rotation {
					SpatialAnim {}
				}

				TapHandler {
					onTapped: {
						const next = Object.assign({}, root.folded);
						next[row.modelData.key] = !next[row.modelData.key];
						root.folded = next;
					}
				}
			}

			StyledText {
				anchors.left: fold.right
				anchors.leftMargin: 4
				anchors.right: pageNo.left
				anchors.rightMargin: 6
				anchors.verticalCenter: parent.verticalCenter
				text: row.modelData.title
				elide: Text.ElideRight
				font.weight: row.modelData.depth === 0 ? Font.DemiBold : Font.Normal
				tone: row.current ? Theme.primary : Theme.text
			}

			StyledText {
				id: pageNo

				anchors.right: parent.right
				anchors.rightMargin: 8
				anchors.verticalCenter: parent.verticalCenter
				text: Pdf.indexOf(row.modelData.page) >= 0 ? String(Pdf.indexOf(row.modelData.page) + 1) : ""
				tone: Theme.textSubtle
				font.pixelSize: Theme.size.small
				tabular: true
			}
		}
	}

	EmptyNote {
		visible: root.rows.length === 0
		icon: "format_list_bulleted_square"
		text: "This file has no contents"
	}

	component EmptyNote: Column {
		property string icon: ""
		property string text: ""

		anchors.centerIn: parent
		spacing: 8

		Glyph {
			anchors.horizontalCenter: parent.horizontalCenter
			icon: parent.icon
			size: 32
			color: Theme.textFaint
		}
		StyledText {
			anchors.horizontalCenter: parent.horizontalCenter
			text: parent.text
			tone: Theme.textSubtle
		}
	}
}
