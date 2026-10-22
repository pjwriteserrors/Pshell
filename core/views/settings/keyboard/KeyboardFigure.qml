pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.style.widgets

// The keyboard from above (full size, German ISO): every special key a spot
// to click, every key lighting up as it is typed, the labels glowing as
// bright as the real backlight. Sizes are in keys (u).
Item {
	id: root

	// [{ control, pos, divertable }] from the keyboard; [{ id, label, icon, codes }]
	property var controls: []
	property var keyList: []
	property string selected: ""
	property var pressed: ({})
	property var keys: ({})
	// 0…1: how bright the labels shine; flash: a level being flashed (-1 none)
	property real light: 0.4
	property real flash: -1
	property var owned: []
	property var assigned: []

	signal picked(string control)

	readonly property real u: Math.min(width / 23, height / 6.6)

	implicitWidth: 690
	implicitHeight: 200

	// the twelve F keys by the position the keyboard gives them, the rest beside
	readonly property var fkeys: {
		const out = [];
		for (let pos = 1; pos <= 12; pos += 1)
			out.push(root.controls.find(c => c.pos === pos)?.control ?? "");
		return out;
	}
	readonly property var extras: root.controls.filter(c => c.pos === 0 && c.divertable).map(c => c.control).slice(0, 7)

	function info(control) {
		return root.keyList.find(k => k.id === control) ?? null;
	}

	// [label, width, code, x?] per row; x jumps to a column
	readonly property var rows: [
		[["^", 1, 41], ["1", 1, 2], ["2", 1, 3], ["3", 1, 4], ["4", 1, 5], ["5", 1, 6], ["6", 1, 7], ["7", 1, 8], ["8", 1, 9], ["9", 1, 10], ["0", 1, 11], ["ß", 1, 12], ["´", 1, 13], ["⌫", 2, 14], ["Einfg", 1, 110, 15.5], ["Pos1", 1, 102], ["Bild↑", 1, 104], ["Num", 1, 69, 19], ["/", 1, 98], ["*", 1, 55], ["−", 1, 74]],
		[["⇥", 1.5, 15], ["Q", 1, 16], ["W", 1, 17], ["E", 1, 18], ["R", 1, 19], ["T", 1, 20], ["Z", 1, 21], ["U", 1, 22], ["I", 1, 23], ["O", 1, 24], ["P", 1, 25], ["Ü", 1, 26], ["+", 1, 27], ["↵", 1.5, 28], ["Entf", 1, 111, 15.5], ["Ende", 1, 107], ["Bild↓", 1, 109], ["7", 1, 71, 19], ["8", 1, 72], ["9", 1, 73]],
		[["⇪", 1.75, 58], ["A", 1, 30], ["S", 1, 31], ["D", 1, 32], ["F", 1, 33], ["G", 1, 34], ["H", 1, 35], ["J", 1, 36], ["K", 1, 37], ["L", 1, 38], ["Ö", 1, 39], ["Ä", 1, 40], ["#", 1, 43], ["4", 1, 75, 19], ["5", 1, 76], ["6", 1, 77]],
		[["⇧", 1.25, 42], ["<", 1, 86], ["Y", 1, 44], ["X", 1, 45], ["C", 1, 46], ["V", 1, 47], ["B", 1, 48], ["N", 1, 49], ["M", 1, 50], [",", 1, 51], [".", 1, 52], ["-", 1, 53], ["⇧", 2.75, 54], ["↑", 1, 103, 16.5], ["1", 1, 79, 19], ["2", 1, 80], ["3", 1, 81]],
		[["Strg", 1.25, 29], ["fn", 1.25, -1], ["❖", 1.25, 125], ["Alt", 1.25, 56], ["", 6.25, 57], ["AltGr", 1.25, 100], ["☰", 1.25, 127], ["Strg", 1.25, 97], ["←", 1, 105, 15.5], ["↓", 1, 108], ["→", 1, 106], ["0", 2, 82, 19], [",", 1, 83]]
	]

	readonly property var placed: {
		const out = [];
		for (let r = 0; r < root.rows.length; r += 1) {
			let x = 0;
			for (const key of root.rows[r]) {
				if (key[3] !== undefined) x = key[3];
				out.push({ label: key[0], w: key[1], code: key[2], x, y: 1.15 + r });
				x += key[1];
			}
		}
		// the tall ones
		out.push({ label: "", w: 1.25, h: 1.06, code: 28, x: 13.75, y: 3.1 });
		out.push({ label: "+", w: 1, h: 2, code: 78, x: 22, y: 2.15 });
		out.push({ label: "↵", w: 1, h: 2, code: 96, x: 22, y: 4.15 });
		return out;
	}

	readonly property real labelGlow: root.flash >= 0 ? root.flash : root.light

	// the slab
	Rectangle {
		id: slab

		anchors.centerIn: parent
		width: 23.4 * root.u
		height: 6.55 * root.u
		radius: root.u * 0.45
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

			x: root.u * 0.2
			y: root.u * 0.2
			width: 23 * root.u
			height: 6.15 * root.u

			// ── the ordinary keys ─────────────────────────────────────────
			Repeater {
				model: root.placed

				delegate: Rectangle {
					id: cap

					required property var modelData
					readonly property bool down: cap.modelData.code >= 0 && root.keys[cap.modelData.code] === true

					x: cap.modelData.x * root.u + 1.5
					y: cap.modelData.y * root.u + 1.5
					width: cap.modelData.w * root.u - 3
					height: (cap.modelData.h ?? 1) * root.u - 3
					radius: root.u * 0.16
					color: cap.down ? Theme.primary : Qt.tint(Theme.layer1, Qt.alpha(Theme.text, 0.03))
					border.width: 1
					border.color: Qt.alpha(Theme.text, cap.down ? 0 : 0.08)
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

					Text {
						anchors.centerIn: parent
						text: cap.modelData.label
						color: cap.down ? Theme.onPrimary : Qt.tint(Theme.textFaint, Qt.alpha("#fff4d6", root.labelGlow * 0.9))
						font.pixelSize: Math.max(7, root.u * (cap.modelData.label.length > 2 ? 0.26 : 0.36))
						font.family: Theme.fontFamily
						font.weight: Font.Medium

						Behavior on color {
							ColorAnim {
								duration: Motion.short
							}
						}
					}
				}
			}

			// ── the top row: Esc, the F keys, the special keys beside ─────
			Repeater {
				model: [{ control: "", label: "esc", x: 0 }].concat(root.fkeys.map((control, i) => ({ control, fn: i + 1, x: 1.25 + i * 1.08 + Math.floor(i / 4) * 0.2 }))).concat(root.extras.map((control, i) => ({ control, x: i < 3 ? 15.5 + i : 19 + (i - 3) })))

				delegate: Rectangle {
					id: special

					required property var modelData
					readonly property var meta: root.info(special.modelData.control)
					readonly property bool active: special.modelData.control !== "" && root.selected === special.modelData.control
					readonly property bool down: root.pressed[special.modelData.control] === true || (special.meta?.codes ?? []).some(c => root.keys[c] === true) || (special.modelData.fn ? root.keys[special.modelData.fn <= 10 ? 58 + special.modelData.fn : 76 + special.modelData.fn] === true : special.modelData.label === "esc" && root.keys[1] === true)
					readonly property bool ruled: root.assigned.includes(special.modelData.control)

					x: special.modelData.x * root.u + 1.5
					y: 1.5
					width: (special.modelData.fn ? 1.08 : 1) * root.u - 3
					height: 0.8 * root.u - 3
					radius: root.u * 0.14
					color: special.down ? Theme.primary : (special.active ? Theme.primaryContainer : (hover.containsMouse ? Theme.layer3 : Qt.tint(Theme.layer1, Qt.alpha(Theme.text, 0.03))))
					border.width: special.active ? 1.5 : 1
					border.color: special.active ? Theme.primary : Qt.alpha(Theme.text, 0.08)
					scale: special.down ? 0.9 : 1

					Behavior on color {
						ColorAnim {
							duration: special.down ? 40 : Motion.medium
						}
					}
					Behavior on scale {
						SpatialAnim {
							duration: Motion.short
						}
					}

					Glyph {
						anchors.centerIn: parent
						anchors.verticalCenterOffset: special.modelData.fn ? -root.u * 0.06 : 0
						visible: !!special.meta
						icon: special.meta?.icon ?? ""
						size: root.u * 0.38
						color: special.down ? Theme.onPrimary : (special.active ? Theme.primary : Qt.tint(Theme.textSubtle, Qt.alpha("#fff4d6", root.labelGlow * 0.9)))
					}

					Text {
						anchors.centerIn: parent
						visible: !special.meta
						text: special.modelData.label ?? ""
						color: Qt.tint(Theme.textFaint, Qt.alpha("#fff4d6", root.labelGlow * 0.9))
						font.pixelSize: Math.max(7, root.u * 0.26)
					}

					Text {
						anchors.right: parent.right
						anchors.bottom: parent.bottom
						anchors.margins: root.u * 0.05
						visible: !!special.modelData.fn
						text: `F${special.modelData.fn}`
						color: special.down ? Theme.onPrimary : Theme.textFaint
						font.pixelSize: Math.max(6, root.u * 0.17)
					}

					// a rule on it, or Solaar's
					Rectangle {
						anchors.top: parent.top
						anchors.right: parent.right
						anchors.margins: root.u * 0.07
						width: root.u * 0.12
						height: width
						radius: width / 2
						visible: special.ruled || root.owned.includes(special.modelData.control)
						color: special.ruled ? Theme.primary : Theme.warning
					}

					MouseArea {
						id: hover

						anchors.fill: parent
						hoverEnabled: true
						enabled: !!special.meta
						cursorShape: Qt.PointingHandCursor
						onClicked: root.picked(special.modelData.control)
					}
				}
			}
		}
	}
}
