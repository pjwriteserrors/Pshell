import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// Where a bind's keys are set: click it (or Enter) and press them. Held
// modifiers light up as keycaps while waiting; the first other key, a wheel
// turn or a side button ends it. Escape alone gives up, and "Type" takes the
// name as niri writes it (Mod+TouchpadScrollDown).
Rectangle {
	id: root

	property string key: ""
	property bool recording: false
	property bool typing: false
	// modifiers held right now, while recording
	property var held: []

	signal recorded(string key)

	function start() {
		root.typing = false;
		root.held = [];
		root.recording = true;
		catcher.forceActiveFocus();
	}

	function stop() {
		root.recording = false;
		root.held = [];
	}

	function take(key) {
		root.stop();
		if (key !== "") root.recorded(key);
	}

	implicitHeight: 148
	radius: Theme.radius.large
	color: root.recording ? Theme.primaryContainer : Theme.layer2
	border.width: root.recording ? 1.5 : 0
	border.color: Qt.alpha(Theme.primary, 0.7)

	Behavior on color {
		ColorAnim {
			duration: Motion.medium
		}
	}

	// Escape in the name field closes the field, not the window
	Keys.onEscapePressed: event => {
		event.accepted = root.typing;
		root.typing = false;
	}

	// the ring that breathes while listening
	Rectangle {
		anchors.fill: parent
		anchors.margins: -ring.grow
		radius: root.radius + ring.grow
		color: "transparent"
		border.width: 2
		border.color: Theme.primary
		opacity: root.recording ? ring.fade : 0

		QtObject {
			id: ring

			property real grow: 0
			property real fade: 0
		}

		SequentialAnimation {
			running: root.recording
			loops: Animation.Infinite

			ParallelAnimation {
				NumberAnimation {
					target: ring
					property: "grow"
					from: 0
					to: 9
					duration: 1300
					easing.type: Easing.OutCubic
				}
				NumberAnimation {
					target: ring
					property: "fade"
					from: 0.55
					to: 0
					duration: 1300
					easing.type: Easing.OutCubic
				}
			}
		}
	}

	FocusScope {
		id: catcher

		anchors.fill: parent
		focus: root.recording

		Keys.onPressed: event => {
			if (!root.recording) return;
			event.accepted = true;
			if (Keybinds.isModifierKey(event)) {
				root.held = Keybinds.modsOf(event.modifiers | (event.key === Qt.Key_Meta || event.key === Qt.Key_Super_L || event.key === Qt.Key_Super_R ? Qt.MetaModifier : 0) | (event.key === Qt.Key_Shift ? Qt.ShiftModifier : 0) | (event.key === Qt.Key_Control ? Qt.ControlModifier : 0) | (event.key === Qt.Key_Alt ? Qt.AltModifier : 0));
				return;
			}
			const mods = Keybinds.modsOf(event.modifiers);
			if (event.key === Qt.Key_Escape && mods.length === 0) {
				root.stop();
				return;
			}
			const name = Keybinds.keyName(event);
			if (name !== "") root.take(Keybinds.join(mods, name));
		}
		Keys.onReleased: event => {
			if (!root.recording) return;
			event.accepted = true;
			if (Keybinds.isModifierKey(event)) {
				let mods = event.modifiers;
				if (event.key === Qt.Key_Meta || event.key === Qt.Key_Super_L || event.key === Qt.Key_Super_R) mods &= ~Qt.MetaModifier;
				if (event.key === Qt.Key_Shift) mods &= ~Qt.ShiftModifier;
				if (event.key === Qt.Key_Control) mods &= ~Qt.ControlModifier;
				if (event.key === Qt.Key_Alt) mods &= ~Qt.AltModifier;
				root.held = Keybinds.modsOf(mods);
			}
		}
	}

	MouseArea {
		anchors.fill: parent
		acceptedButtons: Qt.AllButtons
		cursorShape: Qt.PointingHandCursor
		onClicked: mouse => {
			if (!root.recording) {
				if (mouse.button === Qt.LeftButton) root.start();
				return;
			}
			const mods = Keybinds.modsOf(mouse.modifiers);
			const names = { [Qt.MiddleButton]: "MouseMiddle", [Qt.BackButton]: "MouseBack", [Qt.ForwardButton]: "MouseForward" };
			// a plain click stops; with a modifier held it is the bind
			if (mods.length > 0 && mouse.button === Qt.LeftButton) root.take(Keybinds.join(mods, "MouseLeft"));
			else if (mods.length > 0 && mouse.button === Qt.RightButton) root.take(Keybinds.join(mods, "MouseRight"));
			else if (names[mouse.button]) root.take(Keybinds.join(mods, names[mouse.button]));
			else root.stop();
		}
		onWheel: wheel => {
			if (!root.recording) {
				wheel.accepted = false;
				return;
			}
			const dy = wheel.angleDelta.y;
			const dx = wheel.angleDelta.x;
			const name = Math.abs(dy) >= Math.abs(dx) ? (dy > 0 ? "WheelScrollUp" : "WheelScrollDown") : (dx > 0 ? "WheelScrollLeft" : "WheelScrollRight");
			root.take(Keybinds.join(Keybinds.modsOf(wheel.modifiers), name));
		}
	}

	ColumnLayout {
		anchors.centerIn: parent
		width: parent.width - 32
		spacing: 14

		Item {
			Layout.fillWidth: true
			Layout.preferredHeight: 50

			// the keys of the bind
			KeyCombo {
				id: combo

				anchors.centerIn: parent
				visible: !root.recording && root.key !== ""
				key: root.key
				size: 42
				animated: true
			}

			// held while listening, with a ghost cap for the key to come
			Row {
				anchors.centerIn: parent
				visible: root.recording
				spacing: 9

				KeyCombo {
					caps: root.held.map(mod => Keybinds.keyLabel(mod))
					size: 42
					lit: true
					animated: true
				}

				Keycap {
					text: "…"
					size: 42
					faint: true
					opacity: ghost.value

					QtObject {
						id: ghost

						property real value: 1
					}

					SequentialAnimation {
						running: root.recording
						loops: Animation.Infinite

						NumberAnimation {
							target: ghost
							property: "value"
							to: 0.35
							duration: 700
							easing.type: Easing.InOutSine
						}
						NumberAnimation {
							target: ghost
							property: "value"
							to: 1
							duration: 700
							easing.type: Easing.InOutSine
						}
					}
				}
			}

			StyledText {
				anchors.centerIn: parent
				visible: !root.recording && root.key === ""
				text: "No keys yet"
				tone: Theme.textSubtle
				font.pixelSize: Theme.size.title
			}
		}

		RowLayout {
			Layout.alignment: Qt.AlignHCenter
			spacing: 8

			Glyph {
				icon: root.recording ? "record" : "keyboard"
				size: 15
				color: root.recording ? Theme.primary : Theme.textSubtle
			}

			StyledText {
				text: root.recording ? "Press the keys · Esc gives up" : (root.key === "" ? "Click to record" : "Click to record again")
				tone: root.recording ? Theme.primary : Theme.textMuted
				font.pixelSize: Theme.size.label
				font.weight: Font.Medium
			}
		}
	}

	TextButton {
		anchors.right: parent.right
		anchors.bottom: parent.bottom
		anchors.margins: 8
		implicitHeight: 26
		visible: !root.recording
		variant: "ghost"
		icon: "pencil"
		text: "Type"
		onActivated: {
			root.typing = !root.typing;
			if (root.typing) Qt.callLater(() => typed.focusInput());
		}
	}

	// the name as text, for keys that cannot be pressed here
	Field {
		id: typed

		anchors.left: parent.left
		anchors.right: parent.right
		anchors.bottom: parent.bottom
		anchors.margins: 8
		implicitHeight: 34
		visible: opacity > 0
		opacity: root.typing ? 1 : 0
		icon: "keyboard"
		placeholder: "Mod+Shift+TouchpadScrollDown"
		fontSize: Theme.size.label
		onVisibleChanged: if (visible) typed.text = root.key
		onAccepted: {
			root.typing = false;
			if (typed.text.trim() !== "") root.recorded(typed.text.trim());
		}

		Behavior on opacity {
			Anim {
				duration: Motion.short
			}
		}
	}
}
