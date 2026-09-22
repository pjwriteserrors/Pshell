pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "components"

// Studio's style page. A style is a local Git branch of this configuration:
// checking one out swaps the whole shell at once.
//
// The branches are knots on one wire, drawn like a git graph: the light rests
// on the branch that is checked out, and choosing another lights the stretch
// of wire between the two — the distance the switch would travel. Branches
// without a style manifest are cold knots the keyboard skips.
//
// Keyboard: arrows move, Enter arms and Enter again commits, Escape steps
// back out of the arm and then closes Studio. Mouse: click chooses,
// double-click switches, or hold the button until it is charged.
FocusScope {
	id: root

	signal closeRequested

	required property color foreground
	required property color background
	required property color secondaryBoxColor
	required property color secondaryBoxStrongColor
	required property color secondaryInsetColor
	required property color barColor
	property color danger: Filament.alert
	property real reveal: 1

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
	readonly property int selectedIndex: root.entries.findIndex(entry => entry.branch === root.chosenBranch)
	readonly property int currentIndex: root.entries.findIndex(entry => entry.current)
	readonly property bool canApply: !!root.selected && !root.dirty && root.selected.compatible
		&& !root.selected.current && !root.switching

	readonly property string message: {
		if (root.errorText) return root.errorText;
		if (root.dirty) return "Uncommitted changes: commit or move them before switching. Nothing will be discarded.";
		if (root.confirming) return "Check out " + root.chosenBranch + " and reload the shell? Press Enter again to confirm.";
		return "Local branches only. No stash, no reset, no downloads - and the shell reloads in place instead of restarting.";
	}

	readonly property string verb: {
		if (root.switching) return "Switching…";
		if (root.selected && root.selected.current) return "Current style";
		if (root.confirming) return "Confirm checkout";
		return "Use selected style";
	}

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
	Keys.onUpPressed: root.move(-1)
	Keys.onDownPressed: root.move(1)

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
			text: "style branches"
			caps: true
			tone: "mute"
			font.pixelSize: Filament.textXs
		}

		Row {
			anchors.right: parent.right
			anchors.verticalCenter: parent.verticalCenter
			spacing: 8
			FText { anchors.verticalCenter: parent.verticalCenter; text: "checked out"; caps: true; tone: "faint"; font.pixelSize: Filament.textXs }
			FText { anchors.verticalCenter: parent.verticalCenter; text: root.currentBranch || "…"; mono: true; tone: "charge"; font.pixelSize: Filament.textSm }
		}
	}

	// ----------------------------------------------------------- the graph
	Band {
		id: graph
		reveal: root.reveal
		order: 1
		anchors.top: head.bottom
		anchors.topMargin: 12
		width: parent.width
		height: 250

		readonly property int count: root.entries.length
		readonly property real inset: 90
		readonly property real span: Math.max(1, width - inset * 2)
		readonly property real wireY: 90
		function knotX(index) {
			if (graph.count <= 1) return graph.inset + graph.span / 2;
			return Math.round(graph.inset + graph.span * index / (graph.count - 1));
		}

		// The lit stretch runs from the checked-out branch to the chosen one.
		property real lightX: graph.knotX(Math.max(0, root.selectedIndex))
		Behavior on lightX {
			NumberAnimation { duration: Filament.travelTime(graph.span / 3); easing.type: Easing.BezierSpline; easing.bezierCurve: Filament.easeTravel }
		}
		readonly property real homeX: graph.knotX(Math.max(0, root.currentIndex))

		Wire {
			id: graphWire
			x: 0
			y: graph.wireY - 1
			width: parent.width
			height: 2
			cold: Filament.wireDim
			animateLit: false
			litFrom: Math.min(graph.homeX, graph.lightX) / Math.max(1, width)
			lit: Math.abs(graph.lightX - graph.homeX) / Math.max(1, width)
		}

		// Waiting for the catalog: a pulse runs along the empty wire.
		Timer {
			interval: 900; repeat: true; running: root.entries.length === 0 && root.visible; triggeredOnStart: true
			onTriggered: graphWire.pulse()
		}
		FText {
			anchors.centerIn: parent
			visible: root.entries.length === 0
			text: root.errorText !== "" ? root.errorText : "Reading the branches…"
			tone: root.errorText !== "" ? "alert" : "faint"
			font.pixelSize: Filament.textSm
		}

		Repeater {
			model: root.entries

			Item {
				id: knot
				required property var modelData
				required property int index
				readonly property bool compatible: knot.modelData?.compatible ?? false
				readonly property bool current: knot.modelData?.current ?? false
				readonly property bool chosen: (knot.modelData?.branch ?? "") === root.chosenBranch
				readonly property bool hovered: knotTouch.containsMouse
				x: graph.knotX(index) - width / 2
				y: 0
				width: Math.min(150, Math.max(90, graph.span / Math.max(1, graph.count - 1) - 8))
				height: graph.height

				MouseArea {
					id: knotTouch
					anchors.fill: parent
					hoverEnabled: true
					cursorShape: knot.compatible ? Qt.PointingHandCursor : Qt.ArrowCursor
					onClicked: {
						if (!knot.compatible) return;
						root.choose(knot.modelData.branch);
						root.forceActiveFocus();
					}
					onDoubleClicked: {
						if (!knot.compatible) return;
						root.choose(knot.modelData.branch);
						root.forceActiveFocus();
						root.apply();
						root.apply();
					}
				}

				// The commit knot on the wire.
				Rectangle {
					anchors.horizontalCenter: parent.horizontalCenter
					y: graph.wireY - height / 2
					width: knot.compatible ? (knot.chosen ? 16 : 11) : 7
					height: width
					radius: width / 2
					color: knot.current ? Filament.charge : (knot.compatible ? Filament.planeSolid : Filament.wireDim)
					border.width: knot.compatible ? 2 : 0
					border.color: knot.chosen ? Filament.charge : (knot.hovered ? Filament.wireBright : Filament.wire)
					Behavior on width { SpringAnimation { spring: 4; damping: 0.3; epsilon: 0.05 } }
					Behavior on color { ColorAnimation { duration: Filament.quick } }
					Behavior on border.color { ColorAnimation { duration: Filament.quick } }
				}

				Spark {
					anchors.horizontalCenter: parent.horizontalCenter
					y: graph.wireY - size / 2
					size: 7
					breathing: true
					visible: knot.current
				}

				// A short ref line from the knot down to its label.
				Wire {
					vertical: true
					anchors.horizontalCenter: parent.horizontalCenter
					y: graph.wireY + 10
					height: 18
					width: 2
					cold: knot.chosen ? Filament.charge : Filament.wireDim
					glow: false
					opacity: knot.compatible ? 1 : 0.4
				}

				Column {
					anchors.horizontalCenter: parent.horizontalCenter
					y: graph.wireY + 34
					width: parent.width
					spacing: 2
					opacity: knot.compatible ? 1 : 0.45
					FText {
						width: parent.width
						horizontalAlignment: Text.AlignHCenter
						text: knot.modelData?.name ?? ""
						tone: knot.chosen ? "ink" : (knot.hovered ? "ink" : "soft")
						font.pixelSize: Filament.textMd
						font.weight: knot.chosen ? Font.DemiBold : Font.Medium
					}
					FText {
						width: parent.width
						horizontalAlignment: Text.AlignHCenter
						text: knot.modelData?.branch ?? ""
						mono: true
						tone: knot.chosen ? "charge" : "faint"
						font.pixelSize: Filament.textXs
						elide: Text.ElideMiddle
					}
					Chip {
						anchors.horizontalCenter: parent.horizontalCenter
						visible: knot.current || !knot.compatible
						text: knot.current ? "checked out" : "not a style"
						lit: knot.current
						mono: false
					}
				}
			}
		}
	}

	// ---------------------------------------------------------- the detail
	Band {
		id: detail
		reveal: root.reveal
		order: 2
		anchors.top: graph.bottom
		anchors.topMargin: 10
		width: parent.width
		height: column.y + column.implicitHeight

		Wire {
			x: 0; y: 0
			width: parent.width
			height: 2
			cold: Filament.wireDim
			glow: false
		}

		Column {
			id: column
			x: 0
			y: 22
			width: Math.min(parent.width, 760)
			spacing: 6

			Row {
				spacing: 12
				FText {
					anchors.verticalCenter: parent.verticalCenter
					text: root.selected ? root.selected.name : (root.entries.length === 0 ? "" : "No branch chosen")
					font.pixelSize: Filament.textDisplay
					font.weight: Font.DemiBold
				}
				Chip {
					anchors.verticalCenter: parent.verticalCenter
					visible: !!root.selected
					text: root.selected?.current ? "checked out" : (root.selected?.compatible ? "style branch" : "not a style")
					lit: root.selected?.current ?? false
					mono: false
				}
			}

			FText {
				text: root.selected ? root.selected.branch : ""
				mono: true
				tone: "charge"
				font.pixelSize: Filament.textSm
			}

			FText {
				width: parent.width
				text: root.selected ? String(root.selected.description || "") : ""
				visible: text !== ""
				tone: "soft"
				font.pixelSize: Filament.textMd
				wrapMode: Text.WordWrap
				maximumLineCount: 3
			}
		}
	}

	// ----------------------------------------------------------- the verbs
	Band {
		id: verbs
		reveal: root.reveal
		order: 3
		anchors.top: detail.bottom
		anchors.topMargin: 28
		width: parent.width
		height: 40

		FText {
			anchors.left: parent.left
			anchors.right: switchButton.left
			anchors.rightMargin: 24
			anchors.verticalCenter: parent.verticalCenter
			text: root.message
			tone: root.dirty || root.errorText ? "alert" : (root.confirming ? "charge" : "soft")
			font.pixelSize: Filament.textSm
			wrapMode: Text.WordWrap
			maximumLineCount: 2
			Behavior on color { ColorAnimation { duration: Filament.quick } }
		}

		HoldButton {
			id: switchButton
			anchors.right: parent.right
			anchors.verticalCenter: parent.verticalCenter
			text: root.switching ? "Switching…" : (root.canApply ? (root.confirming ? "Hold, or Enter to confirm" : "Hold to switch") : root.verb)
			icon: "system-switch-user-symbolic"
			alert: false
			enabled: root.canApply
			onHeld: {
				root.forceActiveFocus();
				if (!root.canApply) return;
				root.confirming = true;
				root.apply();
			}
		}
	}
}
