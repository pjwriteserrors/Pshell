pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services
import qs.core.views.overlays.keybinds
import "Nodes.js" as Nodes

// Input: keyboard layouts and options, key repeat, every kind of pointing
// device, tablets and touch screens, how focus follows the mouse, and the
// Mod key.
SettingsPage {
	id: root

	title: "Input"
	description: "Keyboard, mouse, touchpad and the rest. Changes reach the devices the moment they are made."

	property string device: "touchpad"
	property string absolute: "tablet"

	function kb(name) {
		return ["input", "keyboard"].concat([].concat(name));
	}

	// ── layouts ────────────────────────────────────────────────────────────
	SettingCard {
		anchor: "layouts"
		title: "Keyboard layouts"
		subtitle: NiriSettings.has(root.kb(["xkb", "file"])) ? "A keymap file is set below – it wins over these" : "The languages your keys type in"
		icon: "translate"
		modified: NiriSettings.has(root.kb(["xkb", "layout"]))
		onReset: {
			NiriSettings.reset(root.kb(["xkb", "layout"]));
			NiriSettings.reset(root.kb(["xkb", "variant"]));
		}

		KeyboardLayouts {
			Layout.fillWidth: true
		}

		StyledText {
			Layout.fillWidth: true
			visible: !NiriSettings.has(root.kb(["xkb", "layout"]))
			text: "No layout set: niri asks the system (localectl) which one to use."
			tone: Theme.textSubtle
			font.pixelSize: Theme.size.small
		}

		// model, rules and a keymap file – for the few who need them
		RowLayout {
			Layout.fillWidth: true
			spacing: 10

			Repeater {
				model: [
					{ name: "model", hint: "Model (pc105…)" },
					{ name: "rules", hint: "Rules (evdev…)" },
					{ name: "file", hint: "Keymap file (~/.config/keymap.xkb)" }
				]

				delegate: Field {
					id: extra

					required property var modelData

					Layout.fillWidth: true
					Layout.preferredWidth: extra.modelData.name === "file" ? 2 : 1
					implicitHeight: 36
					icon: extra.modelData.name === "file" ? "file_outline" : "cog_outline"
					placeholder: extra.modelData.hint
					text: String(NiriSettings.arg(root.kb(["xkb", extra.modelData.name]), ""))
					onAccepted: extra.text.trim() === "" ? NiriSettings.reset(root.kb(["xkb", extra.modelData.name])) : NiriSettings.set(root.kb(["xkb", extra.modelData.name]), extra.text.trim(), `xkb ${extra.modelData.name} set`, "")
				}
			}
		}
	}

	// ── options ────────────────────────────────────────────────────────────
	SettingCard {
		anchor: "xkb-options"
		title: "Keyboard options"
		subtitle: "What some keys do – click a tile to switch it"
		icon: "keyboard_settings_outline"
		modified: NiriSettings.has(root.kb(["xkb", "options"]))
		onReset: NiriSettings.reset(root.kb(["xkb", "options"]))

		XkbOptions {
			Layout.fillWidth: true
		}
	}

	// ── repeat ─────────────────────────────────────────────────────────────
	SettingCard {
		anchor: "repeat"
		title: "Key repeat"
		subtitle: "How long a held key waits before it repeats, and how fast it then goes"
		icon: "repeat"
		modified: NiriSettings.has(root.kb("repeat-delay")) || NiriSettings.has(root.kb("repeat-rate"))
		onReset: {
			NiriSettings.reset(root.kb("repeat-delay"));
			NiriSettings.reset(root.kb("repeat-rate"));
		}

		RepeatTester {
			Layout.fillWidth: true
			delay: Number(NiriSettings.arg(root.kb("repeat-delay"), 600))
			rate: Number(NiriSettings.arg(root.kb("repeat-rate"), 25))
			onDelayMoved: ms => NiriSettings.set(root.kb("repeat-delay"), ms, `Repeat after ${ms} ms`, "repeat-delay")
			onRateMoved: rate => NiriSettings.set(root.kb("repeat-rate"), rate, `Repeat ${rate} per second`, "repeat-rate")
		}
	}

	// ── num lock, layout per window ────────────────────────────────────────
	SettingCard {
		anchor: "keyboard-more"
		title: "Num Lock and switching layouts"
		icon: "numeric"
		modified: NiriSettings.has(root.kb("numlock")) || NiriSettings.has(root.kb("track-layout"))
		onReset: {
			NiriSettings.reset(root.kb("numlock"));
			NiriSettings.reset(root.kb("track-layout"));
		}

		FlagRow {
			title: "Num Lock on at start"
			subtitle: "Leave off on laptops whose letters double as a number pad"
			checked: NiriSettings.flag(root.kb("numlock"))
			onToggled: on => NiriSettings.setFlag(root.kb("numlock"), on, `Num Lock at start ${on ? "on" : "off"}`)

			Grid {
				anchors.centerIn: parent
				columns: 3
				spacing: 2

				Repeater {
					model: ["7", "8", "9", "4", "5", "6"]

					delegate: Rectangle {
						required property string modelData

						width: 14
						height: 14
						radius: 3
						color: NiriSettings.flag(root.kb("numlock")) ? Theme.primary : Theme.layer3

						Behavior on color {
							ColorAnim {}
						}

						StyledText {
							anchors.centerIn: parent
							text: parent.modelData
							tone: NiriSettings.flag(root.kb("numlock")) ? Theme.onPrimary : Theme.textSubtle
							font.pixelSize: 8
						}
					}
				}
			}
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 10

			Repeater {
				model: [
					{ value: "global", title: "One layout for all", subtitle: "Switching changes it everywhere" },
					{ value: "window", title: "Each window its own", subtitle: "A window keeps the layout it had" }
				]

				delegate: OptionTile {
					id: track

					required property var modelData

					title: track.modelData.title
					subtitle: track.modelData.subtitle
					selected: String(NiriSettings.arg(root.kb("track-layout"), "global")) === track.modelData.value
					onClicked: track.modelData.value === "global" ? NiriSettings.reset(root.kb("track-layout"), "One layout for all windows") : NiriSettings.set(root.kb("track-layout"), "window", "Each window keeps its layout", "")

					Row {
						anchors.centerIn: parent
						spacing: 6

						Repeater {
							model: 3

							delegate: Rectangle {
								required property int index

								width: 46
								height: 52
								radius: 6
								color: Theme.layer3

								Rectangle {
									anchors.horizontalCenter: parent.horizontalCenter
									anchors.bottom: parent.bottom
									anchors.bottomMargin: 6
									width: 28
									height: 16
									radius: 4
									color: track.modelData.value === "window" && index === 1 ? Theme.secondary : Theme.primary

									StyledText {
										anchors.centerIn: parent
										text: track.modelData.value === "window" && index === 1 ? "US" : "DE"
										tone: Theme.onPrimary
										font.pixelSize: 9
										font.weight: Font.Bold
									}
								}
							}
						}
					}
				}
			}
		}
	}

	// ── pointing devices ───────────────────────────────────────────────────
	SettingCard {
		anchor: "pointer"
		title: "Mouse and touchpad"
		subtitle: "Every device of a kind gets the same settings"
		icon: "mouse"
		modified: NiriSettings.has(["input", root.device]) && NiriSettings.kids(["input", root.device]).length > 0
		onReset: NiriSettings.reset(["input", root.device])

		Segmented {
			Layout.fillWidth: true
			options: [
				{ value: "touchpad", label: "Touchpad", icon: "gesture_two_double_tap" },
				{ value: "mouse", label: "Mouse", icon: "mouse" },
				{ value: "trackpoint", label: "Trackpoint", icon: "circle_small" },
				{ value: "trackball", label: "Trackball", icon: "circle_outline" }
			]
			current: root.device
			onSelected: value => root.device = value
		}

		PointerPanel {
			Layout.fillWidth: true
			device: root.device
			active: root.active
		}
	}

	// ── tablet and touch ───────────────────────────────────────────────────
	SettingCard {
		anchor: "tablet"
		title: "Tablet and touch screen"
		subtitle: "Which monitor a pen tablet or a touch screen covers"
		icon: "draw_pen"
		modified: NiriSettings.has(["input", root.absolute]) && NiriSettings.kids(["input", root.absolute]).length > 0
		onReset: NiriSettings.reset(["input", root.absolute])

		Segmented {
			Layout.preferredWidth: 300
			options: [{ value: "tablet", label: "Tablet", icon: "draw_pen" }, { value: "touch", label: "Touch screen", icon: "gesture_tap" }]
			current: root.absolute
			onSelected: value => root.absolute = value
		}

		FlagRow {
			title: "Use it"
			icon: "power"
			checked: !NiriSettings.flag(["input", root.absolute, "off"])
			onToggled: on => NiriSettings.setFlag(["input", root.absolute, "off"], !on, `${root.absolute} ${on ? "on" : "off"}`)
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 18

			MonitorPicker {
				Layout.preferredWidth: 300
				Layout.preferredHeight: 120
				picked: String(NiriSettings.arg(["input", root.absolute, "map-to-output"], ""))
				onChosen: name => name === "" ? NiriSettings.reset(["input", root.absolute, "map-to-output"], "Covers every monitor") : NiriSettings.set(["input", root.absolute, "map-to-output"], name, `Mapped to ${name}`, "")
			}

			ColumnLayout {
				Layout.fillWidth: true
				spacing: 6

				StyledText {
					Layout.fillWidth: true
					text: NiriSettings.has(["input", root.absolute, "map-to-output"]) ? `Covers ${NiriSettings.arg(["input", root.absolute, "map-to-output"], "")} only` : "Covers all monitors together"
					font.weight: Font.DemiBold
				}

				StyledText {
					Layout.fillWidth: true
					text: "Click a monitor to map it there, click it again to let go."
					tone: Theme.textSubtle
					font.pixelSize: Theme.size.small
					wrapMode: Text.WordWrap
				}
			}
		}

		FlagRow {
			visible: root.absolute === "tablet"
			title: "Follow the focused monitor"
			subtitle: "The tablet covers whichever monitor has the focus"
			checked: NiriSettings.flag(["input", "tablet", "map-to-focused-output"])
			onToggled: on => NiriSettings.setFlag(["input", "tablet", "map-to-focused-output"], on, `Tablet follows the focus ${on ? "on" : "off"}`)
		}

		FlagRow {
			visible: root.absolute === "tablet"
			title: "Left-handed"
			subtitle: "Turns the tablet around"
			checked: NiriSettings.flag(["input", "tablet", "left-handed"])
			onToggled: on => NiriSettings.setFlag(["input", "tablet", "left-handed"], on, `Left-handed tablet ${on ? "on" : "off"}`)
		}

		Calibration {
			Layout.fillWidth: true
			matrix: NiriSettings.argsOf(["input", root.absolute, "calibration-matrix"])
			onEdited: m => m ? NiriSettings.setArgs(["input", root.absolute, "calibration-matrix"], m, "Calibration changed", "calibration") : NiriSettings.reset(["input", root.absolute, "calibration-matrix"])
		}
	}

	// ── focus ──────────────────────────────────────────────────────────────
	SettingCard {
		anchor: "focus"
		title: "Focus and the pointer"
		subtitle: "Whether moving the mouse picks windows, and whether the pointer jumps to them"
		icon: "cursor_default_click_outline"
		modified: NiriSettings.has(["input", "focus-follows-mouse"]) || NiriSettings.has(["input", "warp-mouse-to-focus"])
		onReset: {
			NiriSettings.reset(["input", "focus-follows-mouse"]);
			NiriSettings.reset(["input", "warp-mouse-to-focus"]);
		}

		FlagRow {
			title: "Focus follows the mouse"
			subtitle: "The window under the pointer gets the focus without a click"
			checked: NiriSettings.flag(["input", "focus-follows-mouse"])
			onToggled: on => NiriSettings.setFlag(["input", "focus-follows-mouse"], on, `Focus follows mouse ${on ? "on" : "off"}`)

			FocusDemo {
				anchors.fill: parent
				follows: NiriSettings.flag(["input", "focus-follows-mouse"])
				playing: root.active
			}
		}

		RowLayout {
			Layout.fillWidth: true
			Layout.leftMargin: 90
			visible: NiriSettings.flag(["input", "focus-follows-mouse"])
			spacing: 12

			StyledText {
				text: "Scroll at most"
				tone: Theme.textMuted
			}

			ValueSlider {
				from: 0
				to: 100
				step: 5
				readonly property string raw: String(NiriSettings.prop(["input", "focus-follows-mouse"], "max-scroll-amount", "100%"))
				value: Number(raw.replace("%", ""))
				format: v => v >= 100 ? "Any amount" : (v === 0 ? "Never scroll" : `${v}% of the screen`)
				onMoved: v => NiriSettings.setProps(["input", "focus-follows-mouse"], v >= 100 ? {} : { "max-scroll-amount": `${v}%` }, "Focus scrolling limit", "ffm-scroll")
			}
		}

		FlagRow {
			title: "Pointer jumps to the focused window"
			subtitle: "When the keyboard moves the focus, the pointer follows"
			checked: NiriSettings.has(["input", "warp-mouse-to-focus"]) && NiriSettings.arg(["input", "warp-mouse-to-focus"], true) !== false
			onToggled: on => NiriSettings.setFlag(["input", "warp-mouse-to-focus"], on, `Pointer warp ${on ? "on" : "off"}`)
		}

		RowLayout {
			Layout.fillWidth: true
			visible: NiriSettings.has(["input", "warp-mouse-to-focus"])
			spacing: 10

			Repeater {
				model: [
					{ value: "", title: "Shortest way", subtitle: "Only as far as needed, each axis alone" },
					{ value: "center-xy", title: "To the middle", subtitle: "When it was outside the window" },
					{ value: "center-xy-always", title: "Always the middle", subtitle: "Even when it was already inside" }
				]

				delegate: OptionTile {
					id: warp

					required property var modelData

					title: warp.modelData.title
					subtitle: warp.modelData.subtitle
					selected: String(NiriSettings.prop(["input", "warp-mouse-to-focus"], "mode", "")) === warp.modelData.value
					onClicked: NiriSettings.setProps(["input", "warp-mouse-to-focus"], warp.modelData.value === "" ? {} : { mode: warp.modelData.value }, `Pointer warps: ${warp.modelData.title.toLowerCase()}`, "")

					WarpDemo {
						anchors.fill: parent
						mode: warp.modelData.value
						playing: warp.playing && root.active
					}
				}
			}
		}
	}

	// ── mod key ────────────────────────────────────────────────────────────
	SettingCard {
		anchor: "mod"
		title: "Mod key"
		subtitle: "The key every Mod+ bind means – on its own, and in niri running in a window"
		icon: "apple_keyboard_command"
		modified: NiriSettings.has(["input", "mod-key"]) || NiriSettings.has(["input", "mod-key-nested"])
		onReset: {
			NiriSettings.reset(["input", "mod-key"]);
			NiriSettings.reset(["input", "mod-key-nested"]);
		}

		Repeater {
			model: [
				{ name: "mod-key", label: "On its own", fallback: "Super" },
				{ name: "mod-key-nested", label: "In a window", fallback: "Alt" }
			]

			delegate: RowLayout {
				id: modRow

				required property var modelData
				readonly property string current: String(NiriSettings.arg(["input", modRow.modelData.name], modRow.modelData.fallback))

				Layout.fillWidth: true
				spacing: 12

				StyledText {
					Layout.preferredWidth: 100
					text: modRow.modelData.label
					tone: Theme.textMuted
					font.weight: Font.Medium
				}

				Repeater {
					model: ["Super", "Alt", "Ctrl", "Shift", "Mod3", "Mod5"]

					delegate: Item {
						id: cap

						required property string modelData

						Layout.preferredWidth: 70
						Layout.preferredHeight: 48

						Keycap {
							anchors.centerIn: parent
							text: cap.modelData
							size: 26
							lit: modRow.current === cap.modelData
							faint: modRow.current !== cap.modelData && !capMouse.containsMouse
						}

						MouseArea {
							id: capMouse

							anchors.fill: parent
							hoverEnabled: true
							cursorShape: Qt.PointingHandCursor
							onClicked: cap.modelData === modRow.modelData.fallback ? NiriSettings.reset(["input", modRow.modelData.name], `Mod is ${cap.modelData}`) : NiriSettings.set(["input", modRow.modelData.name], cap.modelData, `Mod is ${cap.modelData}`, "")
						}
					}
				}
			}
		}

		StyledText {
			Layout.fillWidth: true
			visible: ["Ctrl", "Shift"].includes(String(NiriSettings.arg(["input", "mod-key"], "Super")))
			text: "Careful: apps use Ctrl and Shift themselves – their shortcuts and typing would hit niri's binds."
			tone: Theme.warning
			font.pixelSize: Theme.size.small
			wrapMode: Text.WordWrap
		}
	}

	// ── more ───────────────────────────────────────────────────────────────
	SettingCard {
		anchor: "input-more"
		title: "Power key, workspaces, hiding the pointer"
		icon: "dots_horizontal_circle_outline"

		FlagRow {
			title: "niri leaves the power key alone"
			subtitle: "By default it puts the computer to sleep instead of off; on: logind decides"
			icon: "power"
			checked: NiriSettings.flag(["input", "disable-power-key-handling"])
			onToggled: on => NiriSettings.setFlag(["input", "disable-power-key-handling"], on, `Power key ${on ? "left to logind" : "handled by niri"}`)
		}

		FlagRow {
			title: "Back and forth between workspaces"
			subtitle: "Going to the workspace you are on goes back to the one before"
			checked: NiriSettings.flag(["input", "workspace-auto-back-and-forth"])
			onToggled: on => NiriSettings.setFlag(["input", "workspace-auto-back-and-forth"], on, `Back and forth ${on ? "on" : "off"}`)

			Column {
				anchors.centerIn: parent
				spacing: 3

				Repeater {
					model: 3

					delegate: Rectangle {
						required property int index

						width: 40
						height: 10
						radius: 3
						color: index === backForth.at ? Theme.primary : Theme.layer3

						Behavior on color {
							ColorAnim {}
						}
					}
				}

				QtObject {
					id: backForth

					property int at: 0
				}

				Timer {
					interval: 800
					repeat: true
					running: root.active && NiriSettings.flag(["input", "workspace-auto-back-and-forth"])
					onTriggered: backForth.at = backForth.at === 0 ? 2 : 0
				}
			}
		}

		FlagRow {
			title: "Hide the pointer while typing"
			subtitle: "It comes back when the mouse moves (may bother some games)"
			icon: "cursor_text"
			checked: NiriSettings.flag(["cursor", "hide-when-typing"])
			onToggled: on => NiriSettings.setFlag(["cursor", "hide-when-typing"], on, `Hide pointer while typing ${on ? "on" : "off"}`)
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 12

			Glyph {
				Layout.leftMargin: 12
				icon: "timer_sand"
				size: 18
				color: Theme.textMuted
			}

			StyledText {
				text: "Hide an idle pointer"
				font.weight: Font.Medium
			}

			ValueSlider {
				from: 0
				to: 10000
				step: 250
				value: Number(NiriSettings.arg(["cursor", "hide-after-inactive-ms"], 0))
				format: v => v === 0 ? "Never" : `after ${(v / 1000).toFixed(v % 1000 === 0 ? 0 : 2)} s`
				onMoved: v => v === 0 ? NiriSettings.reset(["cursor", "hide-after-inactive-ms"], "Idle pointer stays") : NiriSettings.set(["cursor", "hide-after-inactive-ms"], v, `Pointer hides after ${v} ms`, "hide-after")
			}
		}
	}
}
