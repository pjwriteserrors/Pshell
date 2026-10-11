pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// A signature drawn with the mouse (or pen) and put on a page of a PDF.
// The last one is kept, so the next document only needs a click.
DialogFrame {
	id: root

	property var row: null
	property bool drawn: false
	property bool hasSaved: false
	property string page: "last"
	property string position: "bottom-right"
	property real size: 0.3
	readonly property string savedPath: Paths.stateFile("files-signature.png")

	function open(row) {
		root.row = row;
		root.clear();
		root.show();
		Files.request("describe", { paths: [root.savedPath] }, data => root.hasSaved = (data?.entries ?? []).length > 0);
	}

	function clear() {
		const ctx = canvas.getContext("2d");
		if (ctx) ctx.clearRect(0, 0, canvas.width, canvas.height);
		canvas.requestPaint();
		root.drawn = false;
	}

	function useSaved() {
		root.clear();
		canvas.unloadImage(Files.uri(root.savedPath));
		canvas.loadImage(Files.uri(root.savedPath));
	}

	function apply() {
		if (!root.drawn) return;
		const path = `${Paths.runtime}/files-signature-${Date.now()}.png`;
		// what is drawn is kept for next time, and handed to the tool
		canvas.save(path);
		canvas.save(root.savedPath);
		Files.pdfTool("sign", [root.row.path], { image: path, page: root.page, position: root.position, width: Math.round(595 * root.size) });
		root.hide();
	}

	cardWidth: 560
	onDismissed: root.hide()

	ColumnLayout {
		width: parent.width
		spacing: 14

		ColumnLayout {
			spacing: 1

			StyledText {
				text: "Sign"
				font.pixelSize: Theme.size.title
				font.weight: Font.DemiBold
			}

			StyledText {
				text: root.row?.name ?? ""
				tone: Theme.textSubtle
				font.pixelSize: Theme.size.small
			}
		}

		// the paper to sign on
		Rectangle {
			Layout.fillWidth: true
			Layout.preferredHeight: 190
			radius: Theme.radius.large
			color: "white"
			border.width: 1
			border.color: Theme.outline

			Rectangle {
				x: 30
				width: parent.width - 60
				y: parent.height - 46
				height: 1
				color: "#c8c8cc"
			}

			Text {
				x: 30
				y: parent.height - 40
				text: "Sign above the line"
				color: "#9a9aa0"
				font.family: Theme.fontFamily
				font.pixelSize: Theme.size.small
				opacity: root.drawn ? 0 : 1

				Behavior on opacity {
					Anim {}
				}
			}

			Canvas {
				id: canvas

				property var last: null

				anchors.fill: parent
				renderTarget: Canvas.Image
				onImageLoaded: {
					const ctx = canvas.getContext("2d");
					ctx.drawImage(Files.uri(root.savedPath), 0, 0, canvas.width, canvas.height);
					canvas.requestPaint();
					root.drawn = true;
				}

				MouseArea {
					anchors.fill: parent
					cursorShape: Qt.CrossCursor
					onPressed: mouse => canvas.last = Qt.point(mouse.x, mouse.y)
					onPositionChanged: mouse => {
						const ctx = canvas.getContext("2d");
						ctx.strokeStyle = "#1b2a6b";
						ctx.lineWidth = 2.6;
						ctx.lineCap = "round";
						ctx.lineJoin = "round";
						ctx.beginPath();
						ctx.moveTo(canvas.last.x, canvas.last.y);
						// halfway points make the line smooth
						const mid = Qt.point((canvas.last.x + mouse.x) / 2, (canvas.last.y + mouse.y) / 2);
						ctx.quadraticCurveTo(canvas.last.x, canvas.last.y, mid.x, mid.y);
						ctx.lineTo(mouse.x, mouse.y);
						ctx.stroke();
						canvas.last = Qt.point(mouse.x, mouse.y);
						canvas.requestPaint();
						root.drawn = true;
					}
				}
			}

			Row {
				anchors.right: parent.right
				anchors.top: parent.top
				anchors.margins: 8
				spacing: 4

				TextButton {
					visible: root.hasSaved && !root.drawn
					height: 28
					variant: "tonal"
					text: "Use the last one"
					icon: "history"
					onClicked: root.useSaved()
				}

				TextButton {
					visible: root.drawn
					height: 28
					variant: "ghost"
					text: "Clear"
					icon: "eraser"
					onClicked: root.clear()
				}
			}
		}

		GridLayout {
			Layout.fillWidth: true
			columns: 2
			columnSpacing: 12
			rowSpacing: 10

			StyledText {
				text: "On the page"
				tone: Theme.textMuted
				font.pixelSize: Theme.size.small
			}
			Segmented {
				Layout.fillWidth: true
				height: 30
				options: [{ value: "1", label: "First" }, { value: "last", label: "Last" }, { value: "all", label: "Every" }]
				current: root.page
				onSelected: value => root.page = value
			}

			StyledText {
				text: "Where"
				tone: Theme.textMuted
				font.pixelSize: Theme.size.small
			}
			Segmented {
				Layout.fillWidth: true
				height: 30
				options: [{ value: "bottom-left", label: "Left" }, { value: "bottom", label: "Middle" }, { value: "bottom-right", label: "Right" }]
				current: root.position
				onSelected: value => root.position = value
			}

			StyledText {
				text: "Size"
				tone: Theme.textMuted
				font.pixelSize: Theme.size.small
			}
			PillSlider {
				Layout.fillWidth: true
				height: 26
				value: (root.size - 0.12) / 0.4
				valueText: `${Math.round(root.size * 100)} %`
				onMoved: v => root.size = 0.12 + v * 0.4
			}
		}

		RowLayout {
			Layout.alignment: Qt.AlignRight
			spacing: 8

			TextButton {
				text: "Cancel"
				variant: "ghost"
				onClicked: root.hide()
			}

			TextButton {
				text: "Sign as new PDF"
				variant: "filled"
				icon: "draw_pen"
				enabled: root.drawn
				opacity: enabled ? 1 : 0.5
				onClicked: root.apply()
			}
		}
	}
}
