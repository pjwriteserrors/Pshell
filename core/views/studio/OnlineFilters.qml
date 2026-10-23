pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets

// The Online tab's filters, as a sheet that unfolds from the button that
// opens it. Wallhaven: sorting, its period, purity, resolution, aspect
// ratio, colour and the API key; MoeWalls: sorting, period and resolution.
// The categories are not here, they stand as chips above the stage.
Rectangle {
	id: root

	required property var search
	property bool open: false
	property real maxHeight: 600
	readonly property bool wallhaven: root.search.source === "wallhaven"

	signal dismissed

	width: 456
	height: Math.min(root.maxHeight, column.implicitHeight + 40)
	radius: Theme.radius.huge
	color: Qt.alpha(Theme.base, 0.97)
	border.width: 1
	border.color: Theme.outline
	transformOrigin: Item.TopRight
	opacity: root.open ? 1 : 0
	scale: root.open ? 1 : 0.92
	visible: opacity > 0
	enabled: root.open

	Behavior on opacity {
		Anim {
			duration: Motion.short
		}
	}
	Behavior on scale {
		SpatialAnim {
			duration: Motion.medium
		}
	}
	Behavior on height {
		SpatialAnim {
			duration: Motion.medium
		}
	}

	// a part of the sheet that folds away when it means nothing
	component Section: Item {
		id: section

		property string title: ""
		property bool shown: true
		default property alias content: body.data
		property alias trailing: trailingSlot.data

		Layout.fillWidth: true
		Layout.preferredHeight: section.shown ? inner.implicitHeight + 20 : 0
		opacity: section.shown ? 1 : 0
		visible: Layout.preferredHeight > 0.5
		clip: true

		Behavior on Layout.preferredHeight {
			SpatialAnim {
				duration: Motion.medium
			}
		}
		Behavior on opacity {
			Anim {}
		}

		ColumnLayout {
			id: inner

			width: parent.width
			spacing: 10

			RowLayout {
				Layout.fillWidth: true
				Layout.preferredHeight: 26

				SectionLabel {
					Layout.fillWidth: true
					text: section.title
				}

				Row {
					id: trailingSlot

					spacing: 6
				}
			}

			ColumnLayout {
				id: body

				Layout.fillWidth: true
				spacing: 8
			}
		}
	}

	component Choices: Flow {
		id: choices

		property var options: []
		property var selected: []
		property bool dimmedOff: false
		signal picked(string value)

		Layout.fillWidth: true
		spacing: 6

		Repeater {
			model: choices.options

			delegate: Chip {
				required property var modelData

				readonly property string value: String(typeof modelData === "object" ? modelData.value : modelData)

				text: typeof modelData === "object" ? modelData.label : String(modelData).replace("x", " × ")
				icon: typeof modelData === "object" ? (modelData.icon ?? "") : ""
				selected: choices.selected.indexOf(value) >= 0
				enabled: typeof modelData !== "object" || modelData.enabled !== false
				opacity: enabled ? 1 : 0.4
				onClicked: choices.picked(value)
			}
		}
	}

	MouseArea {
		anchors.fill: parent
		acceptedButtons: Qt.AllButtons
		onWheel: wheel => wheel.accepted = true
	}

	Flickable {
		id: flick

		anchors.fill: parent
		anchors.margins: 20
		anchors.rightMargin: 14
		contentHeight: column.implicitHeight
		boundsBehavior: Flickable.StopAtBounds
		clip: true

		ScrollBar.vertical: ThinScrollBar {}

		ColumnLayout {
			id: column

			width: flick.width - 6
			spacing: 0

			// ── Wallhaven ────────────────────────────────────────────────
			Section {
				title: "Sort"
				shown: root.wallhaven

				trailing: IconButton {
					width: 26
					height: 26
					icon: root.search.wallhaven.order === "asc" ? "sort_ascending" : "sort_descending"
					iconSize: 15
					variant: "tonal"
					opacity: root.search.wallhaven.sorting === "random" ? 0 : 1
					visible: opacity > 0
					onClicked: root.search.set("order", root.search.wallhaven.order === "asc" ? "desc" : "asc")

					Behavior on opacity {
						Anim {}
					}
				}

				Choices {
					options: root.search.wallhavenSortings
					selected: [root.search.wallhaven.sorting]
					onPicked: value => root.search.set("sorting", value)
				}
			}

			Section {
				title: "Period"
				shown: root.wallhaven && root.search.wallhaven.sorting === "toplist"

				Choices {
					options: root.search.topRanges
					selected: [root.search.wallhaven.topRange]
					onPicked: value => root.search.set("topRange", value)
				}
			}

			Section {
				title: "Purity"
				shown: root.wallhaven

				Choices {
					options: root.search.purities.map(purity => Object.assign({}, purity, { enabled: purity.value !== "nsfw" || root.search.keySet, icon: purity.value === "nsfw" && !root.search.keySet ? "key_outline" : "" }))
					selected: root.search.wallhaven.purity
					onPicked: value => root.search.toggle("purity", value, true)
				}
			}

			Section {
				title: "Resolution"
				shown: root.wallhaven

				trailing: Segmented {
					width: 170
					height: 26
					options: [
						{ value: "atleast", label: "At least" },
						{ value: "exact", label: "Exactly" }
					]
					current: root.search.wallhaven.resolutionMode
					onSelected: value => root.search.set("resolutionMode", value)
				}

				Choices {
					readonly property bool exact: root.search.wallhaven.resolutionMode === "exact"

					options: [{ value: "", label: "Any" }].concat(root.search.wallhavenResolutions)
					selected: exact ? (root.search.wallhaven.resolutions.length > 0 ? root.search.wallhaven.resolutions : [""]) : [root.search.wallhaven.atleast]
					onPicked: value => {
						if (!exact) root.search.set("atleast", value);
						else if (value === "") root.search.set("resolutions", []);
						else root.search.toggle("resolutions", value, false);
					}
				}
			}

			Section {
				title: "Aspect ratio"
				shown: root.wallhaven

				Choices {
					options: [{ value: "", label: "Any" }].concat(root.search.ratios)
					selected: root.search.wallhaven.ratios.length > 0 ? root.search.wallhaven.ratios : [""]
					onPicked: value => value === "" ? root.search.set("ratios", []) : root.search.toggle("ratios", value, false)
				}
			}

			Section {
				title: "Colour"
				shown: root.wallhaven

				trailing: IconButton {
					width: 26
					height: 26
					icon: "close"
					iconSize: 14
					variant: "tonal"
					scale: root.search.wallhaven.color !== "" ? 1 : 0
					visible: scale > 0
					onClicked: root.search.set("color", "")

					Behavior on scale {
						SpatialAnim {
							duration: Motion.short
						}
					}
				}

				Flow {
					Layout.fillWidth: true
					spacing: 7

					Repeater {
						model: root.search.colors

						delegate: Item {
							id: swatch

							required property string modelData
							readonly property bool chosen: root.search.wallhaven.color === swatch.modelData

							width: 26
							height: 26

							Rectangle {
								anchors.centerIn: parent
								width: 26
								height: 26
								radius: 13
								color: "transparent"
								border.width: 2
								border.color: Theme.primary
								scale: swatch.chosen ? 1 : 0.6
								opacity: swatch.chosen ? 1 : 0

								Behavior on scale {
									SpatialAnim {
										duration: Motion.medium
									}
								}
								Behavior on opacity {
									Anim {
										duration: Motion.short
									}
								}
							}

							Rectangle {
								anchors.centerIn: parent
								width: swatch.chosen ? 16 : 20
								height: width
								radius: width / 2
								color: `#${swatch.modelData}`
								border.width: 1
								border.color: Theme.outline
								scale: swatchMouse.pressed ? 0.85 : (swatchMouse.containsMouse ? 1.12 : 1)

								Behavior on width {
									SpatialAnim {
										duration: Motion.medium
									}
								}
								Behavior on scale {
									SpatialAnim {
										duration: Motion.short
									}
								}
							}

							MouseArea {
								id: swatchMouse

								anchors.fill: parent
								hoverEnabled: true
								cursorShape: Qt.PointingHandCursor
								onClicked: root.search.set("color", swatch.chosen ? "" : swatch.modelData)
							}
						}
					}
				}
			}

			Section {
				title: "File type"
				shown: root.wallhaven

				Choices {
					options: root.search.fileTypes
					selected: [root.search.wallhaven.fileType]
					onPicked: value => root.search.set("fileType", value)
				}
			}

			Section {
				title: "API key"
				shown: root.wallhaven

				trailing: Glyph {
					icon: "check_decagram_outline"
					size: 16
					color: Theme.success
					scale: root.search.keySet ? 1 : 0

					Behavior on scale {
						SpatialAnim {
							duration: Motion.medium
						}
					}
				}

				RowLayout {
					Layout.fillWidth: true
					spacing: 8

					Field {
						id: keyField

						Layout.fillWidth: true
						Layout.preferredHeight: 36
						password: true
						icon: "key_outline"
						placeholder: root.search.keySet ? "Replace the key" : "Paste a key"
						onEscapePressed: root.dismissed()
						onAccepted: if (keyField.text.trim() !== "") {
							root.search.setKey(keyField.text);
							keyField.text = "";
						}
					}

					TextButton {
						Layout.preferredHeight: 36
						variant: keyField.text.trim() !== "" ? "filled" : "ghost"
						text: keyField.text.trim() !== "" ? "Save" : "Remove"
						confirm: keyField.text.trim() === ""
						confirmText: "Remove?"
						busy: root.search.keyBusy
						visible: keyField.text.trim() !== "" || root.search.keySet
						onActivated: {
							root.search.setKey(keyField.text);
							keyField.text = "";
						}
					}
				}

				StyledText {
					Layout.fillWidth: true
					visible: root.search.keyError !== ""
					text: root.search.keyError
					tone: Theme.danger
					font.pixelSize: Theme.size.small
				}
			}

			// ── MoeWalls ─────────────────────────────────────────────────
			Section {
				title: "Sort"
				shown: !root.wallhaven

				Choices {
					options: root.search.moewallsSortings
					selected: [root.search.moewallsSorting]
					onPicked: value => {
						if (value === "popular") root.search.choosePopular();
						else root.search.set("sorting", value);
					}
				}
			}

			Section {
				title: "Period"
				shown: !root.wallhaven && root.search.moewallsSorting === "popular"

				Choices {
					options: root.search.moewallsRanges
					selected: [root.search.moewalls.range]
					onPicked: value => root.search.set("range", value)
				}
			}

			Section {
				title: "Resolution"
				shown: !root.wallhaven

				Choices {
					options: [{ value: "", label: "Any" }].concat(root.search.moewallsResolutions)
					selected: [root.search.moewalls.resolution]
					onPicked: value => root.search.set("resolution", value)
				}
			}

			// ── found, and back to the defaults ─────────────────────────
			RowLayout {
				Layout.fillWidth: true
				Layout.topMargin: 2

				StyledText {
					Layout.fillWidth: true
					text: root.search.total > 0 ? `${root.search.total.toLocaleString(Qt.locale(), "f", 0)} found` : ""
					tone: Theme.textSubtle
					font.pixelSize: Theme.size.small
				}

				TextButton {
					height: 30
					variant: "ghost"
					text: "Reset"
					icon: "restore"
					opacity: root.search.activeFilters > 0 ? 1 : 0
					visible: opacity > 0
					onActivated: root.search.resetFilters()

					Behavior on opacity {
						Anim {}
					}
				}
			}
		}
	}
}
