pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Widgets
import qs.style.theme
import qs.core.services
import qs.style.widgets

// >plugins: everything the shell can do (core/services/Plugins.qml). The
// tabs are on the left, a tab's plugins in the middle as a tree: a plugin
// that needs another one of its tab sits in that one's folder, and plugins
// with a `group` share a folder of that name. The selected one is shown on
// the right with its picture and what it needs. Typing filters, ↑↓ move,
// Enter switches, Tab opens and closes a folder.
ModalWindow {
	id: root

	modalId: "plugins"
	exclusiveKeyboard: true
	onModalOpened: {
		search.text = "";
		root.category = "";
		root.opened = ({});
		root.selected = "";
		search.focusInput();
	}

	// "" shows every tab
	property string category: ""
	// folders that are open: { key: true }
	property var opened: ({})
	// key of the selected row: a plugin's id or a group's "tab/name"
	property string selected: ""
	readonly property string query: search.text.trim().toLowerCase()

	// { tab: [node] }, node: { key, plugin (null for a group), name, tab, children }
	readonly property var tree: {
		const nodes = {};
		const groups = {};
		const tabs = {};
		for (const plugin of Plugins.list) {
			nodes[plugin.id] = { key: plugin.id, plugin: plugin, name: plugin.name, tab: plugin.category, children: [] };
			if (!tabs[plugin.category]) tabs[plugin.category] = [];
		}
		for (const plugin of Plugins.list) {
			const parent = (plugin.requires || []).find(id => nodes[id] && nodes[id].tab === plugin.category);
			if (parent) {
				nodes[parent].children.push(nodes[plugin.id]);
			} else if (plugin.group) {
				const key = `${plugin.category}/${plugin.group}`;
				if (!groups[key]) {
					groups[key] = { key: key, plugin: null, name: plugin.group, tab: plugin.category, children: [] };
					tabs[plugin.category].push(groups[key]);
				}
				groups[key].children.push(nodes[plugin.id]);
			} else {
				tabs[plugin.category].push(nodes[plugin.id]);
			}
		}
		return tabs;
	}

	// the folder a row sits in: { key: key of its folder }
	readonly property var folders: {
		const map = {};
		const walk = node => node.children.forEach(child => {
			map[child.key] = node.key;
			walk(child);
		});
		for (const tab in root.tree) root.tree[tab].forEach(walk);
		return map;
	}

	// what the list shows: { header, name } or { node, depth, folder, open }
	readonly property var rows: {
		const out = [];
		const query = root.query;
		const hit = node => query === "" || `${node.name} ${node.plugin ? node.plugin.id : ""}`.toLowerCase().includes(query);
		const shown = node => hit(node) || node.children.some(shown);
		const walk = (node, depth) => {
			if (!shown(node)) return;
			const folder = node.children.length > 0;
			// a search looks into every folder
			const open = folder && (query !== "" ? node.children.some(shown) : root.opened[node.key] === true);
			out.push({ header: false, node: node, depth: depth, folder: folder, open: open });
			if (open) node.children.forEach(child => walk(child, depth + 1));
		};
		for (const tab of Plugins.categories) {
			if (root.category !== "" && tab !== root.category) continue;
			const before = out.length;
			if (root.category === "") out.push({ header: true, name: tab });
			(root.tree[tab] || []).forEach(node => walk(node, 0));
			if (root.category === "" && out.length === before + 1) out.pop();
		}
		return out;
	}

	readonly property int current: {
		const index = root.rows.findIndex(row => !row.header && row.node.key === root.selected);
		return index >= 0 ? index : root.rows.findIndex(row => !row.header);
	}
	readonly property var currentNode: root.rows[root.current]?.node ?? null

	function plugins(node) {
		const own = node.plugin ? [node.plugin] : [];
		return node.children.reduce((all, child) => all.concat(root.plugins(child)), own);
	}

	function count(list) {
		return `${list.filter(plugin => Plugins.on(plugin.id)).length}/${list.length}`;
	}

	function move(delta) {
		let index = root.current + delta;
		while (index >= 0 && index < root.rows.length && root.rows[index].header) index += delta;
		if (index >= 0 && index < root.rows.length) root.selected = root.rows[index].node.key;
	}

	function fold(key, open) {
		const next = Object.assign({}, root.opened);
		if (open === undefined ? !next[key] : open) next[key] = true;
		else delete next[key];
		root.opened = next;
	}

	function activate() {
		const row = root.rows[root.current];
		if (!row) return;
		if (row.node.plugin) Plugins.toggle(row.node.plugin.id);
		else root.fold(row.node.key);
	}

	// brings a plugin on the screen, wherever it sits
	function reveal(id) {
		const plugin = Plugins.byId[id];
		if (!plugin) return;
		search.text = "";
		if (root.category !== "") root.category = plugin.category;
		const next = Object.assign({}, root.opened);
		for (let key = root.folders[id]; key; key = root.folders[key]) next[key] = true;
		root.opened = next;
		root.selected = id;
	}

	Rectangle {
		anchors.centerIn: parent
		width: Math.min(1240, root.width - 120)
		height: Math.min(900, root.height - 120)
		radius: Theme.radius.huge + 6
		color: Theme.base

		MouseArea {
			anchors.fill: parent
			acceptedButtons: Qt.AllButtons
		}

		RowLayout {
			anchors.fill: parent
			anchors.margins: 22
			spacing: 18

			// tabs
			ColumnLayout {
				Layout.preferredWidth: 210
				Layout.fillHeight: true
				spacing: 4

				RowLayout {
					Layout.fillWidth: true
					Layout.bottomMargin: 14
					spacing: 12

					Rectangle {
						Layout.preferredWidth: 42
						Layout.preferredHeight: 42
						radius: Theme.radius.large
						color: Theme.primaryContainer

						Glyph {
							anchors.centerIn: parent
							icon: "puzzle"
							size: 20
							color: Theme.primary
						}
					}

					StyledText {
						Layout.fillWidth: true
						text: Words.of("plugins.title", "Plugins")
						font.pixelSize: Theme.size.heading
						font.weight: Font.Bold
					}
				}

				Repeater {
					model: [""].concat(Plugins.categories)

					delegate: Clickable {
						id: tab

						required property string modelData
						readonly property bool picked: root.category === tab.modelData

						Layout.fillWidth: true
						implicitHeight: 38
						radius: Theme.radius.medium
						pressedScale: 0.98
						color: tab.picked ? Theme.primaryContainer : "transparent"
						onClicked: root.category = tab.modelData

						RowLayout {
							anchors.fill: parent
							anchors.leftMargin: 14
							anchors.rightMargin: 12

							StyledText {
								Layout.fillWidth: true
								text: tab.modelData === "" ? "All" : tab.modelData
								tone: tab.picked ? Theme.primary : Theme.text
								font.weight: tab.picked ? Font.DemiBold : Font.Medium
							}

							StyledText {
								text: root.count(Plugins.list.filter(plugin => tab.modelData === "" || plugin.category === tab.modelData))
								tabular: true
								tone: Theme.textSubtle
								font.pixelSize: Theme.size.small
							}
						}
					}
				}

				Item {
					Layout.fillHeight: true
				}
			}

			// the tree
			ColumnLayout {
				Layout.fillWidth: true
				Layout.fillHeight: true
				spacing: 12

				Field {
					id: search

					Layout.fillWidth: true
					icon: "magnify"
					placeholder: "Search"
					onEscapePressed: Popups.closeModal()
					onUpPressed: root.move(-1)
					onDownPressed: root.move(1)
					onTabPressed: if (root.rows[root.current]?.folder) root.fold(root.currentNode.key)
					onAccepted: root.activate()
				}

				ListView {
					id: list

					Layout.fillWidth: true
					Layout.fillHeight: true
					clip: true
					model: root.rows
					currentIndex: root.current
					spacing: 2
					boundsBehavior: Flickable.StopAtBounds
					highlightMoveDuration: Motion.short
					ScrollBar.vertical: ThinScrollBar {}

					delegate: Item {
						id: row

						required property var modelData
						required property int index
						readonly property var node: row.modelData.node ?? null
						readonly property var plugin: row.node?.plugin ?? null
						readonly property bool on: row.plugin ? Plugins.on(row.plugin.id) : true
						readonly property var missing: row.plugin ? Plugins.missing(row.plugin.id) : []

						width: list.width - 12
						implicitHeight: row.modelData.header ? 38 : 46

						SectionLabel {
							anchors.left: parent.left
							anchors.leftMargin: 10
							anchors.bottom: parent.bottom
							anchors.bottomMargin: 8
							visible: row.modelData.header
							text: row.modelData.header ? row.modelData.name : ""
						}

						Clickable {
							anchors.fill: parent
							anchors.leftMargin: (row.modelData.depth ?? 0) * 26
							visible: !row.modelData.header
							radius: Theme.radius.medium
							pressedScale: 0.99
							color: row.index === root.current ? Theme.layer2 : "transparent"
							onClicked: {
								root.selected = row.node.key;
								if (row.modelData.folder && root.query === "") root.fold(row.node.key);
							}

							RowLayout {
								anchors.fill: parent
								anchors.leftMargin: 6
								anchors.rightMargin: 10
								spacing: 10

								Glyph {
									Layout.preferredWidth: 18
									opacity: row.modelData.folder ? 1 : 0
									icon: "chevron_right"
									size: 18
									color: Theme.textMuted
									rotation: row.modelData.open ? 90 : 0

									Behavior on rotation {
										SpatialAnim {
											duration: Motion.short
										}
									}
								}

								ClippingRectangle {
									Layout.preferredWidth: 44
									Layout.preferredHeight: 30
									radius: Theme.radius.small
									color: Theme.layer3

									Image {
										id: thumb

										anchors.fill: parent
										source: row.plugin ? Plugins.preview(row.plugin.id) : ""
										sourceSize.height: 60
										fillMode: Image.PreserveAspectCrop
										verticalAlignment: Image.AlignTop
										asynchronous: true
										opacity: row.on ? 1 : 0.35
									}

									Glyph {
										anchors.centerIn: parent
										visible: thumb.status !== Image.Ready
										icon: row.plugin ? (row.plugin.icon || "puzzle") : (row.modelData.open ? "folder_open" : "folder")
										size: 16
										color: row.on ? Theme.textMuted : Theme.textFaint
									}
								}

								StyledText {
									Layout.fillWidth: true
									text: row.node?.name ?? ""
									tone: row.on ? Theme.text : Theme.textMuted
									font.weight: row.modelData.folder ? Font.DemiBold : Font.Medium
								}

								StyledText {
									visible: row.missing.length > 0
									text: `Needs ${row.missing.join(", ")}`
									tone: Theme.warning
									font.pixelSize: Theme.size.small
								}

								StyledText {
									visible: !!row.modelData.folder
									text: row.node ? root.count(row.node.children.reduce((all, child) => all.concat(root.plugins(child)), [])) : ""
									tabular: true
									tone: Theme.textSubtle
									font.pixelSize: Theme.size.small
								}

								Toggle {
									visible: !!row.plugin
									checked: row.plugin ? Plugins.wanted(row.plugin.id) : false
									opacity: row.missing.length > 0 ? 0.5 : 1
									onToggled: {
										root.selected = row.node.key;
										Plugins.toggle(row.plugin.id);
									}
								}
							}
						}
					}
				}
			}

			// the selected one
			Rectangle {
				id: detail

				readonly property var node: root.currentNode
				readonly property var plugin: detail.node?.plugin ?? null
				readonly property var members: detail.node ? root.plugins(detail.node) : []
				readonly property var needs: (detail.plugin?.requires || []).map(id => Plugins.byId[id]).filter(plugin => !!plugin)
				readonly property var users: detail.plugin ? Plugins.list.filter(plugin => (plugin.requires || []).includes(detail.plugin.id)) : []

				Layout.preferredWidth: 360
				Layout.fillHeight: true
				radius: Theme.radius.large
				color: Theme.layer1

				ColumnLayout {
					anchors.fill: parent
					anchors.margins: 14
					spacing: 14
					visible: !!detail.node

					Rectangle {
						Layout.fillWidth: true
						Layout.preferredHeight: 250
						radius: Theme.radius.medium
						color: Theme.layer3
						clip: true

						Image {
							id: picture

							// small things of the bar are not blown up
							property bool small: false

							anchors.fill: parent
							anchors.margins: 8
							source: detail.plugin ? Plugins.preview(detail.plugin.id) : ""
							fillMode: picture.small ? Image.Pad : Image.PreserveAspectFit
							onSourceChanged: picture.small = false
							onStatusChanged: if (status === Image.Ready) picture.small = implicitWidth < width && implicitHeight < height
							asynchronous: true
							smooth: true
							mipmap: true
							opacity: !detail.plugin || Plugins.on(detail.plugin.id) ? 1 : 0.35

							Behavior on opacity {
								Anim {}
							}
						}

						Glyph {
							anchors.centerIn: parent
							visible: picture.status !== Image.Ready
							icon: detail.plugin ? (detail.plugin.icon || "puzzle") : "folder_open"
							size: 44
							color: Theme.textSubtle
						}
					}

					RowLayout {
						Layout.fillWidth: true
						spacing: 10

						ColumnLayout {
							Layout.fillWidth: true
							spacing: 2

							SectionLabel {
								Layout.fillWidth: true
								text: {
									if (!detail.node) return "";
									const path = [];
									for (let key = root.folders[detail.node.key]; key; key = root.folders[key])
										path.unshift(Plugins.byId[key]?.name ?? key.split("/").pop());
									return [detail.node.tab].concat(path).join("  ›  ");
								}
							}

							StyledText {
								Layout.fillWidth: true
								text: detail.node?.name ?? ""
								font.pixelSize: Theme.size.heading
								font.weight: Font.Bold
								wrapMode: Text.WordWrap
							}
						}

						Toggle {
							visible: !!detail.plugin
							checked: detail.plugin ? Plugins.wanted(detail.plugin.id) : false
							onToggled: Plugins.toggle(detail.plugin.id)
						}

						StyledText {
							visible: !detail.plugin
							text: root.count(detail.members)
							tabular: true
							tone: Theme.textMuted
						}
					}

					Repeater {
						model: [
							{ label: "Needs", plugins: detail.needs },
							{ label: "Used by", plugins: detail.users }
						]

						delegate: ColumnLayout {
							id: relation

							required property var modelData

							Layout.fillWidth: true
							visible: relation.modelData.plugins.length > 0
							spacing: 8

							SectionLabel {
								text: relation.modelData.label
							}

							Flow {
								Layout.fillWidth: true
								spacing: 6

								Repeater {
									model: relation.modelData.plugins

									delegate: Chip {
										required property var modelData
										text: modelData.name
										icon: Plugins.on(modelData.id) ? "check_bold" : "close"
										onClicked: root.reveal(modelData.id)
									}
								}
							}
						}
					}

					Item {
						Layout.fillHeight: true
					}
				}
			}
		}
	}
}
