import QtQuick
import QtQuick.Effects
import qs.style.theme
import qs.style.widgets
import qs.core.services

// A live item of a tray: the clock, the weather, the load of the CPU or the
// memory, what plays, the running timer, the battery, the volume. As tall
// as an icon, as wide as the widget needs (AppTray.widgets).
Rectangle {
	id: root

	property var item: null
	property bool lifted: false
	readonly property string kind: String(root.item?.widget ?? "")
	readonly property real unit: root.height

	radius: root.unit * 0.27
	color: root.lifted ? Theme.layer3 : Theme.layer2
	border.width: 1
	border.color: Theme.outline

	Behavior on color {
		ColorAnim {}
	}

	// the clock ticks only while it is shown
	property date time: new Date()

	Timer {
		running: root.kind === "clock" && root.visible
		interval: 1000
		repeat: true
		triggeredOnStart: true
		onTriggered: root.time = new Date()
	}

	Column {
		visible: root.kind === "clock"
		anchors.centerIn: parent
		spacing: -2

		StyledText {
			anchors.horizontalCenter: parent.horizontalCenter
			text: Qt.formatTime(root.time, "HH:mm")
			font.pixelSize: root.unit * 0.36
			font.weight: Font.DemiBold
			tabular: true
		}

		StyledText {
			anchors.horizontalCenter: parent.horizontalCenter
			text: Qt.formatDate(root.time, "ddd d.M.")
			tone: Theme.textMuted
			font.pixelSize: Math.max(8, root.unit * 0.17)
		}
	}

	// a glyph over a value: weather, battery, volume, timer
	Column {
		visible: ["weather", "battery", "volume", "timer"].includes(root.kind)
		anchors.centerIn: parent
		spacing: 1

		Glyph {
			anchors.horizontalCenter: parent.horizontalCenter
			icon: AppTray.widgetGlyph(root.kind)
			size: root.unit * 0.4
			color: root.kind === "timer" && QtrackTimer.tracking ? Theme.primary : Theme.text
		}

		StyledText {
			anchors.horizontalCenter: parent.horizontalCenter
			text: {
				switch (root.kind) {
				case "weather": return Weather.available ? Weather.temperature : "--";
				case "battery": return SysStats.batteryAvailable ? `${SysStats.batteryPercent}%` : (Phone.reachable && Phone.battery >= 0 ? `${Phone.battery}%` : "--");
				case "volume": return Audio.muted ? "Muted" : `${Math.round(Audio.volume * 100)}%`;
				case "timer": return QtrackTimer.tracking ? QtrackTimer.duration : "Idle";
				}
				return "";
			}
			tone: Theme.textMuted
			font.pixelSize: Math.max(8, root.unit * 0.18)
			font.weight: Font.Medium
			tabular: true
		}
	}

	// a curve of the load
	Item {
		visible: root.kind === "cpu" || root.kind === "memory"
		anchors.fill: parent
		anchors.margins: root.unit * 0.12

		Sparkline {
			anchors.left: parent.left
			anchors.right: parent.right
			anchors.bottom: parent.bottom
			height: parent.height * 0.6
			values: root.kind === "cpu" ? SysStats.cpuHistory : SysStats.memoryHistory
			maximum: 100
			lineWidth: 1.5
			color: Theme.primary
		}

		StyledText {
			anchors.left: parent.left
			anchors.top: parent.top
			text: `${root.kind === "cpu" ? "CPU" : "RAM"} ${Math.round(root.kind === "cpu" ? SysStats.cpu : SysStats.memory)}%`
			font.pixelSize: Math.max(8, root.unit * 0.18)
			font.weight: Font.DemiBold
			tabular: true
		}
	}

	// what plays: its cover, title and artist
	Item {
		visible: root.kind === "media"
		anchors.fill: parent
		anchors.margins: root.unit * 0.1

		Image {
			id: cover

			width: parent.height
			height: parent.height
			source: Media.art
			sourceSize: Qt.size(128, 128)
			fillMode: Image.PreserveAspectCrop
			visible: false
			asynchronous: true
		}

		Rectangle {
			id: coverMask

			width: parent.height
			height: parent.height
			radius: width * 0.2
			visible: false
			layer.enabled: true
		}

		MultiEffect {
			width: parent.height
			height: parent.height
			source: cover
			maskEnabled: true
			maskSource: coverMask
			visible: Media.art !== ""
		}

		Rectangle {
			visible: Media.art === ""
			width: parent.height
			height: parent.height
			radius: width * 0.2
			color: Theme.layer3

			Glyph {
				anchors.centerIn: parent
				icon: Media.playing ? "pause" : "music_note"
				size: parent.width * 0.5
				color: Theme.textMuted
				animated: false
			}
		}

		Column {
			anchors.left: parent.left
			anchors.leftMargin: parent.height + 8
			anchors.right: parent.right
			anchors.verticalCenter: parent.verticalCenter
			spacing: 0

			StyledText {
				width: parent.width
				text: Media.hasPlayer ? Media.title : "Nothing plays"
				font.pixelSize: Math.max(9, root.unit * 0.2)
				font.weight: Font.DemiBold
			}

			StyledText {
				width: parent.width
				visible: Media.artist !== ""
				text: Media.artist
				tone: Theme.textMuted
				font.pixelSize: Math.max(8, root.unit * 0.17)
			}

			// how far it is
			Rectangle {
				visible: Media.hasProgress
				width: parent.width
				height: 2
				radius: 1
				color: Theme.layer3

				Rectangle {
					width: parent.width * (Media.length > 0 ? Media.position / Media.length : 0)
					height: parent.height
					radius: 1
					color: Theme.primary
				}
			}
		}
	}
}
