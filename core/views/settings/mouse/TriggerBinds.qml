pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services
import qs.core.views.settings
import "Waves.js" as Waves

// What a press in a game is felt as (options.rumbleBinds, Triggers in
// scripts/mouse/mouse.py): a key or mouse button, the waveform it plays,
// and automatic fire while it is held. A row lights up when its press is
// felt; a click on the key records another one.
ColumnLayout {
	id: root

	// by itself (gamefeel.py) nothing is bound until it is bound here: the
	// game's own haptics and its sound already give what the defaults would
	property bool automatic: false
	// the daemon's defaults until something is changed here
	readonly property var defaults: root.automatic ? [] : [
		{ key: "BTN_LEFT", label: "Shoot", feel: "SHARP COLLISION", repeat: 0 },
		{ key: "BTN_RIGHT", label: "Aim", feel: "WHISPER COLLISION", repeat: 0 },
		{ key: "KEY_R", label: "Reload", feel: "DAMP COLLISION", then: [[420, "SUBTLE COLLISION"], [760, "SHARP STATE CHANGE"]] }
	]
	readonly property var binds: Array.isArray(Mouse.option("rumbleBinds", null)) ? Mouse.option("rumbleBinds", null) : root.defaults
	readonly property var presets: [
		{ key: "KEY_V", label: "Melee", feel: "DAMP COLLISION" },
		{ key: "KEY_G", label: "Grenade", feel: "DAMP STATE CHANGE", then: [[900, "SHARP COLLISION"]] },
		{ key: "KEY_SPACE", label: "Jump", feel: "SUBTLE COLLISION" },
		{ key: "KEY_E", label: "Use", feel: "WHISPER COLLISION" }
	]
	readonly property var feels: ["SHARP COLLISION", "DAMP COLLISION", "SUBTLE COLLISION", "WHISPER COLLISION", "SHARP STATE CHANGE", "DAMP STATE CHANGE", "KNOCK"]
	readonly property var buttonNames: ({ BTN_LEFT: "Left click", BTN_RIGHT: "Right click", BTN_MIDDLE: "Middle click", BTN_SIDE: "Back button", BTN_EXTRA: "Forward button" })
	// the row whose key is being recorded, -1 none
	property int recording: -1
	property int open: -1

	spacing: 6

	function keyName(bind) {
		if (bind.name) return bind.name;
		const key = String(bind.key ?? "");
		if (root.buttonNames[key]) return root.buttonNames[key];
		const plain = key.replace(/^KEY_/, "");
		return plain.length === 1 ? plain : plain.charAt(0) + plain.slice(1).toLowerCase();
	}

	function save(list) {
		Mouse.setOption("rumbleBinds", list);
	}

	function change(index, values) {
		const list = root.binds.slice();
		list[index] = Object.assign({}, list[index], values);
		root.save(list);
	}

	function remove(index) {
		const list = root.binds.slice();
		list.splice(index, 1);
		root.open = -1;
		root.save(list);
	}

	function add(bind) {
		root.save(root.binds.concat([Object.assign({ repeat: 0 }, bind)]));
		root.open = root.binds.length - 1;
	}

	// a key from the keyboard: its evdev code (Qt's native scan code less 8)
	function recordKey(event) {
		if (root.recording < 0) return;
		if (event.key === Qt.Key_Escape) {
			root.recording = -1;
			return;
		}
		const code = event.nativeScanCode - 8;
		if (code <= 0) return;
		let name = event.text && event.text.trim().length === 1 ? event.text.toUpperCase() : "";
		if (!name) name = { [Qt.Key_Space]: "Space", [Qt.Key_Shift]: "Shift", [Qt.Key_Control]: "Ctrl", [Qt.Key_Alt]: "Alt", [Qt.Key_Tab]: "Tab", [Qt.Key_CapsLock]: "Caps Lock" }[event.key] ?? `Key ${code}`;
		root.change(root.recording, { code, key: "", name });
		root.recording = -1;
	}

	function recordButton(button) {
		if (root.recording < 0) return;
		const key = { [Qt.LeftButton]: "BTN_LEFT", [Qt.RightButton]: "BTN_RIGHT", [Qt.MiddleButton]: "BTN_MIDDLE", [Qt.BackButton]: "BTN_SIDE", [Qt.ForwardButton]: "BTN_EXTRA" }[button];
		if (!key) return;
		root.change(root.recording, { key, code: undefined, name: "" });
		root.recording = -1;
	}

	// takes the keys while a row records
	Item {
		id: catcher

		focus: root.recording >= 0
		Keys.onPressed: event => {
			root.recordKey(event);
			event.accepted = true;
		}
		onFocusChanged: if (root.recording >= 0) catcher.forceActiveFocus()
	}

	Repeater {
		model: root.binds.length

		delegate: Rectangle {
			id: row

			required property int index
			readonly property var bind: root.binds[row.index] ?? ({})
			readonly property bool expanded: root.open === row.index
			readonly property bool recordingHere: root.recording === row.index
			property real flash: 0

			Layout.fillWidth: true
			implicitHeight: head.height + (row.expanded ? details.implicitHeight + 12 : 0)
			radius: Theme.radius.large
			color: row.expanded ? Theme.layer2 : Theme.layer1
			clip: true

			Behavior on implicitHeight {
				SpatialAnim {
					duration: Motion.medium
				}
			}
			Behavior on color {
				ColorAnim {}
			}

			Connections {
				target: Mouse

				function onTriggered(key, label) {
					if (label === (row.bind.label ?? "")) {
						row.flash = 1;
						flashOut.restart();
					}
				}
			}

			NumberAnimation {
				id: flashOut

				target: row
				property: "flash"
				to: 0
				duration: 480
				easing.type: Easing.OutCubic
			}

			Rectangle {
				anchors.fill: parent
				radius: parent.radius
				color: Theme.primary
				opacity: row.flash * 0.22
			}

			RowLayout {
				id: head

				anchors.left: parent.left
				anchors.right: parent.right
				anchors.top: parent.top
				anchors.margins: 8
				height: 40
				spacing: 10

				// the key: a click records another
				Clickable {
					id: keyChip

					Layout.preferredWidth: Math.max(96, keyLabel.implicitWidth + 28)
					Layout.preferredHeight: 32
					radius: Theme.radius.medium
					color: row.recordingHere ? Theme.primary : Theme.layer3
					acceptedButtons: row.recordingHere ? (Qt.LeftButton | Qt.RightButton | Qt.MiddleButton | Qt.BackButton | Qt.ForwardButton) : Qt.LeftButton
					onClicked: mouse => {
						if (row.recordingHere) {
							root.recordButton(mouse.button);
							return;
						}
						root.recording = row.index;
						catcher.forceActiveFocus();
					}
					onRightClicked: mouse => root.recordButton(Qt.RightButton)
					onMiddleClicked: mouse => root.recordButton(Qt.MiddleButton)

					StyledText {
						id: keyLabel

						anchors.centerIn: parent
						text: row.recordingHere ? "Press it…" : root.keyName(row.bind)
						tone: row.recordingHere ? Theme.onPrimary : Theme.text
						font.weight: Font.DemiBold
						font.pixelSize: Theme.size.small

						SequentialAnimation on opacity {
							running: row.recordingHere
							loops: Animation.Infinite
							alwaysRunToEnd: true
							NumberAnimation { to: 0.45; duration: 420 }
							NumberAnimation { to: 1; duration: 420 }
						}
					}
				}

				Glyph {
					icon: "arrow_right"
					size: 14
					color: Theme.textFaint
				}

				Field {
					Layout.fillWidth: true
					Layout.preferredHeight: 32
					text: row.bind.label ?? ""
					placeholder: "What it does"
					clearable: false
					onEdited: text => root.change(row.index, { label: text })
				}

				StyledText {
					text: Waves.names[row.bind.feel] ?? row.bind.feel ?? ""
					tone: Theme.textSubtle
					font.pixelSize: Theme.size.small
				}

				Glyph {
					visible: (row.bind.repeat ?? 0) > 0
					icon: "repeat"
					size: 15
					color: Theme.secondary
				}

				IconButton {
					icon: row.expanded ? "chevron_up" : "chevron_down"
					onClicked: root.open = row.expanded ? -1 : row.index
				}
			}

			ColumnLayout {
				id: details

				anchors.left: parent.left
				anchors.right: parent.right
				anchors.top: head.bottom
				anchors.margins: 10
				spacing: 10
				opacity: row.expanded ? 1 : 0

				Behavior on opacity {
					Anim {}
				}

				GridLayout {
					Layout.fillWidth: true
					columns: 4
					columnSpacing: 6
					rowSpacing: 6

					Repeater {
						model: root.feels

						delegate: WaveTile {
							required property string modelData

							Layout.fillWidth: true
							waveform: modelData
							chosen: row.bind.feel === modelData
							onClicked: root.change(row.index, { feel: modelData })
						}
					}
				}

				RowLayout {
					Layout.fillWidth: true
					spacing: 12

					Toggle {
						checked: (row.bind.repeat ?? 0) > 0
						onToggled: on => root.change(row.index, { repeat: on ? 110 : 0 })
					}

					StyledText {
						Layout.fillWidth: true
						text: (row.bind.repeat ?? 0) > 0 ? `Automatic fire: again every ${row.bind.repeat} ms while held` : "Once per press"
						tone: Theme.textSubtle
						font.pixelSize: Theme.size.small
					}

					TextButton {
						text: "Remove"
						icon: "delete_outline"
						variant: "text"
						onActivated: root.remove(row.index)
					}
				}

				ValueSlider {
					Layout.fillWidth: true
					visible: (row.bind.repeat ?? 0) > 0
					from: 50
					to: 400
					step: 10
					unit: " ms"
					icon: "timer_outline"
					label: "Fire rate"
					value: row.bind.repeat ?? 110
					onMoved: v => root.change(row.index, { repeat: Math.round(v) })
				}

				StyledText {
					Layout.fillWidth: true
					visible: (row.bind.then ?? []).length > 0
					text: `Then ${(row.bind.then ?? []).map(step => `${Waves.names[step[1]] ?? step[1]} after ${step[0]} ms`).join(", ")}`
					tone: Theme.textFaint
					font.pixelSize: Theme.size.small
					wrapMode: Text.WordWrap
				}
			}
		}
	}

	Flow {
		Layout.fillWidth: true
		spacing: 6

		TextButton {
			text: "Key or button"
			icon: "plus"
			onActivated: {
				root.add({ key: "KEY_F", label: "", feel: "DAMP COLLISION" });
				root.recording = root.binds.length - 1;
				catcher.forceActiveFocus();
			}
		}

		Repeater {
			model: root.presets.filter(p => !root.binds.some(b => b.label === p.label))

			delegate: TextButton {
				required property var modelData

				text: modelData.label
				icon: "plus"
				variant: "text"
				onActivated: root.add(modelData)
			}
		}

		TextButton {
			visible: Array.isArray(Mouse.option("rumbleBinds", null))
			text: "As it comes"
			icon: "restore"
			variant: "text"
			onActivated: {
				root.open = -1;
				Mouse.setOption("rumbleBinds", null);
			}
		}
	}
}
