pragma ComponentBehavior: Bound

import QtQuick
import QtQuick3D
import QtQuick3D.Helpers
import Quickshell.Io
import qs.style.theme
import qs.core.services
import qs.style.widgets

// The part in 3D: every extrusion of the G-code as a box (an instance table
// from scripts/printer/mesh.py), cut at the layer on the nozzle – below it
// solid, the layer itself hot, above it a ghost, and a glowing sheet where
// the cut runs. Dragging turns it (and lets it spin on), the wheel zooms, a
// double click puts the view back; left alone it turns slowly by itself.
// A job that is not printing builds itself up once when it is shown.
// In lay mode (an STL) the faces the part can rest on show under the
// pointer; a click on one lays the part on it (facePicked).
Item {
	id: root

	// ── laying on a face ─────────────────────────────────────────────────
	property bool layMode: false
	// [{ normal, offset, area, center, triangles }] in bed coordinates
	property var faces: []
	property int hoveredFace: -1
	// faces in a colour no filament and no heat has
	readonly property color faceColor: "#3ad0ff"
	signal facePicked(int index)

	onLayModeChanged: root.hoveredFace = -1

	FileView {
		id: facesFile

		path: root.job?.facesFile && (root.job?.faces ?? []).length > 0 ? root.job.facesFile : ""
		watchChanges: true
		printErrors: false
		onLoaded: {
			try {
				root.faces = JSON.parse(text());
			} catch (error) {
				root.faces = [];
			}
		}
		onPathChanged: if (path === "") root.faces = []
		onFileChanged: reload()
	}

	// a face's triangles in the scene (y up), a hair off the surface
	function positionsOf(face) {
		const out = [];
		const t = face.triangles ?? [];
		const n = face.normal;
		const off = 0.15;
		for (let i = 0; i + 2 < t.length; i += 3)
			out.push(Qt.vector3d(t[i] + n[0] * off, t[i + 2] + n[2] * off, -(t[i + 1] + n[1] * off)));
		return out;
	}
	readonly property var allFacePositions: root.layMode ? root.faces.reduce((all, face) => all.concat(root.positionsOf(face)), []) : []
	readonly property var hoverPositions: root.layMode && root.hoveredFace >= 0 && root.hoveredFace < root.faces.length ? root.positionsOf(root.faces[root.hoveredFace]) : []

	// the face under the pointer, from the picked point's normal and height
	function faceAt(x, y) {
		const result = view.pick(x, y);
		if (!result || result.objectHit !== faceHull) return -1;
		const n = result.sceneNormal;
		const bedNormal = [n.x, -n.z, n.y];
		const p = result.scenePosition;
		const local = [p.x + root.cx, -(p.z - root.cy), p.y - root.lift];
		let best = -1;
		let bestGap = Infinity;
		for (let i = 0; i < root.faces.length; i += 1) {
			const f = root.faces[i].normal;
			const dot = f[0] * bedNormal[0] + f[1] * bedNormal[1] + f[2] * bedNormal[2];
			if (Math.abs(dot) < 0.97) continue;
			const gap = Math.abs(f[0] * local[0] + f[1] * local[1] + f[2] * local[2] - root.faces[i].offset);
			if (gap < bestGap) {
				bestGap = gap;
				best = i;
			}
		}
		return best;
	}

	property var job: null
	// the printer's layer while it prints, -1 otherwise
	property int liveLayer: -1
	// what the view shows when it does not follow the printer, 0…1 of the layers
	property real scrub: 1
	readonly property bool live: root.liveLayer >= 0
	readonly property var shape: root.job?.shape ?? null
	readonly property bool ready: root.shape !== null && root.shape.count > 0
	readonly property int layers: root.shape?.zs?.length ?? 0
	readonly property var render: root.job ? (Printer.renders[root.job.id] ?? null) : null

	// the layer the cut is at, smoothly between layers
	property real at: root.live ? root.liveLayer : root.scrub * root.layers
	Behavior on at {
		enabled: root.live
		NumberAnimation {
			duration: 900
			easing.type: Easing.OutCubic
		}
	}
	readonly property real cut: {
		const zs = root.shape?.zs ?? [];
		if (zs.length === 0) return 0;
		const position = Math.max(0, Math.min(zs.length, root.at));
		const index = Math.floor(position);
		if (index <= 0) return zs[0] * position;
		if (index >= zs.length) return zs[zs.length - 1] + 0.01;
		return zs[index - 1] + (zs[index] - zs[index - 1]) * (position - index);
	}
	readonly property real layerHeight: Math.max(0.08, root.job?.meta?.layerHeight || 0.2)
	readonly property int shownLayer: Math.max(1, Math.min(root.layers, Math.ceil(root.at)))
	readonly property bool complete: root.at >= root.layers - 0.01

	// framing: the part's middle, its size
	readonly property var bounds: root.shape?.bounds ?? [0, 0, 1, 1]
	readonly property real cx: (root.bounds[0] + root.bounds[2]) / 2
	readonly property real cy: (root.bounds[1] + root.bounds[3]) / 2
	readonly property real height3d: root.shape?.height ?? 1
	readonly property real size: Math.max(20, root.bounds[2] - root.bounds[0], root.bounds[3] - root.bounds[1], root.height3d * 1.2)

	// the view: turned (yaw), tilted (pitch), zoomed
	readonly property real homeYaw: 35
	readonly property real homePitch: -26
	property real yaw: root.homeYaw
	property real pitch: root.homePitch
	property real zoom: 1
	property bool held: false
	property real idleSince: 0
	// dropped in from above when a part is shown
	property real lift: 0
	property real intro: 1
	// the swing it arrives with, on top of the yaw
	property real swing: 0
	property real homeTo: root.homeYaw

	function home() {
		spin.stop();
		root.homeTo = root.homeYaw + Math.round((root.yaw - root.homeYaw) / 360) * 360;
		homing.restart();
	}

	function build() {
		if (!root.ready) return;
		root.intro = 0;
		root.lift = root.size * 0.35;
		arrive.restart();
		if (!root.live) {
			root.scrub = 0;
			grow.restart();
		}
	}

	// only another job builds itself up again, not the same one sent anew (a new colour, a picture)
	readonly property string jobId: root.job?.id ?? ""
	onJobIdChanged: Qt.callLater(root.build)
	onReadyChanged: if (root.ready) Qt.callLater(root.build)

	ParallelAnimation {
		id: arrive

		NumberAnimation {
			target: root
			property: "intro"
			to: 1
			duration: 700
			easing.type: Easing.OutCubic
		}
		NumberAnimation {
			target: root
			property: "lift"
			to: 0
			duration: 900
			easing.type: Easing.OutBack
			easing.overshoot: 1.1
		}
		NumberAnimation {
			target: root
			property: "swing"
			from: -70
			to: 0
			duration: 1400
			easing.type: Easing.OutCubic
		}
	}

	NumberAnimation {
		id: grow

		target: root
		property: "scrub"
		from: 0
		to: 1
		duration: 2400
		easing.type: Easing.BezierSpline
		easing.bezierCurve: Motion.decel
	}

	ParallelAnimation {
		id: homing

		NumberAnimation {
			target: root
			property: "yaw"
			to: root.homeTo
			duration: 700
			easing.type: Easing.OutCubic
		}
		NumberAnimation {
			target: root
			property: "pitch"
			to: root.homePitch
			duration: 700
			easing.type: Easing.OutCubic
		}
		NumberAnimation {
			target: root
			property: "zoom"
			to: 1
			duration: 700
			easing.type: Easing.OutCubic
		}
	}

	// the spin a drag lets go with
	NumberAnimation {
		id: spin

		target: root
		property: "yaw"
		duration: 1100
		easing.type: Easing.OutQuart
	}

	// left alone, it turns slowly
	FrameAnimation {
		running: root.visible && root.ready && !root.held && !root.layMode && !spin.running && !homing.running && !arrive.running
		onTriggered: {
			if (Date.now() - root.idleSince > 3500) root.yaw += frameTime * 7;
		}
	}

	View3D {
		id: view

		anchors.fill: parent
		opacity: root.intro
		visible: root.ready

		environment: SceneEnvironment {
			backgroundMode: SceneEnvironment.Transparent
			antialiasingMode: SceneEnvironment.MSAA
			antialiasingQuality: SceneEnvironment.High
			aoEnabled: true
			aoStrength: 55
			aoDistance: root.size * 0.04
			aoSoftness: 40
			tonemapMode: SceneEnvironment.TonemapModeLinear
		}

		Node {
			id: pivot

			position: Qt.vector3d(0, root.height3d * 0.42, 0)
			eulerRotation: Qt.vector3d(root.pitch, root.yaw + root.swing, 0)

			PerspectiveCamera {
				z: root.size * 2.3 / root.zoom
				fieldOfView: 32
				clipNear: 1
				clipFar: 5000
			}
		}

		DirectionalLight {
			eulerRotation: Qt.vector3d(-52, root.yaw - 40, 0)
			brightness: 1.25
			ambientColor: Qt.rgba(0.42, 0.43, 0.46, 1)
			castsShadow: true
			shadowMapQuality: Light.ShadowMapQualityHigh
			shadowFactor: 35
			shadowBias: 0.4
		}

		DirectionalLight {
			eulerRotation: Qt.vector3d(-18, root.yaw + 150, 0)
			brightness: 0.45
		}

		// the bed under the part
		Model {
			source: "#Rectangle"
			eulerRotation.x: -90
			scale: Qt.vector3d(root.size * 0.07, root.size * 0.07, 1)
			materials: CustomMaterial {
				property color tint: Theme.fg
				property vector2d center: Qt.vector2d(0, 0)
				property real spacing: 10
				property real radius: root.size * 2.2
				property real opacity: root.intro
				shadingMode: CustomMaterial.Unshaded
				sourceBlend: CustomMaterial.SrcAlpha
				destinationBlend: CustomMaterial.OneMinusSrcAlpha
				depthDrawMode: Material.NeverDepthDraw
				vertexShader: Qt.resolvedUrl("shaders/plane.vert")
				fragmentShader: Qt.resolvedUrl("shaders/bed.frag")
			}
		}

		Node {
			// the part's middle on the bed's
			position: Qt.vector3d(-root.cx, root.lift, root.cy)

			Model {
				source: "#Cube"
				instancing: FileInstancing {
					source: root.ready ? `file://${root.job.preview}/model.bin` : ""
				}
				materials: CustomMaterial {
					property real cut: root.cut
					property real layerHeight: root.layerHeight
					property real lift: root.lift
					property real glow: root.complete && !root.live ? 0 : 1
					property color hot: Printer.hot
					vertexShader: Qt.resolvedUrl("shaders/part.vert")
					fragmentShader: Qt.resolvedUrl("shaders/part.frag")

					Behavior on glow {
						NumberAnimation {
							duration: 600
						}
					}
				}
			}

			// the faces the part can rest on: invisible but pickable, the one pointed at lit
			Model {
				id: faceHull

				visible: root.layMode && root.allFacePositions.length > 0
				pickable: root.layMode
				geometry: ProceduralMesh {
					positions: root.allFacePositions
				}
				materials: PrincipledMaterial {
					lighting: PrincipledMaterial.NoLighting
					baseColor: Qt.alpha(root.faceColor, 0.16)
					alphaMode: PrincipledMaterial.Blend
					cullMode: Material.NoCulling
					depthDrawMode: Material.NeverDepthDraw
				}
			}

			Model {
				visible: root.hoverPositions.length > 0
				geometry: ProceduralMesh {
					positions: root.hoverPositions
				}
				materials: PrincipledMaterial {
					lighting: PrincipledMaterial.NoLighting
					baseColor: Qt.alpha(root.faceColor, 0.75)
					alphaMode: PrincipledMaterial.Blend
					cullMode: Material.NoCulling
					depthDrawMode: Material.NeverDepthDraw
				}
			}

			Model {
				source: "#Cube"
				instancing: FileInstancing {
					source: root.ready ? `file://${root.job.preview}/model.bin` : ""
				}
				materials: CustomMaterial {
					property real cut: root.cut
					property real lift: root.lift
					property real opacity: 0.06
					property color tint: Theme.fg
					shadingMode: CustomMaterial.Unshaded
					sourceBlend: CustomMaterial.SrcAlpha
					destinationBlend: CustomMaterial.OneMinusSrcAlpha
					depthDrawMode: Material.NeverDepthDraw
					vertexShader: Qt.resolvedUrl("shaders/ghost.vert")
					fragmentShader: Qt.resolvedUrl("shaders/ghost.frag")
				}
			}
		}

		// the sheet where the part is cut
		Model {
			id: sheet

			property real time: 0

			visible: !root.complete || root.live
			source: "#Rectangle"
			eulerRotation.x: -90
			y: root.cut + root.lift + 0.05
			scale: Qt.vector3d((root.bounds[2] - root.bounds[0] + 8) / 100, (root.bounds[3] - root.bounds[1] + 8) / 100, 1)
			materials: CustomMaterial {
				property color hot: Printer.hot
				property real time: sheet.time
				property real opacity: root.intro
				shadingMode: CustomMaterial.Unshaded
				sourceBlend: CustomMaterial.SrcAlpha
				destinationBlend: CustomMaterial.One
				depthDrawMode: Material.NeverDepthDraw
				cullMode: Material.NoCulling
				vertexShader: Qt.resolvedUrl("shaders/plane.vert")
				fragmentShader: Qt.resolvedUrl("shaders/cut.frag")
			}

			FrameAnimation {
				running: root.visible && sheet.visible
				onTriggered: sheet.time += frameTime
			}
		}
	}

	// turning and zooming
	DragHandler {
		id: drag

		property real lastX: 0
		property real lastY: 0
		property real velocity: 0
		property real lastTime: 0

		target: null
		enabled: root.ready
		onActiveChanged: {
			root.held = active;
			root.idleSince = Date.now();
			if (active) {
				spin.stop();
				homing.stop();
				lastX = centroid.position.x;
				lastY = centroid.position.y;
				velocity = 0;
				lastTime = Date.now();
			} else if (Math.abs(velocity) > 0.05) {
				spin.from = root.yaw;
				spin.to = root.yaw + velocity * 260;
				spin.restart();
			}
		}
		onCentroidChanged: {
			if (!active) return;
			const dx = centroid.position.x - lastX;
			const dy = centroid.position.y - lastY;
			const now = Date.now();
			const dt = Math.max(1, now - lastTime);
			root.yaw -= dx * 0.45;
			root.pitch = Math.max(-85, Math.min(5, root.pitch - dy * 0.35));
			velocity = velocity * 0.6 + (-dx * 0.45 / dt) * 0.4;
			lastX = centroid.position.x;
			lastY = centroid.position.y;
			lastTime = now;
		}
	}

	WheelHandler {
		enabled: root.ready
		onWheel: event => {
			root.idleSince = Date.now();
			root.zoom = Math.max(0.5, Math.min(4, root.zoom * Math.pow(1.0018, event.angleDelta.y)));
		}
	}

	TapHandler {
		enabled: root.ready
		onDoubleTapped: root.home()
		onTapped: eventPoint => {
			if (!root.layMode) return;
			const face = root.faceAt(eventPoint.position.x, eventPoint.position.y);
			if (face >= 0) root.facePicked(face);
		}
	}

	HoverHandler {
		enabled: root.ready
		cursorShape: root.layMode ? (root.hoveredFace >= 0 ? Qt.PointingHandCursor : Qt.CrossCursor) : (drag.active ? Qt.ClosedHandCursor : Qt.OpenHandCursor)
		onPointChanged: {
			if (root.layMode && !drag.active) root.hoveredFace = root.faceAt(point.position.x, point.position.y);
		}
		onHoveredChanged: if (!hovered) root.hoveredFace = -1
	}

	// waiting for the part: the slicer's picture, a spinner
	Image {
		anchors.centerIn: parent
		width: parent.width * 0.5
		height: parent.height * 0.5
		fillMode: Image.PreserveAspectFit
		source: root.job && !root.ready && root.render !== null ? `file://${root.job.preview}/thumb.png` : ""
		visible: status === Image.Ready
		opacity: 0.45
	}

	Column {
		anchors.centerIn: parent
		spacing: 10
		visible: root.job !== null && !root.ready

		Spinner {
			anchors.horizontalCenter: parent.horizontalCenter
			width: 34
			height: 34
		}

		StyledText {
			anchors.horizontalCenter: parent.horizontalCenter
			text: root.job?.slicing ? "Slicing" : (root.job?.kind === "model" && !root.job?.file ? "Waiting for the slicer" : "Building the part")
			tone: Theme.textMuted
			font.pixelSize: Theme.size.label
		}
	}
}
