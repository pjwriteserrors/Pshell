pragma ComponentBehavior: Bound

import QtQuick

// Shared wrapper for full-screen modal surfaces (power menu, launcher,
// theme picker, animation picker). Owns the scrim cross-fade and the
// sheet's bouncy entrance / crisp exit so all modal surfaces move
// identically. Place inside a full-screen PanelWindow.
//
//   center mode: sheet scales up from 0.92 with a slight overshoot.
//   bottom mode: sheet slides up from below with a slight overshoot.
Item {
	id: sheet

	required property bool open
	property real scrimOpacity: 0.3
	property string mode: "center"   // "center" | "bottom"
	property real sheetWidth: 400
	property real sheetHeight: 300
	property real bottomMargin: 0
	property color shadowSurfaceColor: "transparent"

	default property alias content: container.data
	readonly property Item containerItem: container

	signal dismissRequested()

	readonly property bool centered: mode === "center"

	anchors.fill: parent

	// Every modal answers Escape, whatever is inside it. Unhandled keys travel
	// up from the focused item, so a search field inside the sheet still gets
	// first refusal and content that wants Escape for itself (stepping back out
	// of a confirmation, clearing a query) just accepts the event.
	// focus: true only claims the keyboard while nothing inside wants it.
	focus: true

	Keys.onEscapePressed: event => {
		event.accepted = true;
		sheet.dismissRequested();
	}


	Rectangle {
		anchors.fill: parent
		color: "black"
		opacity: sheet.open ? sheet.scrimOpacity : 0

		Behavior on opacity {
			NumberAnimation {
				duration: sheet.open ? Motion.large : Motion.largeClose
				easing.type: ThemeEngine.standardEasing
			}
		}

		MouseArea {
			anchors.fill: parent
			onClicked: sheet.dismissRequested()
		}
	}

	Item {
		id: container

		width: sheet.sheetWidth
		height: sheet.sheetHeight
		anchors.horizontalCenter: parent.horizontalCenter
		y: sheet.centered
			? Math.round((sheet.height - height) / 2)
			: sheet.height - height - sheet.bottomMargin
		opacity: sheet.open ? 1 : 0
		scale: sheet.centered ? (sheet.open ? 1 : ThemeEngine.modalStartScale) : 1
		transformOrigin: Item.Center

		NeumorphicShadow {
			anchors.fill: parent
			surfaceColor: sheet.shadowSurfaceColor
			cornerRadius: ThemeEngine.radiusLarge
			depth: sheet.open ? ThemeEngine.modalShadowDepth : 0
		}

		transform: Translate {
			y: sheet.centered ? 0 : (sheet.open ? 0 : Math.round(sheet.sheetHeight * ThemeEngine.modalBottomTravelFactor))

			Behavior on y {
				NumberAnimation {
					duration: sheet.open ? Motion.large : Motion.largeClose
					easing.type: sheet.open ? ThemeEngine.modalOpenEasing : ThemeEngine.exitEasing
					easing.overshoot: sheet.open ? Motion.sheetOvershoot : 0
					easing.amplitude: ThemeEngine.elasticAmplitude
					easing.period: ThemeEngine.elasticPeriod
				}
			}
		}

		Behavior on scale {
			NumberAnimation {
				duration: sheet.open ? Motion.large : Motion.largeClose
			easing.type: sheet.open ? ThemeEngine.modalOpenEasing : ThemeEngine.exitEasing
			easing.overshoot: sheet.open ? Motion.sheetOvershoot : 0
			easing.amplitude: ThemeEngine.elasticAmplitude
			easing.period: ThemeEngine.elasticPeriod
			}
		}

		Behavior on opacity {
			NumberAnimation {
				duration: sheet.open ? Motion.normal : Motion.largeClose
				easing.type: sheet.open ? ThemeEngine.standardEasing : ThemeEngine.exitEasing
			}
		}
	}
}
