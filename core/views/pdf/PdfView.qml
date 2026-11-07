pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import QtQuick.Pdf
import Quickshell
import qs.style.theme
import qs.style.widgets
import qs.core.services
import qs.core.views.files

// The PDFs' window: the pages on a calm sheet, the page looked at glowing
// softly behind them, the bar above fading away while one reads (it comes
// back with the pointer near it). On the left the pages, the contents, the
// notes, the hits of a search and the folder's other files; on the right,
// while editing, the editor's tools (ToolDock.qml). A selection of text
// gets a small menu above it, a link to a page peeks out on hover, F5 shows
// the pages as slides. See core/services/Pdf.qml.
FocusScope {
	id: root

	property bool shown: false
	// for the components below, whose own properties of the same names would shadow the ids
	readonly property Item pages: reader
	readonly property Item menus: menu
	readonly property bool narrow: root.width < 760
	readonly property bool editing: Pdf.editing

	function takeFocus() {
		root.forceActiveFocus();
	}

	// ── the bar comes with the pointer and goes while one reads ────────────
	property bool awake: true
	property bool searchOpen: false
	readonly property bool chrome: root.awake || root.editing || !Pdf.current || Pdf.locked || Pdf.error !== "" || root.searchOpen || Pdf.sidebar !== ""
		|| menu.open || topHover.hovered || pageField.input.activeFocus || !Pdf.setting("barsFade", true) || Pdf.runningJobs.length > 0

	function wake() {
		root.awake = true;
		sleepTimer.restart();
	}

	Timer {
		id: sleepTimer

		interval: 2800
		onTriggered: root.awake = false
	}

	onShownChanged: if (root.shown) root.wake()

	// ── behind the pages ───────────────────────────────────────────────────
	readonly property color sheet: Pdf.night ? "#0e0f12" : (Theme.dark ? Qt.darker(Theme.bg, 1.12) : Theme.layer2)

	Rectangle {
		anchors.fill: parent
		color: root.sheet

		Behavior on color {
			ColorAnimation {
				duration: Motion.long
			}
		}
	}

	// the page looked at, blurred large behind everything: its colours glow around the sheets
	Item {
		id: glow

		anchors.fill: parent
		visible: Pdf.setting("glow", true) && Pdf.current && !Pdf.night && glowLoader.active
		opacity: glowLoader.item?.status === Image.Ready ? (Theme.dark ? 0.34 : 0.26) : 0

		Behavior on opacity {
			Anim {
				duration: Motion.extraLong
			}
		}

		Loader {
			id: glowLoader

			readonly property var p: Pdf.pages[Pdf.page] ?? null
			readonly property var doc: glowLoader.p?.src ? (reader.docs[glowLoader.p.src] ?? null) : null

			anchors.fill: parent
			visible: false
			active: !!glowLoader.doc && glowLoader.doc.status === PdfDocument.Ready

			sourceComponent: PdfPageImage {
				document: glowLoader.doc
				currentFrame: glowLoader.p?.n ?? 0
				sourceSize.width: 48
				asynchronous: true
				fillMode: Image.Stretch
			}
		}

		MultiEffect {
			anchors.fill: parent
			source: glowLoader
			blurEnabled: true
			blur: 1
			blurMax: 64
			saturation: 0.4
		}
	}

	// ── the pages ──────────────────────────────────────────────────────────
	readonly property real sidebarWidth: Pdf.sidebar !== "" && Pdf.current && !Pdf.presenting ? Math.min(300, Math.max(220, root.width * 0.22)) : 0
	property real sidebarShown: root.sidebarWidth
	Behavior on sidebarShown {
		SpatialAnim {
			duration: Motion.long
		}
	}
	readonly property real dockWidth: root.editing && dock.item ? (dock.item.width ?? 0) : 0

	PdfReader {
		id: reader

		anchors.fill: parent
		padTop: topBar.height + 4
		padBottom: 8
		padLeft: root.narrow ? 0 : root.sidebarShown
		padRight: root.dockWidth
		opacity: Pdf.current && !Pdf.locked && Pdf.error === "" ? 1 : 0
		visible: opacity > 0.01

		Behavior on opacity {
			Anim {
				duration: Motion.long
			}
		}

		onSelectionShown: box => selectionMenu.showAt(box)
		onSelectionHidden: selectionMenu.hide()
		onPeekWanted: (index, location, url, x, y, top) => peek.show(index, location, url, x, y, top)
		onPeekGone: peek.hide()
		onMenuWanted: (pageId, px, py, x, y) => root.pageMenu(pageId, px, py, x, y)
	}

	HoverHandler {
		onPointChanged: {
			if (Math.abs(point.position.x - root.lastX) + Math.abs(point.position.y - root.lastY) > 4) root.wake();
			root.lastX = point.position.x;
			root.lastY = point.position.y;
		}
	}

	property real lastX: 0
	property real lastY: 0

	// a page that is scrolled to says which it is, for a moment
	Rectangle {
		anchors.right: parent.right
		anchors.bottom: parent.bottom
		anchors.rightMargin: root.dockWidth + 22
		anchors.bottomMargin: 18
		width: pageLabel.implicitWidth + 24
		height: 30
		radius: 15
		color: Qt.alpha(Theme.bg, 0.86)
		border.color: Theme.outline
		opacity: reader.moving && Pdf.pageCount > 1 && !Pdf.presenting ? 1 : 0
		visible: opacity > 0.01

		Behavior on opacity {
			SequentialAnimation {
				PauseAnimation {
					duration: reader.moving ? 0 : 700
				}
				Anim {
					duration: Motion.medium
				}
			}
		}

		StyledText {
			id: pageLabel

			anchors.centerIn: parent
			text: `${Pdf.page + 1} / ${Pdf.pageCount}`
			tabular: true
			font.weight: Font.DemiBold
		}
	}

	// ── the left: pages, contents, notes, hits, files ──────────────────────
	Loader {
		id: sidebar

		anchors.left: parent.left
		anchors.top: parent.top
		anchors.bottom: parent.bottom
		anchors.topMargin: topBar.height
		width: Math.max(1, root.sidebarShown)
		active: Pdf.current && (Pdf.sidebar !== "" || root.sidebarShown > 1)
		visible: root.sidebarShown > 1
		clip: true
		z: 5
		sourceComponent: PdfSidebar {
			reader: root.pages
			menu: root.menus
			fullWidth: root.sidebarWidth > 0 ? root.sidebarWidth : 240
		}
	}

	// ── the right: the editor's tools ──────────────────────────────────────
	Loader {
		id: dock

		anchors.right: parent.right
		anchors.top: parent.top
		anchors.bottom: parent.bottom
		anchors.topMargin: topBar.height
		active: root.editing
		z: 5
		// by URL: the editor's file
		source: dock.active ? Qt.resolvedUrl("ToolDock.qml") : ""
	}

	// ── above: the name, the page, the zoom, the ways in ───────────────────
	Item {
		id: topBar

		anchors.left: parent.left
		anchors.right: parent.right
		height: root.narrow ? 50 : 56
		z: 10
		visible: !Pdf.presenting
		opacity: root.chrome ? 1 : 0
		transform: Translate {
			y: root.chrome ? 0 : -12

			Behavior on y {
				SpatialAnim {
					duration: Motion.long
				}
			}
		}

		Behavior on opacity {
			Anim {
				duration: Motion.long
			}
		}

		HoverHandler {
			id: topHover
		}

		Rectangle {
			anchors.fill: parent
			color: Qt.alpha(Pdf.night ? "#16171b" : Theme.bg, 0.9)

			Rectangle {
				anchors.left: parent.left
				anchors.right: parent.right
				anchors.bottom: parent.bottom
				height: 1
				color: Theme.outline
			}
		}

		// a thin line along the bottom: how far through the file
		Rectangle {
			anchors.left: parent.left
			anchors.bottom: parent.bottom
			height: 2
			width: Pdf.pageCount > 1 ? parent.width * (Pdf.page + 1) / Pdf.pageCount : 0
			color: Theme.primary
			opacity: 0.7

			Behavior on width {
				SpatialAnim {
					duration: Motion.long
				}
			}
		}

		Row {
			id: leftKeys

			anchors.left: parent.left
			anchors.leftMargin: 10
			anchors.verticalCenter: parent.verticalCenter
			spacing: 4

			BarButton {
				icon: "dock_left"
				tip: "Pages and contents (F9)"
				checked: Pdf.sidebar !== ""
				enabled: Pdf.current
				onClicked: Pdf.sidebar = Pdf.sidebar !== "" ? "" : "pages"
			}
		}

		Column {
			anchors.left: leftKeys.right
			anchors.leftMargin: 10
			anchors.right: middleKeys.left
			anchors.rightMargin: 12
			anchors.verticalCenter: parent.verticalCenter
			spacing: 1

			Row {
				width: parent.width
				spacing: 6

				StyledText {
					width: Math.min(implicitWidth, parent.width - (dirtyDot.visible ? 14 : 0))
					text: Pdf.current ? Pdf.title : "PDF"
					font.pixelSize: Theme.size.title
					font.weight: Font.DemiBold
					elide: Text.ElideRight
				}

				// unsaved changes
				Rectangle {
					id: dirtyDot

					anchors.verticalCenter: parent.verticalCenter
					width: 8
					height: 8
					radius: 4
					color: Theme.warning
					visible: Pdf.dirty
					scale: Pdf.dirty ? 1 : 0

					Behavior on scale {
						SpatialAnim {}
					}
				}
			}

			StyledText {
				width: parent.width
				visible: !root.narrow && text !== ""
				text: Pdf.current ? [Pdf.title !== Pdf.nameOf(Pdf.path) ? Pdf.nameOf(Pdf.path) + ".pdf" : "", Pdf.list.length > 1 ? `${Pdf.listIndex + 1} of ${Pdf.list.length} in the folder` : "",
					root.chapterNow].filter(x => x).join("  ·  ") : ""
				tone: Theme.textMuted
				font.pixelSize: Theme.size.small
				elide: Text.ElideRight
			}
		}

		// the page, the zoom, how pages lie, night
		Row {
			id: middleKeys

			anchors.right: rightKeys.left
			anchors.rightMargin: 10
			anchors.verticalCenter: parent.verticalCenter
			spacing: 6
			visible: Pdf.current && !Pdf.locked

			// the page: typed into, or walked with the arrows beside
			Rectangle {
				anchors.verticalCenter: parent.verticalCenter
				width: pageRow.implicitWidth + 8
				height: 34
				radius: 17
				color: Theme.layer1
				border.color: Theme.outline

				Row {
					id: pageRow

					anchors.centerIn: parent
					spacing: 0

					BarButton {
						small: true
						icon: "chevron_up"
						tip: "Page before (Page Up)"
						enabled: Pdf.page > 0
						onClicked: Pdf.previousPage()
					}

					Field {
						id: pageField

						anchors.verticalCenter: parent.verticalCenter
						width: Math.max(36, String(Pdf.pageCount).length * 9 + 22)
						height: 26
						clearable: false
						color: "transparent"
						input.horizontalAlignment: TextInput.AlignHCenter
						text: String(Pdf.page + 1)
						onAccepted: {
							const n = Number(pageField.text);
							// a page's own label ("iv", "A-3") goes too
							const byLabel = reader.docs.a ? reader.docs.a.pageIndexForLabel(pageField.text) : -1;
							if (n >= 1 && n <= Pdf.pageCount) Pdf.goTo(n - 1);
							else if (byLabel >= 0) Pdf.goTo(byLabel);
							root.takeFocus();
						}
						onEscapePressed: root.takeFocus()

						Connections {
							target: Pdf

							function onPageChanged() {
								if (!pageField.input.activeFocus) pageField.text = String(Pdf.page + 1);
							}
						}
					}

					StyledText {
						anchors.verticalCenter: parent.verticalCenter
						text: `/ ${Pdf.pageCount}`
						tone: Theme.textMuted
						tabular: true
						rightPadding: 4
					}

					BarButton {
						small: true
						icon: "chevron_down"
						tip: "Next page (Page Down)"
						enabled: Pdf.page < Pdf.pageCount - 1
						onClicked: Pdf.nextPage()
					}
				}
			}

			// the zoom: − 100 % +, the number opens the sizes
			Rectangle {
				anchors.verticalCenter: parent.verticalCenter
				visible: !root.narrow
				width: zoomRow.implicitWidth + 8
				height: 34
				radius: 17
				color: Theme.layer1
				border.color: Theme.outline

				Row {
					id: zoomRow

					anchors.centerIn: parent

					BarButton {
						small: true
						icon: "minus"
						tip: "Further (Ctrl+−)"
						onClicked: reader.zoomCentre(1 / 1.2)
					}

					Clickable {
						id: zoomPill

						anchors.verticalCenter: parent.verticalCenter
						width: zoomText.implicitWidth + 16
						height: 26
						radius: 13
						color: zoomPill.hovered ? Theme.layer2 : "transparent"
						onClicked: root.zoomMenu(zoomPill)

						StyledText {
							id: zoomText

							anchors.centerIn: parent
							text: Pdf.fit === "width" ? "Width" : (Pdf.fit === "page" ? "Page" : `${Math.round(Pdf.zoom * 100)} %`)
							tabular: true
							font.weight: Font.DemiBold
						}
					}

					BarButton {
						small: true
						icon: "plus"
						tip: "Closer (Ctrl++)"
						onClicked: reader.zoomCentre(1.2)
					}
				}
			}

			BarButton {
				anchors.verticalCenter: parent.verticalCenter
				visible: !root.narrow
				icon: Pdf.layout === "scroll" ? "view_agenda_outline" : (Pdf.layout === "two" ? "book_open_outline" : "book_open_page_variant_outline")
				tip: Pdf.layout === "scroll" ? "One under the other (L)" : (Pdf.layout === "two" ? "Two side by side (L)" : "A book (L)")
				onClicked: Pdf.cycleLayout()
			}

			BarButton {
				anchors.verticalCenter: parent.verticalCenter
				icon: Pdf.night ? "weather_night" : "white_balance_sunny"
				tip: Pdf.night ? "Day (N)" : "Night (N)"
				checked: Pdf.night
				onClicked: Pdf.night = !Pdf.night
			}
		}

		Row {
			id: rightKeys

			anchors.right: parent.right
			anchors.rightMargin: 10
			anchors.verticalCenter: parent.verticalCenter
			spacing: 4

			BarButton {
				visible: Pdf.current && !Pdf.locked
				icon: "magnify"
				tip: "Search (Ctrl+F)"
				checked: root.searchOpen
				onClicked: root.toggleSearch()
			}
			BarButton {
				visible: Pdf.current && !Pdf.locked && !root.editing && !root.narrow
				icon: "presentation_play"
				tip: "As slides (F5)"
				onClicked: Pdf.present(true)
			}

			// editing: undo, redo, save, done
			Row {
				spacing: 2
				visible: root.editing
				opacity: root.editing ? 1 : 0

				Behavior on opacity {
					Anim {}
				}

				BarButton {
					icon: "undo"
					tip: Pdf.canUndo ? `Undo ${Pdf.undoLabels[Pdf.undoLabels.length - 1] || ""} (Ctrl+Z)` : "Undo"
					enabled: Pdf.canUndo
					onClicked: Pdf.undo()
				}
				BarButton {
					icon: "redo"
					tip: "Redo (Ctrl+Shift+Z)"
					enabled: Pdf.canRedo
					onClicked: Pdf.redo()
				}
				TextButton {
					anchors.verticalCenter: parent.verticalCenter
					height: 34
					text: Pdf.saving ? "Saving" : "Save"
					icon: "content_save_outline"
					variant: Pdf.dirty ? "filled" : "tonal"
					busy: Pdf.saving
					enabled: Pdf.dirty && !Pdf.saving
					onActivated: Pdf.save()
				}
			}

			BarButton {
				visible: Pdf.current && !Pdf.locked
				icon: root.editing ? "check" : "pencil_outline"
				tip: root.editing ? "Done editing (E)" : "Edit (E)"
				checked: root.editing
				onClicked: Pdf.toggleEditing()
			}
			BarButton {
				id: shareKey

				visible: Pdf.current && !Pdf.locked && !root.narrow
				icon: "share_variant_outline"
				tip: Pdf.replyTarget ? "Send or reply with it" : "Send it"
				onClicked: root.shareMenu(shareKey)
			}
			BarButton {
				visible: Pdf.current
				icon: "dots_vertical"
				tip: "More"
				onClicked: root.moreMenu(this)
			}
			BarButton {
				icon: "close"
				tip: "Close (Esc)"
				onClicked: Pdf.close()
			}
		}
	}

	// the chapter the page belongs to (from the contents), for the line under the name
	readonly property string chapterNow: {
		let found = "";
		const walk = list => {
			for (const entry of list || []) {
				const i = Pdf.indexOf(entry.page);
				if (i >= 0 && i <= Pdf.page) found = entry.title;
				walk(entry.children);
			}
		};
		walk(Pdf.outlineNow);
		return found;
	}

	// ── search ─────────────────────────────────────────────────────────────
	SearchBar {
		id: searchBar

		anchors.right: parent.right
		anchors.rightMargin: root.dockWidth + 16
		y: topBar.height + 10
		z: 11
		open: root.searchOpen
		onClosed: {
			root.searchOpen = false;
			root.takeFocus();
		}
	}

	function toggleSearch() {
		root.searchOpen = !root.searchOpen;
		if (root.searchOpen) {
			const text = Pdf.selectionText;
			if (text && text.length < 80) Pdf.searchText = text.trim();
			searchBar.focusField();
		} else root.takeFocus();
	}

	// ── what floats above the pages ────────────────────────────────────────
	SelectionMenu {
		id: selectionMenu

		z: 12
		bounds: Qt.rect(0, topBar.height, root.width - root.dockWidth, root.height - topBar.height)
	}

	LinkPeek {
		id: peek

		z: 13
		reader: root.pages
	}

	// the place it was left: there again, with the start one click away
	Clickable {
		id: resumeChip

		property bool live: false

		anchors.horizontalCenter: parent.horizontalCenter
		y: topBar.height + 14
		z: 11
		width: resumeRow.implicitWidth + 28
		height: 36
		radius: 18
		color: Theme.primaryContainer
		opacity: resumeChip.live ? 1 : 0
		visible: opacity > 0.01
		scale: resumeChip.live ? 1 : 0.9
		onClicked: {
			resumeChip.live = false;
			Pdf.goTo(0);
		}

		Behavior on opacity {
			Anim {}
		}
		Behavior on scale {
			SpatialAnim {}
		}

		Row {
			id: resumeRow

			anchors.centerIn: parent
			spacing: 8

			Glyph {
				anchors.verticalCenter: parent.verticalCenter
				icon: "bookmark_outline"
				size: 16
				color: Theme.primary
			}
			StyledText {
				anchors.verticalCenter: parent.verticalCenter
				text: `Back at page ${Pdf.resumedFrom + 1}  ·  To the start`
			}
		}

		Timer {
			id: resumeTimer

			interval: 7000
			onTriggered: resumeChip.live = false
		}

		Connections {
			target: Pdf

			function onOpened() {
				// PDFium draws pages without their annotations: the file's marks come out and are drawn by the overlay
				if ((Pdf.meta?.annots ?? 0) > 0 && !Pdf.stripped) Pdf.strip(false);
				resumeChip.live = Pdf.resumedFrom > 0;
				if (resumeChip.live) resumeTimer.restart();
				selectionMenu.hide();
				peek.hide();
			}
		}
	}

	// the helper's work: what it does, how far, a way to stop it
	Column {
		anchors.left: parent.left
		anchors.bottom: parent.bottom
		anchors.leftMargin: (root.narrow ? 0 : root.sidebarShown) + 16
		anchors.bottomMargin: 16
		spacing: 6
		z: 11

		Repeater {
			model: Pdf.runningJobs

			Rectangle {
				id: jobChip

				required property var modelData

				width: jobRow.implicitWidth + 22
				height: 36
				radius: 18
				color: Qt.alpha(Theme.bg, 0.94)
				border.color: Theme.outline

				Row {
					id: jobRow

					anchors.centerIn: parent
					spacing: 8

					Item {
						anchors.verticalCenter: parent.verticalCenter
						width: 20
						height: 20

						Spinner {
							anchors.fill: parent
							visible: (jobChip.modelData.progress ?? 0) <= 0
						}
						Ring {
							anchors.fill: parent
							visible: (jobChip.modelData.progress ?? 0) > 0
							value: jobChip.modelData.progress ?? 0
							thickness: 3
						}
					}
					StyledText {
						anchors.verticalCenter: parent.verticalCenter
						text: jobChip.modelData.text ? `${jobChip.modelData.label} · ${jobChip.modelData.text}` : jobChip.modelData.label
					}
					BarButton {
						small: true
						icon: "close"
						tip: "Stop"
						onClicked: Pdf.cancelJob(jobChip.modelData.id)
					}
				}
			}
		}
	}

	// ── nothing open, it would not open, or it is locked ──────────────────
	Column {
		anchors.centerIn: parent
		spacing: 14
		visible: (!Pdf.current || Pdf.error !== "") && !Pdf.loading
		width: Math.min(parent.width - 48, 420)

		Glyph {
			anchors.horizontalCenter: parent.horizontalCenter
			icon: Pdf.error ? "file_alert_outline" : "file_pdf_box"
			size: 54
			color: Theme.textSubtle
		}

		StyledText {
			anchors.horizontalCenter: parent.horizontalCenter
			width: parent.width
			horizontalAlignment: Text.AlignHCenter
			wrapMode: Text.WordWrap
			text: Pdf.error || "Drop a PDF here, or open one in Files"
			tone: Theme.textMuted
			font.pixelSize: Theme.size.title
		}

		Column {
			anchors.horizontalCenter: parent.horizontalCenter
			spacing: 6
			visible: !Pdf.current && Pdf.recent.length > 0

			Repeater {
				model: Pdf.recent.slice(0, 5)

				Clickable {
					id: recentRow

					required property string modelData

					width: 380
					height: 44
					radius: Theme.radius.medium
					color: recentRow.hovered ? Theme.layer2 : Theme.layer1
					onClicked: Pdf.open(recentRow.modelData)

					Row {
						anchors.fill: parent
						anchors.leftMargin: 12
						anchors.rightMargin: 12
						spacing: 10

						Glyph {
							anchors.verticalCenter: parent.verticalCenter
							icon: "file_pdf_box"
							size: 20
							color: Theme.primary
						}
						StyledText {
							anchors.verticalCenter: parent.verticalCenter
							width: parent.width - 30
							text: Pdf.nameOf(recentRow.modelData)
							elide: Text.ElideMiddle
						}
					}
				}
			}
		}
	}

	Spinner {
		anchors.centerIn: parent
		width: 40
		height: 40
		visible: opacity > 0.01
		opacity: Pdf.loading ? 1 : 0

		Behavior on opacity {
			Anim {}
		}
	}

	PasswordSheet {
		id: passwordSheet

		anchors.fill: parent
		z: 30
		onDone: root.takeFocus()
	}

	// ── slides ─────────────────────────────────────────────────────────────
	Loader {
		anchors.fill: parent
		z: 40
		active: Pdf.presenting
		sourceComponent: Presentation {
			reader: root.pages
			onLeave: {
				Pdf.present(false);
				root.takeFocus();
			}
		}
		onLoaded: item.forceActiveFocus()
	}

	// ── what the shell found or does with it ───────────────────────────────
	Column {
		anchors.left: parent.left
		anchors.leftMargin: (root.narrow ? 0 : root.sidebarShown) + 16
		y: topBar.height + 12
		z: 11
		spacing: 8
		visible: !Pdf.presenting

		// an invoice: what it asks, copied at a click, a task to pay it, filed
		Rectangle {
			id: invoiceChip

			visible: !!Pdf.invoice && !root.editing
			width: invoiceRow.implicitWidth + 16
			height: 38
			radius: 19
			color: Qt.alpha(Theme.bg, 0.95)
			border.color: Theme.outline
			opacity: visible ? 1 : 0

			Behavior on opacity {
				Anim {}
			}

			Row {
				id: invoiceRow

				anchors.centerIn: parent
				spacing: 4

				Glyph {
					anchors.verticalCenter: parent.verticalCenter
					icon: "receipt_outline"
					size: 17
					color: Theme.primary
				}
				StyledText {
					anchors.verticalCenter: parent.verticalCenter
					leftPadding: 4
					rightPadding: 4
					text: {
						const i = Pdf.invoice;
						if (!i) return "";
						const amount = i.amount ? `${Number(i.amount).toLocaleString(Qt.locale(), "f", 2)} ${i.currency || "€"}` : "Invoice";
						return i.due ? `${amount}  ·  due ${Qt.formatDate(new Date(i.due), "d MMM")}` : amount;
					}
					font.weight: Font.DemiBold
				}
				BarButton {
					small: true
					visible: !!Pdf.invoice?.amount
					icon: "currency_eur"
					tip: "Copy the amount"
					onClicked: Pdf.copyInvoice("amount")
				}
				BarButton {
					small: true
					visible: !!Pdf.invoice?.iban
					icon: "bank_outline"
					tip: "Copy the IBAN"
					onClicked: Pdf.copyInvoice("iban")
				}
				BarButton {
					small: true
					visible: !!Pdf.invoice?.reference || !!Pdf.invoice?.number
					icon: "pound"
					tip: "Copy the reference"
					onClicked: Pdf.copyInvoice(Pdf.invoice?.reference ? "reference" : "number")
				}
				BarButton {
					small: true
					icon: "bell_plus_outline"
					tip: "A task to pay it"
					onClicked: Pdf.remindInvoice()
				}
				BarButton {
					small: true
					icon: "folder_account_outline"
					tip: Pdf.invoiceCustomer ? `File it under ${Pdf.invoiceCustomer.name}` : "File it with the invoices"
					onClicked: Pdf.fileInvoice()
				}
			}
		}

		// reading aloud, thinking
		Rectangle {
			visible: Pdf.speaking || Pdf.asking
			width: busyRow.implicitWidth + 18
			height: 36
			radius: 18
			color: Theme.primaryContainer

			Row {
				id: busyRow

				anchors.centerIn: parent
				spacing: 8

				Spinner {
					anchors.verticalCenter: parent.verticalCenter
					width: 16
					height: 16
					visible: Pdf.asking
				}
				Glyph {
					anchors.verticalCenter: parent.verticalCenter
					visible: Pdf.speaking
					icon: "account_voice"
					size: 16
					color: Theme.primary
				}
				StyledText {
					anchors.verticalCenter: parent.verticalCenter
					text: Pdf.speaking ? "Reading aloud" : "Thinking…"
				}
				BarButton {
					small: true
					visible: Pdf.speaking
					icon: "stop"
					tip: "Stop"
					onClicked: Pdf.stopSpeaking()
				}
			}
		}
	}

	// the model's answer (translated, explained): to read, copy or keep
	Item {
		id: answer

		property string title: ""
		property string text: ""
		property bool open: false

		anchors.fill: parent
		z: 31
		visible: answerCard.opacity > 0.01

		Rectangle {
			anchors.fill: parent
			color: Theme.scrim
			opacity: answer.open ? 1 : 0

			Behavior on opacity {
				Anim {}
			}

			MouseArea {
				anchors.fill: parent
				onClicked: answer.open = false
			}
		}

		Rectangle {
			id: answerCard

			anchors.centerIn: parent
			width: Math.min(parent.width - 40, 560)
			height: Math.min(parent.height - 80, answerColumn.implicitHeight + 40)
			radius: Theme.radius.huge
			color: Theme.bg
			border.color: Theme.outline
			opacity: answer.open ? 1 : 0
			scale: answer.open ? 1 : 0.94

			Behavior on opacity {
				Anim {}
			}
			Behavior on scale {
				SpatialAnim {}
			}

			Column {
				id: answerColumn

				anchors.fill: parent
				anchors.margins: 20
				spacing: 12

				StyledText {
					text: answer.title || "The answer"
					font.pixelSize: Theme.size.title
					font.weight: Font.DemiBold
				}

				Flickable {
					width: parent.width
					height: Math.min(answerText.implicitHeight, answerCard.parent.height - 220)
					contentHeight: answerText.implicitHeight
					clip: true

					TextEdit {
						id: answerText

						width: parent.width
						text: answer.text
						readOnly: true
						selectByMouse: true
						wrapMode: TextEdit.Wrap
						color: Theme.text
						font.family: Theme.fontFamily
						font.pixelSize: Theme.size.body
					}
				}

				Row {
					anchors.right: parent.right
					spacing: 8

					TextButton {
						text: "As a note"
						icon: "note_outline"
						variant: "ghost"
						onActivated: {
							Pdf.toNote(answer.text, Pdf.page + 1);
							answer.open = false;
						}
					}
					TextButton {
						text: "Copy"
						icon: "content_copy"
						variant: "tonal"
						onActivated: {
							Quickshell.execDetached(["wl-copy", "--", answer.text]);
							Sounds.play("copied");
							answer.open = false;
						}
					}
					TextButton {
						text: "Close"
						variant: "filled"
						onActivated: answer.open = false
					}
				}
			}
		}
	}

	// ── toasts ─────────────────────────────────────────────────────────────
	Rectangle {
		id: toast

		function show(text, icon) {
			toastText.text = text;
			toastGlyph.icon = icon || "information_outline";
			toast.opacity = 1;
			toast.lift = 0;
			toastTimer.restart();
		}

		property real lift: 10

		anchors.horizontalCenter: parent.horizontalCenter
		y: root.height - height - 28 + toast.lift
		width: Math.min(root.width - 24, toastRow.implicitWidth + 30)
		height: 40
		radius: 20
		color: Qt.rgba(0.07, 0.07, 0.08, 0.92)
		opacity: 0
		visible: opacity > 0
		z: 70

		Behavior on opacity {
			Anim {}
		}
		Behavior on lift {
			SpatialAnim {}
		}

		Row {
			id: toastRow

			anchors.centerIn: parent
			spacing: 10

			Glyph {
				id: toastGlyph

				anchors.verticalCenter: parent.verticalCenter
				size: 18
				color: Theme.legible(Theme.primary, 3)
				surface: "transparent"
			}

			StyledText {
				id: toastText

				anchors.verticalCenter: parent.verticalCenter
				tone: "white"
				surface: "transparent"
			}
		}

		Timer {
			id: toastTimer

			interval: 3200
			onTriggered: {
				toast.opacity = 0;
				toast.lift = 10;
			}
		}
	}

	Connections {
		target: Pdf

		function onSaid(text, icon) {
			toast.show(text, icon);
		}

		function onAct(name) {
			root.act(name);
		}

		function onAiAnswer(title, text) {
			answer.title = title;
			answer.text = text;
			answer.open = true;
		}

		function onPasswordWanted(path) {
			passwordSheet.ask(path);
		}

		function onEditingChanged() {
			selectionMenu.hide();
			root.wake();
		}
	}

	// ── files dropped on the window ────────────────────────────────────────
	DropArea {
		id: drop

		anchors.fill: parent
		keys: ["text/uri-list"]
		z: 20
		onDropped: event => {
			const paths = (event.urls || []).map(u => Pdf.plainPath(u.toString()));
			if (paths.length === 0) return;
			// while editing, PDFs and pictures go in at the page they were dropped on
			if (root.editing && Pdf.current) {
				const at = Pdf.page + 1;
				for (const p of paths.slice().reverse()) Pdf.insertFile(p, at);
				return;
			}
			const pdfs = paths.filter(p => Pdf.isPdf(p));
			if (pdfs.length > 0) Pdf.openMany(pdfs);
		}

		Rectangle {
			anchors.fill: parent
			anchors.margins: 10
			radius: Theme.radius.large
			color: Qt.alpha(Theme.primary, 0.08)
			border.color: Theme.primary
			border.width: 2
			opacity: drop.containsDrag ? 1 : 0
			visible: opacity > 0.01

			Behavior on opacity {
				Anim {}
			}

			StyledText {
				anchors.centerIn: parent
				text: root.editing ? `Put in after page ${Pdf.page + 1}` : "Open"
				font.pixelSize: Theme.size.heading
				font.weight: Font.DemiBold
				tone: Theme.primary
			}
		}
	}

	// ── menus ──────────────────────────────────────────────────────────────
	property real calmUntil: 0

	FileMenu {
		id: menu

		anchors.fill: parent
		z: 50
		onClosed: {
			root.calmUntil = Date.now() + 300;
			root.takeFocus();
		}
	}

	function anchorOf(item) {
		const p = item.mapToItem(root, 0, 0);
		return { x: p.x, y: p.y + item.height + 4 };
	}

	function zoomMenu(item) {
		const at = root.anchorOf(item);
		const sizes = [0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4];
		menu.show([
			{ label: "Fit the width", icon: "arrow_expand_horizontal", shortcut: "W", checked: Pdf.fit === "width", run: () => Pdf.fit = "width" },
			{ label: "Fit the page", icon: "fit_to_page_outline", shortcut: "P", checked: Pdf.fit === "page", run: () => Pdf.fit = "page" },
			{ separator: true }
		].concat(sizes.map(z => ({ label: `${Math.round(z * 100)} %`, checked: Pdf.fit === "" && Math.abs(Pdf.zoom - z) < 0.01, shortcut: z === 1 ? "Ctrl+0" : "", run: () => {
			reader.anchorAt(reader.width / 2, reader.height / 3);
			Pdf.setZoom(z);
		} }))).concat([
			{ separator: true },
			{ label: "One under the other", icon: "view_agenda_outline", checked: Pdf.layout === "scroll", run: () => Pdf.layout = "scroll" },
			{ label: "Two side by side", icon: "book_open_outline", checked: Pdf.layout === "two", run: () => Pdf.layout = "two" },
			{ label: "A book", icon: "book_open_page_variant_outline", checked: Pdf.layout === "book", run: () => Pdf.layout = "book" }
		]), at.x - 60, at.y);
	}

	function moreMenu(item) {
		const at = root.anchorOf(item);
		const path = Pdf.path;
		menu.show([
			{ label: "Save", icon: "content_save_outline", shortcut: "Ctrl+S", enabled: Pdf.dirty, run: () => Pdf.save() },
			{ label: "Save a copy", icon: "content_save_all_outline", run: () => Pdf.saveCopy() },
			{ label: "Save as…", icon: "content_save_edit_outline", shortcut: "Ctrl+Shift+S", run: () => Pdf.chooseSaveAs() },
			{ label: "Back to the saved file", icon: "restore", enabled: Pdf.dirty, danger: true, run: () => Pdf.revert() },
			{ separator: true },
			{ label: "Search", icon: "magnify", shortcut: "Ctrl+F", run: () => root.toggleSearch() },
			{ label: "As slides", icon: "presentation_play", shortcut: "F5", run: () => Pdf.present(true) },
			{ label: "Copy this page as a picture", icon: "content_copy", run: () => Pdf.copyPage(Pdf.page) },
			{ separator: true },
			{ label: "Summarize", icon: "creation", run: () => Pdf.summarize() },
			{ label: "Ask the AI about it", icon: "chat_question_outline", run: () => Pdf.askAi("") },
			{ label: Pdf.speaking ? "Stop reading aloud" : "Read this page aloud", icon: Pdf.speaking ? "stop" : "account_voice", run: () => Pdf.readAloud() },
			{ label: "Send it", icon: "share_variant_outline", children: () => root.shareEntries() },
			{ label: "Look", icon: "eye_outline", children: [
				{ label: "Night", checked: Pdf.night, shortcut: "N", run: () => Pdf.night = !Pdf.night },
				{ label: "Night for every file when the desktop is dark", checked: Pdf.setting("nightAuto", false), run: () => Pdf.setSetting("nightAuto", !Pdf.setting("nightAuto", false)) },
				{ label: "The page glows behind", checked: Pdf.setting("glow", true), run: () => Pdf.setSetting("glow", !Pdf.setting("glow", true)) },
				{ label: "The bar fades while reading", checked: Pdf.setting("barsFade", true), run: () => Pdf.setSetting("barsFade", !Pdf.setting("barsFade", true)) },
				{ label: "Pages a link leads to peek out", checked: Pdf.setting("hoverLinks", true), run: () => Pdf.setSetting("hoverLinks", !Pdf.setting("hoverLinks", true)) },
				{ label: "Take up where it was left", checked: Pdf.setting("resume", true), run: () => Pdf.setSetting("resume", !Pdf.setting("resume", true)) }
			] },
			{ separator: true },
			{ label: "Show in Files", icon: "folder_open_outline", run: () => Files.reveal(path) },
			{ label: "Open with another app", icon: "open_in_app", run: () => Quickshell.execDetached(["gio", "open", path]) },
			{ label: "Copy the path", icon: "content_copy", run: () => Quickshell.execDetached(["wl-copy", "--", path]) },
			{ separator: true },
			{ label: Pdf.fullscreen ? "Leave fullscreen" : "Fullscreen", icon: Pdf.fullscreen ? "fullscreen_exit" : "fullscreen", shortcut: "F11", run: () => Pdf.toggleFullscreen() },
			{ label: "Close", icon: "close", shortcut: "Esc", run: () => Pdf.close() }
		], at.x - 230, at.y);
	}

	// where it can go: back to the mail it came with, a new mail, the shell's places, the shelf
	function shareEntries() {
		const out = [];
		if (Pdf.replyTarget) out.push({ label: "Reply with it", icon: "reply_outline", run: () => Pdf.replyWithIt() });
		out.push({ label: "By mail", icon: "email_outline", run: () => Pdf.sendByMail() });
		for (const entry of Pdf.shareEntries()) if (!/mail/i.test(entry.label ?? "")) out.push(entry);
		out.push({ separator: true });
		out.push({ label: "On the shelf", icon: "tray_arrow_down", run: () => Pdf.documentToShelf() });
		return out;
	}

	function shareMenu(item) {
		const at = root.anchorOf(item);
		menu.show(root.shareEntries(), at.x - 200, at.y);
	}

	// a right click on a page
	function pageMenu(pageId, px, py, x, y) {
		const index = Pdf.indexOf(pageId);
		const text = Pdf.selection?.page === pageId ? Pdf.selectionText : "";
		const entries = [];
		if (text) {
			entries.push({ label: "Copy", icon: "content_copy", shortcut: "Ctrl+C", run: () => root.copySelection() });
			entries.push({ label: "Mark", icon: "marker", run: () => Pdf.markSelection("highlight") });
			entries.push({ label: "Search for it", icon: "magnify", run: () => {
				Pdf.searchText = text.trim();
				root.searchOpen = true;
			} });
			entries.push({ separator: true });
		}
		entries.push({ label: "A note here", icon: "note_plus_outline", run: () => {
			Pdf.startEditing("annotate");
			Pdf.addItem({ kind: "note", page: pageId, at: [px, py], text: "", color: "#ffd54f" });
		} });
		entries.push({ label: "Copy the page as a picture", icon: "image_outline", run: () => Pdf.copyPage(index) });
		entries.push({ label: "The page to the shelf", icon: "tray_arrow_down", run: () => Pdf.toShelf([pageId]) });
		entries.push({ label: "Read it aloud", icon: "account_voice", run: () => {
			Pdf.page = index;
			Pdf.readAloud();
		} });
		entries.push({ label: "Turn the page", icon: "rotate_right", run: () => Pdf.rotatePages([pageId], 90) });
		entries.push({ label: "Edit", icon: "pencil_outline", shortcut: "E", run: () => Pdf.startEditing("annotate") });
		entries.push({ label: "Slides from here", icon: "presentation_play", run: () => {
			Pdf.page = index;
			Pdf.present(true);
		} });
		menu.show(entries, x, y);
	}

	function copySelection() {
		if (Pdf.selectionText) Pdf.selectionAction("copy");
	}

	// ── keys ───────────────────────────────────────────────────────────────
	function act(name) {
		if (name.startsWith("tool-")) return Pdf.useTool(name.slice(5));
		if (name.startsWith("draw-")) {
			if (!Pdf.editing) Pdf.startEditing("annotate");
			Pdf.draw = name.slice(5);
			return;
		}
		switch (name) {
		case "edit": return Pdf.toggleEditing();
		case "read": return Pdf.stopEditing();
		case "search": return root.toggleSearch();
		case "search-next": return Pdf.searchStep(1);
		case "search-previous": return Pdf.searchStep(-1);
		case "sidebar": return Pdf.sidebar = Pdf.sidebar !== "" ? "" : "pages";
		case "pages":
		case "outline":
		case "notes":
		case "files": return Pdf.sidebar = Pdf.sidebar === name ? "" : name;
		case "night": return Pdf.night = !Pdf.night;
		case "layout": return Pdf.cycleLayout();
		case "layout-scroll": return Pdf.layout = "scroll";
		case "layout-two": return Pdf.layout = "two";
		case "layout-book": return Pdf.layout = "book";
		case "fit-width": return Pdf.fit = "width";
		case "fit-page": return Pdf.fit = "page";
		case "zoom-in": return reader.zoomCentre(1.2);
		case "zoom-out": return reader.zoomCentre(1 / 1.2);
		case "zoom-reset":
			reader.anchorAt(reader.width / 2, reader.height / 3);
			return Pdf.setZoom(1);
		case "present": return Pdf.present();
		case "fullscreen": return Pdf.toggleFullscreen();
		case "undo": return Pdf.undo();
		case "redo": return Pdf.redo();
		case "save": return Pdf.save();
		case "save-copy": return Pdf.saveCopy();
		case "save-as": return Pdf.chooseSaveAs();
		case "revert": return Pdf.revert();
		case "next-page": return Pdf.nextPage();
		case "previous-page": return Pdf.previousPage();
		case "first": return Pdf.goTo(0);
		case "last": return Pdf.goTo(Pdf.pageCount - 1);
		case "next-file": return Pdf.next();
		case "previous-file": return Pdf.previous();
		case "back": return reader.goBack();
		case "rotate": return Pdf.rotatePages(Pdf.selectedPages.length > 0 ? Pdf.selectedPages : [Pdf.pages[Pdf.page]?.id], 90);
		case "delete-page": return Pdf.deletePages(Pdf.selectedPages.length > 0 ? Pdf.selectedPages : [Pdf.pages[Pdf.page]?.id]);
		case "copy-page": return Pdf.copyPage(Pdf.page);
		case "copy": return root.copySelection();
		case "mark": return Pdf.markSelection("highlight");
		case "select-page": return reader.selectPage();
		case "menu": return root.moreMenu(rightKeys);
		case "close": return Pdf.close();
		}
	}

	Keys.onPressed: event => {
		const ctrl = event.modifiers & Qt.ControlModifier, shift = event.modifiers & Qt.ShiftModifier, alt = event.modifiers & Qt.AltModifier;
		root.wake();
		// the editor's dock takes its keys first
		if (root.editing && dock.item && typeof dock.item.handleKey === "function" && dock.item.handleKey(event)) {
			event.accepted = true;
			return;
		}
		let handled = true;
		const book = Pdf.layout === "book";
		switch (event.key) {
		case Qt.Key_PageDown:
		case Qt.Key_Space:
			if (event.key === Qt.Key_Space && shift) Pdf.previousPage();
			else if (book) reader.bookStep(1);
			else Pdf.nextPage();
			break;
		case Qt.Key_PageUp:
		case Qt.Key_Backspace:
			if (book) reader.bookStep(-1);
			else Pdf.previousPage();
			break;
		case Qt.Key_Down:
			if (book) reader.bookStep(1);
			else reader.flickable.contentY = Math.min(reader.flickable.contentHeight - reader.flickable.height, reader.flickable.contentY + 60);
			break;
		case Qt.Key_Up:
			if (book) reader.bookStep(-1);
			else reader.flickable.contentY = Math.max(0, reader.flickable.contentY - 60);
			break;
		case Qt.Key_Right:
			if (alt) handled = false;
			else if (book) reader.bookStep(1);
			else if (reader.flickable.contentWidth > reader.flickable.width + 2) reader.flickable.contentX = Math.min(reader.flickable.contentWidth - reader.flickable.width, reader.flickable.contentX + 60);
			else Pdf.nextPage();
			break;
		case Qt.Key_Left:
			if (alt) reader.goBack();
			else if (book) reader.bookStep(-1);
			else if (reader.flickable.contentWidth > reader.flickable.width + 2) reader.flickable.contentX = Math.max(0, reader.flickable.contentX - 60);
			else Pdf.previousPage();
			break;
		case Qt.Key_Home:
			Pdf.goTo(0);
			break;
		case Qt.Key_End:
			Pdf.goTo(Pdf.pageCount - 1);
			break;
		case Qt.Key_F:
			if (ctrl) root.toggleSearch();
			else handled = false;
			break;
		case Qt.Key_G:
			if (ctrl) Pdf.searchStep(shift ? -1 : 1);
			else handled = false;
			break;
		case Qt.Key_Plus:
		case Qt.Key_Equal:
			if (ctrl || event.key === Qt.Key_Plus) reader.zoomCentre(1.2);
			else handled = false;
			break;
		case Qt.Key_Minus:
			reader.zoomCentre(1 / 1.2);
			break;
		case Qt.Key_0:
			if (ctrl) root.act("zoom-reset");
			else handled = false;
			break;
		case Qt.Key_W:
			if (ctrl) Pdf.close();
			else Pdf.fit = "width";
			break;
		case Qt.Key_P:
			if (!ctrl) Pdf.fit = "page";
			else handled = false;
			break;
		case Qt.Key_L:
			Pdf.cycleLayout();
			break;
		case Qt.Key_N:
			Pdf.night = !Pdf.night;
			break;
		case Qt.Key_E:
			Pdf.toggleEditing();
			break;
		case Qt.Key_F5:
			Pdf.present(true);
			break;
		case Qt.Key_F9:
			Pdf.sidebar = Pdf.sidebar !== "" ? "" : "pages";
			break;
		case Qt.Key_F11:
			Pdf.toggleFullscreen();
			break;
		case Qt.Key_Z:
			if (ctrl && shift) Pdf.redo();
			else if (ctrl) Pdf.undo();
			else handled = false;
			break;
		case Qt.Key_Y:
			if (ctrl) Pdf.redo();
			else handled = false;
			break;
		case Qt.Key_S:
			if (ctrl && shift) Pdf.chooseSaveAs();
			else if (ctrl) Pdf.save();
			else handled = false;
			break;
		case Qt.Key_C:
			if (ctrl && Pdf.selectionText) root.copySelection();
			else handled = false;
			break;
		case Qt.Key_A:
			if (ctrl) reader.selectPage();
			else handled = false;
			break;
		case Qt.Key_H:
			if (Pdf.selectionText) Pdf.markSelection("highlight");
			else handled = false;
			break;
		case Qt.Key_Escape:
			if (Date.now() < root.calmUntil) break;
			if (answer.open) answer.open = false;
			else if (root.searchOpen) {
				root.searchOpen = false;
				Pdf.searchText = "";
			} else if (Pdf.selection) {
				Pdf.selection = null;
				selectionMenu.hide();
			} else if (Pdf.fullscreen) Pdf.toggleFullscreen();
			else if (root.editing) Pdf.stopEditing();
			else Pdf.close();
			break;
		default:
			handled = false;
		}
		event.accepted = handled;
	}

	// ── little parts ───────────────────────────────────────────────────────
	component BarButton: IconButton {
		id: bar

		property string tip: ""
		property bool small: false

		implicitWidth: bar.small ? 26 : 36
		implicitHeight: bar.small ? 26 : 36
		iconSize: bar.small ? 15 : 19

		Rectangle {
			anchors.horizontalCenter: parent.horizontalCenter
			y: parent.height + 8
			width: tipText.implicitWidth + 16
			height: 26
			radius: 13
			color: Qt.rgba(0.06, 0.06, 0.07, 0.92)
			opacity: bar.hovered && bar.tip !== "" ? 1 : 0
			visible: opacity > 0.01
			z: 100

			Behavior on opacity {
				SequentialAnimation {
					PauseAnimation {
						duration: bar.hovered ? 500 : 0
					}
					Anim {
						duration: Motion.short
					}
				}
			}

			StyledText {
				id: tipText

				anchors.centerIn: parent
				text: bar.tip
				tone: "white"
				surface: "transparent"
				font.pixelSize: Theme.size.small
			}
		}
	}
}
