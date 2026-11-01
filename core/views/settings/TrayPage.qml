pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.style.theme
import qs.style.widgets
import qs.core.services
import qs.core.views.tray

// The app trays (AppTray): which there are, the edge each sits on (carried
// there on a picture of the screens), how it shows, how it looks and what
// it holds. While this page is open the tray being edited stays out on the
// desktop, so every change is seen where it happens.
SettingsPage {
	id: root

	title: "App tray"
	description: "Strips on the edge of a screen for apps, launcher commands, shell lines, folders and links. Drag them in from the launcher, the file manager or any app, or add them here."

	readonly property var tray: AppTray.trayById(AppTray.editing)
	readonly property var full: AppTray.full(root.tray)
	readonly property var items: root.full.items ?? []
	property string selectedItem: ""
	readonly property var selected: root.items.find(item => item.id === root.selectedItem) ?? null
	property string adding: "apps"
	property string query: ""

	// the tray it is snapped to, and the others on its edge it could go next to
	readonly property var anchor: root.tray ? AppTray.anchorOf(root.tray) : null
	readonly property bool vertical: root.full.edge === "left" || root.full.edge === "right"
	readonly property var neighbours: !root.tray ? [] : AppTray.trays.filter(other => other.id !== root.tray.id
		&& AppTray.outputOf(other) === AppTray.outputOf(root.tray) && (other.edge ?? "bottom") === root.full.edge
		&& !AppTray.hangsFrom(other, root.tray.id))

	function sideName(edge, side) {
		const vertical = edge === "left" || edge === "right";
		if (side === "before") return vertical ? "Above" : "Left of";
		return vertical ? "Below" : "Right of";
	}

	onActiveChanged: AppTray.previewing = root.active
	Component.onDestruction: AppTray.previewing = false
	Component.onCompleted: if (!root.tray && AppTray.trays.length > 0) AppTray.editing = AppTray.trays[0].id

	function set(key, value) {
		if (root.tray) AppTray.update(root.tray.id, { [key]: value });
	}

	// one rule of when the tray is there; none left: always
	function setWhen(key, value) {
		const next = Object.assign({}, root.full.when ?? {});
		if (String(value ?? "").trim() === "") delete next[key];
		else next[key] = value;
		root.set("when", Object.keys(next).length > 0 ? next : null);
	}

	component Switch: RowLayout {
		id: line

		property string text: ""
		property string detail: ""
		property bool checked: false
		signal toggled(bool on)

		Layout.fillWidth: true
		spacing: 14

		ColumnLayout {
			Layout.fillWidth: true
			spacing: 1

			StyledText {
				text: line.text
				font.weight: Font.Medium
			}

			StyledText {
				Layout.fillWidth: true
				visible: line.detail !== ""
				text: line.detail
				tone: Theme.textSubtle
				font.pixelSize: Theme.size.small
				wrapMode: Text.WordWrap
			}
		}

		Toggle {
			checked: line.checked
			onToggled: on => line.toggled(on)
		}
	}

	// a tile to add from: an app or a command
	component Pick: Clickable {
		id: pick

		property var item: null
		property string title: ""
		readonly property bool there: !!root.tray && (root.items ?? []).some(other => AppTray.sameThing(other, pick.item))

		implicitWidth: 96
		implicitHeight: 92
		radius: Theme.radius.large
		color: pick.hovered ? Theme.layer2 : "transparent"
		onClicked: if (root.tray) AppTray.addItems(root.tray.id, [pick.item], -1)

		TrayIcon {
			id: pickIcon

			anchors.horizontalCenter: parent.horizontalCenter
			y: 10
			width: 42
			height: 42
			item: pick.item
			lifted: pick.hovered
		}

		Rectangle {
			visible: pick.there
			anchors.right: pickIcon.right
			anchors.top: pickIcon.top
			anchors.margins: -5
			width: 18
			height: 18
			radius: 9
			color: Theme.primary

			Glyph {
				anchors.centerIn: parent
				icon: "check"
				size: 12
				color: Theme.onPrimary
				animated: false
			}
		}

		StyledText {
			anchors.horizontalCenter: parent.horizontalCenter
			anchors.top: pickIcon.bottom
			anchors.topMargin: 8
			width: parent.width - 10
			horizontalAlignment: Text.AlignHCenter
			text: pick.title
			tone: pick.there ? Theme.textSubtle : Theme.textMuted
			font.pixelSize: Theme.size.small
		}
	}

	// ── the trays ───────────────────────────────────────────────────────
	SettingCard {
		anchor: "trays"
		title: "Trays"
		subtitle: AppTray.trays.length === 0 ? "No tray yet" : `${AppTray.trays.length} ${AppTray.trays.length === 1 ? "tray" : "trays"}; the picked one is edited below`
		icon: "dock_window"

		Flow {
			Layout.fillWidth: true
			spacing: 8

			Repeater {
				model: AppTray.trays

				delegate: Clickable {
					id: chip

					required property var modelData
					readonly property bool picked: chip.modelData.id === AppTray.editing

					implicitWidth: chipRow.implicitWidth + 24
					implicitHeight: 36
					radius: 18
					color: chip.picked ? Theme.primary : (chip.hovered ? Theme.layer3 : Theme.layer2)
					onClicked: {
						AppTray.editing = chip.modelData.id;
						root.selectedItem = "";
					}

					Row {
						id: chipRow

						anchors.centerIn: parent
						spacing: 8

						Glyph {
							anchors.verticalCenter: parent.verticalCenter
							icon: ({ left: "dock_left", right: "dock_right", top: "dock_window", bottom: "dock_window" })[chip.modelData.edge] ?? "dock_window"
							size: 16
							color: chip.picked ? Theme.onPrimary : Theme.textMuted
							rotation: chip.modelData.edge === "top" ? 180 : 0
							animated: false
						}

						StyledText {
							anchors.verticalCenter: parent.verticalCenter
							text: `${String(chip.modelData.name ?? "").trim() || "Tray"}  ·  ${AppTray.outputOf(chip.modelData)}`
							tone: chip.picked ? Theme.onPrimary : Theme.text
							font.weight: Font.Medium
						}
					}
				}
			}

			TextButton {
				text: "New tray"
				icon: "plus"
				variant: AppTray.trays.length === 0 ? "filled" : "tonal"
				onActivated: {
					AppTray.addTray("", "");
					root.selectedItem = "";
				}
			}

			TextButton {
				visible: !!root.tray
				text: "New tray beside it"
				icon: "plus"
				variant: "tonal"
				onActivated: {
					AppTray.addBeside(root.tray.id);
					root.selectedItem = "";
				}
			}
		}

		RowLayout {
			Layout.fillWidth: true
			visible: !!root.tray
			spacing: 10

			Field {
				id: nameField

				Layout.fillWidth: true
				placeholder: "Name"
				icon: "pencil_outline"
				text: root.full.name
				onEdited: text => root.set("name", text)
			}

			TextButton {
				text: "Remove tray"
				icon: "delete_outline"
				variant: "danger"
				confirm: true
				confirmText: "Remove it?"
				onActivated: AppTray.removeTray(root.tray.id)
			}
		}

		// sets of trays to switch between (also >tray in the launcher)
		Flow {
			Layout.fillWidth: true
			spacing: 6

			StyledText {
				height: 32
				text: "Profiles"
				tone: Theme.textSubtle
				font.pixelSize: Theme.size.small
			}

			Repeater {
				model: AppTray.profileNames

				delegate: Clickable {
					id: profileChip

					required property string modelData
					readonly property bool current: AppTray.profile === profileChip.modelData

					implicitWidth: profileRow.implicitWidth + 20
					implicitHeight: 32
					radius: 16
					color: profileChip.current ? Theme.primaryContainer : (profileChip.hovered ? Theme.layer3 : Theme.layer2)
					acceptedButtons: Qt.LeftButton | Qt.RightButton
					onClicked: AppTray.useProfile(profileChip.modelData)
					onRightClicked: AppTray.deleteProfile(profileChip.modelData)

					Row {
						id: profileRow

						anchors.centerIn: parent
						spacing: 6

						Glyph {
							anchors.verticalCenter: parent.verticalCenter
							icon: profileChip.current ? "check" : "dock_window"
							size: 14
							color: Theme.textMuted
							animated: false
						}

						StyledText {
							anchors.verticalCenter: parent.verticalCenter
							text: profileChip.modelData
							font.weight: profileChip.current ? Font.DemiBold : Font.Medium
						}
					}
				}
			}

			Field {
				id: profileName

				width: 170
				placeholder: AppTray.profile !== "" ? `Save as… (now ${AppTray.profile})` : "Save as…"
				icon: "content_save_outline"
				onAccepted: {
					AppTray.saveProfile(profileName.text.trim() || AppTray.profile || "Default");
					profileName.text = "";
				}
			}
		}

		StyledText {
			Layout.fillWidth: true
			visible: AppTray.profileNames.length > 0
			text: "A click switches (what is set up now stays in the profile in use), a right click deletes one, Enter in the field saves."
			tone: Theme.textSubtle
			font.pixelSize: Theme.size.small
			wrapMode: Text.WordWrap
		}

		// to another PC
		Flow {
			Layout.fillWidth: true
			visible: !!root.tray
			spacing: 6

			TextButton {
				implicitHeight: 30
				variant: "ghost"
				icon: "content_save_outline"
				text: "Save as a file"
				onActivated: {
					const path = AppTray.exportTray(root.tray.id);
					Notifs.post({ summary: "Tray saved", body: path });
				}
			}

			Repeater {
				model: Pcs.reachable

				delegate: TextButton {
					required property var modelData

					implicitHeight: 30
					variant: "tonal"
					icon: "monitor_multiple"
					text: `Send to ${modelData.name ?? "PC"}`
					onActivated: AppTray.sendTray(root.tray.id, String(modelData.id))
				}
			}
		}
	}

	// ── where it sits ───────────────────────────────────────────────────
	SettingCard {
		anchor: "tray-place"
		title: "Where it sits"
		subtitle: !root.tray ? "Make a tray first" : (root.anchor
			? `${({ left: "Left", right: "Right", top: "Top", bottom: "Bottom" })[root.full.edge]} edge of ${AppTray.outputOf(root.tray)}, snapped to ${String(root.anchor.name ?? "").trim() || "Tray"}. Drag it away to free it.`
			: `${({ left: "Left", right: "Right", top: "Top", bottom: "Bottom" })[root.full.edge]} edge of ${AppTray.outputOf(root.tray)}, ${Math.round(Number(root.full.position) * 100)}% along. Drag it to any edge of any screen; it snaps to the end of another tray.`)
		icon: "monitor_multiple"
		visible: !!root.tray

		TrayPlacer {
			Layout.fillWidth: true
			Layout.preferredHeight: 280
		}

		// side by side with another tray
		RowLayout {
			Layout.fillWidth: true
			visible: !!root.anchor
			spacing: 10

			Glyph {
				icon: "link_variant"
				size: 18
				color: Theme.primary
			}

			StyledText {
				Layout.fillWidth: true
				text: root.anchor ? `${root.sideName(root.full.edge, root.full.snap?.side)} ${String(root.anchor.name ?? "").trim() || "Tray"}: it follows it wherever it goes and however long it gets` : ""
				wrapMode: Text.WordWrap
			}

			TextButton {
				text: "Detach"
				icon: "link_variant_off"
				variant: "ghost"
				onActivated: AppTray.detach(root.tray.id)
			}
		}

		ValueSlider {
			Layout.fillWidth: true
			visible: !!root.anchor
			from: 0
			to: 64
			step: 1
			label: `Distance to ${String(root.anchor?.name ?? "").trim() || "the other tray"}`
			value: Number(root.full.snapGap)
			format: v => v < 1 ? "Touching" : `${Math.round(v)} px`
			onMoved: v => root.set("snapGap", Math.round(v))
		}

		// the trays on the same edge it can go next to
		Flow {
			Layout.fillWidth: true
			visible: root.neighbours.length > 0
			spacing: 6

			StyledText {
				height: 30
				text: root.anchor ? "Or next to:" : "Snap next to:"
				tone: Theme.textSubtle
				font.pixelSize: Theme.size.small
			}

			Repeater {
				model: root.neighbours.reduce((all, other) => all.concat([{ tray: other, side: "before" }, { tray: other, side: "after" }]), [])
					.filter(each => !(root.anchor?.id === each.tray.id && root.full.snap?.side === each.side))

				delegate: TextButton {
					required property var modelData

					implicitHeight: 30
					variant: "tonal"
					icon: modelData.side === "before" ? (root.vertical ? "arrow_up" : "arrow_left") : (root.vertical ? "arrow_down" : "arrow_right")
					text: `${root.sideName(root.full.edge, modelData.side)} ${String(modelData.tray.name ?? "").trim() || "Tray"}`
					onActivated: AppTray.snapTo(root.tray.id, modelData.tray.id, modelData.side)
				}
			}
		}

		ValueSlider {
			Layout.fillWidth: true
			from: 0
			to: 64
			step: 1
			label: "Distance from the edge"
			value: Number(root.full.gap)
			format: v => `${Math.round(v)} px`
			onMoved: v => root.set("gap", Math.round(v))
		}
	}

	// ── how it shows ────────────────────────────────────────────────────
	SettingCard {
		anchor: "tray-reveal"
		title: "When it shows"
		subtitle: ({
			always: "Always there",
			smart: "There, but it makes way while a window covers it",
			hover: "Slides out when the pointer reaches the edge",
			click: "A handle on the edge opens it",
			key: "Only from a key: bind  scripts/ipc.sh apptray toggle"
		})[root.full.reveal] ?? ""
		icon: "eye_outline"
		visible: !!root.tray

		Segmented {
			Layout.fillWidth: true
			options: [
				{ value: "always", label: "Always", icon: "pin_outline" },
				{ value: "smart", label: "Makes way", icon: "arrow_collapse" },
				{ value: "hover", label: "On hover", icon: "cursor_default_outline" },
				{ value: "click", label: "On click", icon: "cursor_default_click_outline" },
				{ value: "key", label: "From a key", icon: "keyboard_outline" }
			]
			current: root.full.reveal
			onSelected: value => root.set("reveal", value)
		}

		ValueSlider {
			Layout.fillWidth: true
			visible: root.full.reveal === "hover" || root.full.reveal === "smart"
			from: 0
			to: 800
			step: 20
			label: "Wait at the edge"
			value: Number(root.full.delay)
			format: v => v < 10 ? "At once" : `${Math.round(v)} ms`
			onMoved: v => root.set("delay", Math.round(v))
		}

		Switch {
			visible: root.full.reveal === "always"
			text: "Keep windows clear of it"
			detail: "Windows end where the tray begins (along the whole edge)"
			checked: root.full.reserve
			onToggled: on => root.set("reserve", on)
		}

		Switch {
			visible: GameMode.enabled
			text: "Out of the way in games"
			detail: "While game mode is on, an always-there tray waits at the edge"
			checked: root.full.gameHide
			onToggled: on => root.set("gameHide", on)
		}
	}

	// ── when it is there at all ─────────────────────────────────────────
	SettingCard {
		anchor: "tray-when"
		title: "Only when"
		subtitle: !root.full.when ? "Always there; set what has to hold for it to come (two trays in one place with other rules swap)" : (AppTray.active(root.tray) ? "It is there now" : "Not there right now")
		icon: "clock_outline"
		visible: !!root.tray
		modified: !!root.full.when
		onReset: root.set("when", null)

		GridLayout {
			Layout.fillWidth: true
			columns: 2
			columnSpacing: 10
			rowSpacing: 10

			Field {
				Layout.fillWidth: true
				placeholder: "On workspaces (names or numbers: 1, web)"
				icon: "view_grid_outline"
				text: root.full.when?.workspaces ?? ""
				onEdited: text => root.setWhen("workspaces", text)
			}

			Field {
				Layout.fillWidth: true
				placeholder: "While an app has the focus (code, floorp)"
				icon: "application_outline"
				text: root.full.when?.apps ?? ""
				onEdited: text => root.setWhen("apps", text)
			}

			Field {
				Layout.fillWidth: true
				placeholder: "From (08:00)"
				icon: "clock_outline"
				text: root.full.when?.from ?? ""
				onEdited: text => root.setWhen("from", text)
			}

			Field {
				Layout.fillWidth: true
				placeholder: "Until (18:00)"
				icon: "clock_outline"
				text: root.full.when?.to ?? ""
				onEdited: text => root.setWhen("to", text)
			}
		}

		Segmented {
			Layout.fillWidth: true
			visible: GameMode.enabled
			options: [{ value: "", label: "Games or not" }, { value: "on", label: "Only in games" }, { value: "off", label: "Not in games" }]
			current: root.full.when?.game ?? ""
			onSelected: value => root.setWhen("game", value)
		}
	}

	// ── keys ────────────────────────────────────────────────────────────
	SettingCard {
		anchor: "tray-keys"
		title: "Keys"
		subtitle: AppTray.keysBound ? "Mod+Alt+1…9 start the items of the tray shown first, Mod+Alt+0 gives a tray the keyboard (arrows, Enter, 1…9, Menu, Escape)" : "Start the items from the keyboard"
		icon: "keyboard_outline"
		visible: !!root.tray

		Switch {
			text: "Mod+Alt+1…9 and Mod+Alt+0"
			detail: "Written to your key binds; keys that already do something are left alone"
			checked: AppTray.keysBound
			onToggled: on => AppTray.bindKeys(on)
		}
	}

	// ── how it looks ────────────────────────────────────────────────────
	SettingCard {
		anchor: "tray-look"
		title: "Look"
		subtitle: `${Math.round(root.full.iconSize)} px icons${Number(root.full.magnify) > 0 ? `, growing to ${Math.round(root.full.iconSize * (1 + Number(root.full.magnify)))} px under the pointer` : ""}`
		icon: "palette"
		visible: !!root.tray

		Segmented {
			Layout.fillWidth: true
			options: [
				{ value: "glass", label: "Glass" },
				{ value: "solid", label: "Solid" },
				{ value: "bare", label: "Icons only" }
			]
			current: root.full.look
			onSelected: value => root.set("look", value)
		}

		ValueSlider {
			Layout.fillWidth: true
			from: 24
			to: 96
			step: 2
			label: "Icon size"
			value: Number(root.full.iconSize)
			format: v => `${Math.round(v)} px`
			onMoved: v => root.set("iconSize", Math.round(v))
		}

		ValueSlider {
			Layout.fillWidth: true
			from: 0
			to: 1
			step: 0.05
			label: "Grow under the pointer"
			value: Number(root.full.magnify)
			format: v => v < 0.03 ? "Off" : `+${Math.round(v * 100)}%`
			onMoved: v => root.set("magnify", Math.round(v * 20) / 20)
		}

		Switch {
			text: "Names"
			detail: "The name of what is under the pointer"
			checked: root.full.labels
			onToggled: on => root.set("labels", on)
		}

		Switch {
			text: "Open windows"
			detail: "A dot under an app for each of its windows"
			checked: root.full.dots
			onToggled: on => root.set("dots", on)
		}

		Switch {
			text: "Go to an open window"
			detail: "A click on a running app brings its window (again: the next one); a middle click starts another"
			checked: root.full.focusRunning
			onToggled: on => root.set("focusRunning", on)
		}

		Switch {
			text: "Open apps too"
			detail: "Apps with a window that are not in it come in behind a line; drag one in or Keep it to pin it"
			checked: root.full.running
			onToggled: on => root.set("running", on)
		}

		Switch {
			text: "Badges"
			detail: "Unread messages, notifications, updates, downloads and prints in progress, playtime, the phone's battery"
			checked: root.full.badges
			onToggled: on => root.set("badges", on)
		}

		Switch {
			text: "Pictures of the windows"
			detail: "Resting on an app shows its windows; a click goes there"
			checked: root.full.previews
			onToggled: on => root.set("previews", on)
		}

		Switch {
			text: "Compact"
			detail: "Small icons until the pointer comes"
			checked: root.full.compact
			onToggled: on => root.set("compact", on)
		}

		Switch {
			visible: root.full.look === "glass"
			text: "Blur behind the glass"
			checked: root.full.blur
			onToggled: on => root.set("blur", on)
		}

		Switch {
			visible: root.vertical
			text: "Names along the edge"
			detail: "Turned, so a name runs beside its icon"
			checked: root.full.labelStyle === "vertical"
			onToggled: on => root.set("labelStyle", on ? "vertical" : "bubble")
		}

		Segmented {
			Layout.fillWidth: true
			options: [{ value: "lively", label: "Lively", icon: "animation" }, { value: "calm", label: "Calm", icon: "minus" }]
			current: root.full.motion
			onSelected: value => root.set("motion", value)
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 10

			Segmented {
				Layout.fillWidth: true
				options: [{ value: "theme", label: "Wallpaper" }, { value: "primary", label: "Accent" }, { value: "secondary", label: "Second" }, { value: "tertiary", label: "Third" }, { value: "custom", label: "Own" }]
				current: root.full.accent
				onSelected: value => root.set("accent", value)
			}

			Rectangle {
				visible: root.full.accent === "custom"
				Layout.preferredWidth: 28
				Layout.preferredHeight: 28
				radius: 14
				color: root.full.accentColor
				border.width: 1
				border.color: Theme.outline
			}

			Field {
				visible: root.full.accent === "custom"
				Layout.preferredWidth: 120
				placeholder: "#7aa2f7"
				text: root.full.accentColor
				onEdited: text => {
					if (/^#[0-9a-fA-F]{6}$/.test(text.trim())) root.set("accentColor", text.trim());
				}
			}
		}
	}

	// ── what it holds ───────────────────────────────────────────────────
	SettingCard {
		anchor: "tray-items"
		title: "In the tray"
		subtitle: root.items.length === 0 ? "Nothing yet: drop something here or on the tray, or add it below" : `${root.items.length} ${root.items.length === 1 ? "item" : "items"}; drag to put them in order, click one to change it`
		icon: "apps"
		visible: !!root.tray

		// the items in order, a drop target too
		Rectangle {
			Layout.fillWidth: true
			Layout.preferredHeight: 104
			radius: Theme.radius.large
			color: itemsDrop.containsDrag ? Theme.primarySoft : Theme.layer1
			border.width: itemsDrop.containsDrag ? 1.5 : 1
			border.color: itemsDrop.containsDrag ? Theme.primary : Theme.outline

			Behavior on color {
				ColorAnim {}
			}

			DropArea {
				id: itemsDrop

				anchors.fill: parent
				onEntered: drag => drag.accepted = AppTray.accepts(drag)
				onDropped: drop => {
					const items = AppTray.itemsOfDrop(drop);
					if (items.length === 0 || !root.tray) return;
					AppTray.addItems(root.tray.id, items, -1);
					drop.accept(Qt.CopyAction);
				}
			}

			StyledText {
				anchors.centerIn: parent
				visible: root.items.length === 0
				text: "Drop apps, files, folders or links here"
				tone: Theme.textSubtle
			}

			Flickable {
				anchors.fill: parent
				anchors.margins: 8
				contentWidth: strip.width
				clip: true
				boundsBehavior: Flickable.StopAtBounds
				interactive: contentWidth > width

				Item {
					id: strip

					property string dragging: ""
					property int dropAt: -1
					readonly property real cellWidth: 82
					readonly property var order: {
						const ids = root.items.map(item => item.id).filter(id => id !== strip.dragging);
						if (strip.dragging !== "") ids.splice(Math.max(0, Math.min(ids.length, strip.dropAt)), 0, strip.dragging);
						return ids;
					}

					width: Math.max(1, root.items.length * strip.cellWidth)
					height: 88

					Repeater {
						model: root.items

						delegate: Item {
							id: cell

							required property var modelData
							readonly property bool dragged: strip.dragging === cell.modelData.id
							readonly property bool isSelected: root.selectedItem === cell.modelData.id
							property real dragX: 0

							x: cell.dragged ? cell.dragX : strip.order.indexOf(cell.modelData.id) * strip.cellWidth
							width: strip.cellWidth
							height: strip.height
							z: cell.dragged ? 2 : 1

							Behavior on x {
								enabled: !cell.dragged
								SpatialAnim {
									duration: Motion.medium
								}
							}

							Rectangle {
								anchors.fill: parent
								anchors.margins: 2
								radius: Theme.radius.medium
								color: cell.isSelected ? Theme.primaryContainer : (cellMouse.containsMouse ? Theme.layer2 : "transparent")
								border.width: cell.isSelected ? 1.5 : 0
								border.color: Theme.primary
							}

							TrayIcon {
								anchors.horizontalCenter: parent.horizontalCenter
								y: 8
								width: 44
								height: 44
								item: cell.modelData
								lifted: cell.dragged || cellMouse.containsMouse
								scale: cell.dragged ? 1.1 : 1
							}

							StyledText {
								anchors.horizontalCenter: parent.horizontalCenter
								y: 60
								width: parent.width - 8
								horizontalAlignment: Text.AlignHCenter
								text: AppTray.nameOf(cell.modelData)
								tone: Theme.textMuted
								font.pixelSize: Theme.size.tiny
							}

							MouseArea {
								id: cellMouse

								property real grabX: 0
								property bool moved: false

								anchors.fill: parent
								hoverEnabled: true
								preventStealing: true
								cursorShape: cell.dragged ? Qt.ClosedHandCursor : Qt.PointingHandCursor
								onPressed: event => {
									cellMouse.grabX = event.x;
									cellMouse.moved = false;
								}
								onPositionChanged: event => {
									if (!pressed) return;
									const p = mapToItem(strip, event.x, event.y);
									if (!cellMouse.moved && Math.abs(event.x - cellMouse.grabX) < 6) return;
									cellMouse.moved = true;
									strip.dragging = cell.modelData.id;
									cell.dragX = p.x - cellMouse.grabX;
									strip.dropAt = Math.round(cell.dragX / strip.cellWidth);
								}
								onReleased: {
									if (!cell.dragged) return;
									const to = Math.max(0, Math.min(root.items.length - 1, strip.dropAt));
									strip.dragging = "";
									AppTray.moveItem(root.tray.id, cell.modelData.id, to);
								}
								onCanceled: strip.dragging = ""
								onClicked: if (!cellMouse.moved) root.selectedItem = cell.isSelected ? "" : cell.modelData.id
							}

							// taken out
							IconButton {
								anchors.right: parent.right
								anchors.top: parent.top
								anchors.margins: 2
								width: 22
								height: 22
								icon: "close"
								variant: "tonal"
								opacity: cellMouse.containsMouse || hovered ? 1 : 0
								onClicked: {
									if (root.selectedItem === cell.modelData.id) root.selectedItem = "";
									AppTray.removeItem(root.tray.id, cell.modelData.id);
								}

								Behavior on opacity {
									Anim {
										duration: Motion.short
									}
								}
							}
						}
					}
				}
			}
		}

		// the picked item: its name, and for a shell line what it runs
		GridLayout {
			Layout.fillWidth: true
			visible: !!root.selected
			columns: 2
			columnSpacing: 10
			rowSpacing: 10

			Field {
				Layout.fillWidth: true
				Layout.columnSpan: root.selected?.kind === "shell" ? 1 : 2
				placeholder: root.selected ? `Name (${AppTray.nameOf(Object.assign({}, root.selected, { label: "" }))})` : "Name"
				icon: "pencil_outline"
				text: root.selected?.label ?? ""
				onEdited: text => AppTray.updateItem(root.tray.id, root.selectedItem, { label: text })
			}

			Field {
				Layout.fillWidth: true
				visible: root.selected?.kind === "shell"
				placeholder: "Command"
				icon: "console"
				text: root.selected?.exec ?? ""
				onEdited: text => {
					if (text.trim() !== "") AppTray.updateItem(root.tray.id, root.selectedItem, { exec: text });
				}
			}

			Switch {
				Layout.columnSpan: 2
				visible: root.selected?.kind === "shell"
				text: "In a terminal"
				detail: "For what prints something or asks"
				checked: root.selected?.terminal === true
				onToggled: on => AppTray.updateItem(root.tray.id, root.selectedItem, { terminal: on })
			}

			// a picture of its own: an icon of the theme or a file
			Field {
				Layout.columnSpan: 2
				Layout.fillWidth: true
				visible: !!root.selected && root.selected.kind !== "separator" && root.selected.kind !== "spacer" && root.selected.kind !== "widget"
				placeholder: "Own icon: a name of the icon theme (org.gnome.Nautilus) or a file (/path/icon.png)"
				icon: "image_outline"
				text: root.selected?.icon ?? ""
				onEdited: text => AppTray.updateItem(root.tray.id, root.selectedItem, { icon: text.trim() })
			}

			Switch {
				Layout.columnSpan: 2
				visible: root.selected?.kind === "file" && root.selected?.folder === true
				text: "As a stack"
				detail: "Its newest files, fanned out from the tray"
				checked: root.selected?.stack === true
				onToggled: on => AppTray.updateItem(root.tray.id, root.selectedItem, { stack: on })
			}

			Field {
				Layout.columnSpan: 2
				Layout.fillWidth: true
				visible: root.selected?.kind === "group"
				placeholder: "Group name"
				icon: "apps"
				text: root.selected?.name ?? ""
				onEdited: text => AppTray.updateItem(root.tray.id, root.selectedItem, { name: text })
			}

			// a glyph for what has no picture of its own
			Flow {
				Layout.columnSpan: 2
				Layout.fillWidth: true
				visible: !!root.selected && ["command", "shell", "link", "action"].includes(root.selected.kind)
				spacing: 4

				Repeater {
					model: ["console", "rocket_launch_outline", "lightning_bolt", "star", "web", "folder", "music_note", "gamepad_variant", "palette", "camera", "chat", "email_outline", "server_network", "cog_outline", "code_braces", "download", "heart", "home"]

					delegate: IconButton {
						required property string modelData

						width: 34
						height: 34
						icon: modelData
						checked: AppTray.glyphOf(root.selected) === modelData
						variant: checked ? "filled" : "ghost"
						onClicked: AppTray.updateItem(root.tray.id, root.selectedItem, { glyph: modelData })
					}
				}
			}
		}

		// adding
		Segmented {
			Layout.fillWidth: true
			Layout.topMargin: 6
			options: [
				{ value: "apps", label: "Apps", icon: "apps" },
				{ value: "commands", label: "Commands", icon: "console" },
				{ value: "shell", label: "Shell line", icon: "console_line" },
				{ value: "place", label: "Folder or link", icon: "folder_outline" },
				{ value: "more", label: "More", icon: "plus" }
			]
			current: root.adding
			onSelected: value => {
				root.adding = value;
				root.query = "";
				searchField.text = "";
			}
		}

		Field {
			id: searchField

			Layout.fillWidth: true
			visible: root.adding === "apps" || root.adding === "commands"
			placeholder: root.adding === "apps" ? "Find an app" : "Find a command"
			icon: "magnify"
			onEdited: text => root.query = text.trim().toLowerCase()
		}

		Flow {
			Layout.fillWidth: true
			visible: root.adding === "apps"
			spacing: 2

			Repeater {
				model: {
					if (root.adding !== "apps") return [];
					const q = root.query;
					return DesktopEntries.applications.values
						.filter(entry => entry && !entry.noDisplay && !entry.hidden)
						.filter(entry => q === "" || String(entry.name).toLowerCase().includes(q) || String(entry.genericName ?? "").toLowerCase().includes(q) || String(entry.id).toLowerCase().includes(q))
						.sort((a, b) => String(a.name).localeCompare(String(b.name)))
						.slice(0, q === "" ? 30 : 60);
				}

				delegate: Pick {
					required property var modelData

					item: ({ kind: "app", app: String(modelData.id) })
					title: String(modelData.name)
				}
			}
		}

		Flow {
			Layout.fillWidth: true
			visible: root.adding === "commands"
			spacing: 2

			Repeater {
				model: {
					if (root.adding !== "commands") return [];
					const q = root.query;
					return AppTray.commandCatalog.filter(command => q === "" || command.name.toLowerCase().includes(q) || command.command.toLowerCase().includes(q));
				}

				delegate: Pick {
					required property var modelData

					item: ({ kind: "command", command: modelData.command, name: modelData.name, glyph: modelData.glyph })
					title: modelData.name
				}
			}
		}

		StyledText {
			Layout.fillWidth: true
			visible: root.adding === "commands" && AppTray.commandCatalog.length === 0
			text: "The launcher has not said which commands there are yet"
			tone: Theme.textSubtle
		}

		// a line for the shell
		GridLayout {
			Layout.fillWidth: true
			visible: root.adding === "shell"
			columns: 3
			columnSpacing: 10
			rowSpacing: 10

			Field {
				id: shellName

				Layout.preferredWidth: 180
				placeholder: "Name"
				icon: "pencil_outline"
			}

			Field {
				id: shellLine

				Layout.fillWidth: true
				placeholder: "Command, e.g. kitty -e btop"
				icon: "console"
				onAccepted: shellAdd.activated()
			}

			TextButton {
				id: shellAdd

				text: "Add"
				icon: "plus"
				variant: "filled"
				onActivated: {
					const line = shellLine.text.trim();
					if (line === "" || !root.tray) return;
					AppTray.addItems(root.tray.id, [{ kind: "shell", exec: line, name: shellName.text.trim() || line.split(/\s+/)[0].split("/").pop(), terminal: shellTerminal.checked }], -1);
					shellLine.text = "";
					shellName.text = "";
				}
			}

			Switch {
				id: shellTerminal

				Layout.columnSpan: 3
				text: "In a terminal"
				detail: "It runs in a terminal window instead of in the background"
				onToggled: on => shellTerminal.checked = on
			}
		}

		// a folder, a file or a link
		RowLayout {
			Layout.fillWidth: true
			visible: root.adding === "place"
			spacing: 10

			Field {
				id: placeField

				Layout.fillWidth: true
				placeholder: "~/Downloads, /path/to/file.pdf or https://…"
				icon: "folder_outline"
				onAccepted: placeAdd.activated()
			}

			TextButton {
				id: placeAdd

				text: "Add"
				icon: "plus"
				variant: "filled"
				onActivated: {
					let value = placeField.text.trim();
					if (value === "" || !root.tray) return;
					if (value.startsWith("~")) value = Quickshell.env("HOME") + value.slice(1);
					const item = /^https?:\/\//.test(value) ? { kind: "link", url: value, name: AppTray.hostOf(value) } : AppTray.itemOfPath(value);
					AppTray.addItems(root.tray.id, [item], -1);
					placeField.text = "";
				}
			}
		}

		// lines, gaps, groups, widgets, actions, the phone, games
		ColumnLayout {
			Layout.fillWidth: true
			visible: root.adding === "more"
			spacing: 6

			SectionLabel {
				text: "Arrange"
			}

			Flow {
				Layout.fillWidth: true
				spacing: 2

				Repeater {
					model: [
						{ item: { kind: "separator" }, title: "Line" },
						{ item: { kind: "spacer" }, title: "Gap" },
						{ item: { kind: "group", name: "Group", items: [] }, title: "Group" }
					]

					delegate: Pick {
						required property var modelData

						item: modelData.item
						title: modelData.title
					}
				}
			}

			SectionLabel {
				text: "Live"
			}

			Flow {
				Layout.fillWidth: true
				spacing: 2

				Repeater {
					model: AppTray.ownWidgets

					delegate: Pick {
						required property var modelData

						item: ({ kind: "widget", widget: modelData.id })
						title: modelData.name
					}
				}
			}

			SectionLabel {
				text: "Live from the shell"
			}

			Flow {
				Layout.fillWidth: true
				spacing: 2

				Repeater {
					model: root.adding === "more" ? Live.sources.filter(src => src.available) : []

					delegate: Pick {
						required property var modelData

						item: ({ kind: "widget", widget: `live:${modelData.key}` })
						title: modelData.name
					}
				}
			}

			StyledText {
				Layout.fillWidth: true
				text: "How each looks (ring, curve, value …) is set in Pshell settings › Desktop › Live status"
				tone: Theme.textSubtle
				font.pixelSize: Theme.size.small
				wrapMode: Text.WordWrap
			}

			StyledText {
				Layout.fillWidth: true
				visible: !Plugins.on("system-monitor")
				text: "CPU and memory move only while the System monitor plugin is on"
				tone: Theme.textSubtle
				font.pixelSize: Theme.size.small
			}

			SectionLabel {
				text: "Drop files on it"
			}

			Flow {
				Layout.fillWidth: true
				spacing: 2

				Repeater {
					model: AppTray.actions

					delegate: Pick {
						required property var modelData

						item: modelData.pc ? ({ kind: "action", action: modelData.id, pc: modelData.pc }) : ({ kind: "action", action: modelData.id })
						title: modelData.name
					}
				}

				Pick {
					visible: Phone.enabled
					item: ({ kind: "phone" })
					title: "Phone"
				}
			}

			SectionLabel {
				visible: Plugins.on("games")
				text: "Games"
			}

			Flow {
				Layout.fillWidth: true
				visible: Plugins.on("games")
				spacing: 2

				Repeater {
					model: root.adding === "more" && Plugins.on("games") ? Games.shown.slice(0, 40) : []

					delegate: Pick {
						required property var modelData

						item: ({ kind: "game", game: String(modelData.id), name: String(modelData.name) })
						title: String(modelData.name)
					}
				}
			}
		}

		StyledText {
			Layout.fillWidth: true
			text: "Also: drag an app or a command out of the launcher onto the tray, or files, folders and links from any app. Right click an item in the tray for its menu; drag it along to move it, away from the edge to take it out."
			tone: Theme.textSubtle
			font.pixelSize: Theme.size.small
			wrapMode: Text.WordWrap
		}
	}
}
