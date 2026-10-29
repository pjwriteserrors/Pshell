pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// One download under way. Its ring and bar fill as it comes in – an
// accelerated one shows its parts, each with its own connection – with
// how far, how fast and how long still. A click folds out its speed over
// time, peak and average, every connection's speed as a bar of its own and
// what one connection alone would do; or, for one the browser downloads
// normally, why it was not accelerated. Through, it turns green with a
// check for a moment before it moves on to the finished ones.
Clickable {
	id: root

	required property string key
	property bool expanded: false
	// it just finished: shown a moment longer, in green
	property bool justDone: false

	readonly property var item: Downloads.table[root.key] ?? null
	readonly property string state_: root.justDone ? "done" : (root.item?.state ?? "")
	readonly property bool running: root.state_ === "running"
	readonly property bool checking: Boost.checking[root.key] === true
	readonly property bool boosted: root.item?.source === "boost" && root.item?.mode === "boost"
	readonly property string mode: root.checking ? "checking" : (root.boosted ? "boost" : (root.item?.source === "torrent" ? "torrent" : "normal"))
	readonly property real ratio: root.item && root.item.total > 0 ? Math.min(1, root.item.received / root.item.total) : (root.state_ === "done" ? 1 : 0)
	readonly property color accent: root.state_ === "failed" ? Theme.danger : (root.state_ === "done" ? Theme.success : (root.state_ === "paused" ? Theme.textSubtle : Theme.primary))
	readonly property var curve: Downloads.curve(root.key)
	readonly property real speedup: root.boosted && (root.item?.bestSingle ?? 0) > 0 && (root.item?.speed ?? 0) > 0 ? root.item.speed / root.item.bestSingle : 0

	implicitHeight: body.implicitHeight + 28
	radius: Theme.radius.large
	color: root.justDone ? Qt.tint(Theme.layer1, Qt.alpha(Theme.success, 0.14)) : (root.hovered ? Theme.layer2 : Theme.layer1)
	pressedScale: 0.985
	onClicked: root.expanded = !root.expanded

	Behavior on color {
		ColorAnim {
			duration: Motion.long
		}
	}
	Behavior on implicitHeight {
		SpatialAnim {
			duration: Motion.long
		}
	}

	// a soft light of the accent behind the card while it runs boosted
	Rectangle {
		anchors.fill: parent
		radius: root.radius
		opacity: root.boosted && root.running ? 1 : 0
		gradient: Gradient {
			orientation: Gradient.Horizontal
			GradientStop { position: 0; color: Qt.alpha(Theme.primary, 0.09) }
			GradientStop { position: 0.6; color: Qt.alpha(Theme.primary, 0) }
		}

		Behavior on opacity {
			Anim {
				duration: Motion.extraLong
			}
		}
	}

	ColumnLayout {
		id: body

		x: 14
		y: 14
		width: parent.width - 28
		spacing: 10

		RowLayout {
			Layout.fillWidth: true
			spacing: 12

			// the ring around its kind of file
			Item {
				Layout.preferredWidth: 40
				Layout.preferredHeight: 40

				Ring {
					id: ring

					anchors.fill: parent
					value: root.ratio
					thickness: 3
					color: root.accent
					trackColor: Qt.alpha(root.accent, 0.16)
				}

				Glyph {
					id: kind

					anchors.centerIn: parent
					icon: root.state_ === "done" ? "check_bold" : (root.state_ === "failed" ? "alert_circle_outline" : Downloads.glyphOf(root.item))
					size: 17
					color: root.accent
					scale: 1

					// the check comes in with a pop
					SequentialAnimation {
						running: root.justDone
						NumberAnimation { target: kind; property: "scale"; to: 1.45; duration: 180; easing.type: Easing.OutCubic }
						NumberAnimation { target: kind; property: "scale"; to: 1; duration: 420; easing.type: Easing.OutBack; easing.overshoot: 2.4 }
					}
				}

				// a ripple from the ring when it is through
				Rectangle {
					id: ripple

					anchors.centerIn: parent
					width: parent.width
					height: width
					radius: width / 2
					color: "transparent"
					border.width: 2
					border.color: Theme.success
					opacity: 0

					ParallelAnimation {
						running: root.justDone
						NumberAnimation { target: ripple; property: "scale"; from: 1; to: 1.9; duration: 700; easing.type: Easing.OutCubic }
						NumberAnimation { target: ripple; property: "opacity"; from: 0.8; to: 0; duration: 700; easing.type: Easing.OutCubic }
					}
				}
			}

			ColumnLayout {
				Layout.fillWidth: true
				spacing: 2

				StyledText {
					Layout.fillWidth: true
					text: root.item?.name ?? ""
					elide: Text.ElideMiddle
					font.pixelSize: Theme.size.body
					font.weight: Font.DemiBold
				}

				StyledText {
					Layout.fillWidth: true
					text: {
						const item = root.item;
						if (!item) return "";
						const parts = [];
						if (item.host) parts.push(item.host);
						if (item.total > 0) parts.push(Format.bytes(item.total));
						return parts.join("  ·  ");
					}
					font.pixelSize: Theme.size.small
					tone: Theme.textSubtle
					elide: Text.ElideRight
				}
			}

			ModeBadge {
				mode: root.mode
				live: root.running
				text: {
					if (root.mode === "checking") return "Checking server";
					if (root.mode === "boost") return root.running ? `${root.item.connections} connections` : "Accelerated";
					if (root.mode === "torrent") return "Torrent";
					return "Normal";
				}
			}

			// quick hands while the pointer is on it
			Row {
				spacing: 2
				opacity: root.hovered && !root.justDone ? 1 : 0
				visible: opacity > 0.01
				Layout.preferredWidth: root.hovered && !root.justDone ? implicitWidth : 0

				Behavior on opacity {
					Anim {}
				}
				Behavior on Layout.preferredWidth {
					SpatialAnim {
						duration: Motion.medium
					}
				}

				IconButton {
					implicitWidth: 30
					implicitHeight: 30
					iconSize: 16
					visible: root.state_ === "running" || root.state_ === "paused" || (root.state_ === "failed" && root.item?.canResume)
					icon: root.state_ === "running" ? "pause" : "play"
					onClicked: root.state_ === "running" ? Downloads.pause(root.key) : Downloads.resume(root.key)
				}

				IconButton {
					implicitWidth: 30
					implicitHeight: 30
					iconSize: 16
					icon: "close"
					onClicked: root.state_ === "failed" ? Downloads.dismiss(root.key) : Downloads.cancel(root.key)
				}
			}
		}

		// the bar: in parts when accelerated
		Item {
			Layout.fillWidth: true
			Layout.preferredHeight: 8

			PartsMap {
				anchors.fill: parent
				visible: root.boosted && (root.item?.parts?.length ?? 0) > 0 && !root.justDone
				parts: root.item?.parts ?? []
				running: root.running
				accent: root.accent
			}

			ProgressStrip {
				anchors.fill: parent
				visible: !root.boosted || (root.item?.parts?.length ?? 0) === 0 || root.justDone
				value: root.ratio
				known: (root.item?.total ?? 0) > 0 || root.state_ === "done"
				running: root.running
				accent: root.accent
			}
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 8

			StyledText {
				Layout.fillWidth: true
				text: {
					const item = root.item;
					if (!item) return "";
					if (root.justDone) {
						const seconds = item.activeTime > 0 ? item.activeTime : ((item.finished || Date.now()) - item.started) / 1000;
						return `Done in ${Format.duration(seconds, true)}  ·  Ø ${Format.rate(Math.max(item.total, item.received) / Math.max(0.5, seconds))}`;
					}
					if (root.state_ === "failed") return item.error || "Failed";
					const how = item.total > 0 ? `${Math.floor(root.ratio * 100)} %  ·  ${Format.bytes(item.received)} of ${Format.bytes(item.total)}` : Format.bytes(item.received);
					return root.state_ === "paused" ? `Paused  ·  ${how}` : how;
				}
				font.pixelSize: Theme.size.small
				tone: root.state_ === "failed" ? Theme.danger : (root.justDone ? Theme.success : Theme.textMuted)
				tabular: true
				elide: Text.ElideRight
			}

			RollingText {
				visible: root.running
				value: root.item?.speed ?? 0
				format: value => Format.rate(value)
				font.pixelSize: Theme.size.label
				font.weight: Font.Bold
				tone: root.accent
			}

			StyledText {
				visible: root.running && (root.item?.eta ?? -1) >= 0
				text: `${Downloads.formatEta(root.item?.eta ?? -1)} left`
				font.pixelSize: Theme.size.small
				tone: Theme.textSubtle
				tabular: true
			}

			Glyph {
				icon: "chevron_down"
				size: 16
				color: Theme.textSubtle
				rotation: root.expanded ? 180 : 0
				visible: !root.justDone

				Behavior on rotation {
					SpatialAnim {
						duration: Motion.medium
					}
				}
			}
		}

		// ── folded out ─────────────────────────────────────────────────────
		Item {
			Layout.fillWidth: true
			Layout.preferredHeight: root.expanded && !root.justDone ? more.implicitHeight : 0
			clip: true
			opacity: root.expanded && !root.justDone ? 1 : 0
			visible: Layout.preferredHeight > 0.5

			Behavior on Layout.preferredHeight {
				SpatialAnim {
					duration: Motion.long
				}
			}
			Behavior on opacity {
				Anim {
					duration: root.expanded ? Motion.long : Motion.short
				}
			}

			ColumnLayout {
				id: more

				width: parent.width
				spacing: 10

				// speed over time
				Rectangle {
					Layout.fillWidth: true
					Layout.topMargin: 2
					Layout.preferredHeight: 64
					radius: Theme.radius.medium
					color: Qt.alpha(Theme.base, 0.35)
					clip: true

					Sparkline {
						anchors.fill: parent
						anchors.topMargin: 8
						values: root.curve.length > 1 ? root.curve.slice(-90) : [0, 0]
						color: root.accent
					}

					StyledText {
						anchors.left: parent.left
						anchors.top: parent.top
						anchors.margins: 8
						text: root.curve.length > 1 ? `Peak ${Format.rate(Math.max(...root.curve))}` : "Speed over time"
						font.pixelSize: Theme.size.tiny
						tone: Theme.textSubtle
						tabular: true
					}
				}

				// the figures
				GridLayout {
					Layout.fillWidth: true
					columns: 4
					columnSpacing: 8
					rowSpacing: 8

					Repeater {
						model: {
							const item = root.item;
							if (!item) return [];
							const seconds = item.activeTime > 0 ? item.activeTime : Math.max(1, (Date.now() - item.started) / 1000);
							const average = item.average > 0 ? item.average : item.received / seconds;
							const peak = Math.max(item.peak || 0, ...root.curve, 0);
							const out = [
								{ label: "Average", value: Format.rate(average), icon: "speedometer" },
								{ label: "Peak", value: Format.rate(peak), icon: "flash" },
								{ label: "Running", value: Format.duration(seconds, true), icon: "timer_outline" }
							];
							if (root.boosted) out.push({ label: "Faster", value: root.speedup > 1 ? `×${root.speedup.toFixed(1)}` : "–", icon: "lightning_bolt", accent: true });
							else out.push({ label: "Connections", value: "1", icon: "lan_connect" });
							return out;
						}

						delegate: Rectangle {
							id: figure

							required property var modelData
							Layout.fillWidth: true
							Layout.preferredHeight: 50
							radius: Theme.radius.medium
							color: figure.modelData.accent ? Qt.alpha(Theme.primary, 0.14) : Theme.layer2

							ColumnLayout {
								anchors.fill: parent
								anchors.margins: 8
								spacing: 1

								RowLayout {
									spacing: 4

									Glyph {
										icon: figure.modelData.icon
										size: 11
										color: figure.modelData.accent ? Theme.primary : Theme.textSubtle
									}

									StyledText {
										text: figure.modelData.label
										font.pixelSize: Theme.size.tiny
										tone: Theme.textSubtle
									}
								}

								StyledText {
									Layout.fillWidth: true
									text: figure.modelData.value
									font.pixelSize: Theme.size.body
									font.weight: Font.DemiBold
									tone: figure.modelData.accent ? Theme.primary : Theme.text
									tabular: true
									elide: Text.ElideRight
								}
							}
						}
					}
				}

				// every connection's speed, side by side
				ColumnLayout {
					Layout.fillWidth: true
					visible: root.boosted
					spacing: 6

					RowLayout {
						Layout.fillWidth: true

						StyledText {
							text: "Connections"
							font.pixelSize: Theme.size.small
							font.weight: Font.DemiBold
							tone: Theme.textMuted
						}

						Item {
							Layout.fillWidth: true
						}

						StyledText {
							text: {
								const item = root.item;
								if (!item) return "";
								const single = item.bestSingle > 0 ? `one alone ≈ ${Format.rate(item.bestSingle)}` : "";
								const parts = [`${item.connections} of ${item.limit}`, `${item.segments} parts`];
								if (single !== "") parts.push(single);
								return parts.join("  ·  ");
							}
							font.pixelSize: Theme.size.tiny
							tone: Theme.textSubtle
							tabular: true
						}
					}

					Item {
						id: lanes

						readonly property var speeds: root.item?.speeds ?? []
						readonly property real highest: Math.max(1, ...lanes.speeds)

						Layout.fillWidth: true
						Layout.preferredHeight: 34

						Row {
							anchors.fill: parent
							spacing: 4

							Repeater {
								model: Math.max(1, root.item?.wanted ?? 8)

								delegate: Item {
									id: lane

									required property int index
									readonly property real speed: lane.index < lanes.speeds.length ? lanes.speeds[lane.index] : -1

									width: (lanes.width - 4 * (Math.max(1, root.item?.wanted ?? 8) - 1)) / Math.max(1, root.item?.wanted ?? 8)
									height: lanes.height

									Rectangle {
										anchors.fill: parent
										radius: 4
										color: Theme.layer2
										opacity: lane.speed < 0 ? 0.45 : 1
									}

									Rectangle {
										anchors.bottom: parent.bottom
										width: parent.width
										height: lane.speed > 0 ? Math.max(3, parent.height * lane.speed / lanes.highest) : 0
										radius: 4
										color: Theme.primary
										opacity: 0.55 + 0.45 * (lane.speed > 0 ? lane.speed / lanes.highest : 0)

										Behavior on height {
											NumberAnimation {
												duration: 800
												easing.type: Easing.OutCubic
											}
										}
									}
								}
							}
						}
					}
				}

				// why it goes the normal way
				RowLayout {
					Layout.fillWidth: true
					visible: !root.boosted && root.item?.source !== "torrent"
					spacing: 8

					Glyph {
						icon: "information_outline"
						size: 14
						color: Theme.textSubtle
					}

					StyledText {
						Layout.fillWidth: true
						wrapMode: Text.Wrap
						text: {
							const item = root.item;
							if (!item) return "";
							if (root.checking) return "The accelerator is asking the server whether it sends parts…";
							if (item.note) return `${item.note} – downloading the normal way.`;
							if (item.source === "boost") return "Over one connection.";
							if (!Boost.enabled) return "The accelerator is off (plugin Download accelerator).";
							if (!Downloads.boost) return "Browser downloads are not handed to the accelerator (settings).";
							return "Downloading the normal way, in the browser.";
						}
						font.pixelSize: Theme.size.small
						tone: Theme.textMuted
					}
				}

				RowLayout {
					Layout.fillWidth: true
					spacing: 6

					TextButton {
						visible: root.state_ === "running" || root.state_ === "paused" || (root.state_ === "failed" && root.item?.canResume)
						text: root.state_ === "running" ? "Pause" : (root.state_ === "failed" ? "Try again" : "Resume")
						icon: root.state_ === "running" ? "pause" : (root.state_ === "failed" ? "refresh" : "play")
						onActivated: root.state_ === "running" ? Downloads.pause(root.key) : Downloads.resume(root.key)
					}

					TextButton {
						visible: (root.item?.path ?? "") !== ""
						text: "Folder"
						icon: "folder_open"
						variant: "ghost"
						onActivated: Downloads.reveal(root.key)
					}

					TextButton {
						visible: (root.item?.url ?? "") !== ""
						text: "Link"
						icon: "content_copy"
						variant: "ghost"
						onActivated: Downloads.copyLink(root.key)
					}

					Item {
						Layout.fillWidth: true
					}

					TextButton {
						text: "Cancel"
						icon: "close"
						variant: "danger"
						confirm: true
						confirmText: "Cancel it?"
						onActivated: root.state_ === "failed" ? Downloads.dismiss(root.key) : Downloads.cancel(root.key)
					}
				}
			}
		}
	}
}
