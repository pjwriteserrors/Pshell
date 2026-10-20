pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "Nodes.js" as Nodes

// Borders & shadows: what niri draws around windows – focus ring, border,
// shadow, the tab indicator of tabbed columns, the insert hint while moving
// a window, and the corners every window gets.
SettingsPage {
	id: root

	title: "Borders & shadows"
	description: "What niri draws around your windows. The workspace on the right shows it as you change it – click a window to move the focus."
	asideWidth: Math.min(560, Math.max(380, width * 0.42))

	readonly property var ring: NiriSettings.node(["layout", "focus-ring"])
	readonly property var border: NiriSettings.node(["layout", "border"])
	readonly property var shadow: NiriSettings.node(["layout", "shadow"])
	readonly property var tabs: NiriSettings.node(["layout", "tab-indicator"])
	readonly property var hint: NiriSettings.node(["layout", "insert-hint"])
	readonly property bool ringOn: Nodes.on(root.ring, true)
	readonly property bool borderOn: Nodes.on(root.border, false)
	readonly property bool shadowOn: Nodes.on(root.shadow, false)
	readonly property bool tabsOn: Nodes.on(root.tabs, true)
	readonly property bool hintOn: Nodes.on(root.hint, true)

	readonly property var monitor: {
		const outputs = NiriSettings.live.outputs || [];
		return outputs.find(o => o.name === Host.primaryOutput && o.logical) ?? outputs.find(o => o.logical) ?? null;
	}

	function put(name, section, note, key) {
		NiriSettings.setChildren(["layout", name], section.children || [], note, key ?? name);
	}

	// the rule that matches every window: where the corners live
	function isGlobal(rule) {
		return rule.name === "window-rule" && !rule.disabled && !(rule.children || []).some(c => c.name === "match" || c.name === "exclude");
	}

	readonly property var cornerRule: {
		const rules = NiriSettings.nodes.filter(root.isGlobal);
		return rules.slice().reverse().find(rule => Nodes.has(rule, "geometry-corner-radius")) ?? rules[0] ?? null;
	}
	readonly property real cornerRadius: Number(Nodes.arg(root.cornerRule, "geometry-corner-radius", 0))
	readonly property bool clipped: Nodes.flag(root.cornerRule, "clip-to-geometry")

	function editCorners(note, key, change) {
		NiriSettings.edit(note, key, draft => {
			const globals = draft.map((node, i) => ({ node: node, i: i })).filter(entry => root.isGlobal(entry.node));
			let target = globals.slice().reverse().find(entry => Nodes.has(entry.node, "geometry-corner-radius")) ?? globals[0];
			if (!target) {
				const rule = { name: "window-rule", args: [], props: {}, children: [], comment: ["corners of every window"] };
				const first = draft.findIndex(node => node.name === "window-rule");
				if (first >= 0) draft.splice(first, 0, rule);
				else NiriSettings.insertOrdered(draft, rule);
				target = { node: rule };
			}
			const next = change(target.node);
			target.node.children = next.children;
		});
	}

	aside: ColumnLayout {
		anchors.fill: parent
		spacing: 12

		Rectangle {
			Layout.fillWidth: true
			Layout.preferredHeight: preview.implicitHeight + 32
			radius: Theme.radius.huge
			color: Theme.layer1

			LayoutPreview {
				id: preview

				anchors.fill: parent
				anchors.margins: 16
				implicitHeight: width * logicalHeight / logicalWidth
				// closer than the real screen: thin borders stay visible
				logicalWidth: 1000
				logicalHeight: 1000 * (root.monitor?.logical ? root.monitor.logical.height / root.monitor.logical.width : 9 / 16)
				gaps: Math.max(Number(NiriSettings.arg(["layout", "gaps"], 16)), 22)
				struts: ({ left: 10, right: 10, top: 12, bottom: 12 })
				centerMode: "always"
				cornerRadius: root.cornerRadius
				columns: [{ width: 0.3, tabs: 1 }, { width: 0.4, tabs: 3 }, { width: 0.3, tabs: 1 }]
				focused: 1
				ring: root.ring
				border: root.border
				shadow: root.shadow
				tabIndicator: root.tabs
				insertHint: root.hint
				showInsertHint: hintHover.hovered
			}
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 8

			Glyph {
				icon: "information_outline"
				size: 15
				color: Theme.textSubtle
			}

			StyledText {
				Layout.fillWidth: true
				text: "The middle column is tabbed, so its tab indicator shows. Wider gaps than yours, so every border stays visible."
				tone: Theme.textSubtle
				font.pixelSize: Theme.size.small
				wrapMode: Text.WordWrap
			}
		}

		Item {
			Layout.fillHeight: true
		}
	}

	// ── focus ring ─────────────────────────────────────────────────────────
	SettingCard {
		anchor: "focus-ring"
		title: "Focus ring"
		subtitle: "Drawn around the active window only, outside of it – windows keep their size"
		icon: "selection_ellipse"
		modified: !!root.ring && NiriSettings.kids(["layout", "focus-ring"]).length > 0
		onReset: NiriSettings.reset(["layout", "focus-ring"])
		trailing: Toggle {
			checked: root.ringOn
			onToggled: on => NiriSettings.setSection(["layout", "focus-ring"], on, `Focus ring ${on ? "on" : "off"}`)
		}

		RingEditor {
			Layout.fillWidth: true
			enabled: root.ringOn
			opacity: root.ringOn ? 1 : 0.45
			section: root.ring
			defaultActive: "#7fc8ff"
			onChanged: s => root.put("focus-ring", s, "Focus ring changed")

			Behavior on opacity {
				Anim {}
			}
		}
	}

	// ── border ─────────────────────────────────────────────────────────────
	SettingCard {
		anchor: "border"
		title: "Border"
		subtitle: "Drawn around every window; windows shrink to make room for it"
		icon: "border_all_variant"
		modified: !!root.border && NiriSettings.kids(["layout", "border"]).length > 0
		onReset: NiriSettings.reset(["layout", "border"])
		trailing: Toggle {
			checked: root.borderOn
			onToggled: on => NiriSettings.setSection(["layout", "border"], on, `Border ${on ? "on" : "off"}`)
		}

		RingEditor {
			Layout.fillWidth: true
			enabled: root.borderOn
			opacity: root.borderOn ? 1 : 0.45
			section: root.border
			defaultActive: "#ffc87f"
			onChanged: s => root.put("border", s, "Border changed")

			Behavior on opacity {
				Anim {}
			}
		}
	}

	// ── shadow ─────────────────────────────────────────────────────────────
	SettingCard {
		anchor: "shadow"
		title: "Shadow"
		subtitle: "Behind every window, like a CSS box-shadow. Grab the shadow below and drag it."
		icon: "box_shadow"
		modified: !!root.shadow && NiriSettings.kids(["layout", "shadow"]).length > 0
		onReset: NiriSettings.reset(["layout", "shadow"])
		trailing: Toggle {
			checked: root.shadowOn
			onToggled: on => NiriSettings.setSection(["layout", "shadow"], on, `Shadow ${on ? "on" : "off"}`)
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 20
			enabled: root.shadowOn
			opacity: root.shadowOn ? 1 : 0.45

			Behavior on opacity {
				Anim {}
			}

			ShadowPad {
				Layout.preferredWidth: 260
				Layout.preferredHeight: 190
				offsetX: Number(Nodes.prop(root.shadow, "offset", "x", 0))
				offsetY: Number(Nodes.prop(root.shadow, "offset", "y", 5))
				softness: Number(Nodes.arg(root.shadow, "softness", 30))
				spread: Number(Nodes.arg(root.shadow, "spread", 5))
				color: String(Nodes.arg(root.shadow, "color", "#00000070"))
				radius: Math.max(4, root.cornerRadius) * 1.4
				onMoved: (x, y) => root.put("shadow", Nodes.withNode(root.shadow, "offset", [], { x: x, y: y }), "Shadow moved", "shadow-offset")
			}

			ColumnLayout {
				Layout.fillWidth: true
				spacing: 12

				ValueSlider {
					from: 0
					to: 100
					step: 1
					unit: " px"
					label: "Softness"
					value: Number(Nodes.arg(root.shadow, "softness", 30))
					onMoved: v => root.put("shadow", Nodes.withArg(root.shadow, "softness", v), "Shadow softness", "shadow-softness")
				}

				ValueSlider {
					from: -30
					to: 60
					step: 1
					unit: " px"
					label: "Spread"
					value: Number(Nodes.arg(root.shadow, "spread", 5))
					onMoved: v => root.put("shadow", Nodes.withArg(root.shadow, "spread", v), "Shadow spread", "shadow-spread")
				}

				RowLayout {
					spacing: 16

					ColorWell {
						label: "Color"
						value: String(Nodes.arg(root.shadow, "color", "#00000070"))
						onPicked: css => root.put("shadow", Nodes.withArg(root.shadow, "color", css), "Shadow color", "shadow-color")
					}

					ColorWell {
						label: Nodes.has(root.shadow, "inactive-color") ? "Inactive windows" : "Inactive: fainter"
						value: String(Nodes.arg(root.shadow, "inactive-color", "#00000054"))
						opacity: Nodes.has(root.shadow, "inactive-color") ? 1 : 0.6
						onPicked: css => root.put("shadow", Nodes.withArg(root.shadow, "inactive-color", css), "Inactive shadow color", "shadow-inactive")
					}

					ResetPill {
						shown: Nodes.has(root.shadow, "inactive-color")
						text: "Fainter"
						onClicked: root.put("shadow", Nodes.without(root.shadow, "inactive-color"), "Inactive shadow follows")
					}
				}
			}
		}

		FlagRow {
			title: "Draw behind the window too"
			subtitle: "Fixes shadow inside rounded corners that apps draw themselves; not needed with corners set below"
			enabled: root.shadowOn
			checked: Nodes.arg(root.shadow, "draw-behind-window", false) === true
			onToggled: on => root.put("shadow", Nodes.withBool(root.shadow, "draw-behind-window", on, false), `Shadow behind windows ${on ? "on" : "off"}`)
		}
	}

	// ── corners ────────────────────────────────────────────────────────────
	SettingCard {
		anchor: "corners"
		title: "Window corners"
		subtitle: "Pull the corner. Borders, rings and shadows follow it; the shell's panels round off the same way."
		icon: "rounded_corner"
		modified: root.cornerRadius > 0 || root.clipped
		onReset: root.editCorners("Square corners", "", rule => Nodes.without(Nodes.without(rule, "geometry-corner-radius"), "clip-to-geometry"))

		RowLayout {
			Layout.fillWidth: true
			spacing: 22

			CornerDrag {
				Layout.preferredWidth: 240
				Layout.preferredHeight: 170
				radius: root.cornerRadius
				clipped: root.clipped
				onMoved: r => root.editCorners(`Corners ${r} px`, "corners", rule => r > 0 ? Nodes.withArg(rule, "geometry-corner-radius", r) : Nodes.without(rule, "geometry-corner-radius"))
			}

			ColumnLayout {
				Layout.fillWidth: true
				spacing: 6

				Flow {
					Layout.fillWidth: true
					spacing: 6

					Repeater {
						model: [0, 6, 12, 18, 24]

						delegate: Chip {
							required property int modelData

							text: modelData === 0 ? "Square" : `${modelData} px`
							selected: Math.round(root.cornerRadius) === modelData
							onClicked: root.editCorners(`Corners ${modelData} px`, "", rule => modelData > 0 ? Nodes.withArg(rule, "geometry-corner-radius", modelData) : Nodes.without(rule, "geometry-corner-radius"))
						}
					}
				}

				FlagRow {
					title: "Cut windows to the corners"
					subtitle: "Without it, what an app draws still shows square (clip-to-geometry)"
					checked: root.clipped
					onToggled: on => root.editCorners(`Clipping ${on ? "on" : "off"}`, "", rule => Nodes.withBool(rule, "clip-to-geometry", on, false))
				}
			}
		}
	}

	// ── screen frame (the shell's, not niri's) ─────────────────────────────
	SettingCard {
		anchor: "screen-frame"
		visible: Plugins.on("bottom-corners")
		title: "Screen frame"
		icon: "rounded_corner"
		modified: Corners.framed || Corners.edges !== "bottom"
		onReset: {
			Corners.setFrame(0);
			Corners.setEdges("bottom");
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 14

			ValueSlider {
				from: 0
				to: Corners.max
				step: 1
				value: Corners.frame
				icon: "rounded_corner"
				label: "Thickness"
				unit: " px"
				onMoved: value => Corners.setFrame(value)
			}

			Segmented {
				Layout.preferredWidth: 220
				color: Theme.layer2
				options: [
					{ value: "bottom", label: "Bottom" },
					{ value: "all", label: "All edges" }
				]
				current: Corners.edges
				onSelected: value => Corners.setEdges(value)
			}
		}
	}

	// ── tab indicator ──────────────────────────────────────────────────────
	SettingCard {
		anchor: "tab-indicator"
		title: "Tab indicator"
		subtitle: "The bar beside a tabbed column, one piece per tab. Click a side of the column to move it."
		icon: "tab"
		modified: !!root.tabs && NiriSettings.kids(["layout", "tab-indicator"]).length > 0
		onReset: NiriSettings.reset(["layout", "tab-indicator"])
		trailing: Toggle {
			checked: root.tabsOn
			onToggled: on => NiriSettings.setSection(["layout", "tab-indicator"], on, `Tab indicator ${on ? "on" : "off"}`)
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 20
			enabled: root.tabsOn
			opacity: root.tabsOn ? 1 : 0.45

			Behavior on opacity {
				Anim {}
			}

			SidePicker {
				Layout.preferredWidth: 210
				Layout.preferredHeight: 180
				side: String(Nodes.arg(root.tabs, "position", "left"))
				proportion: Number(Nodes.prop(root.tabs, "length", "total-proportion", 0.5))
				thickness: Number(Nodes.arg(root.tabs, "width", 4))
				gap: Number(Nodes.arg(root.tabs, "gap", 5))
				onPicked: side => root.put("tab-indicator", Nodes.withArg(root.tabs, "position", side), `Tabs on the ${side}`)
			}

			ColumnLayout {
				Layout.fillWidth: true
				spacing: 10

				ValueSlider {
					from: 0.1
					to: 1
					step: 0.05
					label: "Length"
					value: Number(Nodes.prop(root.tabs, "length", "total-proportion", 0.5))
					format: v => `${Math.round(v * 100)}%`
					onMoved: v => root.put("tab-indicator", Nodes.withNode(root.tabs, "length", [], { "total-proportion": v }), "Tab length", "tab-length")
				}

				ValueSlider {
					from: 1
					to: 16
					step: 1
					unit: " px"
					label: "Thickness"
					value: Number(Nodes.arg(root.tabs, "width", 4))
					onMoved: v => root.put("tab-indicator", Nodes.withArg(root.tabs, "width", v), "Tab thickness", "tab-width")
				}

				ValueSlider {
					from: -16
					to: 24
					step: 1
					unit: " px"
					label: "Gap to the window"
					value: Number(Nodes.arg(root.tabs, "gap", 5))
					onMoved: v => root.put("tab-indicator", Nodes.withArg(root.tabs, "gap", v), "Tab gap", "tab-gap")
				}

				RowLayout {
					spacing: 14

					StyledText {
						text: "Between tabs"
						tone: Theme.textMuted
						font.pixelSize: Theme.size.label
					}

					NumberScrub {
						value: Number(Nodes.arg(root.tabs, "gaps-between-tabs", 0))
						to: 24
						unit: " px"
						onMoved: v => root.put("tab-indicator", Nodes.withArg(root.tabs, "gaps-between-tabs", v), "Space between tabs", "tab-between")
					}

					StyledText {
						text: "Corners"
						tone: Theme.textMuted
						font.pixelSize: Theme.size.label
					}

					NumberScrub {
						value: Number(Nodes.arg(root.tabs, "corner-radius", 0))
						to: 16
						unit: " px"
						onMoved: v => root.put("tab-indicator", Nodes.withArg(root.tabs, "corner-radius", v), "Tab corners", "tab-corners")
					}
				}
			}
		}

		FlagRow {
			title: "Hide with a single tab"
			subtitle: "A tabbed column with one window shows no indicator"
			enabled: root.tabsOn
			checked: Nodes.flag(root.tabs, "hide-when-single-tab")
			onToggled: on => root.put("tab-indicator", Nodes.withFlag(root.tabs, "hide-when-single-tab", on), `Single tab ${on ? "hidden" : "shown"}`)
		}

		FlagRow {
			title: "Inside the column"
			subtitle: "The indicator takes room in the column instead of lying over the neighbour"
			enabled: root.tabsOn
			checked: Nodes.flag(root.tabs, "place-within-column")
			onToggled: on => root.put("tab-indicator", Nodes.withFlag(root.tabs, "place-within-column", on), `Tabs ${on ? "inside" : "outside"} the column`)
		}

		ColumnLayout {
			Layout.fillWidth: true
			spacing: 10
			enabled: root.tabsOn

			SectionLabel {
				text: "Colors – unset ones follow the border or the focus ring"
			}

			PaintRow {
				Layout.fillWidth: true
				section: root.tabs
				kind: "active"
				label: "Active"
				fallback: root.borderOn ? String(Nodes.arg(root.border, "active-color", "#ffc87f")) : String(Nodes.arg(root.ring, "active-color", "#7fc8ff"))
				onChanged: s => root.put("tab-indicator", s, "Tab colors")
			}

			PaintRow {
				Layout.fillWidth: true
				section: root.tabs
				kind: "inactive"
				label: "Inactive"
				fallback: root.borderOn ? String(Nodes.arg(root.border, "inactive-color", "#505050")) : String(Nodes.arg(root.ring, "inactive-color", "#505050"))
				onChanged: s => root.put("tab-indicator", s, "Tab colors")
			}

			PaintRow {
				Layout.fillWidth: true
				section: root.tabs
				kind: "urgent"
				label: "Urgent"
				fallback: "#9b0000"
				onChanged: s => root.put("tab-indicator", s, "Tab colors")
			}
		}
	}

	// ── insert hint ────────────────────────────────────────────────────────
	SettingCard {
		anchor: "insert-hint"
		title: "Insert hint"
		subtitle: "Where a window you drag around would land – hover here and it shows on the right"
		icon: "arrow_collapse_down"
		modified: !!root.hint && NiriSettings.kids(["layout", "insert-hint"]).length > 0
		onReset: NiriSettings.reset(["layout", "insert-hint"])
		trailing: Toggle {
			checked: root.hintOn
			onToggled: on => NiriSettings.setSection(["layout", "insert-hint"], on, `Insert hint ${on ? "on" : "off"}`)
		}

		HoverHandler {
			id: hintHover
		}

		PaintRow {
			Layout.fillWidth: true
			enabled: root.hintOn
			section: root.hint
			kind: "hint"
			colorName: "color"
			gradientName: "gradient"
			label: "Color"
			fallback: "#ffc87f80"
			onChanged: s => root.put("insert-hint", s, "Insert hint color")
		}
	}
}
