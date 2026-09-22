import QtQuick

// Hold to charge. A destructive verb is not a click: the wire under the
// word fills while the button is held and only fires when it is full.
// Letting go early drains it again.
Item {
	id: hold

	property string text: ""
	property string icon: ""
	property int holdTime: 650
	property bool alert: true
	property bool enabled: true
	readonly property color tone: alert ? Filament.alert : Filament.charge
	readonly property bool hovered: touch.containsMouse
	property real charge: 0

	signal held()

	implicitWidth: Math.max(96, row.implicitWidth + 28)
	implicitHeight: 34
	opacity: enabled ? 1 : 0.42

	NumberAnimation { id: chargeUp; target: hold; property: "charge"; to: 1; duration: hold.holdTime; easing.type: Easing.InQuad; onFinished: { hold.held(); drain.start(); } }
	NumberAnimation { id: drain; target: hold; property: "charge"; to: 0; duration: 200; easing.type: Easing.OutCubic }

	MouseArea {
		id: touch
		anchors.fill: parent
		hoverEnabled: true
		enabled: hold.enabled
		cursorShape: Qt.PointingHandCursor
		onPressed: { drain.stop(); chargeUp.restart(); }
		onReleased: { if (chargeUp.running) { chargeUp.stop(); drain.start(); } }
		onCanceled: { chargeUp.stop(); drain.start(); }
	}

	Rectangle {
		anchors.fill: parent
		radius: height / 2
		color: Qt.alpha(hold.tone, 0.06 + hold.charge * 0.5)
		border.width: 1
		border.color: hold.hovered || hold.charge > 0 ? hold.tone : Qt.alpha(hold.tone, 0.5)
		Behavior on border.color { ColorAnimation { duration: Filament.quick } }
	}

	Row {
		id: row
		anchors.centerIn: parent
		spacing: 7
		FIcon { visible: hold.icon !== ""; anchors.verticalCenter: parent.verticalCenter; name: hold.icon; size: 14; color: hold.charge > 0.6 ? Filament.onAlert : hold.tone }
		FText { anchors.verticalCenter: parent.verticalCenter; text: hold.text; color: hold.charge > 0.6 ? Filament.onAlert : hold.tone; font.weight: Font.Medium }
	}

	Wire {
		x: 12
		y: parent.height - 5
		width: parent.width - 24
		height: 2
		lit: hold.charge
		animateLit: false
		hot: hold.tone
		cold: Qt.alpha(hold.tone, 0.2)
	}
}
