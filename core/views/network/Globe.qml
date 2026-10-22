pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io
import Quickshell.Widgets
import qs.style.theme
import qs.core.services
import qs.style.widgets

// The earth as a grid of dots (assets/globe/land.json), with an arc from
// here to every place a connection goes. An arc grows out of the origin when
// its place appears and fades when the last connection there closes. What is
// downloaded travels along it towards the origin as packets, what is
// uploaded the other way, the more the faster it flows.
//
// The view rests between the origin and the places that count (`aimed`),
// as close as still shows them all; dragging turns it and the wheel zooms
// by hand until something else is picked.
Item {
	id: root

	// the globe is on the screen
	property bool shown: false
	// Outbound.places
	property var places: []
	// [latitude, longitude]
	property var origin: [50.1, 8.7]
	// { key: true } of the places that stand out, the others dim; null: all
	property var lit: null
	// { key: true } of the places the view turns to; null: all
	property var aimed: null
	// only this app's traffic moves; "": everyone's
	property string app: ""
	// the place that keeps its label
	property string pinned: ""
	// the place under the pointer
	property string hovered: ""

	signal picked(string key)

	readonly property real radius: Math.min(width, height) * 0.4 * root.zoom
	// 1 shows the whole earth; places close to home are zoomed in on
	property real zoom: 1
	property real aimZoom: 1
	readonly property int steps: 48
	property real lat: 30
	property real lon: 0
	property real aimLat: 30
	property real aimLon: 0
	property bool manual: false
	// milliseconds the globe has been on the screen
	property real now: 0
	// a packet just arrived
	property real flash: 0
	// { key: { place, pts, angle, born, gone, dim, down, up, owedDown, owedUp, packets: [{ born, life, up }] } }
	// changed in place, frame by frame
	property var arcs: ({})
	// unit vectors of the land dots: x, y, z, x, y, z …
	property var land: null
	// where the places are drawn right now: [{ key, x, y }]
	property var spots: []
	// seconds since the last picture, and whether something moves
	property real owed: 0
	property bool busy: true
	// how the earth was turned when it was last drawn
	property real drawnLat: 1000
	property real drawnLon: 1000
	property real drawnZoom: 0

	function vec(lat, lon) {
		const phi = lat * Math.PI / 180;
		const lambda = lon * Math.PI / 180;
		return [Math.cos(phi) * Math.sin(lambda), Math.sin(phi), Math.cos(phi) * Math.cos(lambda)];
	}

	// packets a second for bytes a second
	function flow(rate) {
		return rate < 8192 ? 0 : Math.min(12, 1.2 + 2.6 * Math.log(rate / 8192) / Math.LN10);
	}

	function shape(arc) {
		const a = root.vec(root.origin[0], root.origin[1]);
		const b = root.vec(arc.place.lat, arc.place.lon);
		const angle = Math.acos(Math.max(-1, Math.min(1, a[0] * b[0] + a[1] * b[1] + a[2] * b[2])));
		const sine = Math.sin(angle);
		const lift = 0.04 + 0.3 * angle / Math.PI;
		const pts = new Float32Array((root.steps + 1) * 3);
		for (let i = 0; i <= root.steps; i += 1) {
			const t = i / root.steps;
			const first = sine < 1e-4 ? 1 - t : Math.sin((1 - t) * angle) / sine;
			const second = sine < 1e-4 ? t : Math.sin(t * angle) / sine;
			const height = 1 + lift * Math.sin(Math.PI * t);
			for (let axis = 0; axis < 3; axis += 1) pts[i * 3 + axis] = (a[axis] * first + b[axis] * second) * height;
		}
		arc.pts = pts;
		arc.angle = angle;
	}

	function sync() {
		const seen = {};
		let changed = false;
		for (const place of root.places) {
			seen[place.key] = true;
			let arc = root.arcs[place.key];
			if (!arc) {
				arc = root.arcs[place.key] = { born: root.now, gone: 0, dim: 1, owedDown: 0, owedUp: 0, packets: [] };
				changed = true;
			} else if (arc.gone > 0) {
				arc.gone = 0;
				arc.born = root.now;
			}
			const moved = !arc.place || arc.place.lat !== place.lat || arc.place.lon !== place.lon;
			arc.place = place;
			if (moved) root.shape(arc);
			const own = root.app === "" ? place : (place.apps.find(entry => entry.id === root.app) ?? { down: 0, up: 0 });
			arc.down = own.down;
			arc.up = own.up;
		}
		for (const key in root.arcs) {
			if (seen[key] || root.arcs[key].gone > 0) continue;
			root.arcs[key].gone = root.now;
			changed = true;
		}
		if (changed) root.aim();
	}

	// between the origin and the places that count
	function aim() {
		if (root.manual) return;
		const home = root.vec(root.origin[0], root.origin[1]);
		const weight = root.aimed ? 1 : 2;
		const sum = [home[0] * weight, home[1] * weight, home[2] * weight];
		for (const place of root.places) {
			if (root.aimed && !root.aimed[place.key]) continue;
			const there = root.vec(place.lat, place.lon);
			for (let axis = 0; axis < 3; axis += 1) sum[axis] += there[axis];
		}
		const length = Math.hypot(sum[0], sum[1], sum[2]);
		let to = length < 0.25 ? home : sum.map(value => value / length);
		// never so far that home slips to the rim
		const angle = Math.acos(Math.max(-1, Math.min(1, home[0] * to[0] + home[1] * to[1] + home[2] * to[2])));
		const most = root.aimed ? 0.85 : 0.6;
		if (angle > most) {
			const first = Math.sin(angle - most) / Math.sin(angle);
			const second = Math.sin(most) / Math.sin(angle);
			to = home.map((value, axis) => value * first + to[axis] * second);
		}
		root.aimLat = Math.max(-55, Math.min(55, Math.asin(to[1]) * 180 / Math.PI));
		root.aimLon = Math.atan2(to[0], to[2]) * 180 / Math.PI;
		// as close as keeps home and all of them in sight
		let reach = Math.acos(Math.max(-1, Math.min(1, home[0] * to[0] + home[1] * to[1] + home[2] * to[2])));
		for (const place of root.places) {
			if (root.aimed && !root.aimed[place.key]) continue;
			const there = root.vec(place.lat, place.lon);
			reach = Math.max(reach, Math.acos(Math.max(-1, Math.min(1, there[0] * to[0] + there[1] * to[1] + there[2] * to[2]))));
		}
		root.aimZoom = reach > 1.2 ? 1 : Math.max(1, Math.min(4, 0.78 / Math.max(0.13, Math.sin(reach))));
	}

	function step(dt) {
		// 60 pictures a second are enough, half of that while nothing travels
		root.owed += dt;
		if (root.owed < (root.busy ? 1 / 62 : 1 / 31)) return;
		dt = Math.min(0.05, root.owed);
		root.owed = 0;
		root.now += dt * 1000;
		if (!pointer.pressed) {
			const ease = 1 - Math.exp(-dt * 4);
			const turn = ((root.aimLon - root.lon) % 360 + 540) % 360 - 180;
			const near = Math.abs(turn) + Math.abs(root.aimLat - root.lat) < 0.03;
			root.lat = near ? root.aimLat : root.lat + (root.aimLat - root.lat) * ease;
			root.lon = near ? root.aimLon : root.lon + turn * ease;
		}
		const grown = Math.abs(root.aimZoom - root.zoom) < 0.004;
		root.zoom = grown ? root.aimZoom : root.zoom + (root.aimZoom - root.zoom) * (1 - Math.exp(-dt * 5));
		if (root.lat !== root.drawnLat || root.lon !== root.drawnLon || root.zoom !== root.drawnZoom) earth.requestPaint();
		root.flash *= Math.exp(-dt * 5);
		let busy = false;
		for (const key in root.arcs) {
			const arc = root.arcs[key];
			if (arc.gone > 0 && root.now - arc.gone > 450) {
				delete root.arcs[key];
				continue;
			}
			const dim = !root.lit || root.lit[key] ? 1 : 0.14;
			arc.dim += (dim - arc.dim) * (1 - Math.exp(-dt * 12));
			const open = arc.gone === 0 && root.now - arc.born > 500;
			arc.owedDown = open ? arc.owedDown + dt * root.flow(arc.down) : 0;
			arc.owedUp = open ? arc.owedUp + dt * root.flow(arc.up) : 0;
			const life = 850 + 650 * arc.angle / Math.PI;
			for (; arc.owedDown >= 1 && arc.packets.length < 32; arc.owedDown -= 1) arc.packets.push({ born: root.now - Math.random() * 60, life: life, up: false });
			for (; arc.owedUp >= 1 && arc.packets.length < 32; arc.owedUp -= 1) arc.packets.push({ born: root.now - Math.random() * 60, life: life, up: true });
			for (let i = arc.packets.length - 1; i >= 0; i -= 1) {
				const packet = arc.packets[i];
				if (root.now - packet.born < packet.life) continue;
				if (!packet.up && dim === 1) root.flash = Math.min(1, root.flash + 0.45);
				arc.packets.splice(i, 1);
			}
			if (arc.packets.length > 0 || !open || Math.abs(dim - arc.dim) > 0.01) busy = true;
		}
		root.busy = busy || pointer.pressed || root.lat !== root.aimLat || root.lon !== root.aimLon || root.zoom !== root.aimZoom;
		canvas.requestPaint();
	}

	// the place a pointer at x, y is on
	function spotAt(x, y) {
		let best = "";
		let reach = 13 * 13;
		for (const spot of root.spots) {
			const distance = (spot.x - x) * (spot.x - x) + (spot.y - y) * (spot.y - y);
			if (distance < reach) {
				reach = distance;
				best = spot.key;
			}
		}
		return best;
	}

	onPlacesChanged: root.sync()
	onAppChanged: root.sync()
	onOriginChanged: {
		for (const key in root.arcs) root.shape(root.arcs[key]);
		root.aim();
	}
	onAimedChanged: {
		// what is picked is shown, wherever the globe was turned to
		if (root.aimed) root.manual = false;
		root.aim();
	}
	onShownChanged: {
		if (!root.shown) {
			root.arcs = ({});
			root.hovered = "";
			return;
		}
		root.manual = false;
		root.now = 0;
		root.sync();
		root.aim();
		// it turns into place
		root.lat = root.aimLat;
		root.lon = root.aimLon - 70;
		root.zoom = root.aimZoom * 0.86;
	}

	FileView {
		path: `${Paths.assets}/globe/land.json`
		onLoaded: {
			try {
				const flat = JSON.parse(text());
				const land = new Float32Array(flat.length / 2 * 3);
				for (let i = 0; i < flat.length / 2; i += 1) land.set(root.vec(flat[i * 2], flat[i * 2 + 1]), i * 3);
				root.land = land;
			} catch (error) {}
		}
	}

	FrameAnimation {
		running: root.shown
		onTriggered: root.step(frameTime)
	}

	ClippingRectangle {
		anchors.fill: parent
		radius: Theme.radius.medium
		color: "transparent"

		// the earth itself, drawn again only when it turns
		Canvas {
			id: earth

			anchors.fill: parent
			antialiasing: true
			renderStrategy: Canvas.Cooperative

			onWidthChanged: earth.requestPaint()
			onHeightChanged: earth.requestPaint()

			Connections {
				target: Theme
				function onPrimaryChanged() {
					earth.requestPaint();
				}
				function onBgChanged() {
					earth.requestPaint();
				}
			}

			Connections {
				target: root
				function onLandChanged() {
					earth.requestPaint();
				}
			}

			onPaint: {
				const ctx = getContext("2d");
				ctx.reset();
				const R = root.radius;
				if (R < 10) return;
				root.drawnLat = root.lat;
				root.drawnLon = root.lon;
				root.drawnZoom = root.zoom;
				const cx = width / 2;
				const cy = height / 2;
				const cl = Math.cos(root.lon * Math.PI / 180);
				const sl = Math.sin(root.lon * Math.PI / 180);
				const cp = Math.cos(root.lat * Math.PI / 180);
				const sp = Math.sin(root.lat * Math.PI / 180);
				const tau = Math.PI * 2;
				const primary = Theme.primary;
				const disc = (x, y, r, color) => {
					ctx.beginPath();
					ctx.arc(x, y, r, 0, tau);
					ctx.fillStyle = color;
					ctx.fill();
				};

				// the air around it
				const air = ctx.createRadialGradient(cx, cy, R * 0.92, cx, cy, R * 1.22);
				air.addColorStop(0, Qt.alpha(primary, 0.2));
				air.addColorStop(1, Qt.alpha(primary, 0));
				disc(cx, cy, R * 1.22, air);

				const body = ctx.createRadialGradient(cx - R * 0.35, cy - R * 0.4, R * 0.05, cx, cy, R);
				body.addColorStop(0, Theme.layer3);
				body.addColorStop(1, Theme.base);
				disc(cx, cy, R, body);
				ctx.beginPath();
				ctx.arc(cx, cy, R, 0, tau);
				ctx.strokeStyle = Qt.alpha(primary, 0.28);
				ctx.lineWidth = 1;
				ctx.stroke();

				// land, in three shades from the rim to the middle
				if (root.land) {
					const land = root.land;
					for (let shade = 0; shade < 3; shade += 1) {
						const from = shade / 3;
						const dot = (0.85 + shade * 0.2) * (0.8 + 0.2 * root.zoom);
						ctx.beginPath();
						for (let i = 0; i < land.length; i += 3) {
							const x1 = land[i] * cl - land[i + 2] * sl;
							const z1 = land[i] * sl + land[i + 2] * cl;
							const pz = land[i + 1] * sp + z1 * cp;
							if (pz <= 0.04 || pz < from || pz >= from + 0.334) continue;
							const px = cx + R * x1;
							const py = cy - R * (land[i + 1] * cp - z1 * sp);
							ctx.moveTo(px + dot, py);
							ctx.arc(px, py, dot, 0, tau);
						}
						ctx.fillStyle = Qt.alpha(Theme.text, 0.16 + shade * 0.17);
						ctx.fill();
					}
				}
			}
		}

		Canvas {
			id: canvas

			anchors.fill: parent
			antialiasing: true
			renderStrategy: Canvas.Cooperative

			onPaint: {
				const ctx = getContext("2d");
				ctx.reset();
				const R = root.radius;
				if (R < 10) return;
				const cx = width / 2;
				const cy = height / 2;
				const cl = Math.cos(root.lon * Math.PI / 180);
				const sl = Math.sin(root.lon * Math.PI / 180);
				const cp = Math.cos(root.lat * Math.PI / 180);
				const sp = Math.sin(root.lat * Math.PI / 180);
				const tau = Math.PI * 2;
				const primary = Theme.primary;
				const secondary = Theme.secondary;
				let px = 0;
				let py = 0;
				let pz = 0;
				// a point of the world on the screen; pz > 0 faces the viewer
				const project = (x, y, z) => {
					const x1 = x * cl - z * sl;
					const z1 = x * sl + z * cl;
					px = cx + R * x1;
					py = cy - R * (y * cp - z1 * sp);
					pz = y * sp + z1 * cp;
				};
				// the point at t (0 the origin, 1 the place) of an arc
				const along = (pts, t) => {
					const at = Math.max(0, Math.min(1, t)) * root.steps;
					const i = Math.min(root.steps - 1, Math.floor(at));
					const f = at - i;
					project(pts[i * 3] + (pts[i * 3 + 3] - pts[i * 3]) * f, pts[i * 3 + 1] + (pts[i * 3 + 4] - pts[i * 3 + 1]) * f, pts[i * 3 + 2] + (pts[i * 3 + 5] - pts[i * 3 + 2]) * f);
				};
				// not behind the globe
				const clear = () => pz >= 0 || (px - cx) * (px - cx) + (py - cy) * (py - cy) > R * R;
				const disc = (x, y, r, color) => {
					ctx.beginPath();
					ctx.arc(x, y, r, 0, tau);
					ctx.fillStyle = color;
					ctx.fill();
				};
				const ring = (x, y, r, color, line) => {
					ctx.beginPath();
					ctx.arc(x, y, r, 0, tau);
					ctx.strokeStyle = color;
					ctx.lineWidth = line;
					ctx.stroke();
				};

				const spots = [];
				ctx.lineCap = "round";
				ctx.lineJoin = "round";
				for (const key in root.arcs) {
					const arc = root.arcs[key];
					const age = root.now - arc.born;
					const grow = 1 - Math.pow(1 - Math.min(1, age / 650), 3);
					const fade = arc.gone > 0 ? Math.max(0, 1 - (root.now - arc.gone) / 400) : 1;
					const alpha = fade * arc.dim;
					const pts = arc.pts;

					// the arc, as far as it has grown
					ctx.beginPath();
					let pen = false;
					for (let i = 0; i <= root.steps; i += 1) {
						along(pts, grow * i / root.steps);
						if (!clear()) {
							pen = false;
						} else if (pen) {
							ctx.lineTo(px, py);
						} else {
							ctx.moveTo(px, py);
							pen = true;
						}
					}
					ctx.strokeStyle = Qt.alpha(primary, 0.5 * alpha);
					ctx.lineWidth = 1.2;
					ctx.stroke();

					// what travels along it
					for (const packet of arc.packets) {
						const p = (root.now - packet.born) / packet.life;
						const eased = p * p * (3 - 2 * p);
						const head = packet.up ? eased : 1 - eased;
						const tail = head + (packet.up ? -0.075 : 0.075);
						const glow = Math.min(1, p * 7, (1 - p) * 7) * alpha;
						const color = packet.up ? secondary : primary;
						along(pts, tail);
						if (!clear()) continue;
						const tx = px;
						const ty = py;
						along(pts, (head + tail) / 2);
						const mx = px;
						const my = py;
						along(pts, head);
						if (!clear()) continue;
						const trail = ctx.createLinearGradient(tx, ty, px, py);
						trail.addColorStop(0, Qt.alpha(color, 0));
						trail.addColorStop(1, Qt.alpha(color, glow));
						ctx.beginPath();
						ctx.moveTo(tx, ty);
						ctx.quadraticCurveTo(mx, my, px, py);
						ctx.strokeStyle = trail;
						ctx.lineWidth = 2.2;
						ctx.stroke();
						disc(px, py, 3.6, Qt.alpha(color, 0.28 * glow));
						disc(px, py, 1.7, Qt.alpha(Qt.tint(color, Qt.alpha(Theme.text, 0.55)), glow));
					}

					// the place
					along(pts, 1);
					if (pz <= 0.02 || grow < 0.96) continue;
					const pop = Math.max(0.05, Math.min(1, (age - 420) / 240));
					const size = (2.2 + Math.min(2, Math.log(1 + arc.place.conns) / Math.LN2 * 0.5)) * (pop < 1 ? pop * (2.2 - 1.2 * pop) : 1);
					if (arc.gone === 0) spots.push({ key: key, x: px, y: py });
					if (arc.down + arc.up >= 8192 && arc.gone === 0) {
						const beat = (root.now % 1500) / 1500;
						ring(px, py, size + 2 + beat * 9, Qt.alpha(primary, (1 - beat) * 0.55 * alpha), 1.2);
					}
					disc(px, py, size + 3, Qt.alpha(primary, 0.2 * alpha));
					disc(px, py, size, Qt.alpha(primary, alpha));
					if (key === root.hovered || key === root.pinned) ring(px, py, size + 4.5, Qt.alpha(Theme.text, 0.85 * alpha), 1.3);
				}
				root.spots = spots;

				// here
				const home = root.vec(root.origin[0], root.origin[1]);
				project(home[0], home[1], home[2]);
				if (pz > 0) {
					const beat = (root.now % 2600) / 2600;
					ring(px, py, 4 + beat * 12, Qt.alpha(Theme.text, (1 - beat) * 0.4), 1.2);
					disc(px, py, 6 + root.flash * 5, Qt.alpha(primary, 0.22 + root.flash * 0.3));
					// set off from the places around it
					disc(px, py, 5, Theme.base);
					disc(px, py, 3.4, Theme.text);
				}

				const marked = root.arcs[root.hovered || root.pinned];
				label.place = marked && marked.gone === 0 ? marked.place : null;
				if (label.place) {
					along(marked.pts, 1);
					label.shownAt = pz > 0.02;
					label.px = px;
					label.py = py;
				}
			}
		}

	}

	MouseArea {
		id: pointer

		property real lastX: 0
		property real lastY: 0
		property bool turned: false
		readonly property bool onGlobe: Math.hypot(mouseX - root.width / 2, mouseY - root.height / 2) < root.radius * 1.15

		anchors.fill: parent
		hoverEnabled: true
		cursorShape: root.hovered !== "" ? Qt.PointingHandCursor : (pointer.pressed && pointer.turned ? Qt.ClosedHandCursor : (pointer.onGlobe ? Qt.OpenHandCursor : Qt.ArrowCursor))

		onPressed: mouse => {
			pointer.lastX = mouse.x;
			pointer.lastY = mouse.y;
			pointer.turned = false;
		}
		onPositionChanged: mouse => {
			if (!pointer.pressed) {
				root.hovered = root.spotAt(mouse.x, mouse.y);
				return;
			}
			const dx = mouse.x - pointer.lastX;
			const dy = mouse.y - pointer.lastY;
			if (!pointer.turned && Math.hypot(dx, dy) < 4) return;
			pointer.turned = true;
			root.manual = true;
			root.hovered = "";
			root.lon -= dx / root.radius * 180 / Math.PI;
			root.lat = Math.max(-80, Math.min(80, root.lat + dy / root.radius * 180 / Math.PI));
			root.aimLon = root.lon;
			root.aimLat = root.lat;
			pointer.lastX = mouse.x;
			pointer.lastY = mouse.y;
		}
		onExited: root.hovered = ""
		onWheel: wheel => {
			root.manual = true;
			root.aimZoom = Math.max(1, Math.min(6, root.aimZoom * Math.pow(1.25, wheel.angleDelta.y / 120)));
		}
		onClicked: mouse => {
			if (!pointer.turned) root.picked(root.spotAt(mouse.x, mouse.y));
		}
	}

	Rectangle {
		id: label

		property var place: null
		property bool shownAt: false
		property real px: 0
		property real py: 0
		// the last place stays readable while the label fades
		property string city: ""
		property string country: ""

		onPlaceChanged: {
			if (!label.place) return;
			label.city = label.place.city || label.place.country || "Unknown";
			label.country = label.place.city ? label.place.country : "";
		}

		x: Math.max(6, Math.min(root.width - width - 6, label.px - width / 2))
		y: label.py - height - 14 < 6 ? label.py + 14 : label.py - height - 14
		width: words.implicitWidth + 20
		height: 28
		radius: height / 2
		color: Theme.layer3
		border.width: 1
		border.color: Theme.outline
		opacity: label.place && label.shownAt ? 1 : 0
		scale: label.place && label.shownAt ? 1 : 0.9

		Behavior on opacity {
			Anim {
				duration: Motion.short
			}
		}
		Behavior on scale {
			SpatialAnim {
				duration: Motion.medium
			}
		}

		Row {
			id: words

			anchors.centerIn: parent
			spacing: 6

			StyledText {
				text: label.city
				font.pixelSize: Theme.size.label
				font.weight: Font.DemiBold
			}

			StyledText {
				visible: label.country !== ""
				text: label.country
				tone: Theme.textMuted
				font.pixelSize: Theme.size.label
			}
		}
	}
}
