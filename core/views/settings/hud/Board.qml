pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// The scene's picture with its zones: drag on it to draw one (or click a
// box found on the picture), drag a zone to move it – it snaps to the
// edges of the others – pull an edge or corner to size it, right-click for
// more. Anything carried (a sequence, a reaction) is dropped on a zone.
Rectangle {
	id: root

	property var page: null
	readonly property real pad: 14
	readonly property real head: 54
	readonly property bool ready: picture.status === Image.Ready
	readonly property real ratio: root.ready && picture.implicitWidth > 0 ? picture.implicitHeight / picture.implicitWidth : 9 / 16
	readonly property real availW: Math.max(10, root.width - 2 * root.pad)
	readonly property real availH: Math.max(10, root.height - root.head - root.pad)
	// snapping guides while a zone is moved (fractions, -1 none)
	property real guideX: -1
	property real guideY: -1
	readonly property real pictureWidth: canvas.width
	readonly property real pictureHeight: canvas.height
	// the zones already shown, they come in only once
	property var seen: ({})
	// several chosen zones moved together: the step so far (fractions), or null
	property var shift: null
	// the zone the menu is for
	property string menuFor: ""

	function reload() {
		picture.source = "";
		picture.source = root.page.picture ? `file://${root.page.picture}?${Mouse.hudPictureRev}` : "";
	}

	// the nearest edge of the others (or the middle, or the frame) within a
	// few pixels: [delta, line] for edges a, b, c of the moved box
	function snap(edges, axis, skip) {
		const size = axis === "x" ? canvas.width : canvas.height;
		const reach = 7 / Math.max(1, size);
		const lines = [0, 0.5, 1];
		const skips = Array.isArray(skip) ? skip : [skip];
		for (const z of root.page.zones) {
			if (skips.includes(z.id)) continue;
			if (axis === "x") lines.push(z.x, z.x + z.w, z.x + z.w / 2);
			else lines.push(z.y, z.y + z.h, z.y + z.h / 2);
		}
		let best = null;
		for (const e of edges) {
			for (const l of lines) {
				const d = l - e;
				if (Math.abs(d) <= reach && (!best || Math.abs(d) < Math.abs(best[0]))) best = [d, l];
			}
		}
		return best;
	}

	radius: Theme.radius.huge
	color: Theme.layer1
	clip: true

	// a tool of the bar over the picture
	component Tool: Clickable {
		id: tool

		property bool shown: true
		property string icon: ""
		property string label: ""
		property string tip: ""
		property bool on: false

		visible: tool.shown
		implicitHeight: 28
		implicitWidth: toolRow.implicitWidth + 20
		radius: 14
		color: tool.on ? Theme.primary : "transparent"
		tint: tool.on ? Theme.onPrimary : Theme.text

		Behavior on color {
			ColorAnim {}
		}

		RowLayout {
			id: toolRow

			anchors.centerIn: parent
			spacing: 6

			Glyph {
				icon: tool.icon
				size: 15
				color: tool.on ? Theme.onPrimary : Theme.textMuted
			}

			StyledText {
				text: tool.label
				font.pixelSize: Theme.size.label
				font.weight: Font.Medium
				tone: tool.on ? Theme.onPrimary : Theme.text
			}
		}

		Tip {
			below: true
			text: tool.tip
		}
	}

	Connections {
		target: root.page

		function onPictureChanged() {
			root.reload();
		}
	}

	Connections {
		target: Mouse

		function onHudPictureRevChanged() {
			root.reload();
		}
	}

	Component.onCompleted: root.reload()

	// ── the top: live state, tools ───────────────────────────────────────
	RowLayout {
		anchors.left: parent.left
		anchors.right: parent.right
		anchors.top: parent.top
		anchors.leftMargin: root.pad + 2
		anchors.rightMargin: root.pad
		height: root.head
		spacing: 8

		// live: which scenes the game shows now
		Rectangle {
			Layout.preferredHeight: 30
			Layout.preferredWidth: liveRow.implicitWidth + 22
			radius: 15
			color: root.page.liveScenes.length > 0 ? Theme.primarySoft : Theme.layer2

			Behavior on color {
				ColorAnim {}
			}
			Behavior on Layout.preferredWidth {
				SpatialAnim {
					duration: Motion.medium
				}
			}

			RowLayout {
				id: liveRow

				anchors.centerIn: parent
				spacing: 7

				Item {
					Layout.preferredWidth: 10
					Layout.preferredHeight: 10

					Rectangle {
						anchors.centerIn: parent
						width: 8
						height: 8
						radius: 4
						color: root.page.watching ? Theme.primary : Theme.textFaint
					}

					// a ripple while watching
					Rectangle {
						id: ripple

						anchors.centerIn: parent
						width: 8
						height: 8
						radius: 4
						color: "transparent"
						border.width: 1.5
						border.color: Theme.primary
						visible: root.page.watching

						SequentialAnimation on scale {
							running: root.page.watching
							loops: Animation.Infinite

							NumberAnimation {
								from: 1
								to: 2.6
								duration: 1300
								easing.type: Easing.OutCubic
							}
						}
						SequentialAnimation on opacity {
							running: root.page.watching
							loops: Animation.Infinite

							NumberAnimation {
								from: 0.9
								to: 0
								duration: 1300
								easing.type: Easing.OutCubic
							}
						}
					}
				}

				StyledText {
					text: !root.page.watching ? (root.page.game !== "" ? "Paused" : "No game") : (root.page.liveScenes.length > 0 ? root.page.liveScenes.map(id => root.page.sceneName(id)).join(" + ") : "Nothing recognised")
					font.pixelSize: Theme.size.label
					font.weight: Font.DemiBold
					tone: root.page.liveScenes.length > 0 ? Theme.primary : Theme.textMuted
				}
			}

			Tip {
				below: true
				text: !root.page.watching ? "The picture is watched while the game has the focus" : (Mouse.eyes?.pointer === false ? "No pointer from this game: clicks and hovers stay quiet" : `${Mouse.eyes?.frames ?? 0} frames · ${Mouse.eyes?.seen?.zone ?? 0} pulses`)
			}
		}

		Item {
			Layout.fillWidth: true
		}

		// suggestions: add them all
		TextButton {
			visible: root.page.suggesting && root.page.suggested.length > 0
			text: `Add all ${root.page.suggested.length}`
			icon: "plus"
			variant: "tonal"
			onActivated: root.page.takeSuggestions()
		}

		// the tools, in one pill
		Rectangle {
			Layout.preferredHeight: 34
			Layout.preferredWidth: tools.implicitWidth + 8
			radius: 17
			color: Theme.layer2

			RowLayout {
				id: tools

				anchors.centerIn: parent
				spacing: 2

				Tool {
					shown: root.page.picture !== ""
					icon: "auto_fix"
					label: root.page.guessing ? "Looking…" : "Find zones"
					tip: "Mark what looks like HUD"
					on: root.page.suggesting
					onClicked: root.page.tool("suggest")
				}

				Tool {
					shown: root.page.zones.length > 1
					icon: "select_drag"
					label: root.page.multi.length > 1 ? `${root.page.multi.length} chosen` : "Pick several"
					tip: "Drag around zones to choose them together · Shift+click adds one · Ctrl+A all"
					on: root.page.picking
					onClicked: root.page.picking = !root.page.picking
				}

				Tool {
					shown: root.page.window > 0
					icon: "camera_outline"
					label: root.page.shooting ? "Taking…" : (root.page.picture !== "" ? "Retake" : "Take picture")
					tip: "A new picture of the game's window"
					onClicked: root.page.tool("shoot")
				}

				Tool {
					shown: root.page.window > 0 && Plugins.on("screenshot")
					icon: "selection_drag"
					label: "On screen"
					tip: "Draw zones on the game itself"
					onClicked: root.page.tool("screen")
				}
			}
		}
	}

	// ── the picture ──────────────────────────────────────────────────────
	Item {
		id: canvas

		readonly property real cw: Math.min(root.availW, root.availH / root.ratio)

		x: Math.round((root.width - canvas.cw) / 2)
		y: Math.round(root.head + (root.availH - canvas.cw * root.ratio) / 2)
		width: Math.round(canvas.cw)
		height: Math.round(canvas.cw * root.ratio)

		// a shadow under the picture
		Rectangle {
			anchors.fill: parent
			anchors.margins: -1
			radius: 4
			color: "transparent"
			border.width: 1
			border.color: Theme.outline
		}

		Rectangle {
			anchors.fill: parent
			color: Theme.layer2
			visible: !root.ready
			radius: 6
		}

		Image {
			id: picture

			anchors.fill: parent
			fillMode: Image.Stretch
			cache: false
			asynchronous: true
			smooth: true
			opacity: root.ready ? 1 : 0
			scale: root.ready ? 1 : 1.03
			onStatusChanged: if (status === Image.Ready) root.page.pictureReady()

			Behavior on opacity {
				Anim {
					duration: Motion.long
				}
			}
			Behavior on scale {
				SpatialAnim {
					duration: Motion.extraLong
				}
			}
		}

		// no picture: take one
		ColumnLayout {
			anchors.centerIn: parent
			visible: !root.ready
			spacing: 12

			Glyph {
				Layout.alignment: Qt.AlignHCenter
				icon: root.page.shooting ? "camera_timer" : "image_off_outline"
				size: 40
				color: Theme.textFaint
			}

			StyledText {
				Layout.alignment: Qt.AlignHCenter
				text: root.page.window > 0 ? (root.page.shooting ? "Taking a picture…" : "No picture of this scene") : "Start a game to see it here"
				tone: Theme.textMuted
				font.pixelSize: Theme.size.title
				font.weight: Font.DemiBold
			}

			TextButton {
				Layout.alignment: Qt.AlignHCenter
				visible: root.page.window > 0 && !root.page.shooting
				text: "Take a picture"
				icon: "camera_outline"
				variant: "filled"
				onActivated: root.page.shoot()
			}
		}

		// drawing: drag a box, or click one found on the picture
		MouseArea {
			id: drawer

			property real sx: 0
			property real sy: 0
			property real ex: 0
			property real ey: 0
			readonly property bool drawing: pressed && !drawer.lasso && (Math.abs(ex - sx) >= 4 || Math.abs(ey - sy) >= 4)
			// picking zones by a box around them instead of drawing one
			property bool lasso: false
			readonly property var found: containsMouse && !pressed && !root.page.carry ? root.page.boxAt(mouseX / Math.max(1, width), mouseY / Math.max(1, height)) : null

			anchors.fill: parent
			cursorShape: drawCursor.visible ? Qt.BlankCursor : (root.page.picking ? Qt.ArrowCursor : Qt.CrossCursor)
			hoverEnabled: true
			acceptedButtons: Qt.LeftButton
			onPressed: mouse => {
				root.page.takeFocus();
				drawer.lasso = root.page.picking || !!(mouse.modifiers & (Qt.ShiftModifier | Qt.ControlModifier));
				drawer.sx = drawer.ex = Math.max(0, Math.min(width, mouse.x));
				drawer.sy = drawer.ey = Math.max(0, Math.min(height, mouse.y));
			}
			onPositionChanged: mouse => {
				if (!drawer.pressed) return;
				drawer.ex = Math.max(0, Math.min(width, mouse.x));
				drawer.ey = Math.max(0, Math.min(height, mouse.y));
			}

			// zones are drawn with the cursor theme's crosshair: the size of
			// the box beside it, a selection mark while boxing zones in, a
			// plus over a box the picture offers
			PshellCursor {
				id: drawCursor

				visible: drawer.containsMouse && !root.page.carry && !(root.page.picking && !drawer.pressed) && CursorStyle.ready
				x: drawer.mouseX
				y: drawer.mouseY
				shape: "cross"

				CursorBadge {
					readonly property bool sizing: drawer.drawing
					visible: sizing || (drawer.pressed && drawer.lasso) || drawer.found !== null
					x: 9 * CursorStyle.unit
					y: 9 * CursorStyle.unit
					icon: sizing ? "" : (drawer.lasso ? "selection_drag" : "plus")
					text: sizing ? root.page.pixels(band.width / Math.max(1, canvas.width), band.height / Math.max(1, canvas.height)) : ""
				}
			}
			onReleased: {
				const x0 = Math.min(drawer.sx, drawer.ex), x1 = Math.max(drawer.sx, drawer.ex);
				const y0 = Math.min(drawer.sy, drawer.ey), y1 = Math.max(drawer.sy, drawer.ey);
				if (drawer.lasso) {
					drawer.lasso = false;
					const fx0 = x0 / width, fx1 = x1 / width, fy0 = y0 / height, fy1 = y1 / height;
					const hit = root.page.zones.filter(z => z.x < fx1 && z.x + z.w > fx0 && z.y < fy1 && z.y + z.h > fy0).map(z => z.id);
					if (x1 - x0 < 4 && y1 - y0 < 4) return;
					root.page.selectMany(root.page.chosenIds.concat(hit));
					return;
				}
				if (x1 - x0 < 6 || y1 - y0 < 6) {
					const best = root.page.boxAt(x0 / Math.max(1, width), y0 / Math.max(1, height));
					if (best) root.page.add({ x: best[0], y: best[1], w: best[2], h: best[3] });
					else root.page.select("");
					return;
				}
				root.page.add({ x: x0 / width, y: y0 / height, w: (x1 - x0) / width, h: (y1 - y0) / height });
			}
		}

		// the box found under the pointer
		Rectangle {
			visible: !!drawer.found && !drawer.drawing
			x: (drawer.found?.[0] ?? 0) * canvas.width
			y: (drawer.found?.[1] ?? 0) * canvas.height
			width: (drawer.found?.[2] ?? 0) * canvas.width
			height: (drawer.found?.[3] ?? 0) * canvas.height
			color: Qt.alpha(Theme.primary, 0.12)
			border.width: 1.5
			border.color: Qt.alpha(Theme.primary, 0.8)
			radius: 4

			Behavior on x {
				SpatialAnim {
					duration: Motion.short
				}
			}
			Behavior on y {
				SpatialAnim {
					duration: Motion.short
				}
			}
			Behavior on width {
				SpatialAnim {
					duration: Motion.short
				}
			}
			Behavior on height {
				SpatialAnim {
					duration: Motion.short
				}
			}

			Glyph {
				anchors.centerIn: parent
				icon: "plus"
				size: Math.min(22, parent.height * 0.6)
				color: Theme.primary
				visible: parent.height > 14
			}
		}

		// nothing drawn yet
		Rectangle {
			anchors.centerIn: parent
			visible: root.ready && root.page.zones.length === 0 && !drawer.drawing
			width: emptyRow.implicitWidth + 32
			height: 44
			radius: 22
			color: Qt.alpha(Theme.base, 0.78)
			opacity: drawer.containsMouse ? 0.55 : 1

			Behavior on opacity {
				Anim {}
			}

			RowLayout {
				id: emptyRow

				anchors.centerIn: parent
				spacing: 10

				Glyph {
					icon: "selection_drag"
					size: 20
					color: Theme.primary
				}

				StyledText {
					text: "Drag over the HUD to make a zone"
					font.weight: Font.DemiBold
				}
			}
		}

		// the box zones are picked by
		Rectangle {
			visible: drawer.pressed && drawer.lasso
			x: Math.min(drawer.sx, drawer.ex)
			y: Math.min(drawer.sy, drawer.ey)
			width: Math.abs(drawer.ex - drawer.sx)
			height: Math.abs(drawer.ey - drawer.sy)
			color: Qt.alpha(Theme.secondary, 0.14)
			border.width: 1.5
			border.color: Theme.secondary
			radius: 4
			z: 8
		}

		// the box being drawn, with its size
		Rectangle {
			id: band

			visible: drawer.drawing
			x: Math.min(drawer.sx, drawer.ex)
			y: Math.min(drawer.sy, drawer.ey)
			width: Math.abs(drawer.ex - drawer.sx)
			height: Math.abs(drawer.ey - drawer.sy)
			color: Qt.alpha(Theme.primary, 0.18)
			border.width: 1.5
			border.color: Theme.primary
			radius: 4

			SizeTag {
				// the size rides on the cursor while it is drawn
				visible: !drawCursor.visible
				anchors.top: parent.bottom
				anchors.right: parent.right
				anchors.topMargin: 6
				text: root.page.pixels(band.width / Math.max(1, canvas.width), band.height / Math.max(1, canvas.height))
			}
		}

		// suggestions: a click takes one
		Repeater {
			model: root.page.suggesting ? root.page.suggested : []

			delegate: Rectangle {
				id: hint

				required property var modelData
				required property int index

				x: hint.modelData.x * canvas.width
				y: hint.modelData.y * canvas.height
				width: Math.max(4, hint.modelData.w * canvas.width)
				height: Math.max(4, hint.modelData.h * canvas.height)
				color: Qt.alpha(Theme.tertiary, hintArea.containsMouse ? 0.28 : 0.1)
				border.width: 1.5
				border.color: Theme.tertiary
				radius: 4
				opacity: 0
				scale: 0.8
				Component.onCompleted: hintIn.start()

				Behavior on color {
					ColorAnim {}
				}

				SequentialAnimation {
					id: hintIn

					PauseAnimation {
						duration: hint.index * 35
					}
					ParallelAnimation {
						NumberAnimation {
							target: hint
							property: "opacity"
							to: 1
							duration: Motion.medium
						}
						NumberAnimation {
							target: hint
							property: "scale"
							to: 1
							duration: Motion.long
							easing.type: Easing.BezierSpline
							easing.bezierCurve: Motion.spatial
						}
					}
				}

				MouseArea {
					id: hintArea

					anchors.fill: parent
					hoverEnabled: true
					cursorShape: Qt.PointingHandCursor
					onClicked: root.page.takeSuggestion(hint.modelData)
				}

				Glyph {
					anchors.centerIn: parent
					icon: "plus_circle"
					size: Math.min(24, parent.height * 0.7)
					color: Theme.tertiary
					visible: parent.height > 14
					scale: hintArea.containsMouse ? 1.2 : 1

					Behavior on scale {
						SpatialAnim {
							duration: Motion.short
						}
					}
				}
			}
		}

		// the rest of the picture dims while a zone is chosen
		Item {
			id: spotlight

			readonly property var zone: root.page.zone && root.page.multi.length < 2 && root.page.zones.some(z => z.id === root.page.selected) ? root.page.zone : null
			readonly property real zx: (spotlight.zone?.x ?? 0) * canvas.width
			readonly property real zy: (spotlight.zone?.y ?? 0) * canvas.height
			readonly property real zw: (spotlight.zone?.w ?? 0) * canvas.width
			readonly property real zh: (spotlight.zone?.h ?? 0) * canvas.height

			anchors.fill: parent
			opacity: spotlight.zone && !root.page.carry ? 1 : 0
			visible: opacity > 0.01

			Behavior on opacity {
				Anim {
					duration: Motion.long
				}
			}

			Repeater {
				model: [[0, 0, canvas.width, spotlight.zy], [0, spotlight.zy + spotlight.zh, canvas.width, canvas.height - spotlight.zy - spotlight.zh], [0, spotlight.zy, spotlight.zx, spotlight.zh], [spotlight.zx + spotlight.zw, spotlight.zy, canvas.width - spotlight.zx - spotlight.zw, spotlight.zh]]

				delegate: Rectangle {
					required property var modelData

					x: modelData[0]
					y: modelData[1]
					width: Math.max(0, modelData[2])
					height: Math.max(0, modelData[3])
					color: Qt.rgba(0, 0, 0, 0.28)
				}
			}
		}

		// guides the moved zone snapped to
		Rectangle {
			visible: root.guideX >= 0
			x: root.guideX * canvas.width
			width: 1
			height: canvas.height
			color: Theme.tertiary
			z: 9
		}

		Rectangle {
			visible: root.guideY >= 0
			y: root.guideY * canvas.height
			height: 1
			width: canvas.width
			color: Theme.tertiary
			z: 9
		}

		// ── the zones ──
		Repeater {
			// by count, so a change to one zone does not make them all anew
			model: root.page.zones.length

			delegate: Item {
				id: box

				required property int index
				readonly property var modelData: root.page.zones[box.index] ?? ({ id: "", x: 0, y: 0, w: 0, h: 0 })

				readonly property string zoneId: box.modelData.id
				readonly property bool chosen: root.page.isChosen(box.zoneId)
				// chosen alone: it has handles
				readonly property bool single: box.chosen && root.page.multi.length < 2
				// linked with the chosen one, or in a group at all
				readonly property bool mate: !box.chosen && !!box.modelData.group && box.modelData.group === (root.page.zone?.group ?? "")
				readonly property bool shifted: box.chosen && root.shift !== null
				readonly property bool pointed: root.page.pointed === box.zoneId || boxHover.hovered
				readonly property var values: root.page.live[box.zoneId] ?? null
				// how much it is changing now, 0..1
				readonly property real heat: box.values ? Math.max(0, Math.min(1, Math.max(box.values[0], Math.abs(box.values[1]), Math.abs(box.values[2])) / 40)) : 0
				readonly property bool asleep: root.page.watching && !root.page.zoneAwake(box.modelData)
				readonly property bool target: drop.containsDrag && root.page.carry !== null
				readonly property var triggers: Mouse.hudTriggers(box.modelData).filter(t => t.on !== false)
				// while moved or sized: the box as it is dragged (fractions)
				property var drag: null
				readonly property real fx: box.drag ? box.drag.x : box.modelData.x + (box.shifted ? root.shift.dx : 0)
				readonly property real fy: box.drag ? box.drag.y : box.modelData.y + (box.shifted ? root.shift.dy : 0)
				readonly property real fw: box.drag ? box.drag.w : box.modelData.w
				readonly property real fh: box.drag ? box.drag.h : box.modelData.h

				function commit() {
					root.guideX = -1;
					root.guideY = -1;
					if (!box.drag) return;
					const d = box.drag;
					box.drag = null;
					const r = v => Math.round(v * 10000) / 10000;
					Mouse.hudChangeZone(box.zoneId, { x: r(d.x), y: r(d.y), w: r(d.w), h: r(d.h) });
				}

				x: box.fx * canvas.width
				y: box.fy * canvas.height
				width: Math.max(6, box.fw * canvas.width)
				height: Math.max(6, box.fh * canvas.height)
				z: box.chosen ? 5 : (box.pointed ? 4 : 3)
				opacity: root.seen[box.zoneId] ? 1 : 0
				scale: root.seen[box.zoneId] ? 1 : 0.6
				Component.onCompleted: {
					if (root.seen[box.zoneId]) return;
					boxIn.start();
					root.seen[box.zoneId] = true;
				}

				Behavior on x {
					enabled: !box.drag && !box.shifted
					SpatialAnim {
						duration: Motion.medium
					}
				}
				Behavior on y {
					enabled: !box.drag && !box.shifted
					SpatialAnim {
						duration: Motion.medium
					}
				}
				Behavior on width {
					enabled: !box.drag && !box.shifted
					SpatialAnim {
						duration: Motion.medium
					}
				}
				Behavior on height {
					enabled: !box.drag && !box.shifted
					SpatialAnim {
						duration: Motion.medium
					}
				}

				SequentialAnimation {
					id: boxIn

					PauseAnimation {
						duration: Math.min(box.index, 10) * 30
					}
					ParallelAnimation {
						NumberAnimation {
							target: box
							property: "opacity"
							to: 1
							duration: Motion.short
						}
						NumberAnimation {
							target: box
							property: "scale"
							to: 1
							duration: Motion.long
							easing.type: Easing.BezierSpline
							easing.bezierCurve: Motion.spatialFast
						}
					}
				}

				HoverHandler {
					id: boxHover
				}

				// the glow around the chosen one
				Rectangle {
					anchors.fill: parent
					anchors.margins: -5
					radius: 9
					color: "transparent"
					border.width: 3
					border.color: Qt.alpha(Theme.primary, 0.3)
					opacity: box.chosen ? 1 : 0

					Behavior on opacity {
						Anim {}
					}
				}

				Rectangle {
					id: face

					anchors.fill: parent
					radius: 5
					scale: box.target ? 1.05 : 1
					color: {
						if (root.page.fired === box.zoneId) return Qt.alpha(Theme.primary, 0.6);
						if (box.target) return Qt.alpha(Theme.primary, 0.38);
						const base = box.chosen ? Theme.primary : Theme.text;
						return Qt.alpha(base, (box.chosen ? 0.14 : (box.pointed ? 0.14 : 0.06)) + box.heat * 0.45);
					}
					border.width: box.chosen || box.target ? 2 : 1.5
					border.color: box.chosen || box.target ? Theme.primary : (box.mate ? Theme.secondary : Qt.alpha(Theme.text, box.pointed ? 0.95 : (box.asleep ? 0.3 : 0.65)))

					Behavior on color {
						ColorAnim {
							duration: 120
						}
					}
					Behavior on scale {
						SpatialAnim {
							duration: Motion.medium
						}
					}

					// a ring flies off when it fires
					Rectangle {
						id: ring

						anchors.fill: parent
						radius: 5
						color: "transparent"
						border.width: 2
						border.color: Theme.primary
						opacity: 0

						Connections {
							target: root.page

							function onFiredChanged() {
								if (root.page.fired === box.zoneId) ringOut.restart();
							}
						}

						ParallelAnimation {
							id: ringOut

							NumberAnimation {
								target: ring
								property: "scale"
								from: 1
								to: 1.4
								duration: Motion.extraLong
								easing.type: Easing.OutCubic
							}
							NumberAnimation {
								target: ring
								property: "opacity"
								from: 0.9
								to: 0
								duration: Motion.extraLong
								easing.type: Easing.OutCubic
							}
						}
					}

					// a burst when something is dropped on it
					Rectangle {
						id: burst

						anchors.centerIn: parent
						width: Math.min(parent.width, parent.height)
						height: width
						radius: width / 2
						color: Theme.primary
						opacity: 0

						Connections {
							target: root.page

							function onLanded(kind, id) {
								if (kind === "zone" && id === box.zoneId) burstOut.restart();
							}
						}

						ParallelAnimation {
							id: burstOut

							NumberAnimation {
								target: burst
								property: "scale"
								from: 0.2
								to: 2.2
								duration: Motion.extraLong
								easing.type: Easing.OutCubic
							}
							NumberAnimation {
								target: burst
								property: "opacity"
								from: 0.55
								to: 0
								duration: Motion.extraLong
								easing.type: Easing.OutCubic
							}
						}
					}
				}

				DropArea {
					id: drop

					anchors.fill: parent
					anchors.margins: -4
					keys: ["hud"]
					onDropped: root.page.dropOn("zone", box.zoneId, -1)
				}

				// move it (snapping to the others)
				MouseArea {
					id: mover

					property real px: 0
					property real py: 0
					property bool moved: false

					anchors.fill: parent
					anchors.margins: Math.min(6, Math.min(parent.width, parent.height) / 4)
					acceptedButtons: Qt.LeftButton | Qt.RightButton
					cursorShape: mover.moved ? Qt.ClosedHandCursor : (box.chosen ? Qt.OpenHandCursor : Qt.PointingHandCursor)
					property bool toggled: false

					onPressed: mouse => {
						root.page.takeFocus();
						mover.px = mouse.x;
						mover.py = mouse.y;
						mover.moved = false;
						mover.toggled = false;
						// Ctrl/Shift: one more (or one less) of the chosen
						if (mouse.button === Qt.LeftButton && (mouse.modifiers & (Qt.ShiftModifier | Qt.ControlModifier))) {
							mover.toggled = true;
							root.page.toggle(box.zoneId);
							return;
						}
						if (!box.chosen) root.page.select(box.zoneId);
						if (mouse.button === Qt.RightButton) {
							const p = mover.mapToItem(canvas, mouse.x, mouse.y);
							root.menuFor = box.zoneId;
							menu.x = p.x;
							menu.y = p.y + 6;
							menu.open();
						}
					}
					onPositionChanged: mouse => {
						if (!mover.pressed || mover.toggled || !(mover.pressedButtons & Qt.LeftButton)) return;
						let dx = (mouse.x - mover.px) / canvas.width, dy = (mouse.y - mover.py) / canvas.height;
						if (!mover.moved && Math.abs(dx) * canvas.width < 3 && Math.abs(dy) * canvas.height < 3) return;
						mover.moved = true;
						// the chosen ones together, all kept inside, the pressed one snapping
						if (root.page.multi.length > 1 && box.chosen) {
							const ids = root.page.multi;
							const all = root.page.allZones.filter(z => ids.includes(z.id));
							const lox = Math.max(...all.map(z => -z.x)), hix = Math.min(...all.map(z => 1 - z.x - z.w));
							const loy = Math.max(...all.map(z => -z.y)), hiy = Math.min(...all.map(z => 1 - z.y - z.h));
							const m = box.modelData;
							const free = mouse.modifiers & Qt.AltModifier;
							const sx = free ? null : root.snap([m.x + dx, m.x + m.w + dx, m.x + m.w / 2 + dx], "x", ids);
							const sy = free ? null : root.snap([m.y + dy, m.y + m.h + dy, m.y + m.h / 2 + dy], "y", ids);
							if (sx) dx += sx[0];
							if (sy) dy += sy[0];
							root.guideX = sx ? sx[1] : -1;
							root.guideY = sy ? sy[1] : -1;
							root.shift = { dx: Math.max(lox, Math.min(hix, dx)), dy: Math.max(loy, Math.min(hiy, dy)) };
							return;
						}
						const w = box.modelData.w, h = box.modelData.h;
						let x = Math.max(0, Math.min(1 - w, box.modelData.x + dx));
						let y = Math.max(0, Math.min(1 - h, box.modelData.y + dy));
						const sx = (mouse.modifiers & Qt.AltModifier) ? null : root.snap([x, x + w, x + w / 2], "x", box.zoneId);
						const sy = (mouse.modifiers & Qt.AltModifier) ? null : root.snap([y, y + h, y + h / 2], "y", box.zoneId);
						if (sx) x = Math.max(0, Math.min(1 - w, x + sx[0]));
						if (sy) y = Math.max(0, Math.min(1 - h, y + sy[0]));
						root.guideX = sx ? sx[1] : -1;
						root.guideY = sy ? sy[1] : -1;
						box.drag = { x, y, w, h };
					}
					onReleased: {
						if (root.shift) {
							const step = root.shift;
							Mouse.hudMoveZones(root.page.multi, step.dx, step.dy);
							root.shift = null;
							root.guideX = -1;
							root.guideY = -1;
						}
						box.commit();
						mover.moved = false;
					}
					onDoubleClicked: mouse => {
						if (mouse.button === Qt.LeftButton) root.page.renameZone(box.zoneId);
					}

					// a magnet beside the hand while the zone snaps to another
					PshellCursor {
						visible: mover.moved && (root.guideX >= 0 || root.guideY >= 0) && CursorStyle.ready
						x: mover.mouseX
						y: mover.mouseY
						z: 20
						shape: ""

						CursorBadge {
							icon: "magnet"
						}
					}
				}

				// size it by an edge or a corner
				Repeater {
					model: box.single ? [{ h: "l", v: "t" }, { h: "c", v: "t" }, { h: "r", v: "t" }, { h: "r", v: "c" }, { h: "r", v: "b" }, { h: "c", v: "b" }, { h: "l", v: "b" }, { h: "l", v: "c" }] : []

					delegate: Rectangle {
						id: handle

						required property var modelData
						required property int index
						readonly property bool corner: handle.modelData.h !== "c" && handle.modelData.v !== "c"

						width: handle.corner ? 11 : (handle.modelData.h === "c" ? 16 : 6)
						height: handle.corner ? 11 : (handle.modelData.v === "c" ? 16 : 6)
						radius: Math.min(width, height) / 2
						x: (handle.modelData.h === "l" ? 0 : (handle.modelData.h === "r" ? box.width : box.width / 2)) - width / 2
						y: (handle.modelData.v === "t" ? 0 : (handle.modelData.v === "b" ? box.height : box.height / 2)) - height / 2
						visible: handle.corner || (box.width > 40 && box.height > 30)
						color: Theme.primary
						border.width: 2
						border.color: Theme.base
						property real appear: 0
						property real grow: handleArea.pressed ? 1.45 : (handleArea.containsMouse ? 1.25 : 1)

						scale: handle.appear * handle.grow
						Component.onCompleted: handleIn.start()

						Behavior on grow {
							SpatialAnim {
								duration: Motion.short
							}
						}

						NumberAnimation {
							id: handleIn

							target: handle
							property: "appear"
							to: 1
							duration: Motion.long
							easing.type: Easing.BezierSpline
							easing.bezierCurve: Motion.spatialFast
						}


						MouseArea {
							id: handleArea

							property real ox: 0
							property real oy: 0

							anchors.fill: parent
							anchors.margins: -7
							hoverEnabled: true
							preventStealing: true
							cursorShape: {
								if (handle.modelData.h === "c") return Qt.SizeVerCursor;
								if (handle.modelData.v === "c") return Qt.SizeHorCursor;
								return (handle.modelData.h === "l") === (handle.modelData.v === "t") ? Qt.SizeFDiagCursor : Qt.SizeBDiagCursor;
							}
							onPressed: mouse => {
								const p = handleArea.mapToItem(canvas, mouse.x, mouse.y);
								handleArea.ox = p.x;
								handleArea.oy = p.y;
							}
							onPositionChanged: mouse => {
								if (!handleArea.pressed) return;
								const p = handleArea.mapToItem(canvas, mouse.x, mouse.y);
								const dx = (p.x - handleArea.ox) / canvas.width, dy = (p.y - handleArea.oy) / canvas.height;
								const m = box.modelData, least = 0.006;
								let x0 = m.x, y0 = m.y, x1 = m.x + m.w, y1 = m.y + m.h;
								const free = (mouse.modifiers & Qt.AltModifier);
								let gx = -1, gy = -1;
								if (handle.modelData.h === "l") {
									x0 = Math.max(0, Math.min(x1 - least, x0 + dx));
									const s = free ? null : root.snap([x0], "x", box.zoneId);
									if (s) { x0 = Math.min(x1 - least, x0 + s[0]); gx = s[1]; }
								} else if (handle.modelData.h === "r") {
									x1 = Math.min(1, Math.max(x0 + least, x1 + dx));
									const s = free ? null : root.snap([x1], "x", box.zoneId);
									if (s) { x1 = Math.max(x0 + least, x1 + s[0]); gx = s[1]; }
								}
								if (handle.modelData.v === "t") {
									y0 = Math.max(0, Math.min(y1 - least, y0 + dy));
									const s = free ? null : root.snap([y0], "y", box.zoneId);
									if (s) { y0 = Math.min(y1 - least, y0 + s[0]); gy = s[1]; }
								} else if (handle.modelData.v === "b") {
									y1 = Math.min(1, Math.max(y0 + least, y1 + dy));
									const s = free ? null : root.snap([y1], "y", box.zoneId);
									if (s) { y1 = Math.max(y0 + least, y1 + s[0]); gy = s[1]; }
								}
								root.guideX = gx;
								root.guideY = gy;
								box.drag = { x: x0, y: y0, w: x1 - x0, h: y1 - y0 };
							}
							onReleased: box.commit()
						}
					}
				}

				// its name and what it reacts to; below it when there is no room above
				Rectangle {
					id: tag

					readonly property bool under: box.y < 26

					x: 0
					y: tag.under ? box.height + 4 : -height - 4
					width: tagRow.implicitWidth + 12
					height: 22
					radius: 6
					color: box.target || box.chosen ? Theme.primary : Qt.alpha(Theme.base, 0.82)
					opacity: box.asleep && !box.chosen && !box.pointed ? 0.6 : 1
					scale: box.target ? 1.08 : 1
					transformOrigin: Item.BottomLeft

					Behavior on color {
						ColorAnim {}
					}
					Behavior on width {
						SpatialAnim {
							duration: Motion.medium
						}
					}
					Behavior on scale {
						SpatialAnim {
							duration: Motion.medium
						}
					}

					RowLayout {
						id: tagRow

						anchors.centerIn: parent
						spacing: 4

						Glyph {
							visible: box.target
							icon: "plus"
							size: 12
							color: Theme.onPrimary
						}

						StyledText {
							text: box.target ? (root.page.carry?.label ?? "") : box.modelData.name
							font.pixelSize: Theme.size.small
							font.weight: Font.DemiBold
							color: box.target || box.chosen ? Theme.onPrimary : Theme.text
						}

						// one icon a reaction
						Repeater {
							model: box.target ? [] : box.triggers

							delegate: Glyph {
								required property var modelData

								icon: root.page.kindOf(modelData.kind).icon
								size: 11
								color: box.chosen ? Theme.onPrimary : root.page.kindColor(modelData.kind)
							}
						}

						Glyph {
							visible: !!box.modelData.group && !box.target
							icon: "link_variant"
							size: 11
							color: box.chosen ? Theme.onPrimary : Theme.secondary
						}

						Glyph {
							visible: box.asleep && !box.target
							icon: "sleep"
							size: 11
							color: box.chosen ? Theme.onPrimary : Theme.textFaint
						}
					}
				}

				// the size while it is changed
				SizeTag {
					visible: !!box.drag
					anchors.top: parent.bottom
					anchors.right: parent.right
					anchors.topMargin: tag.under ? 30 : 6
					text: root.page.pixels(box.fw, box.fh)
				}
			}
		}

		// a zone's menu
		PickList {
			id: menu

			width: 230
			current: ""
			entries: {
				const list = [{ value: "rename", label: "Rename", icon: "pencil_outline" }, { value: "duplicate", label: "Duplicate", icon: "content_duplicate", detail: "Ctrl+D" }, { value: "copy", label: "Copy reactions", icon: "content_copy", detail: "Ctrl+C" }];
				if (Mouse.hudClipboard.length > 0) list.push({ value: "paste", label: `Paste ${Mouse.hudClipboard.length} reaction${Mouse.hudClipboard.length === 1 ? "" : "s"}`, icon: "content_paste", detail: "Ctrl+V" });
				list.push({ value: "keep", label: "Keep as sequence", icon: "bookmark_plus_outline" });
				list.push({ value: "delete", label: "Delete", icon: "delete_outline", detail: "Del" });
				return list;
			}
			onPicked: value => root.page.zoneAction(root.menuFor, String(value))
		}
	}
}
