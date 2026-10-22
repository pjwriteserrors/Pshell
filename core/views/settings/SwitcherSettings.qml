pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "../switcher/Layouts.js" as Layouts

// The shell's window switcher on the Overview page: its layout (each tile
// drawn by the same layout code the switcher uses), which windows, the
// pictures, the picked one's effect, how it opens and what is behind it.
ColumnLayout {
	id: root

	spacing: 14

	// eight made-up windows of mixed shapes for the layout tiles
	readonly property var sample: [
		{ width: 1600, height: 900, workspaceId: 1, workspaceIdx: 1, output: "A" },
		{ width: 900, height: 1000, workspaceId: 1, workspaceIdx: 1, output: "A" },
		{ width: 1600, height: 1000, workspaceId: 2, workspaceIdx: 2, output: "A" },
		{ width: 1200, height: 900, workspaceId: 3, workspaceIdx: 1, output: "B" },
		{ width: 1600, height: 900, workspaceId: 3, workspaceIdx: 1, output: "B" },
		{ width: 1000, height: 1000, workspaceId: 4, workspaceIdx: 2, output: "B" }
	]

	RowLayout {
		Layout.fillWidth: true
		spacing: 12

		SectionLabel {
			Layout.fillWidth: true
			text: "Layout – [ and ] change it while it is open"
		}

		TextButton {
			text: "Try it"
			icon: "play"
			onActivated: Switcher.show("", "")
		}
	}

	GridLayout {
		Layout.fillWidth: true
		columns: 3
		columnSpacing: 10
		rowSpacing: 10

		Repeater {
			model: Switcher.layouts

			delegate: Rectangle {
				id: tile

				required property var modelData
				readonly property bool on: Switcher.layout === tile.modelData.id
				// laid out on a screen four times the tile's size, then shrunk to it
				readonly property real zoom: 4
				readonly property var drawn: Layouts.compute(tile.modelData.id, root.sample, 1, art.width * tile.zoom, art.height * tile.zoom, 0.9, name => name === "A" ? 0 : 1)

				Layout.fillWidth: true
				Layout.preferredHeight: 128
				radius: Theme.radius.medium
				color: tile.on ? Theme.primaryContainer : Theme.layer1
				border.width: tile.on ? 2 : 1
				border.color: tile.on ? Theme.primary : Theme.outline

				Behavior on color {
					ColorAnim {}
				}

				Item {
					id: art

					anchors.left: parent.left
					anchors.right: parent.right
					anchors.top: parent.top
					anchors.margins: 8
					height: 76
					clip: true

					Item {
						width: art.width * tile.zoom
						height: art.height * tile.zoom
						scale: 1 / tile.zoom
						transformOrigin: Item.TopLeft

					Repeater {
						model: tile.drawn.groups

						delegate: Rectangle {
							required property var modelData

							x: modelData.x
							y: modelData.y
							width: modelData.w
							height: modelData.h
							radius: 16
							color: Qt.alpha(Theme.fg, 0.05)
							border.width: 4
							border.color: Qt.alpha(Theme.fg, 0.1)
						}
					}

					Repeater {
						model: tile.drawn.hero ? [tile.drawn.hero] : []

						delegate: Rectangle {
							required property var modelData

							x: modelData.x
							y: modelData.y
							width: modelData.w
							height: modelData.h
							radius: 12
							color: Qt.alpha(Theme.primary, 0.5)
						}
					}

					Repeater {
						model: tile.drawn.cards

						delegate: Rectangle {
							id: mini

							required property var modelData
							required property int index

							x: mini.modelData.x
							y: mini.modelData.y
							z: mini.modelData.z
							width: mini.modelData.w
							height: mini.modelData.h
							rotation: mini.modelData.rotation
							scale: mini.modelData.scale
							opacity: mini.modelData.opacity
							radius: mini.modelData.row ? 8 : 12
							color: mini.index === 1 ? Theme.primary : Qt.alpha(Theme.fg, mini.modelData.row ? 0.14 : 0.22)
							transform: Rotation {
								origin.x: mini.width / 2
								origin.y: mini.height / 2
								axis {
									x: 0
									y: 1
									z: 0
								}
								angle: mini.modelData.yaw
							}
						}
					}
					}
				}

				Column {
					anchors.left: parent.left
					anchors.right: parent.right
					anchors.bottom: parent.bottom
					anchors.margins: 8
					spacing: 1

					StyledText {
						text: tile.modelData.label
						font.weight: Font.DemiBold
						tone: tile.on ? Theme.primary : Theme.text
					}

					StyledText {
						width: parent.width
						text: tile.modelData.about
						elide: Text.ElideRight
						font.pixelSize: Theme.size.tiny
						tone: Theme.textSubtle
					}
				}

				MouseArea {
					anchors.fill: parent
					cursorShape: Qt.PointingHandCursor
					onClicked: Switcher.set("layout", tile.modelData.id)
				}
			}
		}
	}

	SwitcherChoice {
		label: "Windows"
		name: "scope"
		options: [{ value: "all", label: "All" }, { value: "others", label: "Other workspaces" }, { value: "output", label: "This monitor" }, { value: "workspace", label: "This workspace" }]
	}

	SwitcherChoice {
		label: "Pictures"
		name: "previews"
		options: [{ value: "live", label: "Live" }, { value: "snapshot", label: "Once when it opens" }, { value: "icons", label: "Icons only" }]
	}

	SwitcherChoice {
		label: "Picked window"
		name: "effect"
		options: [{ value: "glow", label: "Glow" }, { value: "lift", label: "Lift" }, { value: "spotlight", label: "Spotlight" }, { value: "outline", label: "Outline" }]
	}

	SwitcherChoice {
		label: "Coming in"
		name: "entrance"
		options: [{ value: "zoom", label: "Zoom" }, { value: "rise", label: "Rise" }, { value: "cascade", label: "Cascade" }, { value: "fade", label: "Fade" }]
	}

	SwitcherChoice {
		label: "Names"
		name: "titles"
		options: [{ value: "selected", label: "Picked one" }, { value: "all", label: "All" }, { value: "none", label: "None" }]
	}

	SwitcherChoice {
		label: "Behind it"
		name: "backdrop"
		options: [{ value: "blur", label: "Blurred" }, { value: "dim", label: "Darker" }, { value: "clear", label: "Clear" }]
	}

	RowLayout {
		Layout.fillWidth: true
		spacing: 12

		ValueSlider {
			from: 0
			to: 1
			step: 0.05
			label: "Strength"
			value: Switcher.backdropStrength
			format: v => `${Math.round(v * 100)}%`
			onMoved: v => Switcher.set("backdropStrength", v)
		}

		ValueSlider {
			from: 0.6
			to: 1.6
			step: 0.05
			label: "Size"
			value: Switcher.size
			format: v => `${Math.round(v * 100)}%`
			onMoved: v => Switcher.set("size", v)
		}
	}

	RowLayout {
		Layout.fillWidth: true
		spacing: 12

		ValueSlider {
			from: 0
			to: 40
			step: 1
			label: "Corners"
			unit: " px"
			value: Switcher.radius
			onMoved: v => Switcher.set("corner", Math.round(v))
		}

		ValueSlider {
			from: 0
			to: 400
			step: 10
			label: "Shows after"
			value: Switcher.delay
			format: v => `${v} ms`
			onMoved: v => Switcher.set("delay", Math.round(v))
		}
	}

	FlagRow {
		title: "Corners as round as the windows"
		subtitle: `${Theme.windowRadius} px, like niri draws them`
		checked: Switcher.corner < 0
		onToggled: on => Switcher.set("corner", on ? -1 : Math.round(Switcher.radius))
	}

	FlagRow {
		title: "Numbers on the cards"
		subtitle: "1 to 9 switch at once"
		checked: Switcher.numbers
		onToggled: on => Switcher.set("numbers", on)
	}

	StyledText {
		Layout.fillWidth: true
		visible: Switcher.bindNote !== ""
		text: Switcher.bindNote
		tone: Theme.warning
		font.pixelSize: Theme.size.small
		wrapMode: Text.WordWrap
	}
}
