pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "../video"

// Pages: turned, removed, doubled, moved, taken out or cut into files;
// new ones put in – empty, from other files (PDFs, pictures, office files),
// the clipboard, the screen or photographed by the phone; empty pages found
// and removed; sizes made even, two or four on a sheet, a booklet. All of
// it at once in the organizer (G).
PaneFrame {
	id: root

	property Item dock: null

	readonly property var ids: Pdf.scopeIds()
	readonly property int at: Pdf.page + 1
	property int every: 1
	property bool findingBlank: false

	title: "Pages"
	subtitle: `${Pdf.pageCount} ${Pdf.pageCount === 1 ? "page" : "pages"} · on ${Pdf.pageScope === "all" ? "all of them" : (Pdf.pageScope === "selected" ? Pdf.rangeText(Pdf.selectedPages) : (Pdf.pageScope === "this" ? `page ${root.at}` : `the ${Pdf.pageScope} ones`))}`
	onClose: Pdf.tool = ""

	function pickFiles(title, filters, done) {
		Files.pick({ title: title, multiple: true, filters: filters, folder: Pdf.folderOf(Pdf.path) }, paths => {
			if (paths && paths.length > 0) done(paths);
		});
	}

	TextButton {
		width: parent.width
		text: "All pages at once"
		icon: "view_grid_outline"
		variant: "filled"
		onActivated: Pdf.gridOpen = true
	}

	SectionLabel {
		text: "Which pages"
	}

	EditScope {}

	Flow {
		width: parent.width
		spacing: 6

		TextButton {
			text: "Turn left"
			icon: "rotate_left"
			onActivated: Pdf.rotatePages(root.ids, -90)
		}

		TextButton {
			text: "Turn right"
			icon: "rotate_right"
			onActivated: Pdf.rotatePages(root.ids, 90)
		}

		TextButton {
			text: "Double"
			icon: "content_duplicate"
			onActivated: Pdf.duplicatePages(root.ids)
		}

		TextButton {
			text: "Remove"
			icon: "delete_outline"
			variant: "danger"
			onActivated: Pdf.deletePages(root.ids)
		}

		TextButton {
			text: "To the start"
			icon: "arrow_collapse_up"
			onActivated: Pdf.movePages(root.ids, 0)
		}

		TextButton {
			text: "To the end"
			icon: "arrow_collapse_down"
			onActivated: Pdf.movePages(root.ids, Pdf.pageCount)
		}

		TextButton {
			text: "Back to front"
			icon: "swap_vertical"
			onActivated: {
				const next = Pdf.clone(Pdf.recipe);
				const chosen = new Set(root.ids.length > 1 ? root.ids : next.pages.map(p => p.id));
				const slots = next.pages.map((p, i) => chosen.has(p.id) ? i : -1).filter(i => i >= 0);
				const reversed = slots.map(i => next.pages[i]).reverse();
				slots.forEach((slot, k) => next.pages[slot] = reversed[k]);
				Pdf.commit(next, "Order turned around");
			}
		}

		TextButton {
			text: "Take out as a file"
			icon: "file_export_outline"
			onActivated: Pdf.extractPages(root.ids)
		}

		TextButton {
			text: "Copy as picture"
			icon: "image_outline"
			visible: Pdf.pageScope === "this"
			onActivated: Pdf.copyPage(Pdf.page)
		}
	}

	// ── cut in files ───────────────────────────────────────────────────────
	SectionLabel {
		text: "Cut into files"
	}

	Flow {
		width: parent.width
		spacing: 6

		TextButton {
			text: Pdf.pageScope === "selected" ? "After each chosen page" : `After page ${root.at}`
			icon: "content_cut"
			onActivated: Pdf.splitAfter(Pdf.pageScope === "selected" ? Pdf.selectedPages : [Pdf.pages[Pdf.page]?.id])
		}

		Row {
			spacing: 6

			TextButton {
				text: root.every === 1 ? "Every page alone" : `Every ${root.every} pages`
				icon: "format_page_split"
				onActivated: Pdf.splitAfter(Pdf.pages.filter((p, i) => (i + 1) % root.every === 0).map(p => p.id))
			}

			IconButton {
				anchors.verticalCenter: parent.verticalCenter
				icon: "minus"
				enabled: root.every > 1
				onClicked: root.every -= 1
			}

			IconButton {
				anchors.verticalCenter: parent.verticalCenter
				icon: "plus"
				onClicked: root.every = Math.min(Pdf.pageCount, root.every + 1)
			}
		}

		TextButton {
			text: "At each chapter"
			icon: "bookmark_multiple_outline"
			visible: Pdf.outlineNow.length > 1
			onActivated: {
				// a new file starts at each top entry of the contents
				const starts = Pdf.outlineNow.map(e => Pdf.indexOf(e.page)).filter(i => i > 0);
				Pdf.splitAfter(starts.map(i => Pdf.pages[i - 1].id));
			}
		}
	}

	// ── put in ─────────────────────────────────────────────────────────────
	SectionLabel {
		text: `Put in after page ${root.at}`
	}

	Flow {
		width: parent.width
		spacing: 6

		TextButton {
			text: "Empty page"
			icon: "file_outline"
			onActivated: Pdf.insertBlank(root.at)
		}

		TextButton {
			text: "Other files…"
			icon: "file_plus_outline"
			onActivated: root.pickFiles("Put these in", ["*.pdf", "*.png", "*.jpg", "*.jpeg", "*.webp", "*.tif", "*.tiff", "*.docx", "*.doc", "*.odt", "*.xlsx", "*.pptx", "*.txt", "*.html"], paths => {
				let at = root.at;
				for (const p of paths) {
					Pdf.insertFile(p, at);
					at += 1;
				}
			})
		}

		TextButton {
			text: "Put others behind it"
			icon: "file_document_multiple_outline"
			onActivated: root.pickFiles("Put these behind it", ["*.pdf"], paths => {
				for (const p of paths) Pdf.insertFile(p, -1);
			})
		}

		TextButton {
			text: "Picture from the clipboard"
			icon: "clipboard_outline"
			onActivated: Pdf.insertClipboard(root.at)
		}

		TextButton {
			text: "Part of the screen"
			icon: "monitor_screenshot"
			onActivated: Pdf.insertScreenshot(root.at)
		}

		TextButton {
			text: "Photograph with the phone"
			icon: "cellphone_screenshot"
			onActivated: {
				Pdf.bridgeStart("scan");
				root.dock?.sheet("BridgeSheet.qml", { kind: "scan" });
			}
		}
	}

	// ── tidy ───────────────────────────────────────────────────────────────
	SectionLabel {
		text: "Tidy up"
	}

	Flow {
		width: parent.width
		spacing: 6

		TextButton {
			text: root.findingBlank ? "Looking…" : "Remove empty pages"
			icon: "file_hidden"
			busy: root.findingBlank
			onActivated: {
				root.findingBlank = true;
				const path = Pdf.sourcePath("a");
				Pdf.request("blank", { path: path, password: Pdf.password }, data => {
					root.findingBlank = false;
					const empty = new Set(data?.blank ?? []);
					const ids = Pdf.pages.filter(p => (p.src === "a" && empty.has(p.n)) || p.blank).map(p => p.id).filter(id => Pdf.itemsOf(id).length === 0);
					if (ids.length === 0) return Pdf.say("No empty pages", "check");
					if (ids.length >= Pdf.pageCount) return Pdf.say("Every page looks empty – nothing removed", "alert_circle_outline");
					Pdf.deletePages(ids);
					Pdf.say(`${ids.length} empty ${ids.length === 1 ? "page" : "pages"} removed – Ctrl+Z brings them back`, "file_hidden");
				});
			}
		}

		TextButton {
			text: "All the same size"
			icon: "resize"
			onActivated: Pdf.runTool("normalize", { paper: paper.current }, "Pages made one size")
		}

		TextButton {
			text: "Two on a sheet"
			icon: "view_split_vertical"
			onActivated: Pdf.runTool("nup", { n: 2, paper: paper.current }, "Two pages a sheet")
		}

		TextButton {
			text: "Four on a sheet"
			icon: "view_grid_outline"
			onActivated: Pdf.runTool("nup", { n: 4, paper: paper.current }, "Four pages a sheet")
		}

		TextButton {
			text: "Booklet"
			icon: "book_open_page_variant_outline"
			onActivated: Pdf.runTool("booklet", { paper: paper.current }, "Booklet to fold")
		}
	}

	PaneLine {
		label: "Paper"
		detail: "For one size, two or four on a sheet and the booklet"

		Segmented {
			id: paper

			width: 200
			options: [{ value: "A4", label: "A4" }, { value: "A5", label: "A5" }, { value: "A3", label: "A3" }, { value: "Letter", label: "Letter" }]
			current: "A4"
			onSelected: value => paper.current = value
		}
	}

	// ── a PDF from pictures ────────────────────────────────────────────────
	TextButton {
		text: "A new PDF from pictures…"
		icon: "image_multiple_outline"
		onActivated: root.pickFiles("Pictures for a new PDF", ["*.png", "*.jpg", "*.jpeg", "*.webp", "*.tif", "*.tiff", "*.bmp", "*.gif", "*.heic"], paths => {
			Pdf.startJob("images", { paths: paths, out: `${Pdf.folderOf(paths[0])}/${Pdf.nameOf(paths[0]).replace(/\.[^.]+$/, "")}.pdf` }, "Making a PDF of the pictures", result => {
				if (result?.path) Pdf.tellMade(result.path, "PDF made of the pictures");
			});
		})
	}
}
