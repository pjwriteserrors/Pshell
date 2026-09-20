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

			// The chronomancer, as on the primary horizon.
			//
			// The great circle, nearly all of it under the edge of the screen.
			// Every ring on it runs only across the part of itself that is
			// above the horizon, so they all finish on the same line and the
			// whole thing reads as something rising. The runes crown the
			// outside and are cut from the name this hour goes by; the seconds
			// travel the limb under them, the minutes the one under that, and
			// the hour stands in the space they leave.
			Item {
				id: chrono

				readonly property real reach: Arc.chronoRadius + 14

				width: chrono.reach * 2
				height: chrono.reach * 2
				x: Math.round((bar.width - width) / 2)
				y: Math.round(bar.chronoCentreY - chrono.reach)

				readonly property real seconds: root.now.getSeconds() + root.now.getMilliseconds() / 1000
				readonly property int hour: root.now.getHours()

				ArcHalo {
					anchors.horizontalCenter: parent.horizontalCenter
					y: chrono.reach - Arc.chronoRadius - 20
					width: 300
					height: 170
					color: Arc.aether
					strength: 0.18
					spread: 0.34
					flicker: true
				}

				// The fixed part: the crown of runes and the graduated limb.
				// Repainted once an hour, not once a second.
				Canvas {
					id: limb
					anchors.fill: parent
					renderStrategy: Canvas.Cooperative

					readonly property int hour: chrono.hour

					onHourChanged: requestPaint()

					Connections {
						target: Arc
						function onGoldChanged() { limb.requestPaint(); }
					}

					onPaint: {
						const ctx = getContext("2d");
						ctx.reset();
						const cx = width / 2, cy = height / 2, r = Arc.chronoRadius;

						Ink.runeArc(ctx, cx, cy, r + 6,
							Arc.chronoFromAt(r + 6), Arc.chronoToAt(r + 6),
							9, 101 + limb.hour * 17, 12, Arc.ruleThin,
							Qt.alpha(Arc.gold, 0.32), Arc.aether, 0);
						Ink.gradsArc(ctx, cx, cy, r + 1,
							Arc.chronoFromAt(r + 1), Arc.chronoToAt(r + 1),
							30, 3, 7, 5, Arc.ruleThin, Qt.alpha(Arc.gold, 0.30));
						Ink.arcRun(ctx, cx, cy, r - 1,
							Arc.chronoFromAt(r - 1), Arc.chronoToAt(r - 1),
							1.2, Qt.alpha(Arc.gold, 0.30), 1);
						Ink.arcRun(ctx, cx, cy, r - 10,
							Arc.chronoFromAt(r - 10), Arc.chronoToAt(r - 10),
							1.0, Qt.alpha(Arc.gold, 0.16), 1);
					}
				}

				// The readings, each travelling its own limb west to east.
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

						const secondsR = r - 1;
						const sFrom = Arc.chronoFromAt(secondsR), sTo = Arc.chronoToAt(secondsR);
						Ink.arcRun(ctx, cx, cy, secondsR, sFrom, sTo, 1.8, Qt.alpha(Arc.aether, 0.85), s);
						const tip = sFrom + (sTo - sFrom) * s;
						Ink.mote(ctx, cx + Math.cos(tip) * secondsR, cy + Math.sin(tip) * secondsR, 3.0, Arc.aether);

						const minutesR = r - 10;
						Ink.arcRun(ctx, cx, cy, minutesR,
							Arc.chronoFromAt(minutesR), Arc.chronoToAt(minutesR),
							2.0, Qt.alpha(Arc.aetherAlt, 0.7), hands.minutes / 60);

						Ink.runeArc(ctx, cx, cy, r + 6,
							Arc.chronoFromAt(r + 6), Arc.chronoToAt(r + 6),
							9, 101 + root.now.getHours() * 17, 12, Arc.ruleThin * 1.3,
							Qt.alpha(Arc.gold, 0), Arc.aether,
							Math.floor(hands.minutes / 60 * 9) + 1);

					}
				}

				// The hour, on one line in the space the limbs leave. The date
				// is not out here: the ephemeris has it, and out here it would
				// only be costing height.
				Row {
					id: reading
					anchors.horizontalCenter: parent.horizontalCenter
					y: Math.round(chrono.reach - Arc.chronoRadius + Arc.chronoSunk - 24)
					spacing: Arc.s2

					Canvas {
						id: moon
						anchors.verticalCenter: parent.verticalCenter
						width: 13
						height: 13
						renderStrategy: Canvas.Cooperative

						readonly property real phase: Arc.moonPhase(root.now).fraction

						onPhaseChanged: requestPaint()

						onPaint: {
							const ctx = getContext("2d");
							ctx.reset();
							const r = width / 2 - 1;
							ctx.strokeStyle = Arc.goldDim;
							ctx.lineWidth = Arc.ruleThin;
							ctx.beginPath();
							ctx.arc(width / 2, height / 2, r, 0, Math.PI * 2);
							ctx.stroke();
							const waxing = moon.phase < 0.5;
							const sweep = Math.cos(moon.phase * Math.PI * 2);
							ctx.fillStyle = Arc.gold;
							ctx.beginPath();
							ctx.arc(width / 2, height / 2, r,
								waxing ? -Math.PI / 2 : Math.PI / 2,
								waxing ? Math.PI / 2 : Math.PI * 1.5);
							ctx.closePath();
							ctx.fill();
							ctx.globalCompositeOperation = sweep > 0 ? "destination-out" : "source-over";
							ctx.beginPath();
							ctx.ellipse(width / 2 - Math.abs(sweep) * r, height / 2 - r,
								Math.abs(sweep) * r * 2, r * 2);
							ctx.fill();
							ctx.globalCompositeOperation = "source-over";
						}
					}

					ArcText {
						anchors.verticalCenter: parent.verticalCenter
						role: "display"
						font.pixelSize: 25
						font.letterSpacing: 1.5
						text: Qt.formatDateTime(root.now, "HH:mm")
					}

					ArcText {
						anchors.verticalCenter: parent.verticalCenter
						role: "hand"
						tone: "aether"
						font.pixelSize: 14
						text: Arc.hourName(root.now)
					}
				}

				ArcTouch {
					id: chronoTouch
					anchors.fill: undefined
					anchors.horizontalCenter: parent.horizontalCenter
					y: chrono.reach - Arc.chronoRadius
					width: 280
					height: Arc.horizon - (chrono.reach - Arc.chronoRadius)
					onClicked: root.clockClicked()
				}
			}

		ArcMotes {
			anchors.horizontalCenter: parent.horizontalCenter
			anchors.bottom: parent.bottom
			width: Arc.chronoRadius * 2.0
			height: Arc.horizon
			color: Arc.aether
			drifting: true
			density: 4
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
			x: Arc.s5
			y: Math.round(Arc.horizon * 0.40)
			size: 30
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
			anchors.leftMargin: Arc.s4
			anchors.bottom: parent.bottom
			width: Math.max(0, bar.width / 2 - Arc.chronoRadius * 1.02 - x - Arc.s4)
			height: Arc.horizon
			niriState: root.niriState
			outputName: String(root.screen?.name || "")
		}

		NowPlaying {
			id: media
			x: Math.round(bar.width / 2 + Arc.chronoRadius * 1.02)
			y: Math.round(Arc.horizon * 0.36)
			progressColor: Arc.aether
			onClicked: root.mediaClicked()
		}

		ArcSeat {
			id: networkNode
			anchors.left: media.right
			anchors.leftMargin: Arc.s6
			y: Math.round(Arc.horizon * 0.58)
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
			x: bar.width - Arc.s5 - width
			y: Math.round(Arc.horizon * 0.40)
			size: 28
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
