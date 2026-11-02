pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.style.theme
import qs.style.widgets
import qs.core.views.studio

// Springs & curves: niri's animations besides opening and closing windows,
// set by hand (scripts/niri_motion.py). A change plays in the demo at once
// and reaches niri when the slider has rested a moment. What is set here wins
// over the style's motion.kdl and outlives switching the window animation.
Item {
	id: root

	property var nodes: []
	property real slowdown: 1.0
	property string selectedKey: "workspace-switch"
	readonly property var selected: root.nodes.find(node => node.key === root.selectedKey) ?? null
	// the value being edited; the list, graph and demo show it before niri does
	property var draft: null

	readonly property string scriptPath: `${Quickshell.shellDir}/scripts/niri_motion.py`

	// the shell's own beziers (Motion.qml) and "land", the one niri's motion
	// uses (style/animations/motion.kdl), offered as curves
	readonly property var shellCurves: ({
			land: [0.3, 0.8, 0.5, 1.0],
			decel: [0.05, 0.7, 0.1, 1.0],
			accel: [0.3, 0.0, 0.8, 0.15],
			standard: [0.2, 0.0, 0.0, 1.0]
		})

	function reload() {
		describeProcess.running = true;
	}

	Component.onCompleted: root.reload()
	// the window animation may have brought other values since
	onVisibleChanged: if (root.visible) root.reload()
	onSelectedChanged: root.draft = root.selected ? Object.assign({}, root.selected.current) : null

	// changes merge into the draft; a whole new value (another kind) replaces it
	function edit(changes, whole) {
		root.draft = whole ? Object.assign({}, changes) : Object.assign({}, root.draft, changes);
		root.nodes = root.nodes.map(node => node.key === root.selectedKey ? Object.assign({}, node, { current: root.draft, custom: true }) : node);
		writer.queue(["set", root.selectedKey, JSON.stringify(root.draft)]);
		demo.restart();
	}

	function setKind(kind) {
		if (!root.selected || root.draft?.kind === kind) return;
		if (kind === "off")
			root.edit({ kind: "off" }, true);
		else if (kind === "spring")
			root.edit(root.selected.niri.kind === "spring" ? root.selected.niri : { kind: "spring", damping: 1.0, stiffness: 800, epsilon: 0.0001 }, true);
		else
			// what the rest of niri's motion uses (motion.kdl)
			root.edit({ kind: "easing", duration: 260, curve: "cubic-bezier", bezier: root.shellCurves.land }, true);
	}

	// ── the motion itself, as niri computes it ─────────────────────────────
	// a spring of mass 1 from 0 to 1, at rest at the start
	function springAt(t, damping, stiffness) {
		const w = Math.sqrt(stiffness);
		if (damping < 1) {
			const wd = w * Math.sqrt(1 - damping * damping);
			return 1 - Math.exp(-damping * w * t) * (Math.cos(wd * t) + damping * w / wd * Math.sin(wd * t));
		}
		return 1 - Math.exp(-w * t) * (1 + w * t);
	}

	function bezierAt(x, b) {
		let t = x;
		for (let i = 0; i < 8; i += 1) {
			const u = 1 - t;
			const fx = 3 * u * u * t * b[0] + 3 * u * t * t * b[2] + t * t * t - x;
			const dx = 3 * u * u * b[0] + 6 * u * t * (b[2] - b[0]) + 3 * t * t * (1 - b[2]);
			if (Math.abs(dx) < 1e-6) break;
			t = Math.max(0, Math.min(1, t - fx / dx));
		}
		const u = 1 - t;
		return 3 * u * u * t * b[1] + 3 * u * t * t * b[3] + t * t * t;
	}

	function easeAt(x, value) {
		switch (value.curve) {
		case "linear": return x;
		case "ease-out-quad": return 1 - (1 - x) * (1 - x);
		case "ease-out-expo": return x >= 1 ? 1 : 1 - Math.pow(2, -10 * x);
		case "cubic-bezier": return root.bezierAt(x, value.bezier || [0.25, 0.1, 0.25, 1]);
		default: return 1 - Math.pow(1 - x, 3);
		}
	}

	// progress at t seconds, and how long it takes (before the slowdown)
	function progressAt(value, t) {
		if (!value || value.kind === "off") return 1;
		if (value.kind === "spring") return root.springAt(t, value.damping, value.stiffness);
		return root.easeAt(Math.min(1, t / (value.duration / 1000)), value);
	}

	function lengthOf(value) {
		if (!value || value.kind === "off") return 0;
		if (value.kind === "easing") return value.duration / 1000;
		// until it stays within a hair of the target
		let last = 0;
		for (let t = 0; t < 4; t += 0.004)
			if (Math.abs(1 - root.springAt(t, value.damping, value.stiffness)) > 0.002) last = t;
		return last;
	}

	function summary(value) {
		if (!value || value.kind === "off") return "off";
		if (value.kind === "spring")
			return `${value.damping >= 0.995 ? "no bounce" : `bounce ${Math.round((1 - value.damping) / 0.9 * 100)}%`} · ${Math.round(root.lengthOf(value) * 1000)} ms`;
		return `${value.duration} ms · ${root.curveName(value)}`;
	}

	function curveName(value) {
		if (value.curve !== "cubic-bezier") return String(value.curve).replace("ease-out-", "");
		for (const name in root.shellCurves)
			if (JSON.stringify(root.shellCurves[name]) === JSON.stringify((value.bezier || []).map(Number))) return name;
		return "custom";
	}

	// ── talking to niri_motion.py ──────────────────────────────────────────
	Process {
		id: describeProcess
		command: ["python3", root.scriptPath, "describe"]
		stdout: StdioCollector {
			onStreamFinished: {
				try {
					const described = JSON.parse(text);
					root.nodes = described.nodes || [];
					root.slowdown = Number(described.slowdown || 1);
				} catch (error) {}
			}
		}
	}

	// one write at a time; the newest waiting one wins, after a short rest
	QtObject {
		id: writer

		property var pending: null

		function queue(args) {
			writer.pending = args;
			restTimer.restart();
		}

		function flush() {
			if (writer.pending === null || writeProcess.running) return;
			writeProcess.command = ["python3", root.scriptPath, ...writer.pending];
			writer.pending = null;
			writeProcess.running = true;
		}
	}

	Timer {
		id: restTimer
		interval: 350
		onTriggered: writer.flush()
	}

	Process {
		id: writeProcess
		onExited: {
			// a reset brings back the style's value, which only the config knows
			const verb = String(writeProcess.command[2] || "");
			if (writer.pending !== null) writer.flush();
			else if (verb === "reset") root.reload();
		}
	}

	RowLayout {
		anchors.fill: parent
		spacing: 16

		// ── the list ─────────────────────────────────────────────────────
		ColumnLayout {
			// a layout fills by default; the list keeps its width
			Layout.fillWidth: false
			Layout.preferredWidth: 340
			Layout.fillHeight: true
			spacing: 10

			Rectangle {
				Layout.fillWidth: true
				Layout.preferredHeight: speedColumn.implicitHeight + 24
				radius: Theme.radius.huge
				color: Theme.layer1

				ColumnLayout {
					id: speedColumn

					anchors.left: parent.left
					anchors.right: parent.right
					anchors.top: parent.top
					anchors.margins: 12
					spacing: 6

					StyledText {
						text: "Everything"
						font.pixelSize: Theme.size.label
						font.weight: Font.DemiBold
					}

					// niri's slowdown, 0.25× … 3×, on a log scale so 1× sits mid-way
					PillSlider {
						Layout.fillWidth: true
						icon: "speedometer"
						value: Math.log(root.slowdown / 0.25) / Math.log(12)
						valueText: Math.abs(root.slowdown - 1) < 0.03 ? "normal speed" : root.slowdown < 1 ? `${(1 / root.slowdown).toFixed(1)}× faster` : `${root.slowdown.toFixed(1)}× slower`
						stepSize: 0.02
						onMoved: value => {
							root.slowdown = Math.round(0.25 * Math.pow(12, value) * 20) / 20;
							writer.queue(["slowdown", String(root.slowdown)]);
							demo.restart();
						}
					}
				}
			}

			Flickable {
				Layout.fillWidth: true
				Layout.fillHeight: true
				contentHeight: nodeColumn.implicitHeight
				boundsBehavior: Flickable.StopAtBounds
				clip: true

				ColumnLayout {
					id: nodeColumn

					width: parent.width
					spacing: 6

					Repeater {
						model: root.nodes

						delegate: Rectangle {
							id: nodeCard

							required property var modelData
							readonly property bool picked: nodeCard.modelData.key === root.selectedKey

							Layout.fillWidth: true
							Layout.preferredHeight: 52
							radius: Theme.radius.large
							color: nodeCard.picked ? Theme.layer2 : (nodeMouse.containsMouse ? Theme.layer1 : "transparent")
							border.width: nodeCard.picked ? 2 : 0
							border.color: Theme.primary

							Behavior on color {
								ColorAnim {}
							}

							RowLayout {
								anchors.fill: parent
								anchors.leftMargin: 14
								anchors.rightMargin: 14
								spacing: 10

								ColumnLayout {
									Layout.fillWidth: true
									spacing: 1

									StyledText {
										text: nodeCard.modelData.label
										font.pixelSize: Theme.size.label
										font.weight: nodeCard.picked ? Font.Bold : Font.DemiBold
									}

									StyledText {
										Layout.fillWidth: true
										text: root.summary(nodeCard.modelData.current)
										tone: Theme.textSubtle
										font.family: Theme.monoFamily
										font.pixelSize: Theme.size.tiny
										elide: Text.ElideRight
									}
								}

								Rectangle {
									visible: nodeCard.modelData.custom
									Layout.preferredHeight: 20
									Layout.preferredWidth: customLabel.implicitWidth + 14
									radius: 10
									color: Qt.alpha(Theme.tertiary, 0.18)

									StyledText {
										id: customLabel

										anchors.centerIn: parent
										text: "custom"
										tone: Theme.tertiary
										font.pixelSize: Theme.size.tiny
										font.weight: Font.Bold
									}
								}
							}

							MouseArea {
								id: nodeMouse

								anchors.fill: parent
								hoverEnabled: true
								cursorShape: Qt.PointingHandCursor
								onClicked: root.selectedKey = nodeCard.modelData.key
							}
						}
					}
				}
			}
		}

		// ── the editor ───────────────────────────────────────────────────
		Rectangle {
			Layout.fillWidth: true
			Layout.fillHeight: true
			radius: Theme.radius.huge
			color: Theme.layer1
			visible: root.draft !== null

			ColumnLayout {
				anchors.fill: parent
				anchors.margins: 22
				spacing: 14

				RowLayout {
					Layout.fillWidth: true
					spacing: 12

					ColumnLayout {
						Layout.fillWidth: true
						spacing: 2

						StyledText {
							text: root.selected?.label ?? ""
							font.pixelSize: Theme.size.heading
							font.weight: Font.Bold
						}

						StyledText {
							text: root.selected?.description ?? ""
							tone: Theme.textMuted
						}
					}

					TextButton {
						text: "Reset"
						icon: "restore"
						visible: root.selected?.custom ?? false
						onActivated: {
							writer.queue(["reset", root.selectedKey]);
							writer.flush();
						}
					}
				}

				OptionRow {
					label: "Motion"

					Segmented {
						Layout.fillWidth: true
						options: [{ value: "spring", label: "Spring" }, { value: "easing", label: "Curve" }, { value: "off", label: "Off" }]
						current: root.draft?.kind ?? "spring"
						onSelected: value => root.setKind(value)
					}
				}

				// a spring: how much it bounces, how quickly it gets there
				OptionRow {
					label: "Bounce"
					visible: root.draft?.kind === "spring"

					PillSlider {
						id: bounceSlider

						Layout.fillWidth: true
						value: root.draft?.kind === "spring" ? (1 - root.draft.damping) / 0.9 : 0
						valueText: bounceSlider.display > 0.005 ? `${Math.round(bounceSlider.display * 100)}%` : "none"
						stepSize: 0.05
						onMoved: value => root.edit({ damping: Math.round((1 - value * 0.9) * 100) / 100 })
					}
				}

				OptionRow {
					label: "Stiffness"
					visible: root.draft?.kind === "spring"

					// 50 … 3000 on a log scale
					PillSlider {
						Layout.fillWidth: true
						value: root.draft?.kind === "spring" ? Math.log(root.draft.stiffness / 50) / Math.log(60) : 0
						valueText: root.draft?.kind === "spring" ? `${Math.round(root.draft.stiffness)}` : ""
						stepSize: 0.03
						onMoved: value => root.edit({ stiffness: Math.round(50 * Math.pow(60, value) / 10) * 10 })
					}
				}

				// a curve: how long, which shape
				OptionRow {
					label: "Duration"
					visible: root.draft?.kind === "easing"

					PillSlider {
						Layout.fillWidth: true
						value: root.draft?.kind === "easing" ? (root.draft.duration - 50) / 1450 : 0
						valueText: root.draft?.kind === "easing" ? `${root.draft.duration} ms` : ""
						stepSize: 10 / 1450
						onMoved: value => root.edit({ duration: Math.round((50 + value * 1450) / 10) * 10 })
					}
				}

				OptionRow {
					label: "Curve"
					visible: root.draft?.kind === "easing"

					Segmented {
						Layout.fillWidth: true
						options: [
							{ value: "linear", label: "Linear" },
							{ value: "quad", label: "Quad" },
							{ value: "cubic", label: "Cubic" },
							{ value: "expo", label: "Expo" },
							{ value: "land", label: "Land" },
							{ value: "decel", label: "Decel" },
							{ value: "accel", label: "Accel" },
							{ value: "standard", label: "Standard" }
						]
						current: root.draft?.kind === "easing" ? root.curveName(root.draft) : ""
						onSelected: value => {
							if (root.shellCurves[value]) root.edit({ curve: "cubic-bezier", bezier: root.shellCurves[value] });
							else root.edit({ curve: value === "linear" ? "linear" : `ease-out-${value}`, bezier: undefined });
						}
					}
				}

				StyledText {
					visible: root.draft?.kind === "off"
					text: "niri skips this animation: it happens at once."
					tone: Theme.textMuted
				}

				// ── the curve, drawn ─────────────────────────────────────
				Rectangle {
					Layout.fillWidth: true
					Layout.fillHeight: true
					Layout.minimumHeight: 140
					radius: Theme.radius.large
					color: Theme.layer2

					Canvas {
						id: graph

						anchors.fill: parent
						anchors.margins: 16

						readonly property var value: root.draft
						readonly property real span: Math.max(0.15, root.lengthOf(root.draft) * 1.1)
						onValueChanged: graph.requestPaint()
						onWidthChanged: graph.requestPaint()
						onHeightChanged: graph.requestPaint()

						onPaint: {
							const ctx = graph.getContext("2d");
							ctx.reset();
							const value = graph.value;
							if (!value) return;
							// room above the target for an overshoot
							const top = 1.35;
							const yOf = p => graph.height - (p + 0.05) / (top + 0.05) * graph.height;

							ctx.strokeStyle = Theme.textSubtle;
							ctx.lineWidth = 1;
							ctx.setLineDash([4, 4]);
							ctx.beginPath();
							ctx.moveTo(0, yOf(1));
							ctx.lineTo(graph.width, yOf(1));
							ctx.stroke();
							ctx.setLineDash([]);

							ctx.strokeStyle = Theme.primary;
							ctx.lineWidth = 2.5;
							ctx.beginPath();
							for (let i = 0; i <= 200; i += 1) {
								const t = i / 200 * graph.span;
								const x = i / 200 * graph.width;
								const y = yOf(value.kind === "off" ? 1 : root.progressAt(value, t));
								if (i === 0) ctx.moveTo(x, y);
								else ctx.lineTo(x, y);
							}
							ctx.stroke();

							// where the demo is now
							ctx.fillStyle = Theme.primary;
							ctx.beginPath();
							ctx.arc(Math.min(1, demo.clock / graph.span) * graph.width, yOf(demo.progress), 5, 0, 2 * Math.PI);
							ctx.fill();
						}
					}

					StyledText {
						anchors.right: parent.right
						anchors.bottom: parent.bottom
						anchors.margins: 12
						text: root.draft ? `${Math.round(root.lengthOf(root.draft) * root.slowdown * 1000)} ms` : ""
						tone: Theme.textSubtle
						font.family: Theme.monoFamily
						font.pixelSize: Theme.size.tiny
					}
				}

				// ── the demo: a window crossing back and forth ────────────
				Item {
					Layout.fillWidth: true
					Layout.preferredHeight: 84

					Rectangle {
						anchors.fill: parent
						radius: Theme.radius.large
						color: Theme.layer2
					}

					Rectangle {
						id: demoWindow

						readonly property real travel: parent.width - demoWindow.width - 24

						y: 12
						width: 110
						height: parent.height - 24
						x: 12 + demoWindow.travel * (demo.forward ? demo.progress : 1 - demo.progress)
						radius: Theme.radius.medium
						color: Theme.primaryContainer
						border.width: 1
						border.color: Qt.alpha(Theme.primary, 0.5)

						Rectangle {
							x: 10
							y: 12
							width: parent.width * 0.55
							height: 6
							radius: 3
							color: Theme.primary
						}

						Rectangle {
							x: 10
							y: 24
							width: parent.width * 0.7
							height: 4
							radius: 2
							color: Theme.textSubtle
						}
					}

					MouseArea {
						anchors.fill: parent
						cursorShape: Qt.PointingHandCursor
						onClicked: demo.restart()
					}
				}
			}
		}
	}

	// plays the draft in seconds as niri would (slowdown included), then
	// rests and goes back the other way
	FrameAnimation {
		id: demo

		property real clock: 0
		property real progress: 1
		property bool forward: true
		property real startedAt: 0
		readonly property real rest: 0.6

		running: root.visible && root.draft !== null

		function restart() {
			demo.startedAt = Date.now();
		}

		Component.onCompleted: demo.restart()

		onTriggered: {
			const length = root.lengthOf(root.draft);
			const elapsed = (Date.now() - demo.startedAt) / 1000 / root.slowdown;
			demo.clock = elapsed;
			demo.progress = root.progressAt(root.draft, elapsed);
			if (elapsed > length + demo.rest) {
				demo.forward = !demo.forward;
				demo.restart();
			}
			graph.requestPaint();
		}
	}
}
