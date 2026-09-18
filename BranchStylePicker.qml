pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import "components"

// Styles page of Studio. A style is a local Git branch of this configuration:
// checking one out swaps the whole shell at once.
//
// Keyboard: arrows move, Enter applies (twice - once to arm, once to confirm),
// Escape steps back out of the confirmation and then closes Studio.
// Mouse: click selects, double-click applies, the button applies.
Item {
	id: root

	signal closeRequested

	required property color foreground
	required property color background
	required property color secondaryBoxColor
	required property color secondaryBoxStrongColor
	required property color secondaryInsetColor
	required property color barColor
	property color danger: "#df817b"

	property var entries: []
	property string currentBranch: ""
	property bool dirty: false
	property string errorText: ""
	property string chosenBranch: ""
	property bool confirming: false
	property bool switching: false

	readonly property string script: `${Quickshell.shellDir}/scripts/branch_styles.py`
	readonly property var usable: root.entries.filter(entry => entry.compatible)
	readonly property var selected: root.entries.find(entry => entry.branch === root.chosenBranch) || null
	readonly property bool canApply: !!root.selected && !root.dirty && root.selected.compatible
		&& !root.selected.current && !root.switching

	function refresh() {
		if (!catalog.running) catalog.running = true;
	}

	function choose(branch) {
		root.chosenBranch = branch;
		root.confirming = false;
	}

	function move(delta) {
		if (root.usable.length === 0) return;
		let index = root.usable.findIndex(entry => entry.branch === root.chosenBranch);
		if (index < 0) index = 0;
		const next = Math.max(0, Math.min(root.usable.length - 1, index + delta));
		root.choose(root.usable[next].branch);
	}

	// Two presses: the first arms, the second commits. Switching replaces every
	// window on the desktop, which is not something to trigger by accident.
	function apply() {
		if (!root.canApply) return;
		if (!root.confirming) {
			root.confirming = true;
			return;
		}
		root.switching = true;
		root.errorText = "";
		Quickshell.execDetached(["python3", root.script, "switch", root.chosenBranch]);
	}

	focus: true
	Component.onCompleted: root.refresh()

	Keys.onEscapePressed: event => {
		event.accepted = true;
		if (root.confirming) root.confirming = false;
		else root.closeRequested();
	}
	Keys.onReturnPressed: root.apply()
	Keys.onEnterPressed: root.apply()
	Keys.onLeftPressed: root.move(-1)
	Keys.onRightPressed: root.move(1)
	Keys.onUpPressed: root.move(-library.columns)
	Keys.onDownPressed: root.move(library.columns)

	Process {
		id: catalog
		command: ["python3", root.script, "catalog"]

		stdout: StdioCollector {
			onStreamFinished: {
				try {
					const data = JSON.parse(text);
					root.entries = data.branches;
					root.currentBranch = data.current;
					root.dirty = data.dirty;
					root.errorText = data.message || "";
					if (!root.chosenBranch) root.chosenBranch = data.current;
					if (root.errorText) root.switching = false;
				} catch (error) {
					root.errorText = String(error);
				}
			}
		}

		stderr: StdioCollector {
			onStreamFinished: if (text.trim()) root.errorText = text.trim();
		}
	}

	// While a switch is running the shell reloads underneath this window, so
	// polling is only about surfacing an error that the switcher wrote out.
	Timer {
		interval: root.switching ? 600 : 2500
		repeat: true
		running: root.visible
		onTriggered: root.refresh()
	}

	Column {
		anchors.fill: parent
		anchors.margins: 6
		spacing: 14

		BioText {
			role: "title"
			text: "Style"
			color: root.foreground
			font.family: "C059"
			font.pixelSize: 34
		}

		BioText {
			role: "body"
			width: parent.width
			text: "One branch, one complete desktop.   Current: " + root.currentBranch
			color: root.foreground
			opacity: 0.65
			font.pixelSize: 12
			elide: Text.ElideMiddle
		}

		GridView {
			id: library

			readonly property int columns: Math.max(1, Math.floor(width / 310))

			width: parent.width
			height: Math.max(120, parent.height - 210)
			clip: true
			model: root.entries
			cellWidth: width / library.columns
			cellHeight: 190
			currentIndex: root.entries.findIndex(entry => entry.branch === root.chosenBranch)
			highlightMoveDuration: Motion.fast
			keyNavigationEnabled: false

			onCurrentIndexChanged: library.positionViewAtIndex(library.currentIndex, GridView.Contain)

			delegate: Item {
				id: entry

				required property var modelData
				readonly property bool chosen: root.chosenBranch === entry.modelData.branch

				width: library.cellWidth
				height: library.cellHeight

				Rectangle {
					anchors.fill: parent
					anchors.margins: 7
					radius: ThemeEngine.radiusLarge
					color: entry.chosen
						? root.secondaryBoxStrongColor
						: entryMouse.containsMouse ? root.secondaryBoxColor : Qt.alpha(root.secondaryBoxColor, 0.45)
					border.width: entry.chosen ? 1 : 0
					border.color: root.barColor
					opacity: entry.modelData.compatible ? 1 : 0.45

					Behavior on color {
						CAnim {}
					}

					Column {
						anchors.fill: parent
						anchors.margins: 22
						spacing: 8

						BioText {
							role: "label"
							text: entry.modelData.current ? "●  ACTIVE"
								: entry.modelData.compatible ? "○  STYLE BRANCH" : "–  NOT A STYLE"
							color: root.foreground
							opacity: 0.65
							font.family: "Adwaita Mono"
							font.pixelSize: 10
						}

						BioText {
							role: "title"
							width: parent.width
							text: entry.modelData.name
							color: root.foreground
							font.family: "C059"
							font.pixelSize: 32
							elide: Text.ElideRight
						}

						BioText {
							role: "caption"
							width: parent.width
							text: entry.modelData.branch
							color: root.foreground
							opacity: 0.6
							font.family: "Adwaita Mono"
							font.pixelSize: 11
							elide: Text.ElideMiddle
						}

						BioText {
							role: "caption"
							width: parent.width
							text: entry.modelData.description || ""
							visible: text !== ""
							color: root.foreground
							opacity: 0.55
							font.pixelSize: 11
							wrapMode: Text.WordWrap
							maximumLineCount: 2
							elide: Text.ElideRight
						}
					}

					MouseArea {
						id: entryMouse
						anchors.fill: parent
						hoverEnabled: true
						cursorShape: entry.modelData.compatible ? Qt.PointingHandCursor : Qt.ArrowCursor
						onClicked: {
							if (!entry.modelData.compatible) return;
							root.choose(entry.modelData.branch);
							root.forceActiveFocus();
						}
						onDoubleClicked: {
							if (!entry.modelData.compatible) return;
							root.choose(entry.modelData.branch);
							root.forceActiveFocus();
							root.apply();
							root.apply();
						}
					}
				}
			}

			ScrollBar.vertical: ScrollBar {}
		}

		BioText {
			role: "body"
			width: parent.width
			wrapMode: Text.WordWrap
			color: root.dirty || root.errorText ? root.danger : root.foreground
			opacity: root.dirty || root.errorText ? 1 : 0.7
			font.pixelSize: 12
			text: {
				if (root.errorText) return root.errorText;
				if (root.dirty) return "Uncommitted changes: commit or move them before switching. Nothing will be discarded.";
				if (root.confirming) return "Check out " + root.chosenBranch + " and reload the shell? Press Enter again to confirm.";
				return "Local branches only. No stash, no reset, no downloads - and the shell reloads in place instead of restarting.";
			}
		}

		Rectangle {
			width: parent.width
			height: 44
			radius: ThemeEngine.radiusMedium
			color: applyMouse.containsMouse && root.canApply
				? Qt.lighter(root.secondaryBoxStrongColor, 1.15)
				: root.secondaryBoxStrongColor
			opacity: root.canApply ? 1 : 0.5

			Behavior on color {
				CAnim {}
			}

			BioText {
				role: "body"
				anchors.centerIn: parent
				color: root.foreground
				font.pixelSize: 13
				text: {
					if (root.switching) return "Switching…";
					if (root.selected && root.selected.current) return "Current style";
					if (root.confirming) return "Confirm checkout";
					return "Use selected style";
				}
			}

			MouseArea {
				id: applyMouse
				anchors.fill: parent
				hoverEnabled: true
				cursorShape: root.canApply ? Qt.PointingHandCursor : Qt.ArrowCursor
				onClicked: {
					root.forceActiveFocus();
					root.apply();
				}
			}
		}
	}
}
