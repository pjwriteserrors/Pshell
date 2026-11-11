pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services
import qs.core.views.settings.colours

// Colours (core/services/Colours.qml): the engine that reads the wallpaper,
// the style and mode worn, and the tuning of every style. The sliders change
// a draft shown on the wallpaper worn; Apply keeps it and recolours.
SettingsPage {
	id: root

	title: "Colours"
	description: ""

	// what is being looked at and tuned; worn once applied
	property string style: Colours.style
	property string mode: Colours.mode
	readonly property bool own: Colours.engine === "pshell"
	readonly property bool changed: Colours.dirty || root.style !== Colours.style || root.mode !== Colours.mode
	readonly property var params: Colours.params(root.style)
	readonly property var scheme: Colours.preview[root.style]?.[root.mode] ?? null
	// held: the colours worn now, to compare
	property bool comparing: false
	readonly property var worn: ({
			background: Theme.wal.special?.background ?? "#141414",
			foreground: Theme.wal.special?.foreground ?? "#e6e6e6",
			colors: Array.from({ length: 16 }, (_, i) => Theme.wal.colors?.[`color${i}`] ?? "#808080"),
			roles: Theme.wal.roles ?? null
		})

	onActiveChanged: Colours.previewWanted = root.active && root.own
	onOwnChanged: Colours.previewWanted = root.active && root.own
	Component.onCompleted: Colours.previewWanted = root.active && root.own
	Component.onDestruction: Colours.previewWanted = false

	// the engine's palette and style as they are worn, when the page opens
	Connections {
		target: Colours

		function onStyleChanged() {
			if (!root.changed) root.style = Colours.style;
		}
		function onModeChanged() {
			if (!root.changed) root.mode = Colours.mode;
		}
	}

	headerTrailing: RowLayout {
		spacing: 8
		visible: root.own

		TextButton {
			text: "Discard"
			icon: "restore"
			visible: root.changed
			onActivated: {
				Colours.discard();
				root.style = Colours.style;
				root.mode = Colours.mode;
			}
		}

		TextButton {
			text: "Apply"
			icon: "check"
			variant: "filled"
			enabled: root.changed && !Colours.applying
			busy: Colours.applying
			onActivated: Colours.apply(root.style, root.mode)
		}
	}

	// ── engine ─────────────────────────────────────────────────────────────
	SettingCard {
		anchor: "colours-engine"
		title: "Engine"
		icon: "palette_outline"
		modified: !root.own
		onReset: Colours.setEngine("pshell")

		Segmented {
			Layout.fillWidth: true
			options: [
				{ value: "pshell", label: "Pshell", icon: "palette" },
				{ value: "wallust", label: "wallust", icon: "palette_outline" }
			]
			current: Colours.engine
			onSelected: value => Colours.setEngine(value)
		}
	}

	// ── style ──────────────────────────────────────────────────────────────
	SettingCard {
		anchor: "colours-style"
		title: "Style"
		icon: "image_filter_hdr"
		visible: root.own

		trailing: Segmented {
			implicitWidth: 120
			options: [
				{ value: "dark", label: "", icon: "weather_night" },
				{ value: "light", label: "", icon: "weather_sunny" }
			]
			current: root.mode
			onSelected: value => root.mode = value
		}

		GridLayout {
			Layout.fillWidth: true
			columns: Colours.styles.length
			columnSpacing: 10

			Repeater {
				model: Colours.styles

				delegate: StyleTile {
					required property string modelData

					Layout.fillWidth: true
					style: modelData
				}
			}
		}
	}

	// ── preview ────────────────────────────────────────────────────────────
	SettingCard {
		anchor: "colours-preview"
		title: "Preview"
		icon: "circle_half_full"
		visible: root.own

		trailing: IconButton {
			implicitWidth: 34
			implicitHeight: 34
			icon: "compare"
			checked: pressed
			onPressedChanged: root.comparing = pressed
		}

		AppPreview {
			Layout.fillWidth: true
			scheme: root.comparing ? root.worn : root.scheme
			title: root.comparing ? "" : (Colours.styleNames[root.style] ?? root.style)
			mode: root.comparing ? (Theme.dark ? "dark" : "light") : root.mode
		}
	}

	// ── tuning ─────────────────────────────────────────────────────────────
	SettingCard {
		anchor: "colours-tuning"
		title: Colours.styleNames[root.style] ?? root.style
		icon: "tune"
		visible: root.own
		modified: !Colours.isDefault(root.style)
		onReset: Colours.resetStyle(root.style)

		ValueSlider {
			from: 20
			to: 200
			step: 5
			unit: " %"
			icon: "water"
			label: "Saturation"
			value: Math.round(Number(root.params.chroma ?? 1) * 100)
			onMoved: v => Colours.setParam(root.style, "chroma", v / 100)
		}

		ValueSlider {
			from: -20
			to: 20
			step: 1
			icon: "brightness_6"
			label: "Brightness"
			format: v => `${v > 0 ? "+" : ""}${Math.round(v)}`
			value: Math.round(Number(root.params.lightness ?? 0) * 100)
			onMoved: v => Colours.setParam(root.style, "lightness", v / 100)
		}

		ValueSlider {
			from: 0
			to: 100
			step: 5
			unit: " %"
			icon: "format_color_fill"
			label: "Background depth"
			value: Math.round(Number(root.params.depth ?? 0.6) * 100)
			onMoved: v => Colours.setParam(root.style, "depth", v / 100)
		}

		ValueSlider {
			from: 0
			to: 100
			step: 5
			unit: " %"
			icon: "gradient_horizontal"
			label: "Background tint"
			value: Math.round(Number(root.params.tint ?? 0.4) * 100)
			onMoved: v => Colours.setParam(root.style, "tint", v / 100)
		}

		ValueSlider {
			from: 2
			to: 7
			step: 0.1
			decimals: 1
			unit: " : 1"
			icon: "contrast_box"
			label: "Minimum contrast"
			value: Number(root.params.contrast ?? 4)
			onMoved: v => Colours.setParam(root.style, "contrast", v)
		}

		ValueSlider {
			from: 0
			to: 100
			step: 5
			unit: " %"
			icon: "shape_outline"
			label: "Variety"
			value: Math.round(Number(root.params.variety ?? 0.5) * 100)
			onMoved: v => Colours.setParam(root.style, "variety", v / 100)
		}
	}

	// one style: its background with the accents on it; the worn one marked
	component StyleTile: Rectangle {
		id: tile

		property string style: ""
		readonly property var cell: Colours.preview[tile.style]?.[root.mode] ?? null
		readonly property bool picked: root.style === tile.style

		implicitHeight: 84
		radius: Theme.radius.large
		color: tile.cell ? tile.cell.background : Theme.layer2
		border.width: tile.picked ? 2 : 0
		border.color: Theme.primary

		Behavior on color {
			ColorAnim {}
		}

		ColumnLayout {
			anchors.fill: parent
			anchors.margins: 12
			spacing: 8

			StyledText {
				Layout.fillWidth: true
				text: Colours.styleNames[tile.style] ?? tile.style
				color: tile.cell ? tile.cell.foreground : Theme.text
				font.weight: Font.Medium
				elide: Text.ElideRight
			}

			Row {
				spacing: -5

				Repeater {
					model: ["primary", "secondary", "tertiary"]

					delegate: Rectangle {
						required property string modelData

						width: 18
						height: 18
						radius: 9
						color: tile.cell?.roles?.[modelData] ?? Theme.layer3
						border.width: 1.5
						border.color: tile.color
					}
				}
			}

			Glyph {
				visible: Colours.style === tile.style && Colours.mode === root.mode
				icon: "check"
				size: 14
				color: tile.cell ? tile.cell.foreground : Theme.textMuted
			}
		}

		MouseArea {
			anchors.fill: parent
			cursorShape: Qt.PointingHandCursor
			onClicked: root.style = tile.style
		}
	}
}
