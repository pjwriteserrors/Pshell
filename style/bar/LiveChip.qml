import QtQuick
import qs.style.theme
import qs.core.services
import qs.style.widgets

// A live status of the shell in the bar (Live): the glyph, the value that
// rolls, a ring, curve or bar as set in the settings. It grows in when
// something starts and folds away when it is idle and set to hide. A
// click opens the panel behind it or does what fits, the wheel turns what
// can be turned, and resting on it brings a card with more.
BarButton {
	id: root

	required property string key
	readonly property var src: Live.source(root.key)
	readonly property bool wanted: Live.shows(root.key)

	panelId: root.src && !root.src.act ? root.src.panel : ""
	primaryAnchor: false
	padding: 8
	visible: width > 0.5
	implicitWidth: root.wanted ? face.implicitWidth + root.padding * 2 : 0
	// clipped only while it folds, so ripples may reach past it
	clip: root.width < face.implicitWidth + root.padding * 2 - 0.5
	wheelEnabled: !!root.src?.wheel
	onClicked: {
		if (!root.src) return;
		if (root.src.act || root.panelId === "") Live.activate(root.key, root.bar.screen, root);
		else root.toggle(root.src.page);
	}
	onScrolled: wheel => Live.scroll(root.key, wheel.angleDelta.y > 0)

	Behavior on implicitWidth {
		SpatialAnim {
			duration: Motion.long
		}
	}

	Component.onCompleted: Live.hold(root.key, 1)
	Component.onDestruction: Live.hold(root.key, -1)

	LiveFace {
		id: face

		key: root.key
		anchors.verticalCenter: parent.verticalCenter
		animated: root.wanted
		// rises in from below when it comes, sinks when it goes
		opacity: root.wanted ? 1 : 0
		transform: Translate {
			y: root.wanted ? 0 : 8

			Behavior on y {
				SpatialAnim {
					duration: Motion.long
				}
			}
		}

		Behavior on opacity {
			Anim {
				duration: Motion.medium
			}
		}
	}

	LiveCard {
		id: card

		bar: root.bar
		target: root
		key: root.key
		shown: root.bar.tooltipItem === root && root.wanted
	}
}
