pragma ComponentBehavior: Bound

import QtQuick

Rectangle {
	id: root
	signal clicked()
	required property string label
	property string sublabel: ""
	property color accent: "#d7ad65"
	property color foreground: "#fff4dc"
	property bool primary: false
	property bool armed: false
	property bool buttonEnabled: true

	implicitWidth: 150
	implicitHeight: 48
	radius: 14
	opacity: root.buttonEnabled ? 1 : 0.42
	scale: press.pressed ? 0.97 : (press.containsMouse ? 1.025 : 1)
	border.width: 1
	border.color: root.armed ? "#ff6978" : Qt.alpha(root.foreground, root.primary ? 0.28 : 0.12)
	gradient: Gradient {
		GradientStop { position: 0; color: root.armed ? "#d94b62" : (root.primary ? Qt.lighter(root.accent, 1.18) : Qt.alpha(root.accent, 0.32)) }
		GradientStop { position: 1; color: root.armed ? "#8c263d" : (root.primary ? Qt.darker(root.accent, 1.18) : Qt.alpha(root.accent, 0.14)) }
	}
	Column {
		anchors.centerIn: parent; spacing: 1
		Text { anchors.horizontalCenter: parent.horizontalCenter; color: root.foreground; font.pixelSize: root.primary ? 14 : 12; font.weight: Font.Bold; text: root.label }
		Text { visible: root.sublabel !== ""; anchors.horizontalCenter: parent.horizontalCenter; color: Qt.alpha(root.foreground, 0.68); font.pixelSize: 9; text: root.sublabel }
	}
	MouseArea { id: press; anchors.fill: parent; hoverEnabled: true; enabled: root.buttonEnabled; cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor; onClicked: root.clicked() }
	Behavior on scale { NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }
}
