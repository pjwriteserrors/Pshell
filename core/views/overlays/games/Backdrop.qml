import QtQuick
import QtQuick.Effects
import qs.style.theme
import qs.style.widgets

// The picked game's hero picture behind everything. A new game's picture
// loads behind the old one and fades in over it once it is there, slowly
// drifting closer; a game without a hero is its cover, blurred.
Item {
	id: root

	property var game: null
	property bool active: true
	// 0 the shelf, 1 the grid: the picture steps back behind the covers
	property real recede: 0

	readonly property string picture: {
		const art = root.game?.art ?? {};
		return art.hero || art.cover || art.header || "";
	}
	readonly property bool soft: !(root.game?.art?.hero)

	property int front: 0

	function urlOf(path) {
		return path ? `file://${path}` : "";
	}

	onPictureChanged: {
		const back = layers.itemAt(1 - root.front);
		if (!back) return;
		back.soft = root.soft;
		back.source = root.urlOf(root.picture);
		if (back.source === "" || back.status === Image.Ready) root.swap();
	}

	function swap() {
		const back = layers.itemAt(1 - root.front);
		if (!back) return;
		root.front = 1 - root.front;
		back.drift.restart();
	}

	Rectangle {
		anchors.fill: parent
		color: Qt.tint("#07080b", Qt.alpha(Theme.primary, 0.06))
	}

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
					duration: 700
					easing.type: Easing.InOutQuad
				}
			}

			Image {
				id: image

				anchors.fill: parent
				fillMode: Image.PreserveAspectCrop
				asynchronous: true
				sourceSize.width: layer.soft ? 400 : 1920
				visible: !layer.soft
				scale: 1.08

				onStatusChanged: {
					if (image.status === Image.Ready && !layer.shown && image.source !== "" && String(image.source) === root.urlOf(root.picture)) root.swap();
				}

				// slowly closer, a little to the side
				ParallelAnimation {
					id: drift

					running: false

					NumberAnimation {
						target: image
						property: "scale"
						from: 1.12
						to: 1.02
						duration: 16000
						easing.type: Easing.OutSine
					}
					NumberAnimation {
						target: image
						property: "x"
						from: -24
						to: 0
						duration: 16000
						easing.type: Easing.OutSine
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
				saturation: 0.15
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

	// what keeps the words and covers legible: dark from the left and the bottom
	Rectangle {
		anchors.fill: parent
		z: 3
		gradient: Gradient {
			orientation: Gradient.Horizontal
			GradientStop {
				position: 0
				color: Qt.rgba(0, 0, 0, 0.85)
			}
			GradientStop {
				position: 0.45
				color: Qt.rgba(0, 0, 0, 0.4)
			}
			GradientStop {
				position: 1
				color: Qt.rgba(0, 0, 0, 0.1)
			}
		}
	}

	Rectangle {
		anchors.fill: parent
		z: 3
		gradient: Gradient {
			GradientStop {
				position: 0
				color: Qt.rgba(0, 0, 0, 0.7)
			}
			GradientStop {
				position: 0.18
				color: Qt.rgba(0, 0, 0, 0)
			}
			GradientStop {
				position: 0.55
				color: Qt.rgba(0, 0, 0, 0.15)
			}
			GradientStop {
				position: 1
				color: Qt.rgba(0, 0, 0, 0.9)
			}
		}
	}

	// the accent as a faint light from below
	Rectangle {
		anchors.fill: parent
		z: 3
		opacity: 0.35
		gradient: Gradient {
			GradientStop {
				position: 0.6
				color: "transparent"
			}
			GradientStop {
				position: 1
				color: Qt.alpha(Theme.primary, 0.35)
			}
		}
	}

	Rectangle {
		anchors.fill: parent
		z: 4
		color: Qt.rgba(0, 0, 0, 0.35 * root.recede)
	}
}
