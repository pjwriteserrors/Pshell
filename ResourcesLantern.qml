pragma ComponentBehavior: Bound

import QtQuick
import "components"

// The machine, read as wires under load. CPU and memory keep a short
// history drawn as a filament that has been bent by the last minute; the
// disks and the mouse are filaments lit by how full they are.
Item {
	id: page

	property real reveal: 1
	required property var monitor
	property var cpuHistory: []
	property var memHistory: []

	implicitHeight: column.implicitHeight

	function push(list, value) {
		const next = list.concat([Math.max(0, Math.min(1, value))]);
		return next.length > 40 ? next.slice(next.length - 40) : next;
	}

	Timer {
		interval: 2000; running: page.visible; repeat: true; triggeredOnStart: true
		onTriggered: {
			page.cpuHistory = page.push(page.cpuHistory, page.monitor.cpuUsage);
			page.memHistory = page.push(page.memHistory, page.monitor.memoryUsage);
		}
	}

	component Trace: Item {
		id: trace
		property string label: ""
		property string value: ""
		property string detail: ""
		property var history: []
		property real level: 0
		height: 62

		FText { x: 0; y: 0; text: trace.label; caps: true; tone: "mute"; font.pixelSize: Filament.textXs }
		FText { anchors.right: parent.right; y: 0; text: trace.value; mono: true; font.pixelSize: Filament.textMd; font.weight: Font.DemiBold }
		FText { anchors.right: parent.right; y: 18; text: trace.detail; mono: true; tone: "mute"; font.pixelSize: Filament.textXs }

		Canvas {
			id: canvas
			x: 0; y: 20
			width: parent.width - 96
			height: 40
			property var history: trace.history
			property color hot: trace.level > 0.85 ? Filament.alert : Filament.charge
			property color cold: Filament.wireDim
			onHistoryChanged: requestPaint()
			onHotChanged: requestPaint()
			onPaint: {
				const ctx = getContext("2d");
				ctx.clearRect(0, 0, width, height);
				const points = history || [];
				ctx.lineWidth = 2;
				ctx.lineCap = "round";
				ctx.lineJoin = "round";
				const n = 40;
				const stepX = width / (n - 1);
				const offset = n - points.length;
				ctx.beginPath();
				ctx.strokeStyle = cold;
				ctx.moveTo(0, height - 1);
				ctx.lineTo(Math.max(0, offset) * stepX, height - 1);
				ctx.stroke();
				if (points.length < 2) return;
				ctx.beginPath();
				ctx.strokeStyle = hot;
				for (let i = 0; i < points.length; i += 1) {
					const x = (offset + i) * stepX;
					const y = height - 1 - points[i] * (height - 3);
					if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
				}
				ctx.stroke();
				ctx.globalAlpha = 0.14;
				ctx.fillStyle = hot;
				ctx.lineTo((offset + points.length - 1) * stepX, height);
				ctx.lineTo(offset * stepX, height);
				ctx.closePath();
				ctx.fill();
			}
		}

		Spark {
			visible: trace.history.length > 0
			x: canvas.x + canvas.width - 4
			y: canvas.y + canvas.height - 1 - trace.level * (canvas.height - 3) - 4
			size: 7
			color: trace.level > 0.85 ? Filament.alert : Filament.charge
			Behavior on y { NumberAnimation { duration: Filament.settle; easing.type: Easing.BezierSpline; easing.bezierCurve: Filament.easeSettle } }
		}
	}

	component Gauge: Item {
		id: gauge
		property string label: ""
		property string value: ""
		property string detail: ""
		property real level: 0
		property string icon: ""
		height: 26

		FIcon { visible: gauge.icon !== ""; anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; name: gauge.icon; size: 14; color: Filament.inkMute }
		FText { x: gauge.icon !== "" ? 22 : 0; anchors.verticalCenter: parent.verticalCenter; width: 70; text: gauge.label; font.pixelSize: Filament.textSm }
		Wire {
			x: 100; anchors.verticalCenter: parent.verticalCenter
			width: parent.width - 100 - 96
			height: 3; thickness: 3
			cold: Filament.wireDim
			hot: gauge.level > 0.9 ? Filament.alert : Filament.charge
			lit: gauge.level
		}
		FText { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; text: gauge.value; mono: true; font.pixelSize: Filament.textSm; horizontalAlignment: Text.AlignRight }
	}

	Column {
		id: column
		width: parent.width
		spacing: 12

		Band {
			reveal: page.reveal; order: 0; width: parent.width; height: 62
			Trace {
				width: parent.width
				label: "cpu" + (page.monitor.cpuText !== "" ? "  ·  " + page.monitor.cpuText : "")
				value: `${Math.round(page.monitor.cpuUsage * 100)}%`
				history: page.cpuHistory
				level: page.monitor.cpuUsage
			}
		}

		Band {
			reveal: page.reveal; order: 1; width: parent.width; height: 62
			Trace {
				width: parent.width
				label: "memory"
				value: `${Math.round(page.monitor.memoryUsage * 100)}%`
				detail: page.monitor.memoryText
				history: page.memHistory
				level: page.monitor.memoryUsage
			}
		}

		Band {
			reveal: page.reveal; order: 2; width: parent.width; height: 2
			Wire { width: parent.width; height: 2; cold: Filament.wireDim }
		}

		Repeater {
			model: page.monitor.disks
			Band {
				id: diskBand
				required property var modelData
				required property int index
				reveal: page.reveal; order: 3 + index; width: column.width; height: 26
				Gauge {
					width: parent.width
					icon: "drive-harddisk-symbolic"
					label: diskBand.modelData.name
					value: `${diskBand.modelData.freeText} free`
					level: diskBand.modelData.usage
				}
			}
		}

		Band {
			visible: page.monitor.mouseBatteryAvailable
			reveal: page.reveal; order: 4 + page.monitor.disks.length; width: parent.width; height: 26
			Gauge {
				width: parent.width
				icon: "input-mouse-symbolic"
				label: page.monitor.mouseBatteryName
				value: page.monitor.mouseBatteryText + (page.monitor.mouseBatteryStatus !== "" ? "  " + page.monitor.mouseBatteryStatus : "")
				level: page.monitor.mouseBatteryUsage
			}
		}
	}
}
