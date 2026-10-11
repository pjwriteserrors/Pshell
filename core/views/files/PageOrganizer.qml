pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtQuick.Pdf
import qs.style.theme
import qs.style.widgets
import qs.core.services

// A PDF's pages laid out to put in order: drag a page to where it should
// go (or Ctrl and the arrows), turn the picked ones, take them out. Saved
// as a new document beside the old one.
DialogFrame {
	id: root

	property var row: null
	property int current: 0
	property var picked: ({})
	property int pickTick: 0
	property int dragFrom: -1

	function open(row) {
		root.row = row;
		pages.clear();
		root.picked = {};
		root.current = 0;
		root.show();
		keys.forceActiveFocus();
	}

	function fill() {
		pages.clear();
		for (let i = 0; i < root.pdf.pageCount; i += 1) pages.append({ page: i, turn: 0 });
	}

	function isPicked(index) {
		root.pickTick;
		const item = index >= 0 && index < pages.count ? pages.get(index) : null;
		return !!item && root.picked[item.page] === true;
	}

	function pick(index, add) {
		if (index < 0 || index >= pages.count) return;
		const key = pages.get(index).page;
		const next = add ? Object.assign({}, root.picked) : {};
		if (add && next[key]) delete next[key];
		else next[key] = true;
		root.picked = next;
		root.pickTick += 1;
		root.current = index;
	}

	// what the buttons work on: the picked pages, else the current one
	function targets() {
		const out = [];
		for (let i = 0; i < pages.count; i += 1) if (root.picked[pages.get(i).page]) out.push(i);
		return out.length > 0 ? out : (root.current >= 0 && root.current < pages.count ? [root.current] : []);
	}

	function turn(by) {
		for (const index of root.targets()) pages.setProperty(index, "turn", (pages.get(index).turn + by + 360) % 360);
		Sounds.play("select");
	}

	function drop() {
		const gone = root.targets().sort((a, b) => b - a);
		if (gone.length >= pages.count) {
			Files.say("A document needs one page at least", "alert_circle_outline");
			return;
		}
		for (const index of gone) pages.remove(index, 1);
		root.picked = {};
		root.pickTick += 1;
		root.current = Math.min(root.current, pages.count - 1);
		Sounds.play("close");
	}

	function shift(by) {
		const from = root.current;
		const to = from + by;
		if (from < 0 || to < 0 || to >= pages.count) return;
		pages.move(from, to, 1);
		root.current = to;
	}

	function save() {
		const plan = [];
		for (let i = 0; i < pages.count; i += 1) plan.push({ page: pages.get(i).page, rotate: pages.get(i).turn });
		Files.pdfTool("organize", [root.row.path], { pages: plan });
		root.hide();
	}

	cardWidth: Math.min(980, root.width - 80)
	onDismissed: root.hide()

	// the document is opened only while the dialog is up
	readonly property var pdf: pdfLoader.item ?? ({ status: PdfDocument.Loading, pageCount: 0, pagePointSize: () => Qt.size(0, 0) })

	Loader {
		id: pdfLoader

		active: root.shown && !!root.row

		sourceComponent: PdfDocument {
			id: doc

			source: Files.uri(root.row.path)
			onStatusChanged: if (doc.status === PdfDocument.Ready) root.fill()
		}
	}

	ListModel {
		id: pages
	}

	Item {
		id: keys

		focus: root.shown
		Keys.onPressed: event => {
			const ctrl = (event.modifiers & Qt.ControlModifier) !== 0;
			const columns = Math.max(1, Math.floor(grid.width / grid.cellWidth));
			switch (event.key) {
			case Qt.Key_Escape:
				root.hide();
				break;
			case Qt.Key_Left:
				if (ctrl) root.shift(-1);
				else root.current = Math.max(0, root.current - 1);
				break;
			case Qt.Key_Right:
				if (ctrl) root.shift(1);
				else root.current = Math.min(pages.count - 1, root.current + 1);
				break;
			case Qt.Key_Up:
				root.current = Math.max(0, root.current - columns);
				break;
			case Qt.Key_Down:
				root.current = Math.min(pages.count - 1, root.current + columns);
				break;
			case Qt.Key_Space:
				root.pick(root.current, true);
				break;
			case Qt.Key_Delete:
				root.drop();
				break;
			case Qt.Key_R:
				root.turn((event.modifiers & Qt.ShiftModifier) ? -90 : 90);
				break;
			case Qt.Key_Return:
			case Qt.Key_Enter:
				if (ctrl) root.save();
				break;
			default:
				return;
			}
			event.accepted = true;
		}
	}

	ColumnLayout {
		width: parent.width
		spacing: 12

		RowLayout {
			Layout.fillWidth: true
			spacing: 8

			ColumnLayout {
				Layout.fillWidth: true
				spacing: 1

				StyledText {
					text: "Organize pages"
					font.pixelSize: Theme.size.title
					font.weight: Font.DemiBold
				}

				StyledText {
					Layout.fillWidth: true
					text: `${root.row?.name ?? ""} · ${pages.count} page${pages.count === 1 ? "" : "s"}${root.pdf.status === PdfDocument.Ready && pages.count !== root.pdf.pageCount ? ` (was ${root.pdf.pageCount})` : ""}`
					tone: Theme.textSubtle
					font.pixelSize: Theme.size.small
					elide: Text.ElideMiddle
				}
			}

			IconButton {
				width: 34
				height: 34
				iconSize: 17
				variant: "tonal"
				icon: "rotate_left"
				onClicked: root.turn(-90)
			}
			IconButton {
				width: 34
				height: 34
				iconSize: 17
				variant: "tonal"
				icon: "rotate_right"
				onClicked: root.turn(90)
			}
			IconButton {
				width: 34
				height: 34
				iconSize: 17
				variant: "tonal"
				icon: "delete_outline"
				onClicked: root.drop()
			}
		}

		Rectangle {
			Layout.fillWidth: true
			Layout.preferredHeight: Math.min(root.height - 220, 600)
			radius: Theme.radius.large
			color: Theme.layer2

			Spinner {
				anchors.centerIn: parent
				visible: root.pdf.status !== PdfDocument.Ready && root.pdf.status !== PdfDocument.Error
				width: 26
				height: 26
			}

			StyledText {
				anchors.centerIn: parent
				visible: root.pdf.status === PdfDocument.Error
				text: "This PDF cannot be opened here (a password?)"
				tone: Theme.textMuted
			}

			GridView {
				id: grid

				anchors.fill: parent
				anchors.margins: 10
				clip: true
				model: pages
				cellWidth: Math.floor(width / Math.max(1, Math.floor(width / 150)))
				cellHeight: 206
				boundsBehavior: Flickable.StopAtBounds
				interactive: root.dragFrom < 0

				move: Transition {
					NumberAnimation {
						properties: "x,y"
						duration: Motion.medium
						easing.type: Easing.BezierSpline
						easing.bezierCurve: Motion.spatial
					}
				}
				moveDisplaced: Transition {
					NumberAnimation {
						properties: "x,y"
						duration: Motion.medium
						easing.type: Easing.BezierSpline
						easing.bezierCurve: Motion.spatial
					}
				}
				removeDisplaced: Transition {
					NumberAnimation {
						properties: "x,y"
						duration: Motion.medium
						easing.type: Easing.BezierSpline
						easing.bezierCurve: Motion.spatial
					}
				}
				remove: Transition {
					ParallelAnimation {
						NumberAnimation {
							property: "opacity"
							to: 0
							duration: Motion.short
						}
						NumberAnimation {
							property: "scale"
							to: 0.7
							duration: Motion.medium
						}
					}
				}

				delegate: Item {
					id: cell

					required property int index
					required property int page
					required property int turn
					readonly property bool lit: root.isPicked(cell.index)
					readonly property bool here: root.current === cell.index
					readonly property size points: root.pdf.pagePointSize(cell.page)

					width: grid.cellWidth
					height: grid.cellHeight
					z: root.dragFrom === cell.index ? 10 : 0

					Rectangle {
						anchors.fill: parent
						anchors.margins: 5
						radius: Theme.radius.medium
						color: cell.lit ? Theme.primarySoft : Qt.alpha(Theme.layer3, cellMouse.containsMouse ? 0.8 : 0)
						border.width: cell.here ? 2 : 0
						border.color: Qt.alpha(Theme.primary, 0.7)
						scale: root.dragFrom === cell.index ? 1.06 : 1

						Behavior on color {
							ColorAnim {}
						}
						Behavior on scale {
							SpatialAnim {
								duration: Motion.medium
							}
						}
					}

					Item {
						id: sheetBox

						x: 14
						y: 12
						width: parent.width - 28
						height: parent.height - 44

						Rectangle {
							id: sheet

							readonly property real ratio: cell.points.width > 0 ? cell.points.height / cell.points.width : 1.41
							readonly property bool sideways: cell.turn % 180 !== 0
							anchors.centerIn: parent
							// turned sideways, the page still fits the box
							height: sheet.sideways ? Math.min(sheetBox.width, sheetBox.height / sheet.ratio) : Math.min(sheetBox.height, sheetBox.width * sheet.ratio)
							width: sheet.height / sheet.ratio
							color: "white"
							radius: 3
							rotation: cell.turn

							Behavior on rotation {
								SpatialAnim {
									duration: Motion.medium
								}
							}

							PdfPageImage {
								anchors.fill: parent
								document: pdfLoader.item
								currentFrame: cell.page
								asynchronous: true
								sourceSize.width: 220
							}
						}
					}

					StyledText {
						anchors.horizontalCenter: parent.horizontalCenter
						anchors.bottom: parent.bottom
						anchors.bottomMargin: 10
						text: cell.index + 1 === cell.page + 1 ? String(cell.index + 1) : `${cell.index + 1}  ·  was ${cell.page + 1}`
						tone: cell.lit ? Theme.primary : Theme.textMuted
						font.pixelSize: Theme.size.small
						font.weight: cell.lit ? Font.DemiBold : Font.Normal
					}

					// a click picks, Ctrl adds; held and moved, the page goes where the pointer is
					MouseArea {
						id: cellMouse

						property point pressAt: Qt.point(0, 0)

						anchors.fill: parent
						hoverEnabled: true
						preventStealing: true
						onPressed: mouse => {
							cellMouse.pressAt = Qt.point(mouse.x, mouse.y);
							keys.forceActiveFocus();
						}
						onClicked: mouse => root.pick(cell.index, (mouse.modifiers & Qt.ControlModifier) !== 0)
						onPositionChanged: mouse => {
							if (!pressed) return;
							if (root.dragFrom < 0 && Math.hypot(mouse.x - cellMouse.pressAt.x, mouse.y - cellMouse.pressAt.y) > 10) root.dragFrom = cell.index;
							if (root.dragFrom < 0) return;
							const at = cellMouse.mapToItem(grid.contentItem, mouse.x, mouse.y);
							const to = grid.indexAt(at.x, at.y);
							if (to >= 0 && to !== root.dragFrom) {
								pages.move(root.dragFrom, to, 1);
								root.dragFrom = to;
								root.current = to;
							}
						}
						onReleased: root.dragFrom = -1
						onCanceled: root.dragFrom = -1
					}
				}
			}
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 8

			StyledText {
				Layout.fillWidth: true
				text: "Drag to reorder · Ctrl+← → moves · R turns · Del takes out"
				tone: Theme.textSubtle
				font.pixelSize: Theme.size.small
				elide: Text.ElideRight
			}

			TextButton {
				text: "Cancel"
				variant: "ghost"
				onClicked: root.hide()
			}

			TextButton {
				text: "Save as new PDF"
				variant: "filled"
				icon: "check"
				enabled: pages.count > 0
				onClicked: root.save()
			}
		}
	}
}
