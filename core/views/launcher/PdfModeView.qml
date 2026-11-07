pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Quickshell.Widgets
import qs.style.theme
import qs.core.services
import qs.style.widgets

// Launcher >pdf (>pdfs, >docs): the PDF that is open, the ones left half
// read and what was opened lately, each with its first page. Words typed
// after it look through those by name, through the open PDF's text (each
// place a row with its page) and through the text of every PDF the file
// index knows. "12" or "p12" goes to that page of the open one. Enter opens
// it where it was left (at the place found), Ctrl+Enter in the editor,
// Shift+Enter from the first page.
Item {
	id: root

	property string argument: ""
	property bool active: false
	property int currentIndex: 0

	// the first page of each row's PDF, asked for once its row shows: path → picture
	property var covers: ({})
	property var coversAsked: ({})
	// what the open PDF says where the words are: [{ page, text }]
	property var inside: []
	// PDFs of the index whose text has the words: [{ path, snippet }]
	property var found: []

	readonly property string words: root.argument.trim()
	readonly property string lower: root.words.toLowerCase()
	readonly property int pageAsked: {
		const m = root.lower.match(/^(?:p|page|seite|s\.?)\s*(\d{1,5})$|^(\d{1,5})$/);
		return m ? Number(m[1] || m[2]) : -1;
	}

	// read in the middle, newest first
	readonly property var halfRead: Object.entries(Pdf.files_)
		.filter(([path, kept]) => kept.view && kept.pages > 1 && kept.view.page > 0 && kept.view.page < kept.pages - 1)
		.sort((a, b) => (b[1].at || 0) - (a[1].at || 0))
		.map(([path]) => path)

	// [{ path, section, page, text, kind: "file" | "page" | "goto" }]
	readonly property var rows: {
		const out = [];
		const seen = {};
		const push = (path, section) => {
			if (!path || seen[path]) return;
			seen[path] = true;
			out.push({ path: path, section: section, kind: "file", page: -1, text: "" });
		};
		if (root.pageAsked > 0 && Pdf.current) out.push({ path: Pdf.path, section: "Go to", kind: "goto", page: Math.min(root.pageAsked, Pdf.pageCount) - 1, text: "" });
		if (root.words === "" || root.pageAsked > 0) {
			if (Pdf.current) push(Pdf.path, "Open now");
			for (const path of root.halfRead.slice(0, 12)) push(path, "Continue reading");
			for (const path of Pdf.list) if (path !== Pdf.path && out.length < 30) push(path, "In this folder");
			for (const path of Pdf.recent) push(path, "Recently opened");
			return out;
		}
		const terms = root.lower.split(/\s+/).filter(w => w);
		const fits = path => {
			const hay = `${Pdf.nameOf(path)} ${Pdf.keptOf(path)?.title ?? ""}`.toLowerCase();
			return terms.every(w => hay.includes(w));
		};
		if (Pdf.current && fits(Pdf.path)) push(Pdf.path, "Open now");
		for (const hit of root.inside) out.push({ path: Pdf.path, section: `In ${Pdf.title}`, kind: "page", page: hit.page, text: hit.text });
		for (const path of root.halfRead) if (fits(path)) push(path, "Continue reading");
		for (const path of Pdf.recent) if (fits(path)) push(path, "Recently opened");
		for (const hit of root.found) {
			if (seen[hit.path]) continue;
			seen[hit.path] = true;
			out.push({ path: hit.path, section: "What they say", kind: "file", page: -1, text: hit.snippet });
		}
		return out;
	}

	signal closeRequested

	onActiveChanged: {
		if (!root.active) return;
		root.currentIndex = 0;
	}
	onRowsChanged: root.currentIndex = Math.max(0, Math.min(root.currentIndex, root.rows.length - 1))
	onWordsChanged: {
		root.inside = [];
		root.found = [];
		if (root.words.length >= 3 && root.pageAsked < 0) look.restart();
	}

	// the words in the open PDF and in all the index has read, a moment after typing
	Timer {
		id: look

		interval: 280
		onTriggered: {
			const words = root.words;
			if (Pdf.current && !Pdf.locked) {
				Pdf.request("find", { path: Pdf.sourcePath("a"), password: Pdf.password, words: words }, data => {
					if (words !== root.words || !data) return;
					const byPage = {};
					for (const hit of data.hits || []) {
						const at = Pdf.pages.findIndex(p => p.src === "a" && p.n === hit.page);
						if (at >= 0 && byPage[at] === undefined) byPage[at] = hit.text || "";
					}
					root.inside = Object.keys(byPage).map(Number).sort((a, b) => a - b).slice(0, 8).map(page => ({ page: page, text: byPage[page] }));
				});
			}
			Files.request("aisearch", { query: words, limit: 40, smart: false }, data => {
				if (words !== root.words || !data) return;
				root.found = (data.entries || []).filter(entry => Pdf.isPdf(entry.path)).slice(0, 20).map(entry => ({ path: entry.path, snippet: String(entry.snippet || "").replace(/<[^>]+>/g, "") }));
			});
		}
	}

	function wantCover(path) {
		if (root.covers[path] || root.coversAsked[path]) return;
		root.coversAsked[path] = true;
		Pdf.request("pagepng", { path: path, page: 0, dpi: 16 }, data => {
			if (data?.image) root.covers = Object.assign({}, root.covers, { [path]: data.image });
		});
	}

	// "page 12 of 40", "edited", how many pages
	function noteOf(path) {
		const kept = Pdf.keptOf(path);
		const parts = [];
		if (kept?.view && kept.pages > 1 && kept.view.page > 0) parts.push(`Page ${kept.view.page + 1} of ${kept.pages}`);
		else if (kept?.pages) parts.push(kept.pages === 1 ? "1 page" : `${kept.pages} pages`);
		if (kept?.recipe) parts.push("Unsaved changes");
		return parts.join(" · ");
	}

	function folderOf(path) {
		return String(path).slice(0, String(path).lastIndexOf("/")).replace(Paths.home, "~");
	}

	function move(delta) {
		root.select(root.currentIndex + delta);
	}

	function select(index) {
		if (root.rows.length === 0) return;
		root.currentIndex = Math.max(0, Math.min(root.rows.length - 1, index));
		list.positionViewAtIndex(root.currentIndex, ListView.Contain);
	}

	function handleKey(event) {
		return false;
	}

	function cancel() {
		return false;
	}

	function activate(modifiers) {
		const row = root.rows[root.currentIndex];
		if (!row) return;
		if (modifiers & Qt.ControlModifier) root.run("edit", row);
		else if (modifiers & Qt.ShiftModifier) root.run("start", row);
		else root.run("open", row);
	}

	function run(how, row) {
		root.closeRequested();
		// once the launcher has left, the window takes the keyboard
		later.how = how;
		later.row = row;
		later.words = root.words;
		later.restart();
	}

	Timer {
		id: later

		property string how: ""
		property var row: null
		property string words: ""
		interval: Motion.medium
		onTriggered: {
			const row = later.row;
			if (!row) return;
			if (later.how === "edit") return Pdf.edit(row.path, "");
			if (later.how === "start") return Pdf.open(row.path, { page: 0 });
			if (row.kind === "goto" || row.kind === "page") {
				Pdf.showWindow();
				Pdf.goTo(row.page);
				if (row.kind === "page") Pdf.searchText = later.words;
				return;
			}
			// found by its text: opened with the words looked for
			if (row.text && row.section === "What they say") return Pdf.open(row.path, { search: later.words });
			Pdf.open(row.path);
		}
	}

	EmptyState {
		anchors.centerIn: parent
		visible: root.rows.length === 0
		icon: "file_pdf_box"
		title: root.words ? "No PDF says that" : "No PDF read yet"
		subtitle: root.words ? "Only what the file index has read is looked through" : "Open a PDF in Files, or type to look through their text"
	}

	ListView {
		id: list

		anchors.fill: parent
		visible: root.rows.length > 0
		clip: true
		spacing: 2
		model: root.rows
		currentIndex: root.currentIndex
		boundsBehavior: Flickable.StopAtBounds
		ScrollBar.vertical: ThinScrollBar {}

		delegate: Column {
			id: cell

			required property var modelData
			required property int index
			readonly property bool head: cell.index === 0 || root.rows[cell.index - 1]?.section !== cell.modelData.section

			width: list.width

			Item {
				visible: cell.head
				width: parent.width
				height: cell.index === 0 ? 24 : 32

				StyledText {
					anchors.left: parent.left
					anchors.leftMargin: 10
					anchors.bottom: parent.bottom
					anchors.bottomMargin: 6
					text: cell.modelData.section
					tone: Theme.textMuted
					font.pixelSize: Theme.size.small
					font.weight: Font.DemiBold
				}
			}

			ListItem {
				id: docRow

				readonly property var modelData: cell.modelData
				readonly property int index: cell.index
				readonly property string path: docRow.modelData.path
				readonly property string cover: root.covers[docRow.path] ?? ""
				readonly property var kept: Pdf.files_[docRow.path] ?? null
				readonly property real read: docRow.kept?.view && docRow.kept.pages > 1 && docRow.kept.view.page > 0 ? (docRow.kept.view.page + 1) / docRow.kept.pages : 0
				readonly property bool open: docRow.path === Pdf.path && Pdf.current

				width: list.width
				title: docRow.modelData.kind === "goto" ? `Page ${docRow.modelData.page + 1}` : (docRow.modelData.kind === "page" ? `Page ${docRow.modelData.page + 1}` : Pdf.nameOf(docRow.path))
				subtitle: docRow.modelData.kind === "goto" ? `of ${Pdf.title}` : (docRow.modelData.text !== "" ? docRow.modelData.text : [root.noteOf(docRow.path), root.folderOf(docRow.path)].filter(x => x).join(" · "))
				selected: root.currentIndex === docRow.index
				icon: docRow.modelData.kind === "goto" ? "arrow_right_bold_circle_outline" : (docRow.modelData.kind === "page" ? "text_search" : "file_pdf_box")
				leading: docRow.modelData.kind === "file" && docRow.cover !== "" ? coverTile : null
				onPointed: root.currentIndex = docRow.index
				onClicked: root.run("open", docRow.modelData)
				Component.onCompleted: if (docRow.modelData.kind === "file") root.wantCover(docRow.path)

				Component {
					id: coverTile

					ClippingRectangle {
						radius: docRow.selected ? Theme.radius.medium : 18
						color: "white"

						Behavior on radius {
							SpatialAnim {
								duration: Motion.medium
							}
						}

						Image {
							anchors.fill: parent
							source: Pdf.fileUrl(docRow.cover)
							sourceSize: Qt.size(72, 96)
							fillMode: Image.PreserveAspectCrop
							verticalAlignment: Image.AlignTop
							asynchronous: true
						}
					}
				}

				Glyph {
					visible: docRow.open && docRow.modelData.kind === "file"
					icon: "book_open_page_variant_outline"
					size: 16
					color: Theme.primary
				}

				// changes not saved yet
				Rectangle {
					visible: docRow.modelData.kind === "file" && !!docRow.kept?.recipe
					implicitWidth: 8
					implicitHeight: 8
					radius: 4
					color: Theme.warning
				}

				// how far it was read
				Rectangle {
					visible: docRow.modelData.kind === "file" && docRow.read > 0 && docRow.read < 1
					implicitWidth: 64
					implicitHeight: 4
					radius: 2
					color: Theme.layer3

					Rectangle {
						width: parent.width * docRow.read
						height: parent.height
						radius: parent.radius
						color: Theme.primary
					}
				}
			}
		}
	}
}
