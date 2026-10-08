import QtQuick
import QtQuick.Effects
import qs.style.theme
import qs.style.widgets

// The wallpaper with a pane of glass on it: blurred, saturated and grainy
// the way the blur settings say.
Item {
	id: root

	// 0…1
	property real blur: 1
	property real saturation: 1.5
	property real noise: 0.02
	property real paneScale: 0.62

	RoundClip {
		anchors.fill: parent
		radius: Theme.radius.medium

		Image {
			id: wall

			anchors.fill: parent
			source: Theme.wal?.wallpaper ? `file://${Theme.wal.wallpaper}` : ""
			fillMode: Image.PreserveAspectCrop
			sourceSize.width: 500
			asynchronous: true
		}

		// the pane: the same wallpaper, through the effect
		Item {
			id: pane

			anchors.centerIn: parent
			width: parent.width * root.paneScale
			height: parent.height * root.paneScale
			clip: true

			MultiEffect {
				x: -pane.x
				y: -pane.y
				width: wall.width
				height: wall.height
				source: wall
				blurEnabled: true
				blurMax: 48
				blur: Math.min(1, root.blur)
				saturation: Math.max(-1, Math.min(1, root.saturation - 1))
				autoPaddingEnabled: false

				Behavior on blur {
					Anim {}
				}
			}

			// grain
			Canvas {
				anchors.fill: parent
				opacity: Math.min(1, root.noise * 6)
				onWidthChanged: requestPaint()
				onPaint: {
					const ctx = getContext("2d");
					ctx.reset();
					for (let i = 0; i < width * height / 9; i++) {
						const v = Math.random() > 0.5 ? 255 : 0;
						ctx.fillStyle = `rgba(${v},${v},${v},0.35)`;
						ctx.fillRect(Math.random() * width, Math.random() * height, 1, 1);
					}
				}
			}

			Rectangle {
				anchors.fill: parent
				color: Qt.alpha(Theme.base, 0.15)
				border.width: 1
				border.color: Qt.alpha("white", 0.25)
			}
		}
	}
}
