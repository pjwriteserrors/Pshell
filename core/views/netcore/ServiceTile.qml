pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// A service of netcore on the Server page: its state, how it answers, its
// memory against the container's limit (or the Pi's memory when it has
// none), and what can be done with it. Restart, stop, start and pause ask
// first (Ask); a critical one (Pi-hole, WireGuard) says what hangs on it.
Rectangle {
	id: root

	required property var service
	property int index: 0

	readonly property string name: String(root.service?.name ?? "")
	readonly property string title: String(root.service?.title ?? root.name)
	readonly property string status: String(root.service?.state ?? "unknown")
	// docker knows the container (core sends null when it does not): only then it can be started or stopped
	readonly property bool known: !!root.service?.container && typeof root.service.container === "object"
	readonly property var container: root.service?.container ?? ({})
	readonly property string containerName: String(root.service?.container_name ?? root.service?.config?.container ?? root.container.name ?? "")
	readonly property real mem: Number(root.container.mem) || 0
	readonly property real limit: Number(root.container.mem_limit) || 0
	readonly property real against: root.limit > 0 ? root.limit : Netcore.memTotal
	readonly property real memFill: root.against > 0 ? Math.min(1, root.mem / root.against) : 0
	readonly property bool running: ["running", "restarting"].includes(String(root.container.state ?? "")) || root.status === "up" || root.status === "degraded"
	readonly property bool paused: String(root.container.state ?? "") === "paused"
	readonly property bool critical: !!root.service?.critical
	readonly property color tone: Netcore.stateColor(root.status)
	// restart | stop | start | pause | unpause while it asks
	property string asking: ""
	property bool busy: false
	property real enter: 0

	Layout.fillWidth: true
	implicitHeight: column.implicitHeight + 28
	radius: Theme.radius.large
	color: hover.hovered ? Theme.layer2 : Theme.layer1
	border.width: 1
	border.color: Qt.alpha(root.tone, root.status === "down" ? 0.55 : 0.18)
	opacity: root.enter
	transform: Translate {
		y: (1 - root.enter) * 14
	}

	Behavior on color {
		ColorAnim {}
	}
	Behavior on border.color {
		ColorAnim {
			duration: Motion.long
		}
	}

	SequentialAnimation {
		running: true

		PauseAnimation {
			duration: Math.min(root.index, 10) * 40
		}
		NumberAnimation {
			target: root
			property: "enter"
			to: 1
			duration: Motion.long
			easing.type: Easing.BezierSpline
			easing.bezierCurve: Motion.decel
		}
	}

	HoverHandler {
		id: hover
	}

	function verb(action) {
		return ({ restart: "Restart", stop: "Stop", start: "Start", pause: "Pause", unpause: "Go on with" })[action] ?? action;
	}

	ColumnLayout {
		id: column

		x: 14
		y: 14
		width: parent.width - 28
		spacing: 10

		RowLayout {
			Layout.fillWidth: true
			spacing: 12

			Rectangle {
				Layout.preferredWidth: 38
				Layout.preferredHeight: 38
				Layout.alignment: Qt.AlignTop
				radius: Theme.radius.medium
				color: Qt.alpha(root.tone, 0.14)

				Behavior on color {
					ColorAnim {
						duration: Motion.long
					}
				}

				Glyph {
					anchors.centerIn: parent
					icon: Netcore.iconOf(root.service)
					size: 19
					color: root.status === "stopped" || root.status === "unknown" ? Theme.textMuted : root.tone
				}

				// the state, a dot on the corner that breathes while it is down
				Rectangle {
					id: dot

					anchors.right: parent.right
					anchors.bottom: parent.bottom
					anchors.margins: -3
					width: 12
					height: 12
					radius: 6
					color: root.tone
					border.width: 2
					border.color: root.color

					Behavior on color {
						ColorAnim {
							duration: Motion.long
						}
					}

					SequentialAnimation on scale {
						running: root.status === "down" || root.status === "degraded"
						loops: Animation.Infinite
						alwaysRunToEnd: true

						NumberAnimation {
							to: 1.35
							duration: 900
							easing.type: Easing.InOutSine
						}
						NumberAnimation {
							to: 1
							duration: 900
							easing.type: Easing.InOutSine
						}
					}
				}
			}

			ColumnLayout {
				Layout.fillWidth: true
				spacing: 1

				RowLayout {
					Layout.fillWidth: true
					spacing: 6

					StyledText {
						Layout.fillWidth: true
						text: root.title
						font.weight: Font.DemiBold
						elide: Text.ElideRight
					}

					Rectangle {
						visible: root.critical
						implicitWidth: criticalText.implicitWidth + 12
						implicitHeight: 18
						radius: 9
						color: Qt.alpha(Theme.warning, 0.14)

						StyledText {
							id: criticalText

							anchors.centerIn: parent
							text: "critical"
							tone: Theme.warning
							font.pixelSize: Theme.size.tiny
							font.weight: Font.Bold
						}
					}
				}

				StyledText {
					Layout.fillWidth: true
					text: {
						const parts = [Netcore.stateText(root.paused ? "stopped" : root.status)];
						if (root.paused) parts[0] = "Paused";
						const ms = Number(root.service?.http?.ms);
						if (root.status === "up" && ms > 0) parts.push(`${Math.round(ms)} ms`);
						const restarts = Number(root.container.restarts) || 0;
						if (restarts > 0) parts.push(`${restarts} ${restarts === 1 ? "restart" : "restarts"}`);
						if (root.service?.port) parts.push(`:${root.service.port}`);
						return parts.join(" · ");
					}
					tone: root.status === "down" ? Theme.danger : Theme.textMuted
					font.pixelSize: Theme.size.small
					elide: Text.ElideRight
				}
			}

			IconButton {
				Layout.alignment: Qt.AlignTop
				implicitWidth: 30
				implicitHeight: 30
				visible: String(root.service?.url ?? "") !== ""
				icon: "open_in_new"
				onClicked: Netcore.openService(root.service)
			}
		}

		// memory against the limit
		ColumnLayout {
			Layout.fillWidth: true
			spacing: 4
			visible: root.mem > 0

			RowLayout {
				Layout.fillWidth: true

				StyledText {
					Layout.fillWidth: true
					text: root.limit > 0 ? `${Format.bytes(root.mem)} of ${Format.bytes(root.limit)}` : `${Format.bytes(root.mem)} · no limit`
					tone: Theme.textMuted
					font.pixelSize: Theme.size.small
					tabular: true
				}

				StyledText {
					visible: Number(root.container.cpu) > 0
					text: `${Number(root.container.cpu).toFixed(1)} % CPU`
					tone: Theme.textSubtle
					font.pixelSize: Theme.size.small
					tabular: true
				}
			}

			Rectangle {
				Layout.fillWidth: true
				implicitHeight: 6
				radius: 3
				color: Theme.layer3

				Rectangle {
					width: parent.width * root.memFill * root.enter
					height: parent.height
					radius: parent.radius
					color: root.limit > 0 && root.memFill > 0.9 ? Theme.danger : (root.limit > 0 && root.memFill > 0.75 ? Theme.warning : Theme.primary)

					Behavior on width {
						SpatialAnim {
							duration: Motion.extraLong
						}
					}
					Behavior on color {
						ColorAnim {}
					}
				}
			}
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 6
			visible: Netcore.admin && root.asking === "" && root.known && root.containerName !== "" && root.containerName !== "pshell-core" && root.name !== "core"

			TextButton {
				visible: root.running
				text: "Restart"
				icon: "restart"
				variant: "ghost"
				implicitHeight: 30
				busy: root.busy
				onActivated: root.asking = "restart"
			}

			TextButton {
				visible: root.running && !root.paused
				text: "Stop"
				icon: "stop"
				variant: "ghost"
				implicitHeight: 30
				onActivated: root.asking = "stop"
			}

			TextButton {
				visible: root.paused
				text: "Go on"
				icon: "play"
				variant: "ghost"
				implicitHeight: 30
				onActivated: root.asking = "unpause"
			}

			TextButton {
				visible: !root.running && !root.paused
				text: "Start"
				icon: "play"
				variant: "tonal"
				implicitHeight: 30
				busy: root.busy
				onActivated: root.asking = "start"
			}

			Item {
				Layout.fillWidth: true
			}

			StyledText {
				visible: !!root.service?.shed && root.service.shed !== "never"
				text: root.service?.shed === "stop" ? "the guard may stop it" : "pauses under pressure"
				tone: Theme.textSubtle
				font.pixelSize: Theme.size.tiny
			}
		}

		Ask {
			open: root.asking !== ""
			busy: root.busy
			mild: root.asking === "start" || root.asking === "unpause"
			icon: root.asking === "restart" ? "restart" : (root.asking === "stop" ? "stop" : "play")
			title: `${root.verb(root.asking)} ${root.title}?`
			detail: {
				if (root.asking === "start" || root.asking === "unpause") return "";
				if (root.critical) return root.name === "pihole" ? "Critical: every device at home asks it for names – the internet seems gone while it is down." : (root.name === "wg-easy" ? "Critical: the VPN goes down – the phone and the laptop away from home lose the NAS." : "Critical: other things depend on it.");
				return root.asking === "stop" ? "It stays stopped until it is started here or in the portal." : "It is gone for a few seconds.";
			}
			confirmText: root.verb(root.asking)
			onAccepted: {
				root.busy = true;
				Netcore.serviceAction(root.name, root.asking, () => {
					root.busy = false;
					root.asking = "";
				});
			}
			onCancelled: root.asking = ""
		}
	}
}
