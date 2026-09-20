pragma ComponentBehavior: Bound

import QtQuick

// A pane with something written on it: the glass, the light it sits in, and a
// slot for the contents. Every panel body in the sanctum is one of these.
Item {
	id: leaf

	property string variant: "chamber"
	property color lineColor: Arc.goldDim
	property color liveColor: Arc.aether
	property color washTop: Arc.haze
	property color washBottom: Arc.hazeDeep
	property real weight: Arc.rule
	property real intensity: 0
	property real haloStrength: 0.18
	property bool crest: variant === "chamber"
	property bool beading: true
	property real padding: -1

	readonly property real contentMargin: padding >= 0 ? padding : Arc.s4

	default property alias content: slot.data

	// The light a conjured thing sits in. Without it a translucent pane over a
	// bright wallpaper has nothing to separate it from what is behind.
	ArcHalo {
		anchors.centerIn: parent
		width: parent.width * 1.25
		height: parent.height * 1.4
		color: leaf.liveColor
		strength: leaf.haloStrength * (0.5 + leaf.intensity * 0.5)
		spread: 0.44
		visible: leaf.haloStrength > 0.01
	}

	ArcPlate {
		id: glass
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
	}
}
