pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// Cutting a piece out of a picture: a frame to drag and pull at its
// corners, a shape to keep (free, square, 4:3, 16:9), the rest dims.
DialogFrame {
	id: root

	property string path: ""
	property string aspect: "free"
	property bool replace: false
	// the frame, as parts of the picture (0 … 1)
	property real fx: 0.1
	property real fy: 0.1
	property real fw: 0.8
	property real fh: 0.8

	function open(path) {
		root.path = path;
		root.aspect = "free";
		root.replace = false;
		root.fx = 0.1;
		root.fy = 0.1;
		root.fw = 0.8;
		root.fh = 0.8;
		root.show();
		keys.forceActiveFocus();
	}

	readonly property real ratio: {
		switch (root.aspect) {
		case "square": return 1;
		case "43": return 4 / 3;
		case "169": return 16 / 9;
		case "34": return 3 / 4;
		default: return 0;
		}
	}

	// a shape picked: the frame takes it, as big as fits around its middle
	onRatioChanged: {
		if (root.ratio <= 0 || picture.paintedWidth <= 0) return;
		const pw = picture.paintedWidth;
		const ph = picture.paintedHeight;
		let w = root.fw * pw;
		let h = w / root.ratio;
		if (h > ph) {
			h = ph;
			w = h * root.ratio;
		}
		const cx = (root.fx + root.fw / 2) * pw;
		const cy = (root.fy + root.fh / 2) * ph;
		root.fw = w / pw;
		root.fh = h / ph;
		root.fx = Math.max(0, Math.min(1 - root.fw, (cx - w / 2) / pw));
		root.fy = Math.max(0, Math.min(1 - root.fh, (cy - h / 2) / ph));
	}

	function run() {
		Files.imageTool("crop", [root.path], { x: root.fx, y: root.fy, w: root.fw, h: root.fh, replace: root.replace });
		root.hide();
	}

	cardWidth: 760
	onDismissed: root.hide()

	Item {
		id: keys

		focus: root.shown
		Keys.onEscapePressed: root.hide()
		Keys.onReturnPressed: root.run()
		Keys.onEnterPressed: root.run()
	}

	ColumnLayout {
		width: parent.width
		spacing: 12

		RowLayout {
			spacing: 12

			Rectangle {
				width: 40
				height: 40
				radius: 13
				color: Qt.tint(Theme.layer2, Qt.alpha(Theme.tertiary, 0.2))

				Glyph {
					anchors.centerIn: parent
					icon: "crop"
					size: 20
					color: Theme.tertiary
				}
			}

			ColumnLayout {
				Layout.fillWidth: true
				spacing: 1

				StyledText {
					text: "Crop"
					font.pixelSize: Theme.size.title
					font.weight: Font.DemiBold
				}

				StyledText {
					Layout.fillWidth: true
					text: picture.sourceSize.width > 0 ? `${Files.nameOf(root.path)} · ${Math.round(root.fw * picture.sourceSize.width)} × ${Math.round(root.fh * picture.sourceSize.height)} px` : Files.nameOf(root.path)
					tone: Theme.textSubtle
					font.pixelSize: Theme.size.small
					elide: Text.ElideMiddle
				}
			}
		}

		Segmented {
			Layout.fillWidth: true
			height: 32
			options: [{ value: "free", label: "Free" }, { value: "square", label: "Square" }, { value: "43", label: "4 : 3" }, { value: "169", label: "16 : 9" }, { value: "34", label: "Portrait" }]
			current: root.aspect
			onSelected: value => root.aspect = value
		}

		Item {
			Layout.fillWidth: true
			Layout.preferredHeight: Math.max(220, Math.min(480, root.height - 300))

			Image {
				id: picture

				anchors.centerIn: parent
				width: parent.width
				height: parent.height
				source: root.path !== "" && root.shown ? Files.uri(root.path) : ""
				fillMode: Image.PreserveAspectFit
				asynchronous: true
				autoTransform: true
				sourceSize.width: 1600
			}

			// where the picture is drawn inside the item
			Item {
				id: area

				x: (parent.width - picture.paintedWidth) / 2
				y: (parent.height - picture.paintedHeight) / 2
				width: picture.paintedWidth
				height: picture.paintedHeight

				// the rest dims
				Rectangle {
					x: 0
					y: 0
					width: parent.width
					height: frame.y
					color: Theme.scrim
				}
				Rectangle {
					x: 0
					y: frame.y + frame.height
					width: parent.width
					height: parent.height - y
					color: Theme.scrim
				}
				Rectangle {
					x: 0
					y: frame.y
					width: frame.x
					height: frame.height
					color: Theme.scrim
				}
				Rectangle {
					x: frame.x + frame.width
					y: frame.y
					width: parent.width - x
					height: frame.height
					color: Theme.scrim
				}

				Rectangle {
					id: frame

					x: root.fx * area.width
					y: root.fy * area.height
					width: root.fw * area.width
					height: root.fh * area.height
					color: "transparent"
					border.width: 2
					border.color: Theme.primary

					// thirds, for placing what matters
					Repeater {
						model: 2

						delegate: Item {
							required property int index

							Rectangle {
								x: frame.width * (index + 1) / 3
								width: 1
								height: frame.height
								color: Qt.alpha(Theme.primary, 0.4)
							}
							Rectangle {
								y: frame.height * (index + 1) / 3
								width: frame.width
								height: 1
								color: Qt.alpha(Theme.primary, 0.4)
							}
						}
					}

					MouseArea {
						anchors.fill: parent
						cursorShape: Qt.SizeAllCursor
						property real startX: 0
						property real startY: 0
						property real fromX: 0
						property real fromY: 0
						onPressed: mouse => {
							const at = mapToItem(area, mouse.x, mouse.y);
							startX = at.x;
							startY = at.y;
							fromX = root.fx;
							fromY = root.fy;
						}
						onPositionChanged: mouse => {
							const at = mapToItem(area, mouse.x, mouse.y);
							root.fx = Math.max(0, Math.min(1 - root.fw, fromX + (at.x - startX) / area.width));
							root.fy = Math.max(0, Math.min(1 - root.fh, fromY + (at.y - startY) / area.height));
						}
					}

					// the corners pull the frame bigger or smaller
					Repeater {
						model: [{ cx: 0, cy: 0 }, { cx: 1, cy: 0 }, { cx: 0, cy: 1 }, { cx: 1, cy: 1 }]

						delegate: Rectangle {
							id: handle

							required property var modelData

							x: handle.modelData.cx * frame.width - width / 2
							y: handle.modelData.cy * frame.height - height / 2
							width: 16
							height: 16
							radius: 8
							color: Theme.primary
							border.width: 2
							border.color: Theme.base

							MouseArea {
								anchors.fill: parent
								anchors.margins: -6
								cursorShape: (handle.modelData.cx === handle.modelData.cy) ? Qt.SizeFDiagCursor : Qt.SizeBDiagCursor
								onPositionChanged: mouse => {
									const at = mapToItem(area, mouse.x, mouse.y);
									const px = Math.max(0, Math.min(1, at.x / area.width));
									const py = Math.max(0, Math.min(1, at.y / area.height));
									// the corner opposite stays where it is
									const ox = handle.modelData.cx === 0 ? root.fx + root.fw : root.fx;
									const oy = handle.modelData.cy === 0 ? root.fy + root.fh : root.fy;
									let w = Math.max(0.03, Math.abs(px - ox));
									let h = Math.max(0.03, Math.abs(py - oy));
									if (root.ratio > 0) {
										const wanted = root.ratio * area.height / area.width;
										if (w / h > wanted) w = h * wanted;
										else h = w / wanted;
									}
									root.fw = Math.min(w, handle.modelData.cx === 0 ? ox : 1 - ox);
									root.fh = Math.min(h, handle.modelData.cy === 0 ? oy : 1 - oy);
									root.fx = handle.modelData.cx === 0 ? ox - root.fw : ox;
									root.fy = handle.modelData.cy === 0 ? oy - root.fh : oy;
								}
							}
						}
					}
				}
			}
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 8

			Toggle {
				checked: root.replace
				onToggled: on => root.replace = on
			}

			StyledText {
				Layout.fillWidth: true
				text: root.replace ? "In place of the picture (the old one goes to the trash)" : "As a new picture beside it"
				tone: Theme.textMuted
				font.pixelSize: Theme.size.small
			}

			TextButton {
				text: "Cancel"
				variant: "ghost"
				onClicked: root.hide()
			}

			TextButton {
				text: "Crop"
				icon: "crop"
				variant: "filled"
				onClicked: root.run()
			}
		}
	}
}
