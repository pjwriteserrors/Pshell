pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.style.theme
import qs.core.services
import qs.style.widgets
import "DisplayGeometry.js" as DisplayGeometry

// Launcher >setup: the monitors as they are arranged, to drag around and
// rotate, and the saved setups below, each drawn as its monitors.
// Apply tries the arrangement live (it reverts by itself unless kept), Revert
// goes back to how things were when the view opened, and a typed name + Enter
// saves the arrangement as a setup and makes it the active one.
// Keys: ←→ / ↑↓ pick a setup, Enter applies it (or saves when a name is
// typed), Ctrl+Z reverts, Delete removes the picked setup.
ColumnLayout {
	id: root

	property string argument: ""
	property bool active: false
	property int currentIndex: 0

	readonly property string setupScript: `${Quickshell.shellDir}/scripts/display_profile.sh`
	readonly property string helper: `${Quickshell.shellDir}/scripts/display_setup.py`
	readonly property string typedName: String(root.argument || "").trim()
	readonly property bool nameValid: /^[A-Za-z0-9][A-Za-z0-9 _.-]{0,39}$/.test(root.typedName)

	property var live: []
	property var profiles: []
	property string current: ""
	// how things were when the view opened: what Revert goes back to
	property var snapshot: []
	property string snapshotProfile: ""
	property bool snapshotPending: true
	// the arrangement being edited
	property var draft: []
	property var outputNames: []
	property string selectedOutput: ""
	// an applied arrangement waits to be kept, else it goes back to this
	property var beforeApply: []
	property bool awaitingKeep: false
	property int keepSeconds: 0
	property bool busy: false
	property string error: ""

	readonly property bool dirty: DisplayGeometry.signature(root.draft) !== DisplayGeometry.signature(root.live)
	readonly property bool changedSinceOpen: DisplayGeometry.signature(root.live) !== DisplayGeometry.signature(root.snapshot)
		|| root.current !== root.snapshotProfile
	readonly property var selected: root.draft.find(output => output.name === root.selectedOutput) ?? null
	readonly property var matchingProfile: root.profiles.find(profile => root.matches(profile, root.live)) ?? null
	readonly property string enterHint: root.typedName !== "" ? "save" : "apply"
	readonly property string status: {
		if (root.error !== "") return root.error;
		if (root.busy) return "Applying …";
		if (root.awaitingKeep) return `Keep this arrangement? Going back in ${root.keepSeconds} s`;
		if (root.typedName !== "" && !root.nameValid) return "Names use letters, digits, space, - _ .";
		if (root.typedName !== "") return root.profiles.some(p => p.name === root.typedName)
			? `Enter overwrites the setup “${root.typedName}”`
			: `Enter saves this arrangement as “${root.typedName}”`;
		if (root.dirty) return "Changed – Apply tries it, a name + Enter saves it";
		if (root.matchingProfile) return `Setup “${root.matchingProfile.name}”`;
		return "Drag the monitors, rotate the picked one, type a name to save";
	}

	signal closeRequested
	signal argumentRequested(string text)

	spacing: 10

	onActiveChanged: {
		if (!root.active) {
			// leaving with an unconfirmed arrangement keeps it: the user saw it
			root.awaitingKeep = false;
			keepTimer.stop();
			return;
		}
		root.error = "";
		root.snapshotPending = true;
		root.refresh();
	}

	function refresh() {
		listProcess.running = false;
		listProcess.running = true;
	}

	function clone(outputs) {
		return (outputs || []).map(output => Object.assign({}, output));
	}

	function setDraft(outputs) {
		root.draft = root.clone(outputs);
		const names = root.draft.map(output => output.name);
		if (names.join("\n") !== root.outputNames.join("\n")) root.outputNames = names;
		if (!names.includes(root.selectedOutput)) root.selectedOutput = names[0] ?? "";
	}

	function updateOutput(name, changes) {
		root.draft = root.draft.map(output => output.name === name ? Object.assign({}, output, changes) : output);
	}

	// a setup matches when every plugged-in monitor it names sits where it says
	function matches(profile, outputs) {
		const connected = (profile.outputs || []).filter(output => outputs.some(o => o.name === output.name));
		if (connected.length === 0) return false;
		const pick = list => list.filter(o => connected.some(c => c.name === o.name));
		return DisplayGeometry.signature(pick(connected)) === DisplayGeometry.signature(pick(outputs));
	}

	// the setup laid onto the monitors that are plugged in
	function profileDraft(profile) {
		return root.live.map(output => {
			const saved = (profile.outputs || []).find(o => o.name === output.name);
			if (!saved) return Object.assign({}, output);
			const size = /^(\d+)x(\d+)/.exec(saved.mode || "");
			return DisplayGeometry.sized(Object.assign({}, output, {
				x: saved.x,
				y: saved.y,
				transform: saved.transform,
				scale: saved.scale,
				off: saved.off,
				mode: saved.mode || output.mode,
				modeWidth: size ? Number(size[1]) : output.modeWidth,
				modeHeight: size ? Number(size[2]) : output.modeHeight
			}));
		});
	}

	function payload(outputs) {
		return JSON.stringify(DisplayGeometry.normalized(outputs).map(output => ({
			name: output.name,
			x: output.x,
			y: output.y,
			scale: output.scale,
			transform: output.transform,
			mode: output.mode,
			off: !!output.off
		})));
	}

	function run(commands) {
		root.error = "";
		root.busy = true;
		runner.queue = commands;
		runner.next();
	}

	function rotateSelected(clockwise) {
		const output = root.selected;
		if (!output) return;
		const turned = DisplayGeometry.sized(Object.assign({}, output, { transform: DisplayGeometry.rotate(output.transform, clockwise) }));
		// turn around the centre, dock onto a neighbour, then out of the way of the others
		turned.x = Math.round(output.x + (output.width - turned.width) / 2);
		turned.y = Math.round(output.y + (output.height - turned.height) / 2);
		const others = root.draft.filter(o => o.name !== output.name && !o.off);
		const reach = Math.abs(output.width - turned.width) / 2 + 1;
		const placed = DisplayGeometry.separate(DisplayGeometry.snap(turned, others, reach), others);
		root.updateOutput(output.name, { transform: turned.transform, width: turned.width, height: turned.height, x: placed.x, y: placed.y });
	}

	function toggleSelected() {
		const output = root.selected;
		if (!output) return;
		const on = root.draft.filter(o => !o.off);
		if (!output.off && on.length <= 1) return;
		root.updateOutput(output.name, { off: !output.off });
	}

	function applyDraft() {
		if (!root.dirty) return;
		root.beforeApply = root.clone(root.live);
		root.run([["python3", root.helper, "live", root.payload(root.draft)]]);
		root.awaitingKeep = true;
		root.keepSeconds = 15;
		keepTimer.restart();
	}

	function keep() {
		root.awaitingKeep = false;
		keepTimer.stop();
	}

	function backTo(outputs) {
		root.keep();
		root.setDraft(outputs);
		root.run([["python3", root.helper, "live", root.payload(outputs)]]);
	}

	function revert() {
		root.keep();
		root.setDraft(root.snapshot);
		const commands = [];
		if (root.snapshotProfile !== "" && root.current !== root.snapshotProfile)
			commands.push([root.setupScript, "apply", root.snapshotProfile]);
		commands.push(["python3", root.helper, "live", root.payload(root.snapshot)]);
		root.run(commands);
	}

	function save(name) {
		if (!root.nameValid) return;
		root.keep();
		root.run([
			["python3", root.helper, "save", name, root.payload(root.draft)],
			[root.setupScript, "apply", name]
		]);
		root.argumentRequested("");
	}

	function applyProfile(profile) {
		if (!profile) return;
		root.keep();
		root.setDraft(root.profileDraft(profile));
		root.run([[root.setupScript, "apply", profile.name]]);
	}

	function removeProfile(profile) {
		if (!profile) return;
		root.run([["python3", root.helper, "delete", profile.name]]);
	}

	function move(delta) {
		if (root.profiles.length === 0) return;
		root.currentIndex = Math.max(0, Math.min(root.profiles.length - 1, root.currentIndex + delta));
		cards.positionViewAtIndex(root.currentIndex, ListView.Contain);
	}

	function handleKey(event) {
		const ctrl = event.modifiers & Qt.ControlModifier;
		if (event.key === Qt.Key_Left && root.typedName === "") root.move(-1);
		else if (event.key === Qt.Key_Right && root.typedName === "") root.move(1);
		else if (ctrl && event.key === Qt.Key_Z) root.revert();
		else if (event.key === Qt.Key_Delete && root.typedName === "") root.removeProfile(root.profiles[root.currentIndex]);
		else return false;
		return true;
	}

	function cancel() {
		if (!root.awaitingKeep) return false;
		root.backTo(root.beforeApply);
		return true;
	}

	function activate(modifiers) {
		if (root.typedName !== "") root.save(root.typedName);
		else if (root.awaitingKeep) root.keep();
		else root.applyProfile(root.profiles[root.currentIndex]);
	}

	Timer {
		id: keepTimer

		interval: 1000
		repeat: true
		onTriggered: {
			root.keepSeconds -= 1;
			if (root.keepSeconds <= 0) root.backTo(root.beforeApply);
		}
	}

	Process {
		id: listProcess

		command: ["python3", root.helper, "list"]
		stdout: StdioCollector {
			onStreamFinished: {
				let data;
				try {
					data = JSON.parse(text);
				} catch (error) {
					root.error = "Could not read the monitors";
					return;
				}
				root.live = data.live || [];
				root.profiles = data.profiles || [];
				root.current = String(data.current || "");
				root.currentIndex = Math.max(0, Math.min(root.currentIndex, root.profiles.length - 1));
				if (root.snapshotPending) {
					root.snapshotPending = false;
					root.snapshot = root.clone(root.live);
					root.snapshotProfile = root.current;
					root.setDraft(root.live);
					const active = root.profiles.findIndex(profile => profile.name === root.current);
					if (active >= 0) root.currentIndex = active;
				} else if (!root.dirty) {
					root.setDraft(root.live);
				}
			}
		}
	}

	Process {
		id: runner

		property var queue: []

		function next() {
			if (runner.queue.length === 0) {
				root.busy = false;
				// niri needs a moment before the outputs report their new place
				refreshLater.restart();
				return;
			}
			runner.command = runner.queue[0];
			runner.queue = runner.queue.slice(1);
			runner.running = true;
		}

		stderr: StdioCollector {
			id: runnerError
		}
		onExited: code => {
			if (code !== 0) {
				root.error = String(runnerError.text || "").trim().split("\n").pop() || "That did not work";
				runner.queue = [];
				root.awaitingKeep = false;
				keepTimer.stop();
			}
			runner.next();
		}
	}

	Timer {
		id: refreshLater

		interval: 350
		onTriggered: root.refresh()
	}

	// ── arrangement ───────────────────────────────────────────────────────
	RowLayout {
		Layout.fillWidth: true
		Layout.leftMargin: 6
		spacing: 6

		ColumnLayout {
			Layout.fillWidth: true
			spacing: 0

			StyledText {
				Layout.fillWidth: true
				text: root.selected ? `${root.selected.name}${root.selected.label ? " · " + root.selected.label : ""}` : "Monitors"
				elide: Text.ElideRight
				font.pixelSize: Theme.size.title
				font.weight: Font.Bold
			}

			StyledText {
				Layout.fillWidth: true
				text: root.status
				elide: Text.ElideRight
				tone: root.error !== "" ? Theme.danger : (root.awaitingKeep ? Theme.warning : Theme.textMuted)
				font.pixelSize: Theme.size.small
			}
		}

		IconButton {
			icon: "rotate_left"
			variant: "tonal"
			enabled: !!root.selected && !root.selected.off
			onClicked: root.rotateSelected(false)
		}

		IconButton {
			icon: "rotate_right"
			variant: "tonal"
			enabled: !!root.selected && !root.selected.off
			onClicked: root.rotateSelected(true)
		}

		IconButton {
			icon: "power"
			variant: "tonal"
			checked: !!root.selected && !root.selected.off
			enabled: !!root.selected
			onClicked: root.toggleSelected()
		}

		Item {
			Layout.preferredWidth: 6
		}

		TextButton {
			text: "Revert"
			icon: "undo"
			variant: "tonal"
			enabled: !root.busy && (root.dirty || root.changedSinceOpen || root.awaitingKeep)
			onActivated: root.revert()
		}

		TextButton {
			text: root.awaitingKeep ? "Keep" : "Apply"
			icon: "check"
			variant: "filled"
			enabled: !root.busy && (root.dirty || root.awaitingKeep)
			onActivated: root.awaitingKeep ? root.keep() : root.applyDraft()
		}
	}

	Rectangle {
		id: canvas

		Layout.fillWidth: true
		Layout.fillHeight: true
		Layout.minimumHeight: 160
		radius: Theme.radius.large
		color: Theme.layer1

		// the view only rescales when nothing is being dragged
		property bool dragging: false
		property var view: ({ factor: 0, x: 0, y: 0 })
		readonly property var fitted: {
			const box = DisplayGeometry.bounds(root.draft);
			const pad = 28;
			const factor = DisplayGeometry.fit(box, canvas.width - pad * 2, canvas.height - pad * 2);
			return {
				factor: factor,
				x: (canvas.width - box.width * factor) / 2 - box.x * factor,
				y: (canvas.height - box.height * factor) / 2 - box.y * factor
			};
		}
		onFittedChanged: if (!canvas.dragging) canvas.view = canvas.fitted
		onDraggingChanged: if (!canvas.dragging) canvas.view = canvas.fitted

		EmptyState {
			anchors.centerIn: parent
			visible: root.outputNames.length === 0
			icon: "monitor_multiple"
			title: root.error !== "" ? root.error : "Looking for monitors …"
		}

		MouseArea {
			anchors.fill: parent
			onClicked: root.selectedOutput = ""
		}

		Repeater {
			model: root.outputNames

			delegate: Rectangle {
				id: screen

				required property string modelData
				readonly property var output: root.draft.find(o => o.name === screen.modelData) ?? null
				readonly property bool picked: root.selectedOutput === screen.modelData
				readonly property real factor: canvas.view.factor
				// while dragging the rect follows the pointer, snapped live
				property bool held: false
				property real heldX: 0
				property real heldY: 0
				readonly property real logicalX: screen.held ? screen.heldX : (screen.output?.x ?? 0)
				readonly property real logicalY: screen.held ? screen.heldY : (screen.output?.y ?? 0)

				visible: !!screen.output
				x: Math.round(canvas.view.x + screen.logicalX * screen.factor) + 2
				y: Math.round(canvas.view.y + screen.logicalY * screen.factor) + 2
				width: Math.max(8, Math.round((screen.output?.width ?? 0) * screen.factor) - 4)
				height: Math.max(8, Math.round((screen.output?.height ?? 0) * screen.factor) - 4)
				z: screen.held ? 2 : (screen.picked ? 1 : 0)
				radius: Theme.radius.medium
				opacity: screen.output?.off ? 0.4 : 1
				color: screen.picked ? Theme.primaryContainer : Theme.layer3
				border.width: screen.picked ? 2 : 1
				border.color: screen.picked ? Theme.primary : Theme.outline

				Behavior on x {
					enabled: !screen.held
					SpatialAnim {
						duration: Motion.short
					}
				}
				Behavior on y {
					enabled: !screen.held
					SpatialAnim {
						duration: Motion.short
					}
				}
				Behavior on width {
					SpatialAnim {
						duration: Motion.short
					}
				}
				Behavior on height {
					SpatialAnim {
						duration: Motion.short
					}
				}

				Column {
					anchors.centerIn: parent
					width: parent.width - 12
					spacing: 1

					StyledText {
						width: parent.width
						horizontalAlignment: Text.AlignHCenter
						elide: Text.ElideRight
						text: screen.modelData
						font.pixelSize: Theme.size.label
						font.weight: Font.Bold
					}

					StyledText {
						width: parent.width
						visible: screen.height > 44
						horizontalAlignment: Text.AlignHCenter
						elide: Text.ElideRight
						text: screen.output?.off ? "off" : `${screen.output?.modeWidth ?? 0}×${screen.output?.modeHeight ?? 0}`
						tone: Theme.textMuted
						font.pixelSize: Theme.size.tiny
					}
				}

				MouseArea {
					id: dragArea

					property point start
					property real startX: 0
					property real startY: 0

					anchors.fill: parent
					cursorShape: screen.held ? Qt.ClosedHandCursor : Qt.OpenHandCursor
					preventStealing: true

					onPressed: mouse => {
						root.selectedOutput = screen.modelData;
						if (!screen.output || screen.output.off || screen.factor <= 0) return;
						dragArea.start = mapToItem(canvas, mouse.x, mouse.y);
						dragArea.startX = screen.output.x;
						dragArea.startY = screen.output.y;
						screen.heldX = screen.output.x;
						screen.heldY = screen.output.y;
						screen.held = true;
						canvas.dragging = true;
					}
					onPositionChanged: mouse => {
						if (!screen.held) return;
						const point = mapToItem(canvas, mouse.x, mouse.y);
						const moved = Object.assign({}, screen.output, {
							x: dragArea.startX + (point.x - dragArea.start.x) / screen.factor,
							y: dragArea.startY + (point.y - dragArea.start.y) / screen.factor
						});
						const others = root.draft.filter(o => o.name !== screen.modelData && !o.off);
						const snapped = DisplayGeometry.snap(moved, others, 14 / screen.factor);
						screen.heldX = snapped.x;
						screen.heldY = snapped.y;
					}
					onReleased: {
						if (!screen.held) return;
						const others = root.draft.filter(o => o.name !== screen.modelData && !o.off);
						const placed = DisplayGeometry.separate(Object.assign({}, screen.output, {
							x: Math.round(screen.heldX),
							y: Math.round(screen.heldY)
						}), others);
						root.updateOutput(screen.modelData, { x: placed.x, y: placed.y });
						screen.held = false;
						canvas.dragging = false;
						root.setDraft(DisplayGeometry.normalized(root.draft));
					}
					onCanceled: {
						screen.held = false;
						canvas.dragging = false;
					}
				}
			}
		}
	}

	// ── setups ────────────────────────────────────────────────────────────
	ListView {
		id: cards

		Layout.fillWidth: true
		Layout.preferredHeight: 128
		orientation: ListView.Horizontal
		spacing: 8
		clip: true
		model: root.profiles
		currentIndex: root.currentIndex
		boundsBehavior: Flickable.StopAtBounds
		ScrollBar.horizontal: ThinScrollBar {}

		delegate: Rectangle {
			id: card

			required property var modelData
			required property int index
			readonly property bool picked: root.currentIndex === card.index
			readonly property bool isActive: card.modelData.name === root.current
			readonly property bool hovered: cardHover.hovered

			width: 176
			height: cards.height - 8
			radius: Theme.radius.large
			color: card.picked ? Theme.layer2 : Theme.layer1
			border.width: card.picked ? 2 : 0
			border.color: Theme.primary
			scale: cardArea.pressed ? 0.97 : 1

			Behavior on scale {
				SpatialAnim {
					duration: Motion.short
				}
			}

			HoverHandler {
				id: cardHover

				onHoveredChanged: if (cardHover.hovered) root.currentIndex = card.index
			}

			MouseArea {
				id: cardArea

				anchors.fill: parent
				cursorShape: Qt.PointingHandCursor
				onClicked: root.applyProfile(card.modelData)
			}

			DisplayLayout {
				anchors.left: parent.left
				anchors.right: parent.right
				anchors.top: parent.top
				anchors.bottom: nameRow.top
				anchors.margins: 6
				outputs: card.modelData.outputs
				highlighted: card.isActive
				showNames: false
			}

			RowLayout {
				id: nameRow

				anchors.left: parent.left
				anchors.right: parent.right
				anchors.bottom: parent.bottom
				anchors.margins: 8
				spacing: 4

				Glyph {
					visible: card.isActive
					icon: "check"
					size: 14
					color: Theme.primary
				}

				StyledText {
					Layout.fillWidth: true
					text: card.modelData.name
					elide: Text.ElideRight
					font.pixelSize: Theme.size.label
					font.weight: card.isActive ? Font.Bold : Font.Normal
				}
			}

			Row {
				anchors.right: parent.right
				anchors.top: parent.top
				anchors.margins: 6
				spacing: 2
				opacity: card.hovered ? 1 : 0

				Behavior on opacity {
					Anim {
						duration: Motion.short
					}
				}

				IconButton {
					width: 26
					height: 26
					variant: "tonal"
					icon: "pencil"
					onClicked: {
						root.keep();
						root.setDraft(root.profileDraft(card.modelData));
						root.argumentRequested(card.modelData.name);
					}
				}

				IconButton {
					width: 26
					height: 26
					variant: "tonal"
					icon: "delete_outline"
					iconColor: Theme.danger
					onClicked: root.removeProfile(card.modelData)
				}
			}
		}

		footer: Item {
			width: root.profiles.length === 0 ? cards.width : 0
			height: cards.height

			StyledText {
				anchors.centerIn: parent
				visible: root.profiles.length === 0
				text: "No setups yet – type a name and press Enter"
				tone: Theme.textMuted
				font.pixelSize: Theme.size.small
			}
		}
	}
}
