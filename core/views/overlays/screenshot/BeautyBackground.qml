pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import QtQuick.Shapes

// One background of the beautifier, resolution independent (it is drawn at
// preview size and again at export size):
//   { kind: "linear", angle, stops: [[pos, colour], …] }   CSS-like angle
//   { kind: "mesh", base, blobs: [[x, y, radius, colour], …] } relative
//   { kind: "solid", color } · { kind: "image", path, blur } · { kind: "none" }
Item {
	id: root

	property var spec: ({ kind: "none" })
	readonly property string kind: String(root.spec?.kind ?? "none")

	// ── linear ─────────────────────────────────────────────────────────────
	readonly property var stops: {
		const out = (root.spec?.stops ?? []).slice(0, 4);
		while (out.length < 4) out.push(out.length > 0 ? [1, out[out.length - 1][1]] : [1, "transparent"]);
		return out;
	}
	readonly property real angle: (Number(root.spec?.angle ?? 135) * Math.PI) / 180
	readonly property real span: Math.abs(root.width * Math.sin(root.angle)) + Math.abs(root.height * Math.cos(root.angle))

	Shape {
		anchors.fill: parent
		visible: root.kind === "linear"

		ShapePath {
			strokeWidth: -1
			strokeColor: "transparent"
			fillGradient: LinearGradient {
				x1: root.width / 2 - Math.sin(root.angle) * root.span / 2
				y1: root.height / 2 + Math.cos(root.angle) * root.span / 2
				x2: root.width / 2 + Math.sin(root.angle) * root.span / 2
				y2: root.height / 2 - Math.cos(root.angle) * root.span / 2

				GradientStop {
					position: root.stops[0][0]
					color: root.stops[0][1]
				}
				GradientStop {
					position: root.stops[1][0]
					color: root.stops[1][1]
				}
				GradientStop {
					position: root.stops[2][0]
					color: root.stops[2][1]
				}
				GradientStop {
					position: root.stops[3][0]
					color: root.stops[3][1]
				}
			}

			PathRectangle {
				width: root.width
				height: root.height
			}
		}
	}

	// ── mesh: soft radial blobs over a base colour ─────────────────────────
	Rectangle {
		anchors.fill: parent
		visible: root.kind === "mesh" || root.kind === "solid"
		color: root.kind === "solid" ? root.spec.color : (root.spec?.base ?? "transparent")
	}

	Repeater {
		model: root.kind === "mesh" ? root.spec.blobs : []

		delegate: Shape {
			id: blob

			required property var modelData
			readonly property real reach: Math.max(root.width, root.height) * blob.modelData[2]

			anchors.fill: parent

			ShapePath {
				strokeWidth: -1
				strokeColor: "transparent"
				fillGradient: RadialGradient {
					centerX: root.width * blob.modelData[0]
					centerY: root.height * blob.modelData[1]
					centerRadius: blob.reach
					focalX: centerX
					focalY: centerY

					GradientStop {
						position: 0
						color: blob.modelData[3]
					}
					GradientStop {
						position: 0.45
						color: Qt.alpha(blob.modelData[3], 0.55)
					}
					GradientStop {
						position: 1
						color: Qt.alpha(blob.modelData[3], 0)
					}
				}

				PathRectangle {
					width: root.width
					height: root.height
				}
			}
		}
	}

	// ── image (wallpaper); blurred at a small fixed size, then scaled up ───
	Image {
		anchors.fill: parent
		visible: root.kind === "image" && !(root.spec.blur > 0)
		source: root.kind === "image" ? `file://${root.spec.path}` : ""
		fillMode: Image.PreserveAspectCrop
		asynchronous: false
		cache: true
		smooth: true
		mipmap: true
	}

	Item {
		anchors.fill: parent
		visible: root.kind === "image" && root.spec.blur > 0
		clip: true

		Item {
			id: small

			readonly property real inner: 360
			readonly property real margin: 48
			readonly property real factor: root.width / small.inner

			x: -small.margin * small.factor
			y: -small.margin * small.factor
			width: small.inner + 2 * small.margin
			height: root.height / Math.max(0.0001, small.factor) + 2 * small.margin
			scale: small.factor
			transformOrigin: Item.TopLeft

			Image {
				id: wall

				anchors.fill: parent
				visible: false
				source: root.kind === "image" && root.spec.blur > 0 ? `file://${root.spec.path}` : ""
				sourceSize.width: 720
				fillMode: Image.PreserveAspectCrop
				asynchronous: false
				cache: true
				smooth: true
			}

			MultiEffect {
				anchors.fill: parent
				source: wall
				autoPaddingEnabled: false
				blurEnabled: true
				blur: Math.min(1, Number(root.spec?.blur ?? 0))
				blurMax: 40
				saturation: 0.15
			}
		}
	}
}
