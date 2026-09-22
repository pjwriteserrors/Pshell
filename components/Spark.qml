import QtQuick

// A drop of light. Sits on a wire, travels along it, breathes when idle.
Item {
	id: spark

	property real size: 6
	property color color: Filament.charge
	property bool breathing: false
	property real halo: 3
	property real intensity: 1

	implicitWidth: size
	implicitHeight: size
	width: size
	height: size

	Rectangle {
		anchors.centerIn: parent
		width: spark.size * spark.halo
		height: width
		radius: width / 2
		color: Qt.alpha(spark.color, Math.min(1, 0.2 * spark.intensity))
		scale: breath.value
	}

	Rectangle {
		anchors.centerIn: parent
		width: spark.size * 1.8
		height: width
		radius: width / 2
		color: Qt.alpha(spark.color, Math.min(1, 0.35 * spark.intensity))
		scale: breath.value
	}

	Rectangle {
		anchors.centerIn: parent
		width: spark.size
		height: width
		radius: width / 2
		color: Qt.alpha(spark.color, Math.min(1, spark.intensity))
		scale: 0.85 + breath.value * 0.15
	}

	QtObject {
		id: breath
		property real value: 1
	}

	SequentialAnimation {
		running: spark.breathing
		loops: Animation.Infinite
		NumberAnimation { target: breath; property: "value"; to: 1.3; duration: Filament.breathe / 2; easing.type: Easing.InOutSine }
		NumberAnimation { target: breath; property: "value"; to: 1; duration: Filament.breathe / 2; easing.type: Easing.InOutSine }
	}
}
