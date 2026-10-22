pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "Nodes.js" as Nodes

// Named workspaces: they are always there, even empty, in the order written
// here (drag them), on the monitor you pick, and can have a layout of their
// own. Window rules send apps to them (Window rules → On workspace).
SettingsPage {
	id: root

	title: "Workspaces"
	description: "Workspaces with a name stay even when empty – a place for the browser, one for chat. Rules can send apps there."

	property int picked: -1
	readonly property var spaces: NiriSettings.items("workspace")

	function write(list, note) {
		NiriSettings.setItems("workspace", list, note, "");
	}

	function update(index, node, note, key) {
		const list = root.spaces.slice();
		list[index] = node;
		NiriSettings.setItems("workspace", list, note, key ?? "");
	}

	function liveOf(name) {
		return (NiriSettings.live.workspaces || []).find(w => w.name === name) ?? null;
	}

	SettingCard {
		anchor: "workspaces"
		title: "Named workspaces"
		subtitle: root.spaces.length === 0 ? "None yet – niri makes workspaces as you need them" : "Drag to change the order they start in; click one to set it up"
		icon: "view_grid_outline"

		DragList {
			Layout.fillWidth: true
			items: root.spaces
			onReordered: order => {
				root.write(order.map(i => root.spaces[i]), "Workspaces reordered");
				root.picked = order.indexOf(root.picked);
			}

			cell: Rectangle {
				id: space

				property var modelData: null
				property int index: 0
				property Item dragSource: null
				readonly property string name: String(space.modelData?.args?.[0] ?? "")
				readonly property bool open: root.picked === space.index
				readonly property var live: root.liveOf(space.name)
				readonly property string output: String(Nodes.arg(space.modelData, "open-on-output", ""))
				readonly property var layoutNode: Nodes.get(space.modelData, "layout")

				implicitHeight: head.implicitHeight + 20 + (space.open ? body.implicitHeight + 16 : 0)
				radius: Theme.radius.large
				color: space.open ? Theme.base : Theme.layer1
				border.width: space.open ? 1.5 : 1
				border.color: space.open ? Theme.primary : Theme.outline
				clip: true

				Behavior on implicitHeight {
					SpatialAnim {
						duration: Motion.medium
					}
				}

				RowLayout {
					id: head

					x: 10
					y: 10
					width: parent.width - 20
					spacing: 10

					DragGrip {
						source: space.dragSource
					}

					// a little workspace with its name
					Rectangle {
						Layout.preferredWidth: 46
						Layout.preferredHeight: 30
						radius: 6
						color: space.live?.active ? Theme.primary : Theme.layer3

						StyledText {
							anchors.centerIn: parent
							text: space.name.slice(0, 2).toUpperCase()
							tone: space.live?.active ? Theme.onPrimary : Theme.text
							font.weight: Font.Bold
							font.pixelSize: Theme.size.small
						}
					}

					TextInput {
						id: nameInput

						Layout.fillWidth: true
						text: space.name
						color: Theme.text
						font.family: Theme.fontFamily
						font.pixelSize: Theme.size.title
						font.weight: Font.DemiBold
						selectByMouse: true
						onEditingFinished: {
							const next = text.trim();
							if (next !== "" && next !== space.name) root.update(space.index, Object.assign({}, space.modelData, { args: [next] }), `Workspace renamed to ${next}`);
						}
					}

					Chip {
						text: space.output !== "" ? space.output : "Any monitor"
						icon: "monitor"
						selected: space.output !== ""
						onClicked: root.picked = space.open ? -1 : space.index
					}

					StyledText {
						text: space.live ? `on ${space.live.output}` : "not there yet"
						tone: space.live ? Theme.success : Theme.textSubtle
						font.pixelSize: Theme.size.small
					}

					IconButton {
						icon: space.open ? "chevron_up" : "chevron_down"
						implicitWidth: 30
						implicitHeight: 30
						onClicked: root.picked = space.open ? -1 : space.index
					}

					IconButton {
						icon: "delete_outline"
						iconColor: Theme.danger
						implicitWidth: 30
						implicitHeight: 30
						onClicked: {
							root.write(root.spaces.filter((s, i) => i !== space.index), `Workspace ${space.name} removed`);
							root.picked = -1;
						}
					}
				}

				ColumnLayout {
					id: body

					x: 20
					y: head.y + head.implicitHeight + 14
					width: parent.width - 40
					spacing: 12
					opacity: space.open ? 1 : 0

					Behavior on opacity {
						Anim {}
					}

					RowLayout {
						Layout.fillWidth: true
						spacing: 16

						MonitorPicker {
							Layout.preferredWidth: 280
							Layout.preferredHeight: 100
							picked: space.output
							onChosen: name => root.update(space.index, name === "" ? Nodes.without(space.modelData, "open-on-output") : Nodes.withArg(space.modelData, "open-on-output", name), name === "" ? `${space.name} on any monitor` : `${space.name} opens on ${name}`)
						}

						StyledText {
							Layout.fillWidth: true
							text: "The monitor it opens on. Click the picked one again to let niri choose."
							tone: Theme.textSubtle
							font.pixelSize: Theme.size.small
							wrapMode: Text.WordWrap
						}
					}

					SectionLabel {
						text: "Layout on this workspace only"
					}

					RowLayout {
						Layout.fillWidth: true
						spacing: 12

						StyledText {
							Layout.preferredWidth: 130
							text: "Gaps"
							tone: Theme.textMuted
						}

						ValueSlider {
							from: 0
							to: 64
							step: 1
							unit: " px"
							opacity: Nodes.has(space.layoutNode, "gaps") ? 1 : 0.55
							value: Number(Nodes.arg(space.layoutNode, "gaps", NiriSettings.arg(["layout", "gaps"], 16)))
							onMoved: v => root.update(space.index, Nodes.withChild(space.modelData, Nodes.withArg(space.layoutNode ?? Nodes.make("layout", [], {}, []), "gaps", v)), `Gaps on ${space.name}`, `ws-gaps-${space.index}`)
						}

						ResetPill {
							shown: Nodes.has(space.layoutNode, "gaps")
							onClicked: root.update(space.index, Nodes.withChild(space.modelData, Nodes.without(space.layoutNode, "gaps")), "Gaps like everywhere")
						}
					}

					RowLayout {
						Layout.fillWidth: true
						spacing: 12

						StyledText {
							Layout.preferredWidth: 130
							text: "New windows"
							tone: Theme.textMuted
						}

						Flow {
							Layout.fillWidth: true
							spacing: 6

							Repeater {
								model: [0.25, 1 / 3, 0.5, 2 / 3, 1]

								delegate: Chip {
									required property real modelData
									readonly property var size: Nodes.size(Nodes.get(space.layoutNode, "default-column-width"))

									text: Nodes.fraction(modelData)
									selected: !!size && Math.abs(size.value - modelData) < 0.002
									onClicked: root.update(space.index, Nodes.withChild(space.modelData, Nodes.withChild(space.layoutNode ?? Nodes.make("layout", [], {}, []), Nodes.sizeNode("default-column-width", { kind: "proportion", value: modelData }))), `New windows on ${space.name}: ${Nodes.fraction(modelData)}`)
								}
							}
						}
					}

					RowLayout {
						Layout.fillWidth: true
						spacing: 12

						StyledText {
							Layout.preferredWidth: 130
							text: "Columns show"
							tone: Theme.textMuted
						}

						Segmented {
							Layout.preferredWidth: 320
							options: [{ value: "", label: "Like everywhere" }, { value: "normal", label: "Stacked" }, { value: "tabbed", label: "Tabbed" }]
							current: String(Nodes.arg(space.layoutNode, "default-column-display", ""))
							onSelected: value => root.update(space.index, Nodes.withChild(space.modelData, value === "" ? Nodes.without(space.layoutNode, "default-column-display") : Nodes.withArg(space.layoutNode ?? Nodes.make("layout", [], {}, []), "default-column-display", value)), `Columns on ${space.name}`)
						}
					}

					FlagRow {
						title: "Center a lone column"
						checked: Nodes.arg(space.layoutNode, "always-center-single-column", NiriSettings.flag(["layout", "always-center-single-column"])) !== false && (Nodes.has(space.layoutNode, "always-center-single-column") || NiriSettings.flag(["layout", "always-center-single-column"]))
						onToggled: on => root.update(space.index, Nodes.withChild(space.modelData, Nodes.withArg(space.layoutNode ?? Nodes.make("layout", [], {}, []), "always-center-single-column", on)), `Centering on ${space.name}`)
					}

					Item {
						Layout.preferredHeight: 4
					}
				}
			}
		}

		// a new one
		RowLayout {
			Layout.fillWidth: true
			spacing: 10

			Field {
				id: newName

				Layout.fillWidth: true
				icon: "plus"
				placeholder: "Name a new workspace – browser, chat, music"
				onAccepted: create()

				function create() {
					const name = newName.text.trim();
					if (name === "" || root.spaces.some(s => String(s.args[0]) === name)) return;
					root.write(root.spaces.concat([Nodes.make("workspace", [name])]), `Workspace ${name} added`);
					newName.text = "";
				}
			}

			TextButton {
				text: "Add"
				icon: "plus"
				variant: "filled"
				enabled: newName.text.trim() !== ""
				onActivated: newName.create()
			}
		}

		Flow {
			Layout.fillWidth: true
			spacing: 6
			visible: root.spaces.length === 0

			Repeater {
				model: ["browser", "chat", "code", "music", "mail"]

				delegate: Chip {
					required property string modelData

					text: modelData
					icon: "plus"
					onClicked: root.write(root.spaces.concat([Nodes.make("workspace", [modelData])]), `Workspace ${modelData} added`)
				}
			}
		}
	}
}
