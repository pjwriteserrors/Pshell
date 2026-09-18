import QtQuick

// The shell's general-purpose surface, grown over.
//
// Call sites hand it a colour and a size; what comes back is a chamber with a
// skeleton around it. Which skeleton is decided here rather than at the call
// site, from the shape of the thing: a panel gets the full corner bones, a cell
// or button gets the short ones, a pill gets the beaded capsule, and anything
// smaller than a fingertip or larger than a window gets none at all — a
// skeleton drawn around a 10px badge is noise, not anatomy.
//
// Hover and press are picked up from whatever MouseArea a call site already put
// inside, so every existing surface in the shell reacts by lighting up.
Rectangle {
	id: root

	// Kept for source compatibility with the shared components; the bio frames
	// have no bevels or shadows to switch between.
	property string themeStyle: "auto"
	property real themeDepth: 0
	property bool themeEffectsEnabled: true
	property color boneColor: Bio.boneFaint
	property color liveColor: Bio.organ

	readonly property real shortestSide: Math.min(width, height)
	readonly property real longestSide: Math.max(width, height)
	readonly property bool isTinyDecoration: shortestSide < 15
	readonly property bool isThinTrack: shortestSide >= 4
		&& shortestSide <= 18 && longestSide / Math.max(1, shortestSide) >= 2.4
	readonly property bool isHugeBackdrop: width >= 720 && height >= 480
	readonly property bool hasSurfaceColor: root.color.a > 0.015
	readonly property bool boned: root.themeEffectsEnabled && !root.isTinyDecoration
		&& !root.isHugeBackdrop && root.themeStyle !== "flat"
		&& root.shortestSide >= 15
	readonly property string boneVariant: root.isThinTrack ? "capsule"
		: (root.shortestSide >= 64 && root.longestSide >= 120) ? "chamber" : "plate"

	readonly property bool themePressed: root.findInteractionState(root, "pressed")
	readonly property bool themeHovered: root.findInteractionState(root, "containsMouse")

	function findInteractionState(item, propertyName) {
		for (const child of item.children || []) {
			if (child === skeleton) continue;
			if (child[propertyName] === true) return true;
		}
		return false;
	}

	radius: root.isTinyDecoration || root.isThinTrack ? Math.min(width, height) / 2 : 3

	BioFrame {
		id: skeleton
		anchors.fill: parent
		visible: root.boned && root.hasSurfaceColor
		variant: root.boneVariant
		beading: root.boneVariant !== "plate" || root.shortestSide >= 22
		crest: false
		lineColor: root.boneColor
		liveColor: root.liveColor
		weight: root.shortestSide < 40 ? Bio.ribThin : Bio.rib
		intensity: root.themePressed ? 1 : root.themeHovered ? 0.62 : 0
	}
}
