pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.style.theme
import qs.core.services
import qs.style.widgets
import qs.core.views.vm
import qs.core.views.remote

// Remote PCs (`remote-pcs`, >pc): the PCs core knows, under a sky that is
// night while one sleeps and day once it streams. Holding its power key
// (or Enter) wakes it: a shooting star (the magic packet) flies from the
// moon (this PC) over netcore to it, it boots, signs in, the sun (Sunshine)
// rises behind it, and a beam back to the moon is Moonlight connecting.
// The chips say how far a wake goes; the shelf below picks the PC.
ModalWindow {
	id: root

	property int index: 0
	readonly property var pcs: Remote.others
	readonly property var pc: root.pcs.length > 0 ? root.pcs[Math.min(root.index, root.pcs.length - 1)] : null
	readonly property bool targeted: !!root.pc && Remote.target === root.pc.id
	readonly property string phase: root.targeted ? Remote.phase : ""
	readonly property bool travelling: root.targeted && Remote.travelling
	readonly property bool online: !!root.pc?.online
	readonly property bool waking: !!root.pc?.waking && !root.online
	readonly property bool laptop: root.pc?.kind === "laptop"
	readonly property bool ready: root.online && !!root.pc?.session && !!root.pc?.stream

	modalId: "remote"
	scrimColor: Qt.rgba(0, 0, 0, 0.82)

	function pick(next) {
		if (root.pcs.length < 2) return;
		const target = (next + root.pcs.length) % root.pcs.length;
		if (target === root.index) return;
		root.index = target;
		Sounds.play("navigate");
		swap.restart();
	}

	function primary() {
		const pc = root.pc;
		if (!pc) return;
		if (root.phase === "failed") {
			Remote.retry();
			return;
		}
		if (root.travelling || root.phase === "done") return;
		if (root.ready && Remote.wantConnect) Remote.connect(pc.id);
		else Remote.wake(pc.id);
	}

	// ── what the scene shows ────────────────────────────────────────────────
	readonly property string screen: {
		switch (root.phase) {
		case "packet": return root.online ? root.restingScreen : "off";
		case "power": return "boot";
		case "login": return "login";
		}
		return root.restingScreen;
	}
	readonly property string restingScreen: {
		if (!root.online) return "off";
		if (root.pc?.stream) return "stream";
		if (root.pc?.session) return "desktop";
		return "login";
	}
	readonly property real dawn: {
		switch (root.phase) {
		case "packet": return root.online ? 0.4 : 0.05;
		case "power": return 0.22;
		case "login": return 0.4;
		case "sunshine": return 0.62;
		case "moonlight": return 0.8;
		case "done": return 1;
		}
		if (!root.online) return root.waking ? 0.15 : 0;
		if (root.pc?.stream) return 0.85;
		if (root.pc?.session) return 0.6;
		return 0.3;
	}
	readonly property real sunUp: {
		if (root.phase === "sunshine") return 0.45;
		if (root.phase === "moonlight" || root.phase === "done") return 1;
		return root.online && root.pc?.stream ? 1 : 0;
	}
	readonly property real beam: {
		if (root.phase === "moonlight") return 0.55;
		if (root.phase === "done") return 1;
		return Remote.moonWindow && root.pc?.stream ? 1 : 0;
	}

	readonly property string caption: {
		switch (root.phase) {
		case "failed": return "Stopped";
		case "packet": return "Magic packet on its way";
		case "power": return root.laptop ? "Opening its eyes" : "Powering up";
		case "login": return `Signing ${root.pc?.user || "you"} in`;
		case "sunshine": return "Sunrise: Sunshine starts";
		case "moonlight": return Remote.pairing ? "Pairing Moonlight" : "Moonlight connects";
		case "done": return "Here it is";
		}
		if (root.waking) return "Waking up";
		if (!root.pc) return "";
		if (!root.online) return root.pc.last_seen ? `Asleep · seen ${Netcore.ago(root.pc.last_seen)}` : "Asleep";
		if (root.pc.stream) return "Awake · Sunshine is up";
		if (root.pc.session) return `Awake · ${root.pc.user || "signed in"}`;
		return "Awake · at the sign-in";
	}

	readonly property var stations: {
		const pc = root.pc;
		if (!pc) return [];
		const order = Remote.phases;
		const at = root.targeted ? Remote.phaseIndex(root.phase === "failed" ? Remote.failedPhase : root.phase) : -1;
		const reached = { packet: root.online, power: root.online, login: !!pc.session, sunshine: !!pc.stream, moonlight: !!Remote.moonWindow && !!pc.stream };
		const wanted = { packet: true, power: true, login: Remote.wantLogin, sunshine: Remote.wantStream, moonlight: Remote.wantConnect };
		const look = {
			packet: { icon: "lan_connect", title: "Wake", detail: pc.mac ? "Magic packet" : "No MAC known" },
			power: { icon: "power", title: "Power", detail: root.online ? "On" : "Off" },
			login: { icon: "account", title: "Sign in", detail: pc.session ? (pc.user || "Signed in") : "Automatically" },
			sunshine: { icon: "white_balance_sunny", title: "Sunshine", detail: pc.stream ? "Running" : "Starts there" },
			moonlight: { icon: "moon_waning_crescent", title: "Moonlight", detail: Remote.hasMoonlight ? (Remote.pairing ? `PIN ${Remote.pin}` : "Connects here") : "Not installed here" }
		};
		return order.map((name, i) => {
			let state = reached[name] ? "done" : "idle";
			if (root.targeted && root.phase !== "") {
				if (root.phase === "done" || at > i) state = "done";
				else if (at === i) state = root.phase === "failed" ? "failed" : "active";
				else state = reached[name] ? "done" : "idle";
			}
			if (!wanted[name] && state !== "done") state = "skip";
			return Object.assign({ state: state }, look[name]);
		});
	}
	readonly property real progress: {
		const list = root.stations;
		let reach = 0;
		for (let i = 0; i < list.length; i++) {
			if (list[i].state === "done") reach = i;
			else if (list[i].state === "active") return i - 0.5 > reach ? i - 0.5 : reach + 0.5;
		}
		return reach;
	}

	onShownChanged: {
		Remote.watched = root.shown;
		if (!root.shown && !Remote.travelling) Remote.dismiss();
	}

	onModalOpened: {
		if (!Remote.travelling) Remote.dismiss();
		const busy = root.pcs.findIndex(pc => pc.id === Remote.target);
		const asleep = root.pcs.findIndex(pc => !pc.online);
		if (busy >= 0) root.index = busy;
		else if (root.index >= root.pcs.length) root.index = Math.max(0, asleep);
		Remote.refresh();
		Remote.readLocal();
		keys.forceActiveFocus();
		rise.restart();
	}

	// once it streams the popup gives way to Moonlight
	Timer {
		interval: 1800
		running: root.shown && root.phase === "done"
		onTriggered: Popups.closeModal()
	}

	// the packet's flight
	property real packet: -1
	NumberAnimation {
		id: flight

		target: root
		property: "packet"
		from: 0
		to: 1
		duration: 1300
		easing.type: Easing.InOutCubic
		onFinished: root.packet = -1
	}
	onPhaseChanged: if (root.phase === "packet") flight.restart()

	property real lift: 0
	NumberAnimation {
		id: rise

		target: root
		property: "lift"
		from: 0
		to: 1
		duration: 900
		easing.type: Easing.OutCubic
	}

	Item {
		id: keys

		anchors.fill: parent
		focus: true

		Keys.onReturnPressed: root.primary()
		Keys.onEnterPressed: root.primary()
		Keys.onLeftPressed: root.pick(root.index - 1)
		Keys.onRightPressed: root.pick(root.index + 1)
		Keys.onTabPressed: root.pick(root.index + 1)
		Keys.onPressed: event => {
			if (root.travelling || !root.shown) return;
			if (event.key === Qt.Key_1) Remote.wantLogin = !Remote.wantLogin;
			else if (event.key === Qt.Key_2) Remote.wantStream = !Remote.wantStream;
			else if (event.key === Qt.Key_3) Remote.wantConnect = !Remote.wantConnect;
			else return;
			wishes.settle();
			event.accepted = true;
		}

		MouseArea {
			anchors.fill: stage
		}

		ColumnLayout {
			id: stage

			// a fixed top: rows that come and go do not move the sky
			anchors.horizontalCenter: parent.horizontalCenter
			y: Math.max(16, (parent.height - 820) / 2)
			width: 880
			spacing: 0
			visible: root.pc !== null
			opacity: root.lift
			transform: Translate {
				y: 24 * (1 - root.lift)
			}

			// ── the scene ───────────────────────────────────────────────────
			Item {
				id: scene

				Layout.preferredWidth: 880
				Layout.preferredHeight: 380

				Sky {
					id: sky

					anchors.fill: parent
					active: root.shown
					dawn: root.dawn
					sun: root.sunUp
					beam: root.beam
					packet: root.packet
					relayLit: root.packet > 0.36 && root.packet < 0.66
					target: Qt.point(figure.x + figure.screenCenter.x, figure.y + figure.screenCenter.y)
				}

				PcFigure {
					id: figure

					property real offset: 0

					x: (scene.width - width) / 2 + figure.offset
					y: sky.horizonY - 172
					kind: root.pc?.kind ?? "pc"
					screen: root.screen
					user: root.pc?.user ?? ""
					light: root.dawn
					active: root.shown
					led: root.online || root.phase === "power"
					ledBlink: root.phase === "power" || root.phase === "login"
					armed: !root.travelling && root.phase !== "done" && !(root.ready && root.phase === "")
					onTouched: Sounds.play("click")
					onPressedLong: root.primary()
				}

				// another PC walks in from the side
				ParallelAnimation {
					id: swap

					NumberAnimation {
						target: figure
						property: "offset"
						from: 60
						to: 0
						duration: Motion.long
						easing.type: Easing.OutCubic
					}
					NumberAnimation {
						target: figure
						property: "opacity"
						from: 0
						to: 1
						duration: Motion.medium
					}
				}

				// where it is in the network
				Row {
					anchors.top: parent.top
					anchors.right: parent.right
					anchors.margins: 18
					spacing: 6

					Repeater {
						model: [root.pc?.ip, root.pc?.mac].filter(value => !!value)

						delegate: Rectangle {
							required property string modelData

							width: chipText.implicitWidth + 16
							height: 22
							radius: 11
							color: Qt.rgba(0, 0, 0, 0.28)
							border.width: 1
							border.color: Qt.rgba(1, 1, 1, 0.08)

							StyledText {
								id: chipText

								anchors.centerIn: parent
								text: parent.modelData
								tone: Qt.rgba(1, 1, 1, 0.6)
								surface: "transparent"
								font.pixelSize: Theme.size.tiny
								font.family: "monospace"
							}
						}
					}
				}

				// the name, on the hill
				Column {
					anchors.horizontalCenter: parent.horizontalCenter
					anchors.bottom: parent.bottom
					anchors.bottomMargin: 10
					spacing: 2

					StyledText {
						anchors.horizontalCenter: parent.horizontalCenter
						text: root.pc?.name ?? ""
						tone: "white"
						surface: "transparent"
						font.pixelSize: 26
						font.weight: Font.Bold
					}

					RollText {
						anchors.horizontalCenter: parent.horizontalCenter
						text: root.caption
						tone: root.phase === "failed" ? Theme.danger : Qt.rgba(1, 1, 1, 0.68)
						pixelSize: Theme.size.body
						weight: Font.Medium
						alignment: Qt.AlignHCenter
					}
				}
			}

			// ── the way ─────────────────────────────────────────────────────
			Constellation {
				Layout.alignment: Qt.AlignHCenter
				Layout.preferredWidth: 760
				Layout.topMargin: 22
				stations: root.stations
				progress: root.progress
				active: root.shown
			}

			// ── what went wrong ─────────────────────────────────────────────
			Rectangle {
				Layout.alignment: Qt.AlignHCenter
				Layout.preferredWidth: 640
				Layout.topMargin: 4
				visible: root.phase === "failed"
				implicitHeight: troubleRow.implicitHeight + 22
				radius: Theme.radius.large
				color: Qt.alpha(Theme.danger, 0.13)
				border.width: 1
				border.color: Qt.alpha(Theme.danger, 0.3)

				RowLayout {
					id: troubleRow

					anchors.fill: parent
					anchors.margins: 11
					anchors.leftMargin: 16
					spacing: 12

					Glyph {
						icon: "alert_circle_outline"
						size: 20
						color: Theme.danger
						surface: "transparent"
					}

					StyledText {
						Layout.fillWidth: true
						text: Remote.failure
						tone: "white"
						surface: "transparent"
						wrapMode: Text.WordWrap
						font.pixelSize: Theme.size.body
						font.weight: Font.DemiBold
					}

					TextButton {
						visible: Remote.remedy === "moonlight"
						text: "Install Moonlight"
						icon: "download"
						onClicked: Remote.installMoonlight()
					}

					TextButton {
						variant: "danger"
						text: "Try again"
						icon: "refresh"
						onClicked: Remote.retry()
					}
				}
			}

			// ── how far, and what else ──────────────────────────────────────
			RowLayout {
				id: wishes

				function settle() {
					if (!Remote.wantLogin) {
						Remote.wantStream = false;
						Remote.wantConnect = false;
					}
					if (Remote.wantConnect) {
						Remote.wantStream = true;
						Remote.wantLogin = true;
					}
					if (Remote.wantStream) Remote.wantLogin = true;
					Sounds.play("click");
				}

				Layout.alignment: Qt.AlignHCenter
				Layout.topMargin: 18
				spacing: 10

				Repeater {
					model: [
						{ key: "1", icon: "account", title: "Sign in", on: Remote.wantLogin, set: () => { Remote.wantLogin = !Remote.wantLogin; if (!Remote.wantLogin) { Remote.wantStream = false; Remote.wantConnect = false; } } },
						{ key: "2", icon: "white_balance_sunny", title: "Sunshine", on: Remote.wantStream, set: () => { Remote.wantStream = !Remote.wantStream; if (Remote.wantStream) Remote.wantLogin = true; else Remote.wantConnect = false; } },
						{ key: "3", icon: "moon_waning_crescent", title: "Moonlight", on: Remote.wantConnect, set: () => { Remote.wantConnect = !Remote.wantConnect; if (Remote.wantConnect) { Remote.wantStream = true; Remote.wantLogin = true; } } }
					]

					delegate: Rectangle {
						id: wish

						required property var modelData
						readonly property bool on: wish.modelData.on
						readonly property bool locked: root.travelling

						implicitWidth: wishRow.implicitWidth + 26
						implicitHeight: 38
						radius: 19
						color: wish.on ? Qt.alpha(Theme.primary, 0.2) : Qt.rgba(1, 1, 1, wishMouse.containsMouse && !wish.locked ? 0.08 : 0.04)
						border.width: 1
						border.color: wish.on ? Qt.alpha(Theme.primary, 0.6) : Qt.rgba(1, 1, 1, 0.12)
						opacity: wish.locked ? 0.5 : 1

						Behavior on color {
							ColorAnim {}
						}

						RowLayout {
							id: wishRow

							anchors.centerIn: parent
							spacing: 8

							// a switch-like lamp
							Rectangle {
								Layout.preferredWidth: 26
								Layout.preferredHeight: 14
								radius: 7
								color: wish.on ? Theme.primary : Qt.rgba(1, 1, 1, 0.14)

								Behavior on color {
									ColorAnim {}
								}

								Rectangle {
									width: 10
									height: 10
									radius: 5
									y: 2
									x: wish.on ? 14 : 2
									color: wish.on ? Theme.onPrimary : Qt.rgba(1, 1, 1, 0.7)

									Behavior on x {
										SpatialAnim {
											duration: Motion.medium
										}
									}
								}
							}

							Glyph {
								icon: wish.modelData.icon
								size: 16
								color: wish.on ? "white" : Qt.rgba(1, 1, 1, 0.55)
								surface: "transparent"
							}

							StyledText {
								text: wish.modelData.title
								tone: wish.on ? "white" : Qt.rgba(1, 1, 1, 0.6)
								surface: "transparent"
								font.pixelSize: Theme.size.body
								font.weight: Font.DemiBold
							}
						}

						MouseArea {
							id: wishMouse

							anchors.fill: parent
							hoverEnabled: true
							cursorShape: wish.locked ? Qt.ArrowCursor : Qt.PointingHandCursor
							onClicked: {
								if (wish.locked) return;
								wish.modelData.set();
								Sounds.play("click");
							}
						}
					}
				}

				Rectangle {
					Layout.preferredWidth: 1
					Layout.preferredHeight: 26
					Layout.leftMargin: 6
					Layout.rightMargin: 6
					color: Qt.rgba(1, 1, 1, 0.12)
					visible: actions.visible
				}

				RowLayout {
					id: actions

					spacing: 10
					visible: root.travelling || (root.online && root.phase !== "done")

					TextButton {
						visible: root.ready && !root.travelling && root.phase !== "done" && root.phase !== "failed"
						text: "Connect"
						icon: "moon_waning_crescent"
						variant: "filled"
						onClicked: Remote.connect(root.pc.id)
					}

					TextButton {
						visible: root.travelling
						text: "Stop"
						icon: "close"
						onClicked: Remote.cancel()
					}

					HoldButton {
						visible: root.online && !root.travelling && root.phase !== "done"
						text: "Shut down"
						icon: "power"
						accent: Theme.warning
						onConfirmed: Remote.command(root.pc.id, "shutdown")
					}
				}
			}

			// ── the PCs ─────────────────────────────────────────────────────
			Row {
				Layout.alignment: Qt.AlignHCenter
				Layout.topMargin: 24
				spacing: 10
				visible: root.pcs.length > 1

				Repeater {
					model: root.pcs

					delegate: Rectangle {
						id: shelfPc

						required property var modelData
						required property int index
						readonly property bool chosen: shelfPc.index === root.index

						width: 150
						height: 52
						radius: 16
						color: shelfPc.chosen ? Qt.rgba(1, 1, 1, 0.1) : Qt.rgba(1, 1, 1, shelfMouse.containsMouse ? 0.06 : 0.03)
						border.width: 1
						border.color: shelfPc.chosen ? Qt.alpha(Theme.primary, 0.55) : Qt.rgba(1, 1, 1, 0.06)

						Behavior on color {
							ColorAnim {}
						}

						RowLayout {
							anchors.fill: parent
							anchors.leftMargin: 12
							anchors.rightMargin: 12
							spacing: 10

							Item {
								Layout.preferredWidth: 26
								Layout.preferredHeight: 26

								Glyph {
									anchors.centerIn: parent
									icon: shelfPc.modelData.kind === "laptop" ? "laptop" : "desktop_tower_monitor"
									size: 22
									color: shelfPc.modelData.online ? "white" : Qt.rgba(1, 1, 1, 0.4)
									surface: "transparent"
								}

								Rectangle {
									id: shelfLamp

									anchors.right: parent.right
									anchors.bottom: parent.bottom
									width: 8
									height: 8
									radius: 4
									color: shelfPc.modelData.online ? "#7dffb0" : (shelfPc.modelData.waking ? Theme.primary : Qt.rgba(1, 1, 1, 0.25))
									border.width: 1.5
									border.color: "#10131c"

									SequentialAnimation on opacity {
										running: root.shown && !!shelfPc.modelData.waking
										loops: Animation.Infinite
										onRunningChanged: if (!running) shelfLamp.opacity = 1

										NumberAnimation {
											to: 0.3
											duration: 500
										}
										NumberAnimation {
											to: 1
											duration: 500
										}
									}
								}
							}

							Column {
								Layout.fillWidth: true
								spacing: 1

								StyledText {
									width: parent.width
									elide: Text.ElideRight
									text: shelfPc.modelData.name
									tone: "white"
									surface: "transparent"
									font.pixelSize: Theme.size.body
									font.weight: Font.DemiBold
								}

								StyledText {
									text: shelfPc.modelData.online ? (shelfPc.modelData.stream ? "Streams" : (shelfPc.modelData.session ? "Signed in" : "On")) : (shelfPc.modelData.waking ? "Waking" : "Asleep")
									tone: Qt.rgba(1, 1, 1, 0.5)
									surface: "transparent"
									font.pixelSize: Theme.size.tiny
								}
							}
						}

						MouseArea {
							id: shelfMouse

							anchors.fill: parent
							hoverEnabled: true
							cursorShape: Qt.PointingHandCursor
							onClicked: root.pick(shelfPc.index)
						}
					}
				}
			}

			// ── the keys ────────────────────────────────────────────────────
			Row {
				Layout.alignment: Qt.AlignHCenter
				Layout.topMargin: 20
				spacing: 18
				opacity: 0.55

				Repeater {
					model: [
						{ key: "Hold ⏻ / ↵", what: root.phase === "failed" ? "Try again" : (root.ready ? "Connect" : "Wake"), shown: !root.travelling && root.phase !== "done" },
						{ key: "1 2 3", what: "How far", shown: !root.travelling },
						{ key: "← →", what: "PC", shown: root.pcs.length > 1 },
						{ key: "Esc", what: "Close" }
					].filter(hint => hint.shown !== false)

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

			// ── this PC: Sunshine's login, so others can pair without anyone here ──
			RowLayout {
				Layout.alignment: Qt.AlignHCenter
				Layout.topMargin: 18
				spacing: 8
				visible: !!Remote.local?.sunshine && !Remote.local?.creds

				StyledText {
					text: "Sunshine login of this PC"
					tone: Qt.rgba(1, 1, 1, 0.6)
					surface: "transparent"
					font.pixelSize: Theme.size.small
				}

				Field {
					id: credUser

					Layout.preferredWidth: 130
					placeholder: "User"
				}

				Field {
					id: credPass

					Layout.preferredWidth: 150
					placeholder: "Password"
					password: true
					onAccepted: credSave.clicked()
				}

				TextButton {
					id: credSave

					text: credError.text !== "" ? "Again" : "Save"
					icon: "key_variant"
					enabled: credUser.text !== "" && credPass.text !== ""
					onClicked: Remote.setCreds(credUser.text, credPass.text, error => {
						credError.text = error;
						if (!error) credPass.text = "";
					})
				}

				StyledText {
					id: credError

					visible: text !== ""
					text: ""
					tone: Theme.danger
					surface: "transparent"
					font.pixelSize: Theme.size.small
				}
			}
		}

		// nothing to show
		Column {
			anchors.centerIn: parent
			spacing: 14
			visible: root.pc === null

			Spinner {
				anchors.horizontalCenter: parent.horizontalCenter
				visible: Remote.active && !Remote.loaded
				width: 30
				height: 30
				color: "white"
			}

			Glyph {
				anchors.horizontalCenter: parent.horizontalCenter
				visible: !Remote.active || Remote.loaded
				icon: "weather_night"
				size: 54
				color: Qt.rgba(1, 1, 1, 0.6)
				surface: "transparent"
			}

			StyledText {
				anchors.horizontalCenter: parent.horizontalCenter
				visible: !Remote.active || Remote.loaded
				text: !Remote.active ? "netcore is not connected" : (Remote.error !== "" ? Remote.error : "No other PCs")
				tone: "white"
				surface: "transparent"
				font.pixelSize: Theme.size.heading
				font.weight: Font.DemiBold
			}
		}
	}
}
