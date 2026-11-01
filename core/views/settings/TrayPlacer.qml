pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.style.theme
import qs.style.widgets
import qs.core.services

// The screens as they stand and every app tray on its edge. The tray being
// edited is carried to any edge of any screen: it snaps to the edge closest
// to the pointer and slides along it (the middle catches it). The tray on
// the desktop moves with it. A click on another tray picks that one.
Item {
	id: root

	property real padding: 22
	readonly property var screens: Quickshell.screens.map(screen => ({ name: String(screen.name), x: screen.x, y: screen.y, w: screen.width, h: screen.height }))
	readonly property var box: {
		if (root.screens.length === 0) return { x: 0, y: 0, w: 1, h: 1 };
		const left = Math.min(...root.screens.map(s => s.x));
		const top = Math.min(...root.screens.map(s => s.y));
		const right = Math.max(...root.screens.map(s => s.x + s.w));
		const bottom = Math.max(...root.screens.map(s => s.y + s.h));
		return { x: left, y: top, w: Math.max(1, right - left), h: Math.max(1, bottom - top) };
	}
	readonly property real factor: Math.min((root.width - root.padding * 2) / root.box.w, (root.height - root.padding * 2) / root.box.h)
	readonly property real offsetX: (root.width - root.box.w * root.factor) / 2
	readonly property real offsetY: (root.height - root.box.h * root.factor) / 2
	// where the carried tray would go: { name, edge, position }
	property var target: null
	readonly property bool carrying: root.target !== null

	implicitWidth: 520
	implicitHeight: 260

	function px(x) {
		return root.offsetX + (x - root.box.x) * root.factor;
	}
	function py(y) {
		return root.offsetY + (y - root.box.y) * root.factor;
	}

	function screenOf(name) {
		return root.screens.find(s => s.name === name) ?? root.screens[0] ?? { name: "", x: 0, y: 0, w: 1, h: 1 };
	}

	// the edge of a screen closest to a point of the picture; near the end
	// of another tray on that edge it snaps to it
	function nearest(x, y) {
		const gx = (x - root.offsetX) / root.factor + root.box.x;
		const gy = (y - root.offsetY) / root.factor + root.box.y;
		let best = null;
		for (const s of root.screens) {
			const cx = Math.max(s.x, Math.min(s.x + s.w, gx));
			const cy = Math.max(s.y, Math.min(s.y + s.h, gy));
			const edges = [
				{ edge: "left", d: Math.hypot(gx - s.x, gy - cy), t: (cy - s.y) / s.h },
				{ edge: "right", d: Math.hypot(gx - s.x - s.w, gy - cy), t: (cy - s.y) / s.h },
				{ edge: "top", d: Math.hypot(gx - cx, gy - s.y), t: (cx - s.x) / s.w },
				{ edge: "bottom", d: Math.hypot(gx - cx, gy - s.y - s.h), t: (cx - s.x) / s.w }
			];
			for (const e of edges)
				if (!best || e.d < best.d) best = { name: s.name, edge: e.edge, position: e.t, d: e.d };
		}
		if (!best) return null;
		let t = Math.max(0, Math.min(1, best.position));
		const snap = root.snapAt(best.name, best.edge, t);
		if (!snap && Math.abs(t - 0.5) < 0.04) t = 0.5;
		return { name: best.name, edge: best.edge, position: Math.round(t * 1000) / 1000, snap: snap };
	}

	// another tray on that edge whose end the carried one is close to (or over)
	function snapAt(name, edge, t) {
		const carried = AppTray.trayById(AppTray.editing);
		if (!carried) return null;
		const along = root.alongOf(name, edge);
		const p = t * along;
		const half = AppTray.lengthOf(carried) * root.factor / 2;
		const reach = 16;
		let found = null;
		for (const other of AppTray.trays) {
			if (other.id === carried.id || AppTray.outputOf(other) !== name || (other.edge ?? "bottom") !== edge) continue;
			if (AppTray.hangsFrom(other, carried.id)) continue;
			const c = AppTray.centerOf(other.id, along, root.factor);
			const l = AppTray.lengthOf(other) * root.factor / 2;
			const gap = Number(AppTray.full(carried).snapGap) * root.factor;
			const after = Math.abs(p - half - gap - (c + l));
			const before = Math.abs(p + half + gap - (c - l));
			const over = p + half > c - l && p - half < c + l;
			const d = Math.min(after, before);
			if ((d < reach || over) && (!found || d < found.d))
				found = { to: other.id, side: (over ? p >= c : after <= before) ? "after" : "before", d: d };
		}
		return found ? { to: found.to, side: found.side } : null;
	}

	// how long an edge is in the picture
	function alongOf(name, edge) {
		const s = root.screenOf(name);
		return edge === "left" || edge === "right" ? s.h * root.factor : s.w * root.factor;
	}

	// a tray as a bar on its edge, in the picture: { x, y, w, h }
	function barOf(tray, override) {
		const t = override ? Object.assign({}, tray, override) : tray;
		const name = AppTray.outputOf(t);
		const edge = t.edge ?? "bottom";
		const s = root.screenOf(name);
		const full = AppTray.full(t);
		const size = Number(full.iconSize) || 48;
		const length = Math.max(10, AppTray.lengthOf(t) * root.factor);
		const thick = Math.max(6, (size * 1.4) * root.factor);
		const along = root.alongOf(name, edge);
		const raw = AppTray.centerOf(t.id, along, root.factor, override ? Object.assign({ id: t.id }, override) : null);
		const center = Math.max(length / 2, Math.min(along - length / 2, raw));
		const inset = 3 + Number(full.gap || 0) * root.factor;
		const sx = root.px(s.x);
		const sy = root.py(s.y);
		const sw = s.w * root.factor;
		const sh = s.h * root.factor;
		switch (edge) {
		case "left": return { x: sx + inset, y: sy + center - length / 2, w: thick, h: length };
		case "right": return { x: sx + sw - inset - thick, y: sy + center - length / 2, w: thick, h: length };
		case "top": return { x: sx + center - length / 2, y: sy + inset, w: length, h: thick };
		default: return { x: sx + center - length / 2, y: sy + sh - inset - thick, w: length, h: thick };
		}
	}

	// the screens
	Repeater {
		model: root.screens

		delegate: Rectangle {
			id: screen

			required property var modelData
			readonly property bool aimed: root.target?.name === screen.modelData.name

			x: root.px(screen.modelData.x) + 2
			y: root.py(screen.modelData.y) + 2
			width: Math.max(10, screen.modelData.w * root.factor - 4)
			height: Math.max(10, screen.modelData.h * root.factor - 4)
			radius: Theme.radius.small
			color: screen.aimed ? Theme.layer3 : Theme.layer2
			border.width: 1
			border.color: screen.aimed ? Qt.alpha(Theme.primary, 0.5) : Theme.outline

			Behavior on color {
				ColorAnim {}
			}

			StyledText {
				anchors.centerIn: parent
				text: screen.modelData.name
				tone: Theme.textSubtle
				font.pixelSize: Theme.size.small
				font.weight: Font.DemiBold
			}

			// the edge the tray would go to
			Rectangle {
				readonly property string edge: screen.aimed ? root.target.edge : ""

				visible: edge !== ""
				x: edge === "right" ? parent.width - 3 : 0
				y: edge === "bottom" ? parent.height - 3 : 0
				width: edge === "left" || edge === "right" ? 3 : parent.width
				height: edge === "top" || edge === "bottom" ? 3 : parent.height
				radius: 1.5
				color: Qt.alpha(Theme.primary, 0.55)
			}
		}
	}

	// every tray
	Repeater {
		model: AppTray.trays

		delegate: Rectangle {
			id: bar

			required property var modelData
			readonly property bool picked: bar.modelData.id === AppTray.editing
			readonly property bool moving: bar.picked && root.carrying
			readonly property var spot: bar.moving
				? root.barOf(bar.modelData, { output: root.target.name, edge: root.target.edge, position: root.target.position, snap: root.target.snap })
				: root.barOf(bar.modelData, null)
			// the tray the carried one would snap to
			readonly property bool snapTarget: root.carrying && root.target?.snap?.to === bar.modelData.id

			x: bar.spot.x
			y: bar.spot.y
			width: bar.spot.w
			height: bar.spot.h
			z: bar.picked ? 2 : 1
			radius: Math.min(width, height) / 2
			color: bar.picked ? Theme.primary : Qt.alpha(Theme.text, barMouse.containsMouse || bar.snapTarget ? 0.5 : 0.3)
			border.width: bar.snapTarget ? 2 : 0
			border.color: Theme.primary
			scale: bar.moving ? 1.08 : 1

			Behavior on x {
				enabled: !bar.moving
				SpatialAnim {
					duration: Motion.medium
				}
			}
			Behavior on y {
				enabled: !bar.moving
				SpatialAnim {
					duration: Motion.medium
				}
			}
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
			Behavior on scale {
				SpatialAnim {
					duration: Motion.medium
				}
			}

			// the icons it holds, as dots
			Grid {
				anchors.centerIn: parent
				readonly property bool vertical: bar.height > bar.width
				columns: vertical ? 1 : Math.max(1, (bar.modelData.items ?? []).length)
				spacing: 3
				visible: Math.min(bar.width, bar.height) >= 8

				Repeater {
					model: Math.min(12, (bar.modelData.items ?? []).length)

					delegate: Rectangle {
						width: 3
						height: 3
						radius: 1.5
						color: bar.picked ? Theme.onPrimary : Theme.base
						opacity: 0.8
					}
				}
			}

			MouseArea {
				id: barMouse

				anchors.fill: parent
				anchors.margins: -6
				hoverEnabled: true
				cursorShape: bar.picked ? (root.carrying ? Qt.ClosedHandCursor : Qt.OpenHandCursor) : Qt.PointingHandCursor
				preventStealing: true
				onPressed: event => {
					if (!bar.picked) {
						AppTray.editing = bar.modelData.id;
						return;
					}
					const p = mapToItem(root, event.x, event.y);
					root.target = root.nearest(p.x, p.y);
				}
				onPositionChanged: event => {
					if (!root.carrying) return;
					const p = mapToItem(root, event.x, event.y);
					root.target = root.nearest(p.x, p.y);
				}
				onReleased: root.drop()
				onCanceled: root.target = null
			}
		}
	}

	// a press on a screen, away from the trays, carries the picked tray there too
	MouseArea {
		anchors.fill: parent
		z: -1
		enabled: AppTray.trayById(AppTray.editing) !== null
		cursorShape: root.carrying ? Qt.ClosedHandCursor : Qt.ArrowCursor
		onPressed: event => root.target = root.nearest(event.x, event.y)
		onPositionChanged: event => {
			if (root.carrying) root.target = root.nearest(event.x, event.y);
		}
		onReleased: root.drop()
		onCanceled: root.target = null
	}

	// the tray on the desktop goes along while it is carried; kept once let go
	onTargetChanged: {
		const target = root.target;
		const tray = AppTray.trayById(AppTray.editing);
		if (!target || !tray) return;
		const snap = target.snap ?? null;
		if (tray.output === target.name && tray.edge === target.edge && tray.position === target.position && JSON.stringify(tray.snap ?? null) === JSON.stringify(snap)) return;
		AppTray.update(AppTray.editing, { output: target.name, edge: target.edge, position: target.position, snap: snap }, true);
	}

	function drop() {
		const target = root.target;
		root.target = null;
		if (!target || !AppTray.trayById(AppTray.editing)) return;
		// snapped: put into the row properly (a tray already there moves over)
		if (target.snap) AppTray.snapTo(AppTray.editing, target.snap.to, target.snap.side);
		else AppTray.save();
	}

	StyledText {
		anchors.centerIn: parent
		visible: root.screens.length === 0
		text: "No screens"
		tone: Theme.textSubtle
	}
}
