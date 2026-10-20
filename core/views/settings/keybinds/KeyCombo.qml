import QtQuick
import qs.style.theme
import qs.core.services

// The keycaps of a key bind ("Mod+Shift+D" → Super Shift D). With `animated`
// every new combination pops in cap by cap from the left.
Row {
	id: root

	property string key: ""
	// keycaps shown instead of `key` (the modifiers held while recording)
	property var caps: Keybinds.caps(root.key)
	property real size: 24
	property bool animated: false
	property bool lit: false
	property bool faint: false

	spacing: Math.round(root.size * 0.22)

	Repeater {
		model: root.caps

		delegate: Keycap {
			id: cap

			required property string modelData
			required property int index

			text: cap.modelData
			size: root.size
			lit: root.lit
			faint: root.faint
			transformOrigin: Item.Bottom

			Component.onCompleted: if (root.animated) pop.start()

			SequentialAnimation {
				id: pop

				PropertyAction {
					target: cap
					properties: "scale,opacity"
					value: 0
				}
				PauseAnimation {
					duration: cap.index * 45
				}
				ParallelAnimation {
					NumberAnimation {
						target: cap
						property: "scale"
						from: 0.4
						to: 1
						duration: Motion.long
						easing.type: Easing.BezierSpline
						easing.bezierCurve: Motion.spatialFast
					}
					NumberAnimation {
						target: cap
						property: "opacity"
						from: 0
						to: 1
						duration: Motion.short
					}
				}
			}
		}
	}
}
