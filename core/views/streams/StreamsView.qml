import QtQuick
import QtQuick.Effects
import QtQuick.Window
import qs.style.theme

// The same layout at every size: it is laid out for about 1536 x 900 and grows
// with the window, on a 4K screen too, so nothing ends up tiny in empty space.
// A narrow but tall window grows only as far as its width allows, and the
// pages use the height left over.
//
// Under the bar, all of it fades like the panel behind it (PanelShape): see-through
// at the top, nearly solid from 90 pixels down, rounded at the foot.
Item {
	id: root

	property alias windowed: stage.windowed
	readonly property real ui: Math.max(1, Math.min(root.width / 1500, root.height / 860))

	function takeFocus() {
		stage.takeFocus();
	}

	Item {
		id: content

		anchors.fill: parent
		layer.enabled: !root.windowed
		layer.smooth: true
		layer.textureSize: Qt.size(Math.round(root.width * Screen.devicePixelRatio), Math.round(root.height * Screen.devicePixelRatio))
		layer.effect: MultiEffect {
			maskEnabled: true
			maskSource: fade
			// with these the mask's alpha a becomes 3a² - 2a³
			maskThresholdMin: 0.5
			maskSpreadAtMin: 1
		}

		StreamsStage {
			id: stage

			width: root.width / root.ui
			height: root.height / root.ui
			scale: root.ui
			transformOrigin: Item.TopLeft
		}
	}

	Rectangle {
		id: fade

		anchors.fill: parent
		visible: false
		layer.enabled: !root.windowed
		bottomLeftRadius: Theme.panelRadius
		bottomRightRadius: Theme.panelRadius
		gradient: Gradient {
			// Theme.barOpacity at the very top, as PanelShape has it (a ≈ 0.71 gives 0.8)
			GradientStop {
				position: 0
				color: Qt.rgba(1, 1, 1, 0.71)
			}
			GradientStop {
				position: Math.min(1, 90 / Math.max(1, root.height))
				color: Qt.rgba(1, 1, 1, 1)
			}
		}
	}
}
