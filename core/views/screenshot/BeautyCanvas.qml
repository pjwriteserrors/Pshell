pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import Quickshell.Widgets
import qs.style.theme
import qs.style.widgets

// The composed picture of the beautifier. All geometry in `g` is in native
// pixels of the screenshot; `k` scales it (preview: fit the screen, export: 1),
// so both are drawn from the same numbers and every layer is rendered at the
// size it is shown at.
Item {
	id: root

	required property var g
	required property real k
	required property string source
	required property var bg
	required property string frame
	required property bool dark
	required property string title
	required property bool border
	required property bool glow
	required property color glowColor
	required property bool reflection
	required property real grain
	required property color edge
	required property string noiseUrl
	property bool animated: true

	readonly property real u: root.g.u * root.k
	readonly property bool windowed: root.frame === "mac" || root.frame === "browser"
	readonly property bool phone: root.frame === "phone"
	readonly property color chrome: {
		if (root.phone) return root.dark ? "#0e0e10" : "#dfe0e4";
		if (root.windowed) return root.dark ? "#2a2a2d" : "#ececee";
		return root.edge;
	}
	readonly property color chromeText: root.dark ? "#d4d4d8" : "#4a4a50"

	width: Math.max(1, Math.round(root.g.W * root.k))
	height: Math.max(1, Math.round(root.g.H * root.k))

	// ── background, crossfading between two layers ─────────────────────────
	property string bgKey: ""
	property int front: 0

	function applyBg() {
		const key = JSON.stringify(root.bg);
		if (key === root.bgKey) return;
		const first = root.bgKey === "";
		root.bgKey = key;
		if (!root.animated || first) {
			(root.front === 0 ? bgA : bgB).spec = root.bg;
			return;
		}
		const next = root.front === 0 ? bgB : bgA;
		const prev = root.front === 0 ? bgA : bgB;
		next.spec = root.bg;
		prev.z = 0;
		next.z = 1;
		next.opacity = 0;
		fade.target = next;
		fade.restart();
		root.front = 1 - root.front;
	}

	onBgChanged: root.applyBg()
	Component.onCompleted: root.applyBg()

	BeautyBackground {
		id: bgA

		anchors.fill: parent
		z: 1
	}

	BeautyBackground {
		id: bgB

		anchors.fill: parent
		opacity: 0
	}

	NumberAnimation {
		id: fade

		property: "opacity"
		from: 0
		to: 1
		duration: Motion.long
		easing.type: Easing.BezierSpline
		easing.bezierCurve: Motion.standard
	}

	// film grain on the background only, tiled at native size
	Item {
		anchors.fill: parent
		z: 2
		visible: root.grain > 0 && root.noiseUrl !== "" && root.bg.kind !== "none"
		opacity: root.grain
		clip: true

		Image {
			width: parent.width / root.k
			height: parent.height / root.k
			scale: root.k
			transformOrigin: Item.TopLeft
			source: root.noiseUrl
			fillMode: Image.Tile
			smooth: false
		}
	}

	// ── the screenshot block ───────────────────────────────────────────────
	Item {
		id: slot

		z: 3
		x: root.g.bx * root.k
		y: root.g.by * root.k
		width: root.g.bw * root.k
		height: root.g.bh * root.k
		scale: root.g.s

		Item {
			id: tilted

			// perspective that does not depend on the size: shrink, rotate
			// with Qt's fixed camera distance, grow again
			readonly property real p: Math.max(0.05, 2.6 * Math.max(tilted.width, tilted.height) / 1024)
			readonly property real cx: tilted.width / 2
			readonly property real cy: tilted.height / 2

			anchors.fill: parent
			transform: [
				Scale {
					origin.x: tilted.cx
					origin.y: tilted.cy
					xScale: 1 / tilted.p
					yScale: 1 / tilted.p
				},
				Rotation {
					origin.x: tilted.cx
					origin.y: tilted.cy
					axis.x: 1
					axis.y: 0
					axis.z: 0
					angle: root.g.rx
				},
				Rotation {
					origin.x: tilted.cx
					origin.y: tilted.cy
					axis.x: 0
					axis.y: 1
					axis.z: 0
					angle: root.g.ry
				},
				Rotation {
					origin.x: tilted.cx
					origin.y: tilted.cy
					axis.x: 0
					axis.y: 0
					axis.z: 1
					angle: root.g.rz
				},
				Scale {
					origin.x: tilted.cx
					origin.y: tilted.cy
					xScale: tilted.p
					yScale: tilted.p
				}
			]

			RectangularShadow {
				anchors.fill: card
				visible: root.g.shadow > 0.001 || root.glow
				radius: card.radius
				blur: root.glow ? (24 + 110 * root.g.shadow) * root.u : (4 + 80 * root.g.shadow) * root.u
				spread: root.glow ? 6 * root.u * root.g.shadow : 0
				offset.x: 0
				offset.y: root.glow ? 0 : (2 + 30 * root.g.shadow) * root.u
				color: root.glow ? Qt.alpha(root.glowColor, 0.35 + 0.5 * root.g.shadow) : Qt.rgba(0, 0, 0, 0.16 + 0.44 * root.g.shadow)
			}

			// mirrored below the card, fading into the background
			ShaderEffectSource {
				id: mirrorSource

				sourceItem: root.reflection ? card : null
				visible: false
				live: true
			}

			Rectangle {
				id: mirrorMask

				width: card.width
				height: card.height
				visible: false
				layer.enabled: root.reflection
				gradient: Gradient {
					GradientStop {
						position: 0
						color: "transparent"
					}
					GradientStop {
						position: 0.62
						color: "transparent"
					}
					GradientStop {
						position: 1
						color: "white"
					}
				}
			}

			MultiEffect {
				y: card.height + 3 * root.u
				width: card.width
				height: card.height
				visible: root.reflection
				source: mirrorSource
				maskEnabled: true
				maskSource: mirrorMask
				maskThresholdMin: 0
				maskSpreadAtMin: 1
				opacity: 0.28
				transform: Scale {
					origin.y: card.height / 2
					yScale: -1
				}
			}

			ClippingRectangle {
				id: card

				anchors.fill: parent
				radius: root.g.outerRadius * root.k
				color: root.chrome

				Behavior on color {
					enabled: root.animated
					ColorAnim {}
				}

				// title bar (window frames)
				Item {
					id: bar

					width: parent.width
					height: root.g.bar * root.k
					opacity: root.windowed ? 1 : 0
					visible: height > 0.5

					Behavior on opacity {
						enabled: root.animated
						Anim {}
					}

					Rectangle {
						anchors.bottom: parent.bottom
						width: parent.width
						height: Math.max(1, root.u)
						color: root.dark ? Qt.rgba(0, 0, 0, 0.45) : Qt.rgba(0, 0, 0, 0.1)
					}

					Row {
						id: lights

						x: 13 * root.u
						anchors.verticalCenter: parent.verticalCenter
						spacing: 8 * root.u

						Repeater {
							model: ["#ff5f57", "#febc2e", "#28c840"]

							delegate: Rectangle {
								required property string modelData

								width: 12 * root.u
								height: width
								radius: width / 2
								color: modelData
								border.width: Math.max(0.5, 0.5 * root.u)
								border.color: Qt.rgba(0, 0, 0, 0.12)
								antialiasing: true
							}
						}
					}

					Text {
						anchors.centerIn: parent
						width: Math.min(implicitWidth, parent.width - 200 * root.u)
						visible: root.frame === "mac" && root.title !== ""
						text: root.title
						color: root.chromeText
						elide: Text.ElideRight
						font.family: Theme.fontFamily
						font.pixelSize: Math.max(1, 13 * root.u)
						font.weight: Font.DemiBold
					}

					// browser: navigation and the address field
					Item {
						anchors.fill: parent
						visible: root.frame === "browser"

						Row {
							x: lights.x + lights.width + 22 * root.u
							anchors.verticalCenter: parent.verticalCenter
							spacing: 14 * root.u

							Repeater {
								model: ["chevron_left", "chevron_right", "refresh"]

								delegate: Glyph {
									required property string modelData

									animated: false
									icon: modelData
									size: Math.max(1, 17 * root.u)
									color: Qt.alpha(root.chromeText, 0.8)
								}
							}
						}

						Rectangle {
							anchors.centerIn: parent
							width: Math.min(parent.width - 300 * root.u, 560 * root.u)
							height: 26 * root.u
							radius: 8 * root.u
							visible: width > 40 * root.u
							color: root.dark ? "#1b1b1d" : "#ffffff"
							border.width: root.dark ? 0 : Math.max(0.5, 0.5 * root.u)
							border.color: Qt.rgba(0, 0, 0, 0.08)

							Row {
								anchors.centerIn: parent
								spacing: 6 * root.u

								Glyph {
									anchors.verticalCenter: parent.verticalCenter
									visible: root.title !== ""
									animated: false
									icon: "lock"
									size: Math.max(1, 11 * root.u)
									color: Qt.alpha(root.chromeText, 0.7)
								}

								Text {
									anchors.verticalCenter: parent.verticalCenter
									text: root.title
									color: root.chromeText
									font.family: Theme.fontFamily
									font.pixelSize: Math.max(1, 12 * root.u)
								}
							}
						}
					}
				}

				// the screenshot, with its inset in the edge colour
				ClippingRectangle {
					x: root.g.bezel * root.k
					y: (root.g.bar + root.g.bezel) * root.k
					width: root.g.cw * root.k
					height: root.g.ch * root.k
					radius: root.g.screenRadius * root.k
					color: root.edge

					Image {
						x: root.g.inset * root.k
						y: root.g.inset * root.k
						width: root.g.iw * root.k
						height: root.g.ih * root.k
						source: root.source
						asynchronous: false
						cache: true
						smooth: true
						mipmap: root.k < 0.999
					}

					// phone: the camera island
					Rectangle {
						anchors.horizontalCenter: parent.horizontalCenter
						y: 10 * root.u
						width: 92 * root.u
						height: 26 * root.u
						radius: height / 2
						color: "black"
						opacity: root.phone ? 1 : 0
						visible: opacity > 0.01

						Behavior on opacity {
							enabled: root.animated
							Anim {}
						}
					}
				}
			}

			Rectangle {
				anchors.fill: card
				visible: root.border
				radius: card.radius
				color: "transparent"
				antialiasing: true
				border.width: Math.max(1, 1.2 * root.u)
				border.color: (root.windowed || root.phone) && !root.dark ? Qt.rgba(0, 0, 0, 0.14) : Qt.rgba(1, 1, 1, 0.24)
			}
		}
	}
}
