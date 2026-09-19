pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import "components"

// Studio's style page. A style is a local Git branch of this configuration:
// checking one out swaps the whole shell at once.
//
// This page is part of the Studio contract every style has to keep — and this
// one especially: it is how you get back out of a style once you are in it.
// See STUDIO.md.
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
			role: "specimen"
			text: "Strains"
			font.pixelSize: 30
		}

		BioText {
			role: "caption"
			tone: "muted"
			width: parent.width
			text: "One branch, one whole organism.   Growing: " + root.currentBranch
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

				// A branch is a strain in the collection: its own chamber, its
				// name engraved, and a bead that says whether it is the one
				// currently growing.
				BioSurface {
					anchors.fill: parent
					anchors.margins: 7
					variant: "plate"
					washTop: entry.chosen ? Bio.membrane : Bio.tissue2
					washBottom: entry.chosen ? Bio.membraneDeep : Bio.tissue1
					lineColor: entry.chosen ? Bio.boneDim : Bio.boneFaint
					liveColor: Bio.organ
					haloStrength: entry.chosen ? 0.22 : 0
					intensity: entry.chosen ? 1 : (entryMouse.containsMouse ? 0.5 : 0)
					padding: Bio.s6
					opacity: entry.modelData.compatible ? 1 : 0.45

					Column {
						anchors.fill: parent
						spacing: Bio.s2

						Row {
							spacing: Bio.s2

							Rectangle {
								anchors.verticalCenter: parent.verticalCenter
								width: Bio.nodule * 2
								height: Bio.nodule * 2
								radius: width / 2
								color: entry.modelData.current ? Bio.organ
									: entry.modelData.compatible ? Bio.boneFaint : Bio.boneGhost
							}

							BioText {
								anchors.verticalCenter: parent.verticalCenter
								role: "label"
								tone: entry.modelData.current ? "organ" : "faint"
								text: entry.modelData.current ? "Growing"
									: entry.modelData.compatible ? "Viable" : "Not a strain"
							}
						}

						BioText {
							role: "title"
							width: parent.width
							font.pixelSize: 26
							text: entry.modelData.name
						}

						BioText {
							role: "mono"
							tone: "faint"
							width: parent.width
							font.pixelSize: 11
							text: entry.modelData.branch
							elide: Text.ElideMiddle
						}

						BioText {
							role: "caption"
							tone: "muted"
							width: parent.width
							text: entry.modelData.description || ""
							visible: text !== ""
							wrapMode: Text.WordWrap
							maximumLineCount: 2
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
			role: "caption"
			tone: root.dirty || root.errorText ? "alert" : "muted"
			width: parent.width
			wrapMode: Text.WordWrap
			text: {
				if (root.errorText) return root.errorText;
				if (root.dirty) return "Uncommitted changes: commit or move them before switching. Nothing will be discarded.";
				if (root.confirming) return "Check out " + root.chosenBranch + " and reload the shell? Press Enter again to confirm.";
				return "Local branches only. No stash, no reset, no downloads - and the shell reloads in place instead of restarting.";
			}
		}

		BioSurface {
			width: parent.width
			height: 44
			variant: "plate"
			washTop: Bio.tissue2
			washBottom: Bio.tissue1
			lineColor: Bio.boneFaint
			liveColor: Bio.organ
			haloStrength: 0.12
			intensity: applyMouse.live
			opacity: root.canApply ? 1 : 0.5
			padding: 0

			BioText {
				anchors.centerIn: parent
				role: "label"
				tone: applyMouse.live > 0.3 ? "organ" : "default"
				text: {
					if (root.switching) return "Grafting";
					if (root.selected && root.selected.current) return "This strain is growing";
					if (root.confirming) return "Confirm the graft";
					return "Graft the chosen strain";
				}
			}

			BioTouch {
				id: applyMouse
				enabled: root.canApply
				cursorShape: root.canApply ? Qt.PointingHandCursor : Qt.ArrowCursor
				onClicked: {
					root.forceActiveFocus();
					root.apply();
				}
			}
		}
	}
}
