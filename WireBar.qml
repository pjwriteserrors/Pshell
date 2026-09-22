pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Services.SystemTray
import "components"

// The bar is the thread.
//
// One lit filament runs across the top of every screen. Everything on the
// bar is a bead strung on it: the launcher at the left end, the workspace
// knots, the window beads, the media bead, the clock in the middle as the
// largest bead with the resting spark, then the tray, weather, bell,
// clipboard, radios, resources, and the power bead where the thread ends.
//
// Light travels along it. A spark sent with sendSpark() runs from one bead
// to another and blooms where it lands; a notification arrives as a spark
// from the right edge; a change of volume thickens the stretch beside the
// clock into a meter for a moment. Hovering the bar warms the thread near
// the cursor. None of this costs: the thread is two rectangles, the glow is
// one gradient, a spark is three circles moved by a transform.
PanelWindow {
	id: bar

	required property var screenModel
	required property var niriState
	required property var media
	required property var resources
	required property int notificationCount
	required property string networkStatusType
	required property string weatherIcon
	required property string weatherTemperature
	required property bool weatherReady
	required property string activeLantern
	required property string activeModal
	required property bool primary
	required property bool doNotDisturb

	signal activate(string name, var mouse)
	signal trayActivate(var item, var mouse, real x)

	readonly property string outputName: String(screenModel?.name || "")
	readonly property var tasks: niriState.tasksForOutput(outputName)
	readonly property var workspaces: niriState.workspacesForOutput(outputName)
	readonly property var focusedTask: tasks.find(task => task.isFocused) || null

	screen: screenModel
	anchors { left: true; right: true; top: true }
	exclusiveZone: Filament.barHeight
	implicitHeight: Filament.barHeight
	color: "transparent"
	WlrLayershell.layer: WlrLayer.Top

	// Screen x of a bead's centre, for hanging lanterns from it.
	function beadX(name) {
		const item = beadByName(name);
		if (!item) return -1;
		return item.mapToItem(null, item.width / 2, 0).x;
	}

	function beadByName(name) {
		switch (name) {
		case "launcher": return launcherBead;
		case "media": return mediaBead;
		case "clock": return clockBead;
		case "tray": return trayRow;
		case "weather": return weatherBead;
		case "notifications": return bellBead;
		case "clipboard": return clipboardBead;
		case "bluetooth": return bluetoothBead;
		case "network": return networkBead;
		case "resources": return resourcesBead;
		case "power": return powerBead;
		default: return null;
		}
	}

	function flash(name) {
		const item = beadByName(name);
		if (item && item.flash) item.flash();
	}

	// A drop of light runs along the thread from x to x and blooms on arrival.
	function sendSpark(fromX, toX, onArrive) {
		const spark = sparkComponent.createObject(sparkLayer, {
			x: fromX - 4,
			targetX: toX - 4,
			onArrive: onArrive || null
		});
		if (spark) spark.go();
	}

	// Light the clock's hour digits for a moment (what a media spark does).
	function lightClock() {
		clockBead.flash();
		clockLitTimer.restart();
		clockBead.hourLit = true;
	}

	// The whole thread lights up once, end to end (a palette change).
	function sweep() {
		wire.pulse();
	}

	// The thread beside the clock becomes a meter.
	function showMeter(kind, iconName, progress, label) {
		meter.kind = kind;
		meter.iconName = iconName;
		meter.level = Math.max(0, Math.min(1, progress));
		meter.label = label;
		meter.shown = true;
		meterHideTimer.restart();
	}

	Timer {
		id: meterHideTimer
		interval: 1300
		onTriggered: meter.shown = false
	}

	Timer {
		id: clockLitTimer
		interval: 1100
		onTriggered: clockBead.hourLit = false
	}

	Component {
		id: sparkComponent
		Spark {
			id: travelling
			property real targetX: 0
			property var onArrive: null
			y: Filament.wireY - 3
			size: 6
			function go() {
				run.duration = Filament.travelTime(targetX - x);
				run.to = targetX;
				run.start();
			}
			NumberAnimation on x {
				id: run
				running: false
				easing.type: Easing.BezierSpline
				easing.bezierCurve: Filament.easeTravel
				onFinished: {
					if (travelling.onArrive) travelling.onArrive();
					travelling.destroy();
				}
			}
		}
	}

	// ----------------------------------------------------------- the plane
	Rectangle {
		anchors.fill: parent
		color: Qt.alpha(Filament.planeSolid, 0.9)
	}

	HoverHandler {
		id: barHover
	}

	// ---------------------------------------------------------- the thread
	Wire {
		id: wire
		x: 0
		y: Filament.wireY - 1
		width: parent.width
		height: 2
		cold: Filament.wire
		hot: Filament.charge
		pulseWidth: 220
	}

	// Warmth near the cursor: a soft gradient that follows the hand.
	Rectangle {
		id: warmth
		property real targetX: barHover.point.position.x
		width: 240
		height: 10
		y: Filament.wireY - 5
		x: shownX - width / 2
		property real shownX: targetX
		Behavior on shownX { SpringAnimation { spring: 3; damping: 0.4; epsilon: 0.5 } }
		opacity: barHover.hovered ? 1 : 0
		Behavior on opacity { NumberAnimation { duration: Filament.settle } }
		gradient: Gradient {
			orientation: Gradient.Horizontal
			GradientStop { position: 0; color: "transparent" }
			GradientStop { position: 0.5; color: Qt.alpha(Filament.charge, 0.45) }
			GradientStop { position: 1; color: "transparent" }
		}
	}

	// ------------------------------------------------------------ the meter
	// Volume, microphone, brightness. The stretch to the right of the clock
	// thickens into a meter, its level lit, a value pill on the spark.
	Item {
		id: meter
		property bool shown: false
		property string kind: ""
		property string iconName: ""
		property real level: 0
		property string label: ""
		readonly property real fullWidth: 200

		x: clockBead.x + clockBead.width + 18
		y: 0
		height: Filament.barHeight
		width: Math.round(fullWidth * grow)
		clip: true
		opacity: Math.min(1, grow * 1.5)
		property real grow: shown ? 1 : 0
		Behavior on grow {
			NumberAnimation {
				duration: meter.shown ? Filament.unfold : Filament.fold
				easing.type: Easing.BezierSpline
				easing.bezierCurve: meter.shown ? Filament.easeUnfold : Filament.easeFold
			}
		}
		z: 5

		Rectangle {
			anchors.fill: parent
			anchors.topMargin: 4
			anchors.bottomMargin: 4
			radius: height / 2
			color: Filament.planeSolid
			border.width: 1
			border.color: Filament.wireDim
		}

		FIcon {
			id: meterIcon
			x: 10
			anchors.verticalCenter: parent.verticalCenter
			name: meter.iconName
			size: 14
			color: meter.level > 0.001 || meter.kind === "brightness" ? Filament.charge : Filament.inkMute
		}

		Wire {
			id: meterWire
			x: 32
			anchors.verticalCenter: parent.verticalCenter
			width: meter.fullWidth - 32 - 46
			height: 4
			thickness: 4
			cold: Filament.wireDim
			hot: Filament.charge
			lit: meter.level
		}

		Rectangle {
			x: meterWire.x + Math.round(meterWire.width * meterWire.litShown) - 4
			anchors.verticalCenter: parent.verticalCenter
			width: 8; height: 8; radius: 4
			color: Filament.charge
			visible: meter.level > 0.001
		}

		FText {
			anchors.right: parent.right
			anchors.rightMargin: 10
			anchors.verticalCenter: parent.verticalCenter
			text: meter.label
			mono: true
			font.pixelSize: Filament.textSm
			color: Filament.ink
		}
	}

	// ------------------------------------------------------------ the beads
	Row {
		id: leftRow
		x: 10
		anchors.verticalCenter: parent.verticalCenter
		spacing: 10

		Bead {
			id: launcherBead
			active: bar.activeModal === "launcher"
			padding: 8
			onClicked: mouse => bar.activate("launcher", mouse)
			Item {
				width: 18; height: 18
				Spark {
					anchors.centerIn: parent
					size: 7
					breathing: !launcherBead.hovered
					color: Filament.charge
				}
				Repeater {
					model: 4
					Rectangle {
						required property int index
						x: 4 + (index % 2) * 8
						y: 4 + Math.floor(index / 2) * 8
						width: 2; height: 2; radius: 1
						color: launcherBead.hovered ? Filament.ink : Filament.inkMute
						opacity: launcherBead.hovered ? 1 : 0.7
					}
				}
			}
		}

		// Workspace knots, one per workspace on this output.
		Row {
			id: knots
			anchors.verticalCenter: parent.verticalCenter
			spacing: 6
			visible: bar.workspaces.length > 0

			Repeater {
				model: bar.workspaces
				Item {
					id: knot
					required property var modelData
					required property int index
					readonly property bool on: modelData.isActive
					readonly property bool hot: knotTouch.containsMouse
					width: on ? 18 : 14
					height: 24
					anchors.verticalCenter: parent.verticalCenter
					Behavior on width { SpringAnimation { spring: 4; damping: 0.3; epsilon: 0.05 } }

					MouseArea {
						id: knotTouch
						anchors.fill: parent
						anchors.margins: -3
						hoverEnabled: true
						cursorShape: Qt.PointingHandCursor
						onClicked: bar.niriState.focusWorkspace(bar.outputName, knot.modelData.idx)
					}

					Rectangle {
						anchors.centerIn: parent
						width: knot.on ? 30 : 20
						height: width
						radius: width / 2
						color: Qt.alpha(Filament.charge, 0.2)
						opacity: knot.on || knot.hot ? 1 : 0
						Behavior on opacity { NumberAnimation { duration: Filament.quick } }
					}

					Rectangle {
						anchors.centerIn: parent
						width: knot.on ? 16 : (knot.hot ? 10 : (knot.modelData.windowCount > 0 ? 8 : 6))
						height: width
						radius: width / 2
						color: knot.modelData.isUrgent ? Filament.alert
							: (knot.on ? Filament.charge : (knot.hot ? Filament.wireBright : Filament.wire))
						border.width: knot.on ? 0 : 1
						border.color: Filament.planeSolid
						Behavior on width { SpringAnimation { spring: 4; damping: 0.3; epsilon: 0.05 } }
						Behavior on color { ColorAnimation { duration: Filament.quick } }

						FText {
							anchors.centerIn: parent
							text: String(knot.modelData.idx)
							mono: true
							font.pixelSize: 9
							font.weight: Font.Bold
							color: Filament.onCharge
							visible: knot.on
						}
					}
				}
			}
		}

		// Window beads for this output.
		Row {
			id: taskRow
			anchors.verticalCenter: parent.verticalCenter
			spacing: 4
			visible: bar.tasks.length > 0

			Repeater {
				model: ScriptModel {
					objectProp: "id"
					values: bar.tasks
				}
				Bead {
					id: taskBead
					required property var modelData
					padding: 6
					lit: modelData?.isFocused ?? false
					alarm: modelData?.isUrgent ?? false
					acceptedButtons: Qt.LeftButton | Qt.MiddleButton
					onClicked: mouse => {
						if (mouse.button === Qt.MiddleButton) bar.niriState.closeWindow(taskBead.modelData.id);
						else bar.niriState.focusWindow(taskBead.modelData.id);
					}
					Image {
						width: 16; height: 16
						source: bar.taskIcon(taskBead.modelData?.appId ?? "")
						sourceSize: Qt.size(16, 16)
						asynchronous: true
						cache: true
						mipmap: true
						opacity: taskBead.lit || taskBead.hovered ? 1 : 0.72
					}
				}
			}
		}

		// The focused window's title, on its own plane so the thread passes
		// behind the words rather than through them.
		Bead {
			visible: (bar.focusedTask?.title ?? "") !== ""
			interactive: false
			outlined: false
			padding: 6
			FText {
				text: bar.focusedTask?.title ?? ""
				tone: "soft"
				font.pixelSize: Filament.textSm
				width: Math.min(implicitWidth, 260)
			}
		}

		// Media bead: an equaliser while playing, the track name, the
		// progress lit along a filament under the words.
		Bead {
			id: mediaBead
			active: bar.activeLantern === "media"
			lit: bar.media.playing
			padding: bar.media.hasMedia ? 9 : 7
			onClicked: mouse => bar.activate("media", mouse)
			Row {
				spacing: 8
				FIcon {
					visible: !bar.media.hasMedia
					anchors.verticalCenter: parent.verticalCenter
					name: "audio-x-generic-symbolic"
					size: 14
					color: Filament.inkMute
				}
				Row {
					visible: bar.media.hasMedia
					anchors.verticalCenter: parent.verticalCenter
					spacing: 2
					Repeater {
						model: 3
						Rectangle {
							id: eqBar
							required property int index
							anchors.verticalCenter: parent.verticalCenter
							width: 2
							radius: 1
							color: Filament.charge
							height: 4
							SequentialAnimation on height {
								running: bar.media.playing
								loops: Animation.Infinite
								NumberAnimation { to: 12 - eqBar.index * 2; duration: 260 + eqBar.index * 90; easing.type: Easing.InOutSine }
								NumberAnimation { to: 4 + eqBar.index; duration: 300 + eqBar.index * 70; easing.type: Easing.InOutSine }
							}
						}
					}
				}
				Item {
					visible: bar.media.hasMedia
					width: mediaLabel.width
					height: 18
					anchors.verticalCenter: parent.verticalCenter
					FText {
						id: mediaLabel
						y: 0
						text: bar.media.mediaText
						width: Math.min(implicitWidth, 220)
						font.pixelSize: Filament.textSm
						height: 14
					}
					Wire {
						y: 15
						width: mediaLabel.width
						height: 2
						cold: Filament.wireDim
						lit: bar.media.progressValue
					}
				}
			}
		}
	}

	// The clock: the largest bead, with the resting spark.
	Bead {
		id: clockBead
		property bool hourLit: false
		anchors.centerIn: parent
		beadHeight: 28
		padding: 12
		active: bar.activeLantern === "calendar"
		onClicked: mouse => bar.activate("calendar", mouse)
		Row {
			spacing: 9
			Spark {
				anchors.verticalCenter: parent.verticalCenter
				size: 6
				breathing: true
				intensity: clockBead.hourLit ? 1.6 : 1
			}
			Row {
				anchors.verticalCenter: parent.verticalCenter
				spacing: 0
				FText {
					text: Qt.formatDateTime(bar.now, "HH")
					mono: true
					font.pixelSize: 15
					font.weight: Font.DemiBold
					color: clockBead.hourLit ? Filament.charge : Filament.ink
					Behavior on color { ColorAnimation { duration: 260 } }
				}
				FText {
					text: ":"
					mono: true
					font.pixelSize: 15
					font.weight: Font.DemiBold
					opacity: bar.now.getSeconds() % 2 === 0 ? 1 : 0.35
					Behavior on opacity { NumberAnimation { duration: 400 } }
				}
				FText {
					text: Qt.formatDateTime(bar.now, "mm")
					mono: true
					font.pixelSize: 15
					font.weight: Font.DemiBold
				}
			}
		}
	}

	property var now: new Date()
	Timer {
		interval: 1000
		running: true
		repeat: true
		triggeredOnStart: true
		onTriggered: bar.now = new Date()
	}

	Row {
		id: rightRow
		anchors.right: parent.right
		anchors.rightMargin: 10
		anchors.verticalCenter: parent.verticalCenter
		spacing: 8

		Row {
			id: trayRow
			anchors.verticalCenter: parent.verticalCenter
			spacing: 4
			visible: trayRepeater.count > 0
			Repeater {
				id: trayRepeater
				model: ScriptModel { values: SystemTray.items.values }
				Bead {
					id: trayBead
					required property var modelData
					padding: 5
					acceptedButtons: Qt.LeftButton | Qt.RightButton
					onClicked: mouse => bar.trayActivate(trayBead.modelData, mouse, trayBead.mapToItem(null, trayBead.width / 2, 0).x)
					Image {
						width: 16; height: 16
						source: FIconTable.tray(trayBead.modelData?.icon ?? "")
						sourceSize: Qt.size(16, 16)
						asynchronous: true
					}
				}
			}
		}

		Bead {
			id: weatherBead
			active: bar.activeLantern === "weather"
			padding: 8
			onClicked: mouse => bar.activate("weather", mouse)
			Row {
				spacing: 6
				FIcon {
					anchors.verticalCenter: parent.verticalCenter
					name: bar.weatherIcon
					fallbacks: ["weather-overcast-symbolic"]
					size: 14
					color: bar.weatherReady ? Filament.charge2 : Filament.inkMute
				}
				FText {
					anchors.verticalCenter: parent.verticalCenter
					text: bar.weatherTemperature
					mono: true
					font.pixelSize: Filament.textSm
				}
			}
		}

		Bead {
			id: bellBead
			active: bar.activeLantern === "notifications"
			lit: bar.notificationCount > 0 && !bar.doNotDisturb
			padding: 7
			onClicked: mouse => bar.activate("notifications", mouse)
			Row {
				spacing: 5
				FIcon {
					anchors.verticalCenter: parent.verticalCenter
					name: bar.doNotDisturb ? "notifications-disabled-symbolic" : "preferences-system-notifications-symbolic"
					fallbacks: ["dialog-information-symbolic"]
					size: 14
					color: bar.doNotDisturb ? Filament.inkMute : Filament.ink
				}
				Chip {
					anchors.verticalCenter: parent.verticalCenter
					visible: bar.notificationCount > 0
					text: String(bar.notificationCount)
					lit: true
					implicitHeight: 16
					scale: visible ? 1 : 0
					Behavior on scale { SpringAnimation { spring: 4; damping: 0.28 } }
				}
			}
		}

		Bead {
			id: clipboardBead
			active: bar.activeLantern === "clipboard"
			padding: 7
			onClicked: mouse => bar.activate("clipboard", mouse)
			FIcon { name: "edit-paste-symbolic"; size: 14 }
		}

		Bead {
			id: bluetoothBead
			active: bar.activeLantern === "bluetooth"
			padding: 7
			onClicked: mouse => bar.activate("bluetooth", mouse)
			FIcon { name: "bluetooth-active-symbolic"; size: 14 }
		}

		Bead {
			id: networkBead
			active: bar.activeLantern === "network"
			lit: bar.networkStatusType !== "offline"
			padding: 7
			onClicked: mouse => bar.activate("network", mouse)
			FIcon {
				name: bar.networkStatusType === "ethernet" ? "network-wired-symbolic"
					: bar.networkStatusType === "wifi" ? "network-wireless-signal-excellent-symbolic"
					: "network-wireless-offline-symbolic"
				fallbacks: ["network-wireless-signal-excellent-symbolic"]
				size: 14
				color: bar.networkStatusType === "offline" ? Filament.inkMute : Filament.ink
			}
		}

		// Resources: three short vertical filaments, lit by use.
		Bead {
			id: resourcesBead
			active: bar.activeLantern === "resources"
			padding: 8
			onClicked: mouse => bar.activate("resources", mouse)
			Row {
				spacing: 7
				Repeater {
					model: [
						{ key: "cpu", value: bar.resources.cpuUsage },
						{ key: "mem", value: bar.resources.memoryUsage },
						{ key: "disk", value: bar.resources.storageUsage }
					]
					Item {
						id: gauge
						required property var modelData
						width: 3; height: 14
						anchors.verticalCenter: parent.verticalCenter
						Wire {
							anchors.fill: parent
							vertical: true
							thickness: 3
							cold: Filament.wireDim
							hot: gauge.modelData.value > 0.85 ? Filament.alert : Filament.charge
							litFrom: 1 - Math.max(0.05, Math.min(1, gauge.modelData.value))
							lit: Math.max(0.05, Math.min(1, gauge.modelData.value))
							glow: false
						}
					}
				}
				Row {
					visible: bar.resources.mouseBatteryAvailable
					anchors.verticalCenter: parent.verticalCenter
					spacing: 4
					FIcon { anchors.verticalCenter: parent.verticalCenter; name: "input-mouse-symbolic"; size: 12; color: Filament.inkSoft }
					FText { anchors.verticalCenter: parent.verticalCenter; text: bar.resources.mouseBatteryText; mono: true; font.pixelSize: Filament.textXs; tone: "soft" }
				}
			}
		}

		// Where the thread ends.
		Bead {
			id: powerBead
			active: bar.activeModal === "power"
			litColor: Filament.alert
			padding: 7
			onClicked: mouse => bar.activate("power", mouse)
			FIcon { name: "system-shutdown-symbolic"; size: 14; color: Filament.alert }
		}
	}

	Item {
		id: sparkLayer
		anchors.fill: parent
		z: 10
	}

	function taskIcon(appId) {
		const id = String(appId || "");
		if (id === "") return Quickshell.iconPath("application-x-executable", true);
		let path = Quickshell.iconPath(id, true);
		if (path === "") {
			const entry = DesktopEntries.heuristicLookup(id);
			if (entry && entry.icon) path = Quickshell.iconPath(entry.icon, true);
		}
		if (path === "" && !id.endsWith(".desktop")) path = Quickshell.iconPath(`${id}.desktop`, true);
		if (path === "") path = Quickshell.iconPath(id.toLowerCase(), true);
		if (path === "") path = Quickshell.iconPath("application-x-executable", true);
		return path;
	}
}
