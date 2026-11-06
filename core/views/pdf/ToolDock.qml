pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Quickshell
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "../video"

// The editor's tools on the right of the PDF window: a slim rail of them and
// the chosen one's panel sliding out beside it. Every panel is built when it
// is first opened and kept, so what was typed or scrolled in it stays. The
// dock also lays the organizer (PageGrid), the comparison (Compare) and the
// panels' sheets over the whole window.
Item {
	id: root

	readonly property real railWidth: 52
	readonly property real panelWidth: Pdf.tool !== "" ? Math.min(360, Math.max(290, (root.Window.width || 1100) * 0.27)) : 0

	width: root.railWidth + panelShown
	property real panelShown: root.panelWidth

	Behavior on panelShown {
		SpatialAnim {}
	}

	readonly property var tools: [
		{ id: "annotate", label: "Mark", icon: "draw", file: "ToolAnnotate.qml", tip: "Mark, draw, notes – real annotations every viewer shows" },
		{ id: "pages", label: "Pages", icon: "file_document_multiple_outline", file: "ToolPages.qml", tip: "Order, turn, remove, add, split, put together (G: all at once)" },
		{ id: "text", label: "Text", icon: "format_text", file: "ToolText.qml", tip: "Correct words, cover things, write on the page" },
		{ id: "forms", label: "Forms", icon: "form_textbox", file: "ToolForms.qml", tip: "Fill in, make new fields" },
		{ id: "sign", label: "Sign", icon: "draw_pen", file: "ToolSign.qml", tip: "Your signature: drawn, typed, from the phone; or with a certificate" },
		{ id: "redact", label: "Black", icon: "eye_off_outline", file: "ToolRedact.qml", tip: "Black out for good: boxes, words, IBANs, mail addresses …" },
		{ id: "stamp", label: "Stamp", icon: "stamper", file: "ToolStamp.qml", tip: "Paid, Approved, Draft … or your own picture" },
		{ id: "layout", label: "Layout", icon: "page_layout_header_footer", file: "ToolLayout.qml", tip: "Watermark, page numbers, header and footer, Bates" },
		{ id: "crop", label: "Crop", icon: "crop", file: "ToolCrop.qml", tip: "Cut the margins off" },
		{ id: "export", label: "Export", icon: "export_variant", file: "ToolExport.qml", tip: "Smaller, PDF/A, grayscale, pictures, text, Office" },
		{ id: "security", label: "Lock", icon: "lock_outline", file: "ToolSecurity.qml", tip: "Passwords, what may be done, clean hidden data" },
		{ id: "info", label: "Info", icon: "information_outline", file: "ToolInfo.qml", tip: "Details, contents, attachments, earlier saves" },
		{ id: "compare", label: "Compare", icon: "compare", file: "ToolCompare.qml", tip: "What changed against another version" },
		{ id: "scan", label: "Scans", icon: "scanner", file: "ToolScan.qml", tip: "Make scans readable (OCR), straight and clean" },
		{ id: "ai", label: "Ask", icon: "creation", file: "ToolAi.qml", tip: "Summaries, questions, tables, names" }
	]

	// the window's keys come here first while editing
	function handleKey(event) {
		const ctrl = (event.modifiers & Qt.ControlModifier) !== 0;
		if (ctrl && event.key === Qt.Key_Z && !(event.modifiers & Qt.ShiftModifier)) {
			Pdf.undo();
			return true;
		}
		if (ctrl && (event.key === Qt.Key_Y || (event.key === Qt.Key_Z && (event.modifiers & Qt.ShiftModifier)))) {
			Pdf.redo();
			return true;
		}
		if (root.sheetOpen && event.key === Qt.Key_Escape) {
			root.closeSheet();
			return true;
		}
		return Pdf.editKey(event.key, event.modifiers);
	}

	// ── a sheet over the window (the signature pad, the phone's QR) ────────
	property bool sheetOpen: false

	function sheet(file, properties) {
		sheetLoader.setSource(Qt.resolvedUrl(file), Object.assign({ dock: root }, properties || {}));
		root.sheetOpen = true;
	}

	function closeSheet() {
		root.sheetOpen = false;
	}

	// ── the panel ──────────────────────────────────────────────────────────
	Rectangle {
		id: panel

		anchors.right: rail.left
		anchors.top: parent.top
		anchors.bottom: parent.bottom
		width: root.panelShown
		color: Theme.layer1
		clip: true

		Rectangle {
			width: 1
			height: parent.height
			color: Theme.outline
		}

		Repeater {
			model: root.tools.concat([{ id: "history", file: "" }])

			// the history is a pane of this file, the tools are files of their own

			Loader {
				id: slot

				required property var modelData
				readonly property bool shown: Pdf.tool === slot.modelData.id

				x: 1
				width: root.panelWidth > 0 ? root.panelWidth - 1 : 320
				height: panel.height
				active: slot.shown || slot.item !== null
				visible: opacity > 0.01
				opacity: slot.shown ? 1 : 0
				Component.onCompleted: {
					if (slot.modelData.id === "history") slot.sourceComponent = historyPane;
					else if (slot.active) slot.source = Qt.resolvedUrl(slot.modelData.file);
				}
				onActiveChanged: if (slot.active && slot.modelData.file && slot.source.toString() === "") slot.source = Qt.resolvedUrl(slot.modelData.file)
				onLoaded: if ("dock" in slot.item) slot.item.dock = root
				transform: Translate {
					x: slot.shown ? 0 : 24

					Behavior on x {
						SpatialAnim {}
					}
				}

				Behavior on opacity {
					Anim {}
				}
			}
		}
	}

	// ── the rail ───────────────────────────────────────────────────────────
	Rectangle {
		id: rail

		anchors.right: parent.right
		anchors.top: parent.top
		anchors.bottom: parent.bottom
		width: root.railWidth
		color: Theme.layer2

		Flickable {
			anchors.fill: parent
			anchors.bottomMargin: bottomKeys.height + 8
			contentHeight: toolColumn.implicitHeight + 20
			clip: true
			boundsBehavior: Flickable.StopAtBounds

			Column {
				id: toolColumn

				anchors.horizontalCenter: parent.horizontalCenter
				y: 8
				spacing: 2

				Repeater {
					model: root.tools

					Clickable {
						id: toolKey

						required property var modelData
						readonly property bool current: Pdf.tool === toolKey.modelData.id

						width: 44
						height: 46
						radius: Theme.radius.medium
						color: toolKey.current ? Theme.primarySoft : (toolKey.hovered ? Theme.layer3 : "transparent")
						onClicked: Pdf.tool = toolKey.current ? "" : toolKey.modelData.id

						Behavior on color {
							ColorAnim {}
						}

						ToolTip.visible: toolKey.hovered
						ToolTip.delay: 600
						ToolTip.text: toolKey.modelData.tip

						Column {
							anchors.centerIn: parent
							spacing: 1

							Glyph {
								anchors.horizontalCenter: parent.horizontalCenter
								icon: toolKey.modelData.icon
								size: 20
								color: toolKey.current ? Theme.primary : Theme.text
							}

							StyledText {
								anchors.horizontalCenter: parent.horizontalCenter
								text: toolKey.modelData.label
								font.pixelSize: 9
								tone: toolKey.current ? Theme.primary : Theme.textMuted
							}
						}
					}
				}
			}
		}

		// undo, redo, what was done
		Column {
			id: bottomKeys

			anchors.horizontalCenter: parent.horizontalCenter
			anchors.bottom: parent.bottom
			anchors.bottomMargin: 8
			spacing: 2

			IconButton {
				implicitWidth: 38
				implicitHeight: 38
				icon: "undo"
				enabled: Pdf.canUndo
				opacity: enabled ? 1 : 0.4
				onClicked: Pdf.undo()
				ToolTip.visible: hovered && Pdf.canUndo
				ToolTip.text: `Undo: ${Pdf.undoLabels[Pdf.undoLabels.length - 1] ?? ""}`
			}

			IconButton {
				implicitWidth: 38
				implicitHeight: 38
				icon: "redo"
				enabled: Pdf.canRedo
				opacity: enabled ? 1 : 0.4
				onClicked: Pdf.redo()
			}

			IconButton {
				implicitWidth: 38
				implicitHeight: 38
				icon: "history"
				checked: Pdf.tool === "history"
				onClicked: Pdf.tool = Pdf.tool === "history" ? "" : "history"
			}
		}
	}

	// ── the steps done, newest first: a click goes back to there ───────────
	Component {
		id: historyPane

		PaneFrame {
			title: "What was done"
			subtitle: Pdf.undoLabels.length === 0 ? "Nothing yet" : `${Pdf.undoLabels.length} ${Pdf.undoLabels.length === 1 ? "step" : "steps"} – a click goes back to before it`
			onClose: Pdf.tool = ""

			Repeater {
				model: Pdf.undoLabels.slice().reverse()

				delegate: Clickable {
					id: step

					required property string modelData
					required property int index

					width: parent.width
					height: 36
					radius: Theme.radius.small
					color: step.hovered ? Theme.layer3 : "transparent"
					onClicked: Pdf.undoSteps(step.index + 1)

					Row {
						anchors.verticalCenter: parent.verticalCenter
						x: 10
						spacing: 10

						Glyph {
							anchors.verticalCenter: parent.verticalCenter
							icon: step.hovered ? "undo" : "circle_small"
							size: 16
							color: Theme.textMuted
						}

						StyledText {
							anchors.verticalCenter: parent.verticalCenter
							text: step.modelData
						}
					}
				}
			}

			TextButton {
				visible: Pdf.dirty
				text: "Back to the saved file"
				icon: "restore"
				confirm: true
				onActivated: Pdf.revert()
			}
		}
	}

	// ── over the whole window ──────────────────────────────────────────────
	Loader {
		id: gridLayer

		parent: root.Window.contentItem
		anchors.fill: parent
		z: 50
		active: Pdf.gridOpen
		source: active ? Qt.resolvedUrl("PageGrid.qml") : ""
		onLoaded: if ("dock" in item) item.dock = root
	}

	Loader {
		id: compareLayer

		parent: root.Window.contentItem
		anchors.fill: parent
		z: 50
		active: Pdf.compareWith !== ""
		source: active ? Qt.resolvedUrl("Compare.qml") : ""
	}

	Item {
		id: sheetLayer

		parent: root.Window.contentItem
		anchors.fill: parent
		z: 60
		visible: opacity > 0.01
		opacity: root.sheetOpen ? 1 : 0

		Behavior on opacity {
			Anim {}
		}

		Rectangle {
			anchors.fill: parent
			color: Theme.scrim

			MouseArea {
				anchors.fill: parent
				onClicked: root.closeSheet()
			}
		}

		Loader {
			id: sheetLoader

			anchors.centerIn: parent
			scale: root.sheetOpen ? 1 : 0.94
			active: root.sheetOpen || sheetLoader.item !== null

			Behavior on scale {
				SpatialAnim {}
			}
		}
	}
}
