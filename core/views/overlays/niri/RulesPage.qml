pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "Nodes.js" as Nodes
import "RuleSchema.js" as RuleSchema

// Window rules and layer rules: on the left in the order niri reads them
// (a later rule wins – drag them by the grip), on the right the picked one.
// The open windows above can be dropped on a rule, or on "New rule".
Item {
	id: root

	property bool active: false
	property string kind: "window"
	property int picked: 0

	readonly property string nodeName: root.kind === "layer" ? "layer-rule" : "window-rule"
	readonly property var rules: NiriSettings.items(root.nodeName)
	readonly property var rule: root.rules[root.picked] ?? null
	readonly property var setupRules: (NiriSettings.profileRules || []).filter(n => n.name === root.nodeName)
	readonly property var surfaces: root.kind === "layer"
		? (NiriSettings.live.layers || []).map(l => ({ namespace: l[0], layer: l[1], appId: l[0], title: l[1] })).filter(s => s.namespace !== "")
		: (NiriSettings.live.windows || []).filter((w, i, all) => all.findIndex(o => o.appId === w.appId) === i)

	onActiveChanged: if (root.active) NiriSettings.refreshLive()

	function reveal(anchor) {
		root.kind = anchor === "layer-rules" ? "layer" : "window";
	}

	function write(list, note) {
		NiriSettings.setItems(root.nodeName, list, note, "");
	}

	function update(rule) {
		const list = root.rules.slice();
		list[root.picked] = rule;
		NiriSettings.setItems(root.nodeName, list, "Rule changed", `${root.nodeName}-${root.picked}`);
	}

	function create(surface) {
		const rule = Nodes.make(root.nodeName, [], {}, []);
		if (surface) {
			const key = root.kind === "layer" ? "namespace" : "app-id";
			const value = String(root.kind === "layer" ? surface.namespace : surface.appId);
			rule.children.push(Nodes.make("match", [], { [key]: `^${value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}$` }));
			rule.comment = [RuleSchema.nice(value)];
		}
		root.write(root.rules.concat([rule]), surface ? `Rule for ${RuleSchema.nice(root.kind === "layer" ? surface.namespace : surface.appId)}` : "New rule");
		root.picked = root.rules.length;
	}

	function addTo(index, surface) {
		const list = root.rules.slice();
		const rule = Nodes.clone(list[index]);
		const key = root.kind === "layer" ? "namespace" : "app-id";
		const value = String(root.kind === "layer" ? surface.namespace : surface.appId);
		rule.children = (rule.children || []).concat([Nodes.make("match", [], { [key]: `^${value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}$` })]);
		list[index] = rule;
		root.write(list, `${RuleSchema.nice(value)} added to the rule`);
		root.picked = index;
	}

	ColumnLayout {
		anchors.fill: parent
		anchors.margins: 30
		spacing: 14

		RowLayout {
			Layout.fillWidth: true
			spacing: 16

			ColumnLayout {
				Layout.fillWidth: true
				spacing: 4

				StyledText {
					text: root.kind === "layer" ? "Layer rules" : "Window rules"
					font.pixelSize: 26
					font.weight: Font.Bold
				}

				StyledText {
					Layout.fillWidth: true
					text: root.kind === "layer" ? "For bars, notifications and the shell's own surfaces." : "Per app: where it opens, how big, how it looks. Rules lower in the list win."
					tone: Theme.textMuted
				}
			}

			Segmented {
				Layout.preferredWidth: 300
				options: [{ value: "window", label: "Windows", icon: "application_outline" }, { value: "layer", label: "Layers", icon: "layers_outline" }]
				current: root.kind
				onSelected: value => {
					root.kind = value;
					root.picked = 0;
				}
			}
		}

		// what is open now: drag it onto a rule
		RowLayout {
			Layout.fillWidth: true
			spacing: 10

			StyledText {
				text: root.kind === "layer" ? "Open now" : "Open apps"
				tone: Theme.textSubtle
				font.pixelSize: Theme.size.small
				font.weight: Font.DemiBold
			}

			Flickable {
				Layout.fillWidth: true
				Layout.preferredHeight: 36
				contentWidth: tokens.implicitWidth
				clip: true
				boundsBehavior: Flickable.StopAtBounds
				interactive: contentWidth > width

				Row {
					id: tokens

					spacing: 6

					Repeater {
						model: root.surfaces

						delegate: DragToken {
							required property var modelData

							text: root.kind === "layer" ? modelData.namespace : RuleSchema.nice(modelData.appId)
							icon: root.kind === "layer" ? "layers_outline" : "application_outline"
							dragKey: root.kind === "layer" ? "niri-layer" : "niri-window"
							payload: modelData
							onClicked: root.create(modelData)
						}
					}
				}
			}

			IconButton {
				icon: "refresh"
				variant: "tonal"
				onClicked: NiriSettings.refreshLive()
			}
		}

		RowLayout {
			Layout.fillWidth: true
			Layout.fillHeight: true
			spacing: 20

			// ── the rules ──────────────────────────────────────────────
			ColumnLayout {
				Layout.preferredWidth: Math.max(320, root.width * 0.38)
				Layout.maximumWidth: Math.max(320, root.width * 0.38)
				Layout.fillWidth: false
				Layout.fillHeight: true
				spacing: 10

				Flickable {
					Layout.fillWidth: true
					Layout.fillHeight: true
					contentHeight: listColumn.implicitHeight
					clip: true
					boundsBehavior: Flickable.StopAtBounds
					ScrollBar.vertical: ThinScrollBar {}

					ColumnLayout {
						id: listColumn

						width: parent.width - 10
						spacing: 10

						DragList {
							Layout.fillWidth: true
							items: root.rules
							onReordered: order => {
								const pickedRule = root.picked;
								root.write(order.map(i => root.rules[i]), "Rules reordered");
								root.picked = order.indexOf(pickedRule);
							}

							cell: Clickable {
								id: card

								property var modelData: null
								property int index: 0
								property Item dragSource: null
								readonly property bool isPicked: root.picked === card.index
								readonly property bool off: !!card.modelData?.disabled

								implicitHeight: 70
								radius: Theme.radius.large
								pressedScale: 0.98
								color: card.isPicked ? Theme.primaryContainer : (card.hovered ? Theme.layer2 : Theme.layer1)
								border.width: card.isPicked || drop.containsDrag ? 1.5 : 0
								border.color: Theme.primary
								opacity: card.off ? 0.55 : 1
								onClicked: root.picked = card.index

								DropArea {
									id: drop

									anchors.fill: parent
									keys: [root.kind === "layer" ? "niri-layer" : "niri-window"]
									onDropped: event => root.addTo(card.index, event.source.payload)
								}

								RowLayout {
									anchors.fill: parent
									anchors.leftMargin: 8
									anchors.rightMargin: 10
									spacing: 8

									DragGrip {
										source: card.dragSource
									}

									StyledText {
										text: card.index + 1
										tabular: true
										tone: Theme.textFaint
										font.pixelSize: Theme.size.small
									}

									ColumnLayout {
										Layout.fillWidth: true
										spacing: 2

										StyledText {
											Layout.fillWidth: true
											text: (card.modelData?.comment ?? []).join(" ") || RuleSchema.who(card.modelData ?? {}, root.kind)
											font.weight: Font.DemiBold
										}

										StyledText {
											Layout.fillWidth: true
											text: `${(card.modelData?.comment ?? []).length ? RuleSchema.who(card.modelData ?? {}, root.kind) + " · " : ""}${RuleSchema.what(card.modelData ?? {}, root.kind)}`
											tone: Theme.textSubtle
											font.pixelSize: Theme.size.small
										}
									}

									Toggle {
										checked: !card.off
										onToggled: on => {
											const list = root.rules.slice();
											const rule = Nodes.clone(list[card.index]);
											if (on) delete rule.disabled;
											else rule.disabled = true;
											list[card.index] = rule;
											root.write(list, `Rule ${on ? "on" : "off"}`);
										}
									}

									IconButton {
										implicitWidth: 28
										implicitHeight: 28
										iconSize: 14
										icon: "delete_outline"
										iconColor: Theme.danger
										opacity: card.hovered ? 1 : 0
										onClicked: {
											root.write(root.rules.filter((r, i) => i !== card.index), "Rule deleted");
											root.picked = Math.max(0, Math.min(root.picked, root.rules.length - 2));
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

						// new rule: drop an app here or click
						DropArea {
							Layout.fillWidth: true
							implicitHeight: 56
							keys: [root.kind === "layer" ? "niri-layer" : "niri-window"]
							onDropped: event => root.create(event.source.payload)

							Clickable {
								anchors.fill: parent
								radius: Theme.radius.large
								color: parent.containsDrag ? Theme.primaryContainer : "transparent"
								border.width: 1.5
								border.color: parent.containsDrag ? Theme.primary : Theme.textFaint
								onClicked: root.create(null)

								RowLayout {
									anchors.centerIn: parent
									spacing: 8

									Glyph {
										icon: "plus"
										size: 16
										color: Theme.primary
									}

									StyledText {
										text: "New rule – or drop an app here"
										tone: Theme.textMuted
									}
								}
							}
						}

						// rules that come with the display setup
						ColumnLayout {
							Layout.fillWidth: true
							visible: root.setupRules.length > 0
							spacing: 6

							SectionLabel {
								Layout.topMargin: 10
								text: `From the setup “${NiriSettings.profile}” – change them by saving the setup`
							}

							Repeater {
								model: root.setupRules

								delegate: Rectangle {
									required property var modelData

									Layout.fillWidth: true
									implicitHeight: 52
									radius: Theme.radius.large
									color: Theme.layer1
									opacity: 0.75

									ColumnLayout {
										anchors.fill: parent
										anchors.leftMargin: 14
										anchors.rightMargin: 14
										spacing: 2

										StyledText {
											Layout.fillWidth: true
											text: RuleSchema.who(modelData, root.kind)
											font.weight: Font.Medium
										}

										StyledText {
											Layout.fillWidth: true
											text: RuleSchema.what(modelData, root.kind)
											tone: Theme.textSubtle
											font.pixelSize: Theme.size.small
										}
									}
								}
							}
						}
					}
				}
			}

			// ── the picked rule ────────────────────────────────────────
			Rectangle {
				Layout.fillWidth: true
				Layout.fillHeight: true
				radius: Theme.radius.huge
				color: Theme.layer1

				Flickable {
					anchors.fill: parent
					anchors.margins: 20
					contentHeight: editor.implicitHeight
					clip: true
					boundsBehavior: Flickable.StopAtBounds
					visible: !!root.rule
					ScrollBar.vertical: ThinScrollBar {}

					RuleEditor {
						id: editor

						width: parent.width - 10
						kind: root.kind
						rule: root.rule
						onChanged: rule => root.update(rule)
					}
				}

				EmptyState {
					anchors.centerIn: parent
					visible: !root.rule
					icon: root.kind === "layer" ? "layers_outline" : "application_cog_outline"
					title: "No rules yet"
					subtitle: "Drop an open app on “New rule”"
				}
			}
		}
	}
}
