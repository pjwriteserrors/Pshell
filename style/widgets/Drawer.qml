pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Wayland
import qs.style.theme
import qs.core.services

// A panel that grows out of the bar underneath the button that opened it.
//
// Open:  the silhouette extrudes downward with a soft overshoot while it
//        widens from a narrow neck to full width; content settles in after
//        the shape, sliding down a few pixels.
// Close: the shape retracts back into the bar quickly, content leaves first.
// Size changes (switching pages, lists growing) morph the silhouette.
PanelWindow {
	id: root

	required property string panelId
	property real panelWidth: 400
	property real contentHeight: 300
	property real padding: Theme.panelPadding
	property bool keyboard: true
	property bool centered: false
	readonly property real maxBodyHeight: Math.max(160, (root.screen?.height ?? 1080) - Theme.barHeight - 48)
	readonly property real targetHeight: Math.min(root.maxBodyHeight, root.contentHeight + root.padding * 2)
	readonly property real innerHeight: root.targetHeight - root.padding * 2
	readonly property real innerWidth: root.panelWidth - root.padding * 2

	default property alias content: holder.data
	// A second panel that grows out of this one's bottom edge (e.g. details of
	// a selection), with the same silhouette and motion. Its right edge sits
	// `belowInset` inside the panel's, far enough for both fillets.
	property alias below: belowHolder.data
	property bool belowOpen: false
	property real belowWidth: 360
	property real belowContentHeight: 200
	property real belowInset: Theme.panelRadius + Theme.panelFillet + 8
	readonly property real belowTargetHeight: Math.min(Math.max(0, root.height - root.targetHeight - 24), root.belowContentHeight + root.padding * 2)
	readonly property bool belowShown: root.shown && root.belowOpen
	property real belowReveal: root.belowShown ? 1 : 0
	readonly property bool shown: Popups.current === root.panelId
	property var targetScreen: Popups.primaryScreen
	property real reveal: root.shown ? 1 : 0

	signal panelOpened
	signal panelClosed

	onShownChanged: {
		if (root.shown) {
			root.targetScreen = Popups.screen || Popups.primaryScreen;
			root.panelOpened();
			Qt.callLater(() => scope.forceActiveFocus());
		} else {
			root.panelClosed();
		}
	}

	Behavior on reveal {
		NumberAnimation {
			duration: root.shown ? Motion.long : Motion.medium - 60
			easing.type: Easing.BezierSpline
			easing.bezierCurve: root.shown ? Motion.spatial : Motion.accel
		}
	}

	Behavior on belowReveal {
		NumberAnimation {
			duration: root.belowShown ? Motion.long : Motion.medium - 60
			easing.type: Easing.BezierSpline
			easing.bezierCurve: root.belowShown ? Motion.spatial : Motion.accel
		}
	}

	screen: root.targetScreen
	visible: root.shown || root.reveal > 0.002
	color: "transparent"
	anchors {
		left: true
		right: true
		top: true
		bottom: true
	}
	margins.top: Theme.barHeight
	exclusiveZone: 0
	WlrLayershell.namespace: `shell-${root.panelId}`
	WlrLayershell.layer: WlrLayer.Overlay
	WlrLayershell.exclusionMode: ExclusionMode.Ignore
	WlrLayershell.keyboardFocus: root.shown && root.keyboard ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

	MouseArea {
		anchors.fill: parent
		enabled: root.shown
		onPressed: Popups.close()
	}

	readonly property real anchorX: root.centered ? root.width / 2 : Popups.anchorFor(root.targetScreen, root.panelId)
	readonly property real bodyWidth: root.panelWidth * (0.62 + 0.38 * Math.min(1.04, root.reveal))
	property real animatedHeight: root.targetHeight

	Behavior on animatedHeight {
		enabled: root.reveal > 0.98
		SpatialAnim {
			duration: Motion.medium
		}
	}

	RectangularShadow {
		anchors.fill: body
		anchors.topMargin: Math.min(body.height, 90)
		radius: Theme.panelRadius
		blur: 34
		spread: -4
		offset.y: 10
		color: Theme.shadow
		opacity: Math.min(1, root.reveal)
	}

	Item {
		id: body

		readonly property real edge: 10
		x: Math.round(Math.max(Theme.panelFillet + body.edge, Math.min(root.width - width - Theme.panelFillet - body.edge, root.anchorX - width / 2)))
		y: 0
		width: root.bodyWidth
		height: Math.max(0, root.animatedHeight * root.reveal)

		// when another button re-targets an open panel, it glides over
		Behavior on x {
			enabled: root.shown && root.reveal > 0.98
			SpatialAnim {
				duration: Motion.long
			}
		}

		PanelShape {
			anchors.fill: parent
		}

		MouseArea {
			anchors.fill: parent
			acceptedButtons: Qt.AllButtons
			onWheel: wheel => wheel.accepted = true
		}

		Item {
			anchors.fill: parent
			clip: true

			FocusScope {
				id: scope

				x: (parent.width - root.innerWidth) / 2
				y: root.padding - 14 * (1 - Math.min(1, root.reveal))
				width: root.innerWidth
				height: root.innerHeight
				opacity: Math.max(0, Math.min(1, (root.reveal - 0.35) / 0.65))
				focus: true

				Keys.onEscapePressed: Popups.close()

				Item {
					id: holder

					anchors.fill: parent
				}
			}
		}
	}

	property real belowAnimatedHeight: root.belowTargetHeight

	Behavior on belowAnimatedHeight {
		enabled: root.belowReveal > 0.98
		SpatialAnim {
			duration: Motion.medium
		}
	}

	RectangularShadow {
		anchors.fill: belowBody
		anchors.topMargin: Math.min(belowBody.height, 60)
		radius: Theme.panelRadius
		blur: 34
		spread: -4
		offset.y: 10
		color: Theme.shadow
		opacity: Math.min(1, root.belowReveal)
		visible: belowBody.visible
	}

	Item {
		id: belowBody

		// the centre stays put while the neck widens
		readonly property real centre: body.x + body.width - root.belowInset - root.belowWidth / 2
		x: Math.round(belowBody.centre - width / 2)
		y: body.height
		width: root.belowWidth * (0.62 + 0.38 * Math.min(1.04, root.belowReveal))
		height: Math.max(0, root.belowAnimatedHeight * root.belowReveal)
		visible: height > 0.5

		PanelShape {
			anchors.fill: parent
			topOpacity: 0.96
		}

		MouseArea {
			anchors.fill: parent
			acceptedButtons: Qt.AllButtons
			onWheel: wheel => wheel.accepted = true
		}

		Item {
			anchors.fill: parent
			clip: true

			Item {
				id: belowHolder

				x: (parent.width - width) / 2
				y: root.padding - 14 * (1 - Math.min(1, root.belowReveal))
				width: root.belowWidth - root.padding * 2
				height: root.belowTargetHeight - root.padding * 2
				opacity: Math.max(0, Math.min(1, (root.belowReveal - 0.35) / 0.65))
			}
		}
	}
}
