pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io
import "components"

// The power thread. One wire across the middle of the screen with four
// knots on it: lock, log out, restart, power off. The spark rests on the
// knot the arrows are at; Enter on a harmless knot fires, the two that end
// the session need the spark held on them until the wire is full.
FocusScope {
	id: power

	property real reveal: 1
	property int index: 0
	property string statUser: ""
	property string statKernel: ""
	property string statUptime: ""
	property real charge: 0

	readonly property var actions: [
		{ id: "lock", label: "Lock", hint: "keep everything running", icon: "system-lock-screen-symbolic", grave: false },
		{ id: "logout", label: "Log out", hint: "end the session", icon: "system-log-out-symbolic", grave: true },
		{ id: "reboot", label: "Restart", hint: "power cycle", icon: "system-reboot-symbolic", grave: true },
		{ id: "shutdown", label: "Power off", hint: "the end of the thread", icon: "system-shutdown-symbolic", grave: true }
	]

	signal action(string name)
	signal closeRequested()

	focus: true

	Keys.onEscapePressed: event => { event.accepted = true; power.closeRequested(); }
	Keys.onLeftPressed: event => { event.accepted = true; power.index = Math.max(0, power.index - 1); }
	Keys.onRightPressed: event => { event.accepted = true; power.index = Math.min(power.actions.length - 1, power.index + 1); }
	Keys.onReturnPressed: event => { event.accepted = true; power.fire(power.index); }
	Keys.onEnterPressed: event => { event.accepted = true; power.fire(power.index); }
	Keys.onPressed: event => {
		if (event.key === Qt.Key_Space && power.actions[power.index].grave) { event.accepted = true; if (!chargeUp.running) chargeUp.restart(); }
	}
	Keys.onReleased: event => {
		if (event.key === Qt.Key_Space && !event.isAutoRepeat) { event.accepted = true; if (chargeUp.running) { chargeUp.stop(); drain.start(); } }
	}

	function fire(i) {
		const entry = power.actions[i];
		if (!entry.grave) { power.action(entry.id); return; }
		if (!chargeUp.running) chargeUp.restart();
	}

	NumberAnimation { id: chargeUp; target: power; property: "charge"; to: 1; duration: 700; easing.type: Easing.InQuad; onFinished: { power.action(power.actions[power.index].id); drain.start(); } }
	NumberAnimation { id: drain; target: power; property: "charge"; to: 0; duration: 220 }

	Process {
		running: true
		command: ["sh", "-lc", "printf '%s|%s|%s' \"$USER@$(cat /etc/hostname 2>/dev/null || uname -n)\" \"$(uname -r)\" \"$(uptime -p | sed 's/^up //')\""]
		stdout: StdioCollector {
			onStreamFinished: {
				const parts = text.split("|");
				power.statUser = parts[0] || "";
				power.statKernel = parts[1] || "";
				power.statUptime = parts[2] || "";
			}
		}
	}

	readonly property real knotSpacing: (width - 120) / (actions.length - 1)

	Band {
		reveal: power.reveal; order: 0
		x: 30; y: 26
		width: parent.width - 60; height: 40
		FText {
			anchors.left: parent.left
			text: power.statUser
			font.pixelSize: Filament.textLg
			font.weight: Font.DemiBold
		}
		FText {
			anchors.left: parent.left
			y: 22
			text: power.statUptime !== "" ? `up ${power.statUptime}  ·  ${power.statKernel}` : power.statKernel
			mono: true
			tone: "mute"
			font.pixelSize: Filament.textXs
		}
		FText {
			anchors.right: parent.right
			text: power.actions[power.index].grave ? "Enter or Space: hold to charge" : "Enter"
			tone: "faint"
			font.pixelSize: Filament.textXs
		}
	}

	// The thread itself, lit up to the spark.
	Wire {
		id: wire
		x: 60
		y: 130
		width: parent.width - 120
		height: 2
		cold: Filament.wireDim
		lit: power.reveal * (power.index / (power.actions.length - 1))
		hot: Filament.charge
		animateLit: true
	}

	Spark {
		x: 60 + power.index * power.knotSpacing - 6
		y: 131 - 6
		size: 12
		breathing: true
		color: power.actions[power.index].grave ? Filament.alert : Filament.charge
		Behavior on x { SpringAnimation { spring: 3.5; damping: 0.3; epsilon: 0.5 } }
		opacity: power.reveal
	}

	Repeater {
		model: power.actions
		Item {
			id: knot
			required property var modelData
			required property int index
			readonly property bool chosen: power.index === index
			readonly property bool hot: touch.containsMouse
			x: 60 + index * power.knotSpacing - 60
			y: 90
			width: 120
			height: 110
			opacity: Filament.band(power.reveal, index + 1)

			MouseArea {
				id: touch
				anchors.fill: parent
				hoverEnabled: true
				cursorShape: Qt.PointingHandCursor
				onEntered: power.index = knot.index
				onPressed: { power.index = knot.index; if (knot.modelData.grave) { drain.stop(); chargeUp.restart(); } }
				onReleased: {
					if (!knot.modelData.grave) { power.action(knot.modelData.id); return; }
					if (chargeUp.running) { chargeUp.stop(); drain.start(); }
				}
				onCanceled: { chargeUp.stop(); drain.start(); }
			}

			// The knot on the wire: a ring the spark sits in when chosen.
			Rectangle {
				anchors.horizontalCenter: parent.horizontalCenter
				y: 40 - height / 2 + 1
				width: knot.chosen ? 26 : 14
				height: width
				radius: width / 2
				color: knot.chosen ? Qt.alpha(knot.modelData.grave ? Filament.alert : Filament.charge, 0.16 + power.charge * 0.6) : Filament.planeSolid
				border.width: 1
				border.color: knot.chosen ? (knot.modelData.grave ? Filament.alert : Filament.charge) : Filament.wire
				Behavior on width { SpringAnimation { spring: 4; damping: 0.3; epsilon: 0.05 } }
			}

			FIcon {
				anchors.horizontalCenter: parent.horizontalCenter
				y: 58
				name: knot.modelData.icon
				size: 18
				color: knot.chosen ? (knot.modelData.grave ? Filament.alert : Filament.charge) : Filament.inkMute
				Behavior on color { ColorAnimation { duration: Filament.quick } }
			}

			FText {
				anchors.horizontalCenter: parent.horizontalCenter
				y: 82
				text: knot.modelData.label
				font.pixelSize: Filament.textMd
				font.weight: knot.chosen ? Font.DemiBold : Font.Medium
				color: knot.chosen ? Filament.ink : Filament.inkSoft
			}

			FText {
				anchors.horizontalCenter: parent.horizontalCenter
				y: 100
				text: knot.modelData.hint
				tone: "faint"
				font.pixelSize: Filament.textXs
				opacity: knot.chosen ? 1 : 0
				Behavior on opacity { NumberAnimation { duration: Filament.quick } }
			}
		}
	}

	// The charge, drawn as the stretch of thread under the chosen knot filling.
	Wire {
		x: 60 + power.index * power.knotSpacing - 40
		y: 130
		width: 80
		height: 2
		lit: power.charge
		litFrom: 0
		animateLit: false
		cold: "transparent"
		hot: Filament.alert
		glow: true
		visible: power.charge > 0
	}
}
