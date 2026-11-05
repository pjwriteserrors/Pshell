pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.style.theme
import qs.style.widgets
import qs.core.services

// The last 24 hours of the machine: one curve to scrub through – the pointer
// says when, how much and who took the most then – and below what each app
// cost the processor on a day.
Item {
	id: root

	property var history: []
	property var tops: []
	property string metric: "cpu"
	property var usage: ({})
	property var days: []
	property string day: ""
	property real pointer: -1
	property real reveal: 0

	readonly property var metrics: [
		{ id: "cpu", label: "CPU", index: 1, color: Theme.primary, max: 1, format: v => TaskManager.percent(v, 0) },
		{ id: "memory", label: "Memory", index: 2, color: Theme.secondary, max: 1, format: v => TaskManager.percent(v, 0) },
		{ id: "gpu", label: "GPU", index: 3, color: Theme.tertiary, max: 1, format: v => TaskManager.percent(v, 0) },
		{ id: "temp", label: "Temperature", index: 4, color: Theme.danger, max: 100, format: v => `${Math.round(v)} °C` },
		{ id: "net", label: "Network", index: 5, color: Theme.warning, max: 0, format: v => Format.rate(v) },
		{ id: "disk", label: "Disk", index: 6, color: Theme.success, max: 0, format: v => Format.rate(v) },
		{ id: "watts", label: "Power", index: 7, color: Theme.success, max: 0, format: v => `${v.toFixed(1)} W` }
	]
	readonly property var current: root.metrics.find(m => m.id === root.metric) ?? root.metrics[0]
	readonly property real now: Date.now() / 1000
	readonly property real start: root.now - 86400
	readonly property real peak: {
		if (root.current.max > 0) return root.current.max;
		let top = 1;
		for (const sample of root.history) top = Math.max(top, Number(sample[root.current.index]) || 0);
		return top * 1.1;
	}
	readonly property var usageList: Object.keys(root.usage).map(key => Object.assign({ key: key }, root.usage[key]))
		.filter(item => item.s >= 1).sort((a, b) => b.s - a.s).slice(0, 14)
	readonly property real usageTop: root.usageList.length > 0 ? root.usageList[0].s : 1

	function reload() {
		TaskManager.history(data => {
			root.history = data.history ?? [];
			root.tops = data.tops ?? [];
			canvas.requestPaint();
		});
		TaskManager.usage(root.day, data => {
			root.usage = data.usage ?? {};
			root.days = data.days ?? [];
			if (root.day === "") root.day = data.day ?? "";
		});
	}

	Component.onCompleted: {
		root.reload();
		drawIn.restart();
	}
	onMetricChanged: {
		drawIn.restart();
		canvas.requestPaint();
	}
	onDayChanged: TaskManager.usage(root.day, data => root.usage = data.usage ?? {})
	onRevealChanged: canvas.requestPaint()
	onPointerChanged: canvas.requestPaint()

	NumberAnimation {
		id: drawIn

		target: root
		property: "reveal"
		from: 0
		to: 1
		duration: 900
		easing.type: Easing.OutCubic
	}

	Timer {
		running: root.visible
		interval: 30000
		repeat: true
		onTriggered: root.reload()
	}

	// the sample under the pointer, and who took the most then
	readonly property var atPointer: {
		if (root.pointer < 0 || root.history.length === 0) return null;
		const t = root.start + root.pointer / Math.max(1, canvas.width) * 86400;
		let best = null;
		for (const sample of root.history) {
			if (!best || Math.abs(sample[0] - t) < Math.abs(best[0] - t)) best = sample;
		}
		if (!best || Math.abs(best[0] - t) > 600) return null;
		let top = null;
		for (const entry of root.tops) {
			if (!top || Math.abs(entry[0] - best[0]) < Math.abs(top[0] - best[0])) top = entry;
		}
		return { sample: best, top: top && Math.abs(top[0] - best[0]) < 300 ? top[1] : [] };
	}

	Flickable {
		anchors.fill: parent
		contentHeight: body.implicitHeight + 40
		clip: true
		boundsBehavior: Flickable.StopAtBounds
		ScrollBar.vertical: ThinScrollBar {}

		ColumnLayout {
			id: body

			x: 24
			y: 18
			width: parent.width - 48
			spacing: 14

			Flow {
				Layout.fillWidth: true
				spacing: 6

				Repeater {
					model: root.metrics

					Chip {
						required property var modelData

						text: modelData.label
						selected: root.metric === modelData.id
						accent: modelData.color
						onClicked: root.metric = modelData.id
					}
				}
			}

			Rectangle {
				Layout.fillWidth: true
				Layout.preferredHeight: 260
				radius: Theme.radius.huge
				color: Theme.layer1
				border.width: 1
				border.color: Theme.outline
				clip: true

				Canvas {
					id: canvas

					anchors.fill: parent
					anchors.topMargin: 16
					anchors.bottomMargin: 26
					renderStrategy: Canvas.Cooperative
					onWidthChanged: requestPaint()

					onPaint: {
						const ctx = getContext("2d");
						ctx.reset();
						const w = width;
						const h = height;
						const color = root.current.color;
						// the hours
						ctx.strokeStyle = Theme.outline;
						ctx.lineWidth = 1;
						for (let hour = 0; hour <= 24; hour += 3) {
							const t = Math.ceil(root.start / 10800) * 10800 + hour * 3600;
							const x = Math.round((t - root.start) / 86400 * w) + 0.5;
							ctx.beginPath();
							ctx.moveTo(x, 0);
							ctx.lineTo(x, h);
							ctx.stroke();
						}
						const samples = root.history;
						if (samples.length < 2) return;
						ctx.save();
						ctx.beginPath();
						ctx.rect(0, 0, w * root.reveal, h);
						ctx.clip();
						const index = root.current.index;
						const xOf = t => (t - root.start) / 86400 * w;
						const yOf = v => h - Math.max(0, Math.min(1, (Number(v) || 0) / root.peak)) * (h - 2) - 1;
						// gaps of more than a minute: the machine slept or nothing watched
						let open = false;
						ctx.beginPath();
						let firstX = 0;
						let lastX = 0;
						const segments = [];
						for (let i = 0; i < samples.length; i += 1) {
							const s = samples[i];
							const x = xOf(s[0]);
							const y = yOf(s[index]);
							if (!open || s[0] - samples[i - 1][0] > 60) {
								if (open) segments.push([firstX, lastX]);
								ctx.moveTo(x, y);
								firstX = x;
								open = true;
							} else {
								ctx.lineTo(x, y);
							}
							lastX = x;
						}
						segments.push([firstX, lastX]);
						ctx.strokeStyle = color;
						ctx.lineWidth = 1.6;
						ctx.lineJoin = "round";
						ctx.stroke();
						// filled under each stretch
						const gradient = ctx.createLinearGradient(0, 0, 0, h);
						gradient.addColorStop(0, Qt.alpha(color, 0.3));
						gradient.addColorStop(1, Qt.alpha(color, 0.02));
						ctx.fillStyle = gradient;
						let segment = 0;
						ctx.beginPath();
						for (let i = 0; i < samples.length; i += 1) {
							const s = samples[i];
							const x = xOf(s[0]);
							if (i === 0 || s[0] - samples[i - 1][0] > 60) {
								if (i > 0) {
									ctx.lineTo(xOf(samples[i - 1][0]), h);
									ctx.closePath();
								}
								ctx.moveTo(x, h);
							}
							ctx.lineTo(x, yOf(s[index]));
						}
						ctx.lineTo(xOf(samples[samples.length - 1][0]), h);
						ctx.closePath();
						ctx.fill();
						ctx.restore();
						if (root.atPointer) {
							const x = xOf(root.atPointer.sample[0]);
							ctx.strokeStyle = Qt.alpha(Theme.text, 0.4);
							ctx.beginPath();
							ctx.moveTo(Math.round(x) + 0.5, 0);
							ctx.lineTo(Math.round(x) + 0.5, h);
							ctx.stroke();
							ctx.fillStyle = color;
							ctx.beginPath();
							ctx.arc(x, yOf(root.atPointer.sample[index]), 4, 0, Math.PI * 2);
							ctx.fill();
						}
					}

					HoverHandler {
						id: hover

						onPointChanged: root.pointer = hover.hovered ? hover.point.position.x : -1
						onHoveredChanged: if (!hover.hovered) root.pointer = -1
					}
				}

				// the hours under it
				Repeater {
					model: 9

					StyledText {
						required property int index
						readonly property real t: Math.ceil(root.start / 10800) * 10800 + index * 10800

						x: (t - root.start) / 86400 * canvas.width - width / 2
						y: parent.height - 20
						visible: x > 0 && x < parent.width - width
						text: Qt.formatTime(new Date(t * 1000), "HH:mm")
						tone: Theme.textSubtle
						font.pixelSize: Theme.size.tiny
						tabular: true
					}
				}

				StyledText {
					anchors.centerIn: parent
					visible: root.history.length < 2
					text: "The day fills in while the shell runs"
					tone: Theme.textSubtle
				}

				// what the pointer reads off
				Rectangle {
					visible: opacity > 0
					opacity: root.atPointer ? 1 : 0
					x: Math.max(8, Math.min(parent.width - width - 8, root.pointer + 14))
					y: 12
					width: readout.implicitWidth + 20
					height: readout.implicitHeight + 16
					radius: Theme.radius.medium
					color: Theme.layer3

					Behavior on opacity {
						Anim {
							duration: Motion.short
						}
					}

					Column {
						id: readout

						x: 10
						y: 8
						spacing: 4

						StyledText {
							text: root.atPointer ? `${Qt.formatTime(new Date(root.atPointer.sample[0] * 1000), "HH:mm")} · ${root.current.format(root.atPointer.sample[root.current.index])}` : ""
							font.weight: Font.DemiBold
							tabular: true
						}

						Repeater {
							model: root.atPointer?.top ?? []

							StyledText {
								required property var modelData

								text: `${TaskManager.nameOf({ t: "group", kind: String(modelData[1]).startsWith("glyph:") || modelData[1] === "" ? "" : "app", i: modelData[1], n: modelData[0] })}  ${TaskManager.percent(modelData[2], 0)}`
								tone: Theme.textMuted
								font.pixelSize: Theme.size.small
							}
						}
					}
				}
			}

			// ── what each app cost the processor ───────────────────────────
			RowLayout {
				Layout.fillWidth: true
				Layout.topMargin: 10
				spacing: 8

				SectionLabel {
					Layout.fillWidth: true
					text: "Processor time by app"
				}

				Repeater {
					model: root.days.slice(-7)

					Chip {
						required property string modelData

						text: {
							const date = new Date(`${modelData}T12:00:00`);
							const today = new Date();
							if (date.toDateString() === today.toDateString()) return "Today";
							if (date.toDateString() === new Date(today.getTime() - 86400000).toDateString()) return "Yesterday";
							return Qt.formatDate(date, "ddd");
						}
						selected: root.day === modelData
						onClicked: root.day = modelData
					}
				}
			}

			Repeater {
				model: root.usageList

				RowLayout {
					id: usageRow

					required property var modelData
					required property int index
					readonly property var row: ({ t: "group", kind: usageRow.modelData.k, i: usageRow.modelData.i, n: usageRow.modelData.n })
					readonly property string icon: TaskManager.iconOf(usageRow.row)
					property real grown: 0

					Layout.fillWidth: true
					spacing: 12
					Component.onCompleted: grow.start()

					SequentialAnimation {
						id: grow

						PauseAnimation {
							duration: usageRow.index * 40
						}
						NumberAnimation {
							target: usageRow
							property: "grown"
							to: 1
							duration: 700
							easing.type: Easing.OutCubic
						}
					}

					Item {
						Layout.preferredWidth: 22
						Layout.preferredHeight: 22

						Image {
							anchors.fill: parent
							visible: !usageRow.icon.startsWith("glyph:")
							source: usageRow.icon.startsWith("glyph:") ? "" : usageRow.icon
							sourceSize: Qt.size(44, 44)
							asynchronous: true
						}

						Glyph {
							anchors.centerIn: parent
							visible: usageRow.icon.startsWith("glyph:")
							icon: usageRow.icon.slice(6)
							size: 16
							color: Theme.textMuted
						}
					}

					StyledText {
						Layout.preferredWidth: 170
						text: TaskManager.nameOf(usageRow.row)
						elide: Text.ElideRight
					}

					Item {
						Layout.fillWidth: true
						Layout.preferredHeight: 10

						Rectangle {
							width: parent.width * usageRow.modelData.s / root.usageTop * usageRow.grown
							height: parent.height
							radius: 5
							color: Qt.alpha(Theme.primary, 0.75 - usageRow.index * 0.035)
						}
					}

					StyledText {
						Layout.preferredWidth: 80
						horizontalAlignment: Text.AlignRight
						text: Format.duration(usageRow.modelData.s)
						tone: Theme.textMuted
						tabular: true
					}
				}
			}

			EmptyState {
				Layout.alignment: Qt.AlignHCenter
				visible: root.usageList.length === 0
				icon: "chart_timeline_variant"
				title: "Nothing counted yet"
			}
		}
	}
}
