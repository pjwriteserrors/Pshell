pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.core.services

// The painted land under a camera. One clock moves everything (water, trees,
// people, smoke, sails), at a rate that keeps it cheap; only what is in view and
// close enough exists. The sharp city pictures fade in above the map once loaded,
// so that zooming never shows anything but the land.
Item {
	id: root

	required property var world
	required property string folder
	property bool interactive: true
	property bool paused: false
	property int rate: 33
	property real until: 100000
	property int focusDay: -1
	property real focusAmount: root.focusDay >= 0 ? 1 : 0

	readonly property real worldWidth: root.world?.width ?? 1
	readonly property real worldHeight: root.world?.height ?? 1
	readonly property real fitZoom: Math.max(0.05, Math.min(root.width / root.worldWidth, root.height / root.worldHeight) * 1.08)
	readonly property real maxZoom: 8
	readonly property string sprites: root.world?.sprites ?? ""
	readonly property bool close: root.zoom >= 1.5 && root.until >= 254 && root.focusDay < 0
	readonly property real sharp: Math.max(0, Math.min(1, (root.zoom - 1.25) / 0.6))
	readonly property real hour: {
		const now = new Date(root.minute);
		return now.getHours() + now.getMinutes() / 60;
	}
	readonly property real night: Math.max(0, Math.min(1, Math.abs(root.hour - 13) / 2 - 3))
	readonly property string weather: Plugins.on("weather") ? String(Weather.icon) : ""

	property real camX: root.worldWidth / 2
	property real camY: root.worldHeight / 2
	property real zoom: 0.3
	property real targetX: root.camX
	property real targetY: root.camY
	property real targetZoom: root.zoom
	property real ease: 3
	property real clock: 0
	property real minute: Date.now()
	property int hovered: -1
	property point pointer: Qt.point(0, 0)
	property string shownFolder: ""
	property var shown: null

	property var nearby: []
	property var pickIndex: ({})

	function findNearby() {
		if (!root.interactive) return;
		const out = [];
		if (root.close && root.zoom >= 1.5) {
			const boxes = [];
			const all = (root.shown?.labels ?? []).filter(label => root.inView(label[0], label[1], 0)).sort((a, b) => b[3] - a[3]);
			for (const label of all) {
				const w = label[2].length * 7 + 10;
				const px = (label[0] - root.camX) * root.zoom, py = (label[1] - root.camY) * root.zoom;
				if (boxes.some(box => Math.abs(box[0] - px) < (box[2] + w) / 2 && Math.abs(box[1] - py) < 18)) continue;
				boxes.push([px, py, w]);
				out.push(label);
				if (out.length >= 28) break;
			}
		}
		const key = JSON.stringify(out.map(label => label[2] + label[0]));
		if (key !== root.nearbyKey) {
			root.nearbyKey = key;
			root.nearby = out;
		}
	}
	property string nearbyKey: ""

	onShownChanged: {
		const index = {};
		for (const pick of root.shown?.picks ?? []) {
			const cell = `${Math.floor(pick[0] / 30)},${Math.floor(pick[1] / 30)}`;
			(index[cell] = index[cell] ?? []).push(pick);
		}
		root.pickIndex = index;
	}

	signal plotClicked(int index)
	signal emptyClicked

	Behavior on focusAmount {
		NumberAnimation { duration: 500; easing.type: Easing.InOutQuad }
	}

	function clampTargets() {
		root.targetZoom = Math.max(root.fitZoom * 0.85, Math.min(root.maxZoom, root.targetZoom));
		root.targetX = Math.max(0, Math.min(root.worldWidth, root.targetX));
		root.targetY = Math.max(0, Math.min(root.worldHeight, root.targetY));
	}

	function flyTo(x, y, zoom) {
		root.ease = 2.2;
		root.targetX = x;
		root.targetY = y;
		root.targetZoom = zoom;
		root.clampTargets();
	}

	function fit() {
		root.flyTo(root.worldWidth / 2, root.worldHeight / 2, root.fitZoom);
	}

	function jump() {
		root.camX = root.targetX;
		root.camY = root.targetY;
		root.zoom = root.targetZoom;
	}

	function zoomAt(px, py, factor) {
		const next = Math.max(root.fitZoom * 0.85, Math.min(root.maxZoom, root.targetZoom * factor));
		const wx = root.targetX + (px - root.width / 2) / root.targetZoom;
		const wy = root.targetY + (py - root.height / 2) / root.targetZoom;
		root.ease = 9;
		root.targetX = wx - (px - root.width / 2) / next;
		root.targetY = wy - (py - root.height / 2) / next;
		root.targetZoom = next;
		root.clampTargets();
	}

	function toWorld(px, py) {
		return Qt.point(root.camX + (px - root.width / 2) / root.zoom, root.camY + (py - root.height / 2) / root.zoom);
	}

	function inView(x, y, margin) {
		const w = root.width / 2 / root.zoom + margin, h = root.height / 2 / root.zoom + margin;
		return Math.abs(x - root.camX) < w && Math.abs(y - root.camY) < h;
	}

	// the ticket whose house or tree is under the pointer
	function plotAt(px, py) {
		const spot = root.toWorld(px, py);
		const y = spot.y + 8;
		const cx = Math.floor(spot.x / 30), cy = Math.floor(y / 30);
		let best = -1, closest = 22 * 22;
		for (let a = cx - 1; a <= cx + 1; a++) {
			for (let b = cy - 1; b <= cy + 1; b++) {
				for (const pick of root.pickIndex[`${a},${b}`] ?? []) {
					const dx = pick[0] - spot.x, dy = pick[1] - y;
					if (dx * dx + dy * dy < closest) {
						closest = dx * dx + dy * dy;
						best = pick[2];
					}
				}
			}
		}
		return best;
	}

	function cityAt(px, py) {
		const spot = root.toWorld(px, py);
		for (const city of root.shown?.cities ?? []) {
			const plate = city.plate;
			if (spot.x > plate.x && spot.y > plate.z && spot.x < plate.x + plate.w && spot.y < plate.z + plate.h) return city;
		}
		return null;
	}

	// a new world replaces the old one only once it is loaded
	onFolderChanged: root.takeNext()
	onWorldChanged: root.takeNext()
	Component.onCompleted: root.takeNext()
	function takeNext() {
		if (root.folder === root.shownFolder) {
			root.shown = root.world;
			return;
		}
		nextGround.source = root.folder ? `file://${root.folder}/ground.jpg` : "";
		nextObjects.source = root.folder ? `file://${root.folder}/objects.png` : "";
	}
	function settle() {
		if (nextGround.status !== Image.Ready || nextObjects.status !== Image.Ready) return;
		root.shownFolder = root.folder;
		root.shown = root.world;
		nextGround.source = "";
		nextObjects.source = "";
	}

	Image { id: nextGround; visible: false; asynchronous: true; onStatusChanged: root.settle() }
	Image { id: nextObjects; visible: false; asynchronous: true; onStatusChanged: root.settle() }

	Image { id: groundImage; visible: false; source: root.shownFolder ? `file://${root.shownFolder}/ground.jpg` : ""; mipmap: true }
	Image { id: objectsImage; visible: false; source: root.shownFolder ? `file://${root.shownFolder}/objects.png` : ""; mipmap: true }
	Image { id: waterImage; visible: false; source: root.shownFolder ? `file://${root.shownFolder}/water.png` : "" }
	Image { id: birthImage; visible: false; source: root.shownFolder ? `file://${root.shownFolder}/birth.png` : ""; smooth: false }
	Image { id: depthImage; visible: false; source: root.shownFolder ? `file://${root.shownFolder}/depth.png` : ""; smooth: false }
	Image { id: swayImage; visible: false; source: root.shownFolder ? `file://${root.shownFolder}/sway.png` : "" }

	Timer {
		interval: root.rate
		repeat: true
		running: !root.paused && root.visible
		onTriggered: {
			root.clock += root.rate / 1000;
			walkers.advance(root.rate / 1000);
		}
	}

	Timer {
		interval: 60000
		repeat: true
		running: root.visible
		onTriggered: root.minute = Date.now()
	}

	Timer {
		interval: 700
		repeat: true
		running: root.visible && !root.paused
		triggeredOnStart: true
		onTriggered: {
			walkers.assign();
			root.findNearby();
		}
	}

	FrameAnimation {
		running: root.visible && (Math.abs(root.camX - root.targetX) > 0.02 || Math.abs(root.camY - root.targetY) > 0.02 || Math.abs(root.zoom - root.targetZoom) > 0.0005)
		onTriggered: {
			const t = 1 - Math.exp(-root.ease * Math.min(frameTime, 0.05));
			root.camX += (root.targetX - root.camX) * t;
			root.camY += (root.targetY - root.camY) * t;
			root.zoom *= Math.pow(root.targetZoom / root.zoom, t);
		}
	}

	ShaderEffect {
		anchors.fill: parent
		visible: root.shown !== null && groundImage.status === Image.Ready && objectsImage.status === Image.Ready
		fragmentShader: "shaders/world.frag.qsb"

		property var ground: groundImage
		property var objects: objectsImage
		property var water: waterImage
		property var birth: birthImage
		property var sway: swayImage
		property real time: root.clock
		property real zoom: root.zoom
		property real until: root.until
		property real focusDay: root.focusDay >= 0 ? Math.min(254, root.focusDay) : -9
		property real focusAmount: root.focusAmount
		property real night: root.night
		property point camera: Qt.point(root.camX, root.camY)
		property point view: Qt.point(root.width, root.height)
		property point size: Qt.point(root.worldWidth, root.worldHeight)
		property color deep: WorldPalette.deep
		property color shallow: WorldPalette.shallow
	}

	// ── everything in world units ─────────────────────────────────────────
	Item {
		id: land

		x: root.width / 2 - root.camX * root.zoom
		y: root.height / 2 - root.camY * root.zoom
		scale: root.zoom
		transformOrigin: Item.TopLeft
		visible: root.shown !== null

		Repeater {
			model: root.shown?.cities ?? []

			Item {
				id: city

				required property var modelData
				readonly property var plate: city.modelData.plate
				readonly property bool seen: root.close && root.inView(city.plate.x + city.plate.w / 2, city.plate.z + city.plate.h / 2, Math.max(city.plate.w, city.plate.h))

				Image {
					id: picture

					visible: false
					asynchronous: true
					source: root.zoom > 1.2 && city.seen ? `file://${city.plate.file}` : ""
				}

				ShaderEffect {
					x: city.plate.x
					y: city.plate.z
					width: city.plate.w
					height: city.plate.h
					opacity: picture.status === Image.Ready && root.close ? root.sharp : 0
					visible: opacity > 0
					fragmentShader: "shaders/plate.frag.qsb"

					property var plate: picture
					property var sway: swayImage
					property real time: root.clock
					property real night: root.night
					property rect rect: Qt.rect(city.plate.x, city.plate.z, city.plate.w, city.plate.h)
					property point size: Qt.point(root.worldWidth, root.worldHeight)

					Behavior on opacity {
						NumberAnimation { duration: 260 }
					}
				}

				Loader {
					active: city.seen && root.zoom >= 1.6
					sourceComponent: WorldCity {
						city: city.modelData
						clock: root.clock
						sprites: root.sprites
						night: root.night
					}
				}
			}
		}

		// boats at any distance
		Repeater {
			model: root.shown?.boats ?? []

			Image {
				id: boat

				required property var modelData
				required property int index
				readonly property real swing: Math.sin(root.clock * 0.05 + boat.index * 2)

				x: boat.modelData[0] + boat.swing * 46
				y: boat.modelData[1] + Math.sin(root.clock * 0.9 + boat.index) * 0.5
				width: 20
				height: 18
				mirror: Math.cos(root.clock * 0.05 + boat.index * 2) < 0
				rotation: Math.sin(root.clock * 0.8 + boat.index) * 2.5
				source: root.sprites ? `file://${root.sprites}/_boat.png` : ""
				visible: root.until >= 254
			}
		}

		Repeater {
			id: walkersView

			model: walkers.size

			ShaderEffect {
				id: walker

				required property int index
				property real foot: 0
				property real frame: 0
				property real flip: 0
				property real lift: 0
				readonly property real night: root.night
				readonly property point pos: Qt.point(walker.x, walker.y)
				readonly property point size: Qt.point(root.worldWidth, root.worldHeight)
				property var person: sheet
				property var depth: depthImage

				visible: false
				width: 6
				height: 8
				fragmentShader: "shaders/person.frag.qsb"

				Image {
					id: sheet

					visible: false
					source: root.sprites ? `file://${root.sprites}/person${walker.index % 8}.png` : ""
				}
			}
		}

		// what only goes on while it goes on
		Loader {
			active: root.shown !== null && !!World.activeSite && root.until >= 254
			sourceComponent: BuildSite {
				site: World.activeSite
				progress: World.siteProgress
				clock: root.clock
				sprites: root.sprites
			}
		}

		WorldHappenings {
			world: root.shown
			clock: root.clock
			sprites: root.sprites
			visible: root.until >= 254 && root.focusDay < 0
		}

		Repeater {
			model: root.shown?.mills ?? []

			Image {
				id: sail

				required property var modelData

				x: sail.modelData[0] - 15
				y: sail.modelData[1] - 15
				width: 30
				height: 30
				visible: root.until >= 254 && root.zoom >= 0.8
				rotation: root.clock * 24 + sail.modelData[0]
				smooth: true
				source: root.sprites ? `file://${root.sprites}/_blade.png` : ""
			}
		}
	}

	QtObject {
		id: walkers

		readonly property int size: root.interactive ? 110 : 45
		property var states: []
		property string key: ""

		// who walks where: the towns in view, then the ticket's people on the roads
		function assign() {
			const paths = root.shown?.paths;
			if (!paths || !root.close || root.zoom < 1.6) {
				if (walkers.states.length) {
					for (let i = 0; i < walkers.size; i++) {
						const it = walkersView.itemAt(i);
						if (it) it.visible = false;
					}
					walkers.states = [];
					walkers.key = "";
				}
				return;
			}
			const sources = [];
			for (const city of root.shown.cities ?? []) {
				if (city.nodes && root.inView(city.plate.x + city.plate.w / 2, city.plate.z + city.plate.h / 2, Math.max(city.plate.w, city.plate.h) * 0.6)) sources.push({ id: `c${city.realm}`, count: city.people, from: city.nodes[0], to: city.nodes[1] });
			}
			for (const group of root.shown.groups ?? []) {
				if (root.inView(group.x, group.z, 60)) sources.push({ id: `g${group.plot}`, count: Math.min(group.count, 14), from: group.node, to: group.node + 1 });
			}
			const key = sources.map(source => source.id).join(",");
			if (key === walkers.key) return;
			walkers.key = key;
			const states = [];
			for (const source of sources) {
				for (let n = 0; n < source.count && states.length < walkers.size; n++) {
					const at = source.from + Math.floor(Math.random() * (source.to - source.from));
					const place = paths.nodes[at];
					states.push({ prev: -1, at, to: at, ox: (Math.random() - 0.5) * 4, oy: (Math.random() - 0.5) * 2.2, x: place[0], y: place[1], lift: paths.lifts[at] ?? 0, wait: Math.random() * 3, speed: 4.5 + Math.random() * 3.5, step: Math.random() });
				}
			}
			walkers.states = states;
			for (let i = 0; i < walkers.size; i++) {
				const it = walkersView.itemAt(i);
				if (!it) continue;
				it.visible = i < states.length;
				if (i < states.length) walkers.show(it, states[i], 0);
			}
		}

		function show(it, s, dx) {
			const x = s.x + s.ox, y = s.y + s.oy;
			it.x = x - 3;
			it.y = y - 7;
			it.z = y;
			it.foot = y;
			it.lift = s.lift;
			if (dx !== 0) it.flip = dx < 0 ? 1 : 0;
			it.frame = s.step < 0.5 ? 0 : 1;
		}

		function advance(dt) {
			const states = walkers.states;
			const paths = root.shown?.paths;
			if (!paths) return;
			for (let i = 0; i < states.length; i++) {
				const s = states[i], it = walkersView.itemAt(i);
				if (!it) continue;
				if (s.wait > 0) {
					s.wait -= dt;
					continue;
				}
				const goal = paths.nodes[s.to];
				const dx = goal[0] - s.x, dy = goal[1] - s.y, far = Math.hypot(dx, dy);
				if (far < 0.5) {
					const ways = paths.links[s.to] ?? [];
					const onward = ways.filter(way => way !== s.at);
					const next = onward.length ? onward[Math.floor(Math.random() * onward.length)] : ways[0] ?? s.to;
					s.at = s.to;
					s.to = next;
					if (Math.random() < 0.12) s.wait = 1 + Math.random() * 5;
					continue;
				}
				s.lift = Math.max(paths.lifts[s.at] ?? 0, paths.lifts[s.to] ?? 0);
				const go = Math.min(far, s.speed * dt);
				s.x += dx / far * go;
				s.y += dy / far * go;
				s.step = (s.step + dt * 3.4) % 1;
				walkers.show(it, s, dx);
			}
		}
	}

	// ── names, in the type of an old map ──────────────────────────────────
	Repeater {
		model: root.interactive ? (root.shown?.realms ?? []) : []

		Text {
			id: label

			required property var modelData
			readonly property real weight: label.modelData.houses + label.modelData.trees * 0.4

			x: root.width / 2 + (label.modelData.x - root.camX) * root.zoom - width / 2
			y: root.height / 2 + (label.modelData.z - root.camY) * root.zoom + 16
			visible: opacity > 0 && root.until >= label.modelData.first
			opacity: label.weight > 25 || root.zoom > root.fitZoom * 1.5 ? 1 : 0
			text: label.modelData.name
			color: "#fff3d2"
			style: Text.Outline
			styleColor: Qt.alpha("#2a1a0a", 0.75)
			font.family: "serif"
			font.italic: true
			font.letterSpacing: 1.2
			font.pixelSize: Math.round(Math.min(22, 13 + Math.sqrt(label.weight) * 0.4))

			Behavior on opacity {
				NumberAnimation { duration: 300 }
			}
		}
	}

	// up close, whatever one looks at has a name too
	Repeater {
		model: root.interactive ? root.nearby : []

		Text {
			required property var modelData

			x: root.width / 2 + (modelData[0] - root.camX) * root.zoom - width / 2
			y: root.height / 2 + (modelData[1] - root.camY) * root.zoom
			text: modelData[2]
			color: "#fff3d2"
			style: Text.Outline
			styleColor: Qt.alpha("#2a1a0a", 0.8)
			font.family: "serif"
			font.italic: true
			font.pixelSize: 12
		}
	}

	ShaderEffect {
		anchors.fill: parent
		visible: root.weather.includes("rain") || root.weather.includes("snow") || root.weather.includes("pouring")
		fragmentShader: "shaders/weather.frag.qsb"

		property real time: root.clock
		property real snow: root.weather.includes("snow") ? 1 : 0
		property point res: Qt.point(root.width, root.height)
	}

	MouseArea {
		anchors.fill: parent
		enabled: root.interactive
		hoverEnabled: true
		acceptedButtons: Qt.LeftButton | Qt.MiddleButton
		property point last
		property bool dragged: false

		onPressed: mouse => {
			last = Qt.point(mouse.x, mouse.y);
			dragged = false;
		}
		onPositionChanged: mouse => {
			root.pointer = Qt.point(mouse.x, mouse.y);
			if (pressed) {
				if (Math.hypot(mouse.x - last.x, mouse.y - last.y) > 3) dragged = true;
				root.ease = 14;
				root.targetX -= (mouse.x - last.x) / root.zoom;
				root.targetY -= (mouse.y - last.y) / root.zoom;
				root.clampTargets();
				last = Qt.point(mouse.x, mouse.y);
			} else {
				root.hovered = root.plotAt(mouse.x, mouse.y);
			}
		}
		onExited: root.hovered = -1
		onClicked: mouse => {
			if (dragged) return;
			const city = root.zoom < 2.6 ? root.cityAt(mouse.x, mouse.y) : null;
			if (city) {
				root.flyTo(city.centre[0], city.centre[1] + 40, 3.4);
				return;
			}
			const plot = root.plotAt(mouse.x, mouse.y);
			if (plot >= 0) root.plotClicked(plot);
			else root.emptyClicked();
		}
		onWheel: wheel => root.zoomAt(wheel.x, wheel.y, Math.pow(1.0018, wheel.angleDelta.y))
	}
}
