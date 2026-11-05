pragma ComponentBehavior: Bound

import QtQuick
import "Geometry.js" as Geo
import "Recipe.js" as Recipe

// A picture with its recipe, at the size of the result in pixels (scaled by
// whoever shows it). A small decode is there at once; the full picture
// comes when `full` asks for it (zoomed in, editing, saving) and fades in
// over it. Without changes it is the plain picture; with them one shader
// pass does geometry and colour (shaders/develop.frag).
Item {
	id: root

	property string source: ""
	// upright size in pixels, known before anything is decoded
	property real sourceWidth: 1
	property real sourceHeight: 1
	property var recipe: Recipe.blank()
	// the crop left out: the whole straightened picture (while cropping)
	property bool cropless: false
	property bool full: false
	property bool clipWarning: false
	// before / after: left of this share of the width the colours are untouched (0: off)
	property real split: 0
	// the longest side of the quick decode
	property int previewSide: 2048
	// the picture is there to be shown (the quick one at least)
	readonly property bool ready: small.status === Image.Ready || big.status === Image.Ready
	readonly property bool sharp: big.status === Image.Ready
	readonly property bool failed: small.status === Image.Error && (big.status === Image.Error || !root.full)

	readonly property var geometry: root.cropless ? Object.assign({}, Geo.normalised(root.recipe?.geometry), { crop: { x: 0, y: 0, w: 1, h: 1 } }) : Geo.normalised(root.recipe?.geometry)
	readonly property var outSize: Geo.outputSize(root.geometry, root.sourceWidth, root.sourceHeight)
	readonly property bool shaped: !Geo.isIdentity(root.geometry)
	readonly property bool coloured: !Recipe.colourIsPlain(root.recipe)
	readonly property bool cut: !!root.recipe?.cutout && mask.status === Image.Ready
	readonly property bool developed: root.shaped || root.coloured || root.cut || root.split > 0
	readonly property var tones: Recipe.uniforms(root.recipe)
	readonly property Image texture: big.status === Image.Ready ? big : small

	width: root.outSize[0]
	height: root.outSize[1]

	Image {
		id: small

		anchors.fill: parent
		source: root.source ? (root.source.startsWith("/") ? "file://" + root.source : root.source) : ""
		sourceSize: Qt.size(root.sourceWidth >= root.sourceHeight ? Math.min(root.previewSide, root.sourceWidth) : 0, root.sourceHeight > root.sourceWidth ? Math.min(root.previewSide, root.sourceHeight) : 0)
		asynchronous: true
		autoTransform: true
		cache: true
		smooth: true
		mipmap: true
		visible: !root.developed && big.opacity < 1
	}

	Image {
		id: big

		anchors.fill: parent
		source: root.full ? small.source : ""
		asynchronous: true
		autoTransform: true
		cache: false
		smooth: true
		mipmap: true
		visible: !root.developed && opacity > 0
		opacity: big.status === Image.Ready ? 1 : 0

		Behavior on opacity {
			NumberAnimation {
				duration: 180
			}
		}
	}

	Image {
		id: mask

		source: root.recipe?.cutout ? "file://" + root.recipe.cutout : ""
		asynchronous: true
		visible: false
		cache: false
	}

	// the curves as a lookup texture: a row per channel, a tiny picture
	// (PPM) made here and handed over as a data URL
	Image {
		id: lut

		readonly property var rows: Recipe.lut(root.recipe)

		source: {
			let text = "P3\n256 4\n255\n";
			for (let row = 0; row < 4; row += 1) {
				const values = lut.rows[Math.min(row, 2)];
				const line = [];
				for (let i = 0; i < 256; i += 1) {
					const v = Math.round(values[i] * 255);
					line.push(`${v} ${v} ${v}`);
				}
				text += line.join(" ") + "\n";
			}
			return "data:image/x-portable-pixmap;base64," + Qt.btoa(text);
		}
		visible: false
		cache: false
		smooth: true
	}

	ShaderEffect {
		id: effect

		anchors.fill: parent
		visible: root.developed && root.ready

		property var source: root.texture
		property var lut: lut
		property var mask: root.cut ? mask : root.texture
		property matrix4x4 geo: {
			const m = Geo.uniform(Geo.matrix(root.geometry, root.sourceWidth, root.sourceHeight));
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
		property real curves: root.tones.curves
		property real masked: root.cut ? 1 : 0
		property real clip: root.clipWarning ? 1 : 0
		property real split: root.split
		property color shadowTone: root.tones.shadowTone
		property color highlightTone: root.tones.highlightTone
		property size texel: Qt.size(1 / Math.max(1, root.texture.implicitWidth), 1 / Math.max(1, root.texture.implicitHeight))
		property size outSize: Qt.size(root.width, root.height)

		fragmentShader: "shaders/develop.frag.qsb"
	}
}
