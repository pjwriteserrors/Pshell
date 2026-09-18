pragma ComponentBehavior: Bound

import QtQuick

// A chamber with something in it: the membrane, the skeleton, the halo it
// throws, and a content slot that already knows to keep clear of the corner
// bones. Every panel, card and popup body in this style is one of these.
Item {
	id: chamber

	property string variant: "chamber"
	property color lineColor: Bio.boneDim
	property color liveColor: Bio.organ
	property color washTop: Bio.membrane
	property color washBottom: Bio.membraneDeep
	property real weight: Bio.rib
	property real intensity: 0
	property real haloStrength: 0.22
	property bool crest: variant === "chamber"
	property bool beading: true
	property real padding: -1

	readonly property real contentMargin: padding >= 0 ? padding : frame.innerMargin + Bio.s2

	default property alias content: slot.data

	BioGlow {
		anchors.centerIn: parent
		width: parent.width * 1.28
		height: parent.height * 1.5
		color: chamber.liveColor
		strength: chamber.haloStrength * (0.55 + chamber.intensity * 0.45)
		spread: 0.42
		visible: chamber.haloStrength > 0.01
	}

	BioFrame {
		id: frame
		anchors.fill: parent
		variant: chamber.variant
		lineColor: chamber.lineColor
		liveColor: chamber.liveColor
		fillTop: chamber.washTop
		fillBottom: chamber.washBottom
		weight: chamber.weight
		intensity: chamber.intensity
		crest: chamber.crest
		beading: chamber.beading
	}

	Item {
		id: slot
		anchors.fill: parent
		anchors.margins: chamber.contentMargin
	}
}
