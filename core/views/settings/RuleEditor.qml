pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "Nodes.js" as Nodes
import "RuleSchema.js" as RuleSchema

// One rule: who it is for (with the open windows it fits right now) and
// what it does. Drop an open window on "Applies to" to add it; drop a tile
// from the shelf below onto "Does" (or click it) to add what it does.
ColumnLayout {
	id: root

	property string kind: "window"
	property var rule: null

	signal changed(var rule)

	readonly property var kids: root.rule?.children ?? []
	readonly property var matchers: root.kids.filter(c => (c.name === "match" || c.name === "exclude") && !c.disabled)
	readonly property var effects: root.kids.filter(c => c.name !== "match" && c.name !== "exclude")
	readonly property var surfaces: root.kind === "layer"
		? (NiriSettings.live.layers || []).map(l => ({ namespace: l[0], layer: l[1], appId: l[0], title: l[1] }))
		: (NiriSettings.live.windows || [])
	readonly property var fitting: root.rule ? root.surfaces.filter(w => RuleSchema.applies(root.rule, w)) : []

	function replace(index, node) {
		const kids = root.kids.slice();
		if (node === null) kids.splice(index, 1);
		else kids[index] = node;
		root.changed(Object.assign({}, root.rule, { children: kids }));
	}

	function append(node) {
		root.changed(Object.assign({}, root.rule, { children: root.kids.concat([node]) }));
	}

	function addSurface(surface) {
		const key = root.kind === "layer" ? "namespace" : "app-id";
		const value = `^${String(root.kind === "layer" ? surface.namespace : surface.appId).replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}$`;
		if (root.matchers.some(m => m.name === "match" && m.props?.[key] === value)) return;
		root.append(Nodes.make("match", [], { [key]: value }));
	}

	function addEffect(name) {
		if (root.effects.some(e => e.name === name)) return;
		const info = RuleSchema.info(root.kind, name);
		let node;
		switch (info.type) {
		case "size": node = Nodes.sizeNode(name, { kind: "proportion", value: 0.5 }); break;
		case "position": node = Nodes.make(name, [], { x: 32, y: 32, "relative-to": "bottom-right" }); break;
		case "ring": case "shadow": node = Nodes.make(name, [], {}, [Nodes.make("on")]); break;
		case "tabs": case "popups": node = Nodes.make(name, [], {}, []); break;
		case "effect": node = Nodes.make(name, [], {}, [Nodes.make("blur", [true])]); break;
		case "output": node = Nodes.make(name, [((NiriSettings.live.outputs || [])[0]?.name) ?? "DP-1"]); break;
		case "workspace": node = Nodes.make(name, [String(NiriSettings.items("workspace")[0]?.args?.[0] ?? "main")]); break;
		default: node = Nodes.make(name, info.fallback === null ? [] : [info.fallback]);
		}
		root.append(node);
	}

	spacing: 14

	Field {
		Layout.fillWidth: true
		icon: "tag_outline"
		placeholder: "A name for this rule"
		text: (root.rule?.comment ?? []).join(" ")
		onAccepted: root.changed(Object.assign({}, root.rule, { comment: text.trim() === "" ? undefined : [text.trim()] }))
	}

	// ── who ────────────────────────────────────────────────────────────────
	DropArea {
		Layout.fillWidth: true
		implicitHeight: whoBox.implicitHeight
		keys: [root.kind === "layer" ? "niri-layer" : "niri-window"]
		onDropped: drop => root.addSurface(drop.source.payload)

		Rectangle {
			anchors.fill: parent
			anchors.margins: -6
			radius: Theme.radius.large
			color: Qt.alpha(Theme.primary, parent.containsDrag ? 0.12 : 0)
			border.width: parent.containsDrag ? 2 : 0
			border.color: Theme.primary

			Behavior on color {
				ColorAnim {}
			}
		}

		ColumnLayout {
			id: whoBox

			width: parent.width
			spacing: 8

			RowLayout {
				Layout.fillWidth: true

				SectionLabel {
					Layout.fillWidth: true
					text: "Applies to"
				}

				StyledText {
					text: root.matchers.length === 0 ? (root.kind === "layer" ? "every surface" : "every window") : "any Match, but no Except"
					tone: Theme.textSubtle
					font.pixelSize: Theme.size.small
				}
			}

			Repeater {
				// with where each stands among the rule's children
				model: root.matchers.map(m => ({ node: m, at: root.kids.indexOf(m) }))

				delegate: MatcherRow {
					required property var modelData

					kind: root.kind
					node: modelData.node
					onChanged: node => root.replace(modelData.at, node)
					onRemoved: root.replace(modelData.at, null)
				}
			}

			RowLayout {
				spacing: 8

				TextButton {
					text: "Match"
					icon: "plus"
					variant: "tonal"
					onActivated: root.append(Nodes.make("match", [], root.kind === "layer" ? { namespace: "" } : { "app-id": "" }))
				}

				TextButton {
					text: "Except"
					icon: "minus"
					variant: "tonal"
					onActivated: root.append(Nodes.make("exclude", [], root.kind === "layer" ? { namespace: "" } : { "app-id": "" }))
				}

				StyledText {
					Layout.fillWidth: true
					text: root.kind === "layer" ? "or drop a surface from above" : "or drop an open window from above"
					tone: Theme.textSubtle
					font.pixelSize: Theme.size.small
				}
			}

			// what it fits right now
			RowLayout {
				Layout.fillWidth: true
				spacing: 8

				Glyph {
					icon: root.fitting.length > 0 ? "check_circle_outline" : "help_circle_outline"
					size: 15
					color: root.fitting.length > 0 ? Theme.success : Theme.textSubtle
				}

				StyledText {
					Layout.fillWidth: true
					text: root.fitting.length === 0 ? "Fits nothing that is open now" : `Fits ${root.fitting.length} open now: ${root.fitting.slice(0, 6).map(w => root.kind === "layer" ? w.namespace : RuleSchema.nice(w.appId)).filter((v, i, a) => a.indexOf(v) === i).join(", ")}`
					tone: root.fitting.length > 0 ? Theme.text : Theme.textSubtle
					font.pixelSize: Theme.size.small
					elide: Text.ElideRight
				}
			}
		}
	}

	// ── what ───────────────────────────────────────────────────────────────
	DropArea {
		Layout.fillWidth: true
		implicitHeight: whatBox.implicitHeight
		keys: [`niri-prop-${root.kind}`]
		onDropped: drop => root.addEffect(drop.source.payload)

		Rectangle {
			anchors.fill: parent
			anchors.margins: -6
			radius: Theme.radius.large
			color: Qt.alpha(Theme.primary, parent.containsDrag ? 0.12 : 0)
			border.width: parent.containsDrag ? 2 : 0
			border.color: Theme.primary
		}

		ColumnLayout {
			id: whatBox

			width: parent.width
			spacing: 8

			SectionLabel {
				text: "Does"
			}

			Repeater {
				model: root.effects.map(e => ({ node: e, at: root.kids.indexOf(e) }))

				delegate: RuleProperty {
					required property var modelData

					kind: root.kind
					node: modelData.node
					opacity: modelData.node.disabled ? 0.5 : 1
					onChanged: node => root.replace(modelData.at, node)
					onRemoved: root.replace(modelData.at, null)
				}
			}

			Rectangle {
				Layout.fillWidth: true
				visible: root.effects.length === 0
				implicitHeight: 64
				radius: Theme.radius.large
				color: "transparent"
				border.width: 1.5
				border.color: Theme.textFaint

				StyledText {
					anchors.centerIn: parent
					text: "Drop what it should do here"
					tone: Theme.textSubtle
				}
			}
		}
	}

	// ── the shelf of things a rule can do ──────────────────────────────────
	Repeater {
		model: ["Opening", "Size", "Look", "Behaviour"].filter(g => RuleSchema.props(root.kind).some(p => p.group === g))

		delegate: ColumnLayout {
			id: group

			required property string modelData

			Layout.fillWidth: true
			spacing: 6

			StyledText {
				text: group.modelData
				tone: Theme.textSubtle
				font.pixelSize: Theme.size.small
				font.weight: Font.DemiBold
			}

			Flow {
				Layout.fillWidth: true
				spacing: 6

				Repeater {
					model: RuleSchema.props(root.kind).filter(p => p.group === group.modelData && !root.effects.some(e => e.name === p.name))

					delegate: DragToken {
						required property var modelData

						text: modelData.label
						icon: modelData.icon
						dragKey: `niri-prop-${root.kind}`
						payload: modelData.name
						onClicked: root.addEffect(modelData.name)
					}
				}
			}
		}
	}
}
