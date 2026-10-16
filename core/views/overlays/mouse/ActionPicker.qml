pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "Controls.js" as Controls

// What a trigger does: picked from groups (the shell, windows, media, the
// mouse itself …), a shortcut pressed, a command typed. Below: how it feels
// (a haptic pulse) and, for swipes, whether it goes on while moving.
Popup {
	id: root

	property string control: ""
	property string trigger: ""
	property string app: ""
	property var rule: null
	// feel and repeat reach a rule that is already there at once; off for a
	// picker that makes a new rule (one with keys held)
	property bool live: true
	property string group: "suggested"
	readonly property bool recording: recorder.recording

	signal chosen(var action, var extra)

	// the shortcut group listens at once: the next keys pressed are the shortcut
	onGroupChanged: if (root.group === "keys" && root.opened) Qt.callLater(() => recorder.start())
	onOpened: if (root.group === "keys") recorder.start()
	signal cleared

	function show(control, trigger, app) {
		root.control = control;
		root.trigger = trigger;
		root.app = app;
		root.rule = Mouse.ruleFor(control, trigger, app);
		const action = root.rule?.action;
		root.group = action ? ({ keys: "keys", command: "command", button: "buttons", scroll: "buttons", niri: "windows", mouse: "mouse", shell: "shell" })[action.kind] ?? "suggested" : "suggested";
		if (action?.kind === "shell") {
			const known = Mouse.shellActions.find(a => a.id === action.id);
			if (known) root.group = known.group === "Shell" ? "shell" : known.group.toLowerCase();
		}
		if (action?.kind === "niri") {
			const known = Mouse.niriActions.find(a => a.id === action.action);
			if (known) root.group = known.group.toLowerCase();
		}
		feel.current = root.rule?.feel === undefined || root.rule?.feel === null ? "auto" : (root.rule.feel === "" ? "none" : root.rule.feel);
		repeat.checked = root.rule?.repeat === true;
		sustain.checked = action?.sustain === true;
		latch.checked = action?.latch === true;
		recorder.keys = action?.kind === "keys" ? (action.keys ?? []) : [];
		recorder.codes = action?.kind === "keys" ? (action.codes ?? []) : [];
		recorder.label = action?.kind === "keys" ? (action.label ?? "") : "";
		commandField.text = action?.kind === "command" ? String(action.command ?? "") : "";
		search.text = "";
		root.open();
	}

	readonly property bool swipe: ["up", "down", "left", "right", "wheel-up", "wheel-down", "thumb-left", "thumb-right"].includes(root.trigger) || root.control === "thumb"
	readonly property bool canSustain: root.trigger === "click" || root.trigger === "hold"

	function extra() {
		const out = {};
		out.feel = feel.current === "auto" ? null : (feel.current === "none" ? "" : feel.current);
		if (root.swipe) out.repeat = repeat.checked;
		return out;
	}

	// how it feels changed on a rule that exists: keep it without a new pick
	function keep() {
		if (!root.live || !root.rule)
			return;
		root.rule = Object.assign({}, root.rule, root.extra());
		Mouse.putRule(root.rule);
	}

	function pick(action) {
		if (action.kind === "keys" && root.canSustain && sustain.checked) action = Object.assign({}, action, { sustain: true });
		else if (action.kind === "keys" && latch.checked) action = Object.assign({}, action, { latch: true });
		root.chosen(action, root.extra());
		root.close();
	}

	// suggestions per control
	readonly property var suggested: {
		const s = {
			gesture: [{ kind: "niri", action: "toggle-overview" }, { kind: "shell", id: "launcher" }, { kind: "niri", action: "focus-workspace-down" }, { kind: "niri", action: "focus-workspace-up" }, { kind: "shell", id: "radial" }, { kind: "shell", id: "play" }],
			haptic: [{ kind: "shell", id: "radial" }, { kind: "shell", id: "launcher" }, { kind: "niri", action: "toggle-overview" }, { kind: "shell", id: "shot-region" }, { kind: "shell", id: "clipboard" }],
			shift: [{ kind: "mouse", op: "ratchet" }, { kind: "mouse", op: "dpi-shift" }, { kind: "mouse", op: "dpi-cycle" }, { kind: "mouse", op: "smartshift" }],
			middle: [{ kind: "button", button: "middle" }, { kind: "keys", keys: ["ctrl", "w"] }, { kind: "niri", action: "toggle-overview" }, { kind: "shell", id: "play" }],
			back: [{ kind: "button", button: "back" }, { kind: "keys", keys: ["ctrl", "z"] }, { kind: "niri", action: "focus-column-left" }, { kind: "shell", id: "previous" }],
			forward: [{ kind: "button", button: "forward" }, { kind: "keys", keys: ["ctrl", "shift", "z"] }, { kind: "niri", action: "focus-column-right" }, { kind: "shell", id: "next" }],
			thumb: [{ kind: "scroll", dir: root.trigger === "left" ? "left" : "right" }, { kind: "shell", id: root.trigger === "left" ? "volume-down" : "volume-up" }, { kind: "niri", action: root.trigger === "left" ? "focus-column-left" : "focus-column-right" }, { kind: "keys", keys: root.trigger === "left" ? ["ctrl", "shift", "tab"] : ["ctrl", "tab"] }, { kind: "niri", action: root.trigger === "left" ? "focus-workspace-up" : "focus-workspace-down" }]
		};
		return (s[root.control] ?? s.gesture).map(action => ({ action, info: Mouse.describe(action, root.control) }));
	}

	readonly property var groups: [
		{ id: "suggested", label: "Suggested", icon: "star_outline" },
		{ id: "shell", label: "Shell", icon: "view_dashboard_outline" },
		{ id: "windows", label: "Windows", icon: "view_column_outline" },
		{ id: "workspaces", label: "Workspaces", icon: "view_grid_outline" },
		{ id: "media", label: "Media & volume", icon: "music_note" },
		{ id: "screenshot", label: "Screenshot", icon: "selection_drag" },
		{ id: "mouse", label: "The mouse", icon: "mouse" },
		{ id: "profiles", label: "Profiles", icon: "account_switch_outline" },
		{ id: "keys", label: "Shortcut", icon: "keyboard_outline" },
		{ id: "buttons", label: "Click & scroll", icon: "cursor_default_click_outline" },
		{ id: "command", label: "Command", icon: "console" }
	]

	readonly property var all: {
		const out = [];
		for (const p of Mouse.profiles)
			out.push({ group: "profiles", action: { kind: "shell", id: "profile", value: p.id }, info: { label: `Switch to ${p.name}`, icon: p.icon || "mouse_variant" }, detail: "Kept in every profile" });
		for (const a of Mouse.shellActions.filter(a => !a.hidden))
			out.push({ group: a.group === "Shell" ? "shell" : a.group.toLowerCase(), action: { kind: "shell", id: a.id }, info: { label: a.label, icon: a.icon }, detail: a.detail ?? "" });
		for (const a of Mouse.niriActions)
			out.push({ group: a.group.toLowerCase(), action: { kind: "niri", action: a.id }, info: { label: a.label, icon: a.icon }, detail: `niri: ${a.id}` });
		for (const a of Mouse.mouseActions) {
			if (a.lasting && !root.canSustain) continue;
			out.push({ group: "mouse", action: { kind: "mouse", op: a.id }, info: { label: a.label, icon: a.icon }, detail: a.detail ?? "" });
		}
		for (const b of ["left", "right", "middle", "back", "forward"])
			out.push({ group: "buttons", action: { kind: "button", button: b }, info: Mouse.describe({ kind: "button", button: b }), detail: "" });
		for (const d of ["up", "down", "left", "right"])
			out.push({ group: "buttons", action: { kind: "scroll", dir: d }, info: Mouse.describe({ kind: "scroll", dir: d }), detail: "" });
		return out;
	}

	readonly property var shown: {
		const q = search.text.trim().toLowerCase();
		if (q !== "") return root.all.filter(e => `${e.info.label} ${e.detail} ${e.group}`.toLowerCase().includes(q));
		if (root.group === "suggested") return root.suggested.map(e => Object.assign({ group: "suggested", detail: "" }, e));
		return root.all.filter(e => e.group === root.group);
	}

	function same(a, b) {
		if (!a || !b || a.kind !== b.kind) return false;
		return JSON.stringify([a.id, a.action, a.op, a.button, a.dir, a.value]) === JSON.stringify([b.id, b.action, b.op, b.button, b.dir, b.value]);
	}

	anchors.centerIn: Overlay.overlay
	width: 720
	height: 580
	padding: 0
	modal: true
	dim: true
	// keys go to the picker (the recorder, the search), not to the window behind
	focus: true
	closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

	Overlay.modal: Rectangle {
		color: Theme.scrim

		Behavior on opacity {
			Anim {}
		}
	}

	enter: Transition {
		ParallelAnimation {
			NumberAnimation {
				property: "opacity"
				from: 0
				to: 1
				duration: Motion.short
			}
			NumberAnimation {
				property: "scale"
				from: 0.9
				to: 1
				duration: Motion.long
				easing.type: Easing.BezierSpline
				easing.bezierCurve: Motion.spatial
			}
		}
	}
	exit: Transition {
		ParallelAnimation {
			NumberAnimation {
				property: "opacity"
				to: 0
				duration: Motion.short
			}
			NumberAnimation {
				property: "scale"
				to: 0.96
				duration: Motion.short
			}
		}
	}

	background: Rectangle {
		radius: Theme.radius.huge + 4
		color: Theme.base
		border.width: 1
		border.color: Theme.outline
	}

	contentItem: ColumnLayout {
		spacing: 0

		// ── what is being set ──────────────────────────────────────────────
		RowLayout {
			Layout.fillWidth: true
			Layout.margins: 20
			Layout.bottomMargin: 14
			spacing: 14

			Rectangle {
				Layout.preferredWidth: 44
				Layout.preferredHeight: 44
				radius: Theme.radius.large
				color: Theme.primaryContainer

				Glyph {
					anchors.centerIn: parent
					icon: Controls.byId(root.control)?.icon ?? "mouse"
					size: 22
					color: Theme.primary
				}
			}

			ColumnLayout {
				Layout.fillWidth: true
				spacing: 1

				StyledText {
					Layout.fillWidth: true
					text: `${Controls.byId(root.control)?.label ?? root.control} · ${Controls.triggerLabel(root.control, root.trigger)}`
					font.pixelSize: Theme.size.heading
					font.weight: Font.Bold
					elide: Text.ElideRight
				}

				StyledText {
					Layout.fillWidth: true
					text: root.app === "" ? "Everywhere" : `Only in ${root.app}`
					tone: Theme.textSubtle
					font.pixelSize: Theme.size.small
				}
			}

			Field {
				id: search

				Layout.preferredWidth: 220
				icon: "magnify"
				placeholder: "Find an action"
			}
		}

		Rectangle {
			Layout.fillWidth: true
			Layout.preferredHeight: 1
			color: Theme.outline
		}

		RowLayout {
			Layout.fillWidth: true
			Layout.fillHeight: true
			spacing: 0

			// ── groups ─────────────────────────────────────────────────────
			Item {
				Layout.preferredWidth: 200
				Layout.fillHeight: true

				Rectangle {
					id: groupMarker

					readonly property Item target: groupRepeater.itemAt(root.groups.findIndex(g => g.id === root.group))

					x: 10
					width: parent.width - 20
					height: 38
					y: (groupMarker.target ? groupMarker.target.y : 0) + groupColumn.y
					radius: Theme.radius.medium
					color: Theme.primaryContainer
					opacity: search.text.trim() === "" ? 1 : 0

					Behavior on y {
						SpatialAnim {
							duration: Motion.medium
						}
					}
					Behavior on opacity {
						Anim {}
					}
				}

				Column {
					id: groupColumn

					x: 10
					y: 12
					width: parent.width - 20
					spacing: 2

					Repeater {
						id: groupRepeater

						model: root.groups

						delegate: Clickable {
							id: tab

							required property var modelData
							readonly property bool picked: root.group === tab.modelData.id && search.text.trim() === ""

							width: groupColumn.width
							height: 38
							radius: Theme.radius.medium
							pressedScale: 0.97
							sound: "select"
							onClicked: {
								search.text = "";
								root.group = tab.modelData.id;
								if (tab.modelData.id === "command") commandField.focusInput();
							}

							RowLayout {
								anchors.fill: parent
								anchors.leftMargin: 12
								spacing: 10

								Glyph {
									icon: tab.modelData.icon
									size: 16
									color: tab.picked ? Theme.primary : Theme.textMuted
								}

								StyledText {
									Layout.fillWidth: true
									text: tab.modelData.label
									tone: tab.picked ? Theme.primary : Theme.text
									font.weight: tab.picked ? Font.DemiBold : Font.Medium
								}
							}
						}
					}
				}
			}

			Rectangle {
				Layout.preferredWidth: 1
				Layout.fillHeight: true
				color: Theme.outline
			}

			// ── what the group has ─────────────────────────────────────────
			Item {
				Layout.fillWidth: true
				Layout.fillHeight: true
				clip: true

				// a list of actions
				GridView {
					id: grid

					anchors.fill: parent
					anchors.margins: 12
					visible: search.text.trim() !== "" || !["keys", "command"].includes(root.group)
					cellWidth: Math.floor(width / 2)
					cellHeight: 64
					model: root.shown
					boundsBehavior: Flickable.StopAtBounds
					ScrollBar.vertical: ThinScrollBar {}

					// a new group slides its items in
					populate: Transition {
						id: popTrans

						SequentialAnimation {
							PropertyAction {
								property: "opacity"
								value: 0
							}
							PauseAnimation {
								duration: popTrans.ViewTransition.index * 18
							}
							ParallelAnimation {
								NumberAnimation {
									property: "opacity"
									to: 1
									duration: Motion.medium
								}
								NumberAnimation {
									property: "y"
									from: popTrans.ViewTransition.destination.y + 14
									duration: Motion.long
									easing.type: Easing.BezierSpline
									easing.bezierCurve: Motion.decel
								}
							}
						}
					}

					delegate: Item {
						id: cell

						required property var modelData
						readonly property bool current: root.same(root.rule?.action, cell.modelData.action)

						width: grid.cellWidth
						height: grid.cellHeight

						Clickable {
							id: cellButton

							anchors.fill: parent
							anchors.margins: 4
							radius: Theme.radius.large
							color: cell.current ? Theme.primaryContainer : (hovered ? Theme.layer2 : Theme.layer1)
							border.width: cell.current ? 1.5 : 0
							border.color: Theme.primary
							onClicked: root.pick(cell.modelData.action)

							RowLayout {
								anchors.fill: parent
								anchors.leftMargin: 12
								anchors.rightMargin: 8
								spacing: 10

								Rectangle {
									Layout.preferredWidth: 32
									Layout.preferredHeight: 32
									radius: Theme.radius.medium
									color: cell.current ? Theme.primary : Theme.primarySoft

									Glyph {
										anchors.centerIn: parent
										icon: cell.modelData.info.icon || "flash"
										size: 16
										color: cell.current ? Theme.onPrimary : Theme.primary
									}
								}

								ColumnLayout {
									Layout.fillWidth: true
									spacing: 0

									StyledText {
										Layout.fillWidth: true
										text: cell.modelData.info.label
										font.weight: Font.Medium
										elide: Text.ElideRight
									}

									StyledText {
										Layout.fillWidth: true
										visible: text !== ""
										text: cell.modelData.detail ?? ""
										tone: Theme.textSubtle
										font.pixelSize: Theme.size.tiny
										elide: Text.ElideRight
									}
								}

								IconButton {
									implicitWidth: 28
									implicitHeight: 28
									icon: "play_outline"
									visible: cellButton.hovered
									onClicked: Mouse.test(cell.modelData.action)
								}
							}
						}
					}
				}

				EmptyState {
					anchors.centerIn: parent
					visible: grid.visible && root.shown.length === 0
					icon: "magnify"
					title: "No such action"
					subtitle: "A shortcut or a command can do anything else"
				}

				// a shortcut
				ColumnLayout {
					anchors.fill: parent
					anchors.margins: 20
					visible: search.text.trim() === "" && root.group === "keys"
					spacing: 14

					KeyRecorder {
						id: recorder

						Layout.fillWidth: true
						Layout.preferredHeight: 150
					}

					FlagRowLite {
						id: sustain

						Layout.fillWidth: true
						visible: root.canSustain
						title: "Hold the keys while the button is down"
						subtitle: "For a held Shift or Super – the button works like the key itself"
						onCheckedChanged: if (checked) latch.checked = false
					}

					FlagRowLite {
						id: latch

						Layout.fillWidth: true
						title: "Stays down until pressed again"
						subtitle: "A sticky key: one press holds it, the next lets go"
						onCheckedChanged: if (checked) sustain.checked = false
					}

					Item {
						Layout.fillHeight: true
					}

					RowLayout {
						Layout.fillWidth: true

						Item {
							Layout.fillWidth: true
						}

						TextButton {
							variant: "ghost"
							icon: "play_outline"
							text: "Try"
							enabled: recorder.keys.length > 0
							onActivated: Mouse.test({ kind: "keys", keys: recorder.keys, codes: recorder.codes })
						}

						TextButton {
							variant: "filled"
							icon: "check"
							text: "Use this shortcut"
							enabled: recorder.keys.length > 0
							onActivated: root.pick({ kind: "keys", keys: recorder.keys, codes: recorder.codes, label: recorder.label })
						}
					}
				}

				// a command
				ColumnLayout {
					anchors.fill: parent
					anchors.margins: 20
					visible: search.text.trim() === "" && root.group === "command"
					spacing: 12

					StyledText {
						Layout.fillWidth: true
						text: "Runs in a shell (sh -c), with the session's environment."
						tone: Theme.textMuted
						wrapMode: Text.WordWrap
					}

					Field {
						id: commandField

						Layout.fillWidth: true
						icon: "console"
						placeholder: "notify-send 'Hello'"
						onAccepted: if (commandField.text.trim() !== "") root.pick({ kind: "command", command: commandField.text.trim() })
					}

					Item {
						Layout.fillHeight: true
					}

					RowLayout {
						Layout.fillWidth: true

						Item {
							Layout.fillWidth: true
						}

						TextButton {
							variant: "ghost"
							icon: "play_outline"
							text: "Try"
							enabled: commandField.text.trim() !== ""
							onActivated: Mouse.test({ kind: "command", command: commandField.text.trim() })
						}

						TextButton {
							variant: "filled"
							icon: "check"
							text: "Use this command"
							enabled: commandField.text.trim() !== ""
							onActivated: root.pick({ kind: "command", command: commandField.text.trim() })
						}
					}
				}
			}
		}

		Rectangle {
			Layout.fillWidth: true
			Layout.preferredHeight: 1
			color: Theme.outline
		}

		// ── how it feels, and the way back ─────────────────────────────────
		RowLayout {
			Layout.fillWidth: true
			Layout.margins: 14
			Layout.leftMargin: 20
			spacing: 10

			Glyph {
				icon: "vibrate"
				size: 16
				color: Theme.textMuted
				visible: (Mouse.state.haptic ?? null) !== null
			}

			Segmented {
				id: feel

				Layout.preferredWidth: 300
				visible: (Mouse.state.haptic ?? null) !== null
				options: [
					{ value: "auto", label: "Auto" },
					{ value: "none", label: "None" },
					{ value: "SUBTLE COLLISION", label: "Tick" },
					{ value: "SHARP STATE CHANGE", label: "Click" },
					{ value: "KNOCK", label: "Knock" }
				]
				onSelected: value => {
					feel.current = value;
					if (value !== "auto" && value !== "none") Mouse.play(value);
					root.keep();
				}
			}

			FlagRowLite {
				id: repeat

				visible: root.swipe && root.control !== "thumb" && !root.trigger.startsWith("wheel") && !root.trigger.startsWith("thumb")
				title: "Again while moving"
				compact: true
				onClicked: Qt.callLater(root.keep)
			}

			Item {
				Layout.fillWidth: true
			}

			TextButton {
				variant: "ghost"
				icon: "backup_restore"
				text: root.app === "" ? `Default: ${Mouse.nativeLabel(root.control)}` : "As everywhere"
				visible: root.rule !== null
				onActivated: {
					root.cleared();
					root.close();
				}
			}

			TextButton {
				variant: "ghost"
				icon: "cancel"
				text: "Nothing"
				onActivated: root.pick({ kind: "none" })
			}
		}
	}

	// a switch with words, small
	component FlagRowLite: Clickable {
		id: flag

		property string title: ""
		property string subtitle: ""
		property bool checked: false
		property bool compact: false

		implicitHeight: flag.compact ? 36 : (flag.subtitle !== "" ? 56 : 44)
		implicitWidth: flagRow.implicitWidth + 20
		radius: Theme.radius.large
		color: flag.compact ? "transparent" : Theme.layer1
		sound: ""
		onClicked: {
			Sounds.play(flag.checked ? "toggleOff" : "toggleOn");
			flag.checked = !flag.checked;
		}

		RowLayout {
			id: flagRow

			anchors.fill: parent
			anchors.leftMargin: 10
			anchors.rightMargin: 10
			spacing: 10

			ColumnLayout {
				Layout.fillWidth: true
				spacing: 0

				StyledText {
					text: flag.title
					font.weight: Font.Medium
				}

				StyledText {
					visible: flag.subtitle !== ""
					Layout.fillWidth: true
					text: flag.subtitle
					tone: Theme.textSubtle
					font.pixelSize: Theme.size.small
					wrapMode: Text.WordWrap
				}
			}

			Toggle {
				checked: flag.checked
				onToggled: on => flag.checked = on
			}
		}
	}
}
