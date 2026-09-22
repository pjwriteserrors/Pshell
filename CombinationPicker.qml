pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "components"

// Studio's combinations page: a whole look, saved under a name.
//
// Every other page changes one thing - the wallpaper, the motion, the icons,
// the style branch. This one keeps the *set*: what all of them were at once.
// The kept looks hang from a thread on the left; the chosen one's parts are
// short wires on the right, each lit when that part is what the desktop is
// wearing right now.
//
// The work is in `scripts/combinations.py`. Combinations are stored outside
// the style branch on purpose: a combination names a branch, so keeping them
// inside one would lose the lot on the first switch. See STUDIO.md.
FocusScope {
	id: root

	signal closeRequested

	required property color foreground
	required property color background
	required property color secondaryBoxColor
	required property color secondaryBoxStrongColor
	required property color secondaryInsetColor
	required property color barColor
	required property color danger
	property real reveal: 1

	property var combinations: []
	property var currentState: ({})
	property int selectedIndex: 0
	property bool busy: false
	property string notice: ""

	readonly property string scriptPath: `${Quickshell.shellDir}/scripts/combinations.py`
	readonly property var selected: root.combinations.length > 0
		? root.combinations[Math.max(0, Math.min(root.combinations.length - 1, root.selectedIndex))]
		: null

	// A combination is "worn" when every part it names matches what is on.
	function partsOf(entry) {
		if (!entry) return [];
		const state = root.currentState || ({});
		return [
			{ label: "Wallpaper", value: String(entry.themeName || entry.theme || ""), live: String(state.theme || "") === String(entry.theme || "") },
			{ label: "Palette", value: [entry.backend, entry.palette, entry.style].filter(v => String(v || "") !== "").join(" · "), live: String(state.palette || "") === String(entry.palette || "") && String(state.style || "") === String(entry.style || "") },
			{ label: "Motion", value: String(entry.animation || ""), live: String(state.animation || "") === String(entry.animation || "") },
			{ label: "Icons", value: String(entry.icons || ""), live: String(state.icons || "") === String(entry.icons || "") },
			{ label: "Pointer", value: String(entry.cursor || "") + (entry.cursorSize ? ` · ${entry.cursorSize} px` : ""), live: String(state.cursor || "") === String(entry.cursor || "") },
			{ label: "Style", value: String(entry.branch || ""), live: String(state.branch || "") === String(entry.branch || "") }
		].filter(part => part.value !== "");
	}

	readonly property var selectedParts: root.partsOf(root.selected)
	readonly property bool selectedWorn: {
		const parts = root.selectedParts;
		if (parts.length === 0) return false;
		for (const part of parts) {
			if (!part.live) return false;
		}
		return true;
	}

	function subtitleOf(entry) {
		return [
			String(entry?.themeName || ""),
			String(entry?.animation || "").split(":").pop(),
			String(entry?.branch || "").split("/").pop()
		].filter(v => v !== "").join(" · ");
	}

	focus: true

	function reset() {
		root.reload();
		Qt.callLater(function () {
			root.forceActiveFocus();
		});
	}

	function reload() {
		root.busy = true;
		listProcess.running = true;
	}

	function move(delta) {
		if (root.combinations.length === 0) return;
		root.selectedIndex = Math.max(0, Math.min(root.combinations.length - 1, root.selectedIndex + delta));
		combinationList.positionViewAtIndex(root.selectedIndex, ListView.Contain);
	}

	function wear() {
		if (!root.selected) return;
		root.notice = `Wearing ${root.selected.name}…`;
		Quickshell.execDetached(["python3", root.scriptPath, "apply", "--name", String(root.selected.name)]);
	}

	function keep(name) {
		const trimmed = String(name || "").trim();
		if (trimmed === "") return;
		root.busy = true;
		captureProcess.command = ["python3", root.scriptPath, "capture", "--name", trimmed];
		captureProcess.running = true;
		root.notice = `Kept ${trimmed}`;
		nameField.text = "";
	}

	function discard() {
		if (!root.selected) return;
		root.busy = true;
		deleteProcess.command = ["python3", root.scriptPath, "delete", "--name", String(root.selected.name)];
		deleteProcess.running = true;
	}

	Component.onCompleted: root.reset()
	Keys.onEscapePressed: root.closeRequested()
	Keys.onUpPressed: root.move(-1)
	Keys.onDownPressed: root.move(1)
	Keys.onReturnPressed: root.wear()
	Keys.onEnterPressed: root.wear()

	Process {
		id: listProcess
		command: ["python3", root.scriptPath, "list"]

		stdout: StdioCollector {
			onStreamFinished: {
				try {
					const parsed = JSON.parse(String(text || "{}"));
					root.combinations = parsed.combinations || [];
					root.currentState = parsed.current || ({});
				} catch (error) {
					root.combinations = [];
				}
				root.busy = false;
				if (root.selectedIndex >= root.combinations.length)
					root.selectedIndex = Math.max(0, root.combinations.length - 1);
			}
		}
	}

	Process {
		id: captureProcess
		onExited: root.reload()
	}

	Process {
		id: deleteProcess
		onExited: root.reload()
	}

	// ------------------------------------------------------------ the head
	Band {
		id: head
		reveal: root.reveal
		order: 0
		width: parent.width
		height: 30

		FText {
			anchors.left: parent.left
			anchors.verticalCenter: parent.verticalCenter
			text: "kept looks"
			caps: true
			tone: "mute"
			font.pixelSize: Filament.textXs
		}

		FText {
			anchors.left: parent.left
			anchors.leftMargin: 90
			anchors.verticalCenter: parent.verticalCenter
			text: root.busy ? "Reading…" : `${root.combinations.length} kept. A combination applies only the parts it names.`
			tone: "soft"
			font.pixelSize: Filament.textSm
		}

		Row {
			anchors.right: parent.right
			anchors.verticalCenter: parent.verticalCenter
			spacing: 8
			FText { anchors.verticalCenter: parent.verticalCenter; text: "on now"; caps: true; tone: "faint"; font.pixelSize: Filament.textXs }
			FText {
				anchors.verticalCenter: parent.verticalCenter
				text: [root.currentState?.themeName, String(root.currentState?.animation || "").split(":").pop(), root.currentState?.branch].filter(v => String(v || "") !== "").join(" · ")
				mono: true
				tone: "charge"
				font.pixelSize: Filament.textSm
			}
		}
	}

	// ------------------------------------------------------------ the body
	Item {
		id: body
		anchors.top: head.bottom
		anchors.topMargin: 16
		anchors.bottom: verbs.top
		anchors.bottomMargin: 20
		width: parent.width

		readonly property real listWidth: Math.min(width * 0.38, 400)
		readonly property real rowHeight: 50

		// The thread the kept looks hang from.
		Band {
			reveal: root.reveal
			order: 1
			x: 0
			y: 0
			width: body.listWidth
			height: body.height
			implicitHeight: 0

			ThreadLine {
				id: thread
				x: 8
				y: 0
				height: parent.height
				litY: root.combinations.length > 0
					? root.selectedIndex * body.rowHeight + body.rowHeight / 2 - combinationList.contentY
					: -1
				litLength: body.rowHeight
			}

			ListView {
				id: combinationList
				x: 9
				y: 0
				width: parent.width - 9
				height: parent.height
				clip: true
				model: root.combinations
				spacing: 0
				boundsBehavior: Flickable.StopAtBounds
				currentIndex: root.selectedIndex

				delegate: ThreadRow {
					id: row
					required property var modelData
					required property int index
					width: combinationList.width
					height: body.rowHeight
					selected: root.selectedIndex === row.index
					onClicked: {
						root.forceActiveFocus();
						root.selectedIndex = row.index;
					}
					onDoubleClicked: root.wear()

					Column {
						anchors.left: parent.left
						anchors.right: parent.right
						anchors.rightMargin: 12
						anchors.verticalCenter: parent.verticalCenter
						spacing: 2
						FText {
							width: parent.width
							text: row.modelData?.name ?? ""
							tone: row.selected ? "ink" : "soft"
							font.pixelSize: Filament.textMd
							font.weight: row.selected ? Font.DemiBold : Font.Medium
						}
						FText {
							width: parent.width
							text: root.subtitleOf(row.modelData)
							mono: true
							tone: "faint"
							font.pixelSize: Filament.textXs
						}
					}
				}
			}

			// Empty: nothing kept yet.
			Column {
				anchors.centerIn: parent
				width: parent.width - 40
				spacing: 6
				visible: !root.selected && !root.busy
				FText {
					width: parent.width
					horizontalAlignment: Text.AlignHCenter
					text: "Nothing kept yet"
					font.pixelSize: Filament.textLg
					font.weight: Font.DemiBold
				}
				FText {
					width: parent.width
					horizontalAlignment: Text.AlignHCenter
					text: "Set the desktop up across the other pages, then name what is on now and keep it."
					tone: "mute"
					font.pixelSize: Filament.textSm
					wrapMode: Text.WordWrap
				}
			}
		}

		// The chosen look, part by part.
		Band {
			reveal: root.reveal
			order: 2
			x: body.listWidth + 48
			y: 0
			width: body.width - x
			height: body.height
			implicitHeight: 0
			visible: !!root.selected

			Column {
				width: parent.width
				spacing: 8

				Row {
					spacing: 12
					height: 40
					FText {
						anchors.verticalCenter: parent.verticalCenter
						text: root.selected?.name ?? ""
						font.pixelSize: Filament.textDisplay
						font.weight: Font.DemiBold
					}
					Chip {
						anchors.verticalCenter: parent.verticalCenter
						text: root.selectedWorn ? "worn" : "kept"
						lit: root.selectedWorn
						mono: false
					}
				}

				FText {
					text: root.selected?.savedAt ? "kept " + Qt.formatDateTime(new Date(Number(root.selected.savedAt) * 1000), "d MMM yyyy, HH:mm") : ""
					visible: text !== ""
					mono: true
					tone: "faint"
					font.pixelSize: Filament.textXs
				}

				Item { width: 1; height: 8 }

				Repeater {
					model: root.selectedParts

					Item {
						id: part
						required property var modelData
						required property int index
						width: parent.width
						height: 44

						FText {
							x: 0; y: 0
							width: 90
							text: part.modelData?.label ?? ""
							caps: true
							tone: part.modelData?.live ? "charge" : "mute"
							font.pixelSize: Filament.textXs
						}
						FText {
							x: 90; y: -2
							width: parent.width - 120
							text: part.modelData?.value ?? ""
							mono: true
							tone: part.modelData?.live ? "ink" : "soft"
							font.pixelSize: Filament.textMd
						}
						FText {
							anchors.right: parent.right
							y: 0
							text: part.modelData?.live ? "live" : "not on"
							caps: true
							tone: part.modelData?.live ? "charge" : "faint"
							font.pixelSize: Filament.textXs
						}
						Wire {
							x: 0
							y: 26
							width: parent.width
							height: 2
							cold: Filament.wireDim
							lit: part.modelData?.live ? 1 : 0
						}
						Spark {
							anchors.right: parent.right
							anchors.rightMargin: -3
							y: 26 - size / 2 + 1
							size: 6
							visible: part.modelData?.live ?? false
						}
					}
				}

				Item { width: 1; height: 6 }

				FText {
					width: parent.width
					text: root.notice
					visible: text !== ""
					tone: "charge"
					font.pixelSize: Filament.textSm
				}
			}
		}
	}

	// ----------------------------------------------------------- the verbs
	Band {
		id: verbs
		reveal: root.reveal
		order: 3
		anchors.bottom: parent.bottom
		width: parent.width
		height: 40

		FField {
			id: nameField
			anchors.left: parent.left
			anchors.right: keepButton.left
			anchors.rightMargin: 16
			anchors.verticalCenter: parent.verticalCenter
			placeholder: "Keep what is on now as…"
			icon: "bookmark-new-symbolic"
			onAccepted: root.keep(text)
			onEscaped: root.closeRequested()
		}

		FButton {
			id: keepButton
			anchors.right: replaceButton.left
			anchors.rightMargin: 8
			anchors.verticalCenter: parent.verticalCenter
			text: "Keep"
			enabled: nameField.text.trim() !== "" && !root.busy
			onClicked: root.keep(nameField.text)
		}

		FButton {
			id: replaceButton
			anchors.right: discardButton.left
			anchors.rightMargin: 8
			anchors.verticalCenter: parent.verticalCenter
			text: "Replace"
			tooltip: "Keep what is on now under this name"
			enabled: !!root.selected && !root.busy
			onClicked: {
				root.forceActiveFocus();
				root.keep(root.selected.name);
			}
		}

		HoldButton {
			id: discardButton
			anchors.right: wearButton.left
			anchors.rightMargin: 8
			anchors.verticalCenter: parent.verticalCenter
			text: "Discard"
			icon: "user-trash-symbolic"
			enabled: !!root.selected && !root.busy
			onHeld: {
				root.forceActiveFocus();
				root.discard();
			}
		}

		FButton {
			id: wearButton
			anchors.right: parent.right
			anchors.verticalCenter: parent.verticalCenter
			text: root.selectedWorn ? "Worn" : "Wear"
			kind: "charge"
			enabled: !!root.selected
			onClicked: {
				root.forceActiveFocus();
				root.wear();
			}
		}
	}
}
