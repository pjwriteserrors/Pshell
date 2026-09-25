pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Widgets
import qs.style.theme
import qs.core.services
import qs.style.widgets

// Studio's combinations page: whole looks (wallpaper, palette, motion, icons,
// pointer, style branch) saved under a name. The work is done by
// scripts/combinations.py. ↑↓ browse, Enter applies, N saves what is on now
// under a new name, Delete removes (press twice).
ModalWindow {
	id: root

	modalId: "combinations"
	exclusiveKeyboard: true
	onModalOpened: root.reset()

	property var combinations: []
	// what the desktop is wearing right now (`combinations.py current`)
	property var worn: ({})
	property var previews: ({})
	property int selectedIndex: 0
	property bool loaded: false
	property bool naming: false
	property string pendingSelectName: ""
	// "apply" | "save" | "replace" | "delete" while a script runs
	property string busyAction: ""
	property var busyEntry: null
	// "busy" | "ok" | "error"
	property string statusKind: ""
	property string statusText: ""

	readonly property string scriptPath: `${Quickshell.shellDir}/scripts/combinations.py`
	readonly property string branchScriptPath: `${Quickshell.shellDir}/scripts/branch_styles.py`
	readonly property bool busy: root.busyAction !== ""
	readonly property var selected: root.combinations.length > 0
		? root.combinations[Math.max(0, Math.min(root.combinations.length - 1, root.selectedIndex))]
		: null
	readonly property string draftName: nameField.text.trim()
	readonly property bool draftTaken: root.indexOfName(root.draftName) >= 0
	readonly property var detailEntry: root.naming ? root.worn : root.selected
	readonly property bool selectedActive: root.isActive(root.selected)

	// sha1 of the theme path names its preview, as in theme_catalog.sh; the
	// worn theme falls back to the frame of the running wallpaper
	readonly property string previewScript: [
		"import hashlib, json, os, sys",
		"state = os.environ.get('THEME_STATE_DIR') or os.path.expanduser('~/.local/state/quickshell-theme')",
		"folder = os.environ.get('THEME_PREVIEW_DIR') or os.path.join(state, 'previews')",
		"worn, paths = sys.argv[1], sys.argv[2:]",
		"out = {}",
		"for path in paths:",
		"    file = os.path.join(folder, hashlib.sha1(path.encode()).hexdigest() + '.png')",
		"    if os.path.isfile(file):",
		"        out[path] = file",
		"frame = os.path.join(state, 'current', 'frame.png')",
		"if worn and worn not in out and os.path.isfile(frame):",
		"    out[worn] = frame",
		"print(json.dumps(out))"
	].join("\n")

	function reset() {
		root.naming = false;
		nameField.text = "";
		if (root.statusKind !== "busy")
			root.clearStatus();
		root.reload();
		Qt.callLater(function() {
			keyTarget.forceActiveFocus();
		});
	}

	function reload() {
		if (root.selected && root.pendingSelectName === "")
			root.pendingSelectName = String(root.selected.name || "");
		listProcess.running = true;
	}

	function setList(raw) {
		let parsed = {};
		try {
			parsed = JSON.parse(String(raw || "{}"));
		} catch (error) {
			parsed = {};
		}
		root.combinations = (parsed.combinations || []).filter(entry => entry && String(entry.name || "") !== "");
		root.worn = parsed.current || ({});
		root.loaded = true;

		const wanted = root.indexOfName(root.pendingSelectName);
		root.pendingSelectName = "";
		root.selectIndex(wanted >= 0 ? wanted : root.selectedIndex);
		root.loadPreviews();
	}

	function loadPreviews() {
		const paths = [];
		for (const entry of root.combinations.concat([root.worn])) {
			const path = String(entry.theme || "");
			if (path !== "" && paths.indexOf(path) < 0)
				paths.push(path);
		}
		previewProcess.command = ["python3", "-c", root.previewScript, String(root.worn.theme || "")].concat(paths);
		previewProcess.running = true;
	}

	function previewFor(entry) {
		if (!entry)
			return "";
		return root.previews[String(entry.theme || "")] ?? "";
	}

	function indexOfName(name) {
		const wanted = String(name || "").toLowerCase();
		if (wanted === "")
			return -1;
		return root.combinations.findIndex(entry => String(entry.name || "").toLowerCase() === wanted);
	}

	function selectIndex(index) {
		if (root.combinations.length === 0) {
			root.selectedIndex = 0;
			return;
		}
		root.selectedIndex = Math.max(0, Math.min(root.combinations.length - 1, index));
		comboList.positionViewAtIndex(root.selectedIndex, ListView.Contain);
	}

	function moveSelection(delta) {
		root.selectIndex(root.selectedIndex + delta);
	}

	function baseName(path) {
		const parts = String(path || "").split("/").filter(part => part !== "");
		return parts.length > 0 ? parts[parts.length - 1] : "";
	}

	function named(entry, key) {
		const value = entry[key];
		return value !== undefined && value !== null && String(value) !== "" && !(key === "cursorSize" && Number(value) === 0);
	}

	function same(entry, key) {
		if (!root.named(entry, key))
			return true;
		if (key === "cursorSize")
			return Number(entry[key]) === Number(root.worn.cursorSize || 0);
		return String(entry[key]) === String(root.worn[key] ?? "");
	}

	// A combination is active when every part it names is what is on now.
	function isActive(entry) {
		if (!entry)
			return false;
		const keys = ["theme", "backend", "palette", "style", "animation", "icons", "cursor", "cursorSize", "branch"];
		let any = false;
		for (const key of keys) {
			if (!root.named(entry, key))
				continue;
			any = true;
			if (!root.same(entry, key))
				return false;
		}
		return any;
	}

	function partsOf(entry) {
		const e = entry || ({});
		const animation = String(e.animation || "");
		const split = animation.indexOf(":");
		const part = (icon, label, keys, value, tag) => ({
			icon: icon,
			label: label,
			value: value,
			tag: tag || "",
			named: keys.some(key => root.named(e, key)),
			live: keys.some(key => root.named(e, key)) && keys.every(key => root.same(e, key))
		});
		return [
			part("wallpaper", "Wallpaper", ["theme"], String(e.themeName || "") || root.baseName(e.theme)),
			part("palette", "Palette", ["backend", "palette", "style"], [e.backend, e.palette, e.style].filter(v => String(v || "") !== "").join(" · ")),
			part("animation_play", "Animation", ["animation"], split >= 0 ? animation.slice(split + 1) : animation, split >= 0 ? animation.slice(0, split) : ""),
			part("apps", "Icons", ["icons"], String(e.icons || "")),
			part("cursor_default_outline", "Cursor", ["cursor", "cursorSize"], String(e.cursor || ""), e.cursor && Number(e.cursorSize || 0) > 0 ? `${e.cursorSize} px` : ""),
			part("source_branch", "Style", ["branch"], String(e.branch || ""))
		];
	}

	function subtitleOf(entry) {
		const animation = String(entry.animation || "");
		return [
			String(entry.themeName || "") || root.baseName(entry.theme),
			animation.slice(animation.indexOf(":") + 1),
			String(entry.icons || "")
		].filter(value => value !== "").join(" · ");
	}

	function savedLabel(entry) {
		const stamp = Number(entry?.savedAt || 0);
		return stamp > 0 ? Qt.formatDate(new Date(stamp * 1000), "d MMM yyyy") : "";
	}

	function setStatus(kind, text) {
		root.statusKind = kind;
		root.statusText = text;
		if (kind === "ok")
			statusTimer.restart();
		else
			statusTimer.stop();
	}

	function clearStatus() {
		root.statusKind = "";
		root.statusText = "";
	}

	function errorText(raw, fallback) {
		const lines = String(raw || "").split("\n").map(line => line.trim()).filter(line => line !== "");
		const detail = lines.filter(line => !line.startsWith("failed:") && !line.startsWith("Traceback") && !line.startsWith("File "));
		const pick = detail.length > 0 ? detail[detail.length - 1] : (lines.length > 0 ? lines[0] : "");
		return pick !== "" ? `${fallback}: ${pick}` : fallback;
	}

	function applySelected() {
		const entry = root.selected;
		if (!entry || root.busy || root.naming)
			return;
		root.busyAction = "apply";
		root.busyEntry = entry;
		root.setStatus("busy", `Applying ${entry.name}…`);
		// the branch goes separately and detached: switching it reloads the
		// shell, which would take this process down with it
		applyProcess.command = ["python3", root.scriptPath, "apply", "--name", String(entry.name), "--skip-branch"];
		applyProcess.running = true;
	}

	function finishApply(exitCode) {
		const entry = root.busyEntry;
		root.busyAction = "";
		root.busyEntry = null;
		if (exitCode === 0) {
			root.setStatus("ok", `Applied ${entry.name}`);
			const branch = String(entry.branch || "");
			if (branch !== "" && branch !== String(root.worn.branch || ""))
				Quickshell.execDetached(["python3", root.branchScriptPath, "switch", branch]);
		} else {
			root.setStatus("error", root.errorText(applyErrors.text, "Apply failed"));
		}
		root.reload();
	}

	function runWrite(action, args, selectName) {
		if (root.busy)
			return;
		root.busyAction = action;
		root.pendingSelectName = selectName;
		writeProcess.command = ["python3", root.scriptPath].concat(args);
		writeProcess.running = true;
	}

	function finishWrite(exitCode) {
		const action = root.busyAction;
		root.busyAction = "";
		if (exitCode === 0) {
			if (action === "delete")
				root.clearStatus();
			else
				root.setStatus("ok", "Saved");
		} else {
			root.setStatus("error", root.errorText(writeErrors.text, action === "delete" ? "Delete failed" : "Save failed"));
		}
		root.reload();
	}

	function startNaming() {
		if (root.busy)
			return;
		root.naming = true;
		nameField.text = "";
		Qt.callLater(nameField.focusInput);
	}

	function cancelNaming() {
		root.naming = false;
		nameField.text = "";
		keyTarget.forceActiveFocus();
	}

	function saveDraft() {
		const name = root.draftName;
		if (name === "" || root.busy)
			return;
		const existing = root.indexOfName(name);
		const note = existing >= 0 ? String(root.combinations[existing].note || "") : "";
		root.runWrite("save", ["capture", "--name", name, "--note", note], name);
		root.cancelNaming();
	}

	function replaceSelected() {
		const entry = root.selected;
		if (!entry || root.naming)
			return;
		root.runWrite("replace", ["capture", "--name", String(entry.name), "--note", String(entry.note || "")], String(entry.name));
	}

	function deleteSelected() {
		const entry = root.selected;
		if (!entry || root.naming)
			return;
		const next = root.combinations[root.selectedIndex + 1] || root.combinations[root.selectedIndex - 1];
		root.runWrite("delete", ["delete", "--name", String(entry.name)], next ? String(next.name || "") : "");
	}

	Timer {
		id: statusTimer
		interval: 4000
		onTriggered: root.clearStatus()
	}

	Process {
		id: listProcess
		command: ["python3", root.scriptPath, "list"]
		stdout: StdioCollector {
			onStreamFinished: root.setList(text)
		}
	}

	Process {
		id: previewProcess
		command: ["true"]
		stdout: StdioCollector {
			onStreamFinished: {
				try {
					root.previews = JSON.parse(String(text || "{}"));
				} catch (error) {
					root.previews = {};
				}
			}
		}
	}

	Process {
		id: applyProcess
		command: ["true"]
		stdout: StdioCollector {}
		stderr: StdioCollector {
			id: applyErrors
		}
		onExited: exitCode => Qt.callLater(() => root.finishApply(exitCode))
	}

	Process {
		id: writeProcess
		command: ["true"]
		stdout: StdioCollector {}
		stderr: StdioCollector {
			id: writeErrors
		}
		onExited: exitCode => Qt.callLater(() => root.finishWrite(exitCode))
	}

	component KeyHint: RowLayout {
		id: hint

		property string keys: ""
		property string label: ""

		spacing: 5

		Rectangle {
			Layout.preferredHeight: 20
			Layout.preferredWidth: Math.max(22, keyText.implicitWidth + 10)
			radius: 6
			color: Theme.layer2

			StyledText {
				id: keyText
				anchors.centerIn: parent
				text: hint.keys
				font.pixelSize: Theme.size.tiny
				font.weight: Font.Bold
			}
		}

		StyledText {
			text: hint.label
			tone: Theme.textSubtle
			font.pixelSize: Theme.size.small
		}
	}

	component Thumb: ClippingRectangle {
		id: thumb

		property string path: ""
		property int decodeWidth: 160
		property real glyphSize: 18

		color: Theme.layer2

		Image {
			id: thumbImage
			anchors.fill: parent
			source: thumb.path !== "" ? `file://${thumb.path}` : ""
			sourceSize.width: thumb.decodeWidth
			fillMode: Image.PreserveAspectCrop
			asynchronous: true
			opacity: status === Image.Ready ? 1 : 0

			Behavior on opacity {
				Anim {}
			}
		}

		Glyph {
			anchors.centerIn: parent
			visible: thumbImage.status !== Image.Ready
			icon: "image_outline"
			size: thumb.glyphSize
			color: Theme.textFaint
		}
	}

	StudioTabs {
		anchors.horizontalCenter: panel.horizontalCenter
		anchors.bottom: panel.top
		anchors.bottomMargin: 14
	}

	Rectangle {
		id: panel

		anchors.centerIn: parent
		anchors.verticalCenterOffset: 25
		width: Math.min(1400, root.width - 120)
		height: Math.min(860, root.height - 170)
		radius: Theme.radius.huge + 6
		color: Theme.base

		MouseArea {
			anchors.fill: parent
			acceptedButtons: Qt.AllButtons
		}

		Item {
			id: keyTarget

			anchors.fill: parent
			focus: true

			Keys.onEscapePressed: Popups.closeModal()
			Keys.onReturnPressed: root.applySelected()
			Keys.onEnterPressed: root.applySelected()
			Keys.onUpPressed: root.moveSelection(-1)
			Keys.onDownPressed: root.moveSelection(1)
			Keys.onDeletePressed: {
				if (deleteButton.visible && deleteButton.enabled)
					deleteButton.clicked(null);
			}
			Keys.onPressed: event => {
				if (event.key === Qt.Key_Home) {
					root.selectIndex(0);
				} else if (event.key === Qt.Key_End) {
					root.selectIndex(root.combinations.length - 1);
				} else if (event.key === Qt.Key_PageUp) {
					root.moveSelection(-8);
				} else if (event.key === Qt.Key_PageDown) {
					root.moveSelection(8);
				} else if (event.key === Qt.Key_N && !(event.modifiers & (Qt.AltModifier | Qt.MetaModifier))) {
					root.startNaming();
				} else {
					return;
				}
				event.accepted = true;
			}
		}

		ColumnLayout {
			anchors.fill: parent
			anchors.margins: 22
			spacing: 18

			// ── header ────────────────────────────────────────────────────
			RowLayout {
				Layout.fillWidth: true
				spacing: 14

				Rectangle {
					Layout.preferredWidth: 46
					Layout.preferredHeight: 46
					radius: Theme.radius.large
					color: Theme.primaryContainer

					Glyph {
						anchors.centerIn: parent
						icon: "bookmark_outline"
						size: 22
						color: Theme.primary
					}
				}

				ColumnLayout {
					Layout.fillWidth: true
					spacing: 0

					SectionLabel {
						text: "Combinations"
					}

					StyledText {
						Layout.fillWidth: true
						text: {
							if (root.naming)
								return root.draftName !== "" ? root.draftName : "New combination";
							if (root.selected)
								return String(root.selected.name || "");
							return root.loaded ? "No combinations" : "Loading…";
						}
						font.pixelSize: Theme.size.heading
						font.weight: Font.Bold
					}
				}

				StyledText {
					visible: root.loaded
					text: `${root.combinations.length} saved`
					tone: Theme.textSubtle
					font.pixelSize: Theme.size.small
				}

				TextButton {
					implicitHeight: 42
					text: "Save current"
					icon: "bookmark_plus_outline"
					enabled: !root.naming && !root.busy
					onActivated: root.startNaming()
				}

				TextButton {
					implicitHeight: 42
					text: root.selectedActive && !root.naming ? "Active" : "Apply"
					icon: "check"
					variant: "filled"
					busy: root.busyAction === "apply"
					enabled: root.selected !== null && !root.naming && (!root.busy || root.busyAction === "apply")
					onActivated: root.applySelected()
				}

				IconButton {
					icon: "close"
					variant: "tonal"
					onClicked: Popups.closeModal()
				}
			}

			// ── body ──────────────────────────────────────────────────────
			Item {
				Layout.fillWidth: true
				Layout.fillHeight: true

				Spinner {
					anchors.centerIn: parent
					width: 28
					height: 28
					visible: !root.loaded
				}

				EmptyState {
					anchors.centerIn: parent
					visible: root.loaded && root.combinations.length === 0 && !root.naming
					icon: "bookmark_outline"
					title: "No combinations"
				}

				RowLayout {
					anchors.fill: parent
					spacing: 18
					visible: root.loaded && (root.combinations.length > 0 || root.naming)

					// list
					ColumnLayout {
						Layout.preferredWidth: Math.min(420, parent.width * 0.36)
						Layout.fillWidth: false
						Layout.fillHeight: true
						spacing: 8

						Item {
							id: namingRow

							Layout.fillWidth: true
							Layout.preferredHeight: root.naming ? 44 : 0
							visible: Layout.preferredHeight > 0.5
							opacity: root.naming ? 1 : 0
							clip: true

							Behavior on Layout.preferredHeight {
								SpatialAnim {
									duration: Motion.medium
								}
							}
							Behavior on opacity {
								Anim {}
							}

							Keys.onEscapePressed: root.cancelNaming()

							RowLayout {
								anchors.left: parent.left
								anchors.right: parent.right
								anchors.top: parent.top
								height: 44
								spacing: 8

								Field {
									id: nameField

									Layout.fillWidth: true
									Layout.preferredHeight: 42
									icon: "bookmark_plus_outline"
									placeholder: "Name"
									onAccepted: root.saveDraft()
								}

								TextButton {
									implicitHeight: 42
									text: root.draftTaken ? "Replace" : "Save"
									icon: "content_save"
									variant: "filled"
									enabled: root.draftName !== "" && !root.busy
									onActivated: root.saveDraft()
								}
							}
						}

						ListView {
							id: comboList

							Layout.fillWidth: true
							Layout.fillHeight: true
							clip: true
							spacing: 4
							model: root.combinations
							currentIndex: root.selectedIndex
							boundsBehavior: Flickable.StopAtBounds
							highlightFollowsCurrentItem: false
							ScrollBar.vertical: ThinScrollBar {}

							delegate: Clickable {
								id: row

								required property var modelData
								required property int index

								readonly property bool selected: row.index === root.selectedIndex && !root.naming
								readonly property bool active: root.isActive(row.modelData)

								width: comboList.width
								height: 62
								radius: Theme.radius.medium
								pressedScale: 0.98
								color: row.selected ? Qt.alpha(Theme.primary, 0.14) : (row.hovered ? Theme.layer1 : "transparent")

								onClicked: {
									if (root.naming)
										root.cancelNaming();
									if (row.selected) {
										root.applySelected();
										return;
									}
									root.selectIndex(row.index);
								}

								RowLayout {
									anchors.fill: parent
									anchors.leftMargin: 8
									anchors.rightMargin: 14
									spacing: 12

									Thumb {
										Layout.preferredWidth: 72
										Layout.preferredHeight: 46
										radius: Theme.radius.small
										path: root.previewFor(row.modelData)
									}

									ColumnLayout {
										Layout.fillWidth: true
										spacing: 1

										StyledText {
											Layout.fillWidth: true
											text: String(row.modelData.name || "")
											font.pixelSize: Theme.size.body
											font.weight: row.selected ? Font.Bold : Font.DemiBold
										}

										StyledText {
											Layout.fillWidth: true
											visible: text !== ""
											text: root.subtitleOf(row.modelData)
											tone: Theme.textMuted
											font.pixelSize: Theme.size.small
										}
									}

									Rectangle {
										visible: row.active
										Layout.preferredWidth: 8
										Layout.preferredHeight: 8
										radius: 4
										color: Theme.success
									}
								}
							}
						}
					}

					// detail
					Rectangle {
						Layout.fillWidth: true
						Layout.fillHeight: true
						radius: Theme.radius.huge
						color: Theme.layer1

						ColumnLayout {
							anchors.fill: parent
							anchors.margins: 16
							spacing: 16
							visible: root.detailEntry !== null

							Thumb {
								Layout.fillWidth: true
								Layout.fillHeight: true
								Layout.minimumHeight: 120
								radius: Theme.radius.large
								decodeWidth: 1280
								glyphSize: 40
								path: root.previewFor(root.detailEntry)
							}

							RowLayout {
								Layout.fillWidth: true
								Layout.leftMargin: 4
								Layout.rightMargin: 4
								spacing: 12

								ColumnLayout {
									Layout.fillWidth: true
									spacing: 2

									StyledText {
										Layout.fillWidth: true
										text: root.naming ? (root.draftName !== "" ? root.draftName : "Current look") : String(root.selected?.name || "")
										font.pixelSize: Theme.size.heading + 4
										font.weight: Font.Bold
									}

									StyledText {
										Layout.fillWidth: true
										visible: text !== ""
										text: root.naming ? "" : String(root.selected?.note || "")
										tone: Theme.textMuted
										font.pixelSize: Theme.size.body
									}
								}

								StyledText {
									visible: text !== ""
									text: root.naming ? "" : root.savedLabel(root.selected)
									tone: Theme.textSubtle
									font.pixelSize: Theme.size.small
								}

								TextButton {
									visible: !root.naming
									text: "Replace"
									icon: "content_save"
									busy: root.busyAction === "replace"
									enabled: !root.busy || root.busyAction === "replace"
									onActivated: root.replaceSelected()
								}

								TextButton {
									id: deleteButton

									visible: !root.naming
									text: "Delete"
									icon: "delete_outline"
									variant: "danger"
									confirm: true
									confirmText: "Delete?"
									busy: root.busyAction === "delete"
									enabled: !root.busy || root.busyAction === "delete"
									onActivated: root.deleteSelected()
								}
							}

							GridLayout {
								Layout.fillWidth: true
								columns: 3
								columnSpacing: 10
								rowSpacing: 10

								Repeater {
									model: root.partsOf(root.detailEntry)

									delegate: Rectangle {
										id: tile

										required property var modelData

										Layout.fillWidth: true
										Layout.preferredWidth: 1
										Layout.preferredHeight: 66
										radius: Theme.radius.large
										color: Theme.layer2
										opacity: tile.modelData.named ? 1 : 0.55

										ColumnLayout {
											anchors.fill: parent
											anchors.leftMargin: 14
											anchors.rightMargin: 14
											anchors.topMargin: 11
											anchors.bottomMargin: 11
											spacing: 3

											RowLayout {
												Layout.fillWidth: true
												spacing: 6

												Glyph {
													icon: tile.modelData.icon
													size: 13
													color: Theme.textSubtle
												}

												SectionLabel {
													Layout.fillWidth: true
													text: tile.modelData.label
												}

												Rectangle {
													visible: tile.modelData.live && !root.naming
													Layout.preferredWidth: 8
													Layout.preferredHeight: 8
													radius: 4
													color: Theme.success
												}
											}

											RowLayout {
												Layout.fillWidth: true
												spacing: 8

												StyledText {
													Layout.fillWidth: true
													text: tile.modelData.value !== "" ? tile.modelData.value : "—"
													tone: tile.modelData.value !== "" ? Theme.text : Theme.textFaint
													font.pixelSize: Theme.size.body
													font.weight: Font.DemiBold
												}

												Rectangle {
													visible: tile.modelData.tag !== ""
													Layout.preferredHeight: 20
													Layout.preferredWidth: tagLabel.implicitWidth + 14
													radius: 10
													color: Qt.alpha(Theme.primary, 0.18)

													StyledText {
														id: tagLabel

														anchors.centerIn: parent
														text: tile.modelData.tag
														tone: Theme.primary
														font.pixelSize: Theme.size.tiny
														font.weight: Font.Bold
													}
												}
											}
										}
									}
								}
							}
						}
					}
				}
			}

			// ── footer ────────────────────────────────────────────────────
			RowLayout {
				Layout.fillWidth: true
				Layout.preferredHeight: 22
				spacing: 14

				KeyHint { visible: !root.naming && root.selected !== null; keys: "↑↓"; label: "choose" }
				KeyHint { visible: !root.naming && root.selected !== null; keys: "↵"; label: "apply" }
				KeyHint { visible: !root.naming; keys: "N"; label: "new" }
				KeyHint { visible: !root.naming && root.selected !== null; keys: "Del ×2"; label: "delete" }
				KeyHint { visible: !root.naming; keys: "Esc"; label: "close" }
				KeyHint { visible: root.naming; keys: "↵"; label: "save" }
				KeyHint { visible: root.naming; keys: "Esc"; label: "cancel" }

				Item {
					Layout.fillWidth: true
				}

				RowLayout {
					visible: root.statusKind !== ""
					spacing: 7

					Spinner {
						visible: root.statusKind === "busy"
						Layout.preferredWidth: 14
						Layout.preferredHeight: 14
					}

					Glyph {
						visible: root.statusKind === "ok" || root.statusKind === "error"
						icon: root.statusKind === "error" ? "alert_circle" : "check_circle"
						size: 15
						color: root.statusKind === "error" ? Theme.danger : Theme.success
					}

					StyledText {
						Layout.maximumWidth: panel.width * 0.45
						text: root.statusText
						tone: root.statusKind === "error" ? Theme.danger : Theme.textMuted
						font.pixelSize: Theme.size.small
					}
				}

				RowLayout {
					visible: root.statusKind === "" && root.combinations.length > 0
					spacing: 6

					Rectangle {
						Layout.preferredWidth: 8
						Layout.preferredHeight: 8
						radius: 4
						color: Theme.success
					}

					StyledText {
						text: "currently active"
						tone: Theme.textSubtle
						font.pixelSize: Theme.size.small
					}
				}
			}
		}
	}
}
