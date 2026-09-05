import QtQuick

Rectangle {
	id: root

	// auto: cards/buttons are raised, thin tracks are inset, tiny decoration is flat.
	// Explicit roles are "raised", "inset", and "flat".
	property string themeStyle: "auto"
	property real themeDepth: ThemeEngine.controlDepth
	property bool themeEffectsEnabled: true

	readonly property real shortestSide: Math.min(width, height)
	readonly property real longestSide: Math.max(width, height)
	readonly property bool isTinyDecoration: shortestSide < 14
	readonly property bool isThinTrack: shortestSide >= 4
		&& shortestSide <= 18 && longestSide / Math.max(1, shortestSide) >= 2.4
	readonly property bool isHugeBackdrop: width >= 720 && height >= 480
	readonly property bool hasSurfaceColor: root.color.a > 0.015
	readonly property string effectiveThemeStyle: root.themeStyle !== "auto"
		? root.themeStyle
		: root.isTinyDecoration || root.isHugeBackdrop ? "flat"
		: root.isThinTrack ? "inset"
		: "raised"
	readonly property bool themePressed: root.findInteractionState(root, "pressed")
	readonly property bool themeHovered: root.findInteractionState(root, "containsMouse")
	readonly property bool showRaised: ThemeEngine.controlEffectsEnabled
		&& root.themeEffectsEnabled && root.hasSurfaceColor
		&& root.effectiveThemeStyle === "raised"
	readonly property bool showInset: ThemeEngine.controlEffectsEnabled
		&& root.themeEffectsEnabled && root.hasSurfaceColor
		&& (root.effectiveThemeStyle === "inset" || root.themePressed)
	readonly property bool showOrnament: ThemeEngine.ornamentStyle !== "none"
		&& root.themeEffectsEnabled && root.hasSurfaceColor
		&& (root.effectiveThemeStyle !== "flat" || root.isThinTrack
			|| (root.shortestSide >= 24 && root.longestSide >= 96))
		&& !root.isHugeBackdrop

	scale: root.showRaised
		? (root.themePressed ? ThemeEngine.pressedScale
			: root.themeHovered ? ThemeEngine.hoverScale : 1)
		: 1

	Behavior on scale {
		NumberAnimation {
			duration: ThemeEngine.fast
			easing.type: ThemeEngine.standardEasing
		}
	}

	function findInteractionState(item, propertyName) {
		for (const child of item.children || []) {
			if (child === outerShadow || child === solidSurfaceBacking
					|| child === ornament || child === edgeTreatment || child === brutalOutline) continue;
			if (child[propertyName] === true) return true;
		}
		return false;
	}

	NeumorphicShadow {
		id: outerShadow
		anchors.fill: parent
		surfaceColor: root.color
		cornerRadius: root.radius
		depth: !root.showRaised ? 0
			: root.themePressed ? ThemeEngine.controlPressedDepth
			: root.themeHovered ? ThemeEngine.controlHoverDepth
			: root.themeDepth
	}

	// Existing shell roles often use alpha for glassy themes. A hard-shadow
	// theme needs visual mass, so structural surfaces receive an opaque base
	// in the exact same RGB color. Flat fills and overlays remain untouched.
	Rectangle {
		id: solidSurfaceBacking
		anchors.fill: parent
		radius: root.radius
		color: ThemeEngine.solidColor(root.color)
		visible: ThemeEngine.solidSurfaces && root.themeEffectsEnabled
			&& root.hasSurfaceColor && root.color.a < 0.995
			&& root.effectiveThemeStyle !== "flat"
		z: -0.5
	}

	ThemeOrnament {
		id: ornament
		anchors.fill: parent
		surfaceColor: root.color
		cornerRadius: root.radius
		compact: root.isThinTrack
		interactive: root.themeHovered || root.themePressed
		pressed: root.themePressed
		visible: root.showOrnament
	}

	NeumorphicBevel {
		id: edgeTreatment
		anchors.fill: parent
		visible: root.showRaised || root.showInset
		surfaceColor: root.color
		cornerRadius: root.radius
		inset: root.showInset
		strength: root.showInset ? ThemeEngine.insetOpacity : ThemeEngine.bevelOpacity
	}

	// Palette-safe hard keyline used by graphic/neo-brutalist themes. The
	// color is a contrast derivative of this surface, never a theme color.
	Rectangle {
		id: brutalOutline
		anchors.fill: parent
		radius: root.radius
		color: "transparent"
		border.width: ThemeEngine.outlineWidth
		border.color: ThemeEngine.contrastEdge(root.color)
		visible: ThemeEngine.outlineWidth > 0 && root.themeEffectsEnabled
			&& root.hasSurfaceColor && root.effectiveThemeStyle !== "flat"
		z: 901
	}

	transform: Translate {
		x: root.showRaised
			? (root.themePressed ? ThemeEngine.pressTravel
				: root.themeHovered ? -ThemeEngine.hoverLift : 0)
			: 0
		y: root.showRaised
			? (root.themePressed ? ThemeEngine.pressTravel
				: root.themeHovered ? -ThemeEngine.hoverLift : 0)
			: 0

		Behavior on x { NumberAnimation { duration: ThemeEngine.fast; easing.type: ThemeEngine.standardEasing } }
		Behavior on y { NumberAnimation { duration: ThemeEngine.fast; easing.type: ThemeEngine.standardEasing } }
	}
}
