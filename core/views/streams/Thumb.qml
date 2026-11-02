import QtQuick
import QtQuick.Effects
import qs.style.theme
import qs.core.services
import qs.core.views.games

// A video's picture, rounded and cut to fill. Until it came the colours stand
// in its place, so nothing jumps. `large` asks for a bigger version first and
// stays with `source` when there is none. `spoiler` keeps it blurred until
// `revealed`.
Item {
	id: root

	property string source: ""
	property string large: ""
	property var colors: null
	property real radius: Theme.radius.medium
	property bool spoiler: false
	property bool revealed: false
	property real zoom: 1
	property bool dimmed: false
	readonly property color deep: root.colors?.deep ?? Theme.layer3
	readonly property color light: root.colors?.accent ?? Theme.primaryContainer
	readonly property bool veiled: root.spoiler && !root.revealed
	readonly property bool ready: image.status === Image.Ready

	Rounded {
		anchors.fill: parent
		radius: root.radius

		Rectangle {
			anchors.fill: parent
			gradient: Gradient {
				orientation: Gradient.Horizontal
				GradientStop {
					position: 0
					color: Qt.tint(root.deep, Qt.alpha(root.light, 0.3))
				}
				GradientStop {
					position: 1
					color: root.deep
				}
			}
		}

		Image {
			id: image

			property bool tooBig: false

			anchors.fill: parent
			source: Streams.picture(root.large && !image.tooBig ? root.large : root.source)
			onSourceChanged: if (root.large && source.toString() !== Streams.picture(root.large)) image.tooBig = image.tooBig
			onStatusChanged: if (status === Image.Error && root.large) image.tooBig = true
			fillMode: Image.PreserveAspectCrop
			asynchronous: true
			cache: true
			smooth: true
			mipmap: true
			sourceSize.width: root.large ? 1920 : 960
			scale: root.zoom
			opacity: image.status === Image.Ready ? (root.dimmed ? 0.45 : 1) : 0
			visible: !root.veiled

			Behavior on opacity {
				NumberAnimation {
					duration: Motion.long
					easing.type: Easing.OutCubic
				}
			}
			Behavior on scale {
				NumberAnimation {
					duration: Motion.extraLong
					easing.type: Easing.OutCubic
				}
			}
		}

		MultiEffect {
			anchors.fill: parent
			source: image
			visible: root.veiled && image.status === Image.Ready
			blurEnabled: true
			blur: 1
			blurMax: 56
			saturation: -0.1
		}
	}
}
