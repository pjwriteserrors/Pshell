pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// One bind, being changed: its keys (recorded), what it does (picked), its
// name in niri's hotkey overlay and how it behaves. Nothing is written until
// Save (Ctrl+S); a key another bind already has is shown with the way out –
// swap the two, or switch the other one off.
Item {
	id: root

	// a copy of the bind; `original` is null for a new one
	property var draft: ({})
	property var original: null
	readonly property bool isNew: root.original === null
	readonly property bool recording: recorder.recording
	readonly property bool picking: root.pickerOpen
	property bool pickerOpen: false

	readonly property var clash: root.draft.disabled ? null : Keybinds.conflict(root.draft.key, root.draft.uid)
	readonly property bool valid: String(root.draft.key || "") !== "" && String(root.draft.action || "") !== "" && !root.clash
	readonly property bool dirty: root.isNew || JSON.stringify(Keybinds.strip([root.draft])) !== JSON.stringify(Keybinds.strip([root.original]))
	readonly property var meta: root.kind === "niri" ? (Keybinds.niriActions.find(action => action.name === root.draft.action) ?? null) : null
	readonly property string kind: Keybinds.kind(root.draft)

	signal done
	// the bind in the way should be shown
	signal showBind(int uid)

	function record() {
		root.pickerOpen = false;
		recorder.start();
	}

	function edit(bind) {
		root.pickerOpen = false;
		recorder.stop();
		root.original = bind;
		root.draft = JSON.parse(JSON.stringify(bind));
		flick.contentY = 0;
		reveal.restart();
	}

	function create() {
		root.original = null;
		root.draft = { uid: 0, key: "", props: {}, action: "", args: [], aprops: {}, disabled: false };
		root.pickerOpen = false;
		flick.contentY = 0;
		reveal.restart();
		Qt.callLater(recorder.start);
	}

	function set(field, value) {
		const next = Object.assign({}, root.draft);
		next[field] = value;
		root.draft = next;
	}

	function setProp(name, value) {
		const props = Object.assign({}, root.draft.props || {});
		if (value === undefined) delete props[name];
		else props[name] = value;
		root.set("props", props);
	}

	function setAprop(name, value) {
		const aprops = Object.assign({}, root.draft.aprops || {});
		if (value === undefined) delete aprops[name];
		else aprops[name] = value;
		root.set("aprops", aprops);
	}

	function setArg(index, value) {
		const args = (root.draft.args || []).slice();
		while (args.length <= index) args.push("");
		args[index] = value;
		root.set("args", args);
	}

	// a workspace by number stays a number, "-10%" stays text
	function typed(arg, text) {
		if (/^(reference|index|id)$/.test(arg.name) && /^\d+$/.test(text)) return Number(text);
		return text;
	}

	// "a 'b c' d" → ["a", "b c", "d"]
	function words(text) {
		const out = [];
		const pattern = /"((?:[^"\\]|\\.)*)"|'([^']*)'|(\S+)/g;
		let match;
		while ((match = pattern.exec(text)) !== null) out.push(match[1] !== undefined ? match[1].replace(/\\(.)/g, "$1") : match[2] !== undefined ? match[2] : match[3]);
		return out;
	}

	function quoted(args) {
		return (args || []).map(arg => /[\s"']/.test(String(arg)) || String(arg) === "" ? `"${String(arg).replace(/(["\\])/g, "\\$1")}"` : String(arg)).join(" ");
	}

	function save() {
		if (!root.valid || !root.dirty || Keybinds.saving) return;
		Keybinds.upsert(root.draft);
		root.done();
	}

	// the bind in the way takes this one's old key
	function swap() {
		const other = root.clash;
		if (!other || root.isNew) return;
		Keybinds.commitMany([root.draft, Object.assign({}, other, { key: root.original.key })],
			`${Keybinds.keyText(root.draft.key)} and ${Keybinds.keyText(root.original.key)} swapped`);
		root.done();
	}

	function turnOffOther() {
		const other = root.clash;
		if (!other) return;
		const mine = Object.assign({}, root.draft);
		if (!mine.uid) mine.uid = Keybinds.nextUid++;
		Keybinds.commitMany([mine, Object.assign({}, other, { disabled: true })],
			`${Keybinds.keyText(mine.key)} saved, “${Keybinds.title(other)}” switched off`);
		root.done();
	}

	Keys.onPressed: event => {
		if (event.key === Qt.Key_S && (event.modifiers & Qt.ControlModifier)) {
			root.save();
			event.accepted = true;
		} else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && !root.recording && !root.pickerOpen) {
			// Enter records new keys
			root.record();
			event.accepted = true;
		}
	}
	Keys.onEscapePressed: event => {
		event.accepted = true;
		if (root.pickerOpen) root.pickerOpen = false;
		else root.done();
	}

	ParallelAnimation {
		id: reveal

		NumberAnimation {
			target: body
			property: "opacity"
			from: 0
			to: 1
			duration: Motion.medium
			easing.type: Easing.OutCubic
		}
		NumberAnimation {
			target: lift
			property: "y"
			from: 18
			to: 0
			duration: Motion.long
			easing.type: Easing.BezierSpline
			easing.bezierCurve: Motion.spatial
		}
	}

	Rectangle {
		id: body

		anchors.fill: parent
		radius: Theme.radius.large
		color: Theme.base
		border.width: 1
		border.color: Theme.outline
		transform: Translate {
			id: lift
		}

		// the editor steps back while the picker is over it
		Item {
			id: page

			anchors.fill: parent
			opacity: root.pickerOpen ? 0 : 1
			scale: root.pickerOpen ? 0.96 : 1
			enabled: !root.pickerOpen

			Behavior on opacity {
				Anim {}
			}
			Behavior on scale {
				SpatialAnim {}
			}

			ColumnLayout {
				anchors.fill: parent
				anchors.margins: 16
				spacing: 12

				RowLayout {
					Layout.fillWidth: true
					spacing: 8

					ColumnLayout {
						Layout.fillWidth: true
						spacing: 1

						SectionLabel {
							text: root.isNew ? "New bind" : Keybinds.category(root.original)
						}

						StyledText {
							Layout.fillWidth: true
							text: root.draft.action ? Keybinds.title(root.draft) : "Something new"
							font.pixelSize: Theme.size.heading
							font.weight: Font.Bold
						}
					}

					IconButton {
						icon: "close"
						onClicked: root.done()
					}
				}

				Flickable {
					id: flick

					Layout.fillWidth: true
					Layout.fillHeight: true
					clip: true
					contentHeight: column.implicitHeight
					boundsBehavior: Flickable.StopAtBounds
					ScrollBar.vertical: ThinScrollBar {}

					ColumnLayout {
						id: column

						width: flick.width
						spacing: 14

						KeyRecorder {
							id: recorder

							Layout.fillWidth: true
							key: String(root.draft.key || "")
							// the keyboard comes back to the editor (Enter, Ctrl+S, Escape)
							onRecordingChanged: if (!recording && !root.pickerOpen) root.forceActiveFocus()
							onRecorded: key => {
								root.set("key", key);
								// a new bind on a free key goes on to what it does
								if (root.isNew && !root.draft.action && !Keybinds.conflict(key, root.draft.uid)) Qt.callLater(() => {
									root.pickerOpen = true;
									picker.open();
								});
							}
						}

						// the key is taken
						Rectangle {
							Layout.fillWidth: true
							Layout.preferredHeight: root.clash ? clashRow.implicitHeight + 20 : 0
							radius: Theme.radius.medium
							color: Qt.alpha(Theme.warning, 0.14)
							clip: true
							opacity: root.clash ? 1 : 0

							Behavior on Layout.preferredHeight {
								SpatialAnim {
									duration: Motion.medium
								}
							}
							Behavior on opacity {
								Anim {}
							}

							ColumnLayout {
								id: clashRow

								anchors.left: parent.left
								anchors.right: parent.right
								anchors.top: parent.top
								anchors.margins: 10
								spacing: 8

								RowLayout {
									Layout.fillWidth: true
									spacing: 8

									Glyph {
										icon: "alert"
										size: 16
										color: Theme.warning
									}

									StyledText {
										Layout.fillWidth: true
										text: root.clash ? `Already does “${Keybinds.title(root.clash)}”` : ""
										tone: Theme.warning
										font.weight: Font.DemiBold
										wrapMode: Text.WordWrap
									}
								}

								RowLayout {
									spacing: 6

									TextButton {
										visible: !root.isNew && String(root.original?.key || "") !== ""
										implicitHeight: 28
										icon: "swap_horizontal"
										text: "Swap keys"
										onActivated: root.swap()
									}

									TextButton {
										implicitHeight: 28
										variant: "ghost"
										icon: "arrow_right"
										text: "Show it"
										onActivated: root.showBind(root.clash.uid)
									}

									TextButton {
										implicitHeight: 28
										icon: "eye_off"
										text: "Switch it off"
										enabled: String(root.draft.action || "") !== ""
										onActivated: root.turnOffOther()
									}
								}
							}
						}

						SectionLabel {
							text: "Does"
						}

						// what it does: a click opens the picker
						Clickable {
							Layout.fillWidth: true
							implicitHeight: 64
							radius: Theme.radius.large
							pressedScale: 0.98
							color: root.draft.action ? Theme.layer2 : Theme.primaryContainer
							onClicked: {
								root.pickerOpen = true;
								picker.open();
							}

							RowLayout {
								anchors.fill: parent
								anchors.leftMargin: 12
								anchors.rightMargin: 12
								spacing: 12

								Rectangle {
									Layout.preferredWidth: 40
									Layout.preferredHeight: 40
									radius: Theme.radius.medium
									color: root.draft.action ? Theme.layer3 : Theme.primary

									Image {
										id: appIcon

										readonly property var app: Keybinds.app(root.draft)

										anchors.centerIn: parent
										width: 28
										height: 28
										visible: status === Image.Ready
										source: appIcon.app ? AppIcons.app(appIcon.app.icon, [appIcon.app.id]) : ""
										sourceSize: Qt.size(56, 56)
										asynchronous: true
										mipmap: true
									}

									Glyph {
										anchors.centerIn: parent
										visible: !appIcon.visible
										icon: root.draft.action ? (root.kind === "command" ? "console" : Keybinds.categoryIcon(Keybinds.category(root.draft))) : "plus"
										size: 19
										color: root.draft.action ? Theme.text : Theme.onPrimary
									}
								}

								ColumnLayout {
									Layout.fillWidth: true
									spacing: 1

									StyledText {
										Layout.fillWidth: true
										text: root.draft.action ? Keybinds.actionTitle(root.draft) : "Choose what it does"
										font.weight: Font.DemiBold
									}

									StyledText {
										Layout.fillWidth: true
										text: root.draft.action ? (root.meta?.description || Keybinds.detail(root.draft)) : "A shell action, an app, a command or a niri action"
										tone: Theme.textSubtle
										font.pixelSize: Theme.size.small
									}
								}

								IconButton {
									visible: !!root.draft.action
									icon: "play"
									variant: "tonal"
									implicitWidth: 30
									implicitHeight: 30
									onClicked: Keybinds.run(root.draft)
								}

								Glyph {
									icon: "chevron_right"
									size: 18
									color: Theme.textMuted
								}
							}
						}

						// a command line
						Field {
							Layout.fillWidth: true
							visible: root.draft.action === "spawn-sh"
							icon: "console"
							placeholder: "Command"
							input.font.family: Theme.monoFamily
							text: root.draft.action === "spawn-sh" ? String(root.draft.args?.[0] ?? "") : ""
							onEdited: text => root.set("args", [text])
						}

						// a program with its arguments; what is typed stays as typed
						Field {
							id: program

							Layout.fillWidth: true
							visible: root.draft.action === "spawn" && root.kind === "command"
							icon: "console"
							placeholder: "Program and arguments"
							input.font.family: Theme.monoFamily
							onEdited: text => root.set("args", root.words(text))

							Binding {
								target: program
								property: "text"
								value: root.draft.action === "spawn" ? root.quoted(root.draft.args) : ""
								when: !program.focused
								restoreMode: Binding.RestoreNone
							}
						}

						// what a shell call is called with
						Repeater {
							model: {
								if (root.kind !== "shell") return [];
								const call = Keybinds.shellCall(root.draft);
								const known = Keybinds.shellActions.find(entry => entry.target === call.target && entry.function === call.fn);
								return known ? known.params : [];
							}

							delegate: Field {
								id: param

								required property var modelData
								required property int index

								Layout.fillWidth: true
								icon: "pencil"
								placeholder: param.modelData.name
								text: Keybinds.shellCall(root.draft).params[param.index] ?? ""
								onEdited: text => {
									const args = (root.draft.args || []).slice();
									const at = args.indexOf("call") + 3 + param.index;
									while (args.length <= at) args.push("");
									args[at] = text;
									root.set("args", args);
								}
							}
						}

						// niri's arguments
						Repeater {
							model: root.kind === "niri" && root.meta ? root.meta.args.filter(arg => !arg.rest) : []

							delegate: ColumnLayout {
								id: arg

								required property var modelData
								required property int index

								Layout.fillWidth: true
								spacing: 4

								StyledText {
									text: arg.modelData.description || Keybinds.words(arg.modelData.name)
									tone: Theme.textMuted
									font.pixelSize: Theme.size.small
								}

								Field {
									Layout.fillWidth: true
									placeholder: Keybinds.words(arg.modelData.name)
									text: String(root.draft.args?.[arg.index] ?? "")
									onEdited: text => root.setArg(arg.index, root.typed(arg.modelData, text))
								}
							}
						}

						Repeater {
							model: root.kind === "niri" && root.meta ? root.meta.props : []

							delegate: RowLayout {
								id: option

								required property var modelData
								readonly property bool flag: option.modelData.values.length === 2 && option.modelData.values.includes("true")
								readonly property var value: root.draft.aprops?.[option.modelData.name]

								Layout.fillWidth: true
								spacing: 10

								ColumnLayout {
									Layout.fillWidth: true
									spacing: 1

									StyledText {
										Layout.fillWidth: true
										text: Keybinds.words(option.modelData.name)
										font.weight: Font.Medium
									}

									StyledText {
										Layout.fillWidth: true
										text: option.modelData.description
										tone: Theme.textSubtle
										font.pixelSize: Theme.size.small
										wrapMode: Text.WordWrap
									}
								}

								Toggle {
									visible: option.flag
									checked: option.value === undefined ? option.modelData.default === "true" : option.value === true
									onToggled: checked => root.setAprop(option.modelData.name, String(checked) === option.modelData.default ? undefined : checked)
								}

								Field {
									visible: !option.flag
									Layout.preferredWidth: 150
									placeholder: option.modelData.default ?? ""
									text: option.value === undefined ? "" : String(option.value)
									onEdited: text => root.setAprop(option.modelData.name, text === "" ? undefined : (/^\d+$/.test(text) ? Number(text) : text))
								}
							}
						}

						SectionLabel {
							Layout.topMargin: 4
							text: "Name"
						}

						Field {
							Layout.fillWidth: true
							icon: "tag"
							placeholder: root.draft.action ? Keybinds.actionTitle(root.draft) : "Shown in niri's hotkey overlay"
							text: typeof root.draft.props?.["hotkey-overlay-title"] === "string" ? root.draft.props["hotkey-overlay-title"] : ""
							onEdited: text => root.setProp("hotkey-overlay-title", text.trim() === "" ? undefined : text)
						}

						SectionLabel {
							Layout.topMargin: 4
							text: "Behaviour"
						}

						Rectangle {
							Layout.fillWidth: true
							implicitHeight: behaviour.implicitHeight + 8
							radius: Theme.radius.large
							color: Theme.layer2

							ColumnLayout {
								id: behaviour

								anchors.left: parent.left
								anchors.right: parent.right
								anchors.top: parent.top
								anchors.topMargin: 4
								spacing: 0

								Repeater {
									model: [
										{ prop: "repeat", label: "Repeat while held", detail: "Fires again and again while the keys stay down", on: root.draft.props?.repeat !== false, set: on => root.setProp("repeat", on ? undefined : false) },
										{ prop: "allow-when-locked", label: "Works on the lock screen", detail: "For volume, brightness and media keys", on: root.draft.props?.["allow-when-locked"] === true, set: on => root.setProp("allow-when-locked", on ? true : undefined) },
										{ prop: "allow-inhibiting", label: "Always reaches niri", detail: "Even while an app (a game, a remote desktop) takes the keyboard", on: root.draft.props?.["allow-inhibiting"] === false, set: on => root.setProp("allow-inhibiting", on ? false : undefined) }
									]

									delegate: RowLayout {
										id: behaviourRow

										required property var modelData

										Layout.fillWidth: true
										Layout.leftMargin: 12
										Layout.rightMargin: 12
										Layout.topMargin: 8
										Layout.bottomMargin: 8
										spacing: 10

										ColumnLayout {
											Layout.fillWidth: true
											spacing: 1

											StyledText {
												Layout.fillWidth: true
												text: behaviourRow.modelData.label
												font.weight: Font.Medium
											}

											StyledText {
												Layout.fillWidth: true
												text: behaviourRow.modelData.detail
												tone: Theme.textSubtle
												font.pixelSize: Theme.size.small
												wrapMode: Text.WordWrap
											}
										}

										Toggle {
											checked: behaviourRow.modelData.on
											onToggled: checked => behaviourRow.modelData.set(checked)
										}
									}
								}

								RowLayout {
									Layout.fillWidth: true
									Layout.leftMargin: 12
									Layout.rightMargin: 12
									Layout.preferredHeight: 52
									spacing: 10

									ColumnLayout {
										Layout.fillWidth: true
										spacing: 1

										StyledText {
											Layout.fillWidth: true
											text: "Cooldown"
											font.weight: Font.Medium
										}

										StyledText {
											Layout.fillWidth: true
											text: "Quiet time after it fired, for wheels"
											tone: Theme.textSubtle
											font.pixelSize: Theme.size.small
										}
									}

									Segmented {
										Layout.preferredWidth: 172
										implicitHeight: 30
										options: [
											{ value: "0", label: "Off" },
											{ value: "150", label: "150" },
											{ value: "250", label: "250" },
											{ value: "500", label: "500" }
										]
										current: String(root.draft.props?.["cooldown-ms"] ?? 0)
										onSelected: value => root.setProp("cooldown-ms", value === "0" ? undefined : Number(value))
									}
								}
							}
						}

						Item {
							Layout.preferredHeight: 4
						}
					}
				}

				RowLayout {
					Layout.fillWidth: true
					spacing: 8

					TextButton {
						visible: !root.isNew
						variant: "danger"
						icon: "delete_outline"
						text: "Delete"
						confirm: true
						confirmText: "Delete it?"
						onActivated: {
							Keybinds.remove(root.draft.uid);
							root.done();
						}
					}

					Item {
						Layout.fillWidth: true
					}

					TextButton {
						variant: "ghost"
						text: "Cancel"
						onActivated: root.done()
					}

					TextButton {
						id: saveButton

						variant: "filled"
						icon: "check"
						text: root.isNew ? "Add" : "Save"
						enabled: root.valid && root.dirty
						busy: Keybinds.saving
						onActivated: root.save()
						scale: root.valid && root.dirty ? 1 : 0.96

						Behavior on scale {
							SpatialAnim {
								duration: Motion.medium
							}
						}
					}
				}
			}
		}

		// slides in over the editor
		ActionPicker {
			id: picker

			anchors.top: parent.top
			anchors.bottom: parent.bottom
			width: parent.width
			x: root.pickerOpen ? 0 : parent.width + 24
			opacity: root.pickerOpen ? 1 : 0
			visible: opacity > 0.01
			bind: root.draft
			onClosed: {
				root.pickerOpen = false;
				root.forceActiveFocus();
			}
			onPicked: change => {
				const next = Object.assign({}, root.draft, { action: change.action, args: change.args, aprops: change.aprops });
				root.draft = next;
				root.pickerOpen = false;
				root.forceActiveFocus();
			}

			Behavior on x {
				SpatialAnim {}
			}
			Behavior on opacity {
				Anim {
					duration: Motion.short
				}
			}
		}
	}
}
