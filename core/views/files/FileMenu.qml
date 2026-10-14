pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import qs.style.theme
import qs.style.widgets
import qs.core.services

// The file manager's menus: right clicks, view options, "Open with". It
// blooms from where it was asked for; entries with `children` open a
// further panel beside it. The keyboard walks it (arrows, Enter, Escape).
//
// An entry: { label, icon, run, checked, shortcut, children, danger,
// enabled, hint } or { separator: true } or { header: "…" }; children may
// be a function that returns the entries (or calls back later with them).
Item {
	id: root

	// [{ entries, x, y, originX, originY }] – the open panels, the first is the menu
	property var levels: []
	// the entry under the pointer or the keyboard, per panel
	property var currents: []
	readonly property bool open: root.levels.length > 0
	signal closed

	// the panels as a model that only grows and shrinks, so a panel that
	// stays is not drawn again
	ListModel {
		id: panelModel
	}

	function setLevels(next) {
		root.levels = next;
		while (panelModel.count > next.length) panelModel.remove(panelModel.count - 1, 1);
		while (panelModel.count < next.length) panelModel.append({ level: panelModel.count });
		root.currents = next.map((level, i) => root.currents[i] ?? -1);
	}

	// a menu taller than the window scrolls
	function fit(h) {
		return Math.min(h, Math.max(80, root.height - 16));
	}

	function show(entries, x, y) {
		const clean = root.clean(entries);
		if (clean.length === 0) return;
		const size = root.measure(clean);
		size.h = root.fit(size.h);
		root.setLevels([]);
		root.setLevels([{ entries: clean, x: Math.max(8, Math.min(root.width - size.w - 8, x)), y: Math.max(8, Math.min(root.height - size.h - 8, y)), originX: x, originY: y }]);
		Sounds.play("open");
		keys.forceActiveFocus();
	}

	function close() {
		if (!root.open) return;
		root.setLevels([]);
		root.closed();
	}

	function clean(entries) {
		const out = [];
		for (const entry of entries || []) {
			if (!entry || entry.shown === false) continue;
			if (entry.separator && (out.length === 0 || out[out.length - 1].separator)) continue;
			out.push(entry);
		}
		while (out.length > 0 && out[out.length - 1].separator) out.pop();
		// a header with nothing under it goes
		return out.filter((entry, i) => !entry.header || (out[i + 1] && !out[i + 1].header && !out[i + 1].separator));
	}

	function measure(entries) {
		let h = 12;
		let longest = 0;
		for (const entry of entries) {
			h += entry.separator ? 9 : (entry.header ? 26 : 32);
			longest = Math.max(longest, String(entry.label || entry.header || "").length + String(entry.shortcut || "").length * 0.8);
		}
		return { w: Math.max(200, Math.min(320, 92 + longest * 7)), h: h };
	}

	function openChild(level, index) {
		const entry = root.levels[level].entries[index];
		if (!entry?.children) return;
		const place = (entries) => {
			const clean = root.clean(entries);
			if (clean.length === 0) return;
			const parent = root.levels[level];
			const parentSize = root.measure(parent.entries);
			const size = root.measure(clean);
			size.h = root.fit(size.h);
			// where the entry is now, the panel's scroll taken off
			const y = parent.y + 6 + root.offsetOf(parent.entries, index) - (panels.itemAt(level)?.scroll ?? 0);
			let x = parent.x + parentSize.w - 4;
			if (x + size.w > root.width - 8) x = parent.x - size.w + 4;
			const next = root.levels.slice(0, level + 1);
			next.push({ entries: clean, x: Math.max(8, x), y: Math.max(8, Math.min(root.height - size.h - 8, y - 6)), originX: x, originY: y });
			root.setLevels(next);
		};
		if (typeof entry.children === "function") {
			const result = entry.children(place);
			if (Array.isArray(result)) place(result);
		} else {
			place(entry.children);
		}
	}

	function offsetOf(entries, index) {
		let y = 0;
		for (let i = 0; i < index; i += 1) y += entries[i].separator ? 9 : (entries[i].header ? 26 : 32);
		return y;
	}

	function activate(level, index) {
		const entry = root.levels[level]?.entries[index];
		if (!entry || entry.separator || entry.header || entry.enabled === false) return;
		if (entry.children) {
			root.openChild(level, index);
			root.setCurrent(level + 1, 0);
			return;
		}
		root.close();
		Sounds.play("click");
		if (typeof entry.run === "function") entry.run();
	}

	function setCurrent(level, index) {
		if (!root.levels[level]) return;
		const next = root.currents.slice();
		next[level] = index;
		root.currents = next;
	}

	function usable(entry) {
		return entry && !entry.separator && !entry.header && entry.enabled !== false;
	}

	function walk(delta) {
		const level = root.levels.length - 1;
		const panel = root.levels[level];
		const count = panel.entries.length;
		let index = root.currents[level] ?? -1;
		for (let n = 0; n < count; n += 1) {
			index = (index + delta + count) % count;
			if (root.usable(panel.entries[index])) break;
		}
		root.setCurrent(level, index);
	}

	visible: root.open

	// a click beside the menu closes it
	MouseArea {
		anchors.fill: parent
		acceptedButtons: Qt.AllButtons
		// the files behind do not light up under it
		hoverEnabled: true
		onPressed: root.close()
		onWheel: root.close()
	}

	Item {
		id: keys

		focus: root.open
		Keys.onPressed: event => {
			const level = root.levels.length - 1;
			if (level < 0) return;
			switch (event.key) {
			case Qt.Key_Escape:
				if (level > 0) root.setLevels(root.levels.slice(0, level));
				else root.close();
				break;
			case Qt.Key_Down:
				root.walk(1);
				break;
			case Qt.Key_Up:
				root.walk(-1);
				break;
			case Qt.Key_Right:
				if (root.levels[level].entries[root.currents[level]]?.children) root.activate(level, root.currents[level]);
				break;
			case Qt.Key_Left:
				if (level > 0) root.setLevels(root.levels.slice(0, level));
				break;
			case Qt.Key_Return:
			case Qt.Key_Enter:
			case Qt.Key_Space:
				root.activate(level, root.currents[level]);
				break;
			default:
				return;
			}
			event.accepted = true;
		}
	}

	Repeater {
		id: panels

		model: panelModel

		delegate: Rectangle {
			id: panel

			required property int level
			readonly property int index: panel.level
			readonly property var modelData: root.levels[panel.level] ?? { entries: [], x: 0, y: 0, originX: 0, originY: 0 }
			readonly property var entries: panel.modelData.entries
			readonly property var size: root.measure(panel.entries)
			readonly property real scroll: list.contentY
			readonly property int current: root.currents[panel.level] ?? -1

			// the keyboard's entry stays in sight
			onCurrentChanged: {
				if (panel.current < 0 || list.contentHeight <= list.height) return;
				const top = root.offsetOf(panel.entries, panel.current);
				if (top < list.contentY) list.contentY = top;
				else if (top + 32 > list.contentY + list.height) list.contentY = top + 32 - list.height;
			}

			x: panel.modelData.x
			y: panel.modelData.y
			width: panel.size.w
			height: root.fit(panel.size.h)
			clip: true
			radius: Theme.radius.large
			color: Theme.layer2
			border.width: 1
			border.color: Theme.outline
			transformOrigin: panel.modelData.originY > panel.modelData.y + panel.height / 2 ? Item.Bottom : Item.TopLeft

			Component.onCompleted: bloom.start()

			// the panel blooms from the pointer
			ParallelAnimation {
				id: bloom

				NumberAnimation {
					target: panel
					property: "scale"
					from: 0.86
					to: 1
					duration: Motion.medium
					easing.type: Easing.BezierSpline
					easing.bezierCurve: Motion.spatialFast
				}
				NumberAnimation {
					target: panel
					property: "opacity"
					from: 0
					to: 1
					duration: Motion.short
				}
			}

			// a shadow to lift it off the files
			Rectangle {
				z: -1
				anchors.fill: parent
				anchors.margins: -1
				anchors.topMargin: 4
				anchors.bottomMargin: -10
				radius: parent.radius + 3
				color: Theme.shadow
				opacity: 0.35
			}

			MouseArea {
				anchors.fill: parent
				hoverEnabled: true
				// the wheel at the list's end stays here, it does not close the menu
				onWheel: wheel => wheel.accepted = true
			}

			Flickable {
				id: list

				anchors.fill: parent
				anchors.margins: 6
				contentHeight: rows.implicitHeight
				interactive: list.contentHeight > list.height
				boundsBehavior: Flickable.StopAtBounds
				clip: true
				// what opened beside a panel stays with its entry: it closes when the panel scrolls
				onMovementStarted: if (root.levels.length > panel.index + 1) root.setLevels(root.levels.slice(0, panel.index + 1))

				// a menu that goes on below shows that it does
				ScrollBar.vertical: ThinScrollBar {
					active: list.interactive
				}

			Column {
				id: rows

				width: list.width

				Repeater {
					model: panel.entries

					delegate: Item {
						id: row

						required property var modelData
						required property int index
						readonly property bool current: root.currents[panel.index] === row.index
						readonly property bool usable: root.usable(row.modelData)

						width: parent.width
						height: row.modelData.separator ? 9 : (row.modelData.header ? 26 : 32)

						Rectangle {
							visible: !!row.modelData.separator
							anchors.verticalCenter: parent.verticalCenter
							x: 8
							width: parent.width - 16
							height: 1
							color: Theme.outline
						}

						Text {
							visible: !!row.modelData.header
							anchors.left: parent.left
							anchors.leftMargin: 10
							anchors.bottom: parent.bottom
							anchors.bottomMargin: 5
							text: String(row.modelData.header || "").toUpperCase()
							color: Theme.textSubtle
							font.family: Theme.fontFamily
							font.pixelSize: Theme.size.tiny
							font.weight: Font.Bold
							font.letterSpacing: 0.8
						}

						Rectangle {
							visible: !row.modelData.separator && !row.modelData.header
							anchors.fill: parent
							radius: Theme.radius.small
							color: row.current && row.usable ? (row.modelData.danger ? Qt.alpha(Theme.danger, 0.16) : Theme.primarySoft) : "transparent"
							opacity: row.usable ? 1 : 0.4

							Behavior on color {
								ColorAnim {
									duration: Motion.micro
								}
							}

							Glyph {
								id: rowIcon

								x: 10
								anchors.verticalCenter: parent.verticalCenter
								icon: row.modelData.checked === true ? "check" : String(row.modelData.icon || "")
								visible: icon !== ""
								size: 16
								color: row.modelData.danger ? Theme.danger : (row.modelData.checked === true ? Theme.primary : Theme.textMuted)
								animated: false
							}

							// an app's own icon
							Image {
								visible: !!row.modelData.image
								x: 9
								anchors.verticalCenter: parent.verticalCenter
								width: 18
								height: 18
								source: row.modelData.image || ""
								sourceSize: Qt.size(36, 36)
								asynchronous: true
							}

							Text {
								anchors.left: parent.left
								anchors.leftMargin: 36
								anchors.right: tail.left
								anchors.rightMargin: 8
								anchors.verticalCenter: parent.verticalCenter
								text: String(row.modelData.label || "")
								color: row.modelData.danger ? Theme.danger : Theme.text
								font.family: Theme.fontFamily
								font.pixelSize: Theme.size.body
								elide: Text.ElideRight
							}

							Item {
								id: tail

								anchors.right: parent.right
								anchors.rightMargin: 10
								anchors.verticalCenter: parent.verticalCenter
								width: row.modelData.children ? 14 : shortcut.implicitWidth
								height: 16

								Text {
									id: shortcut

									visible: !row.modelData.children
									anchors.right: parent.right
									anchors.verticalCenter: parent.verticalCenter
									text: String(row.modelData.shortcut || row.modelData.hint || "")
									color: Theme.textSubtle
									font.family: Theme.fontFamily
									font.pixelSize: Theme.size.small
								}

								Glyph {
									visible: !!row.modelData.children
									anchors.centerIn: parent
									icon: "chevron_right"
									size: 15
									color: Theme.textSubtle
									animated: false
								}
							}

							MouseArea {
								anchors.fill: parent
								hoverEnabled: true
								enabled: row.usable
								cursorShape: Qt.PointingHandCursor
								onEntered: {
									root.setCurrent(panel.index, row.index);
									if (root.levels.length > panel.index + 1 && !row.modelData.children) root.setLevels(root.levels.slice(0, panel.index + 1));
									if (row.modelData.children) childTimer.restart();
									else childTimer.stop();
								}
								onExited: childTimer.stop()
								onClicked: root.activate(panel.index, row.index)
							}

							Timer {
								id: childTimer

								interval: 180
								onTriggered: root.openChild(panel.index, row.index)
							}
						}
					}
				}
			}
			}
		}
	}
}
