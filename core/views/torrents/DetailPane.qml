pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// One torrent up close: how far it is and when it will be through, the rate
// over time, the figures, which parts are there, its files and peers.
Flickable {
	id: root

	required property string hash
	readonly property var item: Torrents.byHash[root.hash] ?? null
	readonly property var details: Torrents.details && Torrents.details.summary?.hash === root.hash ? Torrents.details : null
	readonly property string phase: root.item?.phase ?? ""
	readonly property bool complete: root.phase === "seeding" || root.phase === "done"
	readonly property bool halted: root.phase === "paused" || root.phase === "done" || root.phase === "error"
	// what was picked for this torrent; until then a running one shows the
	// last minutes, a complete one the whole download
	property string userMode: ""
	readonly property string graphMode: root.userMode !== "" ? root.userMode : (root.complete ? "whole" : "live")
	property bool more: false
	property bool showPeers: false

	contentWidth: width
	contentHeight: column.implicitHeight + 32
	clip: true
	boundsBehavior: Flickable.StopAtBounds
	ScrollBar.vertical: ThinScrollBar {}

	onHashChanged: {
		root.more = false;
		root.contentY = 0;
		root.userMode = "";
		appear.restart();
	}

	// a new torrent picked: the pane comes up again
	ParallelAnimation {
		id: appear

		NumberAnimation {
			target: column
			property: "opacity"
			from: 0
			to: 1
			duration: Motion.medium
		}
		NumberAnimation {
			target: column
			property: "y"
			from: 30
			to: 16
			duration: Motion.long
			easing.type: Easing.BezierSpline
			easing.bezierCurve: Motion.spatial
		}
	}

	ColumnLayout {
		id: column

		x: 20
		y: 16
		width: root.width - 40
		spacing: 14

		// ── the name and what can be done ───────────────────────────────
		ColumnLayout {
			Layout.fillWidth: true
			spacing: 6

			StyledText {
				Layout.fillWidth: true
				text: root.item?.name ?? ""
				font.pixelSize: Theme.size.heading + 2
				font.weight: Font.DemiBold
				wrapMode: Text.WrapAnywhere
				maximumLineCount: 2
				elide: Text.ElideRight
			}

			RowLayout {
				Layout.fillWidth: true
				spacing: 8

				Rectangle {
					id: chip

					readonly property color accent: root.phase === "error" ? Theme.danger : (root.complete ? Theme.success : Theme.primary)

					implicitWidth: chipText.implicitWidth + 18
					implicitHeight: 22
					radius: height / 2
					color: Qt.alpha(chip.accent, 0.16)

					Behavior on color {
						ColorAnim {}
					}

					StyledText {
						id: chipText

						anchors.centerIn: parent
						text: root.phase === "error" ? (root.item?.error || "Error") : Torrents.phaseLabel(root.phase)
						font.pixelSize: Theme.size.small
						font.weight: Font.Medium
						tone: chip.accent
					}
				}

				Clickable {
					Layout.fillWidth: true
					Layout.preferredHeight: 24
					radius: Theme.radius.small
					onClicked: Torrents.reveal(root.hash)

					RowLayout {
						anchors.fill: parent
						anchors.leftMargin: 6
						anchors.rightMargin: 6
						spacing: 6

						Glyph {
							icon: "folder_outline"
							size: 14
							color: Theme.textMuted
						}

						StyledText {
							Layout.fillWidth: true
							text: (root.item?.destination ?? "").replace(Paths.home, "~")
							font.pixelSize: Theme.size.small
							tone: Theme.textMuted
							elide: Text.ElideMiddle
						}
					}
				}
			}
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 8

			TextButton {
				variant: "filled"
				icon: root.halted ? "play" : "pause"
				text: root.halted ? (root.phase === "done" ? "Seed" : "Resume") : "Pause"
				onActivated: root.halted ? Torrents.resume(root.hash) : Torrents.pause(root.hash)
			}

			TextButton {
				icon: "folder_open_outline"
				text: "Show files"
				onActivated: Torrents.reveal(root.hash)
			}

			TextButton {
				icon: "folder_move_outline"
				text: "Move…"
				onActivated: Torrents.pickFolder(root.item?.destination ?? "", path => {
					if (path !== "") Torrents.move(root.hash, path);
				})
			}

			Item {
				Layout.fillWidth: true
			}

			IconButton {
				icon: "dots_vertical"
				checked: root.more
				onClicked: root.more = !root.more
			}
		}

		// what is done less often, folded out
		Flow {
			Layout.fillWidth: true
			spacing: 8
			visible: root.more
			opacity: root.more ? 1 : 0

			Behavior on opacity {
				Anim {}
			}

			TextButton {
				icon: "magnet"
				text: "Copy magnet link"
				variant: "ghost"
				enabled: (root.details?.magnet ?? "") !== ""
				onActivated: Torrents.copy(root.details.magnet)
			}

			TextButton {
				icon: "progress_check"
				text: "Check files"
				variant: "ghost"
				onActivated: Torrents.recheck(root.hash)
			}

			TextButton {
				icon: "refresh"
				text: "Find peers"
				variant: "ghost"
				onActivated: Torrents.reannounce(root.hash)
			}

			TextButton {
				icon: "format_list_numbered"
				text: root.item?.sequential ? "In order: on" : "In order: off"
				variant: root.item?.sequential ? "tonal" : "ghost"
				onActivated: Torrents.setSequential(root.hash, !(root.item?.sequential ?? false))
			}

			TextButton {
				icon: "delete_outline"
				text: "Remove"
				confirmText: "Keep the files?"
				confirm: true
				variant: "danger"
				onActivated: Torrents.remove(root.hash, false)
			}

			TextButton {
				icon: "delete_forever_outline"
				text: "Remove with files"
				confirmText: "Delete the files too?"
				confirm: true
				variant: "danger"
				onActivated: Torrents.remove(root.hash, true)
			}
		}

		// ── how far, and when it is through ─────────────────────────────
		Rectangle {
			Layout.fillWidth: true
			implicitHeight: 112
			radius: Theme.radius.huge
			color: Theme.layer1

			RowLayout {
				anchors.fill: parent
				anchors.margins: 18
				spacing: 18

				ColumnLayout {
					spacing: 0

					StyledText {
						text: `${Math.floor((root.item?.progress ?? 0) * 1000) / 10}`.replace(/\.0$/, "") + " %"
						font.pixelSize: Theme.size.display + 6
						font.weight: Font.DemiBold
						tabular: true
						tone: root.complete ? Theme.success : Theme.text
					}

					StyledText {
						text: (root.item?.size ?? -1) > 0 ? `${Torrents.size(root.item.done)} of ${Torrents.size(root.item.size)}` : "Size not known yet"
						font.pixelSize: Theme.size.small
						tone: Theme.textMuted
						tabular: true
					}
				}

				Rectangle {
					Layout.fillHeight: true
					Layout.preferredWidth: 1
					color: Theme.outline
				}

				ColumnLayout {
					Layout.fillWidth: true
					spacing: 2

					RowLayout {
						spacing: 8

						Glyph {
							icon: root.complete ? "flag_checkered" : "clock_outline"
							size: 18
							color: root.complete ? Theme.success : Theme.primary
						}

						StyledText {
							text: {
								const item = root.item;
								if (!item) return "";
								if (root.complete || item.finished > 0) return item.finished > 0 ? `Finished ${Torrents.when(item.finished)}` : "Complete";
								if (item.phase === "downloading" && item.eta >= 0) return `Done at ${Torrents.finishTime(item.eta)}`;
								if (item.phase === "metadata") return "Getting the file list…";
								if (item.phase === "stalled") return "Waiting for peers";
								if (item.phase === "checking") return "Checking what is there";
								return Torrents.phaseLabel(item.phase);
							}
							font.pixelSize: Theme.size.title + 1
							font.weight: Font.Medium
						}
					}

					StyledText {
						Layout.fillWidth: true
						text: {
							const item = root.item;
							if (!item) return "";
							if (item.finished > 0) return `took ${Torrents.duration(item.finished - item.added)} · added ${Torrents.when(item.added)}`;
							if (item.phase === "downloading" && item.eta >= 0) return `${Torrents.duration(item.eta)} left at ${Torrents.rate(item.down)}`;
							return `added ${Torrents.when(item.added)}`;
						}
						font.pixelSize: Theme.size.small
						tone: Theme.textMuted
						tabular: true
						elide: Text.ElideRight
					}

					PieceStrip {
						Layout.fillWidth: true
						Layout.topMargin: 8
						pieces: root.details?.pieces ?? []
						accent: root.complete ? Theme.success : Theme.primary
					}
				}
			}
		}

		// ── the rate over time ──────────────────────────────────────────
		Rectangle {
			Layout.fillWidth: true
			implicitHeight: 250
			radius: Theme.radius.huge
			color: Theme.layer1

			RowLayout {
				id: graphHead

				anchors.top: parent.top
				anchors.left: parent.left
				anchors.right: parent.right
				anchors.margins: 14
				spacing: 14

				Segmented {
					options: [{ value: "live", label: "Live" }, { value: "whole", label: "Whole download" }]
					current: root.graphMode
					onSelected: value => root.userMode = value
				}

				Item {
					Layout.fillWidth: true
				}

				Repeater {
					model: [
						{ label: "Download", color: Theme.primary, dashed: false },
						{ label: "Upload", color: Torrents.upColor, dashed: false },
						{ label: "Progress", color: Qt.alpha(Theme.text, 0.45), dashed: true, whole: true }
					]

					RowLayout {
						id: legend

						required property var modelData

						visible: !legend.modelData.whole || root.graphMode === "whole"
						spacing: 5

						Rectangle {
							width: 12
							height: legend.modelData.dashed ? 2 : 4
							radius: 2
							color: legend.modelData.color
						}

						StyledText {
							text: legend.modelData.label
							font.pixelSize: Theme.size.small
							tone: Theme.textMuted
						}
					}
				}
			}

			RateGraph {
				anchors.top: graphHead.bottom
				anchors.left: parent.left
				anchors.right: parent.right
				anchors.bottom: parent.bottom
				anchors.margins: 14
				anchors.topMargin: 30
				mode: root.graphMode
				samples: root.graphMode === "live" ? (root.details?.live ?? []) : (root.details?.history ?? [])
			}
		}

		// ── the figures ─────────────────────────────────────────────────
		GridLayout {
			Layout.fillWidth: true
			columns: root.width > 760 ? 4 : 2
			columnSpacing: 10
			rowSpacing: 10

			StatTile {
				Layout.fillWidth: true
				icon: "arrow_down_bold"
				label: "Download"
				value: Torrents.rate(root.item?.down ?? 0)
				note: `${Torrents.size(root.item?.downloaded ?? 0)} received`
			}

			StatTile {
				Layout.fillWidth: true
				icon: "arrow_up_bold"
				accent: Torrents.upColor
				label: "Upload"
				value: Torrents.rate(root.item?.up ?? 0)
				note: `${Torrents.size(root.item?.uploaded ?? 0)} sent`
			}

			StatTile {
				Layout.fillWidth: true
				icon: "account_multiple"
				accent: Theme.secondary
				label: "Peers"
				value: `${root.item?.seeds ?? 0} / ${Math.max(0, (root.item?.peers ?? 0) - (root.item?.seeds ?? 0))}`
				note: `seeds / peers · swarm ${root.item?.swarmSeeds ?? 0} / ${root.item?.swarmPeers ?? 0}`
			}

			StatTile {
				Layout.fillWidth: true
				icon: "swap_vertical"
				accent: Theme.success
				label: "Ratio"
				value: (root.item?.ratio ?? 0).toFixed(2)
				note: Torrents.settings.ratio < 0 ? "seeds on without a limit" : (Torrents.settings.ratio === 0 ? "stops when complete" : `stops seeding at ${Number(Torrents.settings.ratio).toFixed(1)}`)
			}
		}

		// ── the files ───────────────────────────────────────────────────
		SectionLabel {
			text: (root.details?.files ?? []).length === 1 ? "File" : `${(root.details?.files ?? []).length} files`
			visible: (root.details?.files ?? []).length > 0
		}

		Rectangle {
			Layout.fillWidth: true
			visible: (root.details?.files ?? []).length > 0
			implicitHeight: files.implicitHeight + 8
			radius: Theme.radius.large
			color: Theme.layer1

			ColumnLayout {
				id: files

				anchors.left: parent.left
				anchors.right: parent.right
				anchors.top: parent.top
				anchors.margins: 4
				spacing: 0

				Repeater {
					model: (root.details?.files ?? []).slice(0, 300)

					FileLine {
						required property var modelData

						Layout.fillWidth: true
						file: modelData
						hash: root.hash
					}
				}

				StyledText {
					Layout.margins: 10
					visible: (root.details?.files ?? []).length > 300
					text: `and ${(root.details?.files ?? []).length - 300} more`
					font.pixelSize: Theme.size.small
					tone: Theme.textSubtle
				}
			}
		}

		// ── the peers ───────────────────────────────────────────────────
		Clickable {
			Layout.fillWidth: true
			Layout.preferredHeight: 30
			radius: Theme.radius.small
			visible: (root.details?.peerCount ?? 0) > 0
			onClicked: root.showPeers = !root.showPeers

			RowLayout {
				anchors.fill: parent
				anchors.leftMargin: 4
				spacing: 6

				SectionLabel {
					text: `${root.details?.peerCount ?? 0} connected`
				}

				Glyph {
					icon: root.showPeers ? "chevron_up" : "chevron_down"
					size: 16
					color: Theme.textMuted
				}

				Item {
					Layout.fillWidth: true
				}
			}
		}

		Rectangle {
			Layout.fillWidth: true
			visible: root.showPeers && (root.details?.peerCount ?? 0) > 0
			implicitHeight: peers.implicitHeight + 16
			radius: Theme.radius.large
			color: Theme.layer1

			ColumnLayout {
				id: peers

				anchors.left: parent.left
				anchors.right: parent.right
				anchors.top: parent.top
				anchors.margins: 8
				spacing: 2

				Repeater {
					model: root.showPeers ? (root.details?.peers ?? []) : []

					RowLayout {
						id: peer

						required property var modelData

						Layout.fillWidth: true
						Layout.leftMargin: 8
						Layout.rightMargin: 8
						spacing: 10

						StyledText {
							Layout.preferredWidth: 190
							text: peer.modelData.address
							font.family: Theme.monoFamily
							font.pixelSize: Theme.size.small
							elide: Text.ElideRight
						}

						StyledText {
							Layout.fillWidth: true
							text: peer.modelData.client || "–"
							font.pixelSize: Theme.size.small
							tone: Theme.textMuted
							elide: Text.ElideRight
						}

						StyledText {
							Layout.preferredWidth: 46
							horizontalAlignment: Text.AlignRight
							text: peer.modelData.seed ? "seed" : `${Math.round(peer.modelData.progress * 100)} %`
							font.pixelSize: Theme.size.small
							tone: Theme.textSubtle
							tabular: true
						}

						StyledText {
							Layout.preferredWidth: 90
							horizontalAlignment: Text.AlignRight
							text: peer.modelData.down > 0 ? `↓ ${Torrents.rate(peer.modelData.down)}` : ""
							font.pixelSize: Theme.size.small
							tabular: true
						}

						StyledText {
							Layout.preferredWidth: 90
							horizontalAlignment: Text.AlignRight
							text: peer.modelData.up > 0 ? `↑ ${Torrents.rate(peer.modelData.up)}` : ""
							font.pixelSize: Theme.size.small
							tone: Theme.textMuted
							tabular: true
						}
					}
				}
			}
		}
	}
}
