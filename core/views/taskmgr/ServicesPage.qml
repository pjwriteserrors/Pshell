pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.style.theme
import qs.style.widgets
import qs.core.services

// systemd's services, the user's or the system's: what runs breathes, what
// failed is red. The one picked shows what it takes, can be started,
// stopped, restarted, enabled or disabled, and its journal runs along live.
Item {
	id: root

	property string scope: "user"
	property var services: []
	property bool loading: false
	property string picked: ""
	property string show: "running"
	property var entries: []
	property string cursor: ""
	readonly property string needle: TaskManager.filter.toLowerCase()
	readonly property var shownList: root.services.filter(item => {
		if (root.show === "running" && item.active !== "active" && item.active !== "activating" && item.active !== "failed") return false;
		if (root.show === "failed" && item.active !== "failed") return false;
		return root.needle === "" || item.unit.toLowerCase().includes(root.needle) || item.description.toLowerCase().includes(root.needle);
	}).sort((a, b) => (b.active === "failed") - (a.active === "failed") || (b.c ?? 0) - (a.c ?? 0) || a.unit.localeCompare(b.unit))
	readonly property var current: root.services.find(item => item.unit === root.picked) ?? null

	function reload() {
		root.loading = true;
		TaskManager.services(root.scope, list => {
			root.services = list;
			root.loading = false;
		});
	}

	function readJournal(fresh) {
		if (root.picked === "") return;
		const unit = root.picked;
		TaskManager.journal(root.scope, unit, fresh ? "" : root.cursor, data => {
			if (unit !== root.picked) return;
			root.entries = fresh ? data.entries : root.entries.concat(data.entries).slice(-400);
			root.cursor = data.cursor || root.cursor;
			if (data.entries.length > 0) Qt.callLater(() => journalView.positionViewAtEnd());
		});
	}

	onScopeChanged: {
		root.picked = "";
		root.reload();
	}
	onPickedChanged: {
		root.entries = [];
		root.cursor = "";
		root.readJournal(true);
	}
	Component.onCompleted: root.reload()

	onShownListChanged: rows.sync(root.shownList.map(item => item.unit))

	KeyedModel {
		id: rows
	}

	Timer {
		running: root.visible
		interval: 3000
		repeat: true
		onTriggered: root.reload()
	}

	Timer {
		running: root.visible && root.picked !== ""
		interval: 1500
		repeat: true
		onTriggered: root.readJournal(false)
	}

	function act(action) {
		const unit = root.picked;
		TaskManager.serviceAction(root.scope, unit, action, () => {
			root.reload();
			root.readJournal(false);
		});
	}

	RowLayout {
		anchors.fill: parent
		spacing: 0

		ColumnLayout {
			Layout.fillWidth: true
			Layout.fillHeight: true
			Layout.margins: 12
			spacing: 10

			RowLayout {
				Layout.fillWidth: true
				spacing: 8

				Segmented {
					Layout.preferredWidth: 220
					options: [{ value: "user", label: "Mine" }, { value: "system", label: "System" }]
					current: root.scope
					onSelected: value => root.scope = value
				}

				Segmented {
					Layout.preferredWidth: 300
					options: [
						{ value: "running", label: "Running" },
						{ value: "failed", label: `Failed ${root.services.filter(s => s.active === "failed").length}` },
						{ value: "all", label: "All" }
					]
					current: root.show
					onSelected: value => root.show = value
				}

				Item {
					Layout.fillWidth: true
				}

				Spinner {
					Layout.preferredWidth: 18
					Layout.preferredHeight: 18
					visible: root.loading && root.services.length === 0
				}
			}

			ListView {
				id: list

				Layout.fillWidth: true
				Layout.fillHeight: true
				clip: true
				model: rows
				spacing: 2
				boundsBehavior: Flickable.StopAtBounds
				ScrollBar.vertical: ThinScrollBar {}

				add: Transition {
					NumberAnimation {
						property: "opacity"
						from: 0
						to: 1
						duration: Motion.medium
					}
				}
				remove: Transition {
					NumberAnimation {
						property: "opacity"
						to: 0
						duration: Motion.short
					}
				}
				displaced: Transition {
					NumberAnimation {
						property: "y"
						duration: Motion.long
						easing.type: Easing.BezierSpline
						easing.bezierCurve: Motion.spatial
					}
				}

				delegate: Clickable {
					id: service

					required property string key
					readonly property var item: root.services.find(entry => entry.unit === service.key) ?? null
					readonly property bool running: service.item?.active === "active"
					readonly property bool failed: service.item?.active === "failed"
					readonly property bool chosen: root.picked === service.key

					width: list.width - 8
					height: 46
					radius: Theme.radius.medium
					color: service.chosen ? Theme.primaryContainer : (service.hovered ? Theme.layer2 : "transparent")
					onClicked: root.picked = service.chosen ? "" : service.key

					Behavior on color {
						ColorAnim {}
					}

					RowLayout {
						anchors.fill: parent
						anchors.leftMargin: 14
						anchors.rightMargin: 12
						spacing: 12

						// what it does: running breathes, failed is red
						Rectangle {
							id: dot

							Layout.preferredWidth: 10
							Layout.preferredHeight: 10
							radius: 5
							color: service.failed ? Theme.danger : (service.running ? Theme.success : Theme.textFaint)

							SequentialAnimation on opacity {
								running: service.running && service.visible
								loops: Animation.Infinite
								NumberAnimation {
									to: 0.45
									duration: 1400
									easing.type: Easing.InOutSine
								}
								NumberAnimation {
									to: 1
									duration: 1400
									easing.type: Easing.InOutSine
								}
							}
						}

						ColumnLayout {
							Layout.fillWidth: true
							spacing: 0

							StyledText {
								Layout.fillWidth: true
								text: service.key.replace(/\.service$/, "").replace(/\\x2d/g, "-")
								elide: Text.ElideRight
								font.weight: Font.Medium
							}

							StyledText {
								Layout.fillWidth: true
								text: service.item?.description ?? ""
								visible: text !== ""
								elide: Text.ElideRight
								tone: Theme.textSubtle
								font.pixelSize: Theme.size.small
							}
						}

						StyledText {
							visible: (service.item?.m ?? 0) > 0
							text: Format.bytes(service.item?.m ?? 0)
							tone: Theme.textMuted
							font.pixelSize: Theme.size.small
							tabular: true
						}

						StyledText {
							Layout.preferredWidth: 54
							horizontalAlignment: Text.AlignRight
							visible: service.running
							text: TaskManager.percent(service.item?.c ?? 0)
							tone: Theme.textMuted
							font.pixelSize: Theme.size.small
							tabular: true
						}

						Rectangle {
							Layout.preferredHeight: 20
							Layout.preferredWidth: stateText.implicitWidth + 14
							radius: 10
							color: Qt.alpha(service.failed ? Theme.danger : (service.running ? Theme.success : Theme.text), 0.1)

							StyledText {
								id: stateText

								anchors.centerIn: parent
								text: service.item?.sub ?? ""
								tone: service.failed ? Theme.danger : (service.running ? Theme.success : Theme.textSubtle)
								font.pixelSize: Theme.size.tiny
								font.weight: Font.Medium
							}
						}
					}
				}

				EmptyState {
					anchors.centerIn: parent
					visible: list.count === 0 && !root.loading
					icon: root.show === "failed" ? "check_circle_outline" : "cog_off_outline"
					title: root.show === "failed" ? "Nothing failed" : "No services"
				}
			}
		}

		// ── the one picked ─────────────────────────────────────────────────
		Item {
			Layout.fillHeight: true
			Layout.preferredWidth: root.current ? Math.min(480, root.width * 0.46) : 0
			clip: true

			Behavior on Layout.preferredWidth {
				SpatialAnim {
					duration: Motion.long
				}
			}

			Rectangle {
				anchors.left: parent.left
				anchors.top: parent.top
				anchors.bottom: parent.bottom
				width: 1
				color: Theme.outline
			}

			ColumnLayout {
				x: 18
				y: 18
				width: Math.min(480, root.width * 0.46) - 36
				height: parent.height - 36
				spacing: 12
				opacity: root.current ? 1 : 0

				Behavior on opacity {
					Anim {}
				}

				RowLayout {
					Layout.fillWidth: true

					ColumnLayout {
						Layout.fillWidth: true
						spacing: 2

						StyledText {
							Layout.fillWidth: true
							text: root.picked
							font.pixelSize: Theme.size.title
							font.weight: Font.DemiBold
							elide: Text.ElideMiddle
						}

						StyledText {
							Layout.fillWidth: true
							text: [root.current?.active, root.current?.sub, root.current?.enabled].filter(Boolean).join(" · ")
							tone: Theme.textMuted
							font.pixelSize: Theme.size.small
						}
					}

					IconButton {
						icon: "close"
						onClicked: root.picked = ""
					}
				}

				Flow {
					Layout.fillWidth: true
					spacing: 6

					TextButton {
						visible: root.current?.active !== "active"
						text: "Start"
						icon: "play"
						variant: "filled"
						onActivated: root.act("start")
					}

					TextButton {
						visible: root.current?.active === "active"
						text: "Restart"
						icon: "restart"
						onActivated: root.act("restart")
					}

					TextButton {
						visible: root.current?.active === "active"
						text: "Stop"
						icon: "stop"
						variant: "danger"
						onActivated: root.act("stop")
					}

					TextButton {
						visible: ["enabled", "disabled"].includes(root.current?.enabled ?? "")
						text: root.current?.enabled === "enabled" ? "Don't start at login" : "Start at login"
						icon: root.current?.enabled === "enabled" ? "rocket_launch_outline" : "rocket_launch"
						onActivated: root.act(root.current?.enabled === "enabled" ? "disable" : "enable")
					}

					TextButton {
						visible: !!root.current?.key
						text: "Processes"
						icon: "format_list_bulleted"
						onActivated: TaskManager.showKey(root.current.key)
					}
				}

				Rectangle {
					Layout.fillWidth: true
					Layout.fillHeight: true
					radius: Theme.radius.large
					color: Theme.layer1
					clip: true

					ListView {
						id: journalView

						anchors.fill: parent
						anchors.margins: 10
						clip: true
						model: root.entries
						spacing: 3
						boundsBehavior: Flickable.StopAtBounds
						ScrollBar.vertical: ThinScrollBar {}

						add: Transition {
							NumberAnimation {
								property: "opacity"
								from: 0
								to: 1
								duration: Motion.medium
							}
						}

						delegate: RowLayout {
							required property var modelData

							width: journalView.width - 8
							spacing: 8

							StyledText {
								Layout.alignment: Qt.AlignTop
								text: Qt.formatTime(new Date(modelData.t), "HH:mm:ss")
								tone: Theme.textFaint
								font.family: Theme.monoFamily
								font.pixelSize: Theme.size.tiny
							}

							StyledText {
								Layout.fillWidth: true
								text: modelData.m
								wrapMode: Text.WrapAnywhere
								font.family: Theme.monoFamily
								font.pixelSize: Theme.size.tiny
								tone: modelData.p <= 3 ? Theme.danger : (modelData.p === 4 ? Theme.warning : Theme.textMuted)
							}
						}

						EmptyState {
							anchors.centerIn: parent
							visible: journalView.count === 0
							icon: "text_box_outline"
							title: "Nothing in the journal"
						}
					}
				}
			}
		}
	}
}
