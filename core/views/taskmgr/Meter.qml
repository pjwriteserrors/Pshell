import QtQuick
import qs.style.theme
import qs.style.widgets

// A thin bar that fills to `value` (0…1) and glides there; it turns warning
// and danger coloured near the top when `alarming`.
Item {
	id: root

	property real value: 0
	property color color: Theme.primary
	property color track: Theme.layer3
	property bool alarming: false
	property real thickness: 6
	readonly property real clamped: Math.max(0, Math.min(1, Number(root.value) || 0))
	readonly property color shown: root.alarming && root.clamped > 0.9 ? Theme.danger : (root.alarming && root.clamped > 0.75 ? Theme.warning : root.color)

	implicitHeight: root.thickness

	Rectangle {
		anchors.fill: parent
		radius: height / 2
		color: root.track
	}

	Rectangle {
		height: parent.height
		width: Math.max(root.clamped > 0 ? height : 0, parent.width * root.clamped)
		radius: height / 2
		color: root.shown

		Behavior on width {
			SpatialAnim {
				duration: 320
			}
		}
		Behavior on color {
			ColorAnim {}
		}
	}
}
