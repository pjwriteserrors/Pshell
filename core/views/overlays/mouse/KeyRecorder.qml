import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// Takes a shortcut as it is pressed: the modifiers held and one key, or
// modifiers alone (Super pressed and let go is Super). Keeps
// the keys' evdev codes too (Qt's native scan code less 8), so the mouse
// presses the very same keys whatever the layout.
Rectangle {
	id: root

	property bool recording: false
	property var keys: []
	property var codes: []
	property string label: ""
	// the modifiers pressed so far while no other key came
	property var pending: []

	signal recorded(var keys, var codes, string label)

	// ctrl, shift, alt, super: the order the daemon presses them in
	readonly property var modifierOrder: ["ctrl", "shift", "alt", "super"].map(name => Keybinds.modifiers.find(modifier => modifier.name === name))

	function start() {
		root.pending = [];
		root.recording = true;
		catcher.forceActiveFocus();
	}

	// keys given rather than pressed (a key button)
	function use(keys) {
		const codes = keys.map(k => root.modifierOrder.find(m => m.name === k)?.code ?? 0);
		root.finish(keys, codes.includes(0) ? [] : codes);
	}

	function finish(keys, codes) {
		root.keys = keys;
		root.codes = codes.length === keys.length ? codes : [];
		root.label = keys.map(k => root.pretty(k)).join(" + ");
		root.pending = [];
		root.recording = false;
		root.recorded(root.keys, root.codes, root.label);
	}

	function nameOf(event) {
		const named = {
			[Qt.Key_Return]: "enter", [Qt.Key_Enter]: "enter", [Qt.Key_Escape]: "esc", [Qt.Key_Tab]: "tab",
			[Qt.Key_Backtab]: "tab", [Qt.Key_Space]: "space", [Qt.Key_Backspace]: "backspace",
			[Qt.Key_Delete]: "delete", [Qt.Key_Insert]: "insert", [Qt.Key_Home]: "home", [Qt.Key_End]: "end",
			[Qt.Key_PageUp]: "pageup", [Qt.Key_PageDown]: "pagedown", [Qt.Key_Up]: "up", [Qt.Key_Down]: "down",
			[Qt.Key_Left]: "left", [Qt.Key_Right]: "right", [Qt.Key_Print]: "print", [Qt.Key_Menu]: "menu",
			[Qt.Key_MediaPlay]: "playpause", [Qt.Key_MediaTogglePlayPause]: "playpause", [Qt.Key_MediaNext]: "next",
			[Qt.Key_MediaPrevious]: "previous", [Qt.Key_VolumeUp]: "volumeup", [Qt.Key_VolumeDown]: "volumedown",
			[Qt.Key_VolumeMute]: "mute"
		};
		if (named[event.key]) return named[event.key];
		if (event.key >= Qt.Key_F1 && event.key <= Qt.Key_F24) return `f${event.key - Qt.Key_F1 + 1}`;
		// the letter as the layout has it, not what Shift made of it
		if (event.key >= Qt.Key_A && event.key <= Qt.Key_Z) return String.fromCharCode(event.key).toLowerCase();
		if (event.key >= Qt.Key_0 && event.key <= Qt.Key_9) return String.fromCharCode(event.key);
		const text = String(event.text || "").toLowerCase();
		if (text.length === 1 && text.charCodeAt(0) > 32) return text;
		return "";
	}

	function pretty(name) {
		const words = { ctrl: "Ctrl", shift: "Shift", alt: "Alt", super: "Super", enter: "Enter", esc: "Esc", tab: "Tab", space: "Space", backspace: "Backspace", delete: "Delete", pageup: "Page up", pagedown: "Page down", up: "↑", down: "↓", left: "←", right: "→", playpause: "Play", volumeup: "Volume +", volumedown: "Volume −", mute: "Mute", print: "Print", plus: "+", minus: "−" };
		if (words[name]) return words[name];
		if (/^f\d+$/.test(name)) return name.toUpperCase();
		return name.length === 1 ? name.toUpperCase() : name;
	}

	implicitHeight: 120
	radius: Theme.radius.large
	color: root.recording ? Theme.primaryContainer : Theme.layer2
	border.width: 1.5
	border.color: root.recording ? Theme.primary : Theme.outline

	Behavior on color {
		ColorAnim {}
	}

	Item {
		id: catcher

		anchors.fill: parent
		focus: root.recording
		Keys.onPressed: event => {
			if (!root.recording) return;
			event.accepted = true;
			const modifier = root.modifierOrder.find(m => m.keys.includes(event.key));
			if (modifier) {
				if (!root.pending.includes(modifier.name))
					root.pending = root.modifierOrder.filter(m => m.name === modifier.name || root.pending.includes(m.name)).map(m => m.name);
				return;
			}
			const keys = [];
			const codes = [];
			if (event.modifiers & Qt.ControlModifier) { keys.push("ctrl"); codes.push(29); }
			if (event.modifiers & Qt.ShiftModifier) { keys.push("shift"); codes.push(42); }
			if (event.modifiers & Qt.AltModifier) { keys.push("alt"); codes.push(56); }
			if (event.modifiers & Qt.MetaModifier) { keys.push("super"); codes.push(125); }
			const name = root.nameOf(event);
			if (name === "") return;
			keys.push(name);
			if (event.nativeScanCode > 8) codes.push(event.nativeScanCode - 8);
			root.finish(keys, codes);
		}
		// modifiers let go with nothing else pressed: they are the shortcut
		Keys.onReleased: event => {
			if (!root.recording || event.isAutoRepeat) return;
			if (!root.modifierOrder.some(m => m.keys.includes(event.key)) || root.pending.length === 0) return;
			event.accepted = true;
			const names = root.pending;
			root.finish(names, names.map(n => root.modifierOrder.find(m => m.name === n).code));
		}
	}

	MouseArea {
		anchors.fill: parent
		cursorShape: Qt.PointingHandCursor
		onClicked: root.start()
	}

	ColumnLayout {
		anchors.centerIn: parent
		spacing: 10

		Row {
			Layout.alignment: Qt.AlignHCenter
			spacing: 6
			visible: root.keys.length > 0 && !root.recording

			Repeater {
				model: root.keys

				delegate: Rectangle {
					id: cap

					required property string modelData
					required property int index

					width: Math.max(36, capText.implicitWidth + 20)
					height: 36
					radius: Theme.radius.medium
					color: Theme.layer3
					border.width: 1
					border.color: Qt.alpha(Theme.text, 0.14)

					// keys pop in one after the other
					scale: 0
					Component.onCompleted: popIn.start()

					SequentialAnimation {
						id: popIn

						PauseAnimation {
							duration: cap.index * 60
						}
						NumberAnimation {
							target: cap
							property: "scale"
							to: 1
							duration: Motion.medium
							easing.type: Easing.BezierSpline
							easing.bezierCurve: Motion.spatialFast
						}
					}

					Rectangle {
						anchors.left: parent.left
						anchors.right: parent.right
						anchors.bottom: parent.bottom
						height: 3
						radius: 2
						color: Qt.alpha(Theme.text, 0.08)
					}

					StyledText {
						id: capText

						anchors.centerIn: parent
						text: root.pretty(cap.modelData)
						font.weight: Font.DemiBold
					}
				}
			}
		}

		Glyph {
			Layout.alignment: Qt.AlignHCenter
			visible: root.recording || root.keys.length === 0
			icon: "keyboard_outline"
			size: 26
			color: root.recording ? Theme.primary : Theme.textMuted

			SequentialAnimation on opacity {
				running: root.recording
				loops: Animation.Infinite
				onRunningChanged: if (!running) parent.opacity = 1

				Anim {
					to: 0.35
					duration: Motion.extraLong
				}
				Anim {
					to: 1
					duration: Motion.extraLong
				}
			}
		}

		StyledText {
			Layout.alignment: Qt.AlignHCenter
			text: root.recording ? (root.pending.length > 0 ? root.pending.map(k => root.pretty(k)).join(" + ") + " + …  or let go" : "Press the shortcut now") : (root.keys.length > 0 ? "Click to record another" : "Click, then press the shortcut – or one key")
			tone: root.recording ? Theme.primary : Theme.textMuted
			font.weight: Font.Medium
		}
	}
}
