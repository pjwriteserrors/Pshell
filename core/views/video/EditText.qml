pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "../viewer"
import "Edit.js" as Edit

// Words on the film, and arrows and boxes pointing at things: each from one
// moment to another, faded in and out. Picked here or on the picture, where
// they are moved and resized (EditOverlay draws them – the export gets
// pictures of those same items, so they look the same there).
PaneFrame {
	id: root

	property var editor: null
	property color accent: Theme.primary

	readonly property var items: Video.recipe.texts ?? []
	readonly property string selectedId: root.editor?.selectedItem?.kind === "text" ? root.editor.selectedItem.id : ""
	readonly property real outHeight: root.editor?.stage?.outSize?.[1] ?? 1080
	readonly property var swatches: ["#ffffff", "#000000", String(Theme.primary).slice(0, 7), String(Theme.secondary).slice(0, 7), "#ffd54f", "#ff5252", "#69f0ae", "#40c4ff"]

	title: "Text"
	subtitle: root.items.length === 0 ? "Words, arrows and boxes on the picture" : `${root.items.length} on the film`
	closable: false

	function hex(c) {
		return String(c).slice(0, 7);
	}

	// a new one at the playhead, four seconds long (or up to the end)
	function add(kind) {
		const duration = Math.max(0.5, root.editor.duration);
		const a = Math.max(0, Math.min(root.editor.playhead, duration - Math.min(4, duration)));
		const base = { id: Edit.uid("t"), kind: kind, a: Math.round(a * 100) / 100, b: Math.round(Math.min(duration, a + 4) * 100) / 100, fade: 0.3 };
		let item;
		if (kind === "arrow") item = Object.assign(base, { x1: 0.3, y1: 0.3, x2: 0.5, y2: 0.48, color: root.hex(Theme.primary), stroke: 0.012 });
		else if (kind === "rect") item = Object.assign(base, { x: 0.35, y: 0.3, w: 0.3, h: 0.3, color: root.hex(Theme.primary), stroke: 0.008 });
		else item = Object.assign(base, { text: "Your words", x: 0.1, y: 0.74, w: 0.8, h: 0.12, size: 0.07, color: "#ffffff", weight: 700, style: "shadow", align: "center" });
		root.editor.change(r => {
			r.texts = (r.texts || []).concat([item]);
		});
		root.editor.selectedItem = { kind: "text", id: item.id };
	}

	function set(id, changes, live) {
		const fn = r => {
			const it = (r.texts || []).find(t => t.id === id);
			if (it) Object.assign(it, changes);
		};
		if (live) root.editor.drag(fn);
		else root.editor.change(fn);
	}

	function remove(id) {
		root.editor.change(r => {
			r.texts = (r.texts || []).filter(t => t.id !== id);
		});
		if (root.selectedId === id) root.editor.selectedItem = null;
	}

	function duplicate(id) {
		const it = root.items.find(t => t.id === id);
		if (!it) return;
		const copy = Object.assign(Edit.copy(it), { id: Edit.uid("t") });
		if (copy.kind === "arrow") {
			copy.y1 = Math.min(1, copy.y1 + 0.05);
			copy.y2 = Math.min(1, copy.y2 + 0.05);
		} else copy.y = Math.min(1 - copy.h, copy.y + 0.05);
		root.editor.change(r => {
			r.texts = (r.texts || []).concat([copy]);
		});
		root.editor.selectedItem = { kind: "text", id: copy.id };
	}

	function pick(item) {
		root.editor.selectedItem = root.selectedId === item.id ? null : { kind: "text", id: item.id };
		// to a moment it shows at
		if (root.selectedId === item.id && (root.editor.playhead < item.a || root.editor.playhead >= item.b)) root.editor.seekOut(item.a + Math.min(0.5, (item.b - item.a) / 2));
	}

	// a style that brings its own place: the title card fills the middle
	function setStyle(item, style) {
		const changes = { style: style };
		if (style === "title") Object.assign(changes, { x: 0, w: 1, y: 0.36, h: 0.28, size: Math.max(Number(item.size) || 0, 0.1), align: "center" });
		root.set(item.id, changes);
	}

	function nameOf(item) {
		if (item.kind === "arrow") return "Arrow";
		if (item.kind === "rect") return "Box";
		return String(item.text || "").split("\n")[0] || "Words";
	}

	Flow {
		width: parent.width
		spacing: 8

		TextButton {
			text: "Words"
			icon: "format_text"
			variant: "filled"
			onActivated: root.add("text")
		}

		TextButton {
			text: "Arrow"
			icon: "arrow_top_right"
			onActivated: root.add("arrow")
		}

		TextButton {
			text: "Box"
			icon: "rectangle_outline"
			onActivated: root.add("rect")
		}
	}

	StyledText {
		width: parent.width
		visible: root.items.length === 0
		wrapMode: Text.WordWrap
		text: "They start at the playhead. On the picture they are moved by dragging, and resized by their corners."
		font.pixelSize: Theme.size.small
		tone: Theme.textSubtle
	}

	// by count: a field being typed in is not built anew with each letter
	Repeater {
		model: root.items.length

		delegate: Rectangle {
			id: card

			required property int index
			readonly property var item: root.items[card.index] ?? ({})
			readonly property bool selected: root.selectedId === card.item.id
			readonly property bool isText: (card.item.kind ?? "text") === "text"

			width: parent?.width ?? 300
			height: cardColumn.implicitHeight + 16
			radius: Theme.radius.medium
			color: card.selected ? Theme.layer2 : Theme.layer1
			border.width: card.selected ? 1 : 0
			border.color: Qt.alpha(root.accent, 0.6)
			clip: true

			Behavior on height {
				SpatialAnim {}
			}
			Behavior on y {
				SpatialAnim {}
			}

			Column {
				id: cardColumn

				x: 8
				y: 8
				width: card.width - 16
				spacing: 10

				// its name and time; a click picks it
				Clickable {
					width: parent.width
					height: 36
					radius: Theme.radius.small
					onClicked: root.pick(card.item)

					Glyph {
						id: kindGlyph

						x: 6
						anchors.verticalCenter: parent.verticalCenter
						icon: card.item.kind === "arrow" ? "arrow_top_right" : (card.item.kind === "rect" ? "rectangle_outline" : "format_text")
						size: 18
						color: card.selected ? root.accent : Theme.textMuted
					}

					StyledText {
						anchors.left: kindGlyph.right
						anchors.leftMargin: 10
						anchors.right: span.left
						anchors.rightMargin: 8
						anchors.verticalCenter: parent.verticalCenter
						elide: Text.ElideRight
						text: root.nameOf(card.item)
						font.weight: card.selected ? Font.DemiBold : Font.Normal
					}

					StyledText {
						id: span

						anchors.right: parent.right
						anchors.rightMargin: 6
						anchors.verticalCenter: parent.verticalCenter
						text: `${Edit.time(card.item.a)} – ${Edit.time(card.item.b)}`
						tabular: true
						font.pixelSize: Theme.size.small
						tone: Theme.textMuted
					}
				}

				Loader {
					width: parent.width
					active: card.selected
					visible: active
					sourceComponent: Column {
						spacing: 10

						// the words: written into the recipe as they are typed, one step when they rest
						AreaField {
							id: field

							visible: card.isText
							width: parent.width
							height: 74
							placeholder: "The words"
							Component.onCompleted: field.text = card.item.text ?? ""
							onEdited: text => {
								root.set(card.item.id, { text: text }, true);
								typingDone.restart();
							}

							Timer {
								id: typingDone

								interval: 700
								onTriggered: root.editor.endDrag()
							}
						}

						// from … to: steps of a tenth, or the playhead
						Row {
							width: parent.width
							spacing: 6

							TimeEnd {
								label: "From"
								at: card.item.a
								onNudged: d => root.set(card.item.id, { a: Math.max(0, Math.min(card.item.b - 0.1, card.item.a + d)) })
								onHere: root.set(card.item.id, { a: Math.min(card.item.b - 0.1, root.editor.playhead) })
							}

							TimeEnd {
								label: "To"
								at: card.item.b
								onNudged: d => root.set(card.item.id, { b: Math.min(root.editor.duration, Math.max(card.item.a + 0.1, card.item.b + d)) })
								onHere: root.set(card.item.id, { b: Math.max(card.item.a + 0.1, root.editor.playhead) })
							}
						}

						TuneSlider {
							visible: card.isText
							width: parent.width
							label: "Size"
							icon: "format_size"
							accent: root.accent
							from: 0
							to: 0.25
							step: 0.002
							value: Number(card.item.size) || 0.07
							valueText: `${Math.round(shown * root.outHeight)} px`
							onMoved: value => root.set(card.item.id, { size: Math.max(0.015, value) }, true)
							onCommitted: root.editor.endDrag()
						}

						TuneSlider {
							visible: !card.isText
							width: parent.width
							label: "Line"
							icon: "format_line_weight"
							accent: root.accent
							from: 0
							to: 0.04
							step: 0.001
							value: Number(card.item.stroke) || 0.008
							valueText: `${Math.round(shown * root.outHeight)} px`
							onMoved: value => root.set(card.item.id, { stroke: Math.max(0.002, value) }, true)
							onCommitted: root.editor.endDrag()
						}

						// its colour: the theme's two, white and black, a few bright ones
						Row {
							spacing: 6

							Repeater {
								model: root.swatches

								delegate: Rectangle {
									required property string modelData
									readonly property bool current: Qt.colorEqual(card.item.color ?? "#ffffff", modelData)

									width: 24
									height: 24
									radius: 12
									color: modelData
									border.width: current ? 2 : 1
									border.color: current ? root.accent : Theme.outline
									scale: swatchMouse.containsMouse ? 1.12 : 1

									Behavior on scale {
										SpatialAnim {}
									}

									MouseArea {
										id: swatchMouse

										anchors.fill: parent
										hoverEnabled: true
										cursorShape: Qt.PointingHandCursor
										onClicked: root.set(card.item.id, { color: parent.modelData })
									}
								}
							}
						}

						Segmented {
							visible: card.isText
							width: parent.width
							height: 34
							options: [{ value: "300", label: "Light" }, { value: "400", label: "Normal" }, { value: "700", label: "Bold" }, { value: "900", label: "Black" }]
							current: String(card.item.weight ?? 700)
							onSelected: value => root.set(card.item.id, { weight: Number(value) })
						}

						Flow {
							visible: card.isText
							width: parent.width
							spacing: 6

							Repeater {
								model: [{ id: "plain", label: "Plain" }, { id: "shadow", label: "Shadow" }, { id: "outline", label: "Outline" }, { id: "box", label: "Box" }, { id: "title", label: "Title card" }]

								delegate: Chip {
									required property var modelData

									text: modelData.label
									accent: root.accent
									selected: (card.item.style ?? "plain") === modelData.id
									onClicked: root.setStyle(card.item, modelData.id)
								}
							}
						}

						Row {
							visible: card.isText
							spacing: 8

							Segmented {
								width: 132
								height: 34
								options: [{ value: "left", icon: "format_align_left" }, { value: "center", icon: "format_align_center" }, { value: "right", icon: "format_align_right" }]
								current: card.item.align ?? "center"
								onSelected: value => root.set(card.item.id, { align: value })
							}

							// where on the picture, without dragging
							Segmented {
								width: 150
								height: 34
								options: [{ value: "top", label: "Top" }, { value: "middle", label: "Middle" }, { value: "bottom", label: "Low" }]
								current: card.item.y < 0.3 ? "top" : (card.item.y + card.item.h > 0.7 ? "bottom" : "middle")
								onSelected: value => root.set(card.item.id, { y: value === "top" ? 0.06 : (value === "middle" ? (1 - card.item.h) / 2 : 0.94 - card.item.h) })
							}
						}

						TuneSlider {
							width: parent.width
							label: "Fade in and out"
							icon: "blur_linear"
							accent: root.accent
							from: 0
							to: 2
							step: 0.05
							value: Number(card.item.fade) || 0
							valueText: shown > 0 ? `${shown.toFixed(2)} s` : "Off"
							onMoved: value => root.set(card.item.id, { fade: Math.round(value * 100) / 100 }, true)
							onCommitted: root.editor.endDrag()
						}

						Row {
							spacing: 8

							TextButton {
								text: "Twice"
								icon: "content_duplicate"
								variant: "ghost"
								onActivated: root.duplicate(card.item.id)
							}

							TextButton {
								text: "Delete"
								icon: "delete_outline"
								variant: "danger"
								onActivated: root.remove(card.item.id)
							}
						}
					}
				}
			}
		}
	}

	// a start or an end: its time, a tenth earlier or later, the playhead
	component TimeEnd: Rectangle {
		id: end

		property string label: ""
		property real at: 0
		signal nudged(real delta)
		signal here

		width: (parent?.width ?? 300) / 2 - 3
		height: 58
		radius: Theme.radius.small
		color: Theme.layer3

		StyledText {
			x: 8
			y: 6
			text: end.label
			font.pixelSize: Theme.size.small
			tone: Theme.textMuted
		}

		StyledText {
			anchors.right: parent.right
			anchors.rightMargin: 8
			y: 6
			text: Edit.time(end.at)
			tabular: true
			font.pixelSize: Theme.size.small
			font.weight: Font.DemiBold
		}

		Row {
			anchors.horizontalCenter: parent.horizontalCenter
			anchors.bottom: parent.bottom
			anchors.bottomMargin: 2
			spacing: 0

			IconButton {
				width: 28
				height: 28
				icon: "chevron_left"
				onClicked: end.nudged(-0.1)
			}

			IconButton {
				width: 28
				height: 28
				icon: "map_marker_outline"
				onClicked: end.here()
			}

			IconButton {
				width: 28
				height: 28
				icon: "chevron_right"
				onClicked: end.nudged(0.1)
			}
		}
	}
}
