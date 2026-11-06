pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import QtMultimedia
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "../viewer/Geometry.js" as Geo
import "../viewer/Recipe.js" as Recipe

// The picture. Plain, the film is drawn straight from the decoder; edited
// (the editor's crop, turn, straightening and colours) it goes through the
// picture viewer's one shader pass (viewer/shaders/develop.frag), live, so
// what is seen is what the export makes. Around it the film's own colours
// glow softly; the subtitles are drawn here in the shell's type.
Item {
	id: root

	property bool editing: false
	property var recipe: Video.recipe
	// the crop left out (while it is being set)
	property bool cropless: false
	property color accent: Theme.primary
	// room kept free around the picture (the editor's panels)
	property real padLeft: 0
	property real padRight: 0
	property real padTop: 0
	property real padBottom: 0
	// the subtitles go up while the controls are shown
	property real subtitleLift: 0
	property bool glow: Video.setting("ambient", true) && !root.editing
	// before / after: left of this share the colours are untouched (0 off)
	property real split: 0

	// the player's own way of looking: turned, another shape, filling the window, zoomed
	property int viewRot: 0
	property real aspectOverride: 0
	property bool fill: false
	property real zoom: 1
	property real panX: 0
	property real panY: 0

	readonly property alias video: video
	readonly property alias frame: frame

	// the source's size, upright (the file's rotation already applied)
	readonly property real srcW: {
		const m = Video.meta;
		if (!m || !m.width) return 1920;
		return Math.abs(Number(m.rotation) || 0) % 180 === 90 ? m.height : m.width;
	}
	readonly property real srcH: {
		const m = Video.meta;
		if (!m || !m.height) return 1080;
		return Math.abs(Number(m.rotation) || 0) % 180 === 90 ? m.width : m.height;
	}

	readonly property var geometry: {
		if (!root.editing) return Geo.defaults();
		const g = Geo.normalised(root.recipe?.geometry);
		return root.cropless ? Object.assign({}, g, { crop: { x: 0, y: 0, w: 1, h: 1 } }) : g;
	}
	readonly property var outSize: Geo.outputSize(root.geometry, root.srcW, root.srcH)
	readonly property real outAspect: {
		if (root.editing) return root.outSize[0] / Math.max(1, root.outSize[1]);
		const a = root.aspectOverride > 0 ? root.aspectOverride : root.srcW / Math.max(1, root.srcH);
		return root.viewRot % 2 === 1 ? 1 / a : a;
	}
	readonly property bool coloured: root.editing && !Recipe.colourIsPlain(root.recipe)
	readonly property bool shaped: root.editing && !Geo.isIdentity(root.geometry)
	readonly property bool developed: root.coloured || root.shaped || (root.editing && root.split > 0)
	readonly property var tones: Recipe.uniforms(root.recipe)

	// where the picture lies, fitted into the room left for it
	readonly property real roomW: Math.max(1, root.width - root.padLeft - root.padRight)
	readonly property real roomH: Math.max(1, root.height - root.padTop - root.padBottom)
	readonly property real fitW: {
		const wide = root.roomW / root.roomH > root.outAspect;
		return root.fill !== wide ? root.roomH * root.outAspect : root.roomW;
	}
	readonly property real fitH: root.fitW / root.outAspect
	readonly property rect frameRect: Qt.rect(root.padLeft + (root.roomW - root.fitW) / 2, root.padTop + (root.roomH - root.fitH) / 2, root.fitW, root.fitH)

	function resetView() {
		root.zoom = 1;
		root.panX = 0;
		root.panY = 0;
	}

	// zoomed about a point of the window
	function zoomAt(factor, x, y) {
		const next = Math.max(1, Math.min(8, root.zoom * factor));
		const cx = root.frameRect.x + root.frameRect.width / 2 + root.panX;
		const cy = root.frameRect.y + root.frameRect.height / 2 + root.panY;
		const k = next / root.zoom;
		root.panX += (x - cx) * (1 - k);
		root.panY += (y - cy) * (1 - k);
		root.zoom = next;
		if (root.zoom <= 1.001) root.resetView();
		else root.clampPan();
	}

	function clampPan() {
		const mx = Math.max(0, (root.frameRect.width * root.zoom - root.width) / 2 + 40);
		const my = Math.max(0, (root.frameRect.height * root.zoom - root.height) / 2 + 40);
		root.panX = Math.max(-mx, Math.min(mx, root.panX));
		root.panY = Math.max(-my, Math.min(my, root.panY));
	}

	onEditingChanged: root.resetView()

	// ── the glow of the film around it ─────────────────────────────────────
	ShaderEffectSource {
		id: glowSource

		sourceItem: frame
		live: glowLayer.visible
		hideSource: false
		visible: false
		textureSize: Qt.size(48, 27)
		smooth: true
	}

	MultiEffect {
		id: glowLayer

		x: root.frameRect.x - root.frameRect.width * 0.1
		y: root.frameRect.y - root.frameRect.height * 0.12
		width: root.frameRect.width * 1.2
		height: root.frameRect.height * 1.24
		source: glowSource
		visible: opacity > 0.01
		opacity: root.glow && !Video.fullscreen && Video.current && !Video.loading && root.zoom === 1 && (root.frameRect.width < root.width - 40 || root.frameRect.height < root.height - 40) ? 0.55 : 0
		blurEnabled: true
		blur: 1
		blurMax: 64
		saturation: 0.35
		autoPaddingEnabled: false

		Behavior on opacity {
			Anim {
				duration: Motion.extraLong
			}
		}
	}

	// ── the picture ────────────────────────────────────────────────────────
	Item {
		id: frame

		x: root.frameRect.x
		y: root.frameRect.y
		width: root.frameRect.width
		height: root.frameRect.height
		// the picture's fade from and to black, as the export makes it
		opacity: {
			if (!root.editing) return 1;
			const f = root.recipe?.fade ?? {};
			const t = Video.outPosition, end = Video.outDuration;
			let k = 1;
			if ((f.in || 0) > 0) k = Math.min(k, t / f.in);
			if ((f.out || 0) > 0) k = Math.min(k, (end - t) / f.out);
			return Math.max(0, Math.min(1, k));
		}
		transform: [
			Scale {
				origin.x: frame.width / 2
				origin.y: frame.height / 2
				xScale: root.zoom
				yScale: root.zoom
			},
			Translate {
				x: root.panX
				y: root.panY
			}
		]

		Behavior on x {
			enabled: root.editing
			SpatialAnim {
				duration: Motion.long
			}
		}
		Behavior on y {
			enabled: root.editing
			SpatialAnim {
				duration: Motion.long
			}
		}
		Behavior on width {
			enabled: root.editing
			SpatialAnim {
				duration: Motion.long
			}
		}
		Behavior on height {
			enabled: root.editing
			SpatialAnim {
				duration: Motion.long
			}
		}

		// the film itself: filling the frame when plain, at its own shape
		// (and only a texture for the shader) when developed
		Item {
			id: plainBox

			anchors.centerIn: parent
			width: root.viewRot % 2 === 1 ? frame.height : frame.width
			height: root.viewRot % 2 === 1 ? frame.width : frame.height
			rotation: root.viewRot * 90

			Behavior on rotation {
				RotationAnimation {
					duration: Motion.long
					direction: RotationAnimation.Shortest
					easing.type: Easing.OutCubic
				}
			}

			VideoOutput {
				id: video

				readonly property real texW: Math.min(root.srcW, 2560)

				width: root.developed ? video.texW : plainBox.width
				height: root.developed ? video.texW * root.srcH / root.srcW : plainBox.height
				fillMode: VideoOutput.Stretch
				opacity: Video.current && !Video.startPending ? 1 : 0

				Behavior on opacity {
					Anim {
						duration: Motion.long
					}
				}
			}
		}

		ShaderEffectSource {
			id: videoTexture

			sourceItem: root.developed ? video : null
			hideSource: root.developed
			live: true
			visible: false
			smooth: true
		}

		ShaderEffect {
			id: develop

			anchors.fill: parent
			visible: root.developed

			property var source: videoTexture
			property var lut: root.lut
			property var mask: videoTexture
			property matrix4x4 geo: {
				const m = Geo.uniform(Geo.matrix(root.geometry, root.srcW, root.srcH));
				return Qt.matrix4x4(m[0], m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8], m[9], m[10], m[11], m[12], m[13], m[14], m[15]);
			}
			property real exposure: root.tones.exposure
			property real brightness: root.tones.brightness
			property real contrast: root.tones.contrast
			property real highlights: root.tones.highlights
			property real shadows: root.tones.shadows
			property real temperature: root.tones.temperature
			property real tint: root.tones.tint
			property real saturation: root.tones.saturation
			property real vibrance: root.tones.vibrance
			property real fade: root.tones.fade
			property real vignette: root.tones.vignette
			property real grain: root.tones.grain
			property real sharpen: root.tones.sharpen
			property real denoise: root.tones.denoise
			property real curves: root.tones.curves
			property real masked: 0
			property real clip: 0
			property real split: root.split
			property color shadowTone: root.tones.shadowTone
			property color highlightTone: root.tones.highlightTone
			property size texel: Qt.size(1 / Math.max(1, video.width), 1 / Math.max(1, video.height))
			property size outSize: Qt.size(develop.width, develop.height)

			fragmentShader: "../viewer/shaders/develop.frag.qsb"
		}

		// before / after: the line between them
		Rectangle {
			visible: root.developed && root.split > 0
			x: root.split * frame.width - 1
			width: 2
			height: frame.height
			color: "white"
			opacity: 0.8
		}
	}

	// the curves as a lookup texture (as the viewer makes it): two, so a curve
	// being dragged never shows an empty one
	readonly property string lutSource: {
		const rows = Recipe.lut(root.recipe);
		let text = "P3\n256 4\n255\n";
		for (let row = 0; row < 4; row += 1) {
			const values = rows[Math.min(row, 2)];
			const line = [];
			for (let i = 0; i < 256; i += 1) {
				const v = Math.round(values[i] * 255);
				line.push(`${v} ${v} ${v}`);
			}
			text += line.join(" ") + "\n";
		}
		return "data:image/x-portable-pixmap;base64," + root.base64(text);
	}

	// ASCII to base64 (Qt.btoa(string) is on its way out)
	function base64(text) {
		const abc = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
		let out = "";
		for (let i = 0; i < text.length; i += 3) {
			const a = text.charCodeAt(i), b = text.charCodeAt(i + 1), c = text.charCodeAt(i + 2);
			const n = (a << 16) | ((b || 0) << 8) | (c || 0);
			out += abc[(n >> 18) & 63] + abc[(n >> 12) & 63] + (i + 1 < text.length ? abc[(n >> 6) & 63] : "=") + (i + 2 < text.length ? abc[n & 63] : "=");
		}
		return out;
	}
	property int lutFront: 0
	readonly property Image lut: root.lutFront === 0 ? lutA : lutB

	onLutSourceChanged: if (root.coloured) (root.lutFront === 0 ? lutB : lutA).source = root.lutSource
	onColouredChanged: if (root.coloured) (root.lutFront === 0 ? lutB : lutA).source = root.lutSource

	Image {
		id: lutA

		visible: false
		cache: false
		onStatusChanged: if (status === Image.Ready && source.toString() === root.lutSource) root.lutFront = 0
	}

	Image {
		id: lutB

		visible: false
		cache: false
		onStatusChanged: if (status === Image.Ready && source.toString() === root.lutSource) root.lutFront = 1
	}

	// ── the words ──────────────────────────────────────────────────────────
	Item {
		id: words

		readonly property real size: Math.max(14, Math.min(root.frameRect.height, root.height) * 0.052 * Video.setting("subSize", 1))
		readonly property bool box: Video.setting("subBox", false)
		readonly property real bottomOf: Math.min(root.frameRect.y + root.frameRect.height, root.height) - Math.max(0, root.subtitleLift - (root.height - root.frameRect.y - root.frameRect.height))

		x: Math.max(0, root.frameRect.x)
		width: Math.min(root.width, root.frameRect.width)
		y: Math.max(8, root.frameRect.y + root.frameRect.height * Video.setting("subPosition", 0.92) - subText.height - Math.max(0, root.subtitleLift - (root.height - root.frameRect.y - root.frameRect.height) * 0.5))
		height: subText.height
		visible: Video.subText !== "" && !Video.loading

		Behavior on y {
			SpatialAnim {
				duration: Motion.medium
			}
		}

		Rectangle {
			anchors.centerIn: subText
			width: subText.contentWidth + words.size * 0.8
			height: subText.contentHeight + words.size * 0.3
			radius: words.size * 0.25
			color: Qt.rgba(0, 0, 0, 0.62)
			visible: words.box
		}

		Text {
			id: subText

			anchors.horizontalCenter: parent.horizontalCenter
			width: parent.width * 0.86
			text: Video.subText
			textFormat: Text.StyledText
			wrapMode: Text.WordWrap
			horizontalAlignment: Text.AlignHCenter
			color: "white"
			style: words.box ? Text.Normal : Text.Outline
			styleColor: Qt.rgba(0, 0, 0, 0.85)
			font.family: Theme.fontFamily
			font.pixelSize: words.size
			font.weight: Font.DemiBold
			lineHeight: 1.05
		}
	}
}
