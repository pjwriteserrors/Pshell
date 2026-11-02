pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import QtQuick.Particles
import qs.style.theme
import qs.style.widgets
import "../../lib/GameText.js" as GameText

// The picked game behind everything. Its colours (games.py palette_of) set
// the mood: the dark of the picture under it all, lights of its accent
// drifting slowly through, embers of it rising. Over that its hero: a new
// game's picture loads behind the old one and comes in over it once it is
// there, from a little closer, then keeps drifting nearer; a light passes
// over it as it changes. A game without a hero is its cover, blurred.
Item {
	id: root

	property var game: null
	property bool active: true
	// 0 the shelf, 1 the grid: the picture steps back behind the covers
	property real recede: 0
	// the bar's panel: a banner, no embers, a lighter hand with the dark
	property bool compact: false

	readonly property string picture: {
		const art = root.game?.art ?? {};
		return art.hero || art.cover || art.header || "";
	}

	// the game's colours, changing slowly with it
	property color accent: GameText.accent(root.game, Theme.primary)
	property color deep: GameText.deep(root.game, Qt.tint("#0b0c10", Qt.alpha(Theme.primary, 0.08)))
	readonly property color floor: Qt.darker(root.deep, 1.9)

	Behavior on accent {
		ColorAnimation {
			duration: 900
			easing.type: Easing.InOutQuad
		}
	}
	Behavior on deep {
		ColorAnimation {
			duration: 900
			easing.type: Easing.InOutQuad
		}
	}

	property int front: 0

	function urlOf(path) {
		return path ? `file://${path}` : "";
	}

	onPictureChanged: {
		const back = layers.itemAt(1 - root.front);
		if (!back) return;
		// read from the game itself: a binding on it may not have caught up yet
		back.soft = !(root.game?.art?.hero);
		back.source = root.urlOf(root.picture);
		if (String(back.source) === "" || back.status === Image.Ready) root.swap();
	}

	function swap() {
		const back = layers.itemAt(1 - root.front);
		if (!back) return;
		root.front = 1 - root.front;
		back.drift.restart();
		if (root.active) sweep.restart();
	}

	clip: true

	Rectangle {
		anchors.fill: parent
		color: root.floor
	}

	// ── lights of the game's colours, slowly moving ────────────────────────
	Item {
		id: lights

		anchors.fill: parent
		opacity: root.compact ? 0.7 : 1

		Aurora {
			id: glowA

			property real t: 0

			width: Math.max(root.width, root.height) * 0.9
			height: glowA.width
			x: root.width * (0.55 + 0.18 * Math.sin(glowA.t * Math.PI * 2)) - glowA.width / 2
			y: root.height * (0.2 + 0.1 * Math.cos(glowA.t * Math.PI * 2)) - glowA.height / 2
			tint: root.accent
			strength: 0.42

			NumberAnimation on t {
				running: root.active
				from: 0
				to: 1
				duration: 38000
				loops: Animation.Infinite
			}
		}

		Aurora {
			id: glowB

			property real t: 0

			width: Math.max(root.width, root.height) * 0.75
			height: glowB.width
			x: root.width * (0.12 + 0.1 * Math.cos(glowB.t * Math.PI * 2)) - glowB.width / 2
			y: root.height * (0.85 + 0.08 * Math.sin(glowB.t * Math.PI * 2)) - glowB.height / 2
			tint: Qt.lighter(root.deep, 2.6)
			strength: 0.55

			NumberAnimation on t {
				running: root.active
				from: 0
				to: 1
				duration: 52000
				loops: Animation.Infinite
			}
		}
	}

	// ── the hero ───────────────────────────────────────────────────────────
	Repeater {
		id: layers

		model: 2

		delegate: Item {
			id: layer

			required property int index
			property alias source: image.source
			property alias status: image.status
			property bool soft: false
			property alias drift: drift
			readonly property bool shown: root.front === layer.index

			anchors.fill: parent
			opacity: layer.shown ? 1 : 0
			z: layer.shown ? 1 : 0

			Behavior on opacity {
				NumberAnimation {
					duration: 650
					easing.type: Easing.InOutQuad
				}
			}

			Image {
				id: image

				anchors.fill: parent
				fillMode: Image.PreserveAspectCrop
				verticalAlignment: Image.AlignTop
				asynchronous: true
				sourceSize.width: layer.soft ? 400 : (root.compact ? 1200 : 2560)
				visible: !layer.soft
				scale: 1.04
				opacity: root.compact ? 0.95 : 0.9

				onStatusChanged: {
					if (image.status === Image.Ready && !layer.shown && image.source !== "" && String(image.source) === root.urlOf(root.picture)) root.swap();
				}

				// in from a little closer, then slowly nearer, a little to the side
				SequentialAnimation {
					id: drift

					running: false

					NumberAnimation {
						target: image
						property: "scale"
						from: 1.16
						to: 1.07
						duration: 900
						easing.type: Easing.OutCubic
					}
					ParallelAnimation {
						NumberAnimation {
							target: image
							property: "scale"
							to: 1.0
							duration: 18000
							easing.type: Easing.OutSine
						}
						NumberAnimation {
							target: image
							property: "x"
							from: 0
							to: -26
							duration: 18000
							easing.type: Easing.InOutSine
						}
					}
				}
			}

			MultiEffect {
				anchors.fill: parent
				source: image
				visible: layer.soft
				blurEnabled: true
				blurMax: 64
				blur: 1
				saturation: 0.1
				opacity: 0.75
				scale: image.scale
			}
		}
	}

	// blurred and darker while the grid is in front
	MultiEffect {
		anchors.fill: parent
		source: layers.itemAt(root.front)
		visible: root.recede > 0.01
		opacity: root.recede
		blurEnabled: true
		blurMax: 48
		blur: 0.8
		brightness: -0.25
		z: 2
	}

	// a light passes over the picture as it changes
	Rectangle {
		id: light

		property real travel: -1

		z: 2
		visible: light.travel > -1 && light.travel < 1
		width: root.width * 0.35
		height: root.height * 2.2
		y: -root.height * 0.6
		x: -light.width + (root.width + light.width * 2) * (light.travel + 1) / 2
		rotation: 18
		opacity: 0.09
		gradient: Gradient {
			orientation: Gradient.Horizontal
			GradientStop {
				position: 0
				color: "transparent"
			}
			GradientStop {
				position: 0.5
				color: "white"
			}
			GradientStop {
				position: 1
				color: "transparent"
			}
		}

		NumberAnimation {
			id: sweep

			target: light
			property: "travel"
			from: -1
			to: 1
			duration: 1100
			easing.type: Easing.InOutCubic
		}
	}

	// ── what keeps the words and covers legible: the game's own dark from
	// the left and the bottom, not black ────────────────────────────────────
	Rectangle {
		anchors.fill: parent
		z: 3
		gradient: Gradient {
			orientation: Gradient.Horizontal
			GradientStop {
				position: 0
				color: Qt.alpha(root.floor, root.compact ? 0.85 : 0.9)
			}
			GradientStop {
				position: 0.42
				color: Qt.alpha(root.floor, root.compact ? 0.35 : 0.5)
			}
			GradientStop {
				position: 0.75
				color: Qt.alpha(root.floor, 0.05)
			}
		}
	}

	Rectangle {
		anchors.fill: parent
		z: 3
		gradient: Gradient {
			GradientStop {
				position: 0
				color: Qt.alpha(root.floor, root.compact ? 0 : 0.6)
			}
			GradientStop {
				position: 0.16
				color: Qt.alpha(root.floor, 0)
			}
			GradientStop {
				position: root.compact ? 0.4 : 0.5
				color: Qt.alpha(root.floor, 0.1)
			}
			GradientStop {
				position: 1
				color: Qt.alpha(root.floor, root.compact ? 0.92 : 0.96)
			}
		}
	}

	// the game's light from below, where the covers stand
	Rectangle {
		anchors.fill: parent
		z: 3
		gradient: Gradient {
			GradientStop {
				position: 0.55
				color: "transparent"
			}
			GradientStop {
				position: 1
				color: Qt.alpha(root.accent, root.compact ? 0.16 : 0.2)
			}
		}
	}

	// ── embers of the accent, rising ───────────────────────────────────────
	ParticleSystem {
		id: embers

		anchors.fill: parent
		z: 3
		running: root.active && !root.compact && root.visible
	}

	ImageParticle {
		system: embers
		anchors.fill: parent
		z: 3
		source: "qrc:///particleresources/glowdot.png"
		color: Qt.alpha(Qt.lighter(root.accent, 1.25), 0.7)
		colorVariation: 0.08
		alpha: 0.6
		alphaVariation: 0.3
		entryEffect: ImageParticle.Fade
		opacity: 1 - root.recede * 0.6
	}

	Emitter {
		system: embers
		anchors.left: parent.left
		anchors.right: parent.right
		anchors.bottom: parent.bottom
		height: parent.height * 0.25
		emitRate: 7
		lifeSpan: 11000
		lifeSpanVariation: 3000
		size: 10
		sizeVariation: 8
		endSize: 2
		velocity: AngleDirection {
			angle: 270
			angleVariation: 18
			magnitude: 34
			magnitudeVariation: 18
		}
		acceleration: PointDirection {
			y: -2
			xVariation: 3
		}
	}

	Wander {
		system: embers
		anchors.fill: parent
		xVariance: 40
		pace: 30
	}

	Rectangle {
		anchors.fill: parent
		z: 4
		color: Qt.rgba(0, 0, 0, 0.35 * root.recede)
	}
}
