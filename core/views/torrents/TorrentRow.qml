import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// One torrent in the list: its name, what it does, a bar that fills, the rate
// and when it will be through. Picked, it is lifted with the accent.
Clickable {
	id: root

	required property string hash
	property bool picked: false
	readonly property var item: Torrents.byHash[root.hash] ?? null
	readonly property string phase: root.item?.phase ?? ""
	readonly property bool complete: root.phase === "seeding" || root.phase === "done"
	readonly property color accent: root.phase === "error" ? Theme.danger : (root.complete ? Theme.success : (root.phase === "paused" || root.phase === "queued" ? Theme.textSubtle : Theme.primary))

	signal menuRequested(var mouse)

	implicitHeight: 74
	radius: Theme.radius.large
	color: root.picked ? Theme.primaryContainer : (root.hovered ? Theme.layer2 : Theme.layer1)
	acceptedButtons: Qt.LeftButton | Qt.RightButton
	onRightClicked: mouse => root.menuRequested(mouse)

	// the accent's edge when picked
	Rectangle {
		anchors.left: parent.left
		anchors.verticalCenter: parent.verticalCenter
		anchors.leftMargin: 4
		width: 3
		height: root.picked ? parent.height - 28 : 0
		radius: 2
		color: Theme.primary

		Behavior on height {
			SpatialAnim {}
		}
	}

	RowLayout {
		anchors.fill: parent
		anchors.leftMargin: 16
		anchors.rightMargin: 14
		spacing: 12

		// what it does, as a ring around its icon
		Item {
			Layout.preferredWidth: 36
			Layout.preferredHeight: 36

			Ring {
				anchors.fill: parent
				value: root.item?.progress ?? 0
				color: root.accent
				thickness: 3
			}

			Glyph {
				anchors.centerIn: parent
				size: 16
				color: root.accent
				icon: ({
					metadata: "magnet", checking: "progress_check", queued: "timer_sand", downloading: "arrow_down_bold",
					stalled: "progress_download", seeding: "arrow_up_bold", done: "check_bold", paused: "pause", error: "alert_circle_outline", moving: "folder_move_outline"
				})[root.phase] ?? "download"
			}
		}

		ColumnLayout {
			Layout.fillWidth: true
			spacing: 4

			StyledText {
				Layout.fillWidth: true
				text: root.item?.name ?? ""
				elide: Text.ElideMiddle
				font.pixelSize: Theme.size.body
				font.weight: Font.Medium
			}

			// the bar
			Rectangle {
				Layout.fillWidth: true
				Layout.preferredHeight: 4
				radius: 2
				color: Theme.layer3

				Rectangle {
					width: parent.width * Math.max(0, Math.min(1, root.item?.progress ?? 0))
					height: parent.height
					radius: 2
					color: root.accent

					Behavior on width {
						Anim {
							duration: 900
						}
					}
				}
			}

			RowLayout {
				Layout.fillWidth: true
				spacing: 8

				StyledText {
					text: {
						const item = root.item;
						if (!item) return "";
						if (item.phase === "downloading") return `↓ ${Format.rate(item.down)}`;
						if (item.phase === "seeding") return `↑ ${Format.rate(item.up)} · ratio ${item.ratio.toFixed(2)}`;
						if (item.phase === "error") return item.error;
						return Torrents.phaseLabel(item.phase);
					}
					font.pixelSize: Theme.size.small
					tone: root.phase === "error" ? Theme.danger : Theme.textMuted
					tabular: true
					elide: Text.ElideRight
					Layout.maximumWidth: 200
				}

				Item {
					Layout.fillWidth: true
				}

				StyledText {
					text: {
						const item = root.item;
						if (!item) return "";
						if (root.complete) return item.size > 0 ? Format.bytes(item.size) : "";
						if (item.phase === "downloading" && item.eta >= 0) return `done ${Torrents.finishTime(item.eta)}`;
						return item.size > 0 ? `${Math.floor(item.progress * 100)} % of ${Format.bytes(item.size)}` : "";
					}
					font.pixelSize: Theme.size.small
					tone: Theme.textSubtle
					tabular: true
				}
			}
		}
	}
}
