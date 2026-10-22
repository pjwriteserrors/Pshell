pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.style.widgets

// The Apex Pro TKL Gen 3 from above (German ISO): every key a spot to pick
// (Ctrl or Shift adds to the pick), its actuation as a level rising in it,
// a dot where it does something else than its print, keys lighting up as
// they are typed. Sizes are in keys (u).
Item {
	id: root

	// hid -> { act, second, release } of the Hall keys
	property var keyState: ({})
	// [hid] picked; hid -> true for keys with another binding
	property var selected: []
	property var changed: ({})
	// evdev code -> held; hid -> evdev code
	property var keys: ({})
	property var codes: ({})
	property var analog: []
	property string screen: ""
	property real brightness: 1

	signal picked(int hid, bool add)

	readonly property real u: Math.min(width / 18.6, height / 6.85)

	implicitWidth: 640
	implicitHeight: 236

	// [label, width, hid, x?] per row; x jumps to a column
	readonly property var rows: [
		[["Esc", 1, 41], ["F1", 1, 58, 2], ["F2", 1, 59], ["F3", 1, 60], ["F4", 1, 61], ["F5", 1, 62, 6.5], ["F6", 1, 63], ["F7", 1, 64], ["F8", 1, 65], ["F9", 1, 66, 11], ["F10", 1, 67], ["F11", 1, 68], ["F12", 1, 69]],
		[["^", 1, 53], ["1", 1, 30], ["2", 1, 31], ["3", 1, 32], ["4", 1, 33], ["5", 1, 34], ["6", 1, 35], ["7", 1, 36], ["8", 1, 37], ["9", 1, 38], ["0", 1, 39], ["ß", 1, 45], ["´", 1, 46], ["⌫", 2, 42], ["Einfg", 1, 73, 15.25], ["Pos1", 1, 74], ["Bild↑", 1, 75]],
		[["⇥", 1.5, 43], ["Q", 1, 20], ["W", 1, 26], ["E", 1, 8], ["R", 1, 21], ["T", 1, 23], ["Z", 1, 28], ["U", 1, 24], ["I", 1, 12], ["O", 1, 18], ["P", 1, 19], ["Ü", 1, 47], ["+", 1, 48], ["Entf", 1, 76, 15.25], ["Ende", 1, 77], ["Bild↓", 1, 78]],
		[["⇪", 1.75, 57], ["A", 1, 4], ["S", 1, 22], ["D", 1, 7], ["F", 1, 9], ["G", 1, 10], ["H", 1, 11], ["J", 1, 13], ["K", 1, 14], ["L", 1, 15], ["Ö", 1, 51], ["Ä", 1, 52], ["#", 1, 50]],
		[["⇧", 1.25, 225], ["<", 1, 100], ["Y", 1, 29], ["X", 1, 27], ["C", 1, 6], ["V", 1, 25], ["B", 1, 5], ["N", 1, 17], ["M", 1, 16], [",", 1, 54], [".", 1, 55], ["-", 1, 56], ["⇧", 2.75, 229], ["↑", 1, 82, 16.25]],
		[["Strg", 1.25, 224], ["❖", 1.25, 227], ["Alt", 1.25, 226], ["", 6.25, 44], ["AltGr", 1.25, 230], ["❖", 1.25, 231], ["SS", 1.25, 240], ["Strg", 1.25, 228], ["←", 1, 80, 15.25], ["↓", 1, 81], ["→", 1, 79]]
	]

	readonly property var placed: {
		const out = [];
		for (let r = 0; r < root.rows.length; r += 1) {
			let x = 0;
			for (const key of root.rows[r]) {
				if (key[3] !== undefined) x = key[3];
				out.push({ label: key[0], w: key[1], hid: key[2], x, y: r === 0 ? 0 : 0.25 + r, h: 1 });
				x += key[1];
			}
		}
		// the ISO Enter
		out.push({ label: "↵", w: 1.25, h: 2, hid: 40, x: 13.75, y: 2.25 });
		return out;
	}

	Rectangle {
		id: slab

		anchors.centerIn: parent
		width: 18.6 * root.u
		height: 6.85 * root.u
		radius: root.u * 0.4
		gradient: Gradient {
			GradientStop {
				position: 0
				color: Qt.tint(Theme.layer3, Qt.alpha(Theme.text, 0.05))
			}
			GradientStop {
				position: 1
				color: Theme.layer2
			}
		}
		border.width: 1
		border.color: Qt.alpha(Theme.text, 0.1)

		Item {
			id: plate

			x: root.u * 0.18
			y: root.u * 0.18
			width: 18.25 * root.u
			height: 6.5 * root.u

			// ── the OLED, the media button and the dial ───────────────────
			Rectangle {
				x: 15.25 * root.u + 1.5
				y: 1.5
				width: 2.1 * root.u
				height: 0.66 * root.u
				radius: root.u * 0.06
				color: "#05070a"
				border.width: 1
				border.color: Qt.alpha(Theme.text, 0.12)

				OledView {
					anchors.fill: parent
					anchors.margins: root.u * 0.05
					frame: root.screen
					dim: true
				}
			}

			Rectangle {
				x: 17.45 * root.u
				y: 0.1 * root.u
				width: 0.62 * root.u
				height: width
				radius: width / 2
				color: Qt.tint(Theme.layer3, Qt.alpha(Theme.text, 0.08))
				border.width: 1
				border.color: Qt.alpha(Theme.text, 0.18)

				Rectangle {
					anchors.centerIn: parent
					width: parent.width * 0.4
					height: width
					radius: width / 2
					color: Qt.alpha(Theme.text, 0.12)
				}
			}

			// ── the keys ──────────────────────────────────────────────────
			Repeater {
				model: root.placed

				delegate: Rectangle {
					id: cap

					required property var modelData
					readonly property int hid: cap.modelData.hid
					readonly property var st: root.keyState[cap.hid] ?? null
					readonly property bool down: root.keys[root.codes[cap.hid] ?? -1] === true
					readonly property bool picked: root.selected.includes(cap.hid)
					readonly property bool hall: root.analog.includes(cap.hid)

					x: cap.modelData.x * root.u + 1.5
					y: cap.modelData.y * root.u + 1.5
					width: cap.modelData.w * root.u - 3
					height: cap.modelData.h * root.u - 3
					radius: root.u * 0.14
					clip: true
					color: cap.down ? Theme.primary : (cap.picked ? Theme.primaryContainer : (hover.containsMouse ? Theme.layer3 : Qt.tint(Theme.layer1, Qt.alpha(Theme.text, 0.03))))
					border.width: cap.picked ? 1.5 : 1
					border.color: cap.picked ? Theme.primary : Qt.alpha(Theme.text, 0.08)
					scale: cap.down ? 0.92 : 1

					Behavior on color {
						ColorAnim {
							duration: cap.down ? 40 : Motion.medium
						}
					}
					Behavior on scale {
						SpatialAnim {
							duration: Motion.short
						}
					}

					// how deep it fires: the lower, the deeper
					Rectangle {
						visible: !!cap.st
						anchors.left: parent.left
						anchors.right: parent.right
						anchors.bottom: parent.bottom
						height: parent.height * (cap.st?.act ?? 0) / 40
						color: Qt.alpha(cap.st?.release && cap.st.release !== "off" ? Theme.tertiary : Theme.primary, cap.down ? 0 : 0.16)

						Behavior on height {
							SpatialAnim {
								duration: Motion.medium
							}
						}
					}

					// the second point of a 2-in-1 key
					Rectangle {
						visible: (cap.st?.second ?? 0) > 0
						anchors.left: parent.left
						anchors.right: parent.right
						y: parent.height * (1 - (cap.st?.second ?? 0) / 40)
						height: 1.5
						color: Theme.secondary
					}

					Text {
						anchors.centerIn: parent
						text: cap.modelData.label
						color: cap.down ? Theme.onPrimary : (cap.picked ? Theme.primary : Qt.tint(Theme.textSubtle, Qt.alpha("#ffffff", root.brightness * 0.25)))
						font.pixelSize: Math.max(7, root.u * (cap.modelData.label.length > 2 ? 0.24 : 0.34))
						font.family: Theme.fontFamily
						font.weight: Font.Medium
					}

					// it does something else
					Rectangle {
						anchors.top: parent.top
						anchors.right: parent.right
						anchors.margins: root.u * 0.07
						width: root.u * 0.12
						height: width
						radius: width / 2
						visible: root.changed[cap.hid] === true
						color: Theme.primary
					}

					MouseArea {
						id: hover

						anchors.fill: parent
						hoverEnabled: true
						cursorShape: Qt.PointingHandCursor
						onClicked: mouse => root.picked(cap.hid, (mouse.modifiers & (Qt.ControlModifier | Qt.ShiftModifier)) !== 0)
					}
				}
			}
		}
	}
}
