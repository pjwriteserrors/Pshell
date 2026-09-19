pragma ComponentBehavior: Bound

import QtQuick

// The wrapper every full-screen modal sits in (power, Studio, the pickers).
//
// Nothing in this style appears in the middle of the screen. A modal is a
// bench, like the launcher: the desktop dims beside the spine, the column
// itself stays lit and live, and the work is drawn out of it sideways. The
// scrim thickens like fluid while the bench unrolls from the column, and
// closing rolls it back the same way.
//
// Place inside a full-screen PanelWindow.
Item {
	id: sheet

	required property bool open
	property real scrimOpacity: 0.62
	property string mode: "center"   // legacy: every bench docks to the spine
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
			duration: sheet.open ? Bio.unfurl : Bio.furl
			easing.type: sheet.open ? Easing.OutQuint : Easing.InCubic
		}
	}

	Rectangle {
		anchors.left: parent.left
		anchors.right: parent.right
		anchors.top: parent.top
		anchors.bottom: parent.bottom
		anchors.leftMargin: Math.round(Bio.spine)
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

		x: Math.round(Bio.spine + Bio.s7)
		width: Math.min(sheet.sheetWidth, sheet.width - Bio.spine - Bio.s7 * 2)
		height: Math.min(sheet.sheetHeight, sheet.height - Bio.s6 * 2)
		y: Math.round((sheet.height - height) / 2)
		opacity: Math.min(1, sheet.openProgress * 2.2)

		// It unrolls out of the column, like every other chamber: scaled from
		// its left edge only, never from its middle.
		transform: Scale {
			origin.x: -Bio.s7
			origin.y: container.height / 2
			xScale: Math.max(0.03, sheet.openProgress)
			yScale: 0.97 + 0.03 * sheet.openProgress
		}
	}
}
