pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.style.theme
import qs.core.services
import qs.style.widgets

// Studio page "Icons & Pointer": icon theme, cursor theme and cursor size.
// Both lists show the themes' own files (sample icons, the decoded left_ptr).
// ↑↓ move inside a column, ←→ / Tab switch columns, +/− change the size,
// Enter applies all three through scripts/appearance_themes.py.
ModalWindow {
	id: root

	modalId: "dress"
	exclusiveKeyboard: true
	onModalOpened: root.reset()

	property var iconThemes: []
	property var cursorThemes: []
	property int iconIndex: 0
	property int cursorIndex: 0
	property string column: "icons"
	property string liveIcon: ""
	property string liveCursor: ""
	property int liveSize: 24
	property int selectedSize: 24
	property bool listLoading: false
	property bool applying: false
	property string statusKind: "" // "" | ok | error
	property string statusText: ""
	property string applyError: ""

	readonly property string scriptPath: `${Quickshell.shellDir}/scripts/appearance_themes.py`
	readonly property real rowHeight: 76
	readonly property real rowGap: 8

	readonly property var currentIcon: root.iconThemes.length > 0 ? root.iconThemes[Math.max(0, Math.min(root.iconThemes.length - 1, root.iconIndex))] : null
	readonly property var currentCursor: root.cursorThemes.length > 0 ? root.cursorThemes[Math.max(0, Math.min(root.cursorThemes.length - 1, root.cursorIndex))] : null
	readonly property string currentCursorPreview: root.currentCursor ? String(root.currentCursor.preview || "") : ""

	readonly property bool pending: (root.currentIcon !== null && String(root.currentIcon.id) !== root.liveIcon)
		|| (root.currentCursor !== null && String(root.currentCursor.id) !== root.liveCursor)
		|| (root.currentCursor !== null && root.selectedSize !== root.liveSize)

	readonly property var sizeOptions: {
		const sizes = [16, 24, 32, 48, 64];
		if (root.liveSize > 0 && sizes.indexOf(root.liveSize) < 0)
			sizes.push(root.liveSize);
		sizes.sort((a, b) => a - b);
		return sizes;
	}

	function reset() {
		root.column = "icons";
		root.statusKind = "";
		root.statusText = "";
		root.listLoading = true;
		listProcess.running = true;
		currentProcess.running = true;
		Qt.callLater(function () {
			keyTarget.forceActiveFocus();
		});
	}

	function setListing(raw) {
		try {
			const parsed = JSON.parse(String(raw || "{}"));
			root.iconThemes = parsed.icons || [];
			root.cursorThemes = parsed.cursors || [];
		} catch (error) {
			root.iconThemes = [];
			root.cursorThemes = [];
		}
		root.listLoading = false;
		root.selectLive();
	}

	function setCurrent(raw) {
		try {
			const parsed = JSON.parse(String(raw || "{}"));
			root.liveIcon = String(parsed.icon || "");
			root.liveCursor = String(parsed.cursor || "");
			root.liveSize = Number(parsed.cursorSize || 24);
			root.selectedSize = root.liveSize;
		} catch (error) {
			return;
		}
		root.selectLive();
	}

	function indexOfId(list, id) {
		for (let i = 0; i < list.length; i += 1) {
			if (String(list[i].id) === id)
				return i;
		}
		return -1;
	}

	function selectLive() {
		root.iconIndex = Math.max(0, root.indexOfId(root.iconThemes, root.liveIcon));
		root.cursorIndex = Math.max(0, root.indexOfId(root.cursorThemes, root.liveCursor));
		Qt.callLater(root.ensureVisible);
	}

	function clearStatus() {
		if (!root.applying) {
			root.statusKind = "";
			root.statusText = "";
		}
	}

	function selectIcon(index) {
		if (root.iconThemes.length === 0)
			return;
		root.iconIndex = Math.max(0, Math.min(root.iconThemes.length - 1, index));
		root.clearStatus();
		Qt.callLater(root.ensureVisible);
	}

	function selectCursor(index) {
		if (root.cursorThemes.length === 0)
			return;
		root.cursorIndex = Math.max(0, Math.min(root.cursorThemes.length - 1, index));
		root.clearStatus();
		Qt.callLater(root.ensureVisible);
	}

	function move(delta) {
		if (root.column === "icons")
			root.selectIcon(root.iconIndex + delta);
		else
			root.selectCursor(root.cursorIndex + delta);
	}

	function stepSize(delta) {
		const sizes = root.sizeOptions;
		let index = sizes.indexOf(root.selectedSize);
		if (index < 0)
			index = 0;
		root.selectedSize = sizes[Math.max(0, Math.min(sizes.length - 1, index + delta))];
		root.clearStatus();
	}

	function keepVisible(flick, index) {
		const top = index * (root.rowHeight + root.rowGap);
		const bottom = top + root.rowHeight;
		if (top < flick.contentY)
			flick.contentY = top;
		else if (bottom > flick.contentY + flick.height)
			flick.contentY = Math.max(0, bottom - flick.height);
	}

	function ensureVisible() {
		root.keepVisible(iconFlick, root.iconIndex);
		root.keepVisible(cursorFlick, root.cursorIndex);
	}

	function apply() {
		if (root.applying || (!root.currentIcon && !root.currentCursor))
			return;
		const command = ["python3", root.scriptPath, "apply"];
		if (root.currentIcon)
			command.push("--icon", String(root.currentIcon.id));
		if (root.currentCursor)
			command.push("--cursor", String(root.currentCursor.id), "--cursor-size", String(root.selectedSize));
		root.applyError = "";
		root.statusKind = "";
		root.statusText = "";
		root.applying = true;
		applyProcess.command = command;
		applyProcess.running = true;
	}

	function finishApply(exitCode) {
		root.applying = false;
		if (exitCode === 0) {
			if (root.currentIcon)
				root.liveIcon = String(root.currentIcon.id);
			if (root.currentCursor) {
				root.liveCursor = String(root.currentCursor.id);
				root.liveSize = root.selectedSize;
			}
			root.statusKind = "ok";
			root.statusText = "Applied";
			statusTimer.restart();
		} else {
			root.statusKind = "error";
			root.statusText = root.applyError !== "" ? root.applyError : `Failed (exit ${exitCode})`;
		}
	}

	Timer {
		id: statusTimer
		interval: 3200
		onTriggered: {
			if (root.statusKind === "ok")
				root.clearStatus();
		}
	}

	Process {
		id: listProcess
		command: ["python3", root.scriptPath, "list"]
		stdout: StdioCollector {
			onStreamFinished: root.setListing(text)
		}
		onExited: exitCode => {
			if (exitCode !== 0)
				root.listLoading = false;
		}
	}

	Process {
		id: currentProcess
		command: ["python3", root.scriptPath, "current"]
		stdout: StdioCollector {
			onStreamFinished: root.setCurrent(text)
		}
	}

	Process {
		id: applyProcess
		command: ["true"]
		stdout: StdioCollector {}
		stderr: StdioCollector {
			onStreamFinished: {
				const lines = String(text || "").trim().split("\n").filter(line => line.trim() !== "");
				root.applyError = lines.length > 0 ? lines[lines.length - 1].trim() : "";
			}
		}
		onExited: exitCode => Qt.callLater(() => root.finishApply(exitCode))
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

	component ColumnHeader: RowLayout {
		id: header

		property string icon: ""
		property string title: ""
		property int count: 0
		property bool active: false

		Layout.fillWidth: true
		spacing: 8

		Glyph {
			icon: header.icon
			size: 17
			color: header.active ? Theme.primary : Theme.textSubtle
		}

		StyledText {
			text: header.title
			tone: header.active ? Theme.text : Theme.textMuted
			font.pixelSize: Theme.size.title
			font.weight: Font.Bold
		}

		Item {
			Layout.fillWidth: true
		}

		StyledText {
			text: String(header.count)
			tone: Theme.textSubtle
			font.pixelSize: Theme.size.small
			tabular: true
		}
	}

	component RowCard: Item {
		id: rowCard

		property bool selected: false
		property bool focused: false
		default property alias content: inner.data

		signal activated

		Rectangle {
			id: surface

			anchors.fill: parent
			radius: Theme.radius.huge
			color: rowCard.selected ? Theme.layer2 : (rowMouse.containsMouse ? Qt.tint(Theme.layer1, Qt.alpha(Theme.text, 0.025)) : Theme.layer1)
			border.width: rowCard.selected ? 2 : 0
			border.color: rowCard.focused ? Theme.primary : Qt.alpha(Theme.primary, 0.35)
			scale: rowMouse.pressed ? 0.985 : 1

			Behavior on color {
				ColorAnim {}
			}
			Behavior on border.color {
				ColorAnim {}
			}
			Behavior on scale {
				SpatialAnim {
					duration: Motion.short
				}
			}

			Item {
				id: inner

				anchors.fill: parent
				anchors.leftMargin: 16
				anchors.rightMargin: 12
			}
		}

		MouseArea {
			id: rowMouse

			anchors.fill: parent
			hoverEnabled: true
			cursorShape: Qt.PointingHandCursor
			onClicked: rowCard.activated()
		}
	}

	component NameBlock: ColumnLayout {
		id: nameBlock

		property string name: ""
		property string comment: ""
		property bool selected: false
		property bool live: false

		Layout.fillWidth: true
		spacing: 2

		RowLayout {
			Layout.fillWidth: true
			spacing: 8

			Rectangle {
				visible: nameBlock.live
				Layout.preferredWidth: 8
				Layout.preferredHeight: 8
				radius: 4
				color: Theme.success
			}

			StyledText {
				Layout.fillWidth: true
				text: nameBlock.name
				font.pixelSize: Theme.size.body
				font.weight: nameBlock.selected ? Font.Bold : Font.DemiBold
			}
		}

		StyledText {
			Layout.fillWidth: true
			visible: nameBlock.comment !== ""
			text: nameBlock.comment
			tone: Theme.textSubtle
			font.pixelSize: Theme.size.small
		}
	}

	StudioTabs {}

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
			Keys.onReturnPressed: root.apply()
			Keys.onEnterPressed: root.apply()
			Keys.onUpPressed: root.move(-1)
			Keys.onDownPressed: root.move(1)
			Keys.onLeftPressed: root.column = "icons"
			Keys.onRightPressed: root.column = "cursors"
			Keys.onTabPressed: root.column = root.column === "icons" ? "cursors" : "icons"
			Keys.onBacktabPressed: root.column = root.column === "icons" ? "cursors" : "icons"
			Keys.onPressed: event => {
				if (event.key === Qt.Key_Plus || event.key === Qt.Key_Equal) {
					root.stepSize(1);
					event.accepted = true;
				} else if (event.key === Qt.Key_Minus) {
					root.stepSize(-1);
					event.accepted = true;
				} else if (event.key === Qt.Key_Home) {
					root.move(-1000);
					event.accepted = true;
				} else if (event.key === Qt.Key_End) {
					root.move(1000);
					event.accepted = true;
				}
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
						icon: "cursor_default_outline"
						size: 22
						color: Theme.primary
					}
				}

				ColumnLayout {
					Layout.fillWidth: true
					spacing: 0

					SectionLabel {
						text: Words.of("dress.title", "Icons & Pointer")
					}

					StyledText {
						Layout.fillWidth: true
						text: {
							if (root.currentIcon || root.currentCursor) {
								const parts = [];
								if (root.currentIcon)
									parts.push(String(root.currentIcon.name || root.currentIcon.id));
								if (root.currentCursor)
									parts.push(String(root.currentCursor.name || root.currentCursor.id));
								return parts.join("  ·  ");
							}
							return root.listLoading ? "Loading…" : "Nothing installed";
						}
						font.pixelSize: Theme.size.heading
						font.weight: Font.Bold
					}
				}

				TextButton {
					implicitHeight: 42
					text: root.applying ? "Applying" : (root.pending ? "Apply" : "Active")
					icon: "check"
					variant: "filled"
					busy: root.applying
					enabled: root.currentIcon !== null || root.currentCursor !== null
					onActivated: root.apply()
				}

				IconButton {
					icon: "close"
					variant: "tonal"
					onClicked: Popups.closeModal()
				}
			}

			// ── columns ───────────────────────────────────────────────────
			RowLayout {
				id: body

				Layout.fillWidth: true
				Layout.fillHeight: true
				spacing: 22

				// icons
				ColumnLayout {
					Layout.preferredWidth: Math.round((panel.width - 44 - 22) * 0.58)
					Layout.fillWidth: false
					Layout.fillHeight: true
					spacing: 12

					ColumnHeader {
						icon: "apps"
						title: Words.of("dress.icons", "Icons")
						count: root.iconThemes.length
						active: root.column === "icons"
					}

					Item {
						Layout.fillWidth: true
						Layout.fillHeight: true

						Spinner {
							anchors.centerIn: parent
							width: 28
							height: 28
							visible: root.listLoading && root.iconThemes.length === 0
						}

						EmptyState {
							anchors.centerIn: parent
							visible: !root.listLoading && root.iconThemes.length === 0
							icon: "apps"
							title: "No icon themes"
						}

						Flickable {
							id: iconFlick

							anchors.fill: parent
							contentWidth: width
							contentHeight: iconColumn.height
							boundsBehavior: Flickable.StopAtBounds
							clip: true
							ScrollBar.vertical: ThinScrollBar {}

							Behavior on contentY {
								enabled: !iconFlick.moving
								SpatialAnim {
									duration: Motion.medium
								}
							}

							Column {
								id: iconColumn

								width: iconFlick.width
								spacing: root.rowGap

								Repeater {
									model: root.iconThemes

									delegate: RowCard {
										id: iconRow

										required property var modelData
										required property int index

										readonly property bool live: String(iconRow.modelData.id) === root.liveIcon

										width: iconColumn.width
										height: root.rowHeight
										selected: iconRow.index === root.iconIndex
										focused: root.column === "icons"
										onActivated: {
											const again = iconRow.selected && root.column === "icons";
											root.column = "icons";
											if (again)
												root.apply();
											else
												root.selectIcon(iconRow.index);
										}

										RowLayout {
											anchors.fill: parent
											spacing: 14

											NameBlock {
												name: String(iconRow.modelData.name || iconRow.modelData.id)
												comment: String(iconRow.modelData.comment || "")
												selected: iconRow.selected
												live: iconRow.live
											}

											Rectangle {
												Layout.preferredHeight: 54
												Layout.preferredWidth: sampleRow.implicitWidth + 20
												radius: Theme.radius.large
												color: Qt.alpha(Theme.bg, 0.8)

												Row {
													id: sampleRow

													anchors.centerIn: parent
													spacing: 10

													Repeater {
														model: iconRow.modelData.samples || []

														delegate: Image {
															required property string modelData

															width: 34
															height: 34
															source: `file://${modelData}`
															sourceSize: Qt.size(68, 68)
															fillMode: Image.PreserveAspectFit
															smooth: true
															mipmap: true
															asynchronous: true
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

				// pointer
				ColumnLayout {
					Layout.fillWidth: true
					Layout.fillHeight: true
					spacing: 12

					ColumnHeader {
						icon: "cursor_default_outline"
						title: Words.of("dress.pointer", "Pointer")
						count: root.cursorThemes.length
						active: root.column === "cursors"
					}

					Item {
						Layout.fillWidth: true
						Layout.fillHeight: true

						Spinner {
							anchors.centerIn: parent
							width: 28
							height: 28
							visible: root.listLoading && root.cursorThemes.length === 0
						}

						EmptyState {
							anchors.centerIn: parent
							visible: !root.listLoading && root.cursorThemes.length === 0
							icon: "cursor_default_outline"
							title: "No cursor themes"
						}

						Flickable {
							id: cursorFlick

							anchors.fill: parent
							contentWidth: width
							contentHeight: cursorColumn.height
							boundsBehavior: Flickable.StopAtBounds
							clip: true
							ScrollBar.vertical: ThinScrollBar {}

							Behavior on contentY {
								enabled: !cursorFlick.moving
								SpatialAnim {
									duration: Motion.medium
								}
							}

							Column {
								id: cursorColumn

								width: cursorFlick.width
								spacing: root.rowGap

								Repeater {
									model: root.cursorThemes

									delegate: RowCard {
										id: cursorRow

										required property var modelData
										required property int index

										readonly property bool live: String(cursorRow.modelData.id) === root.liveCursor
										readonly property string preview: String(cursorRow.modelData.preview || "")

										width: cursorColumn.width
										height: root.rowHeight
										selected: cursorRow.index === root.cursorIndex
										focused: root.column === "cursors"
										onActivated: {
											const again = cursorRow.selected && root.column === "cursors";
											root.column = "cursors";
											if (again)
												root.apply();
											else
												root.selectCursor(cursorRow.index);
										}

										RowLayout {
											anchors.fill: parent
											anchors.leftMargin: -6
											spacing: 14

											Rectangle {
												Layout.preferredWidth: 54
												Layout.preferredHeight: 54
												radius: Theme.radius.large
												color: Qt.alpha(Theme.bg, 0.8)

												Image {
													anchors.centerIn: parent
													width: 32
													height: 32
													visible: cursorRow.preview !== ""
													source: cursorRow.preview !== "" ? `file://${cursorRow.preview}` : ""
													sourceSize: Qt.size(64, 64)
													fillMode: Image.PreserveAspectFit
													smooth: true
													asynchronous: true
												}

												Glyph {
													anchors.centerIn: parent
													visible: cursorRow.preview === ""
													icon: "cursor_default_outline"
													size: 24
													color: cursorRow.selected ? Theme.primary : Theme.textMuted
												}
											}

											NameBlock {
												name: String(cursorRow.modelData.name || cursorRow.modelData.id)
												comment: String(cursorRow.modelData.comment || "")
												selected: cursorRow.selected
												live: cursorRow.live
											}
										}
									}
								}
							}
						}
					}

					// size
					Rectangle {
						Layout.fillWidth: true
						Layout.preferredHeight: 96
						radius: Theme.radius.huge
						color: Theme.layer1

						RowLayout {
							anchors.fill: parent
							anchors.margins: 14
							spacing: 14

							Rectangle {
								Layout.preferredWidth: 68
								Layout.preferredHeight: 68
								radius: Theme.radius.large
								color: Qt.alpha(Theme.bg, 0.8)
								clip: true

								Image {
									anchors.centerIn: parent
									width: Math.min(64, root.selectedSize)
									height: width
									visible: root.currentCursorPreview !== ""
									source: root.currentCursorPreview !== "" ? `file://${root.currentCursorPreview}` : ""
									sourceSize: Qt.size(128, 128)
									fillMode: Image.PreserveAspectFit
									smooth: true
									asynchronous: true

									Behavior on width {
										SpatialAnim {
											duration: Motion.medium
										}
									}
								}

								Glyph {
									anchors.centerIn: parent
									visible: root.currentCursorPreview === ""
									icon: "cursor_default_outline"
									size: Math.min(64, root.selectedSize)
									color: Theme.text

									Behavior on size {
										SpatialAnim {
											duration: Motion.medium
										}
									}
								}
							}

							ColumnLayout {
								Layout.fillWidth: true
								spacing: 8

								SectionLabel {
									text: "Size"
								}

								Segmented {
									Layout.fillWidth: true
									options: root.sizeOptions.map(size => ({ value: String(size), label: String(size) }))
									current: String(root.selectedSize)
									onSelected: value => {
										root.selectedSize = Number(value);
										root.clearStatus();
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
				spacing: 14

				KeyHint { keys: "↑↓"; label: "choose" }
				KeyHint { keys: "←→"; label: "column" }
				KeyHint { keys: "+−"; label: "size" }
				KeyHint { keys: "↵"; label: "apply" }
				KeyHint { keys: "click ×2"; label: "apply" }
				KeyHint { keys: "Esc"; label: "close" }

				Item {
					Layout.fillWidth: true
				}

				RowLayout {
					visible: root.statusKind !== ""
					spacing: 6

					Glyph {
						icon: root.statusKind === "error" ? "alert_circle" : "check_circle"
						size: 15
						color: root.statusKind === "error" ? Theme.danger : Theme.success
					}

					StyledText {
						Layout.maximumWidth: panel.width * 0.35
						text: root.statusText
						tone: root.statusKind === "error" ? Theme.danger : Theme.success
						font.pixelSize: Theme.size.small
						font.weight: Font.DemiBold
					}
				}

				RowLayout {
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
