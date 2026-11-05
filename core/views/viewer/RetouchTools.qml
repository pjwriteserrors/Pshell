pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Shapes
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "Geometry.js" as Geo
import "Recipe.js" as Recipe

// Taking things out of the picture: what is painted over is filled from
// around it (the helper's `inpaint`). Each stroke is kept in the recipe in
// the source's coordinates, the filled picture in the cache; taking the
// strokes back is one step (undo), or all of them at once.
Item {
	id: root

	required property Item stage
	property real barHeight: bar.height + 24
	// the brush, in pixels of the screen
	property real brush: 36
	property var points: []
	property bool working: false

	readonly property Item slot: root.stage.frontSlot
	readonly property point origin: root.slot ? root.stage.mapToItem(root, root.slot.x, root.slot.y) : Qt.point(0, 0)
	readonly property real k: root.slot ? root.slot.s : 1
	readonly property var strokes: Viewer.recipe.retouch?.strokes ?? []

	// a point of this item → 0..1 of the upright source
	function toSource(x, y) {
		const g = Viewer.recipe.geometry, w = Viewer.info?.width ?? 1, h = Viewer.info?.height ?? 1;
		const [ow, oh] = Geo.outputSize(g, w, h);
		const u = (x - root.origin.x) / root.k / ow, v = (y - root.origin.y) / root.k / oh;
		return Geo.apply(Geo.matrix(g, w, h), u, v);
	}

	function finish() {
		const pts = root.points;
		root.points = [];
		if (pts.length === 0 || root.working) return;
		const w = Viewer.info?.width ?? 1, h = Viewer.info?.height ?? 1;
		const stroke = {
			points: pts.map(p => root.toSource(p.x, p.y)).map(p => [Math.round(p[0] * 10000) / 10000, Math.round(p[1] * 10000) / 10000]),
			// the brush as a share of the source's longer side
			radius: root.brush / 2 / root.k / Math.max(w, h)
		};
		root.apply(root.strokes.concat([stroke]), [stroke]);
	}

	// fills `fresh` on what is there, or everything again from the original
	function apply(all, fresh) {
		const path = Viewer.path;
		const base = Viewer.recipe.retouch?.base;
		const again = !fresh || !base;
		root.working = true;
		Viewer.busy = true;
		Viewer.busyText = "Filling it in…";
		const out = `${Paths.cache}/viewer/retouch/${Qt.md5(path)}-${Date.now()}.${Viewer.info?.alpha ? "png" : "jpg"}`;
		Viewer.request("inpaint", { path: again ? Viewer.shownPath : base, strokes: again ? all : fresh, out: out }, (data, error) => {
			root.working = false;
			Viewer.busy = false;
			if (error) return Viewer.fail(error);
			if (Viewer.path !== path) return;
			const next = Recipe.copy(Viewer.recipe);
			next.retouch = { strokes: all, base: data.path };
			Viewer.commit(next);
		});
	}

	function clearAll() {
		const next = Recipe.copy(Viewer.recipe);
		next.retouch = null;
		Viewer.commit(next);
	}

	// the stroke being painted
	Shape {
		anchors.fill: parent
		preferredRendererType: Shape.CurveRenderer
		visible: root.points.length > 0

		ShapePath {
			strokeColor: Qt.alpha(Theme.primary, 0.55)
			strokeWidth: root.brush
			capStyle: ShapePath.RoundCap
			joinStyle: ShapePath.RoundJoin
			fillColor: "transparent"
			PathPolyline {
				path: root.points
			}
		}
	}

	// the brush under the pointer
	Rectangle {
		x: paint.mouseX - width / 2
		y: paint.mouseY - height / 2
		width: root.brush
		height: root.brush
		radius: width / 2
		color: "transparent"
		border.width: 2
		border.color: "white"
		visible: paint.containsMouse && !root.working
	}

	MouseArea {
		id: paint

		anchors.fill: parent
		anchors.bottomMargin: root.barHeight
		hoverEnabled: true
		cursorShape: Qt.BlankCursor
		enabled: !root.working
		onPressed: event => root.points = [Qt.point(event.x, event.y)]
		onPositionChanged: event => {
			if (!pressed) return;
			const last = root.points[root.points.length - 1];
			if (Math.hypot(event.x - last.x, event.y - last.y) < 3) return;
			root.points = root.points.concat([Qt.point(event.x, event.y)]);
		}
		onReleased: root.finish()
		// the wheel still zooms the picture
		onWheel: wheel => wheel.accepted = false
	}

	Rectangle {
		id: bar

		anchors.horizontalCenter: parent.horizontalCenter
		anchors.bottom: parent.bottom
		anchors.bottomMargin: 12
		width: row.implicitWidth + 32
		height: row.implicitHeight + 24
		radius: Theme.radius.huge
		color: Theme.glass
		border.width: 1
		border.color: Theme.outline

		Row {
			id: row

			anchors.centerIn: parent
			spacing: 12

			StyledText {
				anchors.verticalCenter: parent.verticalCenter
				text: root.working ? "Filling it in…" : "Paint over what should go"
				tone: Theme.textMuted
			}

			TuneSlider {
				width: 200
				label: "Brush"
				icon: "brush"
				from: 0
				to: 1
				value: (root.brush - 8) / 152
				valueText: `${Math.round(root.brush)} px`
				onMoved: value => root.brush = 8 + value * 152
				onCommitted: value => root.brush = 8 + value * 152
			}

			TextButton {
				anchors.verticalCenter: parent.verticalCenter
				text: root.strokes.length > 0 ? `Put back all (${root.strokes.length})` : "Nothing taken out yet"
				icon: "backup_restore"
				variant: "ghost"
				enabled: root.strokes.length > 0
				onActivated: root.clearAll()
			}

			TextButton {
				anchors.verticalCenter: parent.verticalCenter
				text: "Done"
				icon: "check"
				variant: "filled"
				onActivated: Viewer.setMode("view")
			}
		}
	}
}
