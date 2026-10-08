pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.core.services
import qs.style.widgets

// The space around the earth, seen from above the plane the planets move
// in: the moon on its orbit, the side the sun is on, and every asteroid of
// Asteroids.objects where it is right now, with the way it came as a tail.
// Distances are squeezed (a logarithm), or the moon would sit on the earth:
// the rings are 1, 5, 10 and 20 lunar distances. A beam goes round and
// lights up what it passes. The picked asteroid shows its whole way, with a
// ring where it comes closest.
//
// It slowly turns by itself; dragging turns and tilts it, the wheel zooms.
// A click on an asteroid flies close to it, where it is a tumbling rock
// (one of a few shapes, dealt out in turn); a click beside it, or zooming
// out, flies back. `held` moves the scene to another time, and it glides
// back to now when that is let go.
Item {
	id: root

	// the radar is on the screen
	property bool shown: false
	// designation of the picked asteroid, and of what the pointer is on
	property string selected: ""
	property string hovered: ""
	// the time the scene is held at; NaN: now
	property real held: Number.NaN

	// the view is close to the picked asteroid
	property bool close: false

	signal picked(string des)

	// lunar distances the outer ring stands for
	readonly property real reach: 20
	// the time the scene shows
	property real time: 0
	property real yaw: 0.5
	// how far above the plane it is seen from, and where that comes to rest
	property real tilt: 0.62
	property real rest: 0.62
	// where the beam is
	property real beam: 0
	// milliseconds on the screen, and seconds since it was last turned by hand
	property real age: 0
	property real idle: 10
	// 1 shows it all; what the wheel asks for, and what is shown
	property real aimZoom: 1
	property real zoom: 1
	// how close the view is to the picked asteroid, 0 to 1, and what it has
	// in its middle, in the squeezed space the radar is drawn in
	property real near: 0
	property var eye: [0, 0, 0]
	// outlines of the rocks, as distances from the middle all the way round,
	// and how much each is stretched
	readonly property var rocks: [
		{ rim: [1, 0.82, 0.95, 0.7, 0.88, 1, 0.78, 0.92, 0.74, 0.9], wide: 1.25, high: 0.85 },
		{ rim: [0.9, 1, 0.72, 0.86, 0.98, 0.76, 0.8, 1, 0.7], wide: 1.1, high: 0.95 },
		{ rim: [1, 0.7, 0.9, 0.96, 0.66, 0.88, 1, 0.8, 0.74, 0.94, 0.82], wide: 1.35, high: 0.8 },
		{ rim: [0.84, 0.98, 0.9, 0.64, 0.92, 0.78, 1, 0.86], wide: 1, high: 1 },
		{ rim: [1, 0.9, 0.68, 0.8, 0.96, 0.9, 0.62, 0.86, 0.98, 0.74], wide: 1.2, high: 0.9 }
	]
	// how much of the picked way is drawn
	property real grown: 0
	// where things are drawn right now: [{ key, x, y }]
	property var spots: []
	property real owed: 0

	function squeeze(distance) {
		return Math.log(1 + distance / 0.5) / Math.log(1 + root.reach / 0.5);
	}

	function step(dt) {
		root.owed += dt;
		if (root.owed < 1 / 62) return;
		dt = Math.min(0.05, root.owed);
		root.owed = 0;
		root.age += dt * 1000;
		const holding = isFinite(root.held);
		const target = Math.max(Asteroids.from, Math.min(Asteroids.until, holding ? root.held : Date.now()));
		const gap = target - root.time;
		root.time = Math.abs(gap) < 2000 ? target : root.time + gap * (1 - Math.exp(-dt * (holding ? 16 : 4)));
		if (!pointer.pressed) {
			root.idle += dt;
			if (root.hovered === "") root.yaw += dt * 0.06 * Math.min(1, root.idle / 2);
			root.tilt += (root.rest - root.tilt) * (1 - Math.exp(-dt * 3.5));
		}
		root.beam = (root.beam + dt * 1.1) % (Math.PI * 2);
		const closing = root.close && Asteroids.objects.some(object => object.des === root.selected);
		const zoom = closing ? Math.max(4.2, root.aimZoom) : root.aimZoom;
		root.zoom = Math.abs(zoom - root.zoom) < 0.003 ? zoom : root.zoom + (zoom - root.zoom) * (1 - Math.exp(-dt * 4.5));
		root.near = Math.abs((closing ? 1 : 0) - root.near) < 0.003 ? (closing ? 1 : 0) : root.near + ((closing ? 1 : 0) - root.near) * (1 - Math.exp(-dt * 4.5));
		root.grown = Math.min(1, root.grown + dt / 0.7);
		canvas.requestPaint();
	}

	function spotAt(x, y) {
		let best = "";
		let reach = 1;
		for (const spot of root.spots) {
			// how far off, in what the dot or the rock reaches
			const distance = Math.hypot(spot.x - x, spot.y - y) / Math.max(13, (spot.r ?? 0) * 1.3);
			if (distance < reach) {
				reach = distance;
				best = spot.key;
			}
		}
		return best;
	}

	onSelectedChanged: root.grown = 0
	onShownChanged: {
		root.hovered = "";
		if (!root.shown) return;
		// the week so far plays up to now while it tilts into place
		root.age = 0;
		root.grown = 0;
		root.idle = 10;
		root.time = Asteroids.from;
		root.tilt = 1.3;
		root.rest = 0.62;
		root.yaw = 0.5 - 0.9;
		root.close = false;
		root.aimZoom = 1;
		root.zoom = 1;
		root.near = 0;
		root.eye = [0, 0, 0];
	}

	FrameAnimation {
		running: root.shown
		onTriggered: root.step(frameTime)
	}

	Canvas {
		id: canvas

		anchors.fill: parent
		antialiasing: true
		renderStrategy: Canvas.Cooperative

		onPaint: {
			const ctx = getContext("2d");
			ctx.reset();
			if (Asteroids.count < 2) return;
			const tau = Math.PI * 2;
			const cy = Math.cos(root.yaw);
			const sy = Math.sin(root.yaw);
			const ct = Math.cos(root.tilt);
			const st = Math.sin(root.tilt);
			const open = 1 - Math.pow(1 - Math.min(1, root.age / 900), 3);
			const R = Math.min(width / 2 - 6, (height / 2 - 10) / (st + 0.35 * ct)) * (0.72 + 0.28 * open) * root.zoom;
			if (R < 20) return;
			const at = [0, 0, 0];
			const time = root.time;
			// the view follows the picked asteroid when it is close to it
			const followed = root.close ? Asteroids.objects.find(object => object.des === root.selected) : undefined;
			const eye = root.eye;
			for (let axis = 0; axis < 3; axis += 1) {
				let goal = 0;
				if (followed) {
					if (axis === 0) Asteroids.locate(followed.path, time, at);
					const distance = Math.hypot(at[0], at[1], at[2]);
					goal = distance > 0 ? at[axis] * root.squeeze(distance) / distance : 0;
				}
				eye[axis] += (goal - eye[axis]) * 0.11;
			}
			// the earth on the screen
			const mx = width / 2 - R * (eye[0] * cy - eye[1] * sy);
			const my = height / 2 - R * ((eye[0] * sy + eye[1] * cy) * st - eye[2] * ct);
			const primary = Theme.primary;
			const text = Theme.text;
			let px = 0;
			let py = 0;
			let pz = 0;
			// a place in space on the screen; a larger pz is nearer to the viewer
			const project = (x, y, z) => {
				const distance = Math.hypot(x, y, z);
				const k = distance > 0 ? root.squeeze(distance) / distance : 0;
				const x1 = (x * cy - y * sy) * k;
				const y1 = (x * sy + y * cy) * k;
				px = mx + R * x1;
				py = my + R * (y1 * st - z * k * ct);
				pz = y1 * ct + z * k * st;
			};
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
			ctx.lineCap = "round";
			ctx.lineJoin = "round";

			// the beam, brightest at its front
			for (let i = 1; i <= 16; i += 1) {
				ctx.beginPath();
				ctx.moveTo(mx, my);
				for (let j = 0; j <= i; j += 1) {
					const angle = root.beam - j * 0.065 + root.yaw;
					ctx.lineTo(mx + R * Math.cos(angle), my + R * Math.sin(angle) * st);
				}
				ctx.closePath();
				ctx.fillStyle = Qt.alpha(primary, 0.0105 * open);
				ctx.fill();
			}
			ctx.beginPath();
			ctx.moveTo(mx, my);
			ctx.lineTo(mx + R * Math.cos(root.beam + root.yaw), my + R * Math.sin(root.beam + root.yaw) * st);
			ctx.strokeStyle = Qt.alpha(primary, 0.32 * open);
			ctx.lineWidth = 1;
			ctx.stroke();

			// the rings, the moon's a little brighter
			ctx.font = `500 9px "${Theme.fontFamily}"`;
			// the largest ring with room beside it names the unit
			let named = 0;
			for (const distance of [1, 5, 10, 20])
				if (mx + R * root.squeeze(distance) + 36 < width && (distance > 1 || root.zoom > 1.7)) named = distance;
			for (const distance of [1, 5, 10, 20]) {
				const r = R * root.squeeze(distance);
				ctx.beginPath();
				ctx.ellipse(mx - r, my - r * st, r * 2, r * 2 * st);
				ctx.strokeStyle = distance === 1 ? Qt.alpha(primary, 0.34 * open) : Qt.alpha(text, (distance === root.reach ? 0.2 : 0.1) * open);
				ctx.lineWidth = 1;
				ctx.stroke();
				const outer = distance === named;
				// not where it would run into the unit's
				if (!outer && (distance === 1 && root.zoom <= 1.7 || mx + r > width || distance > named && named > 0 && r - R * root.squeeze(named) < 56)) continue;
				ctx.fillStyle = Qt.alpha(text, 0.34 * open);
				ctx.textAlign = outer ? "left" : "right";
				ctx.fillText(outer ? `${distance} LD` : String(distance), mx + r + (outer ? 5 : -4), my - 3);
			}
			// marks that show it turning
			ctx.beginPath();
			for (let i = 0; i < 24; i += 1) {
				const angle = i * tau / 24 + root.yaw;
				const inner = i % 6 === 0 ? 0.94 : 0.975;
				ctx.moveTo(mx + R * inner * Math.cos(angle), my + R * inner * Math.sin(angle) * st);
				ctx.lineTo(mx + R * Math.cos(angle), my + R * Math.sin(angle) * st);
			}
			ctx.strokeStyle = Qt.alpha(text, 0.22 * open);
			ctx.stroke();

			// the sun, out on the rim
			Asteroids.sunAt(time, at);
			project(at[0] * root.reach, at[1] * root.reach, at[2] * root.reach);
			const sunX = px;
			const sunY = py;
			const glare = ctx.createRadialGradient(sunX, sunY, 0, sunX, sunY, 16);
			glare.addColorStop(0, Qt.alpha(Theme.warning, 0.5 * open));
			glare.addColorStop(1, Qt.alpha(Theme.warning, 0));
			disc(sunX, sunY, 16, glare);
			disc(sunX, sunY, 3.2, Qt.alpha(Theme.warning, open));

			// the ways of the picked asteroid and of the one pointed at
			const span = Asteroids.until - Asteroids.from;
			for (const object of Asteroids.objects) {
				const chosen = object.des === root.selected;
				if (!chosen && object.des !== root.hovered) continue;
				const shownSpan = chosen ? root.grown * span : span;
				const strength = chosen ? 1 : 0.45;
				// behind it faint, ahead of it bright
				for (let side = 0; side < 2; side += 1) {
					ctx.beginPath();
					let pen = false;
					const draw = moment => {
						Asteroids.locate(object.path, moment, at);
						if (Math.hypot(at[0], at[1], at[2]) > root.reach + 2) {
							pen = false;
							return;
						}
						project(at[0], at[1], at[2]);
						if (pen) ctx.lineTo(px, py);
						else ctx.moveTo(px, py);
						pen = true;
					};
					const from = side === 0 ? Math.max(Asteroids.from, time - shownSpan) : time;
					const to = side === 0 ? time : Math.min(Asteroids.until, time + shownSpan);
					// half steps keep the bend round where it comes close
					const pace = Asteroids.step / 2;
					draw(from);
					for (let i = Math.floor((from - Asteroids.from) / pace) + 1; Asteroids.from + i * pace < to; i += 1) draw(Asteroids.from + i * pace);
					draw(to);
					ctx.strokeStyle = Qt.alpha(primary, (side === 0 ? 0.22 : 0.8) * strength);
					ctx.lineWidth = 1.4;
					ctx.stroke();
				}
				if (!chosen) continue;
				// where it comes closest
				Asteroids.locate(object.path, object.at, at);
				project(at[0], at[1], at[2]);
				const mark = Math.max(0, Math.min(1, root.grown * 2 - 0.6));
				ctx.beginPath();
				ctx.moveTo(mx, my);
				ctx.lineTo(px, py);
				ctx.strokeStyle = Qt.alpha(primary, 0.3 * mark);
				ctx.lineWidth = 1;
				ctx.stroke();
				ring(px, py, 4.5 * (2 - mark), Qt.alpha(primary, 0.9 * mark), 1.3);
			}

			// everything that is a dot, the farthest first
			const dots = [{ kind: "earth", x: mx, y: my, z: 0 }];
			Asteroids.locate(Asteroids.moon, time, at);
			project(at[0], at[1], at[2]);
			dots.push({ kind: "moon", x: px, y: py, z: pz });
			for (let index = 0; index < Asteroids.objects.length; index += 1) {
				const object = Asteroids.objects[index];
				Asteroids.locate(object.path, time, at);
				const distance = Math.hypot(at[0], at[1], at[2]);
				const alpha = Math.max(0, Math.min(1, 1 - (distance - root.reach) / 2));
				if (alpha <= 0) continue;
				project(at[0], at[1], at[2]);
				const behind = ((root.beam - Math.atan2(at[1], at[0])) % tau + tau) % tau;
				dots.push({ kind: "rock", object: object, index: index, x: px, y: py, z: pz, alpha: alpha, glow: Math.exp(-behind * 1.2), sx: at[0], sy: at[1] });
			}
			dots.sort((a, b) => a.z - b.z);

			const spots = [];
			for (const dot of dots) {
				if (dot.kind === "earth") {
					const air = ctx.createRadialGradient(mx, my, 4, mx, my, 15);
					air.addColorStop(0, Qt.alpha(primary, 0.4 * open));
					air.addColorStop(1, Qt.alpha(primary, 0));
					disc(mx, my, 15, air);
					disc(mx, my, 6, primary);
					// its night side
					const away = Math.hypot(sunX - mx, sunY - my) || 1;
					ctx.save();
					ctx.beginPath();
					ctx.arc(mx, my, 6, 0, tau);
					ctx.clip();
					disc(mx - (sunX - mx) / away * 5, my - (sunY - my) / away * 5, 6.4, Qt.alpha(Theme.base, 0.6));
					ctx.restore();
					continue;
				}
				if (dot.kind === "moon") {
					disc(dot.x, dot.y, 2.6, Qt.alpha(text, 0.9 * open));
					spots.push({ key: "moon", x: dot.x, y: dot.y });
					continue;
				}
				const object = dot.object;
				const chosen = object.des === root.selected;
				const color = chosen ? primary : (object.dist < 1 ? Theme.warning : text);
				const alpha = dot.alpha * open;
				const dotted = 1.7 + Math.max(0, Math.min(2.4, Math.log(Math.max(5, object.size || 10) / 5) / Math.LN10 * 1.2));
				// they grow as the view comes closer, the one it flies to the most
				const grown = dotted * (0.6 + 0.4 * root.zoom);
				const r = chosen ? grown + (20 + dotted * 3 - grown) * root.near : grown;

				// what it stands over in the plane
				project(dot.sx, dot.sy, 0);
				ctx.beginPath();
				ctx.moveTo(dot.x, dot.y);
				ctx.lineTo(px, py);
				ctx.strokeStyle = Qt.alpha(text, 0.16 * alpha);
				ctx.lineWidth = 1;
				ctx.stroke();
				disc(px, py, 1, Qt.alpha(text, 0.3 * alpha));

				// the way it came
				let lastX = dot.x;
				let lastY = dot.y;
				// round ends would show as beads once it is wide
				ctx.lineCap = "butt";
				for (let i = 1; i <= 7; i += 1) {
					Asteroids.locate(object.path, time - i * 2400000, at);
					project(at[0], at[1], at[2]);
					ctx.beginPath();
					ctx.moveTo(lastX, lastY);
					ctx.lineTo(px, py);
					ctx.strokeStyle = Qt.alpha(color, (0.5 + 0.3 * dot.glow) * alpha * (1 - i / 8));
					ctx.lineWidth = Math.min(r, dotted * 2.2) * 1.3 * (1 - i / 9);
					ctx.stroke();
					lastX = px;
					lastY = py;
				}
				ctx.lineCap = "round";

				disc(dot.x, dot.y, r + 2.5 + dot.glow * 4, Qt.alpha(color, (0.1 + 0.26 * dot.glow) * alpha));
				if (r < 3.6) {
					disc(dot.x, dot.y, r, Qt.alpha(color, (0.62 + 0.38 * dot.glow) * alpha));
				} else {
					// a rock of flat sides, each as bright as it faces the sun
					const rock = root.rocks[dot.index % root.rocks.length];
					const count = rock.rim.length;
					const spin = dot.index * 1.7 + root.age / 1000 * (0.22 + 0.07 * (dot.index % 3)) * (dot.index % 2 ? -1 : 1);
					const cs = Math.cos(spin);
					const sn = Math.sin(spin);
					const light = Math.atan2(sunY - dot.y, sunX - dot.x);
					const corner = i => {
						const angle = i % count * tau / count;
						const x = Math.cos(angle) * rock.rim[i % count] * rock.wide * r;
						const y = Math.sin(angle) * rock.rim[i % count] * rock.high * r;
						px = dot.x + x * cs - y * sn;
						py = dot.y + x * sn + y * cs;
					};
					const topX = dot.x + (0.14 * cs + 0.1 * sn) * r;
					const topY = dot.y + (0.14 * sn - 0.1 * cs) * r;
					ctx.globalAlpha = alpha;
					for (let i = 0; i < count; i += 1) {
						corner(i);
						const fromX = px;
						const fromY = py;
						corner(i + 1);
						const facing = 0.5 + 0.5 * Math.cos(Math.atan2((fromY + py) / 2 - topY, (fromX + px) / 2 - topX) - light);
						const shade = Qt.tint(Theme.base, Qt.alpha(color, 0.2 + 0.68 * Math.pow(facing, 1.3) + 0.1 * dot.glow));
						ctx.beginPath();
						ctx.moveTo(topX, topY);
						ctx.lineTo(fromX, fromY);
						ctx.lineTo(px, py);
						ctx.closePath();
						ctx.fillStyle = shade;
						ctx.fill();
						ctx.strokeStyle = shade;
						ctx.lineWidth = 0.6;
						ctx.stroke();
					}
					if (r > 12) {
						// two craters
						for (const [across, along, girth] of [[0.42, -0.3, 0.17], [-0.38, 0.28, 0.12]]) {
							const x = dot.x + (across * cs - along * sn) * r * rock.wide * 0.8;
							const y = dot.y + (across * sn + along * cs) * r * rock.high * 0.8;
							disc(x, y, girth * r, Qt.alpha(Theme.base, 0.3));
							ring(x, y, girth * r, Qt.alpha(color, 0.22), 0.8);
						}
					}
					ctx.globalAlpha = 1;
				}
				if (chosen) {
					const beat = (root.age % 1800) / 1800;
					ring(dot.x, dot.y, r * 1.3 + 3 + beat * 8, Qt.alpha(primary, (1 - beat) * 0.6 * alpha), 1.2);
					ring(dot.x, dot.y, r * 1.3 + 3.5, Qt.alpha(text, 0.85 * alpha * (1 - 0.6 * root.near)), 1.3);
				} else if (object.des === root.hovered) {
					ring(dot.x, dot.y, r * 1.3 + 3.5, Qt.alpha(text, 0.6 * alpha), 1.3);
				}
				if (dot.alpha > 0.3) spots.push({ key: object.des, x: dot.x, y: dot.y, r: r });
			}
			root.spots = spots;

			// zoomed in, it fades out towards the edges
			if (root.zoom > 1.02) {
				ctx.globalCompositeOperation = "destination-in";
				for (const upright of [false, true]) {
					const fade = upright ? ctx.createLinearGradient(0, 0, 0, height) : ctx.createLinearGradient(0, 0, width, 0);
					const edge = (upright ? 22 : 26) / (upright ? height : width);
					const least = Math.max(0, 1 - (root.zoom - 1) * 4);
					fade.addColorStop(0, Qt.rgba(0, 0, 0, least));
					fade.addColorStop(edge, Qt.rgba(0, 0, 0, 1));
					fade.addColorStop(1 - edge, Qt.rgba(0, 0, 0, 1));
					fade.addColorStop(1, Qt.rgba(0, 0, 0, least));
					ctx.fillStyle = fade;
					ctx.fillRect(0, 0, width, height);
				}
				ctx.globalCompositeOperation = "source-over";
			}

			const marked = spots.find(spot => spot.key === root.hovered);
			label.at = marked !== undefined;
			if (marked) {
				label.px = marked.x;
				label.py = marked.y;
				const object = Asteroids.objects.find(entry => entry.des === root.hovered);
				Asteroids.locate(object ? object.path : Asteroids.moon, time, at);
				label.name = object ? object.name : "Moon";
				label.distance = Asteroids.distance(Math.hypot(at[0], at[1], at[2]));
			}
		}
	}

	MouseArea {
		id: pointer

		property real lastX: 0
		property real lastY: 0
		property bool turned: false

		anchors.fill: parent
		hoverEnabled: true
		cursorShape: root.hovered !== "" && root.hovered !== "moon" ? Qt.PointingHandCursor : (pointer.pressed && pointer.turned ? Qt.ClosedHandCursor : Qt.OpenHandCursor)

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
			root.hovered = "";
			root.idle = 0;
			root.yaw -= dx / 110;
			root.tilt = Math.max(0.25, Math.min(1.45, root.tilt + dy / 140));
			root.rest = root.tilt;
			pointer.lastX = mouse.x;
			pointer.lastY = mouse.y;
		}
		onExited: root.hovered = ""
		onClicked: mouse => {
			if (pointer.turned) return;
			const key = root.spotAt(mouse.x, mouse.y);
			if (key === "" || key === "moon") {
				root.close = false;
				return;
			}
			// to it, and away again from the one the view is at
			root.close = !(root.close && key === root.selected);
			root.picked(key);
		}
		onWheel: wheel => {
			const next = Math.max(1, Math.min(6, (root.close ? Math.max(4.2, root.aimZoom) : root.aimZoom) * Math.pow(1.2, wheel.angleDelta.y / 120)));
			// zooming out leaves the asteroid
			if (next < 4.2) root.close = false;
			root.aimZoom = root.close ? next : Math.min(next, wheel.angleDelta.y < 0 ? root.aimZoom : next);
		}
	}

	Rectangle {
		id: label

		property bool at: false
		property real px: 0
		property real py: 0
		property string name: ""
		property string distance: ""

		x: Math.max(0, Math.min(root.width - width, label.px - width / 2))
		y: label.py - height - 12 < 0 ? label.py + 12 : label.py - height - 12
		width: words.implicitWidth + 20
		height: 26
		radius: height / 2
		color: Theme.layer3
		border.width: 1
		border.color: Theme.outline
		opacity: label.at ? 1 : 0
		scale: label.at ? 1 : 0.9

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
				text: label.name
				font.pixelSize: Theme.size.label
				font.weight: Font.DemiBold
			}

			StyledText {
				text: label.distance
				tone: Theme.textMuted
				tabular: true
				font.pixelSize: Theme.size.label
			}
		}
	}
}
