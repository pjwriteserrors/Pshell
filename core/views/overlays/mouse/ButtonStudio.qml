pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "Controls.js" as Controls

// What one control does, laid out the way it is used: the click in the
// middle of a cross of swipes, the other ways around it. Pick the control
// on the drawing, in the row of chips, or by pressing it on the mouse; pick
// where (everywhere, or one app); pick a tile and say what it does.
ColumnLayout {
	id: root

	property string control: "gesture"
	property string app: ""
	property bool active: false
	readonly property var meta: Controls.byId(root.control)
	readonly property var triggers: Controls.triggersOf(root.control)
	readonly property bool editable: root.triggers.length > 0
	property alias picker: picker

	signal controlPicked(string control)
	signal appPicked(string app)

	spacing: 16

	function tileFor(trigger) {
		const own = Mouse.ruleFor(root.control, trigger, root.app);
		const inherited = !own && root.app !== "" ? Mouse.ruleFor(root.control, trigger, "") : null;
		const rule = own ?? inherited;
		let info;
		if (rule) info = Mouse.describe(rule.action, root.control);
		else if (trigger === "click" || root.control === "thumb") info = { label: root.control === "thumb" ? `Scroll ${trigger === "left" ? "back" : "on"}` : Mouse.nativeLabel(root.control), icon: "", plain: true };
		else info = { label: "—", icon: "", plain: true };
		return { own: !!own, inherited: !!inherited, info };
	}

	function edit(trigger) {
		picker.show(root.control, trigger, root.app);
	}

	function applyPreset(preset) {
		for (const r of preset.rules)
			Mouse.assign(preset.control, r.trigger, root.app, r.action, { repeat: r.repeat === true });
		root.controlPicked(preset.control);
		Mouse.play("COMPLETED");
	}

	// the real mouse: a press picks the control, a fired rule lights its tile
	Connections {
		target: Mouse
		enabled: root.active

		function onPressedControl(control, down) {
			if (down && control !== root.control && Controls.byId(control) && control !== "left" && control !== "right") root.controlPicked(control);
		}
		function onFired(rule, control, trigger) {
			if (control !== root.control) return;
			const tile = tiles.find(t => t.trigger === trigger);
			if (tile) tile.flash();
		}
		function onWheeled(wheel, delta) {
			if (wheel === "thumb" && root.control === "thumb") {
				const tile = tiles.find(t => t.trigger === (delta > 0 ? "right" : "left"));
				if (tile) tile.flash();
			}
		}
	}

	property var tiles: []

	// ── the controls ───────────────────────────────────────────────────────
	Flow {
		Layout.fillWidth: true
		spacing: 6

		Repeater {
			model: Controls.controls.filter(c => c.triggers !== "none")

			delegate: Chip {
				required property var modelData

				text: modelData.label
				icon: modelData.icon
				selected: root.control === modelData.id
				onClicked: root.controlPicked(modelData.id)
			}
		}
	}

	// ── where ──────────────────────────────────────────────────────────────
	RowLayout {
		Layout.fillWidth: true
		spacing: 10

		StyledText {
			text: "Where"
			tone: Theme.textSubtle
			font.pixelSize: Theme.size.small
			font.weight: Font.DemiBold
		}

		Flow {
			Layout.fillWidth: true
			spacing: 6

			AppChip {
				app: ""
			}

			Repeater {
				model: Mouse.apps

				delegate: AppChip {
					required property string modelData

					app: modelData
				}
			}

			Clickable {
				width: 34
				height: 34
				radius: 17
				color: Theme.layer2
				onClicked: appList.open()

				Glyph {
					anchors.centerIn: parent
					icon: "plus"
					size: 16
					color: Theme.textMuted
				}

				PickList {
					id: appList

					y: parent.height + 6
					placeholder: "An open window or an app id"
					entries: {
						const seen = new Set(Mouse.apps);
						const out = [];
						for (const w of Niri.windows) {
							const id = String(w.app_id || "");
							if (!id || seen.has(id)) continue;
							seen.add(id);
							out.push({ value: id, label: id, detail: String(w.title || ""), icon: "application_outline" });
						}
						return out;
					}
					searchable: true
					onPicked: value => {
						Mouse.addApp(String(value));
						root.appPicked(String(value));
					}
				}
			}
		}

		StyledText {
			visible: root.active && Mouse.focusApp !== ""
			text: `Now: ${Mouse.focusApp}`
			tone: Theme.textFaint
			font.pixelSize: Theme.size.small
		}
	}

	// ── not remappable ─────────────────────────────────────────────────────
	Rectangle {
		Layout.fillWidth: true
		visible: !root.editable
		implicitHeight: 90
		radius: Theme.radius.large
		color: Theme.layer2

		RowLayout {
			anchors.fill: parent
			anchors.margins: 18
			spacing: 14

			Glyph {
				icon: "lock_outline"
				size: 22
				color: Theme.textMuted
			}

			StyledText {
				Layout.fillWidth: true
				text: "The mouse keeps the left and right button to itself – they always click. Every other control can do what you like."
				tone: Theme.textMuted
				wrapMode: Text.WordWrap
			}
		}
	}

	// ── the thumb wheel ────────────────────────────────────────────────────
	RowLayout {
		Layout.fillWidth: true
		visible: root.control === "thumb"
		spacing: 12

		Repeater {
			model: Controls.thumbTriggers

			delegate: TriggerTile {
				id: thumbTile

				required property var modelData
				readonly property var tile: root.tileFor(thumbTile.modelData.id)

				Layout.fillWidth: true
				trigger: thumbTile.modelData.id
				triggerLabel: thumbTile.modelData.label
				triggerIcon: thumbTile.modelData.icon
				info: thumbTile.tile.info
				own: thumbTile.tile.own
				inherited: thumbTile.tile.inherited
				onClicked: root.edit(thumbTile.modelData.id)
				Component.onCompleted: root.tiles = root.tiles.concat([thumbTile])
				Component.onDestruction: root.tiles = root.tiles.filter(t => t !== thumbTile)
			}
		}
	}

	StyledText {
		Layout.fillWidth: true
		visible: root.control === "thumb"
		text: "Without a rule the thumb wheel scrolls sideways, as it does on its own. Its direction is set under Scrolling."
		tone: Theme.textFaint
		font.pixelSize: Theme.size.small
		wrapMode: Text.WordWrap
	}

	// ── a button: the cross, then the rest ─────────────────────────────────
	Item {
		id: cross

		readonly property real cellW: Math.min(210, (cross.width - 16) / 3)
		readonly property real cellH: 70
		readonly property bool live: Mouse.moveControl === root.control && !!Mouse.pressed[root.control]
		readonly property real distance: Mouse.option("swipeDistance", 70)
		readonly property real nx: cross.live ? Mouse.moveX / cross.distance : 0
		readonly property real ny: cross.live ? Mouse.moveY / cross.distance : 0

		Layout.fillWidth: true
		Layout.preferredHeight: cross.cellH * 3 + 16
		visible: root.editable && root.control !== "thumb"

		// guides from the middle
		Rectangle {
			anchors.centerIn: parent
			width: cross.cellW * 2 + 16
			height: 2
			radius: 1
			color: Theme.outline
		}
		Rectangle {
			anchors.centerIn: parent
			width: 2
			height: parent.height - cross.cellH
			radius: 1
			color: Theme.outline
		}

		Repeater {
			model: [
				{ id: "up", col: 1, row: 0 }, { id: "left", col: 0, row: 1 }, { id: "click", col: 1, row: 1 },
				{ id: "right", col: 2, row: 1 }, { id: "down", col: 1, row: 2 }
			]

			delegate: TriggerTile {
				id: crossTile

				required property var modelData
				readonly property var tile: root.tileFor(crossTile.modelData.id)
				readonly property var meta: Controls.swipes.find(s => s.id === crossTile.modelData.id)

				x: (cross.width - cross.cellW * 3 - 16) / 2 + crossTile.modelData.col * (cross.cellW + 8)
				y: crossTile.modelData.row * (cross.cellH + 8)
				width: cross.cellW
				height: cross.cellH
				trigger: crossTile.modelData.id
				triggerLabel: crossTile.modelData.id === "click" ? "Click" : (crossTile.meta?.label ?? "")
				triggerIcon: crossTile.modelData.id === "click" ? "gesture_tap" : (crossTile.meta?.icon ?? "")
				info: crossTile.tile.info
				own: crossTile.tile.own
				inherited: crossTile.tile.inherited
				approach: {
					if (!cross.live) return 0;
					const along = (v, other) => Math.max(0, Math.min(1, v)) * (Math.abs(v) >= Math.abs(other) ? 1 : 0.3);
					switch (crossTile.modelData.id) {
					case "up": return along(-cross.ny, cross.nx);
					case "down": return along(cross.ny, cross.nx);
					case "left": return along(-cross.nx, cross.ny);
					case "right": return along(cross.nx, cross.ny);
					}
					return Math.max(0, 1 - Math.hypot(cross.nx, cross.ny));
				}
				z: crossTile.modelData.id === "click" ? 2 : 1
				onClicked: root.edit(crossTile.modelData.id)
				Component.onCompleted: root.tiles = root.tiles.concat([crossTile])
				Component.onDestruction: root.tiles = root.tiles.filter(t => t !== crossTile)

				Behavior on approach {
					Anim {
						duration: Motion.micro
					}
				}
			}
		}

		// the press itself, a dot travelling from the middle
		Rectangle {
			width: 14
			height: 14
			radius: 7
			z: 5
			color: Theme.primary
			border.width: 3
			border.color: Qt.alpha(Theme.primary, 0.3)
			opacity: cross.live ? 1 : 0
			scale: cross.live ? 1 : 0.4
			x: cross.width / 2 - 7 + Math.max(-1.2, Math.min(1.2, cross.nx)) * (cross.cellW + 8)
			y: cross.height / 2 - 7 + Math.max(-1.2, Math.min(1.2, cross.ny)) * (cross.cellH + 8)

			Behavior on opacity {
				Anim {
					duration: Motion.short
				}
			}
			Behavior on scale {
				SpatialAnim {}
			}
			Behavior on x {
				SpatialAnim {
					duration: Motion.micro
				}
			}
			Behavior on y {
				SpatialAnim {
					duration: Motion.micro
				}
			}
		}
	}

	// the other ways
	GridLayout {
		Layout.fillWidth: true
		visible: root.editable && root.control !== "thumb"
		columns: root.width > 640 ? 3 : 2
		rowSpacing: 8
		columnSpacing: 8

		Repeater {
			model: Controls.extras

			delegate: TriggerTile {
				id: extraTile

				required property var modelData
				readonly property var tile: root.tileFor(extraTile.modelData.id)

				Layout.fillWidth: true
				Layout.preferredWidth: 1
				compact: true
				trigger: extraTile.modelData.id
				triggerLabel: extraTile.modelData.label
				triggerIcon: extraTile.modelData.icon
				info: extraTile.tile.info
				own: extraTile.tile.own
				inherited: extraTile.tile.inherited
				onClicked: root.edit(extraTile.modelData.id)
				Component.onCompleted: root.tiles = root.tiles.concat([extraTile])
				Component.onDestruction: root.tiles = root.tiles.filter(t => t !== extraTile)
			}
		}
	}

	RowLayout {
		Layout.fillWidth: true
		visible: root.editable
		spacing: 8

		Glyph {
			icon: Mouse.inCharge ? "gesture_tap_button" : "information_outline"
			size: 14
			color: Theme.textFaint
		}

		StyledText {
			Layout.fillWidth: true
			text: Mouse.inCharge ? (root.control === "thumb" ? "Turn the thumb wheel: the tile it would use lights up." : "Press a button on the mouse to pick it here; what it does lights up as it happens.") : "These rules start working once the shell has the mouse (Solaar above)."
			tone: Theme.textFaint
			font.pixelSize: Theme.size.small
			wrapMode: Text.WordWrap
		}

		TextButton {
			implicitHeight: 30
			variant: "ghost"
			icon: "auto_fix"
			text: "Presets"
			onActivated: presetList.open()

			PickList {
				id: presetList

				x: parent.width - width
				y: parent.height + 6
				width: 380
				entries: Controls.presets.map(p => ({ value: p.id, label: p.label, detail: `${Controls.byId(p.control).label}: ${p.detail}`, icon: p.icon }))
				onPicked: value => root.applyPreset(Controls.presets.find(p => p.id === value))
			}
		}
	}

	ActionPicker {
		id: picker

		onChosen: (action, extra) => Mouse.assign(picker.control, picker.trigger, picker.app, action, extra)
		onCleared: Mouse.assign(picker.control, picker.trigger, picker.app, null)
	}

	// one place: everywhere, or an app
	component AppChip: Clickable {
		id: chip

		property string app: ""
		readonly property bool picked: root.app === chip.app
		readonly property string iconSource: chip.app === "" ? "" : AppIcons.forAppId(chip.app)

		width: chipRow.implicitWidth + 24
		height: 34
		radius: 17
		color: chip.picked ? Theme.primary : Theme.layer2
		acceptedButtons: Qt.LeftButton | Qt.RightButton
		onClicked: root.appPicked(chip.app)
		onRightClicked: if (chip.app !== "") removeMenu.open()

		Behavior on width {
			SpatialAnim {
				duration: Motion.medium
			}
		}

		Row {
			id: chipRow

			anchors.centerIn: parent
			spacing: 7

			Glyph {
				visible: chip.app === "" || chip.iconSource === ""
				anchors.verticalCenter: parent.verticalCenter
				icon: chip.app === "" ? "earth" : "application_outline"
				size: 15
				color: chip.picked ? Theme.onPrimary : Theme.textMuted
			}

			Image {
				visible: chip.app !== "" && chip.iconSource !== ""
				anchors.verticalCenter: parent.verticalCenter
				width: 18
				height: 18
				sourceSize: Qt.size(36, 36)
				source: chip.iconSource
			}

			StyledText {
				anchors.verticalCenter: parent.verticalCenter
				text: chip.app === "" ? "Everywhere" : chip.app
				tone: chip.picked ? Theme.onPrimary : Theme.text
				font.weight: chip.picked ? Font.DemiBold : Font.Medium
			}

			// how many rules it has of its own
			Rectangle {
				readonly property int count: Mouse.rules.filter(r => (r.app ?? "") === chip.app && r.control === root.control).length

				visible: count > 0
				anchors.verticalCenter: parent.verticalCenter
				width: 18
				height: 18
				radius: 9
				color: chip.picked ? Qt.alpha(Theme.onPrimary, 0.25) : Theme.primarySoft

				StyledText {
					anchors.centerIn: parent
					text: parent.count
					tone: chip.picked ? Theme.onPrimary : Theme.primary
					font.pixelSize: Theme.size.tiny
					font.weight: Font.Bold
				}
			}
		}

		PickList {
			id: removeMenu

			y: parent.height + 6
			entries: [{ value: "remove", label: `Forget ${chip.app}`, detail: "And every rule only it has", icon: "delete_outline" }]
			onPicked: {
				if (root.app === chip.app) root.appPicked("");
				Mouse.removeApp(chip.app);
			}
		}
	}
}
