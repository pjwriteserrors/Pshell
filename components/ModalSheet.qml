pragma ComponentBehavior: Bound

import QtQuick

// The wrapper every full-screen modal sits in (power, launcher, Studio, the
// pickers). It owns the scrim and the one entrance the style has: the sheet
// does not scale up out of nowhere, it *incubates* — the scrim thickens like
// fluid, the sheet swells from a slit and settles, and closing collapses it
// back along the same axis.
//
// Place inside a full-screen PanelWindow.
Item {
	id: sheet

	required property bool open
	property real scrimOpacity: 0.62
	property string mode: "center"   // "center" | "bottom"
	property real sheetWidth: 400
	property real sheetHeight: 300
	property real bottomMargin: 0
	property color shadowSurfaceColor: "transparent"

	default property alias content: container.data
	readonly property Item containerItem: container

	signal dismissRequested()

	readonly property bool centered: mode === "center"
	property real openProgress: open ? 1 : 0

	anchors.fill: parent

	// Every modal answers Escape, whatever is inside it. Unhandled keys travel
	// up from the focused item, so a search field inside the sheet still gets
	// first refusal. focus: true only claims the keyboard while nothing inside
	// wants it.
	focus: true

	Keys.onEscapePressed: event => {
		event.accepted = true;
		sheet.dismissRequested();
	}

	Behavior on openProgress {
		NumberAnimation {
			duration: sheet.open ? Bio.swell : Bio.relax
			easing.type: sheet.open ? Easing.OutBack : Easing.InCubic
			easing.overshoot: sheet.open ? 1.08 : 0
		}
	}

	Rectangle {
		anchors.fill: parent
		color: Bio.scrim
		opacity: sheet.open ? sheet.scrimOpacity : 0

		Behavior on opacity {
			NumberAnimation {
				duration: sheet.open ? Bio.swell : Bio.relax
				easing.type: Easing.OutCubic
			}
		}

		MouseArea {
			anchors.fill: parent
			onClicked: sheet.dismissRequested()
		}
	}

	// The organ light the sheet throws onto the scrim while it is open.
	BioGlow {
		anchors.centerIn: container
		width: container.width * 1.5
		height: container.height * 1.5
		color: Bio.organ
		strength: 0.16 * sheet.openProgress
		spread: 0.45
		visible: sheet.openProgress > 0.02
	}

	Item {
		id: container

		width: sheet.sheetWidth
		height: sheet.sheetHeight
		anchors.horizontalCenter: parent.horizontalCenter
		y: sheet.centered
			? Math.round((sheet.height - height) / 2)
			: sheet.height - height - sheet.bottomMargin
		opacity: Math.min(1, sheet.openProgress * 2.4)

		transform: Scale {
			origin.x: container.width / 2
			origin.y: sheet.centered ? container.height / 2 : container.height
			xScale: 0.90 + 0.10 * Math.min(1, sheet.openProgress * 1.7)
			yScale: Math.max(0.03, sheet.openProgress)
		}
	}
}
