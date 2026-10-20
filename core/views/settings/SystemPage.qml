pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "Nodes.js" as Nodes

// System: what starts with niri, the environment it hands to programs,
// where screenshots go, title bars, blur, and the small switches.
SettingsPage {
	id: root

	title: "System"
	description: "What starts with niri and what it gives the programs it starts – and the rest of the house rules."

	readonly property var startup: NiriSettings.items(["spawn-at-startup", "spawn-sh-at-startup"])

	function commandOf(node) {
		return node.name === "spawn-sh-at-startup" ? String(node.args[0] ?? "") : (node.args || []).map(a => /\s/.test(String(a)) ? `"${a}"` : String(a)).join(" ");
	}

	function appOf(node) {
		const program = String(node.name === "spawn-sh-at-startup" ? String(node.args[0] ?? "").split(/\s+/)[0] : (node.args?.[0] ?? "")).split("/").pop();
		if (program === "") return null;
		return DesktopEntries.applications.values.find(e => e.id === program || e.id.toLowerCase() === program.toLowerCase() || String(e.command?.[0] || "").split("/").pop() === program) ?? null;
	}

	function writeStartup(list, note) {
		NiriSettings.setItems(["spawn-at-startup", "spawn-sh-at-startup"], list, note, "");
	}

	// ── startup ────────────────────────────────────────────────────────────
	SettingCard {
		anchor: "startup"
		title: "Starts with niri"
		subtitle: "In this order. Switched off ones stay in the file, ready to come back."
		icon: "rocket_launch_outline"

		// the shell's own: they live in the repository
		Repeater {
			model: NiriSettings.shellStartup

			delegate: RowLayout {
				required property var modelData

				Layout.fillWidth: true
				spacing: 10
				opacity: 0.7

				Glyph {
					Layout.leftMargin: 14
					icon: "lock_outline"
					size: 15
					color: Theme.textSubtle
				}

				StyledText {
					Layout.fillWidth: true
					text: root.commandOf(modelData)
					font.family: Theme.monoFamily
					font.pixelSize: Theme.size.small
				}

				StyledText {
					text: `the shell (${modelData.source})`
					tone: Theme.textSubtle
					font.pixelSize: Theme.size.small
				}
			}
		}

		DragList {
			Layout.fillWidth: true
			items: root.startup
			onReordered: order => root.writeStartup(order.map(i => root.startup[i]), "Startup order changed")

			cell: Rectangle {
				id: entry

				property var modelData: null
				property int index: 0
				property Item dragSource: null
				readonly property var app: entry.modelData ? root.appOf(entry.modelData) : null
				readonly property bool off: !!entry.modelData?.disabled

				implicitHeight: 58
				radius: Theme.radius.large
				color: Theme.layer2
				opacity: entry.off ? 0.55 : 1

				Behavior on opacity {
					Anim {}
				}

				RowLayout {
					anchors.fill: parent
					anchors.leftMargin: 8
					anchors.rightMargin: 12
					spacing: 10

					DragGrip {
						source: entry.dragSource
					}

					Item {
						Layout.preferredWidth: 30
						Layout.preferredHeight: 30

						Image {
							anchors.fill: parent
							visible: !!entry.app
							source: entry.app ? Quickshell.iconPath(entry.app.icon, true) : ""
							sourceSize.width: 60
							asynchronous: true
						}

						Glyph {
							anchors.centerIn: parent
							visible: !entry.app
							icon: entry.modelData?.name === "spawn-sh-at-startup" ? "console" : "application_outline"
							size: 18
							color: Theme.textMuted
						}
					}

					ColumnLayout {
						Layout.fillWidth: true
						spacing: 1

						StyledText {
							Layout.fillWidth: true
							visible: !!entry.app
							text: entry.app?.name ?? ""
							font.weight: Font.Medium
						}

						TextInput {
							Layout.fillWidth: true
							text: entry.modelData ? root.commandOf(entry.modelData) : ""
							color: entry.app ? Theme.textSubtle : Theme.text
							font.family: Theme.monoFamily
							font.pixelSize: entry.app ? Theme.size.small : Theme.size.label
							selectByMouse: true
							clip: true
							onEditingFinished: {
								if (!entry.modelData || text === root.commandOf(entry.modelData)) return;
								const list = root.startup.slice();
								list[entry.index] = Object.assign({}, entry.modelData, { name: "spawn-sh-at-startup", args: [text.trim()] });
								root.writeStartup(list, "Startup command changed");
							}
						}
					}

					Toggle {
						checked: !entry.off
						onToggled: on => {
							const list = root.startup.slice();
							const node = Nodes.clone(entry.modelData);
							if (on) delete node.disabled;
							else node.disabled = true;
							list[entry.index] = node;
							root.writeStartup(list, `${entry.app?.name ?? "Command"} ${on ? "starts again" : "no longer starts"}`);
						}
					}

					IconButton {
						icon: "delete_outline"
						iconColor: Theme.danger
						implicitWidth: 30
						implicitHeight: 30
						onClicked: root.writeStartup(root.startup.filter((n, i) => i !== entry.index), "Removed from startup")
					}
				}
			}
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 10

			TextButton {
				text: "Add an app"
				icon: "apps"
				variant: "tonal"
				onActivated: appPicker.open()

				PickList {
					id: appPicker

					y: parent.height + 4
					width: 380
					placeholder: "Search apps"
					searchable: true
					entries: DesktopEntries.applications.values.filter(e => !e.noDisplay).map(e => ({ value: e.id, label: e.name, detail: (e.command || []).join(" ") })).sort((a, b) => a.label.localeCompare(b.label))
					onPicked: value => {
						const app = DesktopEntries.applications.values.find(e => e.id === value);
						const command = (app?.command || []).filter(part => !/^%[a-zA-Z]$/.test(part));
						if (command.length === 0) return;
						root.writeStartup(root.startup.concat([Nodes.make("spawn-at-startup", command)]), `${app.name} starts with niri`);
					}
				}
			}

			Field {
				id: commandField

				Layout.fillWidth: true
				icon: "console"
				placeholder: "Or a command (run through sh)"
				onAccepted: {
					const text = commandField.text.trim();
					if (text === "") return;
					root.writeStartup(root.startup.concat([Nodes.make("spawn-sh-at-startup", [text])]), "Command starts with niri");
					commandField.text = "";
				}
			}
		}
	}

	// ── environment ────────────────────────────────────────────────────────
	SettingCard {
		anchor: "environment"
		title: "Environment"
		subtitle: "Variables niri sets – or takes away – for the programs it starts"
		icon: "variable"
		modified: NiriSettings.kids(["environment"]).length > 0
		onReset: NiriSettings.reset(["environment"])

		readonly property var vars: NiriSettings.kids(["environment"]).filter(c => !c.disabled)

		function write(list, note) {
			NiriSettings.setChildren(["environment"], list, note, "");
		}

		Repeater {
			model: envCard.vars

			delegate: RowLayout {
				id: envRow

				required property var modelData
				required property int index
				readonly property var card: envRow.parent?.parent?.parent ?? null
				readonly property bool unset: envRow.modelData.args[0] === null

				Layout.fillWidth: true
				spacing: 10

				Rectangle {
					Layout.preferredWidth: Math.max(200, nameText.implicitWidth + 24)
					Layout.preferredHeight: 36
					radius: 18
					color: Theme.layer2

					StyledText {
						id: nameText

						anchors.centerIn: parent
						text: envRow.modelData.name
						font.family: Theme.monoFamily
						font.weight: Font.DemiBold
						font.pixelSize: Theme.size.label
					}
				}

				Glyph {
					icon: envRow.unset ? "minus_circle_outline" : "equal"
					size: 16
					color: envRow.unset ? Theme.danger : Theme.textSubtle
				}

				Field {
					Layout.fillWidth: true
					implicitHeight: 36
					visible: !envRow.unset
					text: String(envRow.modelData.args[0] ?? "")
					placeholder: Quickshell.env(envRow.modelData.name) ? `now: ${Quickshell.env(envRow.modelData.name)}` : "value"
					input.font.family: Theme.monoFamily
					onAccepted: envCard.write(envCard.vars.map((v, i) => i === envRow.index ? Nodes.make(v.name, [text]) : v), `${envRow.modelData.name} set`)
				}

				StyledText {
					Layout.fillWidth: true
					visible: envRow.unset
					text: "taken away – programs do not see it"
					tone: Theme.danger
					font.pixelSize: Theme.size.small
				}

				Chip {
					text: envRow.unset ? "Give it a value" : "Take away"
					icon: envRow.unset ? "plus" : "minus"
					onClicked: envCard.write(envCard.vars.map((v, i) => i === envRow.index ? Nodes.make(v.name, [envRow.unset ? "" : null]) : v), `${envRow.modelData.name} ${envRow.unset ? "set" : "taken away"}`)
				}

				IconButton {
					icon: "delete_outline"
					iconColor: Theme.danger
					implicitWidth: 30
					implicitHeight: 30
					onClicked: envCard.write(envCard.vars.filter((v, i) => i !== envRow.index), `${envRow.modelData.name} removed`)
				}
			}
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 10

			Field {
				id: newVar

				Layout.preferredWidth: 260
				icon: "plus"
				placeholder: "NAME"
				input.font.family: Theme.monoFamily
				onAccepted: newValue.focusInput()
			}

			Field {
				id: newValue

				Layout.fillWidth: true
				placeholder: "value – Enter adds it"
				input.font.family: Theme.monoFamily
				onAccepted: {
					const name = newVar.text.trim();
					if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(name)) return;
					envCard.write(envCard.vars.filter(v => v.name !== name).concat([Nodes.make(name, [newValue.text])]), `${name} set`);
					newVar.text = "";
					newValue.text = "";
				}
			}
		}

		Flow {
			Layout.fillWidth: true
			spacing: 6

			Repeater {
				model: [
					{ name: "QT_QPA_PLATFORM", value: "wayland" },
					{ name: "ELECTRON_OZONE_PLATFORM_HINT", value: "auto" },
					{ name: "MOZ_ENABLE_WAYLAND", value: "1" },
					{ name: "_JAVA_AWT_WM_NONREPARENTING", value: "1" }
				].filter(v => !(envCard.vars || []).some(e => e.name === v.name))

				delegate: Chip {
					required property var modelData

					text: `${modelData.name}=${modelData.value}`
					icon: "plus"
					onClicked: envCard.write(envCard.vars.concat([Nodes.make(modelData.name, [modelData.value])]), `${modelData.name} set`)
				}
			}
		}

		id: envCard
	}

	// ── screenshots ────────────────────────────────────────────────────────
	SettingCard {
		anchor: "screenshots"
		title: "Screenshots"
		subtitle: "Where niri's own screenshots go. The name can carry the date: click a piece to add it."
		icon: "monitor_screenshot"
		modified: NiriSettings.has(["screenshot-path"])
		onReset: NiriSettings.reset(["screenshot-path"])

		readonly property var raw: NiriSettings.node(["screenshot-path"])
		readonly property bool off: !!raw && raw.args[0] === null
		readonly property string path: off ? "" : String(raw?.args?.[0] ?? "~/Pictures/Screenshots/Screenshot from %Y-%m-%d %H-%M-%S.png")

		function example(text) {
			const d = new Date();
			const pad = n => String(n).padStart(2, "0");
			const days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
			return text.replace(/%Y/g, d.getFullYear()).replace(/%m/g, pad(d.getMonth() + 1)).replace(/%d/g, pad(d.getDate()))
				.replace(/%H/g, pad(d.getHours())).replace(/%M/g, pad(d.getMinutes())).replace(/%S/g, pad(d.getSeconds()))
				.replace(/%a/g, days[d.getDay()]).replace(/%s/g, Math.floor(d.getTime() / 1000)).replace(/^~/, Paths.home);
		}

		FlagRow {
			title: "Save to disk"
			subtitle: shotCard.off ? "Off – screenshots only go to the clipboard" : "Every screenshot is kept as a file"
			icon: "content_save_outline"
			checked: !shotCard.off
			onToggled: on => on ? NiriSettings.reset(["screenshot-path"], "Screenshots are saved") : NiriSettings.set(["screenshot-path"], null, "Screenshots only to the clipboard", "")
		}

		ColumnLayout {
			Layout.fillWidth: true
			visible: !shotCard.off
			spacing: 10

			Field {
				id: pathField

				Layout.fillWidth: true
				icon: "folder_outline"
				text: shotCard.path
				input.font.family: Theme.monoFamily
				onAccepted: NiriSettings.set(["screenshot-path"], pathField.text.trim(), "Screenshot path changed", "")
			}

			Flow {
				Layout.fillWidth: true
				spacing: 6

				Repeater {
					model: [
						{ token: "%Y", label: "Year" }, { token: "%m", label: "Month" }, { token: "%d", label: "Day" },
						{ token: "%H", label: "Hour" }, { token: "%M", label: "Minute" }, { token: "%S", label: "Second" },
						{ token: "%a", label: "Weekday" }, { token: "%s", label: "Seconds since 1970" }
					]

					delegate: Chip {
						required property var modelData

						text: modelData.label
						icon: "plus"
						onClicked: {
							const at = pathField.input.cursorPosition;
							pathField.text = pathField.text.slice(0, at) + modelData.token + pathField.text.slice(at);
							pathField.input.cursorPosition = at + modelData.token.length;
							pathField.focusInput();
						}
					}
				}
			}

			RowLayout {
				spacing: 8

				Glyph {
					icon: "file_image"
					size: 15
					color: Theme.primary
				}

				StyledText {
					Layout.fillWidth: true
					text: `Today that is ${shotCard.example(pathField.text)}`
					tone: Theme.textMuted
					font.family: Theme.monoFamily
					font.pixelSize: Theme.size.small
					elide: Text.ElideMiddle
				}
			}
		}

		id: shotCard
	}

	// ── title bars ─────────────────────────────────────────────────────────
	SettingCard {
		anchor: "decorations"
		title: "Title bars"
		subtitle: "Ask apps to leave out their own title bars and shadows (prefer-no-csd). Restart an app to see it fully."
		icon: "page_layout_header"
		modified: NiriSettings.has(["prefer-no-csd"])
		onReset: NiriSettings.reset(["prefer-no-csd"], "Apps keep their title bars")

		RowLayout {
			Layout.fillWidth: true
			spacing: 18

			Item {
				Layout.preferredWidth: 180
				Layout.preferredHeight: 110

				readonly property bool bare: NiriSettings.flag(["prefer-no-csd"])

				Rectangle {
					anchors.fill: parent
					anchors.margins: 8
					radius: parent.bare ? 4 : 10
					color: Theme.layer2
					border.width: 1
					border.color: Theme.outline
					clip: true

					Behavior on radius {
						SpatialAnim {}
					}

					Rectangle {
						width: parent.width
						height: 24
						color: Theme.layer3
						y: parent.parent.bare ? -24 : 0

						Behavior on y {
							SpatialAnim {
								duration: Motion.long
							}
						}

						Row {
							anchors.right: parent.right
							anchors.rightMargin: 8
							anchors.verticalCenter: parent.verticalCenter
							spacing: 5

							Repeater {
								model: 3

								delegate: Rectangle {
									width: 8
									height: 8
									radius: 4
									color: Theme.textSubtle
								}
							}
						}
					}

					Column {
						x: 12
						y: parent.parent.bare ? 12 : 34
						spacing: 6

						Behavior on y {
							SpatialAnim {
								duration: Motion.long
							}
						}

						Repeater {
							model: [100, 70, 120]

							delegate: Rectangle {
								required property int modelData

								width: modelData
								height: 6
								radius: 3
								color: Theme.layer3
							}
						}
					}
				}
			}

			FlagRow {
				title: "Without their title bars"
				subtitle: "niri then draws rings and borders around them, not behind"
				checked: NiriSettings.flag(["prefer-no-csd"])
				onToggled: on => NiriSettings.setFlag(["prefer-no-csd"], on, on ? "Apps asked to drop their title bars" : "Apps keep their title bars")
			}
		}
	}

	// ── blur ───────────────────────────────────────────────────────────────
	SettingCard {
		anchor: "blur"
		title: "Blur"
		subtitle: "How blur behind windows and panels looks – for whatever asks for it, or a rule turns on"
		icon: "blur"
		modified: NiriSettings.kids(["blur"]).length > 0
		onReset: NiriSettings.reset(["blur"])
		trailing: Toggle {
			checked: !NiriSettings.flag(["blur", "off"])
			onToggled: on => NiriSettings.setFlag(["blur", "off"], !on, `Blur ${on ? "on" : "off"}`)
		}

		readonly property int passes: Number(NiriSettings.arg(["blur", "passes"], 3))
		readonly property real offset: Number(NiriSettings.arg(["blur", "offset"], 3))

		RowLayout {
			Layout.fillWidth: true
			spacing: 20
			enabled: !NiriSettings.flag(["blur", "off"])
			opacity: enabled ? 1 : 0.45

			GlassSample {
				Layout.preferredWidth: 280
				Layout.preferredHeight: 180
				// dual kawase reaches about offset · 2^passes pixels
				blur: Math.min(1, blurCard.offset * Math.pow(2, blurCard.passes) / 80)
				saturation: Number(NiriSettings.arg(["blur", "saturation"], 1.5))
				noise: Number(NiriSettings.arg(["blur", "noise"], 0.02))
			}

			ColumnLayout {
				Layout.fillWidth: true
				spacing: 10

				RowLayout {
					spacing: 10

					StyledText {
						text: "Passes"
						tone: Theme.textMuted
					}

					Repeater {
						model: [1, 2, 3, 4, 5, 6]

						delegate: Clickable {
							required property int modelData

							implicitWidth: 34
							implicitHeight: 34
							radius: 17
							color: modelData <= blurCard.passes ? Theme.primary : Theme.layer2
							onClicked: NiriSettings.set(["blur", "passes"], modelData, `Blur passes ${modelData}`, "")

							Behavior on color {
								ColorAnim {}
							}

							StyledText {
								anchors.centerIn: parent
								text: modelData
								tone: modelData <= blurCard.passes ? Theme.onPrimary : Theme.textMuted
								font.weight: Font.DemiBold
							}
						}
					}
				}

				ValueSlider {
					from: 0.5
					to: 12
					step: 0.5
					decimals: 1
					label: "Offset"
					value: blurCard.offset
					onMoved: v => NiriSettings.set(["blur", "offset"], v, `Blur offset ${v}`, "blur-offset")
				}

				ValueSlider {
					from: 0
					to: 0.2
					step: 0.005
					decimals: 3
					label: "Grain"
					value: Number(NiriSettings.arg(["blur", "noise"], 0.02))
					onMoved: v => NiriSettings.set(["blur", "noise"], v, "Blur grain", "blur-noise")
				}

				ValueSlider {
					from: 0
					to: 3
					step: 0.05
					decimals: 2
					label: "Saturation"
					value: Number(NiriSettings.arg(["blur", "saturation"], 1.5))
					format: v => `${Math.round(v * 100)}%`
					onMoved: v => NiriSettings.set(["blur", "saturation"], v, "Blur saturation", "blur-saturation")
				}

				StyledText {
					Layout.fillWidth: true
					text: "Raise the offset first – it costs nothing. When it starts to look blocky, add a pass."
					tone: Theme.textSubtle
					font.pixelSize: Theme.size.small
					wrapMode: Text.WordWrap
				}
			}
		}

		id: blurCard
	}

	// ── the small switches ─────────────────────────────────────────────────
	SettingCard {
		anchor: "system-more"
		title: "Clipboard, help overlay, notices, X11 apps"
		icon: "dots_horizontal_circle_outline"

		FlagRow {
			title: "Middle-click paste"
			subtitle: "Selecting text copies it, a middle click pastes it (primary selection) – for apps started after the change"
			checked: !NiriSettings.flag(["clipboard", "disable-primary"])
			onToggled: on => NiriSettings.setFlag(["clipboard", "disable-primary"], !on, `Middle-click paste ${on ? "on" : "off"}`)

			Item {
				anchors.fill: parent

				Rectangle {
					anchors.centerIn: parent
					width: 26
					height: 38
					radius: 13
					color: Theme.layer2
					border.width: 1
					border.color: Theme.outline

					Rectangle {
						anchors.horizontalCenter: parent.horizontalCenter
						y: 6
						width: 5
						height: 10
						radius: 2.5
						color: !NiriSettings.flag(["clipboard", "disable-primary"]) ? Theme.primary : Theme.textSubtle
					}
				}
			}
		}

		FlagRow {
			title: "Show the key help when niri starts"
			subtitle: "The “Important hotkeys” overlay at login"
			icon: "help_circle_outline"
			checked: !NiriSettings.flag(["hotkey-overlay", "skip-at-startup"])
			onToggled: on => NiriSettings.setFlag(["hotkey-overlay", "skip-at-startup"], !on, `Key help at start ${on ? "on" : "off"}`)
		}

		FlagRow {
			title: "Key help shows only bound keys"
			subtitle: "Hide the important actions that have no key"
			icon: "keyboard_off_outline"
			checked: NiriSettings.flag(["hotkey-overlay", "hide-not-bound"])
			onToggled: on => NiriSettings.setFlag(["hotkey-overlay", "hide-not-bound"], on, `Unbound actions ${on ? "hidden" : "shown"}`)
		}

		FlagRow {
			title: "Tell me when the config is broken"
			subtitle: "niri's “Failed to parse the config” notice – this window never writes a broken one"
			icon: "alert_outline"
			checked: !NiriSettings.flag(["config-notification", "disable-failed"])
			onToggled: on => NiriSettings.setFlag(["config-notification", "disable-failed"], !on, `Config notice ${on ? "on" : "off"}`)
		}

		FlagRow {
			title: "X11 apps (xwayland-satellite)"
			subtitle: NiriSettings.flag(["xwayland-satellite", "off"]) ? "Off – no DISPLAY, old X11 programs will not start" : "niri starts xwayland-satellite when an X11 program needs it"
			icon: "alpha_x_box_outline"
			checked: !NiriSettings.flag(["xwayland-satellite", "off"])
			onToggled: on => NiriSettings.setFlag(["xwayland-satellite", "off"], !on, `X11 apps ${on ? "on" : "off"}`)
		}

		Field {
			Layout.fillWidth: true
			visible: !NiriSettings.flag(["xwayland-satellite", "off"])
			icon: "file_cog_outline"
			placeholder: "Path to xwayland-satellite (empty: the one on PATH)"
			text: String(NiriSettings.arg(["xwayland-satellite", "path"], ""))
			input.font.family: Theme.monoFamily
			onAccepted: text.trim() === "" ? NiriSettings.reset(["xwayland-satellite", "path"]) : NiriSettings.set(["xwayland-satellite", "path"], text.trim(), "xwayland-satellite path set", "")
		}
	}
}
