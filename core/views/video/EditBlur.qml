pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "../viewer"
import "Edit.js" as Edit

// Parts of the picture made unreadable – a number plate, a screen, a face
// that should not be seen – blurred or in blocks, each from one moment to
// another; on the picture they are moved and resized (EditOverlay shows
// them as the export makes them). Every face at once is the export's job.
PaneFrame {
	id: root

	property var editor: null
	property color accent: Theme.primary

	readonly property var items: Video.recipe.blurs ?? []
	readonly property string selectedId: root.editor?.selectedItem?.kind === "blur" ? root.editor.selectedItem.id : ""

	title: "Blur"
	subtitle: root.items.length === 0 ? (Video.recipe.faces ? "Every face" : "Parts of the picture made unreadable") : `${root.items.length} ${root.items.length === 1 ? "part" : "parts"}${Video.recipe.faces ? " and every face" : ""}`
	closable: false

	function add() {
		const duration = Math.max(0.5, root.editor.duration);
		const a = Math.max(0, Math.min(root.editor.playhead, duration - Math.min(4, duration)));
		const item = { id: Edit.uid("b"), a: Math.round(a * 100) / 100, b: Math.round(Math.min(duration, a + 4) * 100) / 100, x: 0.38, y: 0.36, w: 0.24, h: 0.28, strength: 0.6, kind: "blur", fade: 0 };
		root.editor.change(r => {
			r.blurs = (r.blurs || []).concat([item]);
		});
		root.editor.selectedItem = { kind: "blur", id: item.id };
	}

	function set(id, changes, live) {
		const fn = r => {
			const it = (r.blurs || []).find(b => b.id === id);
			if (it) Object.assign(it, changes);
		};
		if (live) root.editor.drag(fn);
		else root.editor.change(fn);
	}

	function remove(id) {
		root.editor.change(r => {
			r.blurs = (r.blurs || []).filter(b => b.id !== id);
		});
		if (root.selectedId === id) root.editor.selectedItem = null;
	}

	function pick(item) {
		root.editor.selectedItem = root.selectedId === item.id ? null : { kind: "blur", id: item.id };
		if (root.selectedId === item.id && (root.editor.playhead < item.a || root.editor.playhead >= item.b)) root.editor.seekOut(item.a + Math.min(0.5, (item.b - item.a) / 2));
	}

	TextButton {
		text: "Blur a part"
		icon: "blur"
		variant: "filled"
		onActivated: root.add()
	}

	PaneLine {
		label: "Blur every face"
		detail: "Found in each frame by the export – slower, and not shown here"

		Toggle {
			checked: !!Video.recipe.faces
			onToggled: checked => root.editor.change(r => r.faces = checked)
		}
	}

	// by count, so a slider is not built anew while it is dragged
	Repeater {
		model: root.items.length

		delegate: Rectangle {
			id: card

			required property int index
			readonly property var item: root.items[card.index] ?? ({})
			readonly property bool selected: root.selectedId === card.item.id

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

				Clickable {
					width: parent.width
					height: 36
					radius: Theme.radius.small
					onClicked: root.pick(card.item)

					Glyph {
						id: kindGlyph

						x: 6
						anchors.verticalCenter: parent.verticalCenter
						icon: card.item.kind === "pixel" ? "grid" : "blur"
						size: 18
						color: card.selected ? root.accent : Theme.textMuted
					}

					StyledText {
						anchors.left: kindGlyph.right
						anchors.leftMargin: 10
						anchors.verticalCenter: parent.verticalCenter
						text: card.item.kind === "pixel" ? `Blocks ${card.index + 1}` : `Blur ${card.index + 1}`
						font.weight: card.selected ? Font.DemiBold : Font.Normal
					}

					StyledText {
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

						Segmented {
							width: parent.width
							height: 34
							options: [{ value: "blur", label: "Blurred", icon: "blur" }, { value: "pixel", label: "Blocks", icon: "grid" }]
							current: card.item.kind ?? "blur"
							onSelected: value => root.set(card.item.id, { kind: value })
						}

						TuneSlider {
							width: parent.width
							label: "Strength"
							icon: "blur_radial"
							accent: root.accent
							from: 0
							to: 1
							value: Number(card.item.strength ?? 0.6)
							onMoved: value => root.set(card.item.id, { strength: Math.max(0.05, Math.round(value * 100) / 100) }, true)
							onCommitted: root.editor.endDrag()
						}

						Row {
							width: parent.width
							spacing: 6

							TextButton {
								width: (parent.width - 6) / 2
								text: `From ${Edit.time(card.item.a)}`
								icon: "ray_start"
								onActivated: root.set(card.item.id, { a: Math.min(card.item.b - 0.1, root.editor.playhead) })
							}

							TextButton {
								width: (parent.width - 6) / 2
								text: `To ${Edit.time(card.item.b)}`
								icon: "ray_end"
								onActivated: root.set(card.item.id, { b: Math.max(card.item.a + 0.1, root.editor.playhead) })
							}
						}

						StyledText {
							width: parent.width
							wrapMode: Text.WordWrap
							text: "The buttons set its start or end to the playhead. On the picture: drag it, or its corners."
							font.pixelSize: Theme.size.small
							tone: Theme.textSubtle
						}

						Row {
							spacing: 8

							TextButton {
								text: "The whole film"
								icon: "arrow_expand_horizontal"
								variant: "ghost"
								onActivated: root.set(card.item.id, { a: 0, b: root.editor.duration })
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
}
