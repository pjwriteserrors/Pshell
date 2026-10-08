pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// Export: which settings go into one KDL file (downloads folder) or onto the
// clipboard. The pages open to their cards (the `take` of NiriSettingsWindow's
// index); only what is set is listed, the rest is niri's default. With
// everything ticked the files go out whole.
FocusScope {
	id: root

	property bool open: false
	property var pages: []
	property var index: []
	// "page/anchor" of the ticked cards
	property var picked: ({})
	property string expanded: ""

	function show(page) {
		const group = root.groups.find(group => group.page.id === page);
		const picked = {};
		(group ? group.entries : root.entries).forEach(entry => picked[root.keyOf(entry)] = true);
		root.picked = picked;
		root.expanded = group ? page : "";
		root.open = true;
		root.forceActiveFocus();
	}

	function close() {
		root.open = false;
	}

	function keyOf(entry) {
		return `${entry.page}/${entry.anchor}`;
	}

	function anyAt(list, names) {
		return (list || []).some(node => node.name === names[0] && (names.length === 1 || root.anyAt(node.children, names.slice(1))));
	}

	function isSet(take) {
		if (take === "@binds") return Keybinds.binds.length > 0;
		if (take === "@corners")
			return NiriSettings.nodes.some(node => node.name === "window-rule" && !node.disabled
				&& !(node.children || []).some(child => child.name === "match" || child.name === "exclude")
				&& (node.children || []).some(child => child.name === "geometry-corner-radius" || child.name === "clip-to-geometry"));
		if (take.startsWith("output:")) return NiriSettings.outputs.some(block => root.anyAt(block.children, [take.slice(7)]));
		return root.anyAt(NiriSettings.nodes, take.split("/"));
	}

	readonly property var groups: root.pages.map(page => ({
		page: page,
		entries: root.index.filter(entry => entry.page === page.id && entry.take && entry.take.some(take => root.isSet(take)))
	})).filter(group => group.entries.length > 0)
	readonly property var entries: root.groups.reduce((all, group) => all.concat(group.entries), [])
	readonly property var chosen: root.entries.filter(entry => root.picked[root.keyOf(entry)])

	// 0 none, 1 some, 2 all
	function level(entries) {
		const count = entries.filter(entry => root.picked[root.keyOf(entry)]).length;
		return count === 0 ? 0 : (count === entries.length ? 2 : 1);
	}

	function tick(entries, on) {
		const picked = Object.assign({}, root.picked);
		entries.forEach(entry => {
			if (on) picked[root.keyOf(entry)] = true;
			else delete picked[root.keyOf(entry)];
		});
		root.picked = picked;
	}

	function send(to) {
		if (root.chosen.length === 0) return;
		const what = { to: to };
		if (root.chosen.length === root.entries.length) {
			what.all = true;
		} else {
			const takes = root.chosen.reduce((all, entry) => all.concat(entry.take), []);
			const parts = root.groups.map(group => root.level(group.entries) === 2 ? [group.page.label]
				: group.entries.filter(entry => root.picked[root.keyOf(entry)]).map(entry => entry.title));
			const titles = parts.reduce((all, part) => all.concat(part), []);
			what.paths = takes.filter(take => !take.startsWith("@") && !take.startsWith("output:")).map(take => take.split("/"));
			what.outputs = takes.filter(take => take.startsWith("output:")).map(take => take.slice(7));
			what.binds = takes.includes("@binds");
			what.corners = takes.includes("@corners");
			what.title = titles.join(", ");
			what.name = titles.length === 1 ? titles[0] : "selection";
		}
		NiriSettings.exportSettings(what);
		root.close();
	}

	enabled: root.open
	visible: scrim.opacity > 0.01

	Keys.onEscapePressed: root.close()
	Keys.onReturnPressed: root.send("file")
	Keys.onEnterPressed: root.send("file")

	component Check: Rectangle {
		property int level: 0

		implicitWidth: 20
		implicitHeight: 20
		radius: 6
		color: level > 0 ? Theme.primary : "transparent"
		border.width: level > 0 ? 0 : 1.5
		border.color: Theme.outline

		Behavior on color {
			ColorAnim {}
		}

		Glyph {
			anchors.centerIn: parent
			visible: parent.level > 0
			icon: parent.level === 1 ? "minus" : "check"
			size: 14
			color: Theme.onPrimary
		}
	}

	Rectangle {
		id: scrim

		anchors.fill: parent
		color: Theme.scrim
		opacity: root.open ? 1 : 0

		Behavior on opacity {
			Anim {
				duration: Motion.short
			}
		}

		MouseArea {
			anchors.fill: parent
			acceptedButtons: Qt.AllButtons
			hoverEnabled: true
			onWheel: wheel => wheel.accepted = true
			onClicked: root.close()
		}
	}

	Rectangle {
		id: card

		anchors.centerIn: parent
		width: 480
		height: column.implicitHeight + 40
		radius: Theme.radius.huge
		color: Theme.layer1
		border.width: 1
		border.color: Theme.outline
		opacity: scrim.opacity
		scale: root.open ? 1 : 0.94

		Behavior on scale {
			SpatialAnim {
				duration: Motion.medium
			}
		}

		MouseArea {
			anchors.fill: parent
			acceptedButtons: Qt.AllButtons
		}

		ColumnLayout {
			id: column

			anchors.left: parent.left
			anchors.right: parent.right
			anchors.top: parent.top
			anchors.margins: 20
			spacing: 12

			RowLayout {
				Layout.fillWidth: true
				spacing: 12

				StyledText {
					Layout.fillWidth: true
					text: "Export"
					font.pixelSize: Theme.size.heading
					font.weight: Font.Bold
				}

				IconButton {
					icon: "close"
					implicitWidth: 30
					implicitHeight: 30
					onClicked: root.close()
				}
			}

			Clickable {
				Layout.fillWidth: true
				implicitHeight: 44
				radius: Theme.radius.large
				color: Theme.layer2
				pressedScale: 0.98
				onClicked: root.tick(root.entries, root.level(root.entries) !== 2)

				RowLayout {
					anchors.fill: parent
					anchors.leftMargin: 14
					anchors.rightMargin: 14
					spacing: 12

					Check {
						level: root.level(root.entries)
					}

					StyledText {
						Layout.fillWidth: true
						text: "Everything"
						font.weight: Font.DemiBold
					}
				}
			}

			Flickable {
				id: flick

				Layout.fillWidth: true
				Layout.preferredHeight: Math.min(list.implicitHeight, root.height - 300)
				contentWidth: width
				contentHeight: list.implicitHeight
				boundsBehavior: Flickable.StopAtBounds
				clip: true
				ScrollBar.vertical: ThinScrollBar {}

				Column {
					id: list

					width: flick.width
					spacing: 2

					Repeater {
						model: root.groups

						delegate: Column {
							id: group

							required property var modelData
							readonly property bool expanded: root.expanded === group.modelData.page.id

							width: list.width

							RowLayout {
								width: parent.width
								height: 42
								spacing: 0

								Clickable {
									Layout.preferredWidth: 46
									Layout.fillHeight: true
									radius: Theme.radius.large
									onClicked: root.tick(group.modelData.entries, root.level(group.modelData.entries) !== 2)

									Check {
										anchors.centerIn: parent
										level: root.level(group.modelData.entries)
									}
								}

								Clickable {
									Layout.fillWidth: true
									Layout.fillHeight: true
									radius: Theme.radius.large
									pressedScale: 0.98
									onClicked: root.expanded = group.expanded ? "" : group.modelData.page.id

									RowLayout {
										anchors.fill: parent
										anchors.leftMargin: 8
										anchors.rightMargin: 12
										spacing: 12

										Glyph {
											icon: group.modelData.page.icon
											size: 17
											color: Theme.textMuted
										}

										StyledText {
											Layout.fillWidth: true
											text: group.modelData.page.label
											font.weight: Font.Medium
										}

										Glyph {
											icon: "chevron_down"
											size: 16
											color: Theme.textSubtle
											animated: false
											rotation: group.expanded ? 180 : 0

											Behavior on rotation {
												SpatialAnim {
													duration: Motion.medium
												}
											}
										}
									}
								}
							}

							Item {
								width: parent.width
								height: group.expanded ? cards.implicitHeight : 0
								clip: true

								Behavior on height {
									Anim {
										duration: Motion.medium
									}
								}

								Column {
									id: cards

									width: parent.width

									Repeater {
										model: group.modelData.entries

										delegate: Clickable {
											id: card

											required property var modelData

											width: cards.width
											height: 36
											radius: Theme.radius.large
											pressedScale: 0.98
											onClicked: root.tick([card.modelData], !root.picked[root.keyOf(card.modelData)])

											RowLayout {
												anchors.fill: parent
												anchors.leftMargin: 46
												anchors.rightMargin: 12
												spacing: 12

												Check {
													implicitWidth: 18
													implicitHeight: 18
													level: root.picked[root.keyOf(card.modelData)] ? 2 : 0
												}

												StyledText {
													Layout.fillWidth: true
													text: card.modelData.title
													tone: Theme.textMuted
													elide: Text.ElideRight
												}
											}
										}
									}
								}
							}
						}
					}
				}
			}

			RowLayout {
				Layout.fillWidth: true
				Layout.topMargin: 4
				spacing: 8

				Item {
					Layout.fillWidth: true
				}

				TextButton {
					icon: "content_copy"
					text: "Copy"
					enabled: root.chosen.length > 0
					onActivated: root.send("clipboard")
				}

				TextButton {
					variant: "filled"
					icon: "tray_arrow_down"
					text: "Save"
					enabled: root.chosen.length > 0
					onActivated: root.send("file")
				}
			}
		}
	}
}
