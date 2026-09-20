pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Services.SystemTray
import Quickshell.Wayland
import "components"
import "components/ArcInk.js" as Ink

// The horizon again, on a screen that is not the primary one.
//
// Same sanctum, fewer things in it: the chronomancer, the realms on this
// output, and the way out. The readings that belong to the machine as a whole
// — the oracle, the ravens, the core — stay on the one horizon that owns them.
// Every press is a signal; this window knows nothing about panels.
PanelWindow {
	id: root

	signal launcherClicked
	signal mediaClicked
	signal clockClicked
	signal clipboardClicked
	signal bluetoothClicked
	signal networkClicked
	signal resourcesClicked
	signal powerClicked

	required property var screenModel
	required property string networkStatusType
	required property var niriState

	// Kept so the primary shell can keep handing its palette over; the colours
	// themselves come from Bio, which reads the same Wallust file.
	property color foreground: Arc.ink
	property color background: Arc.abyss
	property color secondaryBoxColor: Arc.veil1
	property color secondaryBoxStrongColor: Arc.veil2
	property color secondaryInsetColor: Arc.depth
	property color tertiary: Arc.aetherAlt
	property color primary: Arc.aether
	property color onPrimaryColor: Arc.onAether
	property color danger: Arc.bane

	property date now: new Date()

	function trayIconSource(icon) {
		if (!icon) return "";

		if (icon.includes("?path=")) {
			const parts = icon.split("?path=");
			const name = parts[0];
			const path = parts[1];
			return Qt.resolvedUrl(`${path}/${name.slice(name.lastIndexOf("/") + 1)}`);
		}

		return icon;
	}

	screen: screenModel

	anchors {
		left: true
		right: true
		bottom: true
	}

	margins {
		left: 0
		right: 0
		bottom: 0
	}

	exclusiveZone: Math.round(Arc.horizon)
	implicitHeight: Math.round(Arc.horizon)
	color: "transparent"

	Item {
		id: bar
		anchors.fill: parent

		readonly property real chronoCentreY: bar.height + Arc.chronoSunk

		Rectangle {
			anchors.fill: parent
			gradient: Gradient {
				GradientStop { position: 0.0; color: "transparent" }
				GradientStop { position: 0.35; color: Qt.alpha(Arc.abyss, Arc.light ? 0.40 : 0.62) }
				GradientStop { position: 1.0; color: Qt.alpha(Arc.abyss, Arc.light ? 0.80 : 0.96) }
			}
		}

		Item {
			id: chrono

			width: Arc.chronoRadius * 2
			height: Arc.chronoRadius * 2
			x: Math.round((bar.width - width) / 2)
			y: Math.round(bar.chronoCentreY - Arc.chronoRadius)

			readonly property real seconds: root.now.getSeconds()

			ArcHalo {
				anchors.centerIn: parent
				width: parent.width * 1.5
				height: parent.height * 1.5
				color: Arc.aether
				strength: 0.20
				spread: 0.30
				flicker: true
			}

			Canvas {
				id: limb
				anchors.fill: parent
				renderStrategy: Canvas.Cooperative

				readonly property int hour: root.now.getHours()

				onHourChanged: requestPaint()

				Connections {
					target: Arc
					function onGoldChanged() { limb.requestPaint(); }
				}

				onPaint: {
					const ctx = getContext("2d");
					ctx.reset();
					const cx = width / 2, cy = height / 2, r = Arc.chronoRadius;
					Ink.ring(ctx, cx, cy, r - 3, 1.4, Qt.alpha(Arc.gold, 0.34), 1);
					Ink.graduations(ctx, cx, cy, r - 5, 60, 4, 11, 5,
						Arc.ruleThin, Qt.alpha(Arc.gold, 0.30), 1);
					Ink.ring(ctx, cx, cy, r - 26, 1.0, Qt.alpha(Arc.gold, 0.22), 1);
					Ink.runeRing(ctx, cx, cy, r - 42, 12, 101 + limb.hour * 17, 17,
						Arc.ruleThin, Qt.alpha(Arc.gold, 0.30), Arc.aether, 0);
					Ink.ring(ctx, cx, cy, r - 62, 1.0, Qt.alpha(Arc.gold, 0.16), 1);
				}
			}

			Canvas {
				id: hands
				anchors.fill: parent
				renderStrategy: Canvas.Cooperative

				readonly property real seconds: chrono.seconds
				readonly property real minutes: root.now.getMinutes() + chrono.seconds / 60

				onSecondsChanged: requestPaint()

				onPaint: {
					const ctx = getContext("2d");
					ctx.reset();
					const cx = width / 2, cy = height / 2, r = Arc.chronoRadius;
					const s = hands.seconds / 60;
					Ink.ring(ctx, cx, cy, r - 3, 1.8, Qt.alpha(Arc.aether, 0.85), s);
					const tip = -Math.PI / 2 + Math.PI * 2 * s;
					Ink.mote(ctx, cx + Math.cos(tip) * (r - 3), cy + Math.sin(tip) * (r - 3), 3.4, Arc.aether);
					Ink.ring(ctx, cx, cy, r - 26, 2.4, Qt.alpha(Arc.aetherAlt, 0.7), hands.minutes / 60);
					Ink.runeRing(ctx, cx, cy, r - 42, 12, 101 + root.now.getHours() * 17, 17,
						Arc.ruleThin * 1.3, Qt.alpha(Arc.gold, 0),
						Arc.aether, Math.floor(hands.minutes / 60 * 12) + 1);
				}
			}

			Column {
				anchors.horizontalCenter: parent.horizontalCenter
				y: 20
				spacing: -2

				ArcText {
					anchors.horizontalCenter: parent.horizontalCenter
					role: "display"
					font.pixelSize: 38
					font.letterSpacing: 3
					text: Qt.formatDateTime(root.now, "HH:mm")
				}

				ArcText {
					anchors.horizontalCenter: parent.horizontalCenter
					role: "hand"
					tone: "aether"
					font.pixelSize: 16
					text: Arc.hourName(root.now)
				}

				ArcText {
					anchors.horizontalCenter: parent.horizontalCenter
					role: "label"
					tone: "muted"
					font.pixelSize: 9
					text: Qt.formatDateTime(root.now, "ddd dd MMM")
				}
			}

			ArcTouch {
				anchors.fill: undefined
				anchors.horizontalCenter: parent.horizontalCenter
				y: 20
				width: 230
				height: Arc.horizon - 20
				onClicked: root.clockClicked()
			}
		}

		ArcMotes {
			anchors.horizontalCenter: parent.horizontalCenter
			anchors.bottom: parent.bottom
			width: Arc.chronoRadius * 2.2
			height: Arc.horizon
			color: Arc.aether
			drifting: true
			density: 5
			drift: -6
			span: 2.6
		}

		Timer {
			running: true
			repeat: true
			interval: 1000
			onTriggered: root.now = new Date()
		}

		ArcSeat {
			id: launcherNode
			x: Arc.s6
			y: Math.round(Arc.horizon * 0.42)
			size: 38
			seed: 0
			label: "Codex"
			onClicked: root.launcherClicked()

			ArcMark {
				anchors.centerIn: parent
				width: parent.width * 0.68
				height: parent.height * 0.68
				glyph: "book"
				weight: Arc.rule
				lineColor: launcherNode.live > 0.25 ? Arc.aether : Arc.ink
			}
		}

		RealmMap {
			anchors.left: launcherNode.right
			anchors.leftMargin: Arc.s6
			anchors.bottom: parent.bottom
			width: Math.max(0, bar.width / 2 - Arc.chronoRadius * 0.86 - x - Arc.s5)
			height: Arc.horizon
			niriState: root.niriState
			outputName: String(root.screen?.name || "")
		}

		NowPlaying {
			id: media
			x: Math.round(bar.width / 2 + Arc.chronoRadius * 0.86)
			y: Math.round(Arc.horizon * 0.44)
			progressColor: Arc.aether
			onClicked: root.mediaClicked()
		}

		ArcSeat {
			id: networkNode
			anchors.left: media.right
			anchors.leftMargin: Arc.s6
			y: Math.round(Arc.horizon * 0.62)
			size: 24
			seed: 0
			label: "Ley"
			iconSource: root.networkStatusType === "ethernet"
				? Arc.icon("network-wired-symbolic")
				: Arc.icon("network-wireless-signal-excellent-symbolic")
			onClicked: root.networkClicked()
		}

		ArcSeat {
			id: powerNode
			x: bar.width - Arc.s6 - width
			y: Math.round(Arc.horizon * 0.42)
			size: 32
			seed: 2
			label: "The Void"
			liveColor: Arc.bane
			onClicked: root.powerClicked()

			ArcMark {
				anchors.centerIn: parent
				width: parent.width * 0.7
				height: parent.height * 0.7
				glyph: "gate"
				weight: Arc.rule
				lineColor: powerNode.live > 0.25 ? Arc.bane : Qt.alpha(Arc.bane, 0.8)
			}
		}
	}
}
