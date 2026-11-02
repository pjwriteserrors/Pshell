pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.style.widgets

// The Ultimate 2 Wireless from the front, live: what is held lights up,
// the sticks' dots move, the triggers fill. Every button is a spot to pick
// (its function in the profile underneath). PL/PR and L4/R4 sit below the
// body, as seen through it; they report only what they are mapped to, so
// that button lights instead.
Item {
	id: root

	property var held: []
	property var axes: ({})
	property string picked: ""
	property color ring: Theme.primary

	signal pick(string id)

	implicitWidth: 460
	implicitHeight: 300

	function on(id) {
		if (root.held.includes(id)) return true;
		switch (id) {
		case "up": return (root.axes.hy ?? 0) < 0;
		case "down": return (root.axes.hy ?? 0) > 0;
		case "left": return (root.axes.hx ?? 0) < 0;
		case "right": return (root.axes.hx ?? 0) > 0;
		case "lt": return (root.axes.lt ?? 0) > 20;
		case "rt": return (root.axes.rt ?? 0) > 20;
		}
		return false;
	}

	component Spot: Rectangle {
		id: spot

		required property string key
		property string text: ""
		property bool round: true
		readonly property bool lit: root.on(spot.key)

		radius: spot.round ? Math.min(width, height) / 2 : 6
		color: spot.lit ? Theme.primary : (root.picked === spot.key ? Theme.primaryContainer : Theme.layer3)
		border.width: root.picked === spot.key ? 2 : 0
		border.color: Theme.primary

		Behavior on color {
			ColorAnim {}
		}

		StyledText {
			anchors.centerIn: parent
			text: spot.text
			font.pixelSize: Theme.size.small
			font.weight: Font.Bold
			tone: spot.lit ? Theme.onPrimary : Theme.textMuted
		}

		MouseArea {
			anchors.fill: parent
			cursorShape: Qt.PointingHandCursor
			onClicked: root.pick(spot.key)
		}
	}

	component Stick: Item {
		id: stick

		required property string key
		property real ax: 0
		property real ay: 0

		width: 62
		height: 62

		Rectangle {
			anchors.fill: parent
			radius: width / 2
			color: Theme.layer2
			border.width: 3
			border.color: Qt.alpha(root.ring, 0.55)
		}

		Spot {
			key: stick.key
			text: ""
			width: 34
			height: 34
			x: (stick.width - width) / 2 + stick.ax * 13
			y: (stick.height - height) / 2 + stick.ay * 13
		}
	}

	// shoulders and triggers
	Repeater {
		model: [
			{ key: "lt", x: 70, w: 70, axis: "lt" },
			{ key: "rt", x: 320, w: 70, axis: "rt" }
		]

		delegate: Rectangle {
			id: trig

			required property var modelData

			x: trig.modelData.x
			y: 0
			width: trig.modelData.w
			height: 22
			radius: 8
			color: root.picked === trig.modelData.key ? Theme.primaryContainer : Theme.layer3
			border.width: root.picked === trig.modelData.key ? 2 : 0
			border.color: Theme.primary
			clip: true

			Rectangle {
				width: parent.width * Math.min(1, (root.axes[trig.modelData.axis] ?? 0) / 255)
				height: parent.height
				color: Theme.primary
			}

			StyledText {
				anchors.centerIn: parent
				text: trig.modelData.key.toUpperCase()
				font.pixelSize: Theme.size.small
				font.weight: Font.Bold
				tone: Theme.textMuted
			}

			MouseArea {
				anchors.fill: parent
				cursorShape: Qt.PointingHandCursor
				onClicked: root.pick(trig.modelData.key)
			}
		}
	}

	Spot { key: "lb"; text: "LB"; round: false; x: 60; y: 28; width: 92; height: 20 }
	Spot { key: "rb"; text: "RB"; round: false; x: 308; y: 28; width: 92; height: 20 }
	Spot { key: "l4"; text: "L4"; round: false; x: 156; y: 28; width: 36; height: 20 }
	Spot { key: "r4"; text: "R4"; round: false; x: 268; y: 28; width: 36; height: 20 }

	// the body
	Rectangle {
		x: 30
		y: 54
		width: 400
		height: 190
		radius: 90
		color: Theme.layer1
		border.width: 1
		border.color: Theme.outline
	}

	Stick {
		key: "l3"
		x: 72
		y: 82
		ax: (root.axes.lx ?? 0) / 32768
		ay: (root.axes.ly ?? 0) / 32768
	}

	Stick {
		key: "r3"
		x: 262
		y: 160
		ax: (root.axes.rx ?? 0) / 32768
		ay: (root.axes.ry ?? 0) / 32768
	}

	// d-pad
	Spot { key: "up"; round: false; x: 152; y: 150; width: 22; height: 26 }
	Spot { key: "down"; round: false; x: 152; y: 198; width: 22; height: 26 }
	Spot { key: "left"; round: false; x: 126; y: 176; width: 26; height: 22 }
	Spot { key: "right"; round: false; x: 174; y: 176; width: 26; height: 22 }

	// face buttons
	Spot { key: "y"; text: "Y"; x: 340; y: 78; width: 30; height: 30 }
	Spot { key: "x"; text: "X"; x: 308; y: 108; width: 30; height: 30 }
	Spot { key: "b"; text: "B"; x: 372; y: 108; width: 30; height: 30 }
	Spot { key: "a"; text: "A"; x: 340; y: 138; width: 30; height: 30 }

	// the middle
	Spot { key: "select"; text: "⧉"; x: 186; y: 104; width: 22; height: 22 }
	Spot { key: "start"; text: "≡"; x: 252; y: 104; width: 22; height: 22 }
	Spot { key: "home"; text: "8"; x: 216; y: 72; width: 28; height: 28 }
	Spot { key: "star"; text: "★"; x: 219; y: 140; width: 22; height: 22 }

	// the back, as seen through it
	Spot { key: "pl"; text: "PL"; round: false; x: 130; y: 256; width: 60; height: 26; opacity: 0.85 }
	Spot { key: "pr"; text: "PR"; round: false; x: 270; y: 256; width: 60; height: 26; opacity: 0.85 }

	StyledText {
		x: 0
		width: root.width
		y: 284
		horizontalAlignment: Text.AlignHCenter
		text: "back"
		font.pixelSize: Theme.size.small
		tone: Theme.textSubtle
	}
}
