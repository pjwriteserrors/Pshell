pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import qs.style.theme
import qs.style.widgets
import "Nodes.js" as Nodes
import "NiriColor.js" as NiriColor

// A workspace as niri lays it out, from the settings: columns side by side
// with gaps, the struts at the edges, the view scrolled the way
// center-focused-column says, and the focus ring, borders, shadows, the tab
// indicator and the insert hint drawn as niri draws them. Click a window to
// focus it; drag a gap or an edge to change gaps and struts.
Item {
	id: root

	// logical size of the monitor shown
	property real logicalWidth: 1600
	property real logicalHeight: 900
	readonly property real factor: Math.min(root.width / root.logicalWidth, root.height / root.logicalHeight)
	readonly property real screenWidth: root.logicalWidth * root.factor
	readonly property real screenHeight: root.logicalHeight * root.factor

	property real gaps: 16
	property var struts: ({ left: 0, right: 0, top: 0, bottom: 0 })
	property string centerMode: "never"
	property bool centerSingle: false
	property color background: "#262626"
	// the wallpaper covers the background color, as on the desktop; it steps
	// aside while the background color is being looked at
	property string wallpaper: String(Theme.wal?.wallpaper ?? "")
	property bool peekBackground: false
	property real cornerRadius: 0
	// [{ width (proportion), tabs }]
	property var columns: [{ width: 0.5, tabs: 1 }, { width: 0.33333, tabs: 1 }, { width: 0.5, tabs: 1 }]
	property int focused: 0
	property var ring: null
	property var border: null
	property var shadow: null
	property var tabIndicator: null
	property var insertHint: null
	property bool showInsertHint: false
	property bool tabbed: false
	property bool interactive: true
	// what can be dragged here
	property bool gapsHandle: false
	property bool strutHandles: false

	signal gapsMoved(real value)
	signal strutMoved(string side, real value)

	// ── the layout, in logical pixels ────────────────────────────────────
	readonly property bool ringOn: Nodes.on(root.ring, true)
	readonly property bool borderOn: Nodes.on(root.border, false)
	readonly property bool shadowOn: Nodes.on(root.shadow, false)
	readonly property real borderWidth: root.borderOn ? Number(Nodes.arg(root.border, "width", 4)) : 0
	readonly property real ringWidth: root.ringOn ? Number(Nodes.arg(root.ring, "width", 4)) : 0
	readonly property real areaX: Number(root.struts.left || 0)
	readonly property real areaY: Number(root.struts.top || 0)
	readonly property real areaW: root.logicalWidth - Number(root.struts.left || 0) - Number(root.struts.right || 0)
	readonly property real areaH: root.logicalHeight - Number(root.struts.top || 0) - Number(root.struts.bottom || 0)
	readonly property var tiles: {
		const out = [];
		let x = root.gaps;
		for (const column of root.columns) {
			// proportions count the gaps: four ¼ columns fill the screen exactly
			const w = (root.areaW - root.gaps) * column.width - root.gaps;
			out.push({ x: x, y: root.gaps, w: Math.max(40, w), h: root.areaH - root.gaps * 2, tabs: column.tabs || 1 });
			x += Math.max(40, w) + root.gaps;
		}
		return out;
	}
	readonly property real viewX: {
		const tile = root.tiles[root.focused];
		if (!tile) return 0;
		const center = tile.x + tile.w / 2 - root.areaW / 2;
		if (root.tiles.length === 1 && root.centerSingle) return center;
		if (root.centerMode === "always") return center;
		// the focused column with the gap after it in view, from the start
		let view = 0;
		if (tile.x + tile.w + root.gaps > view + root.areaW) view = tile.x + tile.w + root.gaps - root.areaW;
		if (root.centerMode === "on-overflow") {
			const before = root.tiles[root.focused - 1];
			if (before && tile.x + tile.w - before.x + root.gaps * 2 > root.areaW) return center;
		}
		return view;
	}
	property real shownView: root.viewX

	Behavior on shownView {
		SpatialAnim {
			duration: Motion.extraLong
		}
	}

	function paint(section, kind, fallback) {
		return NiriColor.qt(String(Nodes.arg(section, `${kind}-color`, fallback)));
	}

	implicitWidth: 640
	implicitHeight: 360

	Item {
		id: screen

		anchors.centerIn: parent
		width: root.screenWidth
		height: root.screenHeight

		RoundClip {
			anchors.fill: parent
			radius: Theme.radius.large

			Rectangle {
				anchors.fill: parent
				color: root.background

				Behavior on color {
					ColorAnim {}
				}
			}

			Image {
				anchors.fill: parent
				visible: root.wallpaper !== ""
				source: root.wallpaper !== "" ? `file://${root.wallpaper}` : ""
				fillMode: Image.PreserveAspectCrop
				asynchronous: true
				sourceSize.width: 900
				opacity: root.peekBackground ? 0 : 1

				Behavior on opacity {
					Anim {
						duration: Motion.long
					}
				}
			}

			// the struts: room the windows leave free
			Repeater {
				model: ["left", "right", "top", "bottom"]

				delegate: Rectangle {
					id: strut

					required property string modelData
					readonly property real amount: Number(root.struts[strut.modelData] || 0) * root.factor
					readonly property bool vertical: strut.modelData === "left" || strut.modelData === "right"

					x: strut.modelData === "right" ? screen.width - strut.amount : 0
					y: strut.modelData === "bottom" ? screen.height - strut.amount : 0
					width: strut.vertical ? Math.max(0, strut.amount) : screen.width
					height: strut.vertical ? screen.height : Math.max(0, strut.amount)
					color: Qt.alpha(Theme.primary, 0.12)
					visible: strut.amount > 0.5

					Behavior on width {
						SpatialAnim {
							duration: Motion.medium
						}
					}
					Behavior on height {
						SpatialAnim {
							duration: Motion.medium
						}
					}
				}
			}

			// the working area, scrolled
			Item {
				id: area

				x: root.areaX * root.factor
				y: root.areaY * root.factor
				width: root.areaW * root.factor
				height: root.areaH * root.factor

				Behavior on x {
					SpatialAnim {
						duration: Motion.medium
					}
				}
				Behavior on y {
					SpatialAnim {
						duration: Motion.medium
					}
				}

				Item {
					id: strip

					x: -root.shownView * root.factor
					width: parent.width
					height: parent.height

					Repeater {
						model: root.tiles.length

						delegate: Item {
							id: tile

							required property int index
							readonly property var geo: root.tiles[tile.index] ?? { x: 0, y: 0, w: 100, h: 100, tabs: 1 }
							readonly property bool active: tile.index === root.focused
							readonly property real radius: root.cornerRadius * root.factor
							readonly property bool isTabbed: tile.geo.tabs > 1

							x: tile.geo.x * root.factor
							y: tile.geo.y * root.factor
							width: tile.geo.w * root.factor
							height: tile.geo.h * root.factor

							Behavior on x {
								SpatialAnim {
									duration: Motion.long
								}
							}
							Behavior on width {
								SpatialAnim {
									duration: Motion.long
								}
							}
							Behavior on y {
								SpatialAnim {
									duration: Motion.medium
								}
							}
							Behavior on height {
								SpatialAnim {
									duration: Motion.medium
								}
							}

							RectangularShadow {
								visible: root.shadowOn
								anchors.fill: parent
								offset.x: Number(Nodes.prop(root.shadow, "offset", "x", 0)) * root.factor
								offset.y: Number(Nodes.prop(root.shadow, "offset", "y", 5)) * root.factor
								blur: Number(Nodes.arg(root.shadow, "softness", 30)) * root.factor
								spread: Number(Nodes.arg(root.shadow, "spread", 5)) * root.factor
								radius: tile.radius
								color: {
									const base = NiriColor.qt(String(Nodes.arg(root.shadow, "color", "#00000070")));
									if (tile.active) return base;
									const inactive = Nodes.arg(root.shadow, "inactive-color", "");
									return inactive !== "" ? NiriColor.qt(String(inactive)) : Qt.rgba(base.r, base.g, base.b, base.a * 0.75);
								}
								cached: false
							}

							// the focus ring: around the active window, outside it
							Item {
								visible: root.ringOn && tile.active && root.ringWidth > 0
								x: -root.ringWidth * root.factor
								y: -root.ringWidth * root.factor
								width: parent.width + root.ringWidth * root.factor * 2
								height: parent.height + root.ringWidth * root.factor * 2

								Rectangle {
									anchors.fill: parent
									visible: !Nodes.gradient(root.ring, "active-gradient")
									radius: tile.radius + root.ringWidth * root.factor
									color: root.paint(root.ring, "active", "#7fc8ff")

									Behavior on color {
										ColorAnim {}
									}
								}

								GradientFill {
									readonly property var g: Nodes.gradient(root.ring, "active-gradient")
									readonly property bool wide: g?.relativeTo === "workspace-view"

									visible: !!g
									x: wide ? -tile.x - parent.x : 0
									width: wide ? area.width : parent.width
									height: parent.height
									from: g?.from ?? "#000"
									to: g?.to ?? "#fff"
									angle: g?.angle ?? 180
									space: g?.space ?? "srgb"
									radius: wide ? 0 : tile.radius + root.ringWidth * root.factor
									layer.enabled: wide
								}
							}

							// the window, inside its border
							Item {
								id: frameItem

								anchors.fill: parent

								Rectangle {
									anchors.fill: parent
									visible: root.borderOn && !Nodes.gradient(root.border, tile.active ? "active-gradient" : "inactive-gradient")
									radius: tile.radius
									color: tile.active ? root.paint(root.border, "active", "#ffc87f") : root.paint(root.border, "inactive", "#505050")

									Behavior on color {
										ColorAnim {}
									}
								}

								RoundClip {
									readonly property var g: Nodes.gradient(root.border, tile.active ? "active-gradient" : "inactive-gradient")

									anchors.fill: parent
									radius: tile.radius
									visible: root.borderOn && !!g

									GradientFill {
										readonly property var g: parent.parent.g
										readonly property bool wide: g?.relativeTo === "workspace-view"

										x: wide ? -tile.x : 0
										width: wide ? area.width : parent.width
										height: parent.height
										from: g?.from ?? "#000"
										to: g?.to ?? "#fff"
										angle: g?.angle ?? 180
										space: g?.space ?? "srgb"
									}
								}

								Rectangle {
									id: win

									anchors.fill: parent
									anchors.margins: root.borderWidth * root.factor
									radius: Math.max(0, tile.radius - root.borderWidth * root.factor)
									color: Qt.tint(Theme.base, Qt.alpha(Theme.text, tile.active ? 0.07 : 0.035))

									Behavior on anchors.margins {
										SpatialAnim {
											duration: Motion.medium
										}
									}

									// a little app inside
									Column {
										anchors.left: parent.left
										anchors.right: parent.right
										anchors.top: parent.top
										anchors.margins: Math.max(4, 14 * root.factor)
										spacing: Math.max(3, 9 * root.factor)
										clip: true

										Rectangle {
											width: parent.width * 0.4
											height: Math.max(3, 12 * root.factor)
											radius: height / 2
											color: tile.active ? Qt.alpha(Theme.primary, 0.55) : Theme.layer3
										}

										Repeater {
											model: [0.9, 0.75, 0.82, 0.6, 0.7]

											delegate: Rectangle {
												required property real modelData

												width: parent.width * modelData
												height: Math.max(2, 7 * root.factor)
												radius: height / 2
												color: Theme.layer3
											}
										}
									}
								}
							}

							// tabs of a tabbed column
							Item {
								id: tabs

								readonly property var section: root.tabIndicator
								readonly property bool shown: tile.isTabbed && Nodes.on(tabs.section, true) && !(Nodes.flag(tabs.section, "hide-when-single-tab") && tile.geo.tabs < 2)
								readonly property string position: String(Nodes.arg(tabs.section, "position", "left"))
								readonly property bool vertical: tabs.position === "left" || tabs.position === "right"
								readonly property real thickness: Number(Nodes.arg(tabs.section, "width", 4)) * root.factor
								readonly property real gap: Number(Nodes.arg(tabs.section, "gap", 5)) * root.factor
								readonly property real proportion: Number(Nodes.prop(tabs.section, "length", "total-proportion", 0.5))
								readonly property real between: Number(Nodes.arg(tabs.section, "gaps-between-tabs", 0)) * root.factor
								readonly property real corner: Number(Nodes.arg(tabs.section, "corner-radius", 0)) * root.factor
								readonly property real length: (tabs.vertical ? tile.height : tile.width) * tabs.proportion

								visible: tabs.shown
								x: tabs.position === "left" ? -tabs.gap - tabs.thickness : (tabs.position === "right" ? tile.width + tabs.gap : (tile.width - tabs.length) / 2)
								y: tabs.position === "top" ? -tabs.gap - tabs.thickness : (tabs.position === "bottom" ? tile.height + tabs.gap : (tile.height - tabs.length) / 2)
								width: tabs.vertical ? tabs.thickness : tabs.length
								height: tabs.vertical ? tabs.length : tabs.thickness

								Behavior on x {
									SpatialAnim {
										duration: Motion.medium
									}
								}
								Behavior on y {
									SpatialAnim {
										duration: Motion.medium
									}
								}

								Repeater {
									model: tile.geo.tabs

									delegate: Rectangle {
										required property int index
										readonly property real each: (tabs.length - tabs.between * (tile.geo.tabs - 1)) / tile.geo.tabs

										x: tabs.vertical ? 0 : index * (each + tabs.between)
										y: tabs.vertical ? index * (each + tabs.between) : 0
										width: tabs.vertical ? tabs.thickness : each
										height: tabs.vertical ? each : tabs.thickness
										radius: tabs.corner
										color: index === 0
											? (Nodes.has(tabs.section, "active-color") ? root.paint(tabs.section, "active", "#7fc8ff") : (root.borderOn ? root.paint(root.border, "active", "#ffc87f") : root.paint(root.ring, "active", "#7fc8ff")))
											: (Nodes.has(tabs.section, "inactive-color") ? root.paint(tabs.section, "inactive", "#505050") : (root.borderOn ? root.paint(root.border, "inactive", "#505050") : root.paint(root.ring, "inactive", "#505050")))
									}
								}
							}

							MouseArea {
								anchors.fill: parent
								enabled: root.interactive
								cursorShape: Qt.PointingHandCursor
								onClicked: root.focused = tile.index
							}
						}
					}

					// where a dragged window would land
					Rectangle {
						id: hint

						readonly property var g: Nodes.gradient(root.insertHint, "gradient")
						readonly property var after: root.tiles[0]

						visible: root.showInsertHint && Nodes.on(root.insertHint, true) && !!hint.after
						x: hint.after ? (hint.after.x + hint.after.w) * root.factor + (root.gaps * root.factor - width) / 2 : 0
						y: hint.after ? hint.after.y * root.factor : 0
						width: Math.max(4, 30 * root.factor)
						height: hint.after ? hint.after.h * root.factor : 0
						radius: Math.max(2, root.cornerRadius * root.factor)
						color: NiriColor.qt(String(Nodes.arg(root.insertHint, "color", "#ffc87f80")))
						opacity: 0.5 + 0.5 * Math.abs(Math.sin(hint.phase))

						property real phase: 0

						NumberAnimation on phase {
							running: hint.visible
							from: 0
							to: Math.PI * 2
							duration: 2400
							loops: Animation.Infinite
						}

						GradientFill {
							anchors.fill: parent
							visible: !!hint.g
							from: hint.g?.from ?? "#000"
							to: hint.g?.to ?? "#fff"
							angle: hint.g?.angle ?? 180
							space: hint.g?.space ?? "srgb"
							radius: parent.radius
						}
					}

					// the gap handle, between the first two columns
					Rectangle {
						id: gapHandle

						readonly property var first: root.tiles[0]

						visible: root.gapsHandle && !!gapHandle.first
						x: gapHandle.first ? (gapHandle.first.x + gapHandle.first.w) * root.factor + (root.gaps * root.factor - width) / 2 : 0
						y: area.height / 2 - height / 2
						width: gapMouse.pressed ? 10 : 8
						height: 44
						radius: width / 2
						color: Theme.primary
						border.width: 2
						border.color: Theme.base
						scale: gapMouse.containsMouse || gapMouse.pressed ? 1.15 : 1

						Behavior on scale {
							SpatialAnim {
								duration: Motion.short
							}
						}

						MouseArea {
							id: gapMouse

							property real startX
							property real startGaps

							anchors.fill: parent
							anchors.margins: -10
							hoverEnabled: true
							preventStealing: true
							cursorShape: Qt.SizeHorCursor
							onPressed: event => {
								gapMouse.startX = mapToItem(screen, event.x, 0).x;
								gapMouse.startGaps = root.gaps;
							}
							onPositionChanged: event => {
								if (!pressed) return;
								const dx = mapToItem(screen, event.x, 0).x - gapMouse.startX;
								root.gapsMoved(Math.max(0, Math.min(96, Math.round(gapMouse.startGaps + dx / root.factor))));
							}
						}
					}
				}
			}

			// the strut handles: one on each edge
			Repeater {
				model: root.strutHandles ? ["left", "right", "top", "bottom"] : []

				delegate: Item {
					id: edge

					required property string modelData
					readonly property bool vertical: edge.modelData === "left" || edge.modelData === "right"
					readonly property real amount: Number(root.struts[edge.modelData] || 0) * root.factor

					x: edge.modelData === "left" ? edge.amount - 8 : (edge.modelData === "right" ? screen.width - edge.amount - 8 : screen.width / 2 - 40)
					y: edge.modelData === "top" ? edge.amount - 8 : (edge.modelData === "bottom" ? screen.height - edge.amount - 8 : screen.height / 2 - 40)
					width: edge.vertical ? 16 : 80
					height: edge.vertical ? 80 : 16

					Rectangle {
						anchors.centerIn: parent
						width: edge.vertical ? (edgeMouse.containsMouse || edgeMouse.pressed ? 6 : 4) : 46
						height: edge.vertical ? 46 : (edgeMouse.containsMouse || edgeMouse.pressed ? 6 : 4)
						radius: 3
						color: edgeMouse.containsMouse || edgeMouse.pressed ? Theme.primary : Qt.alpha(Theme.text, 0.35)

						Behavior on color {
							ColorAnim {}
						}
					}

					MouseArea {
						id: edgeMouse

						property point start
						property real startAmount

						anchors.fill: parent
						hoverEnabled: true
						preventStealing: true
						cursorShape: edge.vertical ? Qt.SizeHorCursor : Qt.SizeVerCursor
						onPressed: event => {
							edgeMouse.start = mapToItem(screen, event.x, event.y);
							edgeMouse.startAmount = Number(root.struts[edge.modelData] || 0);
						}
						onPositionChanged: event => {
							if (!pressed) return;
							const p = mapToItem(screen, event.x, event.y);
							let delta = edge.vertical ? p.x - edgeMouse.start.x : p.y - edgeMouse.start.y;
							if (edge.modelData === "right" || edge.modelData === "bottom") delta = -delta;
							root.strutMoved(edge.modelData, Math.max(-64, Math.min(400, Math.round(edgeMouse.startAmount + delta / root.factor))));
						}
					}
				}
			}
		}

		Rectangle {
			anchors.fill: parent
			color: "transparent"
			radius: Theme.radius.large
			border.width: 1
			border.color: Theme.outline
		}
	}
}
