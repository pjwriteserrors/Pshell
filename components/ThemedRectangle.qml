import QtQuick

// The shell's general-purpose surface, re-cut.
//
// Call sites hand it a colour and a size; what comes back is a field cut into
// the instrument. Which fittings it gets is decided here from the shape of the
// thing, not at the call site: a panel-sized field gets a brass border and
// registration marks at its corners, a small cell gets the marks alone, a
// track gets a channel rim, and anything smaller than a fingertip or larger
// than a window gets nothing — an engraved border around a 10px badge is
// noise, not an instrument.
//
// Corners are square. Everything machined in this style is square or chamfered;
// only a channel that something runs along is round-ended.
Rectangle {
	id: root

	// Kept for source compatibility with the shared components; there are no
	// bevels or drop shadows in an engraved instrument.
	property string themeStyle: "auto"
	property real themeDepth: 0
	property bool themeEffectsEnabled: true
	property color boneColor: Arc.giltFaint
	property color liveColor: Arc.aether

	readonly property real shortestSide: Math.min(width, height)
	readonly property real longestSide: Math.max(width, height)
	readonly property bool isTinyDecoration: shortestSide < 15
	readonly property bool isThinTrack: shortestSide >= 4
		&& shortestSide <= 18 && longestSide / Math.max(1, shortestSide) >= 2.4
	readonly property bool isHugeBackdrop: width >= 720 && height >= 480
	readonly property bool hasSurfaceColor: root.color.a > 0.015
	readonly property bool cut: root.themeEffectsEnabled && !root.isTinyDecoration
		&& !root.isHugeBackdrop && root.themeStyle !== "flat"
		&& root.shortestSide >= 15
	readonly property string plateVariant: root.isThinTrack ? "capsule" : "field"

	readonly property bool themePressed: root.findInteractionState(root, "pressed")
	readonly property bool themeHovered: root.findInteractionState(root, "containsMouse")

	function findInteractionState(item, propertyName) {
		for (const child of item.children || []) {
			if (child === fittings) continue;
			if (child[propertyName] === true) return true;
		}
		return false;
	}

	radius: root.isThinTrack ? Math.min(width, height) / 2 : 0

	ArcPlate {
		id: fittings
		anchors.fill: parent
		visible: root.cut && root.hasSurfaceColor
		variant: root.plateVariant
		beading: root.shortestSide >= 22
		crest: false
		inset: 1
		lineColor: root.boneColor
		liveColor: root.liveColor
		weight: root.shortestSide < 40 ? Arc.ruleThin : Arc.rule
		intensity: root.themePressed ? 1 : root.themeHovered ? 0.6 : 0
	}
}
