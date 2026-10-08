pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "DisplayGeometry.js" as DisplayGeometry
import "Nodes.js" as Nodes

// Displays: the monitors as they stand – drag them into place, pick one to
// set its mode, scale, rotation and the rest. Where a monitor is and how it
// runs is tried live first: a bar asks to keep it and goes back on its own
// after 15 seconds (a monitor that stays black needs no hand). Kept, it is
// written to display-profile.kdl, the active setup. Setups are saved
// arrangements to switch between (scripts/display_setup.py).
SettingsPage {
	id: root

	title: "Displays"
	description: "Drag the monitors where they stand on your desk. Changes are tried right away – keep them, or they go back by themselves."

	readonly property string helper: `${Quickshell.shellDir}/scripts/display_setup.py`
	readonly property string setupScript: `${Quickshell.shellDir}/scripts/display_profile.sh`

	property var live: []
	property var profiles: []
	property string current: ""
	property var draft: []
	property var names: []
	property string selected: ""
	// a change that runs live and waits to be kept
	property var before: []
	property bool pending: false
	property int seconds: 0
	property bool busy: false
	property string failure: ""
	property string typedName: ""

	readonly property var picked: root.draft.find(o => o.name === root.selected) ?? null
	readonly property var info: (NiriSettings.live.outputs || []).find(o => o.name === root.selected) ?? null
	readonly property var matching: root.profiles.find(profile => root.matches(profile, root.live)) ?? null

	onActiveChanged: if (root.active) root.refresh()

	function refresh() {
		lister.running = false;
		lister.running = true;
		NiriSettings.refreshLive();
	}

	function clone(list) {
		return (list || []).map(o => Object.assign({}, o));
	}

	function setDraft(list) {
		root.draft = root.clone(list);
		const names = root.draft.map(o => o.name);
		if (names.join("\n") !== root.names.join("\n")) root.names = names;
		if (!names.includes(root.selected)) root.selected = names[0] ?? "";
	}

	function matches(profile, outputs) {
		const connected = (profile.outputs || []).filter(output => outputs.some(o => o.name === output.name));
		if (connected.length === 0) return false;
		const pick = list => list.filter(o => connected.some(c => c.name === o.name));
		return DisplayGeometry.signature(pick(connected)) === DisplayGeometry.signature(pick(outputs));
	}

	function payload(list) {
		return JSON.stringify(DisplayGeometry.normalized(list).map(o => ({ name: o.name, x: o.x, y: o.y, scale: o.scale, transform: o.transform, mode: o.mode, off: !!o.off })));
	}

	// tries an arrangement live; the first change remembers how it was
	function tryOut(list, note) {
		const next = DisplayGeometry.normalized(list);
		if (DisplayGeometry.signature(next) === DisplayGeometry.signature(root.live) && !root.pending) {
			root.setDraft(next);
			return;
		}
		if (!root.pending) root.before = root.clone(root.live);
		root.setDraft(next);
		root.pending = true;
		root.seconds = 15;
		countdown.restart();
		root.note = note || "Arrangement changed";
		root.run([["python3", root.helper, "live", root.payload(next)]]);
	}

	property string note: ""

	function change(name, changes, note) {
		const list = root.draft.map(o => o.name === name ? DisplayGeometry.sized(Object.assign({}, o, changes)) : o);
		root.tryOut(list, note);
	}

	// kept: the arrangement goes into display-profile.kdl
	function keep() {
		countdown.stop();
		root.pending = false;
		const blocks = NiriSettings.clone(NiriSettings.outputs);
		for (const o of DisplayGeometry.normalized(root.draft)) {
			let block = blocks.find(b => String(b.args?.[0]) === o.name);
			if (!block) {
				block = { name: "output", args: [o.name], props: {}, children: [] };
				blocks.push(block);
			}
			const rest = (block.children || []).filter(c => !["off", "mode", "scale", "transform", "position"].includes(c.name));
			const arrangement = [];
			if (o.off) arrangement.push(Nodes.make("off"));
			if (o.mode) arrangement.push(Nodes.make("mode", [o.mode]));
			arrangement.push(Nodes.make("scale", [Number(o.scale) || 1]));
			arrangement.push(Nodes.make("transform", [o.transform || "normal"]));
			arrangement.push(Nodes.make("position", [], { x: Math.round(o.x), y: Math.round(o.y) }));
			block.children = arrangement.concat(rest);
		}
		NiriSettings.setOutputs(blocks, `${root.note} – kept`);
	}

	function goBack() {
		countdown.stop();
		root.pending = false;
		root.setDraft(root.before);
		root.run([["python3", root.helper, "live", root.payload(root.before)]]);
	}

	function run(commands) {
		root.failure = "";
		root.busy = true;
		runner.queue = commands;
		runner.next();
	}

	function rotate(clockwise) {
		const o = root.picked;
		if (!o || o.off) return;
		const turned = DisplayGeometry.sized(Object.assign({}, o, { transform: DisplayGeometry.rotate(o.transform, clockwise) }));
		turned.x = Math.round(o.x + (o.width - turned.width) / 2);
		turned.y = Math.round(o.y + (o.height - turned.height) / 2);
		const others = root.draft.filter(other => other.name !== o.name && !other.off);
		const reach = Math.abs(o.width - turned.width) / 2 + 1;
		const placed = DisplayGeometry.separate(DisplayGeometry.snap(turned, others, reach), others);
		root.tryOut(root.draft.map(other => other.name === o.name ? Object.assign({}, turned, { x: placed.x, y: placed.y }) : other), `${o.name} turned`);
	}

	function setTransform(transform) {
		const o = root.picked;
		if (!o) return;
		const turned = DisplayGeometry.sized(Object.assign({}, o, { transform: transform }));
		turned.x = Math.round(o.x + (o.width - turned.width) / 2);
		turned.y = Math.round(o.y + (o.height - turned.height) / 2);
		const others = root.draft.filter(other => other.name !== o.name && !other.off);
		const placed = DisplayGeometry.separate(DisplayGeometry.snap(turned, others, Math.abs(o.width - turned.width) / 2 + 1), others);
		root.tryOut(root.draft.map(other => other.name === o.name ? Object.assign({}, turned, { x: placed.x, y: placed.y }) : other), `${o.name} turned`);
	}

	function applyProfile(profile) {
		if (!profile) return;
		countdown.stop();
		root.pending = false;
		root.run([[root.setupScript, "apply", profile.name]]);
	}

	function saveProfile(name) {
		if (!/^[A-Za-z0-9][A-Za-z0-9 _.-]{0,39}$/.test(name)) return;
		if (root.pending) root.keep();
		root.run([["python3", root.helper, "save", name, root.payload(root.draft)], [root.setupScript, "apply", name]]);
		nameField.text = "";
	}

	// the output block's extras (VRR, backdrop …) for the picked monitor
	function extra(path, fallback) {
		return NiriSettings.outputArg(root.selected, [].concat(path), fallback);
	}

	function hasExtra(path) {
		return !!NiriSettings.outputNode(root.selected, [].concat(path));
	}

	function editExtra(note, key, change) {
		NiriSettings.editOutput(root.selected, note, key, block => {
			const next = change(block);
			block.children = next.children;
		});
	}

	Timer {
		id: countdown

		interval: 1000
		repeat: true
		onTriggered: {
			root.seconds -= 1;
			if (root.seconds <= 0) root.goBack();
		}
	}

	Process {
		id: lister

		command: ["python3", root.helper, "list"]
		stdout: StdioCollector {
			onStreamFinished: {
				let data;
				try {
					data = JSON.parse(text);
				} catch (error) {
					root.failure = "Could not read the monitors";
					return;
				}
				root.live = data.live || [];
				root.profiles = data.profiles || [];
				root.current = String(data.current || "");
				if (!root.pending) root.setDraft(root.live);
			}
		}
	}

	Process {
		id: runner

		property var queue: []

		function next() {
			if (runner.queue.length === 0) {
				root.busy = false;
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
				root.failure = String(runnerError.text || "").trim().split("\n").pop() || "That did not work";
				runner.queue = [];
			}
			runner.next();
		}
	}

	Timer {
		id: refreshLater

		interval: 400
		onTriggered: root.refresh()
	}

	// ── keep it? ───────────────────────────────────────────────────────────
	headerTrailing: Rectangle {
		width: keepRow.implicitWidth + 24
		height: 48
		radius: 24
		color: Theme.primaryContainer
		border.width: 1.5
		border.color: Theme.primary
		visible: opacity > 0.01
		opacity: root.pending ? 1 : 0
		scale: root.pending ? 1 : 0.85

		Behavior on opacity {
			Anim {}
		}
		Behavior on scale {
			SpatialAnim {}
		}

		RowLayout {
			id: keepRow

			anchors.centerIn: parent
			spacing: 10

			// the seconds running out, as a ring
			Item {
				Layout.preferredWidth: 30
				Layout.preferredHeight: 30

				Ring {
					anchors.fill: parent
					value: root.seconds / 15
				}

				StyledText {
					anchors.centerIn: parent
					text: root.seconds
					tabular: true
					tone: Theme.primary
					font.weight: Font.Bold
					font.pixelSize: Theme.size.small
				}
			}

			StyledText {
				text: "Keep this?"
				font.weight: Font.DemiBold
			}

			TextButton {
				text: "Go back"
				icon: "undo"
				variant: "ghost"
				onActivated: root.goBack()
			}

			TextButton {
				text: "Keep"
				icon: "check"
				variant: "filled"
				onActivated: root.keep()
			}
		}
	}

	// ── arrangement ────────────────────────────────────────────────────────
	SettingCard {
		anchor: "arrangement"
		title: root.matching ? `Setup “${root.matching.name}”` : "Arrangement"
		subtitle: root.failure !== "" ? root.failure : (root.busy ? "Applying…" : "Drag a monitor to move it; it clicks onto the edges of the others. Click one to set it up below.")
		icon: "monitor_multiple"

		Rectangle {
			id: canvas

			Layout.fillWidth: true
			Layout.preferredHeight: 300
			radius: Theme.radius.large
			color: Theme.layer2

			property bool dragging: false
			property var view: ({ factor: 0, x: 0, y: 0 })
			readonly property var fitted: {
				const box = DisplayGeometry.bounds(root.draft);
				const pad = 34;
				const factor = DisplayGeometry.fit(box, canvas.width - pad * 2, canvas.height - pad * 2);
				return { factor: factor, x: (canvas.width - box.width * factor) / 2 - box.x * factor, y: (canvas.height - box.height * factor) / 2 - box.y * factor };
			}
			onFittedChanged: if (!canvas.dragging) canvas.view = canvas.fitted
			onDraggingChanged: if (!canvas.dragging) canvas.view = canvas.fitted

			EmptyState {
				anchors.centerIn: parent
				visible: root.names.length === 0
				icon: "monitor_multiple"
				title: "Looking for monitors…"
			}

			Repeater {
				model: root.names

				delegate: Rectangle {
					id: screen

					required property string modelData
					readonly property var output: root.draft.find(o => o.name === screen.modelData) ?? null
					readonly property bool isPicked: root.selected === screen.modelData
					readonly property real factor: canvas.view.factor
					readonly property bool starred: NiriSettings.outputFlag(screen.modelData, ["focus-at-startup"])
					property bool held: false
					property real heldX: 0
					property real heldY: 0
					readonly property real lx: screen.held ? screen.heldX : (screen.output?.x ?? 0)
					readonly property real ly: screen.held ? screen.heldY : (screen.output?.y ?? 0)

					visible: !!screen.output
					x: Math.round(canvas.view.x + screen.lx * screen.factor) + 3
					y: Math.round(canvas.view.y + screen.ly * screen.factor) + 3
					width: Math.max(10, Math.round((screen.output?.width ?? 0) * screen.factor) - 6)
					height: Math.max(10, Math.round((screen.output?.height ?? 0) * screen.factor) - 6)
					z: screen.held ? 3 : (screen.isPicked ? 2 : 1)
					radius: Theme.radius.medium
					opacity: screen.output?.off ? 0.4 : 1
					color: screen.isPicked ? Theme.primaryContainer : Theme.layer3
					border.width: screen.isPicked ? 2 : 1
					border.color: screen.isPicked ? Theme.primary : Theme.outline
					scale: screen.held ? 1.03 : 1

					Behavior on x {
						enabled: !screen.held
						SpatialAnim {
							duration: Motion.medium
						}
					}
					Behavior on y {
						enabled: !screen.held
						SpatialAnim {
							duration: Motion.medium
						}
					}
					Behavior on width {
						SpatialAnim {
							duration: Motion.long
						}
					}
					Behavior on height {
						SpatialAnim {
							duration: Motion.long
						}
					}
					Behavior on scale {
						SpatialAnim {
							duration: Motion.short
						}
					}

					// the wallpaper on it, a little
					RoundClip {
						anchors.fill: parent
						anchors.margins: 4
						radius: Theme.radius.small
						opacity: screen.isPicked ? 0.55 : 0.3

						Image {
							anchors.fill: parent
							source: Theme.wal?.wallpaper ? `file://${Theme.wal.wallpaper}` : ""
							fillMode: Image.PreserveAspectCrop
							sourceSize.width: 300
							asynchronous: true
						}
					}

					Column {
						anchors.centerIn: parent
						width: parent.width - 12
						spacing: 1

						StyledText {
							width: parent.width
							horizontalAlignment: Text.AlignHCenter
							text: screen.modelData
							font.pixelSize: Theme.size.label
							font.weight: Font.Bold
						}

						StyledText {
							width: parent.width
							visible: screen.height > 46
							horizontalAlignment: Text.AlignHCenter
							text: screen.output?.off ? "off" : `${screen.output?.modeWidth ?? 0}×${screen.output?.modeHeight ?? 0} · ${Math.round((Number(screen.output?.scale) || 1) * 100)}%`
							tone: Theme.textMuted
							font.pixelSize: Theme.size.tiny
						}
					}

					Glyph {
						anchors.top: parent.top
						anchors.right: parent.right
						anchors.margins: 6
						visible: screen.starred
						icon: "star"
						size: 13
						color: Theme.warning
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
							root.selected = screen.modelData;
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
							const snapped = DisplayGeometry.snap(moved, others, 16 / screen.factor);
							screen.heldX = snapped.x;
							screen.heldY = snapped.y;
						}
						onReleased: {
							if (!screen.held) return;
							const others = root.draft.filter(o => o.name !== screen.modelData && !o.off);
							const placed = DisplayGeometry.separate(Object.assign({}, screen.output, { x: Math.round(screen.heldX), y: Math.round(screen.heldY) }), others);
							screen.held = false;
							canvas.dragging = false;
							if (placed.x !== screen.output.x || placed.y !== screen.output.y)
								root.tryOut(root.draft.map(o => o.name === screen.modelData ? Object.assign({}, o, { x: placed.x, y: placed.y }) : o), `${screen.modelData} moved`);
						}
						onCanceled: {
							screen.held = false;
							canvas.dragging = false;
						}
					}
				}
			}
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 8

			Repeater {
				model: root.names

				delegate: Chip {
					required property string modelData

					text: modelData
					icon: "monitor"
					selected: root.selected === modelData
					onClicked: root.selected = modelData
				}
			}

			Item {
				Layout.fillWidth: true
			}

			IconButton {
				icon: "refresh"
				variant: "tonal"
				onClicked: root.refresh()
			}
		}
	}

	// ── setups ─────────────────────────────────────────────────────────────
	SettingCard {
		anchor: "setups"
		title: "Setups"
		subtitle: "Arrangements to switch between – at home, at work. Click one to switch; the phone can switch them too."
		icon: "view_dashboard_variant_outline"

		ListView {
			id: cards

			Layout.fillWidth: true
			Layout.preferredHeight: 130
			orientation: ListView.Horizontal
			spacing: 10
			clip: true
			model: root.profiles
			boundsBehavior: Flickable.StopAtBounds
			ScrollBar.horizontal: ThinScrollBar {}

			delegate: Clickable {
				id: setup

				required property var modelData
				readonly property bool isActive: setup.modelData.name === root.current

				width: 186
				height: cards.height - 8
				radius: Theme.radius.large
				color: setup.isActive ? Theme.primaryContainer : (setup.hovered ? Theme.layer3 : Theme.layer2)
				border.width: setup.isActive ? 1.5 : 0
				border.color: Theme.primary
				onClicked: root.applyProfile(setup.modelData)

				DisplayLayout {
					anchors.left: parent.left
					anchors.right: parent.right
					anchors.top: parent.top
					anchors.bottom: setupName.top
					anchors.margins: 8
					outputs: setup.modelData.outputs
					highlighted: setup.isActive
					showNames: false
				}

				RowLayout {
					id: setupName

					anchors.left: parent.left
					anchors.right: parent.right
					anchors.bottom: parent.bottom
					anchors.margins: 10
					spacing: 4

					Glyph {
						visible: setup.isActive
						icon: "check"
						size: 14
						color: Theme.primary
					}

					StyledText {
						Layout.fillWidth: true
						text: setup.modelData.name
						font.pixelSize: Theme.size.label
						font.weight: setup.isActive ? Font.Bold : Font.Medium
					}

					IconButton {
						implicitWidth: 24
						implicitHeight: 24
						iconSize: 13
						icon: "delete_outline"
						iconColor: Theme.danger
						opacity: setup.hovered ? 1 : 0
						onClicked: root.run([["python3", root.helper, "delete", setup.modelData.name]])

						Behavior on opacity {
							Anim {
								duration: Motion.short
							}
						}
					}
				}
			}

			footer: Item {
				width: root.profiles.length === 0 ? cards.width : 0
				height: cards.height

				StyledText {
					anchors.centerIn: parent
					visible: root.profiles.length === 0
					text: "No setups yet – name this arrangement below"
					tone: Theme.textMuted
				}
			}
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 10

			Field {
				id: nameField

				Layout.fillWidth: true
				icon: "content_save_outline"
				placeholder: "Save this arrangement as… (home, office)"
				onAccepted: root.saveProfile(nameField.text.trim())
			}

			TextButton {
				text: root.profiles.some(p => p.name === nameField.text.trim()) ? "Overwrite" : "Save setup"
				icon: "content_save"
				variant: "filled"
				enabled: /^[A-Za-z0-9][A-Za-z0-9 _.-]{0,39}$/.test(nameField.text.trim())
				onActivated: root.saveProfile(nameField.text.trim())
			}
		}
	}

	// ── the picked monitor ─────────────────────────────────────────────────
	SettingCard {
		id: modeCard

		anchor: "mode"
		title: root.picked ? `${root.picked.name}${root.picked.label ? " · " + root.picked.label : ""}` : "Monitor"
		subtitle: "Resolution and refresh rate"
		icon: "monitor"
		visible: !!root.picked
		trailing: Toggle {
			checked: !!root.picked && !root.picked.off
			onToggled: on => {
				if (!on && root.draft.filter(o => !o.off).length <= 1) return;
				root.change(root.selected, { off: !on }, `${root.selected} ${on ? "on" : "off"}`);
			}
		}

		readonly property var modes: root.info?.modes ?? []
		readonly property var sizes: {
			const seen = [];
			for (const m of modes) if (!seen.some(s => s.w === m.width && s.h === m.height)) seen.push({ w: m.width, h: m.height });
			return seen;
		}
		readonly property string currentMode: root.picked?.mode ?? ""
		readonly property var currentSize: /^(\d+)x(\d+)/.exec(currentMode)

		SectionLabel {
			text: "Resolution"
		}

		Flow {
			Layout.fillWidth: true
			spacing: 6

			Repeater {
				model: modeCard.sizes

				delegate: Chip {
					id: sizeChip

					required property var modelData
					readonly property var card: modeCard

					text: `${modelData.w} × ${modelData.h}`
					selected: !!sizeChip.card.currentSize && Number(sizeChip.card.currentSize[1]) === modelData.w && Number(sizeChip.card.currentSize[2]) === modelData.h
					onClicked: {
						const best = sizeChip.card.modes.filter(m => m.width === modelData.w && m.height === modelData.h).sort((a, b) => b.refresh - a.refresh)[0];
						if (best) root.change(root.selected, { mode: `${best.width}x${best.height}@${(best.refresh / 1000).toFixed(3)}`, modeWidth: best.width, modeHeight: best.height }, `${root.selected}: ${best.width}×${best.height}`);
					}
				}
			}
		}

		SectionLabel {
			text: "Refresh rate"
		}

		// the rates of this resolution, as a row of speeds
		Flow {
			id: rates

			Layout.fillWidth: true
			spacing: 6

			readonly property var card: modeCard

			Repeater {
				model: (rates.card.modes ?? []).filter(m => !!rates.card.currentSize && m.width === Number(rates.card.currentSize[1]) && m.height === Number(rates.card.currentSize[2])).sort((a, b) => b.refresh - a.refresh)

				delegate: Clickable {
					id: rate

					required property var modelData
					readonly property string modeText: `${modelData.width}x${modelData.height}@${(modelData.refresh / 1000).toFixed(3)}`
					readonly property bool isOn: rates.card.currentMode === rate.modeText

					implicitWidth: 92
					implicitHeight: 62
					radius: Theme.radius.large
					color: rate.isOn ? Theme.primaryContainer : (rate.hovered ? Theme.layer3 : Theme.layer2)
					border.width: rate.isOn ? 1.5 : 0
					border.color: Theme.primary
					onClicked: root.change(root.selected, { mode: rate.modeText }, `${root.selected}: ${(modelData.refresh / 1000).toFixed(0)} Hz`)

					// a dot that runs at the rate (slowed down so it can be seen)
					Rectangle {
						id: runner2

						y: 12
						width: 8
						height: 8
						radius: 4
						color: rate.isOn ? Theme.primary : Theme.textSubtle
						x: 10 + (parent.width - 28) * runPhase.value

						QtObject {
							id: runPhase

							property real value: 0
						}

						NumberAnimation {
							target: runPhase
							property: "value"
							running: (rate.hovered || rate.isOn) && root.active
							from: 0
							to: 1
							loops: Animation.Infinite
							duration: Math.max(300, 60000 / Math.max(1, modelData.refresh / 1000))
						}
					}

					StyledText {
						anchors.horizontalCenter: parent.horizontalCenter
						anchors.bottom: parent.bottom
						anchors.bottomMargin: 10
						text: `${(modelData.refresh / 1000).toFixed(modelData.refresh % 1000 === 0 ? 0 : 2)} Hz`
						tabular: true
						tone: rate.isOn ? Theme.primary : Theme.text
						font.weight: Font.DemiBold
					}

					Glyph {
						visible: modelData.preferred
						anchors.top: parent.top
						anchors.right: parent.right
						anchors.margins: 6
						icon: "star_outline"
						size: 11
						color: Theme.textSubtle
					}
				}
			}
		}
	}

	SettingCard {
		anchor: "scale"
		title: "Scale"
		subtitle: root.picked ? `Everything on ${root.picked.name} is drawn ${Math.round((Number(root.picked.scale) || 1) * 100)}% big – the sample grows with it` : ""
		icon: "magnify_plus_outline"
		visible: !!root.picked && !root.picked.off

		RowLayout {
			Layout.fillWidth: true
			spacing: 20

			// a sample at the size it will have
			Rectangle {
				Layout.preferredWidth: 180
				Layout.preferredHeight: 110
				radius: Theme.radius.large
				color: Theme.layer2
				clip: true

				Column {
					anchors.centerIn: parent
					spacing: 4 * (Number(root.picked?.scale) || 1)

					StyledText {
						anchors.horizontalCenter: parent.horizontalCenter
						text: "Aa"
						font.pixelSize: 16 * (Number(root.picked?.scale) || 1)
						font.weight: Font.Bold

						Behavior on font.pixelSize {
							SpatialAnim {}
						}
					}

					Rectangle {
						anchors.horizontalCenter: parent.horizontalCenter
						width: 60 * (Number(root.picked?.scale) || 1)
						height: 8 * (Number(root.picked?.scale) || 1)
						radius: height / 2
						color: Theme.primary

						Behavior on width {
							SpatialAnim {}
						}
					}
				}
			}

			ColumnLayout {
				Layout.fillWidth: true
				spacing: 10

				ValueSlider {
					from: 0.5
					to: 3
					step: 0.05
					decimals: 2
					value: Number(root.picked?.scale) || 1
					format: v => `${Math.round(v * 100)}%`
					icon: "magnify_plus_outline"
					// tried live once the slider stops
					onMoved: v => scaleLater.wanted = v
				}

				Timer {
					id: scaleLater

					property real wanted: 0
					interval: 500
					onWantedChanged: scaleLater.restart()
					onTriggered: if (scaleLater.wanted > 0) root.change(root.selected, { scale: scaleLater.wanted }, `${root.selected} at ${Math.round(scaleLater.wanted * 100)}%`)
				}

				Flow {
					Layout.fillWidth: true
					spacing: 6

					Repeater {
						model: [1, 1.25, 1.5, 1.75, 2]

						delegate: Chip {
							required property real modelData

							text: `${Math.round(modelData * 100)}%`
							selected: Math.abs((Number(root.picked?.scale) || 1) - modelData) < 0.001
							onClicked: root.change(root.selected, { scale: modelData }, `${root.selected} at ${Math.round(modelData * 100)}%`)
						}
					}
				}
			}
		}
	}

	SettingCard {
		id: rotationCard

		anchor: "rotation"
		title: "Rotation"
		subtitle: "Turn the monitor the way it stands; mirror it for a projector or a teleprompter"
		icon: "phone_rotate_landscape"
		visible: !!root.picked && !root.picked.off

		readonly property string turned: root.picked?.transform ?? "normal"
		readonly property bool flipped: turned.startsWith("flipped")
		readonly property string angle: flipped ? (turned === "flipped" ? "normal" : turned.slice(8)) : turned

		RowLayout {
			Layout.fillWidth: true
			spacing: 10

			Repeater {
				// niri turns counter-clockwise: "90" stands the screen on its right side
				model: [
					{ value: "normal", title: "Landscape", deg: 0 },
					{ value: "90", title: "Portrait, turned left", deg: -90 },
					{ value: "180", title: "Upside down", deg: 180 },
					{ value: "270", title: "Portrait, turned right", deg: 90 }
				]

				delegate: OptionTile {
					id: turn

					required property var modelData
					readonly property var card: rotationCard

					title: turn.modelData.title
					selected: turn.card.angle === turn.modelData.value
					onClicked: root.setTransform(turn.card.flipped ? (turn.modelData.value === "normal" ? "flipped" : `flipped-${turn.modelData.value}`) : turn.modelData.value)

					Rectangle {
						anchors.centerIn: parent
						width: 66
						height: 42
						radius: 5
						color: turn.selected ? Theme.primary : Theme.layer3
						rotation: turn.playing || turn.selected ? turn.modelData.deg : 0

						Behavior on rotation {
							SpatialAnim {
								duration: Motion.long
							}
						}

						// the top edge, to see where up is
						Rectangle {
							width: parent.width
							height: 5
							radius: 2
							color: turn.selected ? Theme.onPrimary : Theme.textMuted
							transform: Scale {
								xScale: turn.card.flipped ? -1 : 1
								origin.x: 33
							}
						}

						StyledText {
							anchors.centerIn: parent
							text: "A"
							tone: turn.selected ? Theme.onPrimary : Theme.text
							font.weight: Font.Bold
							transform: Scale {
								xScale: turn.card.flipped ? -1 : 1
								origin.x: 5
							}
						}
					}
				}
			}
		}

		FlagRow {
			title: "Mirrored"
			subtitle: "Flipped left to right"
			icon: "flip_horizontal"
			checked: rotationCard.flipped
			onToggled: on => {
				const a = rotationCard.angle;
				root.setTransform(on ? (a === "normal" ? "flipped" : `flipped-${a}`) : a);
			}
		}
	}

	SettingCard {
		anchor: "vrr"
		title: "Variable refresh rate"
		subtitle: root.info && !root.info.vrrSupported ? `${root.selected} does not report VRR support` : "FreeSync / G-Sync: the monitor waits for the next frame instead of tearing or stuttering"
		icon: "sine_wave"
		visible: !!root.picked && !root.picked.off
		modified: root.hasExtra("variable-refresh-rate")
		onReset: root.editExtra("VRR off", "", b => Nodes.without(b, "variable-refresh-rate"))

		RowLayout {
			Layout.fillWidth: true
			spacing: 10

			Repeater {
				model: [
					{ value: "off", title: "Off", subtitle: "A steady rate" },
					{ value: "on", title: "Always", subtitle: "Can flicker or slow the cursor on some setups" },
					{ value: "demand", title: "For some apps", subtitle: "Only while a window with the VRR rule shows (games, video)" }
				]

				delegate: OptionTile {
					id: vrr

					required property var modelData
					readonly property string now: !root.hasExtra("variable-refresh-rate") ? "off" : (NiriSettings.outputNode(root.selected, ["variable-refresh-rate"])?.props?.["on-demand"] === true ? "demand" : "on")

					title: vrr.modelData.title
					subtitle: vrr.modelData.subtitle
					selected: vrr.now === vrr.modelData.value
					enabled: !root.info || root.info.vrrSupported || vrr.modelData.value === "off"
					opacity: enabled ? 1 : 0.4
					onClicked: root.editExtra(`VRR: ${vrr.modelData.title.toLowerCase()}`, "", b => vrr.modelData.value === "off" ? Nodes.without(b, "variable-refresh-rate") : Nodes.withNode(b, "variable-refresh-rate", [], vrr.modelData.value === "demand" ? { "on-demand": true } : {}))

					// frames: even, or as they come
					Row {
						anchors.centerIn: parent
						spacing: vrr.modelData.value === "off" ? 8 : 3

						Repeater {
							model: 6

							delegate: Rectangle {
								required property int index

								width: 6
								height: vrr.modelData.value === "off" ? 30 : [30, 18, 34, 24, 30, 14][index]
								radius: 3
								anchors.bottom: parent.bottom
								color: vrr.selected ? Theme.primary : Theme.textSubtle
							}
						}
					}
				}
			}
		}
	}

	SettingCard {
		id: extrasCard

		anchor: "monitor-extras"
		title: "More for this monitor"
		subtitle: "Where niri starts, what shows between workspaces, its hot corners and layout"
		icon: "tune_vertical_variant"
		visible: !!root.picked

		FlagRow {
			title: "Focus here when niri starts"
			subtitle: "The monitor you begin on"
			icon: "star"
			checked: NiriSettings.outputFlag(root.selected, ["focus-at-startup"])
			onToggled: on => root.editExtra(`Start on ${root.selected} ${on ? "on" : "off"}`, "", b => Nodes.withFlag(b, "focus-at-startup", on))
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 14

			ColorWell {
				label: "Backdrop"
				value: String(root.extra("backdrop-color", NiriSettings.arg(["overview", "backdrop-color"], "#262626")))
				opacity: root.hasExtra("backdrop-color") ? 1 : 0.7
				onPicked: css => root.editExtra("Backdrop color", "backdrop", b => Nodes.withArg(b, "backdrop-color", css))
			}

			StyledText {
				Layout.fillWidth: true
				text: root.hasExtra("backdrop-color") ? "Behind the workspaces of this monitor, in the overview and between them" : "Follows the overview's backdrop – pick one for this monitor only"
				tone: Theme.textSubtle
				font.pixelSize: Theme.size.small
				wrapMode: Text.WordWrap
			}

			ResetPill {
				shown: root.hasExtra("backdrop-color")
				onClicked: root.editExtra("Backdrop follows the overview", "", b => Nodes.without(b, "backdrop-color"))
			}
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 18

			CornerPicker {
				Layout.preferredWidth: 230
				Layout.preferredHeight: 140
				readonly property var block: NiriSettings.outputNode(root.selected, ["hot-corners"])
				label: block ? "" : "Like every monitor"
				off: !!block && Nodes.flag(block, "off")
				corners: block ? ["top-left", "top-right", "bottom-left", "bottom-right"].filter(c => Nodes.flag(block, c)) : (NiriSettings.has(["gestures", "hot-corners"]) ? ["top-left", "top-right", "bottom-left", "bottom-right"].filter(c => NiriSettings.flag(["gestures", "hot-corners", c])) : ["top-left"])
				onEdited: (corners, off) => root.editExtra("Hot corners of this monitor", "", b => Nodes.withChild(b, Nodes.make("hot-corners", [], {}, off ? [Nodes.make("off")] : corners.map(c => Nodes.make(c)))))
			}

			ColumnLayout {
				Layout.fillWidth: true
				spacing: 6

				StyledText {
					Layout.fillWidth: true
					text: "Hot corners here"
					font.weight: Font.DemiBold
				}

				StyledText {
					Layout.fillWidth: true
					text: "Push the pointer into a lit corner to open the overview. Click corners to change them for this monitor only."
					tone: Theme.textSubtle
					font.pixelSize: Theme.size.small
					wrapMode: Text.WordWrap
				}

				ResetPill {
					shown: !!NiriSettings.outputNode(root.selected, ["hot-corners"])
					text: "Like every monitor"
					onClicked: root.editExtra("Hot corners like every monitor", "", b => Nodes.without(b, "hot-corners"))
				}
			}
		}

		// layout settings of this monitor only
		SectionLabel {
			Layout.topMargin: 6
			text: "Layout on this monitor only"
		}

		readonly property var layoutNode: NiriSettings.outputNode(root.selected, ["layout"])

		RowLayout {
			Layout.fillWidth: true
			spacing: 12

			StyledText {
				Layout.preferredWidth: 150
				text: "Gaps"
				tone: Theme.textMuted
			}

			ValueSlider {
				from: 0
				to: 64
				step: 1
				unit: " px"
				opacity: Nodes.has(extrasCard.layoutNode, "gaps") ? 1 : 0.55
				value: Number(Nodes.arg(extrasCard.layoutNode, "gaps", NiriSettings.arg(["layout", "gaps"], 16)))
				onMoved: v => root.editExtra(`Gaps on ${root.selected}`, "output-gaps", b => Nodes.withChild(b, Nodes.withArg(Nodes.get(b, "layout") ?? Nodes.make("layout", [], {}, []), "gaps", v)))
			}

			ResetPill {
				shown: Nodes.has(extrasCard.layoutNode, "gaps")
				onClicked: root.editExtra("Gaps like everywhere", "", b => Nodes.withChild(b, Nodes.without(Nodes.get(b, "layout"), "gaps")))
			}
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 12

			StyledText {
				Layout.preferredWidth: 150
				text: "New windows open"
				tone: Theme.textMuted
			}

			Flow {
				Layout.fillWidth: true
				spacing: 6

				Repeater {
					model: [0.25, 1 / 3, 0.5, 2 / 3, 1]

					delegate: Chip {
						required property real modelData
						readonly property var size: Nodes.size(Nodes.get(extrasCard.layoutNode, "default-column-width"))

						text: Nodes.fraction(modelData)
						selected: !!size && size.kind === "proportion" && Math.abs(size.value - modelData) < 0.001
						onClicked: root.editExtra(`New windows on ${root.selected}: ${Nodes.fraction(modelData)}`, "", b => Nodes.withChild(b, Nodes.withChild(Nodes.get(b, "layout") ?? Nodes.make("layout", [], {}, []), Nodes.sizeNode("default-column-width", { kind: "proportion", value: modelData }))))
					}
				}

				ResetPill {
					shown: Nodes.has(extrasCard.layoutNode, "default-column-width")
					text: "Like everywhere"
					onClicked: root.editExtra("Width like everywhere", "", b => Nodes.withChild(b, Nodes.without(Nodes.get(b, "layout"), "default-column-width")))
				}
			}
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 12

			StyledText {
				Layout.preferredWidth: 150
				text: "Center the focus"
				tone: Theme.textMuted
			}

			Segmented {
				Layout.preferredWidth: 380
				readonly property var node: extrasCard.layoutNode
				options: [{ value: "", label: "Like everywhere" }, { value: "never", label: "When needed" }, { value: "on-overflow", label: "On overflow" }, { value: "always", label: "Always" }]
				current: String(Nodes.arg(node, "center-focused-column", ""))
				onSelected: value => root.editExtra(`Centering on ${root.selected}`, "", b => Nodes.withChild(b, value === "" ? Nodes.without(Nodes.get(b, "layout"), "center-focused-column") : Nodes.withArg(Nodes.get(b, "layout") ?? Nodes.make("layout", [], {}, []), "center-focused-column", value)))
			}
		}
	}
}
