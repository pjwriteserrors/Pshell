pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import "components"

// Studio's combinations page: a whole look, saved under a name.
//
// Every other page changes one thing — the wallpaper, the motion, the icons,
// the style branch. This one keeps the *set*: what all of them were at once.
// Put a look together across the other pages, come here, keep it, and it can
// be worn again in one action however far you wander afterwards.
//
// The work is in `scripts/combinations.py`. Combinations are stored outside
// the style branch on purpose: a combination names a branch, so keeping it
// inside one would lose the lot on the first switch.
//
// If you are writing a new style: keep this page and keep it calling that
// script, so combinations saved under one style still work under the next.
Item {
	id: root

	signal closeRequested

	required property color foreground
	required property color background
	required property color secondaryBoxColor
	required property color secondaryBoxStrongColor
	required property color secondaryInsetColor
	required property color barColor
	property color danger: Arc.bane

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
			{ label: "Marks", value: String(entry.icons || ""), live: String(state.icons || "") === String(entry.icons || "") },
			{ label: "Pointer", value: String(entry.cursor || "") + (entry.cursorSize ? ` · ${entry.cursorSize} px` : ""), live: String(state.cursor || "") === String(entry.cursor || "") },
			{ label: "Style", value: String(entry.branch || ""), live: String(state.branch || "") === String(entry.branch || "") }
		].filter(part => part.value !== "");
	}

	readonly property bool selectedWorn: {
		const parts = root.partsOf(root.selected);
		if (parts.length === 0) return false;
		for (const part of parts) {
			if (!part.live) return false;
		}
		return true;
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

	// --------------------------------------------------------------- the list
	ArcText {
		id: listHeading
		anchors.left: parent.left
		anchors.top: parent.top
		role: "label"
		tone: "muted"
		text: root.busy ? "Reading…" : `${root.combinations.length} kept`
	}

	ListView {
		id: combinationList

		anchors.left: parent.left
		anchors.top: listHeading.bottom
		anchors.topMargin: Arc.s3
		anchors.bottom: keepRow.top
		anchors.bottomMargin: Arc.s5
		width: Math.round(Math.min(parent.width * 0.34, 340))
		clip: true
		model: root.combinations
		currentIndex: root.selectedIndex
		boundsBehavior: Flickable.StopAtBounds

		delegate: Item {
			id: comboRow

			required property var modelData
			required property int index

			readonly property bool selected: root.selectedIndex === comboRow.index

			width: combinationList.width
			height: 42

			Rectangle {
				anchors.left: parent.left
				anchors.verticalCenter: parent.verticalCenter
				width: Arc.rule * 1.6
				height: parent.height * (comboRow.selected ? 0.62 : 0)
				radius: width / 2
				color: Arc.aether
				opacity: comboRow.selected ? 1 : 0

				Behavior on height {
					NumberAnimation { duration: Arc.turn; easing.type: Easing.OutCubic }
				}
			}

			Column {
				anchors.left: parent.left
				anchors.leftMargin: Arc.s4
				anchors.right: parent.right
				anchors.rightMargin: Arc.s3
				anchors.verticalCenter: parent.verticalCenter
				spacing: -2

				ArcText {
					width: parent.width
					role: "heading"
					font.pixelSize: 14
					tone: comboRow.selected ? "default" : "muted"
					text: String(comboRow.modelData.name || "")
				}

				ArcText {
					width: parent.width
					role: "caption"
					tone: "faint"
					text: [
						String(comboRow.modelData.themeName || ""),
						String(comboRow.modelData.animation || "").split(":").pop(),
						String(comboRow.modelData.branch || "").split("/").pop()
					].filter(v => v !== "").join(" · ")
				}
			}

			ArcTouch {
				onEntered: root.selectedIndex = comboRow.index
				onClicked: root.selectedIndex = comboRow.index
				onDoubleClicked: root.wear()
			}
		}
	}

	// Keeping what is on now: the one place this page writes anything.
	Item {
		id: keepRow

		anchors.left: parent.left
		anchors.bottom: parent.bottom
		width: combinationList.width
		height: 34

		TextField {
			id: nameField

			anchors.left: parent.left
			anchors.right: keepLabel.left
			anchors.rightMargin: Arc.s3
			anchors.verticalCenter: parent.verticalCenter
			height: 28
			font.family: Arc.book
			font.pixelSize: Arc.sizeCaption
			color: Arc.ink
			placeholderText: "Keep what is on as…"
			placeholderTextColor: Arc.inkFaint
			selectedTextColor: Arc.ink
			selectionColor: Qt.alpha(Arc.aether, 0.3)
			onAccepted: root.keep(text)

			background: Item {
				Rectangle {
					anchors.left: parent.left
					anchors.right: parent.right
					anchors.bottom: parent.bottom
					height: Arc.ruleThin
					color: Arc.goldFaint
				}

				Rectangle {
					anchors.left: parent.left
					anchors.bottom: parent.bottom
					width: nameField.activeFocus ? parent.width : 0
					height: Arc.rule
					color: Arc.aether

					Behavior on width {
						NumberAnimation { duration: Arc.turn; easing.type: Easing.OutCubic }
					}
				}
			}
		}

		ArcText {
			id: keepLabel
			anchors.right: parent.right
			anchors.verticalCenter: parent.verticalCenter
			role: "label"
			tone: keepTouch.containsMouse && nameField.text.trim() !== "" ? "aether" : "faint"
			text: "Keep"

			ArcTouch {
				id: keepTouch
				anchors.margins: -Arc.s2
				enabled: nameField.text.trim() !== ""
				onClicked: root.keep(nameField.text)
			}
		}
	}

	Rectangle {
		id: comboRule
		anchors.left: combinationList.right
		anchors.leftMargin: Arc.s6
		anchors.top: parent.top
		anchors.bottom: parent.bottom
		anchors.topMargin: Arc.s3
		anchors.bottomMargin: Arc.s3
		width: Arc.ruleThin
		color: Arc.goldGhost
	}

	// ----------------------------------------------------------- the specimen
	Item {
		id: specimen

		anchors.left: comboRule.right
		anchors.leftMargin: Arc.s7
		anchors.right: parent.right
		anchors.top: parent.top
		anchors.bottom: parent.bottom
		opacity: root.selected ? 1 : 0

		Behavior on opacity {
			NumberAnimation { duration: Arc.turn }
		}

		ArcText {
			id: specimenName
			anchors.left: parent.left
			anchors.top: parent.top
			role: "display"
			font.pixelSize: 30
			text: root.selected ? String(root.selected.name || "") : ""
		}

		ArcText {
			id: specimenNote
			anchors.left: parent.left
			anchors.right: parent.right
			anchors.top: specimenName.bottom
			anchors.topMargin: Arc.s2
			role: "body"
			tone: "muted"
			visible: text !== ""
			text: root.selected ? String(root.selected.note || "") : ""
		}

		// What the combination is made of, part by part, with the parts the
		// desktop is already wearing marked.
		Column {
			id: partList

			anchors.left: parent.left
			anchors.right: parent.right
			anchors.top: specimenNote.visible ? specimenNote.bottom : specimenName.bottom
			anchors.topMargin: Arc.s6
			spacing: Arc.s2

			Repeater {
				model: root.partsOf(root.selected)

				delegate: Item {
					id: partRow
					required property var modelData

					width: partList.width
					height: 30

					ArcText {
						id: partLabel
						anchors.left: parent.left
						anchors.verticalCenter: parent.verticalCenter
						width: 96
						role: "label"
						tone: "faint"
						text: String(partRow.modelData.label)
					}

					ArcText {
						anchors.left: partLabel.right
						anchors.leftMargin: Arc.s3
						anchors.right: partMark.left
						anchors.rightMargin: Arc.s3
						anchors.verticalCenter: parent.verticalCenter
						role: "body"
						tone: partRow.modelData.live ? "default" : "muted"
						text: String(partRow.modelData.value)
					}

					// Already on, or waiting.
					Rectangle {
						id: partMark
						anchors.right: parent.right
						anchors.verticalCenter: parent.verticalCenter
						width: Arc.mote * 2
						height: Arc.mote * 2
						radius: width / 2
						color: partRow.modelData.live ? Arc.ward : Arc.goldGhost
					}

					Rectangle {
						anchors.left: partLabel.left
						anchors.right: parent.right
						anchors.bottom: parent.bottom
						height: Arc.ruleThin
						color: Arc.goldGhost
						opacity: 0.6
					}
				}
			}
		}

		ArcText {
			id: noticeLabel
			anchors.left: parent.left
			anchors.bottom: parent.bottom
			anchors.bottomMargin: Arc.s3
			role: "caption"
			tone: "faint"
			text: root.notice
		}

		Row {
			anchors.right: parent.right
			anchors.bottom: parent.bottom
			anchors.bottomMargin: Arc.s3
			spacing: Arc.s6

			ArcText {
				role: "label"
				tone: replaceTouch.containsMouse ? "aether" : "faint"
				text: "Replace"

				ArcTouch {
					id: replaceTouch
					anchors.margins: -Arc.s2
					onClicked: {
						if (root.selected) root.keep(String(root.selected.name));
					}
				}
			}

			ArcText {
				role: "label"
				tone: discardTouch.containsMouse ? "alert" : "faint"
				text: "Discard"

				ArcTouch {
					id: discardTouch
					anchors.margins: -Arc.s2
					onClicked: root.discard()
				}
			}

			ArcText {
				role: "label"
				tone: wearTouch.containsMouse ? "aether" : "muted"
				text: root.selectedWorn ? "Worn" : "Wear"

				ArcTouch {
					id: wearTouch
					anchors.margins: -Arc.s2
					onClicked: root.wear()
				}
			}
		}
	}

	// Nothing kept yet.
	Column {
		anchors.centerIn: specimen
		visible: !root.selected && !root.busy
		spacing: Arc.s3

		ArcRune {
			anchors.horizontalCenter: parent.horizontalCenter
			width: 54
			height: 54
			seed: 11
			lineColor: Arc.goldGhost
		}

		ArcText {
			anchors.horizontalCenter: parent.horizontalCenter
			role: "heading"
			tone: "muted"
			text: "Nothing kept yet"
		}

		ArcText {
			anchors.horizontalCenter: parent.horizontalCenter
			role: "caption"
			tone: "faint"
			text: "Name what is on now and keep it"
		}
	}
}
