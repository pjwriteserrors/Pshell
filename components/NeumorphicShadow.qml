import QtQuick
import QtQuick.Effects

Item {
	id: root

	property color surfaceColor: "transparent"
	property real cornerRadius: ThemeEngine.radiusMedium
	property real depth: 1
	property bool animateDepth: true

	visible: ThemeEngine.shadowEnabled && root.depth > 0
	z: -1

	Behavior on depth {
		enabled: root.animateDepth
		NumberAnimation {
			duration: ThemeEngine.normal
			easing.type: ThemeEngine.standardEasing
		}
	}

	RectangularShadow {
		anchors.fill: parent
		radius: root.cornerRadius
		blur: ThemeEngine.hardShadow ? 0 : ThemeEngine.shadowBlur * root.depth
		spread: ThemeEngine.hardShadow ? 0 : ThemeEngine.shadowSpread * root.depth
		offset: Qt.vector2d(ThemeEngine.shadowOffset * root.depth, ThemeEngine.shadowOffset * root.depth)
		color: ThemeEngine.hardShadow
			? ThemeEngine.contrastEdge(root.surfaceColor, ThemeEngine.darkShadowOpacity)
			: Qt.alpha(Qt.darker(root.surfaceColor, 1.7), ThemeEngine.darkShadowOpacity)
	}

	RectangularShadow {
		anchors.fill: parent
		visible: !ThemeEngine.hardShadow
		radius: root.cornerRadius
		blur: ThemeEngine.shadowBlur * root.depth
		spread: ThemeEngine.shadowSpread * root.depth
		offset: Qt.vector2d(-ThemeEngine.shadowOffset * root.depth, -ThemeEngine.shadowOffset * root.depth)
		color: Qt.alpha(Qt.lighter(root.surfaceColor, 1.7), ThemeEngine.lightShadowOpacity)
	}
}
