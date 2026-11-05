pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.style.theme
import qs.style.widgets
import qs.core.services

// What listens: each port with whoever holds it, whether only this machine
// can reach it or every network. A web server opens in the browser; whoever
// holds a port can be ended.
Item {
	id: root

	property var ports: []
	property bool loaded: false
	property string show: "tcp"
	readonly property string needle: TaskManager.filter.toLowerCase()
	readonly property var shownList: root.ports.filter(item => (root.show === "all" || item.proto === root.show)
		&& (root.needle === "" || String(item.port).includes(root.needle) || item.name.toLowerCase().includes(root.needle) || (item.group?.name ?? "").toLowerCase().includes(root.needle)))

	function reload(fresh) {
		TaskManager.ports(list => {
			root.ports = list;
			root.loaded = true;
		}, fresh);
	}

	Component.onCompleted: root.reload(true)
	onShownListChanged: rows.sync(root.shownList.map(item => `${item.proto}:${item.port}:${item.pids.join(",")}`))

	KeyedModel {
		id: rows
	}

	Timer {
		running: root.visible
		interval: 2500
		repeat: true
		onTriggered: root.reload(false)
	}

	ColumnLayout {
		anchors.fill: parent
		anchors.margins: 12
		spacing: 10

		Segmented {
			Layout.preferredWidth: 300
			options: [{ value: "tcp", label: "TCP" }, { value: "udp", label: "UDP" }, { value: "all", label: "All" }]
			current: root.show
			onSelected: value => root.show = value
		}

		GridView {
			id: grid

			Layout.fillWidth: true
			Layout.fillHeight: true
			clip: true
			model: rows
			cellWidth: Math.floor(width / Math.max(1, Math.floor(width / 280)))
			cellHeight: 92
			boundsBehavior: Flickable.StopAtBounds
			ScrollBar.vertical: ThinScrollBar {}

			add: Transition {
				ParallelAnimation {
					NumberAnimation {
						property: "opacity"
						from: 0
						to: 1
						duration: Motion.medium
					}
					NumberAnimation {
						property: "scale"
						from: 0.9
						to: 1
						duration: Motion.long
						easing.type: Easing.BezierSpline
						easing.bezierCurve: Motion.spatial
					}
				}
			}
			remove: Transition {
				ParallelAnimation {
					NumberAnimation {
						property: "opacity"
						to: 0
						duration: Motion.short
					}
					NumberAnimation {
						property: "scale"
						to: 0.9
						duration: Motion.short
					}
				}
			}
			displaced: Transition {
				NumberAnimation {
					properties: "x,y"
					duration: Motion.long
					easing.type: Easing.BezierSpline
					easing.bezierCurve: Motion.spatial
				}
			}

			delegate: Item {
				id: cell

				required property string key
				readonly property var item: root.ports.find(entry => `${entry.proto}:${entry.port}:${entry.pids.join(",")}` === cell.key) ?? null
				readonly property var row: cell.item?.group ? { t: "group", kind: cell.item.group.kind, i: cell.item.group.icon, n: cell.item.group.name } : null
				readonly property string icon: cell.row ? TaskManager.iconOf(cell.row) : "glyph:lan"

				width: grid.cellWidth
				height: grid.cellHeight

				Clickable {
					id: card

					anchors.fill: parent
					anchors.margins: 4
					radius: Theme.radius.large
					color: card.hovered ? Theme.layer2 : Theme.layer1
					onClicked: if (cell.item?.group) TaskManager.showKey(cell.item.group.key)

					Behavior on color {
						ColorAnim {}
					}

					RowLayout {
						anchors.fill: parent
						anchors.leftMargin: 16
						anchors.rightMargin: 10
						spacing: 12

						ColumnLayout {
							Layout.fillWidth: true
							spacing: 2

							RowLayout {
								spacing: 8

								StyledText {
									text: `:${cell.item?.port ?? ""}`
									font.pixelSize: Theme.size.heading + 2
									font.weight: Font.Bold
									tabular: true
								}

								Rectangle {
									Layout.preferredHeight: 18
									Layout.preferredWidth: scopeText.implicitWidth + 12
									radius: 9
									color: Qt.alpha(cell.item?.scope === "local" ? Theme.success : Theme.warning, 0.14)

									StyledText {
										id: scopeText

										anchors.centerIn: parent
										text: cell.item?.scope === "local" ? "This machine" : "Network"
										tone: cell.item?.scope === "local" ? Theme.success : Theme.warning
										font.pixelSize: Theme.size.tiny
										font.weight: Font.Medium
									}
								}
							}

							RowLayout {
								spacing: 6

								Item {
									Layout.preferredWidth: 16
									Layout.preferredHeight: 16

									Image {
										anchors.fill: parent
										visible: !cell.icon.startsWith("glyph:")
										source: cell.icon.startsWith("glyph:") ? "" : cell.icon
										sourceSize: Qt.size(32, 32)
										asynchronous: true
									}

									Glyph {
										anchors.centerIn: parent
										visible: cell.icon.startsWith("glyph:")
										icon: cell.icon.slice(6)
										size: 14
										color: Theme.textMuted
									}
								}

								StyledText {
									Layout.maximumWidth: card.width - 140
									text: cell.row ? TaskManager.nameOf(cell.row) : (cell.item?.name || "System")
									tone: Theme.textMuted
									elide: Text.ElideRight
								}
							}

							StyledText {
								text: `${cell.item?.proto ?? ""} · ${(cell.item?.addresses ?? []).join(", ")}`
								tone: Theme.textSubtle
								font.pixelSize: Theme.size.tiny
							}
						}

						IconButton {
							visible: cell.item?.proto === "tcp"
							icon: "open_in_new"
							opacity: card.hovered ? 1 : 0.5
							onClicked: Qt.openUrlExternally(`http://localhost:${cell.item.port}`)
						}

						IconButton {
							visible: (cell.item?.pids ?? []).length > 0
							icon: "close"
							variant: "danger"
							opacity: card.hovered ? 1 : 0
							onClicked: cell.item.pids.forEach(pid => TaskManager.end(`p:${pid}`))

							Behavior on opacity {
								Anim {}
							}
						}
					}
				}
			}

			EmptyState {
				anchors.centerIn: parent
				visible: grid.count === 0 && root.loaded
				icon: "lan_disconnect"
				title: root.needle !== "" ? `Nothing on “${TaskManager.filter}”` : "Nothing listens"
			}
		}
	}
}
