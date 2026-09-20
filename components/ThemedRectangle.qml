import QtQuick

// The shell's general-purpose surface, in glass.
//
// Call sites hand it a colour and a size; what comes back is a pane with light
// on its upper edge and nothing else. No border, no chamfer, no registration
// marks — anything that encloses a thing belongs to a different style. A cell
// too small to carry even that light gets nothing at all.
Rectangle {
	id: root

	// Kept for source compatibility with the shared components.
	property string themeStyle: "auto"
	property real themeDepth: 0
	property bool themeEffectsEnabled: true
	property color boneColor: Arc.goldFaint
	property color liveColor: Arc.aether

	readonly property real shortestSide: Math.min(width, height)
	readonly property real longestSide: Math.max(width, height)
	readonly property bool isTinyDecoration: shortestSide < 14
	readonly property bool isThinTrack: shortestSide >= 4
		&& shortestSide <= 18 && longestSide / Math.max(1, shortestSide) >= 2.4
	readonly property bool isHugeBackdrop: width >= 760 && height >= 500
	readonly property bool hasSurfaceColor: root.color.a > 0.015
	readonly property bool cut: root.themeEffectsEnabled && !root.isTinyDecoration
		&& !root.isHugeBackdrop && root.themeStyle !== "flat"
		&& root.shortestSide >= 14

	readonly property bool themePressed: root.findInteractionState(root, "pressed")
	readonly property bool themeHovered: root.findInteractionState(root, "containsMouse")

	function findInteractionState(item, propertyName) {
		for (const child of item.children || []) {
			if (child === pane) continue;
			if (child[propertyName] === true) return true;
		}
		return false;
	}

	radius: root.isThinTrack ? Math.min(width, height) / 2 : 0

	ArcPlate {
		id: pane
		anchors.fill: parent
		visible: root.cut && root.hasSurfaceColor
		variant: root.isThinTrack ? "capsule" : "plate"
		crest: false
		beading: true
		lineColor: root.boneColor
		liveColor: root.liveColor
		weight: Arc.ruleThin
		intensity: root.themePressed ? 1 : root.themeHovered ? 0.6 : 0
	}
}
