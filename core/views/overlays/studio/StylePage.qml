pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.style.theme
import qs.core.services
import qs.style.widgets

// Studio's style page. A style is a local Git branch of this configuration
// (scripts/branch_styles.py); switching checks it out and reloads the shell,
// which tears this page down on success. ↑↓ move between styles, Enter arms
// the switch and a second Enter confirms it; Escape disarms, then closes.
ModalWindow {
	id: root

	modalId: "styles"
	exclusiveKeyboard: true
	onModalOpened: root.reset()

	property var entries: []
	property string currentBranch: ""
	property bool dirty: false
	property bool loaded: false
	property string loadError: ""
	property string switchError: ""
	property string selectedBranch: ""
	property bool switching: false
	property string resultPath: ""

	property bool catalogParseFailed: false
	property string catalogStderr: ""
	property bool expectSwitchError: false
	property string switchStderr: ""

	readonly property var backend: ["python3", `${Quickshell.shellDir}/scripts/branch_styles.py`]
	readonly property var usable: root.entries.filter(entry => entry.compatible)
	readonly property var selected: root.entries.find(entry => entry.branch === root.selectedBranch) ?? null
	readonly property bool detached: root.loaded && root.currentBranch === ""
	readonly property bool canSwitch: !!root.selected && root.selected.compatible && !root.selected.current
		&& !root.dirty && !root.detached && !root.switching
	readonly property var notices: {
		const list = [];
		if (root.dirty)
			list.push({ icon: "alert", text: `Uncommitted changes on ${root.currentBranch || "HEAD"}` });
		if (root.detached)
			list.push({ icon: "alert", text: "Detached HEAD" });
		if (root.switchError !== "")
			list.push({ icon: "alert_circle", text: root.switchError });
		if (root.loadError !== "" && root.entries.length > 0)
			list.push({ icon: "alert_circle", text: root.loadError });
		return list;
	}

	// the message of a Python traceback, or else the last line of output
	function lastLine(text) {
		const lines = String(text || "").split("\n").map(line => line.trim()).filter(line => line !== "");
		const pattern = /^[A-Za-z_.]*(Error|Exception): /;
		for (let i = lines.length - 1; i >= 0; i -= 1) {
			if (pattern.test(lines[i]))
				return lines[i].replace(pattern, "");
		}
		return lines.length > 0 ? lines[lines.length - 1] : "";
	}

	function refresh() {
		if (catalogProcess.running)
			return;
		root.catalogParseFailed = false;
		root.catalogStderr = "";
		catalogProcess.running = true;
	}

	function reset() {
		root.selectedBranch = "";
		applyButton.armed = false;
		root.refresh();
		Qt.callLater(() => keyTarget.forceActiveFocus());
	}

	function setCatalog(text) {
		let data;
		try {
			data = JSON.parse(text);
		} catch (error) {
			root.catalogParseFailed = true;
			root.updateLoadError();
			return;
		}
		root.entries = Array.isArray(data.branches) ? data.branches : [];
		root.currentBranch = String(data.current || "");
		root.dirty = !!data.dirty;
		root.loaded = true;
		root.loadError = "";
		const message = String(data.message || "");
		if (root.expectSwitchError) {
			root.expectSwitchError = false;
			root.switchError = message || root.lastLine(root.switchStderr) || "Switch failed";
		} else if (!root.switching) {
			root.switchError = message;
		}
		if (!root.usable.some(entry => entry.branch === root.selectedBranch)) {
			const current = root.usable.find(entry => entry.current);
			root.selectedBranch = current ? current.branch : (root.usable.length > 0 ? root.usable[0].branch : "");
		}
		Qt.callLater(root.ensureSelectedVisible);
	}

	function updateLoadError() {
		if (!root.catalogParseFailed)
			return;
		root.loadError = root.lastLine(root.catalogStderr) || "Could not read the style catalog";
		if (root.expectSwitchError) {
			root.expectSwitchError = false;
			root.switchError = root.lastLine(root.switchStderr) || "Switch failed";
		}
	}

	function select(branch) {
		if (root.switching || root.selectedBranch === branch)
			return;
		root.selectedBranch = branch;
		applyButton.armed = false;
		Qt.callLater(root.ensureSelectedVisible);
	}

	function move(delta) {
		if (root.usable.length === 0)
			return;
		let index = root.usable.findIndex(entry => entry.branch === root.selectedBranch);
		if (index < 0)
			index = 0;
		else
			index = Math.max(0, Math.min(root.usable.length - 1, index + delta));
		root.select(root.usable[index].branch);
	}

	// Enter and a click on the chosen row go through the button, so the
	// keyboard gets the same arm-then-confirm step as the mouse.
	function trigger() {
		if (root.canSwitch)
			applyButton.clicked(null);
	}

	function startSwitch() {
		if (!root.canSwitch)
			return;
		const base = Quickshell.env("XDG_RUNTIME_DIR") || "/tmp";
		root.resultPath = `${base}/pshell-style-switch-${Date.now()}`;
		root.switchError = "";
		root.switchStderr = "";
		root.switching = true;
		// detached, so the switch outlives the reload it causes
		Quickshell.execDetached(["sh", "-c",
			'out=$("$@" 2>&1 >/dev/null); code=$?; printf "%s\\n%s" "$code" "$out" > "$0.tmp" && mv "$0.tmp" "$0"',
			root.resultPath, ...root.backend, "switch", root.selectedBranch]);
	}

	function finishSwitch(text) {
		if (text === "")
			return;
		const newline = text.indexOf("\n");
		const code = parseInt(newline < 0 ? text : text.slice(0, newline));
		root.switching = false;
		root.resultPath = "";
		if (code !== 0) {
			root.switchStderr = newline < 0 ? "" : text.slice(newline + 1);
			root.expectSwitchError = true;
		}
		root.refresh();
	}

	function ensureSelectedVisible() {
		if (listFlickable.contentHeight <= listFlickable.height) {
			listFlickable.contentY = 0;
			return;
		}
		const row = rowRepeater.itemAt(root.entries.findIndex(entry => entry.branch === root.selectedBranch));
		if (!row)
			return;
		const top = row.y + row.rowTop;
		const bottom = row.y + row.height;
		if (top < listFlickable.contentY)
			listFlickable.contentY = top;
		else if (bottom > listFlickable.contentY + listFlickable.height)
			listFlickable.contentY = Math.max(0, bottom - listFlickable.height);
	}

	Process {
		id: catalogProcess

		command: [...root.backend, "catalog"]
		stdout: StdioCollector {
			onStreamFinished: root.setCatalog(text)
		}
		stderr: StdioCollector {
			onStreamFinished: {
				root.catalogStderr = text;
				root.updateLoadError();
			}
		}
	}

	Process {
		id: resultProcess

		command: ["sh", "-c", 'cat "$0" 2>/dev/null && rm -f "$0"', root.resultPath]
		stdout: StdioCollector {
			onStreamFinished: root.finishSwitch(text)
		}
	}

	Timer {
		interval: root.switching ? 400 : 3000
		repeat: true
		running: root.shown || root.switching
		onTriggered: {
			if (root.switching) {
				if (root.resultPath !== "" && !resultProcess.running)
					resultProcess.running = true;
			} else {
				root.refresh();
			}
		}
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

	StudioTabs {}

	Rectangle {
		id: panel

		// hangs right under the tabs like the taller pages, instead of floating mid-screen
		anchors.horizontalCenter: parent.horizontalCenter
		anchors.top: parent.top
		anchors.topMargin: Math.max(85, (parent.height - 900) / 2 + 25)
		width: Math.min(760, root.width - 120)
		height: Math.min(root.height - 170, Math.max(420, 22 * 2 + 46 + 20 + 18 * 2 + noticeColumn.height + rowColumn.height + 16))
		radius: Theme.radius.huge + 6
		color: Theme.base

		Behavior on height {
			SpatialAnim {
				duration: Motion.medium
			}
		}

		MouseArea {
			anchors.fill: parent
			acceptedButtons: Qt.AllButtons
		}

		Item {
			id: keyTarget

			anchors.fill: parent
			focus: true

			Keys.onEscapePressed: event => {
				event.accepted = true;
				if (applyButton.armed)
					applyButton.armed = false;
				else
					Popups.closeModal();
			}
			Keys.onReturnPressed: root.trigger()
			Keys.onEnterPressed: root.trigger()
			Keys.onUpPressed: root.move(-1)
			Keys.onDownPressed: root.move(1)
		}

		ColumnLayout {
			anchors.fill: parent
			anchors.margins: 22
			spacing: 18

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
						icon: "source_branch"
						size: 22
						color: Theme.primary
					}
				}

				ColumnLayout {
					Layout.fillWidth: true
					spacing: 0

					SectionLabel {
						text: Words.of("styles.title", "Style")
					}

					StyledText {
						Layout.fillWidth: true
						text: root.selected ? root.selected.name : (root.loaded || root.loadError !== "" ? "No styles" : "Loading styles…")
						font.pixelSize: Theme.size.heading
						font.weight: Font.Bold
					}
				}

				TextButton {
					id: applyButton

					implicitHeight: 42
					text: root.switching ? "Switching" : (root.selected && root.selected.current ? "Active" : "Switch")
					icon: "swap_horizontal"
					variant: "filled"
					confirm: true
					confirmText: "Switch?"
					busy: root.switching
					enabled: root.canSwitch || root.switching
					onActivated: root.startSwitch()
				}

				IconButton {
					icon: "close"
					variant: "tonal"
					onClicked: Popups.closeModal()
				}
			}

			ColumnLayout {
				id: noticeColumn

				Layout.fillWidth: true
				Layout.preferredHeight: implicitHeight
				visible: root.notices.length > 0
				spacing: 8

				Repeater {
					model: root.notices

					delegate: Rectangle {
						id: notice

						required property var modelData

						Layout.fillWidth: true
						Layout.preferredHeight: Math.max(40, noticeText.implicitHeight + 20)
						radius: Theme.radius.medium
						color: Theme.dangerContainer

						RowLayout {
							anchors.fill: parent
							anchors.leftMargin: 14
							anchors.rightMargin: 14
							spacing: 10

							Glyph {
								icon: notice.modelData.icon
								size: 17
								color: Theme.danger
							}

							StyledText {
								id: noticeText

								Layout.fillWidth: true
								text: notice.modelData.text
								font.pixelSize: Theme.size.label
								font.weight: Font.DemiBold
								wrapMode: Text.Wrap
							}
						}
					}
				}
			}

			Item {
				Layout.fillWidth: true
				Layout.fillHeight: true
				clip: true

				Spinner {
					anchors.centerIn: parent
					width: 26
					height: 26
					visible: !root.loaded && root.loadError === ""
				}

				EmptyState {
					anchors.centerIn: parent
					visible: root.entries.length === 0 && (root.loaded || root.loadError !== "")
					icon: root.loadError !== "" ? "alert_circle" : "source_branch"
					title: root.loadError !== "" ? "Styles unavailable" : "No branches"
					subtitle: root.loadError
				}

				Flickable {
					id: listFlickable

					anchors.fill: parent
					contentWidth: width
					contentHeight: rowColumn.height
					boundsBehavior: Flickable.StopAtBounds
					interactive: contentHeight > height
					ScrollBar.vertical: ThinScrollBar {}

					onHeightChanged: Qt.callLater(root.ensureSelectedVisible)

					Behavior on contentY {
						enabled: !listFlickable.moving
						SpatialAnim {
							duration: Motion.medium
						}
					}

					Column {
						id: rowColumn

						width: listFlickable.width
						spacing: 4

						Repeater {
							id: rowRepeater

							model: root.entries

							delegate: Column {
								id: row

								required property var modelData
								required property int index

								readonly property bool chosen: row.modelData.branch === root.selectedBranch
								readonly property bool firstOther: !row.modelData.compatible
									&& (row.index === 0 || root.entries[row.index - 1].compatible)
								readonly property real rowTop: otherLabel.visible ? otherLabel.height + row.spacing : 0

								width: rowColumn.width
								spacing: 4

								SectionLabel {
									id: otherLabel

									visible: row.firstOther
									height: 30
									leftPadding: 8
									verticalAlignment: Text.AlignBottom
									bottomPadding: 4
									text: "Other branches"
								}

								ListItem {
									width: parent.width
									height: 60
									icon: "source_branch"
									title: row.modelData.name
									subtitle: row.modelData.description
									selected: row.chosen
									interactive: row.modelData.compatible && !root.switching
									opacity: row.modelData.compatible ? 1 : 0.4
									onClicked: {
										keyTarget.forceActiveFocus();
										if (row.chosen)
											root.trigger();
										else
											root.select(row.modelData.branch);
									}

									StyledText {
										Layout.maximumWidth: 200
										text: row.modelData.branch
										tone: Theme.textSubtle
										font.family: Theme.monoFamily
										font.pixelSize: Theme.size.small
										elide: Text.ElideMiddle
									}

									Item {
										Layout.preferredWidth: 16
										Layout.preferredHeight: 8

										Rectangle {
											anchors.right: parent.right
											anchors.verticalCenter: parent.verticalCenter
											visible: row.modelData.current
											width: 8
											height: 8
											radius: 4
											color: Theme.success
										}
									}
								}
							}
						}
					}
				}
			}

			RowLayout {
				Layout.fillWidth: true
				spacing: 14

				KeyHint { keys: "↑↓"; label: "choose" }
				KeyHint { keys: "↵ ×2"; label: "switch" }
				KeyHint { keys: "Esc"; label: "close" }

				Item {
					Layout.fillWidth: true
				}

				RowLayout {
					visible: root.entries.length > 0
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
