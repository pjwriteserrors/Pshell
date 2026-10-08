pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services
import qs.core.views.overlays.keybinds
import "Nodes.js" as Nodes

// Overview & gestures: how far the overview zooms out and what is behind
// it, the hot corners, scrolling while dragging to an edge, and the Alt-Tab
// window switcher.
SettingsPage {
	id: root

	title: "Overview & gestures"
	description: "The overview, the corners that open it, what happens at the screen's edges while dragging, and the window switcher."

	readonly property var shadow: NiriSettings.node(["overview", "workspace-shadow"])
	readonly property var recent: NiriSettings.node(["recent-windows"])
	readonly property bool recentOn: !NiriSettings.flag(["recent-windows", "off"])
	readonly property var defaultBinds: [
		{ key: "Alt+Tab", action: "next-window", props: {} },
		{ key: "Alt+Shift+Tab", action: "previous-window", props: {} },
		{ key: "Alt+grave", action: "next-window", props: { filter: "app-id" } },
		{ key: "Alt+Shift+grave", action: "previous-window", props: { filter: "app-id" } },
		{ key: "Mod+Tab", action: "next-window", props: {} },
		{ key: "Mod+Shift+Tab", action: "previous-window", props: {} },
		{ key: "Mod+grave", action: "next-window", props: { filter: "app-id" } },
		{ key: "Mod+Shift+grave", action: "previous-window", props: { filter: "app-id" } }
	]
	readonly property var switcherBinds: {
		const block = NiriSettings.node(["recent-windows", "binds"]);
		if (!block) return root.defaultBinds;
		return (block.children || []).filter(b => !b.disabled).map(b => ({ key: b.name, action: b.children?.[0]?.name ?? "next-window", props: b.children?.[0]?.props ?? {} }));
	}

	function writeBinds(list, note) {
		NiriSettings.setChildren(["recent-windows", "binds"], list.map(b => Nodes.make(b.key, [], {}, [Nodes.make(b.action, [], b.props)])), note, "");
	}

	// ── overview ───────────────────────────────────────────────────────────
	SettingCard {
		anchor: "overview"
		title: "Overview"
		subtitle: "Mod+O, or a hot corner: every workspace at once. Drag the corner of the middle one to zoom."
		icon: "view_dashboard_outline"
		modified: NiriSettings.has(["overview"]) && NiriSettings.kids(["overview"]).length > 0
		onReset: NiriSettings.reset(["overview"])

		RowLayout {
			Layout.fillWidth: true
			spacing: 20

			OverviewPreview {
				Layout.preferredWidth: 420
				Layout.preferredHeight: 236
				zoom: Number(NiriSettings.arg(["overview", "zoom"], 0.5))
				backdrop: String(NiriSettings.arg(["overview", "backdrop-color"], "#262626"))
				shadowOn: Nodes.on(root.shadow, true)
				softness: Number(Nodes.arg(root.shadow, "softness", 40))
				spread: Number(Nodes.arg(root.shadow, "spread", 10))
				offsetY: Number(Nodes.prop(root.shadow, "offset", "y", 10))
				shadowColor: String(Nodes.arg(root.shadow, "color", "#00000050"))
				onZoomed: z => NiriSettings.set(["overview", "zoom"], z, `Overview at ${Math.round(z * 100)}%`, "overview-zoom")
			}

			ColumnLayout {
				Layout.fillWidth: true
				spacing: 12

				ValueSlider {
					from: 0.05
					to: 0.75
					step: 0.01
					label: "Zoom"
					value: Number(NiriSettings.arg(["overview", "zoom"], 0.5))
					format: v => `${Math.round(v * 100)}%`
					onMoved: v => NiriSettings.set(["overview", "zoom"], v, `Overview at ${Math.round(v * 100)}%`, "overview-zoom")
				}

				ColorWell {
					label: "Backdrop"
					alpha: false
					allowTransparent: true
					value: String(NiriSettings.arg(["overview", "backdrop-color"], "#262626"))
					onPicked: css => NiriSettings.set(["overview", "backdrop-color"], css, "Backdrop color", "overview-backdrop")
				}

				FlagRow {
					title: "Shadows under the workspaces"
					checked: Nodes.on(root.shadow, true)
					onToggled: on => NiriSettings.setSection(["overview", "workspace-shadow"], on, `Workspace shadows ${on ? "on" : "off"}`)
				}
			}
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 12
			visible: Nodes.on(root.shadow, true)

			ValueSlider {
				from: 0
				to: 200
				step: 1
				label: "Softness"
				unit: " px"
				value: Number(Nodes.arg(root.shadow, "softness", 40))
				onMoved: v => NiriSettings.setChildren(["overview", "workspace-shadow"], Nodes.withArg(root.shadow, "softness", v).children, "Workspace shadow", "ws-shadow-soft")
			}

			ValueSlider {
				from: -50
				to: 100
				step: 1
				label: "Spread"
				unit: " px"
				value: Number(Nodes.arg(root.shadow, "spread", 10))
				onMoved: v => NiriSettings.setChildren(["overview", "workspace-shadow"], Nodes.withArg(root.shadow, "spread", v).children, "Workspace shadow", "ws-shadow-spread")
			}

			ValueSlider {
				from: -60
				to: 120
				step: 1
				label: "Drop"
				unit: " px"
				value: Number(Nodes.prop(root.shadow, "offset", "y", 10))
				onMoved: v => NiriSettings.setChildren(["overview", "workspace-shadow"], Nodes.withNode(root.shadow, "offset", [], { x: Number(Nodes.prop(root.shadow, "offset", "x", 0)), y: v }).children, "Workspace shadow", "ws-shadow-offset")
			}

			ColorWell {
				showHex: false
				value: String(Nodes.arg(root.shadow, "color", "#00000050"))
				onPicked: css => NiriSettings.setChildren(["overview", "workspace-shadow"], Nodes.withArg(root.shadow, "color", css).children, "Workspace shadow color", "ws-shadow-color")
			}
		}
	}

	// ── hot corners ────────────────────────────────────────────────────────
	SettingCard {
		anchor: "hot-corners"
		title: "Hot corners"
		subtitle: "Push the pointer into a lit corner and the overview opens – also while dragging something. Click the corners."
		icon: "arrow_top_left_thick"
		modified: NiriSettings.has(["gestures", "hot-corners"])
		onReset: NiriSettings.reset(["gestures", "hot-corners"])

		RowLayout {
			Layout.fillWidth: true
			spacing: 20

			CornerPicker {
				Layout.preferredWidth: 300
				Layout.preferredHeight: 180
				readonly property var block: NiriSettings.node(["gestures", "hot-corners"])
				off: !!block && Nodes.flag(block, "off")
				corners: {
					if (!block) return ["top-left"];
					const set = ["top-left", "top-right", "bottom-left", "bottom-right"].filter(c => Nodes.flag(block, c));
					return set.length > 0 ? set : ["top-left"];
				}
				onEdited: (corners, off) => NiriSettings.setChildren(["gestures", "hot-corners"], off ? [NiriSettings.leaf("off")] : corners.map(c => NiriSettings.leaf(c)), off ? "Hot corners off" : "Hot corners changed", "")
			}

			StyledText {
				Layout.fillWidth: true
				text: "Every monitor gets these; a monitor can have its own on the Displays page."
				tone: Theme.textSubtle
				font.pixelSize: Theme.size.small
				wrapMode: Text.WordWrap
			}
		}
	}

	// ── dragging to an edge ────────────────────────────────────────────────
	SettingCard {
		anchor: "dnd-edge"
		title: "Scrolling while dragging"
		subtitle: "Drag a file or a window against an edge and the view moves along. Pull the strips wider or narrower."
		icon: "gesture_swipe_horizontal"
		modified: NiriSettings.has(["gestures", "dnd-edge-view-scroll"]) || NiriSettings.has(["gestures", "dnd-edge-workspace-switch"])
		onReset: {
			NiriSettings.reset(["gestures", "dnd-edge-view-scroll"]);
			NiriSettings.reset(["gestures", "dnd-edge-workspace-switch"]);
		}

		Repeater {
			model: [
				{ name: "dnd-edge-view-scroll", axis: "sides", size: "trigger-width", title: "Left and right: the columns scroll", logical: 1920 },
				{ name: "dnd-edge-workspace-switch", axis: "ends", size: "trigger-height", title: "Top and bottom, in the overview: workspaces switch", logical: 1080 }
			]

			delegate: RowLayout {
				id: edge

				required property var modelData
				readonly property var path: ["gestures", edge.modelData.name]

				Layout.fillWidth: true
				spacing: 18

				EdgeZones {
					Layout.preferredWidth: 260
					Layout.preferredHeight: 140
					axis: edge.modelData.axis
					logical: edge.modelData.logical
					trigger: Number(NiriSettings.arg(edge.path.concat([edge.modelData.size]), edge.modelData.axis === "sides" ? 30 : 50))
					delay: Number(NiriSettings.arg(edge.path.concat(["delay-ms"]), 100))
					playing: root.active
					onMoved: v => NiriSettings.set(edge.path.concat([edge.modelData.size]), v, "Edge strip changed", `${edge.modelData.name}-size`)
				}

				ColumnLayout {
					Layout.fillWidth: true
					spacing: 10

					StyledText {
						Layout.fillWidth: true
						text: edge.modelData.title
						font.weight: Font.DemiBold
					}

					TimeLine {
						Layout.fillWidth: true
						maximum: 1000
						start: "At the edge"
						happens: "Scrolls"
						icon: "arrow_right"
						playing: root.active
						value: Number(NiriSettings.arg(edge.path.concat(["delay-ms"]), 100))
						onMoved: v => NiriSettings.set(edge.path.concat(["delay-ms"]), v, "Edge delay changed", `${edge.modelData.name}-delay`)
					}

					ValueSlider {
						from: 200
						to: 6000
						step: 100
						label: "Fastest"
						value: Number(NiriSettings.arg(edge.path.concat(["max-speed"]), 1500))
						format: v => edge.modelData.axis === "sides" ? `${v} px/s` : `${(v / 1500).toFixed(1)} screens/s`
						onMoved: v => NiriSettings.set(edge.path.concat(["max-speed"]), v, "Edge speed changed", `${edge.modelData.name}-speed`)
					}
				}
			}
		}
	}

	// ── window switcher ────────────────────────────────────────────────────
	SettingCard {
		anchor: "recent"
		title: "Window switcher"
		subtitle: "Alt-Tab through the windows you used last – hold the modifier, tap Tab"
		icon: "swap_horizontal_variant"
		modified: !!root.recent && NiriSettings.kids(["recent-windows"]).length > 0
		onReset: NiriSettings.reset(["recent-windows"])
		trailing: Toggle {
			checked: root.recentOn
			onToggled: on => NiriSettings.setFlag(["recent-windows", "off"], !on, `Window switcher ${on ? "on" : "off"}`)
		}

		ColumnLayout {
			Layout.fillWidth: true
			spacing: 14
			enabled: root.recentOn
			opacity: root.recentOn ? 1 : 0.45

			Behavior on opacity {
				Anim {}
			}

			RowLayout {
				Layout.fillWidth: true
				spacing: 18

				SwitcherPreview {
					Layout.preferredWidth: 420
					Layout.preferredHeight: 170
					playing: root.active
					active: String(NiriSettings.arg(["recent-windows", "highlight", "active-color"], "#999999ff"))
					urgent: String(NiriSettings.arg(["recent-windows", "highlight", "urgent-color"], "#ff9999ff"))
					padding: Number(NiriSettings.arg(["recent-windows", "highlight", "padding"], 30))
					corner: Number(NiriSettings.arg(["recent-windows", "highlight", "corner-radius"], 0))
					maxScale: Number(NiriSettings.arg(["recent-windows", "previews", "max-scale"], 0.5))
				}

				ColumnLayout {
					Layout.fillWidth: true
					spacing: 10

					RowLayout {
						spacing: 12

						ColorWell {
							label: "Highlight"
							value: String(NiriSettings.arg(["recent-windows", "highlight", "active-color"], "#999999ff"))
							onPicked: css => NiriSettings.set(["recent-windows", "highlight", "active-color"], css, "Switcher highlight", "rw-active")
						}

						ColorWell {
							label: "Urgent"
							value: String(NiriSettings.arg(["recent-windows", "highlight", "urgent-color"], "#ff9999ff"))
							onPicked: css => NiriSettings.set(["recent-windows", "highlight", "urgent-color"], css, "Switcher urgent color", "rw-urgent")
						}
					}

					ValueSlider {
						from: 0
						to: 80
						step: 1
						label: "Room around"
						unit: " px"
						value: Number(NiriSettings.arg(["recent-windows", "highlight", "padding"], 30))
						onMoved: v => NiriSettings.set(["recent-windows", "highlight", "padding"], v, "Highlight padding", "rw-padding")
					}

					ValueSlider {
						from: 0
						to: 60
						step: 1
						label: "Corners"
						unit: " px"
						value: Number(NiriSettings.arg(["recent-windows", "highlight", "corner-radius"], 0))
						onMoved: v => NiriSettings.set(["recent-windows", "highlight", "corner-radius"], v, "Highlight corners", "rw-corner")
					}
				}
			}

			RowLayout {
				Layout.fillWidth: true
				spacing: 12

				ValueSlider {
					from: 0.1
					to: 0.75
					step: 0.05
					label: "Previews at most"
					value: Number(NiriSettings.arg(["recent-windows", "previews", "max-scale"], 0.5))
					format: v => `${Math.round(v * 100)}% big`
					onMoved: v => NiriSettings.set(["recent-windows", "previews", "max-scale"], v, "Preview size", "rw-scale")
				}

				ValueSlider {
					from: 120
					to: 1440
					step: 20
					label: "and"
					value: Number(NiriSettings.arg(["recent-windows", "previews", "max-height"], 480))
					format: v => `${v} px high`
					onMoved: v => NiriSettings.set(["recent-windows", "previews", "max-height"], v, "Preview height", "rw-height")
				}
			}

			TimeLine {
				Layout.fillWidth: true
				maximum: 1000
				start: "Alt+Tab"
				happens: "Shows"
				playing: root.active
				value: Number(NiriSettings.arg(["recent-windows", "open-delay-ms"], 150))
				onMoved: v => NiriSettings.set(["recent-windows", "open-delay-ms"], v, `Switcher after ${v} ms`, "rw-open")
			}

			TimeLine {
				Layout.fillWidth: true
				maximum: 3000
				step: 50
				start: "Focused"
				happens: "Counts as used"
				icon: "check"
				playing: root.active
				value: Number(NiriSettings.arg(["recent-windows", "debounce-ms"], 750))
				onMoved: v => NiriSettings.set(["recent-windows", "debounce-ms"], v, `Counted after ${v} ms`, "rw-debounce")
			}

			// the keys that open it
			SectionLabel {
				text: NiriSettings.has(["recent-windows", "binds"]) ? "Its keys" : "Its keys – niri's defaults"
			}

			Repeater {
				model: root.switcherBinds

				delegate: RowLayout {
					id: bindRow

					required property var modelData
					required property int index

					Layout.fillWidth: true
					spacing: 12

					KeyCombo {
						Layout.preferredWidth: 180
						key: bindRow.modelData.key
						size: 22
					}

					Chip {
						text: bindRow.modelData.action === "next-window" ? "Next" : "Back"
						icon: bindRow.modelData.action === "next-window" ? "arrow_right" : "arrow_left"
						onClicked: root.writeBinds(root.switcherBinds.map((b, i) => i === bindRow.index ? Object.assign({}, b, { action: b.action === "next-window" ? "previous-window" : "next-window" }) : b), "Switcher key changed")
					}

					Chip {
						text: "Same app only"
						icon: "application_outline"
						selected: bindRow.modelData.props.filter === "app-id"
						onClicked: {
							const props = Object.assign({}, bindRow.modelData.props);
							if (props.filter) delete props.filter;
							else props.filter = "app-id";
							root.writeBinds(root.switcherBinds.map((b, i) => i === bindRow.index ? Object.assign({}, b, { props: props }) : b), "Switcher key changed");
						}
					}

					Segmented {
						Layout.preferredWidth: 300
						implicitHeight: 30
						options: [{ value: "", label: "Any" }, { value: "all", label: "All" }, { value: "output", label: "Monitor" }, { value: "workspace", label: "Workspace" }]
						current: String(bindRow.modelData.props.scope ?? "")
						onSelected: value => {
							const props = Object.assign({}, bindRow.modelData.props);
							if (value === "") delete props.scope;
							else props.scope = value;
							root.writeBinds(root.switcherBinds.map((b, i) => i === bindRow.index ? Object.assign({}, b, { props: props }) : b), "Switcher scope changed");
						}
					}

					Item {
						Layout.fillWidth: true
					}

					IconButton {
						icon: "close"
						implicitWidth: 28
						implicitHeight: 28
						iconSize: 14
						onClicked: root.writeBinds(root.switcherBinds.filter((b, i) => i !== bindRow.index), `${bindRow.modelData.key} no longer switches`)
					}
				}
			}

			Flow {
				Layout.fillWidth: true
				spacing: 6

				Repeater {
					model: root.defaultBinds.filter(d => !root.switcherBinds.some(b => b.key === d.key))

					delegate: Chip {
						required property var modelData

						text: modelData.key
						icon: "plus"
						onClicked: root.writeBinds(root.switcherBinds.concat([modelData]), `${modelData.key} switches windows`)
					}
				}
			}
		}
	}
}
