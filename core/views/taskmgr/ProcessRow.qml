pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// One line of the list: a section, an app or service, or a process, indented
// by its depth. Each column glows warmer the more it takes; resting on it
// brings pause and end; a row being ended dims with a spinner and offers to
// force it when it does not go.
Clickable {
	id: root

	required property string key
	property bool picked: false
	readonly property var row: TaskManager.rows[root.key] ?? null
	readonly property bool section: root.row?.t === "section"
	readonly property int depth: root.row?.d ?? 0
	readonly property var flags: root.row?.f ?? []
	readonly property bool paused: root.flags.includes("paused")
	readonly property bool ending: TaskManager.ending[root.key] !== undefined
	readonly property bool lingering: TaskManager.lingering[root.key] !== undefined
	readonly property string icon: TaskManager.iconOf(root.row)
	readonly property bool agent: (root.row?.w ?? []).some(id => Agents.busy[id] !== undefined)
	readonly property var columns: TaskManager.settings.columns ?? {}
	readonly property real memTotal: TaskManager.memory.total || 1
	readonly property string chipSpec: {
		const out = [];
		if (root.agent) out.push({ icon: "robot_outline", tone: "primary", text: "" });
		if (root.lingering) out.push({ icon: "alert_outline", tone: "danger", text: "Not responding" });
		if (root.flags.includes("watched") || TaskManager.watched[root.key]) out.push({ icon: "bell_ring_outline", tone: "primary", text: "" });
		if (root.flags.includes("oldlibs")) out.push({ icon: "update", tone: "warning", text: "Old version" });
		if (root.flags.includes("zombie")) out.push({ icon: "ghost_outline", tone: "muted", text: "Zombie" });
		if (root.flags.includes("waiting")) out.push({ icon: "harddisk", tone: "muted", text: "" });
		if (root.row?.u) out.push({ icon: "account_outline", tone: "subtle", text: root.row.u });
		return JSON.stringify(out);
	}

	function toneColor(name) {
		return ({ primary: Theme.primary, danger: Theme.danger, warning: Theme.warning, muted: Theme.textMuted, subtle: Theme.textSubtle })[name] ?? Theme.text;
	}

	signal menuRequested(var mouse)
	signal toggled

	implicitHeight: root.section ? 40 : 44
	radius: Theme.radius.medium
	color: root.picked ? Theme.primaryContainer : (root.hovered ? Theme.layer2 : "transparent")
	pressedScale: 0.99
	acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
	sound: ""
	onRightClicked: mouse => root.menuRequested(mouse)

	Behavior on color {
		ColorAnim {}
	}

	// the accent's edge when picked
	Rectangle {
		anchors.left: parent.left
		anchors.verticalCenter: parent.verticalCenter
		anchors.leftMargin: 3
		width: 3
		height: root.picked ? parent.height - 20 : 0
		radius: 2
		color: Theme.primary

		Behavior on height {
			SpatialAnim {}
		}
	}

	RowLayout {
		anchors.fill: parent
		anchors.leftMargin: 10
		anchors.rightMargin: 8
		spacing: 0
		opacity: root.ending && !root.lingering ? 0.45 : 1

		Behavior on opacity {
			Anim {}
		}

		Item {
			Layout.preferredWidth: Math.max(0, root.depth - (root.section ? 0 : 1)) * 18
		}

		// open or closed
		Item {
			Layout.preferredWidth: 22
			Layout.fillHeight: true

			Glyph {
				anchors.centerIn: parent
				visible: (root.row?.x ?? 0) > 0
				icon: "chevron_right"
				size: 16
				color: Theme.textMuted
				rotation: root.row?.x === 2 ? 90 : 0

				Behavior on rotation {
					SpatialAnim {
						duration: Motion.medium
					}
				}
			}

			MouseArea {
				anchors.fill: parent
				enabled: (root.row?.x ?? 0) > 0
				cursorShape: Qt.PointingHandCursor
				onClicked: root.toggled()
			}
		}

		// what it is
		Item {
			Layout.preferredWidth: root.section ? 26 : 30
			Layout.preferredHeight: 26

			Image {
				anchors.centerIn: parent
				width: root.section ? 18 : 22
				height: width
				visible: !root.icon.startsWith("glyph:") && !root.ending
				source: root.icon.startsWith("glyph:") ? "" : root.icon
				sourceSize: Qt.size(44, 44)
				fillMode: Image.PreserveAspectFit
				asynchronous: true
				mipmap: true
				opacity: root.paused ? 0.45 : 1

				Behavior on opacity {
					Anim {}
				}
			}

			Glyph {
				anchors.centerIn: parent
				visible: root.icon.startsWith("glyph:") && !root.ending
				icon: root.icon.slice(6)
				size: root.section ? 16 : 18
				color: root.section ? Theme.textMuted : Theme.text
				opacity: root.paused ? 0.45 : 1
			}

			Spinner {
				anchors.centerIn: parent
				width: 18
				height: 18
				visible: root.ending
				color: root.lingering ? Theme.danger : Theme.primary
			}

			// paused: a small mark over the icon
			Rectangle {
				anchors.right: parent.right
				anchors.bottom: parent.bottom
				anchors.rightMargin: 1
				width: 13
				height: 13
				radius: 7
				color: Theme.warning
				visible: scale > 0.01
				scale: root.paused && !root.section ? 1 : 0

				Behavior on scale {
					SpatialAnim {
						duration: Motion.medium
					}
				}

				Glyph {
					anchors.centerIn: parent
					icon: "pause"
					size: 9
					color: Theme.bg
					animated: false
				}
			}
		}

		Item {
			Layout.preferredWidth: 8
		}

		// its name and what else is said of it
		ColumnLayout {
			Layout.fillWidth: true
			// it takes what the cells leave, never more
			Layout.preferredWidth: 100
			Layout.minimumWidth: 0
			Layout.alignment: Qt.AlignVCenter
			spacing: 0

			RowLayout {
				Layout.fillWidth: true
				spacing: 6

				// as wide as the name, narrower only when there is no room
				StyledText {
					Layout.preferredWidth: Math.ceil(implicitWidth) + 1
					Layout.minimumWidth: 0
					text: root.section ? TaskManager.nameOf(root.row).toUpperCase() : TaskManager.nameOf(root.row)
					elide: Text.ElideRight
					font.pixelSize: root.section ? Theme.size.label : Theme.size.body
					font.weight: root.section ? Font.DemiBold : (root.row?.t === "group" ? Font.Medium : Font.Normal)
					tone: root.section ? Theme.textMuted : Theme.text
				}

				StyledText {
					visible: root.section || (root.row?.t === "group" && (root.row?.cnt ?? 0) > 1)
					text: `${root.row?.cnt ?? ""}`
					tone: Theme.textSubtle
					font.pixelSize: Theme.size.small
					tabular: true
				}

				Row {
					id: chips

					visible: !root.section
					spacing: 4

					Repeater {
						// a string: the chips are made anew only when they change
						model: JSON.parse(root.chipSpec)

						delegate: Rectangle {
							id: chip

							required property var modelData
							readonly property color tone: root.toneColor(chip.modelData.tone)

							height: 18
							width: chipRow.implicitWidth + (chip.modelData.text !== "" ? 12 : 6)
							radius: 9
							color: Qt.alpha(chip.tone, 0.14)
							scale: 0.6
							opacity: 0
							Component.onCompleted: {
								chip.scale = 1;
								chip.opacity = 1;
							}

							Behavior on scale {
								SpatialAnim {
									duration: Motion.medium
								}
							}
							Behavior on opacity {
								Anim {}
							}

							Row {
								id: chipRow

								anchors.centerIn: parent
								spacing: 3

								Glyph {
									anchors.verticalCenter: parent.verticalCenter
									icon: chip.modelData.icon
									size: 11
									color: chip.tone
								}

								StyledText {
									anchors.verticalCenter: parent.verticalCenter
									visible: chip.modelData.text !== ""
									text: chip.modelData.text
									tone: chip.tone
									font.pixelSize: Theme.size.tiny
									font.weight: Font.Medium
								}
							}
						}
					}
				}

				Item {
					Layout.fillWidth: true
				}
			}

			StyledText {
				Layout.fillWidth: true
				visible: !root.section && text !== ""
				text: {
					const row = root.row;
					if (!row) return "";
					if (row.t === "group" && row.kind === "app") return row.s || "";
					if (row.t === "group") return (row.cnt ?? 1) > 1 ? (row.unit ?? "") : (row.s || "");
					return root.picked || root.hovered ? (row.s ?? "") : `${row.p ?? ""}`;
				}
				elide: Text.ElideRight
				tone: Theme.textSubtle
				font.pixelSize: Theme.size.small
			}
		}

		// what resting on it brings: pause, end; force when it does not go
		Row {
			Layout.leftMargin: 6
			spacing: 2
			visible: !root.section && (opacity > 0.01 || root.lingering)
			opacity: root.hovered || root.lingering ? 1 : 0

			Behavior on opacity {
				Anim {
					duration: Motion.short
				}
			}

			TextButton {
				visible: root.lingering
				height: 28
				text: "Force"
				icon: "close_octagon_outline"
				variant: "danger"
				onActivated: TaskManager.kill(root.key)
			}

			IconButton {
				visible: !root.lingering && !root.ending
				width: 30
				height: 30
				icon: root.paused ? "play" : "pause"
				onClicked: root.paused ? TaskManager.resume(root.key) : TaskManager.pause(root.key)
			}

			IconButton {
				visible: !root.lingering && !root.ending
				width: 30
				height: 30
				icon: "close"
				variant: "danger"
				onClicked: TaskManager.end(root.key)
			}
		}

		Cell {
			visible: root.columns.cpu !== false
			heat: Math.sqrt(Math.min(1, (root.row?.c ?? 0) * 1.6))
			text: TaskManager.percent(root.row?.c ?? 0)
		}

		Cell {
			visible: root.columns.mem !== false
			Layout.preferredWidth: 96
			heat: Math.min(1, (root.row?.m ?? 0) / root.memTotal * 4)
			text: Format.bytes(root.row?.m ?? 0)
		}

		Cell {
			visible: root.columns.io !== false
			Layout.preferredWidth: 92
			heat: Math.min(1, (root.row?.io ?? 0) / 52428800)
			text: (root.row?.io ?? 0) > 0 ? Format.rate(root.row.io) : "0 MB/s"
		}

		Cell {
			visible: root.columns.gpu !== false && TaskManager.hasGpu
			Layout.preferredWidth: 64
			heat: Math.sqrt(Math.min(1, root.row?.g ?? 0))
			text: TaskManager.percent(root.row?.g ?? 0, 0)
		}
	}

	component Cell: Rectangle {
		id: cell

		property real heat: 0
		property string text: ""

		Layout.preferredWidth: 80
		Layout.fillHeight: true
		Layout.topMargin: root.section ? 8 : 4
		Layout.bottomMargin: root.section ? 8 : 4
		radius: Theme.radius.small
		color: Qt.alpha(cell.heat > 0.7 ? Theme.danger : (cell.heat > 0.4 ? Theme.warning : Theme.primary), Math.min(0.32, cell.heat * 0.36))

		Behavior on color {
			ColorAnimation {
				duration: 350
				easing.type: Easing.OutCubic
			}
		}

		StyledText {
			anchors.right: parent.right
			anchors.rightMargin: 10
			anchors.verticalCenter: parent.verticalCenter
			text: cell.text
			tabular: true
			font.pixelSize: root.section ? Theme.size.small : Theme.size.body
			tone: root.section ? Theme.textMuted : (cell.heat > 0.02 ? Theme.text : Theme.textSubtle)
		}
	}
}
