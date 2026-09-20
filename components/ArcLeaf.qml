pragma ComponentBehavior: Bound

import QtQuick

// A sheet with something written on it: the vellum, the fittings that hold it,
// the candlelight it sits in, and a slot that already knows to keep clear of
// the corner mounts. Every panel, card and popup body in the instrument is one
// of these.
Item {
	id: leaf

	property string variant: "chamber"
	property color lineColor: Arc.giltDim
	property color liveColor: Arc.aether
	property color washTop: Arc.wash
	property color washBottom: Arc.washDeep
	property real weight: Arc.rule
	property real intensity: 0
	property real haloStrength: 0.20
	property bool crest: variant === "chamber"
	property bool beading: true
	property real padding: -1

	readonly property real contentMargin: padding >= 0 ? padding : plate.innerMargin + Arc.s2

	default property alias content: slot.data

	ArcHalo {
		anchors.centerIn: parent
		width: parent.width * 1.2
		height: parent.height * 1.35
		color: leaf.liveColor
		strength: leaf.haloStrength * (0.55 + leaf.intensity * 0.45)
		spread: 0.44
		visible: leaf.haloStrength > 0.01
	}

	ArcPlate {
		id: plate
		anchors.fill: parent
		variant: leaf.variant
		lineColor: leaf.lineColor
		liveColor: leaf.liveColor
		fillTop: leaf.washTop
		fillBottom: leaf.washBottom
		weight: leaf.weight
		intensity: leaf.intensity
		crest: leaf.crest
		beading: leaf.beading
	}

	Item {
		id: slot
		anchors.fill: parent
		anchors.margins: leaf.contentMargin
		anchors.topMargin: leaf.contentMargin + plate.railHeight
	}
}
