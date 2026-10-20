pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import QtQuick.Layouts
import Quickshell
import qs.style.theme
import qs.core.services
import qs.style.widgets
import qs.core.views.overlays.vm

// The VM launcher (`vm-launcher`, >vm). One machine at a time, drawn as a
// monitor; under it what it has and the three steps of a launch – drive,
// machine, Looking Glass – that double as its status. Enter starts it; the
// popup stays while Windows boots and gives way to Looking Glass once the
// host application answers. ←/→ walk the machines when there are several.
ModalWindow {
	id: root

	property int index: 0
	// which way the last change of machine went, for the slide
	property int direction: 1
	readonly property var machines: Machines.vms
	readonly property var machine: root.machines.length > 0 ? root.machines[Math.min(root.index, root.machines.length - 1)] : null
	readonly property bool targeted: !!root.machine && Machines.target === root.machine.name
	readonly property string step: root.targeted ? Machines.step : ""
	readonly property bool launching: root.targeted && Machines.launching
	readonly property string pending: root.machine ? (Machines.pending[root.machine.name] ?? "") : ""
	readonly property bool running: !!root.machine?.running
	readonly property bool connected: root.running && Machines.lgOpen && Machines.lgState === "ready"
	// Looking Glass is up and waits, by its window or by its log
	readonly property bool lgUp: Machines.lgOpen || (Machines.lgFresh && Machines.lgState !== "")

	readonly property var storage: root.machine?.storage ?? []
	readonly property var drives: root.machine?.drives ?? []
	readonly property bool mountedAll: root.storage.every(item => item.mounted && !item.missing)
	readonly property bool drivesFree: root.drives.every(drive => drive.busy.length === 0)
	readonly property bool anyMounted: root.storage.some(item => item.mount !== "" && item.mounted)

	readonly property string phase: {
		if (root.step === "start") return "waking";
		if (root.step === "display") return "booting";
		if (root.running || root.step === "done") return "on";
		return "off";
	}

	readonly property string caption: {
		switch (root.step) {
		case "start": return "Starting";
		case "display": return root.lgUp ? `Waiting for ${root.machine?.family === "windows" ? "Windows" : "the system"}` : "Opening Looking Glass";
		}
		if (root.pending === "shutdown") return "Shutting down";
		if (root.connected) return "Looking Glass connected";
		return "";
	}

	readonly property var stations: {
		if (!root.machine) return [];
		const at = root.targeted ? Machines.stepIndex(root.step === "failed" ? Machines.failedStep : root.step) : -1;
		const done = root.step === "done";
		const stateOf = (i, ready) => {
			if (root.targeted && root.step !== "") {
				if (done || at > i) return "done";
				if (at === i) return root.step === "failed" ? "failed" : "active";
			}
			return ready ? "ready" : "idle";
		};
		const failedHere = name => root.step === "failed" && Machines.failedStep === name;
		const storageDetail = (() => {
			if (failedHere("storage")) return Machines.remedy === "root" ? "Needs a password" : (Machines.remedy === "busy" ? "In use on this PC" : "Failed");
			if (root.step === "storage") return "Mounting";
			if (!root.drivesFree) return "In use on this PC";
			if (root.storage.length === 0) return "Ready";
			return root.mountedAll ? "Mounted" : "Not mounted";
		})();
		const machineDetail = (() => {
			if (failedHere("start")) return "Did not start";
			if (root.step === "start") return "Starting";
			if (root.pending === "shutdown") return "Shutting down";
			if (root.pending === "kill") return "Turning off";
			return root.running ? "Running" : "Off";
		})();
		const displayDetail = (() => {
			if (!root.machine.lookingGlass) return "Not set up";
			if (failedHere("display")) return "Failed";
			if (root.step === "display") return root.lgUp ? `Waiting for ${root.machine.family === "windows" ? "Windows" : "the system"}` : "Opening";
			if (root.connected) return "Connected";
			if (Machines.lgOpen) return "Open";
			return "Closed";
		})();
		// a step the launch is past says what it left
		const stations = [
			{ icon: "harddisk", title: "Drive", detail: storageDetail, past: "Mounted", state: stateOf(0, root.mountedAll && root.drivesFree) },
			{ icon: "power", title: "Machine", detail: machineDetail, past: "Running", state: stateOf(1, root.running) },
			{ icon: "monitor_share", title: "Looking Glass", detail: displayDetail, past: "Connected", state: stateOf(2, root.connected) }
		];
		return stations.map(station => Object.assign(station, { detail: station.state === "done" ? station.past : station.detail }));
	}

	readonly property real progress: {
		if (root.targeted && root.step !== "") {
			if (root.step === "done") return 2;
			return Math.max(0, Machines.stepIndex(root.step === "failed" ? Machines.failedStep : root.step));
		}
		if (root.connected) return 2;
		if (root.running) return 1;
		return 0;
	}

	readonly property var specs: {
		const m = root.machine;
		if (!m) return [];
		const out = [];
		if (m.cpus) out.push({ icon: "cpu_64_bit", text: `${m.cpus} threads` });
		if (m.memory) out.push({ icon: "memory", text: `${Math.round(m.memory)} GB` });
		if (m.gpu) out.push({ icon: "expansion_card", text: m.gpu.replace(/^GeForce /, "").replace(/^Radeon /, "Radeon ") });
		for (const drive of m.drives ?? []) out.push({ icon: "harddisk", text: drive.label && /\d\s*[TG]B/i.test(drive.label) ? drive.label : [drive.label, Format.bytes(drive.size, "")].filter(v => v).join(" · "), warn: drive.busy.length > 0 });
		for (const item of m.storage ?? []) if (item.size) out.push({ icon: "file_outline", text: `${Format.bytes(item.size, "")} image` });
		return out;
	}

	function pick(next) {
		if (root.machines.length < 2) return;
		const target = (next + root.machines.length) % root.machines.length;
		if (target === root.index) return;
		root.direction = next > root.index ? 1 : -1;
		root.index = target;
		Sounds.play("select");
		slide.restart();
		root.intro(true);
	}

	function primary() {
		const m = root.machine;
		if (!m) return;
		if (root.step === "failed") {
			Machines.retry();
		} else if (root.launching || root.step === "done" || root.pending !== "") {
			return;
		} else if (!root.running) {
			Machines.launch(m.name);
		} else if (Machines.lgOpen) {
			Machines.openDisplay(m.name);
			Popups.closeModal();
		} else if (m.lookingGlass) {
			Machines.openDisplay(m.name);
		}
	}

	readonly property var primaryLook: {
		if (!root.machine) return { text: "", icon: "" };
		switch (root.step) {
		case "storage": return { text: "Mounting the drive", icon: "", busy: true };
		case "start": return { text: "Starting", icon: "", busy: true };
		case "display": return { text: root.lgUp ? `Waiting for ${root.machine.family === "windows" ? "Windows" : "the system"}` : "Opening Looking Glass", icon: "", busy: true };
		case "done": return { text: "Ready", icon: "check_bold" };
		case "failed": return { text: "Try again", icon: "refresh" };
		}
		if (root.pending === "shutdown") return { text: "Shutting down", icon: "", busy: true };
		if (root.pending !== "") return { text: "One moment", icon: "", busy: true };
		if (!root.running) return { text: "Start", icon: "play" };
		if (Machines.lgOpen) return { text: `Show ${root.machine.family === "windows" ? "Windows" : root.machine.title}`, icon: "open_in_new" };
		if (root.machine.lookingGlass) return { text: "Open Looking Glass", icon: "monitor_share" };
		return { text: "Running", icon: "check_bold", inert: true };
	}

	// what comes in when the popup opens (and when another machine is picked)
	property real riseTitle: 0
	property real riseSpecs: 0
	property real riseSteps: 0
	property real riseActions: 0

	function intro(quick) {
		risingIn.stop();
		if (quick) {
			root.riseTitle = 0;
			root.riseSpecs = 0;
		} else {
			root.riseTitle = 0;
			root.riseSpecs = 0;
			root.riseSteps = 0;
			root.riseActions = 0;
		}
		risingIn.quick = !!quick;
		risingIn.start();
	}

	ParallelAnimation {
		id: risingIn

		property bool quick: false

		SequentialAnimation {
			PauseAnimation {
				duration: risingIn.quick ? 40 : 120
			}
			SpatialAnim {
				target: root
				property: "riseTitle"
				to: 1
				duration: Motion.long
			}
		}
		SequentialAnimation {
			PauseAnimation {
				duration: risingIn.quick ? 90 : 200
			}
			SpatialAnim {
				target: root
				property: "riseSpecs"
				to: 1
				duration: Motion.long
			}
		}
		SequentialAnimation {
			PauseAnimation {
				duration: risingIn.quick ? 0 : 280
			}
			SpatialAnim {
				target: root
				property: "riseSteps"
				to: 1
				duration: Motion.long
			}
		}
		SequentialAnimation {
			PauseAnimation {
				duration: risingIn.quick ? 0 : 360
			}
			SpatialAnim {
				target: root
				property: "riseActions"
				to: 1
				duration: Motion.long
			}
		}
	}

	modalId: "vm"
	scrimColor: Qt.rgba(0, 0, 0, 0.8)

	onShownChanged: {
		Machines.watched = root.shown;
		// a launch that finished is over once the popup has gone
		if (!root.shown && !Machines.launching) Machines.dismiss();
	}

	onModalOpened: {
		if (!Machines.launching) Machines.dismiss();
		// the machine being launched, else the one that runs, else the last one
		const busy = root.machines.findIndex(m => m.name === Machines.target);
		const on = root.machines.findIndex(m => m.running);
		if (busy >= 0) root.index = busy;
		else if (on >= 0) root.index = on;
		Machines.refresh();
		root.intro(false);
		keys.forceActiveFocus();
	}

	Connections {
		target: Machines

		function onLaunched(name) {
			if (root.machine?.name === name) art.celebrate();
		}
	}

	// once it is ready the popup gives way to Looking Glass
	Timer {
		interval: 1500
		running: root.shown && root.step === "done"
		onTriggered: Popups.closeModal()
	}

	// ── ambience: two slow clouds of the accent behind everything ─────────
	Item {
		id: clouds

		anchors.centerIn: parent
		anchors.verticalCenterOffset: -120
		width: 900
		height: 600
		visible: false
		layer.enabled: true

		Rectangle {
			id: cloudA

			property real drift: 0

			x: 180 + 70 * Math.sin(cloudA.drift * Math.PI * 2)
			y: 140 + 40 * Math.cos(cloudA.drift * Math.PI * 2)
			width: 380
			height: 300
			radius: 150
			color: Theme.primary

			NumberAnimation on drift {
				running: root.shown
				loops: Animation.Infinite
				from: 0
				to: 1
				duration: 14000
			}
		}

		Rectangle {
			id: cloudB

			property real drift: 0

			x: 380 - 80 * Math.sin(cloudB.drift * Math.PI * 2)
			y: 200 - 50 * Math.sin(cloudB.drift * Math.PI * 4)
			width: 340
			height: 260
			radius: 130
			color: Theme.tertiary

			NumberAnimation on drift {
				running: root.shown
				loops: Animation.Infinite
				from: 0
				to: 1
				duration: 19000
			}
		}
	}

	MultiEffect {
		anchors.fill: clouds
		source: clouds
		blurEnabled: true
		blurMax: 64
		blur: 1
		opacity: (root.phase === "off" ? 0.16 : 0.3) * root.reveal

		Behavior on opacity {
			Anim {
				duration: Motion.extraLong
			}
		}
	}

	Item {
		id: keys

		anchors.fill: parent
		focus: true

		Keys.onReturnPressed: root.primary()
		Keys.onEnterPressed: root.primary()
		Keys.onSpacePressed: root.primary()
		Keys.onLeftPressed: root.pick(root.index - 1)
		Keys.onRightPressed: root.pick(root.index + 1)
		Keys.onTabPressed: root.pick(root.index + 1)

		// a click on the content is not one beside it
		MouseArea {
			anchors.fill: stage
		}

		ColumnLayout {
			id: stage

			anchors.centerIn: parent
			width: 640
			spacing: 0
			visible: root.machine !== null

			// ── header ─────────────────────────────────────────────────────
			RowLayout {
				Layout.alignment: Qt.AlignHCenter
				Layout.bottomMargin: 6
				spacing: 10
				opacity: root.riseTitle

				StyledText {
					text: "Virtual machines"
					tone: Qt.rgba(1, 1, 1, 0.5)
					surface: "transparent"
					font.pixelSize: Theme.size.tiny
					font.weight: Font.Bold
					font.letterSpacing: 1.6
					font.capitalization: Font.AllUppercase
				}

				// a dot for each machine when there are several
				Row {
					visible: root.machines.length > 1
					spacing: 5

					Repeater {
						model: root.machines.length

						delegate: Rectangle {
							required property int index

							width: index === root.index ? 16 : 6
							height: 6
							radius: 3
							color: index === root.index ? Theme.primary : Qt.rgba(1, 1, 1, 0.25)

							Behavior on width {
								SpatialAnim {
									duration: Motion.medium
								}
							}
							Behavior on color {
								ColorAnim {}
							}
						}
					}
				}
			}

			// ── the machine ────────────────────────────────────────────────
			Item {
				id: hero

				property real leanX: 0
				property real leanY: 0

				Layout.alignment: Qt.AlignHCenter
				Layout.preferredWidth: 640
				Layout.preferredHeight: 300

				Behavior on leanX {
					SpringAnimation {
						spring: 2.2
						damping: 0.32
					}
				}
				Behavior on leanY {
					SpringAnimation {
						spring: 2.2
						damping: 0.32
					}
				}

				MouseArea {
					anchors.fill: parent
					hoverEnabled: true
					acceptedButtons: Qt.NoButton
					onPositionChanged: mouse => {
						hero.leanX = Math.max(-1, Math.min(1, (mouse.x - width / 2) / (width / 2)));
						hero.leanY = Math.max(-1, Math.min(1, (mouse.y - height / 2) / (height / 2)));
					}
					onExited: {
						hero.leanX = 0;
						hero.leanY = 0;
					}
				}

				MachineArt {
					id: art

					property real offset: 0

					anchors.horizontalCenter: parent.horizontalCenter
					anchors.horizontalCenterOffset: art.offset
					machine: root.machine
					phase: root.phase
					caption: root.caption
					active: root.shown
					lean: Qt.point(hero.leanX, hero.leanY)
					scale: 0.94 + 0.06 * root.reveal
				}

				// another machine slides in from the side it was picked from
				ParallelAnimation {
					id: slide

					NumberAnimation {
						target: art
						property: "offset"
						from: 70 * root.direction
						to: 0
						duration: Motion.long
						easing.type: Easing.BezierSpline
						easing.bezierCurve: Motion.spatial
					}
					NumberAnimation {
						target: art
						property: "opacity"
						from: 0
						to: 1
						duration: Motion.medium
					}
				}

				Repeater {
					model: root.machines.length > 1 ? [-1, 1] : []

					delegate: IconButton {
						required property int modelData

						anchors.verticalCenter: parent.verticalCenter
						anchors.verticalCenterOffset: -20
						x: modelData < 0 ? 8 : parent.width - width - 8
						implicitWidth: 40
						implicitHeight: 40
						icon: modelData < 0 ? "chevron_left" : "chevron_right"
						iconColor: "white"
						onClicked: root.pick(root.index + modelData)
					}
				}
			}

			// ── name and state ─────────────────────────────────────────────
			ColumnLayout {
				Layout.alignment: Qt.AlignHCenter
				Layout.topMargin: 4
				spacing: 8
				opacity: root.riseTitle
				transform: Translate {
					y: 14 * (1 - root.riseTitle)
				}

				StyledText {
					Layout.alignment: Qt.AlignHCenter
					text: root.machine?.title ?? ""
					tone: "white"
					surface: "transparent"
					font.pixelSize: 32
					font.weight: Font.Bold
				}

				// the state as a pill with a light that breathes while it runs
				Rectangle {
					id: statePill

					readonly property bool lit: root.running || root.launching || root.step === "done"
					readonly property string words: {
						if (root.step === "failed") return "Launch stopped";
						if (root.step === "done") return "Ready";
						if (root.launching) return "Launching";
						if (root.pending === "shutdown") return "Shutting down";
						if (root.running) return root.machine?.state === "paused" ? "Paused" : "Running";
						return "Off";
					}

					Layout.alignment: Qt.AlignHCenter
					implicitWidth: pillRow.implicitWidth + 22
					implicitHeight: 26
					radius: 13
					color: root.step === "failed" ? Qt.alpha(Theme.danger, 0.2) : (statePill.lit ? Qt.alpha(Theme.primary, 0.18) : Qt.rgba(1, 1, 1, 0.08))

					Behavior on color {
						ColorAnim {}
					}
					Behavior on implicitWidth {
						SpatialAnim {
							duration: Motion.medium
						}
					}

					RowLayout {
						id: pillRow

						anchors.centerIn: parent
						spacing: 7

						Rectangle {
							id: lamp

							property real glow: 1

							Layout.preferredWidth: 7
							Layout.preferredHeight: 7
							radius: 3.5
							color: root.step === "failed" ? Theme.danger : (statePill.lit ? Theme.primary : Qt.rgba(1, 1, 1, 0.35))
							opacity: lamp.glow

							SequentialAnimation on glow {
								running: root.shown && statePill.lit
								loops: Animation.Infinite
								onRunningChanged: if (!running) lamp.glow = 1

								NumberAnimation {
									to: 0.35
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

						StyledText {
							text: statePill.words
							tone: Qt.rgba(1, 1, 1, 0.85)
							surface: "transparent"
							font.pixelSize: Theme.size.small
							font.weight: Font.DemiBold
						}
					}
				}
			}

			// ── what it has ────────────────────────────────────────────────
			Row {
				Layout.alignment: Qt.AlignHCenter
				Layout.topMargin: 18
				spacing: 8

				Repeater {
					model: root.specs

					delegate: Rectangle {
						id: spec

						required property var modelData
						required property int index
						readonly property real rise: Math.max(0, Math.min(1, root.riseSpecs * (root.specs.length + 1) - spec.index))

						width: specLine.implicitWidth + 22
						height: 30
						radius: 15
						color: spec.modelData.warn ? Qt.alpha(Theme.warning, 0.18) : Qt.rgba(1, 1, 1, 0.07)
						opacity: spec.rise
						transform: Translate {
							y: 10 * (1 - spec.rise)
						}

						RowLayout {
							id: specLine

							anchors.centerIn: parent
							spacing: 6

							Glyph {
								icon: spec.modelData.icon
								size: 15
								color: spec.modelData.warn ? Theme.warning : Qt.alpha(Theme.primary, 0.95)
								surface: "transparent"
							}

							StyledText {
								text: spec.modelData.text
								tone: Qt.rgba(1, 1, 1, 0.82)
								surface: "transparent"
								font.pixelSize: Theme.size.small
								font.weight: Font.Medium
							}
						}
					}
				}
			}

			// ── the steps ──────────────────────────────────────────────────
			LaunchSteps {
				Layout.alignment: Qt.AlignHCenter
				Layout.preferredWidth: 600
				Layout.topMargin: 30
				stations: root.stations
				progress: root.progress
				active: root.shown
				opacity: root.riseSteps
				transform: Translate {
					y: 18 * (1 - root.riseSteps)
				}
			}

			// ── what went wrong, and what helps ────────────────────────────
			Item {
				id: trouble

				readonly property bool shown: root.step === "failed"
				property string words: ""

				Layout.alignment: Qt.AlignHCenter
				Layout.preferredWidth: 560
				Layout.preferredHeight: trouble.shown ? troubleCard.implicitHeight : 0
				Layout.topMargin: trouble.shown ? 8 : 0
				opacity: trouble.shown ? 1 : 0
				clip: true

				onShownChanged: if (trouble.shown) trouble.words = Machines.failure

				Behavior on Layout.preferredHeight {
					SpatialAnim {
						duration: Motion.medium
					}
				}
				Behavior on Layout.topMargin {
					SpatialAnim {
						duration: Motion.medium
					}
				}
				Behavior on opacity {
					Anim {}
				}

				Rectangle {
					id: troubleCard

					width: parent.width
					implicitHeight: troubleRow.implicitHeight + 24
					radius: Theme.radius.large
					color: Qt.alpha(Theme.danger, 0.13)
					border.width: 1
					border.color: Qt.alpha(Theme.danger, 0.3)

					RowLayout {
						id: troubleRow

						anchors.fill: parent
						anchors.margins: 12
						anchors.leftMargin: 16
						spacing: 12

						Glyph {
							icon: Machines.remedy === "root" ? "key_variant" : "alert_circle_outline"
							size: 22
							color: Theme.danger
							surface: "transparent"
						}

						ColumnLayout {
							Layout.fillWidth: true
							spacing: 2

							StyledText {
								Layout.fillWidth: true
								text: trouble.words
								tone: "white"
								surface: "transparent"
								wrapMode: Text.WordWrap
								font.pixelSize: Theme.size.body
								font.weight: Font.DemiBold
							}

							StyledText {
								Layout.fillWidth: true
								visible: text !== ""
								text: {
									if (Machines.remedy === "root") return "A terminal asks for it; after that Pshell mounts it on its own.";
									if (Machines.remedy === "busy") return Machines.busy.map(entry => `${entry.mountpoint} has to be unmounted first`).join("\n");
									return "";
								}
								tone: Qt.rgba(1, 1, 1, 0.6)
								surface: "transparent"
								wrapMode: Text.WordWrap
								font.pixelSize: Theme.size.small
							}
						}

						TextButton {
							visible: Machines.remedy !== ""
							variant: "danger"
							text: Machines.authorizing ? "In the terminal" : (Machines.remedy === "root" ? "Enter password" : "Unmount")
							icon: Machines.authorizing ? "" : "key_variant"
							busy: Machines.authorizing
							enabled: !Machines.authorizing
							onClicked: Machines.authorize()
						}
					}
				}
			}

			// ── actions ────────────────────────────────────────────────────
			RowLayout {
				Layout.alignment: Qt.AlignHCenter
				Layout.topMargin: 22
				spacing: 12
				opacity: root.riseActions
				transform: Translate {
					y: 18 * (1 - root.riseActions)
				}

				// the one thing to do now
				Item {
					id: go

					readonly property var look: root.primaryLook
					readonly property bool busy: !!go.look.busy
					readonly property bool inert: go.busy || !!go.look.inert || root.step === "done"

					Layout.preferredWidth: Math.max(200, goRow.implicitWidth + 48)
					Layout.preferredHeight: 52

					Behavior on Layout.preferredWidth {
						SpatialAnim {
							duration: Motion.medium
						}
					}

					Rectangle {
						id: goFace

						anchors.fill: parent
						radius: height / 2
						color: root.step === "failed" ? Theme.danger : Theme.primary
						opacity: go.busy ? 0.75 : 1
						scale: goMouse.pressed && !go.inert ? 0.95 : (goMouse.containsMouse && !go.inert ? 1.03 : 1)
						clip: true

						Behavior on color {
							ColorAnim {}
						}
						Behavior on opacity {
							Anim {}
						}
						Behavior on scale {
							SpatialAnim {
								duration: Motion.medium
							}
						}

						// a shimmer runs over it while it waits
						Rectangle {
							id: shimmer

							property real travel: 0

							visible: go.busy
							width: 70
							height: parent.height * 2
							y: -parent.height / 2
							rotation: 20
							x: -width + (parent.width + width * 2) * shimmer.travel
							gradient: Gradient {
								orientation: Gradient.Horizontal
								GradientStop {
									position: 0
									color: Qt.rgba(1, 1, 1, 0)
								}
								GradientStop {
									position: 0.5
									color: Qt.rgba(1, 1, 1, 0.28)
								}
								GradientStop {
									position: 1
									color: Qt.rgba(1, 1, 1, 0)
								}
							}

							NumberAnimation on travel {
								running: go.busy && root.shown
								loops: Animation.Infinite
								from: 0
								to: 1
								duration: 1400
								easing.type: Easing.InOutQuad
							}
						}

						RowLayout {
							id: goRow

							anchors.centerIn: parent
							spacing: 10

							Spinner {
								visible: go.busy
								Layout.preferredWidth: 18
								Layout.preferredHeight: 18
								color: Theme.onPrimary
							}

							Glyph {
								visible: !go.busy && go.look.icon !== ""
								icon: go.look.icon || "play"
								size: 22
								color: root.step === "failed" ? Theme.bg : Theme.onPrimary
								surface: goFace.color
							}

							StyledText {
								text: go.look.text
								tone: root.step === "failed" ? Theme.bg : Theme.onPrimary
								surface: goFace.color
								font.pixelSize: Theme.size.title
								font.weight: Font.Bold
							}
						}
					}

					MouseArea {
						id: goMouse

						anchors.fill: parent
						hoverEnabled: true
						cursorShape: go.inert ? Qt.ArrowCursor : Qt.PointingHandCursor
						onClicked: {
							if (go.inert) return;
							Sounds.play("click");
							root.primary();
						}
					}
				}

				HoldButton {
					visible: root.running && !root.launching && root.step !== "done"
					text: root.pending === "shutdown" ? "Shutting down" : "Shut down"
					icon: "power"
					accent: Theme.warning
					busy: root.pending === "shutdown"
					enabled: root.pending === "" || root.pending === "shutdown"
					onConfirmed: Machines.shutdown(root.machine.name)
				}

				HoldButton {
					visible: root.running && !root.launching && root.step !== "done"
					text: "Force off"
					icon: "power_plug_off"
					holdTime: 1200
					busy: root.pending === "kill"
					onConfirmed: Machines.kill(root.machine.name)
				}

				TextButton {
					visible: !root.running && root.step === "" && root.anyMounted
					implicitHeight: 44
					text: root.pending === "unmount" ? "Unmounting" : "Unmount drive"
					icon: "eject"
					busy: root.pending === "unmount"
					onClicked: Machines.unmount(root.machine.name)
				}
			}

			// ── the keys ───────────────────────────────────────────────────
			Row {
				Layout.alignment: Qt.AlignHCenter
				Layout.topMargin: 22
				spacing: 18
				opacity: 0.55 * root.riseActions

				Repeater {
					model: [
						{ key: "↵", what: root.primaryLook.text, shown: !root.primaryLook.busy && !root.primaryLook.inert && root.step !== "done" },
						{ key: "← →", what: "Machine", shown: root.machines.length > 1 },
						{ key: "Esc", what: "Close" }
					].filter(hint => hint.shown !== false && hint.what)

					delegate: Row {
						id: hint

						required property var modelData

						spacing: 6

						Rectangle {
							anchors.verticalCenter: parent.verticalCenter
							width: Math.max(22, keyText.implicitWidth + 12)
							height: 20
							radius: 5
							color: Qt.rgba(1, 1, 1, 0.1)
							border.width: 1
							border.color: Qt.rgba(1, 1, 1, 0.14)

							StyledText {
								id: keyText

								anchors.centerIn: parent
								text: hint.modelData.key
								tone: "white"
								surface: "transparent"
								font.pixelSize: Theme.size.tiny
								font.weight: Font.Bold
							}
						}

						StyledText {
							anchors.verticalCenter: parent.verticalCenter
							text: hint.modelData.what
							tone: "white"
							surface: "transparent"
							font.pixelSize: Theme.size.small
						}
					}
				}
			}
		}

		// nothing to show yet, or nothing at all
		Column {
			anchors.centerIn: parent
			spacing: 14
			visible: root.machine === null

			Spinner {
				anchors.horizontalCenter: parent.horizontalCenter
				visible: !Machines.loaded
				width: 30
				height: 30
				color: "white"
			}

			Glyph {
				anchors.horizontalCenter: parent.horizontalCenter
				visible: Machines.loaded
				icon: "monitor_off"
				size: 54
				color: Qt.rgba(1, 1, 1, 0.6)
				surface: "transparent"
			}

			StyledText {
				anchors.horizontalCenter: parent.horizontalCenter
				text: Machines.loaded ? (Machines.error !== "" ? "libvirt does not answer" : "No virtual machines") : "Looking for machines"
				tone: "white"
				surface: "transparent"
				font.pixelSize: Theme.size.heading
				font.weight: Font.DemiBold
			}

			StyledText {
				anchors.horizontalCenter: parent.horizontalCenter
				visible: Machines.loaded
				text: Machines.error !== "" ? "Is libvirtd running? (systemctl start libvirtd)" : "Create one in virt-manager and it shows up here."
				tone: Qt.rgba(1, 1, 1, 0.6)
				surface: "transparent"
				font.pixelSize: Theme.size.body
			}
		}
	}
}
