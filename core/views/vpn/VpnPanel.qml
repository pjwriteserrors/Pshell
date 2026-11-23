pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.style.theme
import qs.core.services
import qs.style.widgets

// The phone's VPN (docs/mobile.md, "Away from home"): who is in it and what
// is linked to what. On top a map – the server in the middle, its clients
// around it, a line to each that is green while the client is in the VPN
// and answers, amber while it is in but does not answer, dashed while it is
// out; a dot runs along the lines that carry a Pshell link. Below it what is
// wrong, each with what to do; the Pshell links and the way each takes; the
// server's clients with their last handshake and traffic. Asks the daemon
// (`vpn status`) every few seconds while it is open.
Drawer {
	id: root

	panelId: "vpn"
	panelWidth: Math.min(780, (root.screen?.width ?? 1920) - 80)
	centered: true
	contentHeight: layout.implicitHeight

	property var status: null
	property bool busy: false
	property string failure: ""
	property real now: Date.now() / 1000
	// the dots on the lines
	property real flow: 0

	readonly property var clients: root.status?.clients ?? []
	readonly property var links: root.status?.links ?? []
	readonly property var problems: root.status?.problems ?? []
	readonly property int serious: root.problems.filter(p => p.level !== "info").length
	// the map's nodes: the server's clients, or – away from home, without them – this machine and the links
	readonly property var nodes: {
		if (!root.status) return [];
		if (root.clients.length > 0) return root.clients.map(client => {
			const link = root.links.find(l => l.client === client.name) ?? null;
			return {
				name: client.name, address: client.address, self: client.self,
				state: client.self ? (root.status.tunnel.active ? "ok" : "down") : !client.enabled || !client.online ? "down" : client.ping >= 0 ? "ok" : "quiet",
				ping: client.ping, icon: root.iconFor(client.name, link?.kind ?? "", client.self), link: link
			};
		});
		const own = { name: root.status.host, address: root.status.tunnel.address, self: true, state: root.status.tunnel.active ? "ok" : "down", ping: 0, icon: root.iconFor(root.status.host, "", true), link: null };
		return [own].concat(root.links.map(link => ({
			name: link.name, address: link.way === "vpn" ? link.address : "", self: false,
			state: link.connected && link.way.startsWith("vpn") ? "ok" : "down", ping: -1, icon: root.iconFor(link.name, link.kind, false), link: link
		})));
	}

	function refresh(fresh) {
		if (root.busy) return;
		root.busy = true;
		Phone.call("vpn", "status", { fresh: !!fresh }, (data, error) => {
			root.busy = false;
			root.now = Date.now() / 1000;
			if (error) {
				root.failure = String(error.message || error.code);
				return;
			}
			root.failure = "";
			root.status = data;
		}, { timeout: 25 });
	}

	function iconFor(name, kind, self) {
		const text = String(name).toLowerCase();
		if (kind === "phone" || /handy|phone|a55|pixel|galaxy/.test(text)) return "cellphone";
		if (/laptop|cogi|book/.test(text)) return "laptop";
		if (kind === "pc" || self || /pc|desktop|iseeu/.test(text)) return "monitor";
		return "lan";
	}

	function ago(seconds) {
		if (!seconds) return "never";
		const s = Math.max(0, Math.round(root.now - seconds));
		if (s < 60) return `${s} s ago`;
		if (s < 3600) return `${Math.round(s / 60)} min ago`;
		if (s < 172800) return `${Math.round(s / 3600)} h ago`;
		return `${Math.round(s / 86400)} days ago`;
	}

	function bytes(n) {
		if (n < 1024) return `${n} B`;
		if (n < 1048576) return `${(n / 1024).toFixed(0)} KB`;
		if (n < 1073741824) return `${(n / 1048576).toFixed(1)} MB`;
		return `${(n / 1073741824).toFixed(2)} GB`;
	}

	function wayText(link) {
		if (!link.connected) return `Not linked · seen ${root.ago(link.seen)}`;
		const way = { "vpn": "over the VPN", "vpn-lan": "over the VPN into the home LAN", "lan": "in the LAN", "internet": "over the internet" }[link.way] ?? "";
		return `Linked · ${link.address}${way ? " · " + way : ""}`;
	}

	function stateColor(state) {
		return state === "ok" ? Theme.success : state === "quiet" ? Theme.warning : Theme.textFaint;
	}

	onPanelOpened: {
		root.status = null;
		root.refresh(true);
	}

	Timer {
		interval: 4000
		repeat: true
		running: root.shown
		onTriggered: root.refresh(false)
	}

	NumberAnimation on flow {
		from: 0
		to: 1
		duration: 1800
		loops: Animation.Infinite
		running: root.shown
	}

	ColumnLayout {
		id: layout

		anchors.left: parent.left
		anchors.right: parent.right
		spacing: 14

		// ── what this is ──────────────────────────────────────────────────
		RowLayout {
			Layout.fillWidth: true
			spacing: 12

			Rectangle {
				Layout.preferredWidth: 40
				Layout.preferredHeight: 40
				radius: 20
				color: root.serious > 0 ? Theme.dangerContainer : Theme.primaryContainer

				Glyph {
					anchors.centerIn: parent
					icon: "vpn"
					size: 22
					color: root.serious > 0 ? Theme.danger : Theme.primary
				}
			}

			ColumnLayout {
				spacing: 0

				StyledText {
					text: "VPN"
					font.pixelSize: Theme.size.heading
					font.weight: Font.Bold
				}

				StyledText {
					text: !root.status ? (root.failure || "Asking…")
						: `${root.status.network} · server ${root.status.server.lan || root.status.server.address}${root.status.tunnel.address ? " · this is " + root.status.tunnel.address : ""}`
					tone: Theme.textMuted
					font.pixelSize: Theme.size.label
				}
			}

			Item {
				Layout.fillWidth: true
			}

			Rectangle {
				Layout.preferredHeight: 28
				Layout.preferredWidth: verdict.implicitWidth + 22
				radius: 14
				visible: root.status !== null
				color: root.serious > 0 ? Theme.dangerContainer : Theme.primaryContainer

				StyledText {
					id: verdict

					anchors.centerIn: parent
					text: root.serious === 0 ? "All good" : root.serious === 1 ? "1 problem" : `${root.serious} problems`
					tone: root.serious > 0 ? Theme.danger : Theme.primary
					font.pixelSize: Theme.size.label
					font.weight: Font.DemiBold
				}
			}

			IconButton {
				implicitWidth: 32
				implicitHeight: 32
				icon: "refresh"
				onClicked: root.refresh(true)
			}
		}

		// ── the map ───────────────────────────────────────────────────────
		Rectangle {
			id: map

			Layout.fillWidth: true
			Layout.preferredHeight: 300
			radius: Theme.radius.large
			color: Theme.layer1

			readonly property real cx: width / 2
			readonly property real cy: height / 2
			readonly property real rx: width * 0.34
			readonly property real ry: height * 0.32
			readonly property var spots: root.nodes.map((node, i) => {
				const angle = Math.PI + i * 2 * Math.PI / Math.max(1, root.nodes.length);
				return { x: map.cx + Math.cos(angle) * map.rx, y: map.cy + Math.sin(angle) * map.ry };
			})

			onSpotsChanged: lines.requestPaint()

			Canvas {
				id: lines

				anchors.fill: parent

				onPaint: {
					const ctx = getContext("2d");
					ctx.reset();
					ctx.lineCap = "round";
					root.nodes.forEach((node, i) => {
						const spot = map.spots[i];
						if (!spot) return;
						ctx.strokeStyle = root.stateColor(node.state);
						ctx.lineWidth = node.state === "down" ? 1.5 : 2.5;
						ctx.setLineDash(node.state === "down" ? [5, 6] : []);
						ctx.beginPath();
						ctx.moveTo(map.cx, map.cy);
						ctx.lineTo(spot.x, spot.y);
						ctx.stroke();
					});
				}

				Connections {
					target: Theme

					function onPrimaryChanged() {
						lines.requestPaint();
					}
				}

				Connections {
					target: root

					function onNodesChanged() {
						lines.requestPaint();
					}
				}
			}

			// a Pshell link runs this way: dots from the node to the server
			Repeater {
				model: root.nodes.length

				delegate: Rectangle {
					id: dot

					required property int index
					readonly property var node: root.nodes[dot.index]
					readonly property var spot: map.spots[dot.index]
					readonly property real t: (root.flow + dot.index * 0.31) % 1

					visible: !!dot.node && !!dot.spot && (dot.node.link?.connected ?? false) && dot.node.state !== "down"
					width: 7
					height: 7
					radius: 3.5
					color: Theme.primary
					x: dot.spot ? dot.spot.x + (map.cx - dot.spot.x) * dot.t - 3.5 : 0
					y: dot.spot ? dot.spot.y + (map.cy - dot.spot.y) * dot.t - 3.5 : 0
					opacity: Math.sin(dot.t * Math.PI)
				}
			}

			// the ping on each line
			Repeater {
				model: root.nodes.length

				delegate: StyledText {
					id: latency

					required property int index
					readonly property var node: root.nodes[latency.index]
					readonly property var spot: map.spots[latency.index]

					visible: !!latency.node && !latency.node.self && latency.node.ping > 0
					text: latency.node ? `${Math.round(latency.node.ping)} ms` : ""
					x: latency.spot ? (latency.spot.x + map.cx) / 2 - width / 2 : 0
					y: latency.spot ? (latency.spot.y + map.cy) / 2 - height - 4 : 0
					tone: Theme.textMuted
					font.pixelSize: Theme.size.tiny
				}
			}

			// the server
			Column {
				x: map.cx - width / 2
				y: map.cy - 34
				spacing: 4

				Rectangle {
					anchors.horizontalCenter: parent.horizontalCenter
					width: 68
					height: 68
					radius: 34
					color: Theme.primaryContainer
					border.width: 2
					border.color: root.status && root.status.server.ping >= 0 ? Theme.primary : Theme.danger

					Glyph {
						anchors.centerIn: parent
						icon: "server_network"
						size: 30
						color: Theme.primary
					}
				}

				StyledText {
					anchors.horizontalCenter: parent.horizontalCenter
					text: "Server"
					font.pixelSize: Theme.size.label
					font.weight: Font.DemiBold
				}

				StyledText {
					anchors.horizontalCenter: parent.horizontalCenter
					text: root.status ? `${root.status.server.address}${root.status.server.ping >= 0 ? " · " + Math.round(root.status.server.ping) + " ms" : " · no answer"}` : ""
					tone: Theme.textMuted
					font.pixelSize: Theme.size.tiny
				}
			}

			// the clients
			Repeater {
				model: root.nodes

				delegate: Column {
					id: node

					required property var modelData
					required property int index
					readonly property var spot: map.spots[node.index] ?? { x: 0, y: 0 }

					x: node.spot.x - width / 2
					y: node.spot.y - 26
					spacing: 3

					Behavior on x {
						Anim {}
					}
					Behavior on y {
						Anim {}
					}

					Rectangle {
						anchors.horizontalCenter: parent.horizontalCenter
						width: 52
						height: 52
						radius: 26
						color: node.modelData.state === "down" ? Theme.layer2 : Qt.tint(Theme.layer2, Qt.alpha(root.stateColor(node.modelData.state), 0.22))
						border.width: node.modelData.self ? 3 : 2
						border.color: root.stateColor(node.modelData.state)

						Glyph {
							anchors.centerIn: parent
							icon: node.modelData.icon
							size: 24
							color: node.modelData.state === "down" ? Theme.textSubtle : Theme.text
						}

						// a Pshell link
						Rectangle {
							anchors.right: parent.right
							anchors.top: parent.top
							anchors.margins: -2
							width: 16
							height: 16
							radius: 8
							visible: node.modelData.link?.connected ?? false
							color: Theme.primary

							Glyph {
								anchors.centerIn: parent
								icon: "check_bold"
								size: 10
								color: Theme.onPrimary
							}
						}
					}

					StyledText {
						anchors.horizontalCenter: parent.horizontalCenter
						text: node.modelData.self ? `${node.modelData.name} (here)` : node.modelData.name
						font.pixelSize: Theme.size.label
						font.weight: Font.DemiBold
					}

					StyledText {
						anchors.horizontalCenter: parent.horizontalCenter
						text: [node.modelData.address, node.modelData.state === "ok" ? "" : node.modelData.state === "quiet" ? "no answer" : "out"].filter(s => s).join(" · ")
						tone: node.modelData.state === "quiet" ? Theme.warning : Theme.textMuted
						font.pixelSize: Theme.size.tiny
					}
				}
			}

			// the legend
			Row {
				anchors.left: parent.left
				anchors.bottom: parent.bottom
				anchors.margins: 12
				spacing: 14

				Repeater {
					model: [
						{ color: Theme.success, text: "in the VPN" },
						{ color: Theme.warning, text: "in, no answer" },
						{ color: Theme.textFaint, text: "out" },
						{ color: Theme.primary, text: "Pshell link" }
					]

					delegate: Row {
						id: key

						required property var modelData

						spacing: 5

						Rectangle {
							anchors.verticalCenter: parent.verticalCenter
							width: 8
							height: 8
							radius: 4
							color: key.modelData.color
						}

						StyledText {
							text: key.modelData.text
							tone: Theme.textSubtle
							font.pixelSize: Theme.size.tiny
						}
					}
				}
			}

			StyledText {
				anchors.right: parent.right
				anchors.bottom: parent.bottom
				anchors.margins: 12
				visible: root.status !== null && !root.status.server.details
				text: "Server details from the home network only"
				tone: Theme.textSubtle
				font.pixelSize: Theme.size.tiny
			}

			Spinner {
				anchors.centerIn: parent
				visible: root.status === null && root.failure === ""
			}
		}

		// ── what is wrong ─────────────────────────────────────────────────
		SectionLabel {
			text: root.problems.length > 0 ? "Problems" : "Problems: none"
			visible: root.status !== null
		}

		Repeater {
			model: root.problems

			delegate: Rectangle {
				id: problem

				required property var modelData
				readonly property color tint: problem.modelData.level === "error" ? Theme.danger : problem.modelData.level === "warning" ? Theme.warning : Theme.primary

				Layout.fillWidth: true
				implicitHeight: problemRow.implicitHeight + 20
				radius: Theme.radius.medium
				color: Qt.tint(Theme.layer1, Qt.alpha(problem.tint, 0.1))
				border.width: 1
				border.color: Qt.alpha(problem.tint, 0.35)

				RowLayout {
					id: problemRow

					anchors.fill: parent
					anchors.margins: 10
					spacing: 10

					Glyph {
						Layout.alignment: Qt.AlignTop
						icon: problem.modelData.level === "error" ? "close_circle" : problem.modelData.level === "warning" ? "alert" : "information_outline"
						size: 20
						color: problem.tint
					}

					ColumnLayout {
						Layout.fillWidth: true
						spacing: 2

						StyledText {
							Layout.fillWidth: true
							text: problem.modelData.text
							font.weight: Font.DemiBold
							wrapMode: Text.Wrap
						}

						StyledText {
							Layout.fillWidth: true
							visible: problem.modelData.hint !== ""
							text: problem.modelData.hint
							tone: Theme.textMuted
							font.pixelSize: Theme.size.label
							wrapMode: Text.Wrap
						}
					}

					IconButton {
						Layout.alignment: Qt.AlignTop
						implicitWidth: 28
						implicitHeight: 28
						visible: problem.modelData.hint !== ""
						icon: "content_copy"
						onClicked: Quickshell.clipboardText = problem.modelData.hint
					}
				}
			}
		}

		// ── the Pshell links ──────────────────────────────────────────────
		SectionLabel {
			text: "Pshell links"
			visible: root.links.length > 0
		}

		Repeater {
			model: root.links

			delegate: ListItem {
				id: link

				required property var modelData

				Layout.fillWidth: true
				icon: root.iconFor(link.modelData.name, link.modelData.kind, false)
				title: link.modelData.client ? `${link.modelData.name}  ·  ${link.modelData.client}` : link.modelData.name
				subtitle: root.wayText(link.modelData)
				selected: link.modelData.connected
			}
		}

		// ── the NAS: reached at home or through the VPN, mounted or not ──
		ListItem {
			Layout.fillWidth: true
			visible: Plugins.on("nas")
			icon: "server_network"
			title: Nas.online ? `NAS  ·  ${Nas.viaText}` : "NAS"
			subtitle: !Nas.online ? (Nas.configured ? "Not reachable – neither at home nor through the VPN" : "Not set up") : `${Nas.address}${Nas.mounted ? " · mounted at " + Nas.mountPath.replace(Paths.home, "~") : " · not mounted"}`
			selected: Nas.online
			onClicked: {
				Popups.close();
				Nas.openSettings();
			}
		}

		// ── the server's clients ──────────────────────────────────────────
		SectionLabel {
			text: "On the server"
			visible: root.clients.length > 0
		}

		GridLayout {
			Layout.fillWidth: true
			visible: root.clients.length > 0
			columns: 5
			columnSpacing: 16
			rowSpacing: 6

			Repeater {
				model: ["Client", "Address", "Comes from", "Handshake", "Traffic ↓ ↑"]

				delegate: StyledText {
					required property string modelData

					text: modelData
					tone: Theme.textSubtle
					font.pixelSize: Theme.size.tiny
					font.weight: Font.DemiBold
				}
			}

			Repeater {
				model: root.clients.reduce((cells, client) => cells.concat([
					{ text: client.self ? `${client.name} (here)` : client.name, strong: true, state: client.self || (client.online && client.enabled) ? "ok" : "down" },
					{ text: client.address },
					{ text: client.endpoint || "–" },
					{ text: client.enabled ? root.ago(client.handshake) : "switched off" },
					{ text: `${root.bytes(client.tx)}  ${root.bytes(client.rx)}` }
				]), [])

				delegate: RowLayout {
					id: cell

					required property var modelData

					spacing: 6

					Rectangle {
						visible: cell.modelData.state !== undefined
						Layout.preferredWidth: 8
						Layout.preferredHeight: 8
						radius: 4
						color: root.stateColor(cell.modelData.state ?? "down")
					}

					StyledText {
						text: cell.modelData.text
						font.pixelSize: Theme.size.label
						font.weight: cell.modelData.strong ? Font.DemiBold : Font.Normal
						font.family: cell.modelData.strong ? Theme.fontFamily : Theme.monoFamily
					}
				}
			}
		}
	}
}
