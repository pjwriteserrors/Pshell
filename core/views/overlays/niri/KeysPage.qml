pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.style.theme
import qs.style.widgets
import qs.core.services
import qs.core.views.overlays.keybinds

// Key binds (core/services/Keybinds.qml, keybinds.kdl): the binds in the
// middle, the one being changed on the right. Typing filters, ↑↓ move, Enter
// opens and Enter again records new keys, Ctrl+N makes a new one; while keys
// are recorded niri passes its own shortcuts through. "Lid & tablet" holds
// the switch events (settings.kdl).
Item {
	id: root

	property bool active: false
	readonly property bool recording: editor.recording

	// "" every bind, a category id, "off", or "switches"
	property string category: ""
	property int selectedUid: 0
	property bool editing: false
	readonly property string query: search.text.trim().toLowerCase()

	onActiveChanged: if (root.active) Qt.callLater(() => search.focusInput())

	function reveal(anchor) {
		root.category = anchor === "switches" ? "switches" : "";
	}

	function matches(bind) {
		if (root.category === "off" && !bind.disabled) return false;
		if (root.category !== "" && root.category !== "off" && Keybinds.category(bind) !== root.category) return false;
		if (root.query === "") return true;
		const hay = `${Keybinds.keyText(bind.key)} ${bind.key} ${Keybinds.title(bind)} ${Keybinds.detail(bind)} ${bind.action}`.toLowerCase();
		return root.query.split(/\s+/).every(word => hay.includes(word));
	}

	readonly property var rows: {
		const out = [];
		for (const entry of Keybinds.categories) {
			const binds = Keybinds.binds.filter(bind => Keybinds.category(bind) === entry.id && root.matches(bind));
			if (binds.length === 0) continue;
			if (root.category === "" || root.category === "off") out.push({ id: `h:${entry.id}`, header: true, name: entry.label, uid: 0 });
			binds.filter(bind => !bind.disabled).concat(binds.filter(bind => bind.disabled))
				.forEach(bind => out.push({ id: `b:${bind.uid}`, header: false, name: "", uid: bind.uid }));
		}
		return out;
	}

	function count(id) {
		if (id === "") return Keybinds.binds.length;
		if (id === "off") return Keybinds.binds.filter(bind => bind.disabled).length;
		if (id === "switches") return 4;
		return Keybinds.binds.filter(bind => Keybinds.category(bind) === id).length;
	}

	onRowsChanged: root.sync()
	function sync() {
		const wanted = root.rows;
		const ids = new Set(wanted.map(row => row.id));
		for (let i = model.count - 1; i >= 0; i--)
			if (!ids.has(model.get(i).rowId)) model.remove(i);
		for (let i = 0; i < wanted.length; i++) {
			const row = wanted[i];
			if (i < model.count && model.get(i).rowId === row.id) continue;
			let from = -1;
			for (let j = i + 1; j < model.count; j++) {
				if (model.get(j).rowId === row.id) {
					from = j;
					break;
				}
			}
			if (from >= 0) model.move(from, i, 1);
			else model.insert(i, { rowId: row.id, header: row.header, name: row.name, uid: row.uid });
		}
	}

	readonly property int current: {
		const index = root.rows.findIndex(row => row.uid === root.selectedUid && !row.header);
		return index >= 0 ? index : -1;
	}

	function move(delta) {
		let index = root.current < 0 ? (delta > 0 ? -1 : root.rows.length) : root.current;
		index += delta;
		while (index >= 0 && index < root.rows.length && root.rows[index].header) index += delta;
		if (index >= 0 && index < root.rows.length) {
			root.selectedUid = root.rows[index].uid;
			list.positionViewAtIndex(index, ListView.Contain);
			if (root.editing) root.open(root.selectedUid);
		}
	}

	function open(uid) {
		const bind = Keybinds.byUid(uid);
		if (!bind) return;
		if (root.editing && editor.draft.uid === uid && !editor.recording) {
			editor.record();
			return;
		}
		root.selectedUid = uid;
		root.editing = true;
		editor.edit(bind);
	}

	function showBind(uid) {
		search.text = "";
		root.category = "";
		root.editing = false;
		root.open(uid);
		Qt.callLater(() => list.positionViewAtIndex(root.current, ListView.Center));
	}

	function create() {
		root.selectedUid = 0;
		root.editing = true;
		editor.create();
	}

	function closeEditor() {
		root.editing = false;
		search.focusInput();
	}

	ListModel {
		id: model
	}

	Keys.onPressed: event => {
		if (event.key === Qt.Key_N && (event.modifiers & Qt.ControlModifier)) {
			root.create();
			event.accepted = true;
		}
	}

	ColumnLayout {
		anchors.fill: parent
		anchors.margins: 30
		anchors.topMargin: 30
		spacing: 16

		RowLayout {
			Layout.fillWidth: true
			spacing: 16

			ColumnLayout {
				Layout.fillWidth: true
				spacing: 4

				StyledText {
					text: "Key binds"
					font.pixelSize: 26
					font.weight: Font.Bold
				}

				StyledText {
					Layout.fillWidth: true
					text: Keybinds.loading && !Keybinds.loaded ? "Reading niri…" : `${Keybinds.binds.filter(bind => !bind.disabled).length} binds live in niri – keys are recorded as you press them, mouse wheel and side buttons too.`
					tone: Theme.textMuted
				}
			}

			TextButton {
				implicitHeight: 40
				variant: "ghost"
				icon: "eye_outline"
				text: "niri's overlay"
				onActivated: {
					Popups.closeModal();
					Quickshell.execDetached(["sh", "-c", "sleep 0.35; niri msg action show-hotkey-overlay"]);
				}
			}
		}

		// the kinds, as chips
		Flow {
			Layout.fillWidth: true
			spacing: 6

			Repeater {
				model: [{ id: "", label: "All", icon: "keyboard" }].concat(Keybinds.categories, [{ id: "off", label: "Switched off", icon: "eye_off" }, { id: "switches", label: "Lid & tablet", icon: "laptop" }])

				delegate: Chip {
					id: kind

					required property var modelData
					readonly property int amount: root.count(kind.modelData.id)

					visible: kind.amount > 0 || kind.modelData.id === ""
					text: kind.modelData.id === "switches" ? kind.modelData.label : `${kind.modelData.label}  ${kind.amount}`
					icon: kind.modelData.icon
					selected: root.category === kind.modelData.id
					onClicked: {
						root.category = kind.modelData.id;
						if (kind.modelData.id === "switches") root.editing = false;
					}
				}
			}
		}

		Item {
			Layout.fillWidth: true
			Layout.fillHeight: true

			// ── the binds and the editor ───────────────────────────────
			RowLayout {
				anchors.fill: parent
				spacing: 18
				opacity: root.category === "switches" ? 0 : 1
				visible: opacity > 0.01
				enabled: root.category !== "switches"

				Behavior on opacity {
					Anim {}
				}

				ColumnLayout {
					Layout.fillWidth: true
					Layout.fillHeight: true
					spacing: 12

					Keys.onEscapePressed: event => {
						event.accepted = root.editing;
						if (root.editing) root.closeEditor();
					}

					RowLayout {
						Layout.fillWidth: true
						spacing: 10

						Field {
							id: search

							Layout.fillWidth: true
							icon: "magnify"
							placeholder: "Search keys and what they do"
							onEdited: if (root.current < 0 && root.rows.length > 0) root.selectedUid = root.rows.find(row => !row.header)?.uid ?? 0
							onUpPressed: root.move(-1)
							onDownPressed: root.move(1)
							onAccepted: if (root.selectedUid) root.open(root.selectedUid)
						}

						TextButton {
							implicitHeight: 40
							variant: "filled"
							icon: "plus"
							text: "New bind"
							onActivated: root.create()
						}
					}

					ListView {
						id: list

						Layout.fillWidth: true
						Layout.fillHeight: true
						clip: true
						model: model
						currentIndex: root.current
						spacing: 2
						boundsBehavior: Flickable.StopAtBounds
						highlightFollowsCurrentItem: false
						ScrollBar.vertical: ThinScrollBar {}

						add: Transition {
							ParallelAnimation {
								NumberAnimation {
									property: "opacity"
									from: 0
									to: 1
									duration: Motion.medium
									easing.type: Easing.OutCubic
								}
								NumberAnimation {
									property: "x"
									from: 18
									to: 0
									duration: Motion.long
									easing.type: Easing.BezierSpline
									easing.bezierCurve: Motion.spatial
								}
							}
						}
						remove: Transition {
							ParallelAnimation {
								NumberAnimation {
									property: "opacity"
									to: 0
									duration: Motion.short
								}
								NumberAnimation {
									property: "x"
									to: -14
									duration: Motion.short
									easing.type: Easing.BezierSpline
									easing.bezierCurve: Motion.accel
								}
							}
						}
						displaced: Transition {
							NumberAnimation {
								properties: "x,y"
								duration: Motion.long
								easing.type: Easing.BezierSpline
								easing.bezierCurve: Motion.spatial
							}
							NumberAnimation {
								property: "opacity"
								to: 1
								duration: Motion.short
							}
						}
						move: Transition {
							NumberAnimation {
								properties: "x,y"
								duration: Motion.long
								easing.type: Easing.BezierSpline
								easing.bezierCurve: Motion.spatial
							}
						}

						delegate: Item {
							id: row

							required property string rowId
							required property bool header
							required property string name
							required property int uid
							required property int index
							readonly property var bind: row.header ? null : Keybinds.byUid(row.uid)

							width: list.width - 12
							height: row.header ? 36 : 54

							SectionLabel {
								anchors.left: parent.left
								anchors.leftMargin: 12
								anchors.bottom: parent.bottom
								anchors.bottomMargin: 8
								visible: row.header
								text: row.name
							}

							BindRow {
								anchors.fill: parent
								visible: !row.header && !!row.bind
								bind: row.bind
								selected: root.selectedUid === row.uid && (root.editing || search.focused)
								onClicked: root.open(row.uid)
								onToggled: on => Keybinds.setDisabled(row.uid, !on)
							}
						}

						EmptyState {
							anchors.centerIn: parent
							visible: list.count === 0 && Keybinds.loaded
							icon: root.query !== "" ? "magnify" : "keyboard"
							title: root.query !== "" ? "No bind fits" : "No binds yet"
							subtitle: root.query !== "" ? "Try a key (super d) or what it does" : "Make the first one with New bind"
						}

						Spinner {
							anchors.centerIn: parent
							width: 26
							height: 26
							visible: Keybinds.loading && !Keybinds.loaded
						}
					}
				}

				Item {
					Layout.preferredWidth: Math.round(Math.max(340, Math.min(440, root.width * 0.38)))
					Layout.fillHeight: true

					BindEditor {
						id: editor

						anchors.fill: parent
						visible: opacity > 0.01
						opacity: root.editing ? 1 : 0
						focus: root.editing
						onDone: root.closeEditor()
						onShowBind: uid => root.showBind(uid)

						Behavior on opacity {
							Anim {}
						}
					}

					Rectangle {
						anchors.fill: parent
						radius: Theme.radius.large
						color: Theme.layer1
						visible: opacity > 0.01
						opacity: root.editing ? 0 : 1

						Behavior on opacity {
							Anim {}
						}

						ColumnLayout {
							anchors.centerIn: parent
							width: parent.width - 64
							spacing: 22

							KeyCombo {
								id: demo

								property int step: 0
								readonly property var samples: ["Mod+D", "Mod+Shift+S", "Ctrl+Alt+Delete", "Mod+WheelScrollDown", "XF86AudioRaiseVolume"]

								Layout.alignment: Qt.AlignHCenter
								key: demo.samples[demo.step % demo.samples.length]
								size: 38
								animated: true

								Timer {
									interval: 2400
									repeat: true
									running: root.active && !root.editing
									onTriggered: demo.step += 1
								}
							}

							ColumnLayout {
								Layout.fillWidth: true
								spacing: 14

								Repeater {
									model: [
										{ icon: "gesture_tap", text: "Click a bind to change it – or find it by typing, Enter opens it and Enter again records new keys" },
										{ icon: "record", text: "Keys are recorded as you press them, the wheel and side buttons too" },
										{ icon: "swap_horizontal", text: "A key that is taken shows by what – swap the two with a click" },
										{ icon: "plus", text: "Ctrl+N makes a new bind, Ctrl+S saves it" }
									]

									delegate: RowLayout {
										id: tip

										required property var modelData

										Layout.fillWidth: true
										spacing: 12

										Rectangle {
											Layout.preferredWidth: 30
											Layout.preferredHeight: 30
											radius: Theme.radius.medium
											color: Theme.layer2

											Glyph {
												anchors.centerIn: parent
												icon: tip.modelData.icon
												size: 15
												color: Theme.primary
											}
										}

										StyledText {
											Layout.fillWidth: true
											text: tip.modelData.text
											tone: Theme.textMuted
											wrapMode: Text.WordWrap
										}
									}
								}
							}
						}
					}
				}
			}

			// ── lid and tablet mode ────────────────────────────────────
			Flickable {
				anchors.fill: parent
				contentHeight: switches.implicitHeight
				clip: true
				opacity: root.category === "switches" ? 1 : 0
				visible: opacity > 0.01
				boundsBehavior: Flickable.StopAtBounds
				transform: Translate {
					y: root.category === "switches" ? 0 : 24

					Behavior on y {
						SpatialAnim {}
					}
				}

				Behavior on opacity {
					Anim {}
				}

				SwitchEvents {
					id: switches

					width: parent.width
					active: root.active && root.category === "switches"
				}
			}
		}
	}
}
