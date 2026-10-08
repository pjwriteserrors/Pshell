import QtQuick
import qs.style.theme
import qs.style.widgets

// A number you drag sideways to change (the way design tools do it), nudge
// with the wheel, or double-click to type.
Rectangle {
	id: root

	property real value: 0
	property real from: 0
	property real to: 100
	property real step: 1
	property int decimals: 0
	property string unit: ""
	// value per pixel dragged
	property real speed: root.step / 2

	signal moved(real value)

	function clampValue(v) {
		const stepped = Math.round(v / root.step) * root.step;
		return Number(Math.max(root.from, Math.min(root.to, stepped)).toFixed(root.decimals));
	}

	implicitWidth: Math.max(54, label.implicitWidth + 22)
	implicitHeight: 28
	radius: 14
	color: mouse.pressed ? Theme.primary : (mouse.containsMouse || input.activeFocus ? Theme.layer3 : Theme.layer2)
	scale: mouse.pressed ? 1.08 : 1

	Behavior on color {
		ColorAnim {}
	}
	Behavior on scale {
		SpatialAnim {
			duration: Motion.short
		}
	}

	StyledText {
		id: label

		anchors.centerIn: parent
		visible: !input.visible
		text: `${Number(root.value).toFixed(root.decimals)}${root.unit}`
		tabular: true
		tone: mouse.pressed ? Theme.onPrimary : Theme.text
		font.weight: Font.DemiBold
		font.pixelSize: Theme.size.label
	}

	TextInput {
		id: input

		anchors.centerIn: parent
		width: parent.width - 12
		visible: false
		horizontalAlignment: TextInput.AlignHCenter
		color: Theme.text
		font.family: Theme.fontFamily
		font.pixelSize: Theme.size.label
		validator: DoubleValidator {}
		onAccepted: {
			root.moved(root.clampValue(Number(input.text)));
			input.visible = false;
		}
		onActiveFocusChanged: if (!activeFocus) input.visible = false
		Keys.onEscapePressed: input.visible = false
	}

	MouseArea {
		id: mouse

		property real startX
		property real startValue

		anchors.fill: parent
		hoverEnabled: true
		preventStealing: true
		enabled: !input.visible
		cursorShape: Qt.SizeHorCursor
		onPressed: event => {
			mouse.startX = event.x;
			mouse.startValue = root.value;
		}
		onPositionChanged: event => {
			if (!pressed) return;
			const next = root.clampValue(mouse.startValue + (event.x - mouse.startX) * root.speed);
			if (next !== root.value) root.moved(next);
		}
		onDoubleClicked: {
			input.text = String(root.value);
			input.visible = true;
			input.forceActiveFocus();
			input.selectAll();
		}
		onWheel: wheel => root.moved(root.clampValue(root.value + (wheel.angleDelta.y > 0 ? root.step : -root.step)))
	}
}
