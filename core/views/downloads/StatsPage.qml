pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// The statistics: how much came in and how many files, how much time the
// accelerator saved and how much faster it was than one connection; the
// accelerated beside the normal downloads (their average speeds, how much
// of everything went faster); every day as a bar; the servers downloaded
// from most and whether they send parts; the fastest and biggest download.
// For the last 7 or 30 days or all of it; everything counts up when shown.
ColumnLayout {
	id: root

	property bool shown: false
	// 7 | 30 | 0 (all)
	property int range: 7

	readonly property var boost: Downloads.totals("boost", root.range)
	readonly property var normal: Downloads.totals("normal", root.range)
	readonly property var torrent: Downloads.totals("torrent", root.range)
	readonly property real bytes: root.boost.bytes + root.normal.bytes + root.torrent.bytes
	readonly property int count: root.boost.count + root.normal.count + root.torrent.count
	readonly property real boostSpeed: root.boost.seconds > 0 ? root.boost.bytes / root.boost.seconds : 0
	readonly property real normalSpeed: root.normal.seconds > 0 ? root.normal.bytes / root.normal.seconds : 0
	// how long the accelerated ones would have taken over one connection, against how long they took
	readonly property real factor: root.boost.seconds > 0 ? (root.boost.seconds + root.boost.saved) / root.boost.seconds : 0
	readonly property real share: root.boost.bytes + root.normal.bytes > 0 ? root.boost.bytes / (root.boost.bytes + root.normal.bytes) : 0
	readonly property var recent: {
		const since = root.range > 0 ? Date.now() - root.range * 86400000 : 0;
		return (Downloads.stats.recent || []).filter(entry => entry.at >= since);
	}
	readonly property var fastest: root.recent.filter(entry => entry.mode !== "torrent").reduce((best, entry) => !best || entry.average > best.average ? entry : best, null)
	readonly property var biggest: root.recent.reduce((best, entry) => !best || entry.bytes > best.bytes ? entry : best, null)
	readonly property var hosts: {
		const all = Downloads.stats.hosts || {};
		return Object.keys(all).map(name => Object.assign({ name: name }, all[name])).sort((a, b) => b.bytes - a.bytes).slice(0, 5);
	}

	// the figures count up again whenever the page or the range changes
	property bool play: false
	onShownChanged: root.replay()
	onRangeChanged: root.replay()

	function replay() {
		root.play = false;
		if (root.shown) replayTimer.restart();
	}

	Timer {
		id: replayTimer

		interval: 60
		onTriggered: root.play = true
	}

	spacing: 12

	RowLayout {
		Layout.fillWidth: true
		spacing: 8

		Segmented {
			Layout.preferredWidth: 300
			implicitHeight: 32
			current: String(root.range)
			options: [{ value: "7", label: "7 days" }, { value: "30", label: "30 days" }, { value: "0", label: "All time" }]
			onSelected: value => root.range = Number(value)
		}

		Item {
			Layout.fillWidth: true
		}

		StyledText {
			text: `since ${Qt.formatDate(new Date(Downloads.stats.since || Date.now()), "d MMM yyyy")}`
			font.pixelSize: Theme.size.tiny
			tone: Theme.textFaint
		}
	}

	EmptyState {
		Layout.fillWidth: true
		Layout.topMargin: 30
		Layout.bottomMargin: 30
		visible: root.count === 0
		icon: "chart_bar"
		title: root.range > 0 ? "Nothing downloaded these days" : "No statistics yet"
		subtitle: "Every finished download leaves its figures here – accelerated and normal ones."
	}

	ColumnLayout {
		Layout.fillWidth: true
		visible: root.count > 0
		spacing: 12

		GridLayout {
			Layout.fillWidth: true
			columns: 4
			columnSpacing: 8
			rowSpacing: 8

			FigureTile {
				Layout.fillWidth: true
				Layout.preferredWidth: 1
				icon: "download"
				label: "Downloaded"
				value: root.bytes
				play: root.play
				format: value => Format.bytes(value)
				note: `${root.count} file${root.count === 1 ? "" : "s"}`
			}

			FigureTile {
				Layout.fillWidth: true
				Layout.preferredWidth: 1
				icon: "lightning_bolt"
				label: "Faster"
				value: root.factor
				play: root.play
				highlight: root.factor > 1.05
				format: value => value > 0 ? `×${value.toFixed(1)}` : "–"
				note: "than one connection"
			}

			FigureTile {
				Layout.fillWidth: true
				Layout.preferredWidth: 1
				icon: "clock_fast"
				label: "Time saved"
				value: root.boost.saved
				play: root.play
				accent: Theme.success
				format: value => value >= 1 ? Format.duration(value, true) : "–"
				note: `${root.boost.count} accelerated`
			}

			FigureTile {
				Layout.fillWidth: true
				Layout.preferredWidth: 1
				icon: "speedometer"
				label: "Average"
				value: root.boost.seconds + root.normal.seconds > 0 ? (root.boost.bytes + root.normal.bytes) / (root.boost.seconds + root.normal.seconds) : 0
				play: root.play
				accent: Theme.secondary
				format: value => Format.rate(value, "–")
				note: "over all downloads"
			}
		}

		// accelerated beside normal
		Rectangle {
			Layout.fillWidth: true
			implicitHeight: compare.implicitHeight + 28
			radius: Theme.radius.large
			color: Theme.layer1

			RowLayout {
				id: compare

				x: 14
				y: 14
				width: parent.width - 28
				spacing: 18

				// how much of it all went faster
				Item {
					Layout.preferredWidth: 86
					Layout.preferredHeight: 86

					Ring {
						anchors.fill: parent
						value: root.play ? root.share : 0
						thickness: 9
						color: Theme.primary
						trackColor: Qt.alpha(Theme.text, 0.12)
					}

					ColumnLayout {
						anchors.centerIn: parent
						spacing: -2

						RollingText {
							Layout.alignment: Qt.AlignHCenter
							value: root.play ? root.share * 100 : 0
							duration: 1100
							format: value => `${Math.round(value)} %`
							font.pixelSize: Theme.size.title
							font.weight: Font.Bold
						}

						StyledText {
							Layout.alignment: Qt.AlignHCenter
							text: "accelerated"
							font.pixelSize: Theme.size.tiny
							tone: Theme.textSubtle
						}
					}
				}

				ColumnLayout {
					Layout.fillWidth: true
					spacing: 12

					Repeater {
						model: [
							{ label: "Accelerated", icon: "lightning_bolt", speed: root.boostSpeed, bucket: root.boost, color: Theme.primary },
							{ label: "Normal", icon: "download", speed: root.normalSpeed, bucket: root.normal, color: Qt.alpha(Theme.text, 0.45) }
						]

						delegate: ColumnLayout {
							id: line

							required property var modelData
							required property int index
							Layout.fillWidth: true
							spacing: 5

							RowLayout {
								Layout.fillWidth: true
								spacing: 6

								Glyph {
									icon: line.modelData.icon
									size: 13
									color: line.index === 0 ? Theme.primary : Theme.textMuted
								}

								StyledText {
									text: line.modelData.label
									font.pixelSize: Theme.size.small
									font.weight: Font.DemiBold
								}

								StyledText {
									Layout.fillWidth: true
									text: `${line.modelData.bucket.count}  ·  ${Format.bytes(line.modelData.bucket.bytes)}`
									font.pixelSize: Theme.size.tiny
									tone: Theme.textSubtle
									tabular: true
								}

								RollingText {
									value: root.play ? line.modelData.speed : 0
									duration: 1100
									format: value => `Ø ${Format.rate(value, "–")}`
									font.pixelSize: Theme.size.small
									font.weight: Font.Bold
									tone: line.index === 0 ? Theme.primary : Theme.text
								}
							}

							Rectangle {
								Layout.fillWidth: true
								Layout.preferredHeight: 10
								radius: 5
								color: Theme.layer2

								Rectangle {
									readonly property real highest: Math.max(1, root.boostSpeed, root.normalSpeed)
									height: parent.height
									radius: 5
									width: root.play ? Math.max(line.modelData.speed > 0 ? 10 : 0, parent.width * line.modelData.speed / highest) : 0
									color: line.modelData.color

									Behavior on width {
										SequentialAnimation {
											PauseAnimation {
												duration: 120 + line.index * 120
											}
											NumberAnimation {
												duration: 900
												easing.type: Easing.OutCubic
											}
										}
									}
								}
							}
						}
					}

					StyledText {
						Layout.fillWidth: true
						visible: root.boostSpeed > 0 && root.normalSpeed > 0
						text: root.boostSpeed > root.normalSpeed ? `Accelerated downloads came ${(root.boostSpeed / root.normalSpeed).toFixed(1)}× as fast as normal ones.` : "Normal downloads were as fast here – these servers send quickly anyway."
						wrapMode: Text.Wrap
						font.pixelSize: Theme.size.tiny
						tone: Theme.textSubtle
					}
				}
			}
		}

		// day by day
		Rectangle {
			Layout.fillWidth: true
			implicitHeight: days.implicitHeight + 28
			radius: Theme.radius.large
			color: Theme.layer1

			ColumnLayout {
				id: days

				x: 14
				y: 14
				width: parent.width - 28
				spacing: 10

				RowLayout {
					Layout.fillWidth: true
					spacing: 12

					StyledText {
						Layout.fillWidth: true
						text: root.range === 30 || root.range === 0 ? "Last 30 days" : "Last 14 days"
						font.pixelSize: Theme.size.small
						font.weight: Font.DemiBold
					}

					Repeater {
						model: [{ label: "Accelerated", color: Theme.primary }, { label: "Normal", color: Qt.alpha(Theme.text, 0.32) }].concat(root.torrent.count > 0 || Downloads.totals("torrent").count > 0 ? [{ label: "Torrent", color: Theme.tertiary }] : [])

						delegate: RowLayout {
							required property var modelData
							spacing: 5

							Rectangle {
								implicitWidth: 8
								implicitHeight: 8
								radius: 2
								color: parent.modelData.color
							}

							StyledText {
								text: parent.modelData.label
								font.pixelSize: Theme.size.tiny
								tone: Theme.textMuted
							}
						}
					}
				}

				DayBars {
					Layout.fillWidth: true
					days: Downloads.dayList(root.range === 7 ? 14 : 30)
					play: root.play
				}
			}
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 8

			// where from
			Rectangle {
				Layout.fillWidth: true
				Layout.preferredWidth: 3
				Layout.alignment: Qt.AlignTop
				implicitHeight: hostList.implicitHeight + 28
				radius: Theme.radius.large
				color: Theme.layer1
				visible: root.hosts.length > 0

				ColumnLayout {
					id: hostList

					x: 14
					y: 14
					width: parent.width - 28
					spacing: 8

					StyledText {
						text: "Servers"
						font.pixelSize: Theme.size.small
						font.weight: Font.DemiBold
					}

					Repeater {
						model: root.hosts

						delegate: ColumnLayout {
							id: host

							required property var modelData
							required property int index
							Layout.fillWidth: true
							spacing: 3

							RowLayout {
								Layout.fillWidth: true
								spacing: 6

								StyledText {
									Layout.fillWidth: true
									text: host.modelData.name
									font.pixelSize: Theme.size.small
									elide: Text.ElideMiddle
								}

								Glyph {
									icon: host.modelData.boost > 0 ? "lightning_bolt" : "download"
									size: 11
									color: host.modelData.boost > 0 ? Theme.primary : Theme.textSubtle
								}

								StyledText {
									text: `${Format.bytes(host.modelData.bytes)}  ·  Ø ${Format.rate(host.modelData.seconds > 0 ? host.modelData.bytes / host.modelData.seconds : 0, "–")}`
									font.pixelSize: Theme.size.tiny
									tone: Theme.textSubtle
									tabular: true
								}
							}

							Rectangle {
								Layout.fillWidth: true
								Layout.preferredHeight: 4
								radius: 2
								color: Theme.layer2

								Rectangle {
									height: parent.height
									radius: 2
									width: root.play ? parent.width * host.modelData.bytes / Math.max(1, root.hosts[0].bytes) : 0
									color: host.modelData.boost > 0 ? Theme.primary : Qt.alpha(Theme.text, 0.4)

									Behavior on width {
										SequentialAnimation {
											PauseAnimation {
												duration: 200 + host.index * 70
											}
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
			}

			// the records
			ColumnLayout {
				Layout.fillWidth: true
				Layout.preferredWidth: 2
				Layout.alignment: Qt.AlignTop
				spacing: 8

				Repeater {
					model: [
						{ label: "Fastest", icon: "flash", entry: root.fastest, value: root.fastest ? `Ø ${Format.rate(root.fastest.average)}` : "" },
						{ label: "Biggest", icon: "package_variant", entry: root.biggest, value: root.biggest ? Format.bytes(root.biggest.bytes) : "" }
					].filter(record => record.entry)

					delegate: Rectangle {
						id: record

						required property var modelData
						Layout.fillWidth: true
						implicitHeight: recordBody.implicitHeight + 24
						radius: Theme.radius.large
						color: Theme.layer1

						ColumnLayout {
							id: recordBody

							x: 12
							y: 12
							width: parent.width - 24
							spacing: 2

							RowLayout {
								spacing: 5

								Glyph {
									icon: record.modelData.icon
									size: 12
									color: Theme.warning
								}

								StyledText {
									text: record.modelData.label
									font.pixelSize: Theme.size.tiny
									tone: Theme.textMuted
								}

								ModeBadge {
									implicitHeight: 18
									mode: record.modelData.entry.mode === "boost" ? "boost" : (record.modelData.entry.mode === "torrent" ? "torrent" : "normal")
									text: record.modelData.entry.mode === "boost" ? `${record.modelData.entry.connections}` : ""
									visible: record.modelData.entry.mode === "boost"
								}
							}

							StyledText {
								text: record.modelData.value
								font.pixelSize: Theme.size.title
								font.weight: Font.Bold
								tabular: true
							}

							StyledText {
								Layout.fillWidth: true
								text: record.modelData.entry.name
								font.pixelSize: Theme.size.tiny
								tone: Theme.textSubtle
								elide: Text.ElideMiddle
							}
						}
					}
				}
			}
		}
	}
}
