pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.style.widgets
import qs.core.services
import qs.core.views.screenshot
import "Geometry.js" as Geo
import "Recipe.js" as Recipe

// Where the picture is: fitted, zoomed (wheel at the pointer, pinch,
// double-click for 100 %), moved by dragging. Two slots: the next picture
// is decoded in the one behind and slides in once it is there, so nothing
// ever flashes empty. The front slot's `content` is the result at full
// size, what a save grabs.
Item {
	id: root

	property real margin: 28
	// the crop being made: the whole straightened picture is shown
	property bool cropless: false
	property bool clipWarning: false
	// the plain picture, pressed and held (before / after)
	property bool original: false
	property bool exporting: false
	// before / after side by side: where the line is (0..1 of the width, 0: off)
	property real split: 0
	property bool markingsShown: true
	readonly property Item exported: root.front ? root.front.content : null
	readonly property Item frontSlot: root.front
	readonly property real zoom: root.front ? root.front.s : 1
	readonly property real fitZoom: root.front ? root.fitOf(root.front) : 1
	readonly property bool fitted: root.front ? root.front.fitted : true
	readonly property bool ready: !!root.front && root.front.develop.ready
	readonly property bool sharp: !!root.front && root.front.develop.sharp
	property bool interacting: false
	signal pointerMoved

	property Item front: slotA
	readonly property Item behind: root.front === slotA ? slotB : slotA
	readonly property int direction: Viewer.direction

	clip: true

	function fitOf(slot) {
		const w = Math.max(1, slot.content.width), h = Math.max(1, slot.content.height);
		return Math.min((root.width - root.margin * 2) / w, (root.height - root.margin * 2) / h, 1);
	}

	function refit(slot, animate) {
		slot.animated = !!animate;
		slot.s = root.fitOf(slot);
		slot.cx = slot.content.width / 2;
		slot.cy = slot.content.height / 2;
		slot.fitted = true;
		slot.animated = true;
	}

	// zoom to `s`, keeping the content point under (px, py) of the stage where it is
	function zoomTo(s, px, py, animate) {
		const f = root.front;
		if (!f) return;
		const fit = root.fitOf(f);
		s = Math.max(Math.min(fit, 0.05), Math.min(32, s));
		if (px === undefined) {
			px = root.width / 2;
			py = root.height / 2;
		}
		// the content point under the pointer now
		const qx = f.cx + (px - root.width / 2) / f.s;
		const qy = f.cy + (py - root.height / 2) / f.s;
		f.animated = animate !== false;
		f.s = s;
		f.cx = qx - (px - root.width / 2) / s;
		f.cy = qy - (py - root.height / 2) / s;
		f.fitted = Math.abs(s - fit) < 1e-3;
		root.clampPan(f);
		f.animated = true;
	}

	function zoomBy(factor, px, py, animate) {
		if (root.front) root.zoomTo(root.front.s * factor, px, py, animate);
	}

	function fit() {
		if (root.front) root.refit(root.front, true);
	}

	function actualSize(px, py) {
		if (!root.front) return;
		if (Math.abs(root.front.s - 1) < 1e-3) root.fit();
		else root.zoomTo(1, px, py);
	}

	// the picture never leaves more of the stage empty than it must
	function clampPan(f) {
		const w = f.content.width * f.s, h = f.content.height * f.s;
		const limit = (size, view, centre, full) => {
			if (size <= view) return full / 2;
			const half = view / 2 / f.s;
			return Math.max(half, Math.min(full - half, centre));
		};
		f.cx = limit(w, root.width, f.cx, f.content.width);
		f.cy = limit(h, root.height, f.cy, f.content.height);
	}

	function panBy(dx, dy) {
		const f = root.front;
		if (!f) return;
		f.animated = false;
		f.cx -= dx / f.s;
		f.cy -= dy / f.s;
		root.clampPan(f);
		f.animated = true;
	}

	// ── a new picture ──────────────────────────────────────────────────────
	property string wanted: Viewer.shownPath
	property var wantedInfo: Viewer.info

	onWantedChanged: root.bring()

	function bring() {
		if (!root.wanted || !root.wantedInfo) return;
		const b = root.behind;
		if (root.front.path === root.wanted && root.front.serial === Viewer.openSerial) {
			root.front.recipe = Qt.binding(() => root.original ? Recipe.blank() : Viewer.recipe);
			return;
		}
		b.recipe = Qt.binding(() => root.original ? Recipe.blank() : Viewer.recipe);
		b.path = root.wanted;
		b.serial = Viewer.openSerial;
		b.sourceWidth = root.wantedInfo.width || 1;
		b.sourceHeight = root.wantedInfo.height || 1;
		b.animatedSource = !!root.wantedInfo.animated;
		b.pending = true;
		if (b.develop.ready || b.movie) root.swap();
	}

	function swap() {
		const old = root.front;
		const next = root.behind;
		if (!next.pending) return;
		next.pending = false;
		old.leaving = true;
		next.leaving = false;
		root.refit(next, false);
		next.enter(root.direction);
		old.leave(root.direction);
		root.front = next;
	}

	component Slot: Item {
		id: slot

		property string path: ""
		property int serial: 0
		property real sourceWidth: 1
		property real sourceHeight: 1
		property bool animatedSource: false
		property bool pending: false
		property bool leaving: false
		readonly property bool isFront: root.front === slot
		// bound to the viewer's while in front, kept as it was once it leaves
		property var recipe: Recipe.blank()
		readonly property bool movie: slot.animatedSource && movieLoader.status === Loader.Ready && movieLoader.item.status === AnimatedImage.Ready
		readonly property alias develop: develop
		readonly property alias content: content
		readonly property Item movieItem: movieLoader.item

		// zoom and the content point in the stage's middle
		property real s: 1
		property real cx: 0
		property real cy: 0
		property bool fitted: true
		property bool animated: true
		// entering and leaving
		property real shift: 0
		property real fade: 1
		property real lift: 1
		// a quarter turn being shown
		property real turn: 0

		visible: slot.fade > 0.001 && (slot.isFront || slot.leaving)
		opacity: slot.fade
		x: root.width / 2 - slot.cx * slot.s + slot.shift
		y: root.height / 2 - slot.cy * slot.s
		width: content.width
		height: content.height
		transformOrigin: Item.TopLeft
		scale: slot.s
		z: slot.isFront ? 1 : 0

		Behavior on s {
			enabled: slot.animated && !root.interacting
			NumberAnimation {
				duration: Motion.long
				easing.type: Easing.BezierSpline
				easing.bezierCurve: Motion.spatial
			}
		}
		Behavior on cx {
			enabled: slot.animated && !root.interacting
			NumberAnimation {
				duration: Motion.long
				easing.type: Easing.BezierSpline
				easing.bezierCurve: Motion.spatial
			}
		}
		Behavior on cy {
			enabled: slot.animated && !root.interacting
			NumberAnimation {
				duration: Motion.long
				easing.type: Easing.BezierSpline
				easing.bezierCurve: Motion.spatial
			}
		}

		function enter(direction) {
			enterAnim.stop();
			leaveAnim.stop();
			slot.shift = direction * 70;
			slot.fade = 0;
			slot.lift = 0.965;
			enterAnim.start();
		}

		function leave(direction) {
			enterAnim.stop();
			leaveAnim.stop();
			leaveAnim.start();
			slot.leaveDirection = direction;
		}

		property int leaveDirection: 1

		ParallelAnimation {
			id: enterAnim

			NumberAnimation {
				target: slot
				property: "shift"
				to: 0
				duration: Motion.long
				easing.type: Easing.BezierSpline
				easing.bezierCurve: Motion.decel
			}
			NumberAnimation {
				target: slot
				property: "fade"
				to: 1
				duration: Motion.medium
				easing.type: Easing.BezierSpline
				easing.bezierCurve: Motion.standard
			}
			NumberAnimation {
				target: slot
				property: "lift"
				to: 1
				duration: Motion.long
				easing.type: Easing.BezierSpline
				easing.bezierCurve: Motion.decel
			}
		}

		SequentialAnimation {
			id: leaveAnim

			ParallelAnimation {
				NumberAnimation {
					target: slot
					property: "shift"
					to: -slot.leaveDirection * 70
					duration: Motion.medium
					easing.type: Easing.BezierSpline
					easing.bezierCurve: Motion.accel
				}
				NumberAnimation {
					target: slot
					property: "fade"
					to: 0
					duration: Motion.medium
					easing.type: Easing.BezierSpline
					easing.bezierCurve: Motion.accel
				}
			}
			ScriptAction {
				script: slot.leaving = false
			}
		}

		NumberAnimation on turn {
			id: turnAnim

			running: false
			to: 0
			duration: Motion.long
			easing.type: Easing.BezierSpline
			easing.bezierCurve: Motion.spatial
		}

		function showTurn(quarters) {
			turnAnim.stop();
			slot.turn = -90 * quarters;
			turnAnim.start();
		}

		Item {
			id: content

			width: develop.width
			height: develop.height
			scale: slot.lift
			rotation: slot.turn

			Develop {
				id: develop

				source: slot.path
				sourceWidth: slot.sourceWidth
				sourceHeight: slot.sourceHeight
				recipe: slot.recipe
				cropless: slot.isFront && root.cropless
				full: slot.isFront && !slot.movie && (Viewer.mode !== "view" || root.exporting || slot.s * Math.max(slot.sourceWidth, slot.sourceHeight) > develop.previewSide * 0.9)
				clipWarning: slot.isFront && root.clipWarning
				split: slot.isFront && !root.exporting && !root.cropless ? root.split : 0
				previewSide: 1280
				visible: !slot.movie
				onReadyChanged: if (develop.ready && slot.pending) root.swap()
			}

			Loader {
				id: movieLoader

				anchors.fill: parent
				active: slot.animatedSource && slot.path !== ""
				sourceComponent: AnimatedImage {
					source: "file://" + slot.path
					asynchronous: true
					cache: false
					smooth: true
					mipmap: true
					playing: slot.isFront && Viewer.windowOpen
					onStatusChanged: if (status === AnimatedImage.Ready && slot.pending) root.swap()
				}
			}

			Markings {
				anchors.fill: parent
				visible: root.markingsShown && !root.cropless && !root.original
				items: slot.recipe?.markup?.items ?? []
				source: develop
			}
		}
	}

	// the neighbours decoded ahead, the way Develop asks for them (the same
	// source and size are the same entry of Qt's picture cache)
	Repeater {
		model: Viewer.windowOpen ? Viewer.ahead : []

		delegate: Image {
			required property var modelData
			readonly property real w: modelData.info.width
			readonly property real h: modelData.info.height

			visible: false
			source: "file://" + modelData.path
			sourceSize: Qt.size(w >= h ? Math.min(1280, w) : 0, h > w ? Math.min(1280, h) : 0)
			asynchronous: true
			autoTransform: true
			cache: true
		}
	}

	// see-through parts on a quiet chequer, under the picture on the screen
	// (not part of what is saved)
	Image {
		readonly property Item f: root.front
		visible: !!f && f.develop.ready && !root.cropless && (!!Viewer.info?.alpha || !!f.recipe?.cutout)
		x: f ? f.x : 0
		y: f ? f.y : 0
		width: f ? f.content.width * f.s : 0
		height: f ? f.content.height * f.s : 0
		z: 0.5
		opacity: f ? f.fade : 0
		fillMode: Image.Tile
		source: `data:image/svg+xml;utf8,<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24"><rect width="24" height="24" fill="${Theme.dark ? "%232a2a2a" : "%23e8e8e8"}"/><rect width="12" height="12" fill="${Theme.dark ? "%23363636" : "%23ffffff"}"/><rect x="12" y="12" width="12" height="12" fill="${Theme.dark ? "%23363636" : "%23ffffff"}"/></svg>`
	}

	Slot {
		id: slotA
	}

	Slot {
		id: slotB
	}

	// the line between before and after, dragged sideways
	Item {
		id: divider

		readonly property Item f: root.front
		visible: root.split > 0.001 && !!f && !root.cropless
		z: 5
		x: f ? f.x + f.content.width * f.s * root.split - width / 2 : 0
		y: f ? Math.max(0, f.y) : 0
		width: 40
		height: f ? Math.min(root.height, f.content.height * f.s) : 0

		Rectangle {
			anchors.horizontalCenter: parent.horizontalCenter
			width: 2
			height: parent.height
			color: "white"
			opacity: 0.9
		}

		Rectangle {
			anchors.centerIn: parent
			width: 34
			height: 34
			radius: 17
			color: Theme.base
			border.width: 2
			border.color: "white"

			Glyph {
				anchors.centerIn: parent
				icon: "arrow_left_right"
				size: 18
				color: Theme.text
			}
		}

		StyledText {
			x: -implicitWidth - 4
			y: 10
			text: "Before"
			font.pixelSize: Theme.size.small
			tone: "white"
			style: Text.Outline
			styleColor: Qt.rgba(0, 0, 0, 0.6)
		}

		StyledText {
			x: parent.width + 4
			y: 10
			text: "After"
			font.pixelSize: Theme.size.small
			tone: "white"
			style: Text.Outline
			styleColor: Qt.rgba(0, 0, 0, 0.6)
		}

		MouseArea {
			anchors.fill: parent
			cursorShape: Qt.SizeHorCursor
			preventStealing: true
			onPositionChanged: event => {
				if (!pressed || !divider.f) return;
				const p = mapToItem(root, event.x, event.y);
				root.split = Math.max(0.02, Math.min(0.98, (p.x - divider.f.x) / Math.max(1, divider.f.content.width * divider.f.s)));
			}
		}
	}

	// a quarter turn of the front picture turns it in front of the eyes
	property int lastRot: 0
	property string lastRotPath: ""

	Connections {
		target: Viewer

		// the picture that goes keeps the recipe it had
		function onAboutToLoad() {
			if (root.front) root.front.recipe = root.front.recipe;
		}

		function onRecipeChanged() {
			const f = root.front;
			if (!f) return;
			const rot = Geo.normalised(Viewer.recipe.geometry).rot;
			if (root.lastRotPath === f.path && rot !== root.lastRot) {
				let d = rot - root.lastRot;
				if (d === 3) d = -1;
				if (d === -3) d = 1;
				if (Math.abs(d) === 1) f.showTurn(d);
			}
			root.lastRot = rot;
			root.lastRotPath = f.path;
		}
	}

	// the size of what is shown changed (crop, turn, a new picture): fitted stays fitted
	Connections {
		target: root.front ? root.front.content : null

		function onWidthChanged() {
			root.keepFit();
		}
		function onHeightChanged() {
			root.keepFit();
		}
	}

	// the window's own size: no glide, the picture just fits
	onWidthChanged: root.keepFit(false)
	onHeightChanged: root.keepFit(false)
	onCroplessChanged: if (root.front) root.refit(root.front, true)

	function keepFit(animate) {
		const f = root.front;
		if (!f) return;
		if (f.fitted) root.refit(f, animate !== false && !root.interacting);
		else root.clampPan(f);
	}

	// ── pointer ────────────────────────────────────────────────────────────
	MouseArea {
		id: mouse

		anchors.fill: parent
		hoverEnabled: true
		acceptedButtons: Qt.LeftButton | Qt.MiddleButton
		property real lastX: 0
		property real lastY: 0
		property bool moved: false
		cursorShape: pressed && moved ? Qt.ClosedHandCursor : (root.front && !root.front.fitted ? Qt.OpenHandCursor : Qt.ArrowCursor)

		onPositionChanged: event => {
			root.pointerMoved();
			if (!pressed) return;
			const dx = event.x - mouse.lastX, dy = event.y - mouse.lastY;
			if (Math.abs(dx) + Math.abs(dy) > 0) mouse.moved = true;
			root.interacting = true;
			root.panBy(dx, dy);
			mouse.lastX = event.x;
			mouse.lastY = event.y;
		}
		onPressed: event => {
			mouse.lastX = event.x;
			mouse.lastY = event.y;
			mouse.moved = false;
		}
		onReleased: root.interacting = false
		onDoubleClicked: event => root.actualSize(event.x, event.y)
		onWheel: wheel => {
			root.pointerMoved();
			// a mouse wheel zooms; a touchpad's two fingers move, with Ctrl they zoom
			const touchpad = wheel.pixelDelta.y !== 0 || wheel.pixelDelta.x !== 0;
			if (touchpad && !(wheel.modifiers & Qt.ControlModifier)) {
				root.panBy(wheel.pixelDelta.x, wheel.pixelDelta.y);
				return;
			}
			const steps = touchpad ? wheel.pixelDelta.y / 60 : wheel.angleDelta.y / 120;
			root.zoomBy(Math.pow(1.18, steps), wheel.x, wheel.y, !touchpad);
		}
	}

	PinchHandler {
		target: null
		property real startScale: 1

		onActiveChanged: {
			root.interacting = active;
			if (active && root.front) startScale = root.front.s;
		}
		onActiveScaleChanged: root.zoomTo(startScale * activeScale, centroid.position.x, centroid.position.y, false)
	}

	// ── saving: the front content at full size ─────────────────────────────
	function render(path, done) {
		const f = root.front;
		if (!f || !f.develop.ready) {
			done(false);
			return;
		}
		root.exporting = true;
		const grab = () => {
			const ok = f.content.grabToImage(result => {
				root.exporting = false;
				done(result.saveToFile(path));
			}, Qt.size(f.content.width, f.content.height));
			if (!ok) {
				root.exporting = false;
				done(false);
			}
		};
		// the full picture first, if it is not there yet
		if (f.develop.sharp || f.movie) Qt.callLater(grab);
		else waitSharp.start(grab);
	}

	Timer {
		id: waitSharp

		property var then: null
		property int tries: 0

		function start(fn) {
			waitSharp.then = fn;
			waitSharp.tries = 0;
			waitSharp.restart();
		}

		interval: 50
		repeat: true
		onTriggered: {
			waitSharp.tries += 1;
			if (root.front?.develop.sharp || waitSharp.tries > 600) {
				waitSharp.stop();
				waitSharp.then();
			}
		}
	}
}
