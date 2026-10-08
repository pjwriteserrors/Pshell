pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// The keyboard layouts as tiles, the first one is the one you start with:
// drag them into order, pick a variant on a tile, add one from the list of
// every layout xkb knows. Writes `layout "de,us"` and `variant ",intl"`.
ColumnLayout {
	id: root

	readonly property var path: ["input", "keyboard", "xkb"]
	readonly property var layouts: String(NiriSettings.arg(root.path.concat(["layout"]), "")).split(",").map(s => s.trim()).filter(s => s !== "")
	readonly property var variants: String(NiriSettings.arg(root.path.concat(["variant"]), "")).split(",").map(s => s.trim())
	readonly property var entries: root.layouts.map((layout, i) => ({ layout: layout, variant: root.variants[i] || "" }))

	function describe(layout) {
		return (NiriSettings.xkb.layouts || []).find(entry => entry.name === layout)?.description ?? layout;
	}

	function variantName(layout, variant) {
		if (!variant) return "Standard";
		const found = ((NiriSettings.xkb.layouts || []).find(entry => entry.name === layout)?.variants || []).find(v => v.name === variant);
		return found ? found.description.replace(/^[^(]*\(([^)]*)\).*$/, "$1") : variant;
	}

	function write(list, note) {
		NiriSettings.edit(note, "", draft => {
			const layout = list.map(e => e.layout).join(",");
			const variant = list.map(e => e.variant).join(",");
			NiriSettings.setIn(draft, root.path.concat(["layout"]), [layout], undefined, true);
			if (list.some(e => e.variant !== "")) NiriSettings.setIn(draft, root.path.concat(["variant"]), [variant], undefined, true);
			else NiriSettings.removeIn(draft, root.path.concat(["variant"]));
		});
	}

	spacing: 12

	RowLayout {
		Layout.fillWidth: true
		spacing: 10

		DragList {
			id: list

			Layout.fillWidth: true
			Layout.preferredHeight: 104
			horizontal: true
			spacing: 10
			items: root.entries
			onReordered: order => root.write(order.map(i => root.entries[i]), "Layouts reordered")

			cell: Rectangle {
				id: tile

				property var modelData: ({ layout: "", variant: "" })
				property int index: 0
				property Item dragSource: null

				implicitWidth: 190
				implicitHeight: 100
				radius: Theme.radius.large
				color: tile.index === 0 ? Theme.primaryContainer : Theme.layer2
				border.width: tile.index === 0 ? 1.5 : 0
				border.color: Theme.primary

				Behavior on color {
					ColorAnim {}
				}

				RowLayout {
					anchors.fill: parent
					anchors.margins: 10
					spacing: 8

					DragGrip {
						source: tile.dragSource
						horizontal: true
						visible: root.entries.length > 1
					}

					ColumnLayout {
						Layout.fillWidth: true
						spacing: 4

						RowLayout {
							spacing: 8

							Rectangle {
								Layout.preferredWidth: 38
								Layout.preferredHeight: 28
								radius: 6
								color: tile.index === 0 ? Theme.primary : Theme.layer3

								StyledText {
									anchors.centerIn: parent
									text: tile.modelData.layout.toUpperCase().slice(0, 3)
									tone: tile.index === 0 ? Theme.onPrimary : Theme.text
									font.weight: Font.Bold
									font.family: Theme.monoFamily
								}
							}

							StyledText {
								visible: tile.index === 0
								text: "first"
								tone: Theme.primary
								font.pixelSize: Theme.size.tiny
								font.weight: Font.Bold
							}

							Item {
								Layout.fillWidth: true
							}

							IconButton {
								implicitWidth: 24
								implicitHeight: 24
								icon: "close"
								iconSize: 13
								visible: root.entries.length > 1
								onClicked: root.write(root.entries.filter((e, i) => i !== tile.index), `${tile.modelData.layout} removed`)
							}
						}

						StyledText {
							Layout.fillWidth: true
							text: root.describe(tile.modelData.layout)
							font.weight: Font.Medium
							font.pixelSize: Theme.size.label
						}

						// the variant: click to choose
						Clickable {
							Layout.fillWidth: true
							implicitHeight: 22
							radius: 6
							onClicked: variantMenu.open()

							RowLayout {
								anchors.fill: parent
								spacing: 4

								StyledText {
									Layout.fillWidth: true
									text: root.variantName(tile.modelData.layout, tile.modelData.variant)
									tone: Theme.textMuted
									font.pixelSize: Theme.size.small
								}

								Glyph {
									icon: "chevron_down"
									size: 13
									color: Theme.textSubtle
								}
							}

							PickList {
								id: variantMenu

								y: parent.height + 4
								placeholder: "Search variants"
								current: tile.modelData.variant
								entries: [{ value: "", label: "Standard" }].concat(((NiriSettings.xkb.layouts || []).find(entry => entry.name === tile.modelData.layout)?.variants ?? []).map(v => ({ value: v.name, label: v.description, detail: v.name })))
								onPicked: value => root.write(root.entries.map((e, i) => i === tile.index ? { layout: e.layout, variant: String(value) } : e), "Variant changed")
							}
						}
					}
				}
			}
		}

		// add a layout
		Clickable {
			Layout.preferredWidth: 100
			Layout.preferredHeight: 100
			radius: Theme.radius.large
			color: Theme.layer2
			onClicked: {
				addSearch.text = "";
				adder.open();
				addSearch.focusInput();
			}

			Column {
				anchors.centerIn: parent
				spacing: 6

				Glyph {
					anchors.horizontalCenter: parent.horizontalCenter
					icon: "plus"
					size: 22
					color: Theme.primary
				}

				StyledText {
					text: "Add"
					tone: Theme.textMuted
					font.pixelSize: Theme.size.small
				}
			}

			Popup {
				id: adder

				y: parent.height + 6
				x: parent.width - width
				width: 340
				height: 380
				padding: 12
				modal: true
				dim: false

				background: Rectangle {
					radius: Theme.radius.huge
					color: Theme.layer2
					border.width: 1
					border.color: Theme.outline
				}

				contentItem: ColumnLayout {
					spacing: 8

					Field {
						id: addSearch

						Layout.fillWidth: true
						icon: "magnify"
						placeholder: "German, us, dvorak…"
						onAccepted: if (matches.count > 0) matches.itemAtIndex(0)?.add()
					}

					ListView {
						id: matches

						Layout.fillWidth: true
						Layout.fillHeight: true
						clip: true
						spacing: 2
						model: {
							const q = addSearch.text.trim().toLowerCase();
							return (NiriSettings.xkb.layouts || []).filter(entry => !root.layouts.includes(entry.name) && (q === "" || `${entry.name} ${entry.description}`.toLowerCase().includes(q))).slice(0, 80);
						}
						ScrollBar.vertical: ThinScrollBar {}

						delegate: Clickable {
							id: hit

							required property var modelData

							function add() {
								root.write(root.entries.concat([{ layout: hit.modelData.name, variant: "" }]), `${hit.modelData.description} added`);
								adder.close();
							}

							width: matches.width - 8
							height: 40
							radius: Theme.radius.medium
							color: hit.hovered ? Theme.layer3 : "transparent"
							onClicked: hit.add()

							RowLayout {
								anchors.fill: parent
								anchors.leftMargin: 10
								anchors.rightMargin: 10
								spacing: 10

								StyledText {
									Layout.preferredWidth: 36
									text: hit.modelData.name
									font.family: Theme.monoFamily
									font.weight: Font.Bold
									tone: Theme.primary
								}

								StyledText {
									Layout.fillWidth: true
									text: hit.modelData.description
								}
							}
						}
					}
				}
			}
		}
	}

	StyledText {
		Layout.fillWidth: true
		visible: root.entries.length > 1
		text: "Drag a tile by its grip to change the order – the first one is the layout you start with. Switching between them needs a key (a bind or an option below)."
		tone: Theme.textSubtle
		font.pixelSize: Theme.size.small
		wrapMode: Text.WordWrap
	}
}
