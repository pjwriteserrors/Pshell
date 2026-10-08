pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services
import qs.core.views.overlays.keybinds

// xkb options: the ones people want as tiles that show the keys they change,
// every other one from xkb's list. Options for the same key replace each
// other (Caps Lock can be Escape or Ctrl, not both).
ColumnLayout {
	id: root

	readonly property var path: ["input", "keyboard", "xkb", "options"]
	readonly property var options: String(NiriSettings.arg(root.path, "")).split(",").map(s => s.trim()).filter(s => s !== "")
	readonly property var popular: [
		{ value: "caps:escape", slot: "caps", from: "Caps", to: "Esc", label: "Caps Lock is Escape" },
		{ value: "ctrl:nocaps", slot: "caps", from: "Caps", to: "Ctrl", label: "Caps Lock is Ctrl" },
		{ value: "caps:swapescape", slot: "caps", from: "Caps", to: "Esc", swap: true, label: "Caps Lock and Escape swap" },
		{ value: "altwin:swap_alt_win", slot: "altwin", from: "Alt", to: "Super", swap: true, label: "Alt and Super swap" },
		{ value: "compose:ralt", slot: "compose", from: "AltGr", to: "◌́", label: "Right Alt composes é ü ñ" },
		{ value: "grp:alt_shift_toggle", slot: "grp", from: "Alt+Shift", to: "⌨", label: "Alt+Shift switches layout" },
		{ value: "grp:win_space_toggle", slot: "grp", from: "Super+Space", to: "⌨", label: "Super+Space switches layout" }
	]

	function slotOf(option) {
		const known = root.popular.find(p => p.value === option);
		if (known) return known.slot;
		if (option.startsWith("caps:") || option === "ctrl:nocaps" || option === "ctrl:swapcaps") return "caps";
		return option.split(":")[0];
	}

	function write(list, note) {
		if (list.length === 0) NiriSettings.reset(root.path, note);
		else NiriSettings.set(root.path, list.join(","), note, "");
	}

	function toggle(option) {
		if (root.options.includes(option)) {
			root.write(root.options.filter(o => o !== option), "Option removed");
			return;
		}
		const slot = root.slotOf(option);
		root.write(root.options.filter(o => root.slotOf(o) !== slot || slot === "misc" || slot === "lv3").concat([option]), "Option added");
	}

	spacing: 12

	GridLayout {
		Layout.fillWidth: true
		columns: Math.max(2, Math.floor(width / 230))
		columnSpacing: 10
		rowSpacing: 10

		Repeater {
			model: root.popular

			delegate: Clickable {
				id: tile

				required property var modelData
				readonly property bool on: root.options.includes(tile.modelData.value)

				Layout.fillWidth: true
				implicitHeight: 92
				radius: Theme.radius.large
				pressedScale: 0.96
				color: tile.on ? Theme.primaryContainer : (tile.hovered ? Theme.layer3 : Theme.layer2)
				border.width: tile.on ? 1.5 : 0
				border.color: Theme.primary
				onClicked: root.toggle(tile.modelData.value)

				RowLayout {
					id: keys

					anchors.horizontalCenter: parent.horizontalCenter
					y: 12
					spacing: 8

					Keycap {
						text: tile.modelData.from
						size: 24
						lit: tile.on
					}

					Glyph {
						icon: tile.modelData.swap ? "swap_horizontal" : "arrow_right"
						size: 16
						color: tile.on ? Theme.primary : Theme.textSubtle
						rotation: tile.on && tile.modelData.swap ? 180 : 0

						Behavior on rotation {
							SpatialAnim {
								duration: Motion.long
							}
						}
					}

					Keycap {
						text: tile.modelData.to
						size: 24
						lit: tile.on
					}
				}

				StyledText {
					anchors.horizontalCenter: parent.horizontalCenter
					anchors.bottom: parent.bottom
					anchors.bottomMargin: 12
					width: parent.width - 16
					horizontalAlignment: Text.AlignHCenter
					text: tile.modelData.label
					tone: tile.on ? Theme.primary : Theme.textMuted
					font.pixelSize: Theme.size.small
					font.weight: Font.Medium
				}
			}
		}
	}

	// the others that are on, and all of xkb's
	Flow {
		Layout.fillWidth: true
		spacing: 6

		Repeater {
			model: root.options.filter(o => !root.popular.some(p => p.value === o))

			delegate: Chip {
				required property string modelData

				text: modelData
				icon: "close"
				selected: true
				onClicked: root.toggle(modelData)
			}
		}

		Chip {
			text: "Every xkb option…"
			icon: "format_list_bulleted"
			onClicked: everything.open()

			PickList {
				id: everything

				y: parent.height + 4
				width: 440
				placeholder: "ctrl, compose, numpad…"
				entries: (NiriSettings.xkb.options || []).map(o => ({
					value: o.name,
					label: o.description,
					detail: `${(NiriSettings.xkb.groups || {})[o.group] ?? o.group} · ${o.name}`,
					icon: root.options.includes(o.name) ? "check_circle" : ""
				}))
				onPicked: value => root.toggle(String(value))
			}
		}
	}
}
