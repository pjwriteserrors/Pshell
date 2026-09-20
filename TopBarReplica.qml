pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Services.SystemTray
import Quickshell.Wayland
import "components"
import "components/ArcInk.js" as Ink

// The chain again, across the top of a screen that is not the primary one.
//
// Same instrument, fewer fittings: the horologe, the realms on this output and
// the way out are here, but the readings that belong to the machine as a whole
// — the oracle, the ravens — stay on the one chain that owns them. Every press
// is a signal; this window knows nothing about panels.
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
	property color background: Arc.vellum
	property color secondaryBoxColor: Arc.leaf1
	property color secondaryBoxStrongColor: Arc.leaf2
	property color secondaryInsetColor: Arc.well
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
		top: true
	}

	margins {
		left: 0
		right: 0
		top: 0
	}

	exclusiveZone: Math.round(Arc.gantryDepth)
	implicitHeight: Math.round(Arc.gantryDepth)
	color: "transparent"

	Item {
		id: bar
		anchors.fill: parent

		function chainAt(centreX) {
			return Arc.chainY(centreX / Math.max(1, bar.width));
		}

		function seatY(centreX, size) {
			return Math.round(bar.chainAt(centreX) - size / 2);
		}

		// The instrument's shade, as on the primary chain: without it the
		// engraving vanishes wherever the wallpaper is pale.
		Rectangle {
			anchors.fill: parent
			gradient: Gradient {
				GradientStop { position: 0.0; color: Qt.alpha(Arc.well, Arc.light ? 0.50 : 0.92) }
				GradientStop { position: 0.62; color: Qt.alpha(Arc.well, Arc.light ? 0.34 : 0.66) }
				GradientStop { position: 1.0; color: "transparent" }
			}
		}

		Canvas {
			id: chain
			anchors.fill: parent
			renderStrategy: Canvas.Cooperative

			Connections {
				target: Arc
				function onGiltChanged() { chain.requestPaint(); }
			}

			onPaint: {
				const ctx = getContext("2d");
				ctx.reset();
				if (width <= 8) return;
				const shadow = Qt.alpha(Qt.darker(Arc.gilt, 2.4), 0.6);
				const highlight = Qt.alpha(Qt.lighter(Arc.gilt, 1.8), 0.5);
				const gap = Arc.horologe * 0.44;

				Ink.groove(ctx, [
					{ x: 0, y: Arc.gantryRise },
					{ x: width / 2 - gap, y: Arc.chainY(0.5 - gap / width) }
				], Arc.rule * 2.0, Arc.gilt, highlight, shadow, false);
				Ink.groove(ctx, [
					{ x: width / 2 + gap, y: Arc.chainY(0.5 + gap / width) },
					{ x: width, y: Arc.gantryRise }
				], Arc.rule * 2.0, Arc.gilt, highlight, shadow, false);

				const spacing = 26;
				const marks = Math.floor(width / spacing);
				for (let index = 0; index <= marks; index++) {
					const x = index * spacing;
					const y = Arc.chainY(x / width);
					const long = index % 5 === 0;
					Ink.cut(ctx, [{ x: x, y: y + 2 }, { x: x, y: y + (long ? 8 : 4) }],
						Arc.ruleThin, Qt.alpha(Arc.gilt, long ? 0.55 : 0.3), false);
				}

				for (const side of [0, width]) {
					const dir = side === 0 ? 1 : -1;
					Ink.groove(ctx, [
						{ x: side, y: Arc.gantryRise + 16 },
						{ x: side, y: Arc.gantryRise },
						{ x: side + dir * 20, y: Arc.gantryRise }
					], Arc.rule * 1.4, Arc.gilt, highlight, shadow, false);
					Ink.rivet(ctx, side + dir * 7, Arc.gantryRise, 2.4, Arc.gilt, highlight, shadow);
				}
			}
		}

		Row {
			id: leftLimb
			anchors.left: parent.left
			anchors.leftMargin: 22
			anchors.top: parent.top
			height: parent.height
			spacing: Arc.s3

			ArcSeat {
				id: launcherNode
				size: 34
				seed: 0
				y: bar.seatY(leftLimb.x + x + width / 2, height)
				onClicked: root.launcherClicked()

				ArcMark {
					anchors.centerIn: parent
					width: parent.width * 0.60
					height: parent.height * 0.60
					glyph: "book"
					weight: Arc.rule
					lineColor: Arc.ink
				}
			}

			NiriTaskbar {
				id: taskbarIsland
				visible: root.niriState.tasksForOutput(String(root.screen?.name || "")).length > 0
				height: root.height
				niriState: root.niriState
				outputName: String(root.screen?.name || "")
				originX: leftLimb.x + x
				chainAt: bar.chainAt
				background: Arc.leaf1
				foreground: Arc.ink
				secondaryBoxColor: Arc.leaf2
				secondaryBoxStrongColor: Arc.leaf3
			}
		}

		Item {
			id: horologe

			width: Arc.horologe
			height: Arc.horologe
			x: Math.round((bar.width - width) / 2)
			y: bar.seatY(bar.width / 2, height)

			readonly property real seconds: root.now.getSeconds()

			ArcHalo {
				anchors.centerIn: parent
				width: parent.width * 2.3
				height: parent.height * 2.3
				color: Arc.aether
				strength: 0.26
				spread: 0.34
				flicker: true
			}

			Canvas {
				id: face
				anchors.fill: parent
				renderStrategy: Canvas.Cooperative

				Connections {
					target: Arc
					function onGiltChanged() { face.requestPaint(); }
					function onLeaf1Changed() { face.requestPaint(); }
				}

				onPaint: {
					const ctx = getContext("2d");
					ctx.reset();
					const cx = width / 2, cy = height / 2;
					const r = Math.min(width, height) / 2 - 1;
					const cast = ctx.createLinearGradient(0, 0, 0, height);
					cast.addColorStop(0, Arc.leaf2);
					cast.addColorStop(1, Arc.well);
					ctx.fillStyle = cast;
					ctx.beginPath();
					ctx.arc(cx, cy, r, 0, Math.PI * 2);
					ctx.fill();
					Ink.guilloche(ctx, cx, cy, r * 0.74, 22, r * 0.045, 3,
						Arc.ruleThin * 0.7, Qt.alpha(Arc.gilt, 0.14));
				}
			}

			ArcDial {
				anchors.fill: parent
				seed: 0
				weight: Arc.rule
				lineColor: Arc.giltDim
				liveColor: Arc.aether
				intensity: horologeTouch.live
				progress: horologe.seconds / 60
			}

			ArcDial {
				anchors.centerIn: parent
				width: parent.width - 13
				height: parent.height - 13
				seed: 1
				weight: Arc.ruleThin
				beading: false
				lineColor: Arc.giltGhost
				liveColor: Arc.aetherAlt
				progress: (root.now.getMinutes() + horologe.seconds / 60) / 60
			}

			Column {
				anchors.centerIn: parent
				spacing: -3

				ArcText {
					anchors.horizontalCenter: parent.horizontalCenter
					role: "reading"
					font.pixelSize: 20
					font.letterSpacing: 0.5
					text: Qt.formatDateTime(root.now, "HH:mm")
				}

				Rectangle {
					anchors.horizontalCenter: parent.horizontalCenter
					width: 22
					height: Arc.ruleThin
					color: Arc.giltFaint
				}
			}

			ArcTouch {
				id: horologeTouch
				onClicked: root.clockClicked()
			}
		}

		Column {
			id: dayBlock
			anchors.right: horologe.left
			anchors.rightMargin: Arc.s4
			y: Math.round(bar.chainAt(dayBlock.x + dayBlock.width / 2) - dayBlock.height / 2)
			spacing: -1

			ArcText {
				anchors.right: parent.right
				role: "label"
				tone: "muted"
				text: Qt.formatDateTime(root.now, "ddd dd MMM")
			}

			ArcText {
				anchors.right: parent.right
				role: "hand"
				tone: "faint"
				font.pixelSize: 13
				text: Arc.hourName(root.now)
			}
		}

		Timer {
			running: true
			repeat: true
			interval: 1000
			onTriggered: root.now = new Date()
		}

		Row {
			id: rightLimb
			anchors.right: parent.right
			anchors.rightMargin: 22
			anchors.top: parent.top
			height: parent.height
			layoutDirection: Qt.RightToLeft
			spacing: Arc.s3

			ArcSeat {
				id: powerNode
				seed: 2
				y: bar.seatY(rightLimb.x + x + width / 2, height)
				ringColor: Qt.alpha(Arc.bane, 0.5)
				liveColor: Arc.bane
				iconColor: Qt.alpha(Arc.bane, 0.85)
				iconSource: Arc.icon("system-shutdown-symbolic")
				onClicked: root.powerClicked()
			}

			Item {
				id: trayRun
				width: trayRow.width
				height: root.height
				visible: trayRepeater.count > 0

				Row {
					id: trayRow
					spacing: Arc.s2

					Repeater {
						id: trayRepeater
						model: ScriptModel {
							values: SystemTray.items.values
						}

						ArcSeat {
							id: trayNode

							required property SystemTrayItem modelData
							required property int index

							size: 26
							seed: trayNode.index + 1
							y: bar.seatY(rightLimb.x + trayRun.x + trayNode.x + width / 2, height)
							acceptedButtons: Qt.LeftButton | Qt.RightButton

							Image {
								anchors.centerIn: parent
								width: 14
								height: 14
								source: root.trayIconSource(trayNode.modelData?.icon ?? "")
								fillMode: Image.PreserveAspectFit
								smooth: true
								mipmap: true
							}

							onClicked: event => {
								if (event.button === Qt.RightButton) trayNode.modelData.secondaryActivate();
								else trayNode.modelData.activate();
							}
						}
					}
				}
			}

			TopBarResourceBars {
				y: bar.seatY(rightLimb.x + x + width / 2, height)
				onClicked: root.resourcesClicked()
			}

			ArcSeat {
				seed: 0
				y: bar.seatY(rightLimb.x + x + width / 2, height)
				iconSource: root.networkStatusType === "ethernet"
					? Arc.icon("network-wired-symbolic")
					: Arc.icon("network-wireless-signal-excellent-symbolic")
				onClicked: root.networkClicked()
			}

			ArcSeat {
				seed: 3
				y: bar.seatY(rightLimb.x + x + width / 2, height)
				iconSource: Arc.icon("bluetooth-active-symbolic")
				onClicked: root.bluetoothClicked()
			}

			ArcSeat {
				seed: 2
				y: bar.seatY(rightLimb.x + x + width / 2, height)
				iconSource: Arc.icon("edit-paste-symbolic")
				onClicked: root.clipboardClicked()
			}

			NowPlaying {
				originX: rightLimb.x + x
				chainAt: bar.chainAt
				foreground: Arc.ink
				secondaryBoxColor: Arc.leaf1
				progressColor: Arc.aether
				onClicked: root.mediaClicked()
			}
		}
	}
}
