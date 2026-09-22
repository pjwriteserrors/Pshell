pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io
import "components"

// The connection as two filaments carrying traffic: up on one, down on the
// other, each with a spark at the head of a moving history. Offline, the
// wires go cold. One hold-to-charge verb disconnects.
Item {
	id: page

	property real reveal: 1
	property bool active: false
	property string statusType: "offline"
	property string interfaceName: ""
	property string ip: ""
	property real uploadSpeed: 0
	property real downloadSpeed: 0
	property var uploadHistory: []
	property var downloadHistory: []
	property real lastRx: -1
	property real lastTx: -1
	property real historyMax: 1
	readonly property int throughputIntervalMs: 2000

	signal disconnectRequested()

	implicitHeight: column.implicitHeight

	function formatSpeed(bytesPerSecond) {
		const units = ["B/s", "KB/s", "MB/s", "GB/s"];
		let value = Math.max(0, bytesPerSecond);
		let unit = 0;
		while (value >= 1024 && unit < units.length - 1) { value /= 1024; unit += 1; }
		return `${unit === 0 ? Math.round(value) : value.toFixed(1)} ${units[unit]}`;
	}

	function resetThroughput() {
		page.lastRx = -1; page.lastTx = -1;
		page.uploadSpeed = 0; page.downloadSpeed = 0;
		page.uploadHistory = []; page.downloadHistory = [];
		page.historyMax = 1;
	}

	function sample(raw) {
		if (page.interfaceName === "") return;
		const match = String(raw).match(new RegExp(`^\\s*${page.interfaceName}:\\s*(.+)$`, "m"));
		if (!match) return;
		const fields = match[1].trim().split(/\s+/).map(Number);
		if (fields.length < 16) return;
		const rx = fields[0], tx = fields[8];
		if (page.lastRx < 0) { page.lastRx = rx; page.lastTx = tx; return; }
		const seconds = page.throughputIntervalMs / 1000;
		page.downloadSpeed = Math.max(0, (rx - page.lastRx) / seconds);
		page.uploadSpeed = Math.max(0, (tx - page.lastTx) / seconds);
		page.lastRx = rx; page.lastTx = tx;
		page.downloadHistory = page.downloadHistory.concat([page.downloadSpeed]).slice(-30);
		page.uploadHistory = page.uploadHistory.concat([page.uploadSpeed]).slice(-30);
		page.historyMax = Math.max(1, ...page.downloadHistory, ...page.uploadHistory);
	}

	onInterfaceNameChanged: resetThroughput()
	onStatusTypeChanged: if (statusType === "offline") resetThroughput()

	Timer {
		interval: page.throughputIntervalMs
		running: page.active && page.statusType !== "offline"
		repeat: true
		triggeredOnStart: true
		onTriggered: netDev.reload()
		onRunningChanged: if (!running) page.resetThroughput()
	}

	FileView {
		id: netDev
		path: "/proc/net/dev"
		onLoaded: page.sample(text())
	}

	component Stream: Item {
		id: flow
		property string label: ""
		property real speed: 0
		property var history: []
		property bool up: false
		height: 58

		FText { x: 0; y: 0; text: flow.label; caps: true; tone: "mute"; font.pixelSize: Filament.textXs }
		FText { anchors.right: parent.right; y: 0; text: page.formatSpeed(flow.speed); mono: true; font.pixelSize: Filament.textMd; font.weight: Font.DemiBold }

		Canvas {
			id: canvas
			x: 0; y: 20
			width: parent.width
			height: 36
			property var history: flow.history
			property real max: page.historyMax
			property color hot: flow.up ? Filament.charge3 : Filament.charge
			onHistoryChanged: requestPaint()
			onMaxChanged: requestPaint()
			onPaint: {
				const ctx = getContext("2d");
				ctx.clearRect(0, 0, width, height);
				const points = history || [];
				const n = 30, stepX = width / (n - 1), offset = n - points.length;
				ctx.lineWidth = 2; ctx.lineCap = "round"; ctx.lineJoin = "round";
				ctx.beginPath(); ctx.strokeStyle = Filament.wireDim;
				ctx.moveTo(0, height - 1); ctx.lineTo(width, height - 1); ctx.stroke();
				if (points.length < 2) return;
				ctx.beginPath(); ctx.strokeStyle = hot;
				for (let i = 0; i < points.length; i += 1) {
					const x = (offset + i) * stepX;
					const y = height - 1 - (points[i] / max) * (height - 4);
					if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
				}
				ctx.stroke();
			}
		}

		Spark {
			visible: flow.history.length > 0
			x: canvas.x + canvas.width - 4
			y: canvas.y + canvas.height - 1 - (flow.speed / page.historyMax) * (canvas.height - 4) - 4
			size: 7
			color: flow.up ? Filament.charge3 : Filament.charge
			Behavior on y { NumberAnimation { duration: Filament.settle; easing.type: Easing.BezierSpline; easing.bezierCurve: Filament.easeSettle } }
		}
	}

	Column {
		id: column
		width: parent.width
		spacing: 12

		Band {
			reveal: page.reveal; order: 0; width: parent.width; height: 44
			FIcon {
				id: icon
				anchors.left: parent.left
				anchors.verticalCenter: parent.verticalCenter
				name: page.statusType === "ethernet" ? "network-wired-symbolic"
					: page.statusType === "wifi" ? "network-wireless-signal-excellent-symbolic" : "network-wireless-offline-symbolic"
				fallbacks: ["network-wireless-signal-excellent-symbolic"]
				size: 26
				color: page.statusType === "offline" ? Filament.inkMute : Filament.charge
			}
			Column {
				anchors.left: icon.right
				anchors.leftMargin: 12
				anchors.verticalCenter: parent.verticalCenter
				spacing: 2
				FText {
					text: page.statusType === "ethernet" ? "Ethernet" : page.statusType === "wifi" ? "Wi-Fi" : "Offline"
					font.pixelSize: Filament.textLg
					font.weight: Font.DemiBold
				}
				FText {
					text: page.statusType === "offline" ? "no interface" : `${page.interfaceName}  ·  ${page.ip !== "" ? page.ip : "no IP"}`
					mono: true
					tone: "mute"
					font.pixelSize: Filament.textXs
				}
			}
		}

		Band {
			reveal: page.reveal; order: 1; width: parent.width; height: 58
			Stream { width: parent.width; label: "download"; speed: page.downloadSpeed; history: page.downloadHistory }
		}

		Band {
			reveal: page.reveal; order: 2; width: parent.width; height: 58
			Stream { width: parent.width; label: "upload"; speed: page.uploadSpeed; history: page.uploadHistory; up: true }
		}

		Band {
			reveal: page.reveal; order: 3; width: parent.width; height: 34
			visible: page.statusType !== "offline"
			HoldButton {
				anchors.right: parent.right
				text: "hold to disconnect"
				icon: "window-close-symbolic"
				onHeld: page.disconnectRequested()
			}
			FText {
				anchors.left: parent.left
				anchors.verticalCenter: parent.verticalCenter
				text: page.statusType === "ethernet" ? "turns autoconnect off for this device" : "drops the current network"
				tone: "faint"
				font.pixelSize: Filament.textXs
			}
		}
	}
}
