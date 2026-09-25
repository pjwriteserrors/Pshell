pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.style.theme
import qs.core.services
import qs.style.widgets

// Window overview (right click on the workspaces). Every monitor is a
// column, left to right like they are arranged; every workspace a miniature
// of its screen with the windows laid out like niri's scrolling columns.
// Click a window to focus it, middle click closes it, drag it onto another
// workspace (also on another monitor) to move it there. Clicking an empty
// spot focuses that workspace.
Drawer {
	id: root

	readonly property real cardWidth: 232
	readonly property real columnGap: 14
	property var monitors: []
	property string monitorsKey: ""
	property bool dragging: false
	property bool pending: false
	property var hoveredWindow: null

	panelId: "overview"
	panelWidth: Math.max(360, root.monitors.length * root.cardWidth + Math.max(0, root.monitors.length - 1) * root.columnGap + root.padding * 2)
	padding: 16
	keyboard: true
	contentHeight: content.implicitHeight

	onPanelOpened: {
		root.hoveredWindow = null;
		root.rebuild();
	}

	Connections {
		target: Niri
		enabled: root.shown
		function onWindowsChanged() {
			root.rebuild();
		}
		function onWorkspacesChanged() {
			root.rebuild();
		}
	}

	function screenSize(name) {
		for (const screen of Quickshell.screens)
			if (String(screen.name) === String(name)) return { w: screen.width || 1920, h: screen.height || 1080 };
		return { w: 1920, h: 1080 };
	}

	// windows of one workspace, positioned in 0..1 card coordinates
	function layoutWindows(windows, size) {
		const gap = 16;
		const columns = {};
		const floating = [];
		for (const window of windows) {
			const pos = window.layout?.pos_in_scrolling_layout;
			if (window.is_floating || !Array.isArray(pos)) {
				floating.push(window);
				continue;
			}
			(columns[pos[0]] = columns[pos[0]] || []).push(window);
		}
		const tiles = [];
		let x = 0;
		for (const key of Object.keys(columns).map(Number).sort((a, b) => a - b)) {
			const column = columns[key].sort((a, b) => a.layout.pos_in_scrolling_layout[1] - b.layout.pos_in_scrolling_layout[1]);
			const width = Math.max(...column.map(w => Number(w.layout.tile_size?.[0] || size.w / 2)));
			const total = column.reduce((sum, w) => sum + Number(w.layout.tile_size?.[1] || size.h), 0) + gap * (column.length - 1);
			let y = Math.max(0, (size.h - total) / 2);
			for (const window of column) {
				const height = Number(window.layout.tile_size?.[1] || size.h);
				tiles.push({ window, x: x + gap, y, w: width, h: height });
				y += height + gap;
			}
			x += width + gap;
		}
		const span = Math.max(size.w, x + gap);
		const result = tiles.map(t => root.entry(t.window, (t.x) / span, t.y / size.h, t.w / span, t.h / size.h, false));
		for (const window of floating) {
			const w = Number(window.layout?.window_size?.[0] || size.w / 3);
			const h = Number(window.layout?.window_size?.[1] || size.h / 3);
			const pos = window.layout?.tile_pos_in_workspace_view;
			const px = Array.isArray(pos) ? Number(pos[0]) : (size.w - w) / 2;
			const py = Array.isArray(pos) ? Number(pos[1]) : (size.h - h) / 2;
			result.push(root.entry(window, px / size.w, py / size.h, w / size.w, h / size.h, true));
		}
		return result;
	}

	function entry(window, x, y, w, h, floating) {
		const clamp = v => Math.max(0, Math.min(1, v));
		return {
			id: Number(window.id),
			appId: window.app_id || "",
			title: window.title || window.app_id || "Window",
			focused: !!window.is_focused,
			urgent: !!window.is_urgent,
			floating,
			x: clamp(x),
			y: clamp(y),
			w: Math.max(0.06, Math.min(1 - clamp(x), w)),
			h: Math.max(0.1, Math.min(1 - clamp(y), h))
		};
	}

	function rebuild() {
		if (root.dragging) {
			root.pending = true;
			return;
		}
		const byWorkspace = {};
		for (const window of Niri.windows) (byWorkspace[window.workspace_id] = byWorkspace[window.workspace_id] || []).push(window);
		const monitors = [];
		for (const group of Niri.workspaceGroups) {
			const size = root.screenSize(group.output);
			monitors.push({
				output: group.output,
				width: size.w,
				height: size.h,
				workspaces: group.workspaces.map(ws => ({ ws, windows: root.layoutWindows(byWorkspace[ws.id] || [], size) }))
			});
		}
		const key = JSON.stringify(monitors);
		if (key === root.monitorsKey) return;
		root.monitorsKey = key;
		root.monitors = monitors;
	}

	ColumnLayout {
		id: content

		anchors.left: parent.left
		anchors.right: parent.right
		spacing: 12

		RowLayout {
			Layout.fillWidth: true
			spacing: 10

			Glyph {
				icon: "view_grid_outline"
				size: 18
				color: Theme.primary
			}

			StyledText {
				text: "Overview"
				font.pixelSize: Theme.size.title
				font.weight: Font.Bold
			}

			StyledText {
				Layout.fillWidth: true
				horizontalAlignment: Text.AlignRight
				text: root.hoveredWindow ? root.hoveredWindow.title : "Click to focus · drag to move · middle-click to close"
				tone: root.hoveredWindow ? Theme.text : Theme.textSubtle
				font.pixelSize: Theme.size.small
			}
		}

		Flickable {
			id: flick

			Layout.fillWidth: true
			Layout.preferredHeight: Math.min(monitorsRow.implicitHeight, root.maxBodyHeight - root.padding * 2 - 48)
			implicitHeight: monitorsRow.implicitHeight
			contentHeight: monitorsRow.implicitHeight
			contentWidth: width
			clip: true
			boundsBehavior: Flickable.StopAtBounds
			interactive: !root.dragging && contentHeight > height

			Row {
				id: monitorsRow

				spacing: root.columnGap

				Repeater {
					model: root.monitors

					delegate: Column {
						id: monitor

						required property var modelData
						readonly property bool here: root.targetScreen && String(root.targetScreen.name) === monitor.modelData.output
						readonly property real cardHeight: Math.round(root.cardWidth * monitor.modelData.height / monitor.modelData.width)

						width: root.cardWidth
						spacing: 8

						RowLayout {
							width: parent.width
							spacing: 6

							Glyph {
								icon: monitor.modelData.width < 2000 ? "laptop" : "monitor"
								size: 14
								color: monitor.here ? Theme.primary : Theme.textMuted
							}

							StyledText {
								text: monitor.modelData.output
								font.pixelSize: Theme.size.label
								font.weight: Font.DemiBold
								tone: monitor.here ? Theme.primary : Theme.text
							}

							StyledText {
								Layout.fillWidth: true
								text: monitor.here ? "this screen" : `${monitor.modelData.width}×${monitor.modelData.height}`
								tone: Theme.textSubtle
								font.pixelSize: Theme.size.tiny
							}
						}

						Repeater {
							model: monitor.modelData.workspaces

							delegate: Item {
								id: slot

								required property var modelData
								readonly property var ws: slot.modelData.ws
								readonly property bool compact: slot.modelData.windows.length === 0 && !slot.ws.active

								width: root.cardWidth
								height: slot.compact ? 30 : monitor.cardHeight

								// card background; a drag hovering here lights it up
								Rectangle {
									id: card

									anchors.fill: parent
									radius: Theme.radius.medium
									color: drop.containsDrag ? Qt.alpha(Theme.primary, 0.18)
										: (slot.ws.focused ? Qt.alpha(Theme.primary, 0.08) : Theme.layer1)
									border.width: slot.ws.focused || drop.containsDrag ? 2 : 1
									border.color: drop.containsDrag || slot.ws.focused ? Theme.primary
										: (slot.ws.active ? Qt.alpha(Theme.fg, 0.22) : Theme.outline)
									scale: drop.containsDrag ? 1.02 : 1

									Behavior on color {
										ColorAnim {}
									}
									Behavior on scale {
										SpatialAnim {
											duration: Motion.short
										}
									}

									MouseArea {
										anchors.fill: parent
										cursorShape: Qt.PointingHandCursor
										onClicked: {
											Niri.focusWorkspace(slot.ws);
											Popups.close();
										}
									}

									// workspace number
									Rectangle {
										x: 6
										y: slot.compact ? (parent.height - height) / 2 : 6
										z: 5
										width: Math.max(18, number.implicitWidth + 10)
										height: 18
										radius: 9
										color: slot.ws.focused ? Theme.primary : Qt.alpha(Theme.bg, 0.75)

										StyledText {
											id: number

											anchors.centerIn: parent
											text: slot.ws.name || slot.ws.idx
											font.pixelSize: Theme.size.tiny
											font.weight: Font.Bold
											tone: slot.ws.focused ? Theme.onPrimary : Theme.textMuted
										}
									}

									RowLayout {
										visible: slot.compact
										anchors.fill: parent
										anchors.leftMargin: 32
										anchors.rightMargin: 10
										spacing: 6

										StyledText {
											Layout.fillWidth: true
											text: drop.containsDrag ? "Move here" : "Empty workspace"
											tone: drop.containsDrag ? Theme.primary : Theme.textSubtle
											font.pixelSize: Theme.size.small
										}

										Glyph {
											icon: "plus"
											size: 14
											color: Theme.textSubtle
										}
									}

									// windows
									Item {
										id: canvas

										anchors.fill: parent
										anchors.margins: 4
										visible: !slot.compact

										Repeater {
											model: slot.modelData.windows

											delegate: Rectangle {
												id: tile

												required property var modelData
												readonly property bool hovered: tileMouse.containsMouse
												readonly property bool lifted: root.dragging && ghost.windowId === tile.modelData.id

												x: tile.modelData.x * canvas.width + 1.5
												y: tile.modelData.y * canvas.height + 1.5
												z: tile.modelData.floating ? 2 : 1
												width: Math.max(10, tile.modelData.w * canvas.width - 3)
												height: Math.max(10, tile.modelData.h * canvas.height - 3)
												radius: Theme.radius.small
												color: tile.modelData.focused ? Theme.primaryContainer : Theme.layer3
												border.width: tile.hovered || tile.modelData.focused || tile.modelData.urgent ? 1.5 : 0
												border.color: tile.modelData.urgent ? Theme.danger : (tile.hovered ? Theme.primary : Qt.alpha(Theme.primary, 0.6))
												opacity: tile.lifted ? 0.3 : 1
												scale: tile.hovered && !root.dragging ? 1.04 : 1

												Behavior on scale {
													SpatialAnim {
														duration: Motion.short
													}
												}
												Behavior on opacity {
													Anim {
														duration: Motion.short
													}
												}

												Column {
													anchors.centerIn: parent
													width: parent.width - 12
													spacing: 4

													Image {
														anchors.horizontalCenter: parent.horizontalCenter
														width: Math.min(28, tile.width - 8, tile.height - 8)
														height: width
														source: AppIcons.forAppId(tile.modelData.appId)
														sourceSize: Qt.size(56, 56)
														fillMode: Image.PreserveAspectFit
														asynchronous: true
														smooth: true
														mipmap: true
													}

													StyledText {
														width: parent.width
														visible: tile.height > 64 && tile.width > 70
														horizontalAlignment: Text.AlignHCenter
														text: tile.modelData.title
														tone: tile.modelData.focused ? Theme.text : Theme.textMuted
														font.pixelSize: Theme.size.tiny
													}
												}

												MouseArea {
													id: tileMouse

													property point pressPoint
													property bool moved: false

													anchors.fill: parent
													preventStealing: true
													hoverEnabled: true
													acceptedButtons: Qt.LeftButton | Qt.MiddleButton
													cursorShape: root.dragging ? Qt.ClosedHandCursor : Qt.PointingHandCursor
													onContainsMouseChanged: {
														if (containsMouse) root.hoveredWindow = tile.modelData;
														else if (root.hoveredWindow && root.hoveredWindow.id === tile.modelData.id) root.hoveredWindow = null;
													}
													onPressed: mouse => {
														pressPoint = Qt.point(mouse.x, mouse.y);
														moved = false;
													}
													onPositionChanged: mouse => {
														if (!pressed || !(mouse.buttons & Qt.LeftButton)) return;
														if (!root.dragging && Math.hypot(mouse.x - pressPoint.x, mouse.y - pressPoint.y) > 6) {
															moved = true;
															ghost.begin(tile, tile.modelData);
														}
														if (root.dragging) ghost.follow(tileMouse, mouse);
													}
													onReleased: mouse => {
														if (root.dragging) ghost.finish();
													}
													onClicked: mouse => {
														if (moved) return;
														if (mouse.button === Qt.MiddleButton) {
															Niri.closeWindow(tile.modelData.id);
															return;
														}
														Niri.focusWindow(tile.modelData.id);
														Popups.close();
													}
												}
											}
										}
									}
								}

								DropArea {
									id: drop

									anchors.fill: parent
									keys: ["niri-window"]
									onDropped: Niri.moveWindow(ghost.windowId, slot.ws)
								}
							}
						}
					}
				}
			}
		}
	}

	// the window being dragged, floating above all columns
	Rectangle {
		id: ghost

		property int windowId: -1
		property string appId: ""

		function begin(tile, data) {
			ghost.windowId = data.id;
			ghost.appId = data.appId;
			ghost.width = Math.min(120, Math.max(44, tile.width));
			ghost.height = Math.min(80, Math.max(34, tile.height));
			root.dragging = true;
		}

		function follow(area, mouse) {
			const p = area.mapToItem(ghost.parent, mouse.x, mouse.y);
			ghost.x = p.x - ghost.width / 2;
			ghost.y = p.y - ghost.height / 2;
		}

		function finish() {
			ghost.Drag.drop();
			root.dragging = false;
			if (root.pending) {
				root.pending = false;
				root.rebuild();
			}
		}

		z: 100
		visible: root.dragging
		radius: Theme.radius.small
		color: Theme.primaryContainer
		border.width: 2
		border.color: Theme.primary
		scale: root.dragging ? 1 : 0.8
		Drag.active: root.dragging
		Drag.keys: ["niri-window"]
		Drag.hotSpot.x: width / 2
		Drag.hotSpot.y: height / 2

		Behavior on scale {
			SpatialAnim {
				duration: Motion.short
			}
		}

		Image {
			anchors.centerIn: parent
			width: 26
			height: 26
			source: ghost.appId !== "" || root.dragging ? AppIcons.forAppId(ghost.appId) : ""
			sourceSize: Qt.size(52, 52)
			fillMode: Image.PreserveAspectFit
			smooth: true
			mipmap: true
		}
	}
}
