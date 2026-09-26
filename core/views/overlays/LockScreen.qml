pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pam
import Quickshell.Wayland
import qs.style.theme
import qs.core.services
import qs.style.widgets

// Session lock. Wallpaper frame blurred behind a large clock; the password
// pill holds a bar that fills up per keystroke, shakes on a wrong password
// and glows while checking. PAM password + fprintd, screen sleep after idle.
Scope {
	id: root

	property bool enableFingerprint: Host.has("fingerprint")
	property int maxFingerprintTries: 5
	property int screenSleepDelay: 100000

	property bool locked: false

	readonly property string wallpaperFramePath: `${Quickshell.env("HOME")}/.local/state/quickshell-theme/current/frame.png`
	readonly property string wallpaperFrameSource: `file://${root.wallpaperFramePath}?v=${root.wallpaperFrameSerial}`
	readonly property string statusText: {
		if (root.passwordActive) return "Checking…";
		if (root.fingerprintActive) return "Touch the fingerprint sensor";
		if (root.authState === "fingerprint-failed") return root.authMessage || "Fingerprint not recognized";
		if (root.authState === "fingerprint-error") return root.authMessage || "Fingerprint error";
		if (root.authState === "fingerprint-max") return root.authMessage || "Use password";
		if (root.authState === "failed") return root.authMessage || "Incorrect password";
		if (root.authState === "error") return root.authMessage || "Authentication error";
		if (root.authState === "max") return root.authMessage || "Too many attempts";
		return "";
	}
	readonly property bool failing: ["failed", "error", "max", "fingerprint-failed", "fingerprint-error", "fingerprint-max"].includes(root.authState)
	readonly property bool busy: root.locked || root.passwordActive || root.fingerprintActive

	property int wallpaperFrameSerial: 0
	property var lockNow: new Date()
	property string passwordSubmission: ""
	property string authState: ""
	property string authMessage: ""
	property bool passwordActive: false
	property bool fingerprintActive: false
	property bool fingerprintAvailable: false
	property int fingerprintTries: 0
	property int fingerprintErrorTries: 0
	property bool fingerprintSuspended: false
	property real fingerprintStartedAt: 0
	property bool screensDimmed: false
	property bool screensPoweredOff: false

	signal clearPasswordInput
	signal focusPasswordInput
	signal shake

	onLockedChanged: {
		Session.locked = root.locked;
		if (locked) {
			focusDelay.restart();
			screenSleepTimer.restart();
		} else {
			focusDelay.stop();
			screenSleepTimer.stop();
			screenPowerOffTimer.stop();
			authMessageReset.stop();
			if (passwordPam.active) passwordPam.abort();
			if (fingerprintPam.active) fingerprintPam.abort();
			fingerprintRetry.stop();
			fingerprintWakeRetry.stop();
			fingerprintAvailableRetry.stop();
			fingerprintAvailableCheck.running = false;
			root.fingerprintSuspended = false;
			root.wakeScreens();
			root.passwordSubmission = "";
			root.authState = "";
			root.authMessage = "";
			root.clearPasswordInput();
		}
	}

	Connections {
		target: Session
		function onLockRequested() {
			root.lock();
		}
	}

	function primeForLock() {
		authMessageReset.stop();
		root.lockNow = new Date();
		root.passwordSubmission = "";
		root.authState = "";
		root.authMessage = "";
		root.fingerprintAvailable = false;
		root.fingerprintTries = 0;
		root.fingerprintErrorTries = 0;
		root.clearPasswordInput();
		root.wallpaperFrameSerial = Date.now();
	}

	function startFingerprintCheck() {
		if (!root.locked || !root.enableFingerprint) return;
		root.fingerprintTries = 0;
		root.fingerprintErrorTries = 0;
		fingerprintAvailableCheck.running = true;
	}

	function startFingerprintAuth() {
		if (!root.locked || !root.enableFingerprint || !root.fingerprintAvailable || fingerprintPam.active) return;
		fingerprintPam.start();
	}

	function dimAndPowerOffScreens() {
		if (!root.locked) return;
		root.screensDimmed = true;
		screenPowerOffTimer.restart();
	}

	function powerOffScreens() {
		if (!root.locked) return;
		root.fingerprintSuspended = true;
		fingerprintRetry.stop();
		if (fingerprintPam.active) fingerprintPam.abort();
		root.screensPoweredOff = true;
		Quickshell.execDetached(["niri", "msg", "action", "power-off-monitors"]);
	}

	function wakeScreens() {
		const shouldPowerOn = root.screensPoweredOff;
		root.screensDimmed = false;
		root.screensPoweredOff = false;
		if (shouldPowerOn) {
			Quickshell.execDetached(["niri", "msg", "action", "power-on-monitors"]);
			if (root.locked && root.enableFingerprint) fingerprintWakeRetry.restart();
		}
	}

	function resetScreenSleepTimer() {
		if (!root.locked) return;
		root.wakeScreens();
		screenPowerOffTimer.stop();
		screenSleepTimer.restart();
	}

	function lock() {
		if (root.busy) {
			root.focusPasswordInput();
			return false;
		}
		Popups.closeAll();
		root.primeForLock();
		root.locked = true;
		root.startFingerprintCheck();
		return true;
	}

	function unlock() {
		root.locked = false;
	}

	function submitPassword(password) {
		if (!root.locked || passwordPam.active || root.authState === "max" || password.length === 0) return;
		root.passwordSubmission = password;
		root.authState = "checking";
		root.authMessage = "";
		passwordPam.start();
	}

	Timer {
		id: focusDelay
		interval: 60
		onTriggered: root.focusPasswordInput()
	}

	Variants {
		model: Quickshell.screens

		PanelWindow {
			id: lockWindow

			required property var modelData
			property real reveal: root.locked ? 1 : 0

			screen: modelData
			anchors {
				left: true
				right: true
				top: true
				bottom: true
			}
			exclusiveZone: 0
			visible: root.locked
			color: Theme.bg
			WlrLayershell.namespace: "shell-lock"
			WlrLayershell.exclusionMode: ExclusionMode.Ignore
			WlrLayershell.layer: WlrLayer.Overlay
			WlrLayershell.keyboardFocus: root.locked ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

			Behavior on reveal {
				NumberAnimation {
					duration: Motion.extraLong
					easing.type: Easing.BezierSpline
					easing.bezierCurve: Motion.decel
				}
			}

			ShortcutInhibitor {
				window: lockWindow
				enabled: root.locked
			}

			onVisibleChanged: if (visible) root.focusPasswordInput()

			Image {
				id: wallpaper

				anchors.fill: parent
				source: root.wallpaperFrameSource
				fillMode: Image.PreserveAspectCrop
				cache: false
				visible: false
			}

			MultiEffect {
				anchors.fill: parent
				source: wallpaper
				blurEnabled: true
				blurMax: 64
				blur: 0.2 + 0.8 * lockWindow.reveal
				brightness: -0.12 * lockWindow.reveal
				saturation: 0.1
				opacity: Math.min(1, lockWindow.reveal * 1.4)
			}

			Rectangle {
				anchors.fill: parent
				gradient: Gradient {
					GradientStop { position: 0; color: Qt.alpha(Theme.bg, 0.15) }
					GradientStop { position: 1; color: Qt.alpha(Theme.bg, 0.7) }
				}
				opacity: lockWindow.reveal
			}

			Rectangle {
				anchors.fill: parent
				color: "black"
				z: 100
				opacity: root.screensDimmed ? 1 : 0

				Behavior on opacity {
					NumberAnimation {
						duration: 1200
						easing.type: Easing.InOutCubic
					}
				}
			}

			MouseArea {
				anchors.fill: parent
				hoverEnabled: true
				cursorShape: Qt.BlankCursor
				onClicked: {
					root.resetScreenSleepTimer();
					root.focusPasswordInput();
				}
				onPositionChanged: root.resetScreenSleepTimer()
			}

			// clock
			Column {
				anchors.horizontalCenter: parent.horizontalCenter
				y: parent.height * 0.2 + 30 * (1 - lockWindow.reveal)
				opacity: lockWindow.reveal
				spacing: 0

				StyledText {
					anchors.horizontalCenter: parent.horizontalCenter
					text: Qt.formatDateTime(root.lockNow, "HH:mm")
					tabular: true
					tone: "white"
					surface: "transparent"
					font.pixelSize: Math.round(lockWindow.height * 0.15)
					font.weight: Font.Bold
					font.letterSpacing: -4
				}

				StyledText {
					anchors.horizontalCenter: parent.horizontalCenter
					text: Qt.formatDateTime(root.lockNow, "dddd, d. MMMM")
					tone: Qt.rgba(1, 1, 1, 0.8)
					surface: "transparent"
					font.pixelSize: Math.round(lockWindow.height * 0.024)
					font.weight: Font.Medium
				}
			}

			// password
			Column {
				id: auth

				anchors.horizontalCenter: parent.horizontalCenter
				y: parent.height * 0.62 + 40 * (1 - lockWindow.reveal)
				opacity: lockWindow.reveal
				spacing: 16

				Rectangle {
					id: pill

					property real shakeX: 0
					readonly property int count: passwordInput.text.length

					anchors.horizontalCenter: parent.horizontalCenter
					width: 320
					height: 58
					radius: 29
					color: Qt.alpha(Theme.bg, 0.72)
					border.width: 2
					border.color: root.failing ? Theme.danger : (root.passwordActive ? Theme.primary : (passwordInput.activeFocus ? Qt.alpha(Theme.primary, 0.6) : Qt.rgba(1, 1, 1, 0.12)))

					transform: Translate {
						x: pill.shakeX
					}

					Behavior on border.color {
						ColorAnim {}
					}

					SequentialAnimation {
						id: shakeAnim

						NumberAnimation { target: pill; property: "shakeX"; to: -16; duration: 50 }
						NumberAnimation { target: pill; property: "shakeX"; to: 13; duration: 70 }
						NumberAnimation { target: pill; property: "shakeX"; to: -9; duration: 70 }
						NumberAnimation { target: pill; property: "shakeX"; to: 5; duration: 70 }
						NumberAnimation { target: pill; property: "shakeX"; to: 0; duration: 90 }
					}

					Connections {
						target: root
						function onShake() {
							shakeAnim.restart();
						}
					}

					Glyph {
						id: lockGlyph

						x: 20
						anchors.verticalCenter: parent.verticalCenter
						icon: root.fingerprintActive ? "fingerprint" : (root.passwordActive ? "lock_outline" : "lock")
						size: 20
						color: root.failing ? Theme.danger : Theme.primary

						SequentialAnimation on opacity {
							running: root.fingerprintActive || root.passwordActive
							loops: Animation.Infinite
							onRunningChanged: if (!running) lockGlyph.opacity = 1
							NumberAnimation { to: 0.35; duration: 600; easing.type: Easing.InOutSine }
							NumberAnimation { to: 1; duration: 600; easing.type: Easing.InOutSine }
						}
					}

					StyledText {
						anchors.centerIn: parent
						visible: pill.count === 0 && !root.passwordActive
						text: Words.of("lock.password", "Password")
						tone: Qt.rgba(1, 1, 1, 0.5)
						font.pixelSize: Theme.size.title
					}

					// fills up while typing, like the login screen; a light sweeps
					// across it while PAM checks the password
					Item {
						id: meter

						readonly property real level: Math.min(1, pill.count / 12)

						anchors.centerIn: parent
						width: 200
						height: 5
						visible: pill.count > 0 || root.passwordActive

						Rectangle {
							anchors.fill: parent
							radius: height / 2
							color: Qt.rgba(1, 1, 1, 0.16)
						}

						Rectangle {
							id: fill

							width: Math.max(parent.height, parent.width * (root.passwordActive ? 1 : meter.level))
							height: parent.height
							radius: height / 2
							color: root.failing ? Theme.danger : Theme.primary
							clip: true

							Behavior on width {
								SpatialAnim {
									duration: Motion.medium
								}
							}
							Behavior on color {
								ColorAnim {}
							}

							Rectangle {
								id: sweep

								width: 60
								height: parent.height
								x: -width
								gradient: Gradient {
									orientation: Gradient.Horizontal
									GradientStop { position: 0; color: Qt.rgba(1, 1, 1, 0) }
									GradientStop { position: 0.5; color: Qt.rgba(1, 1, 1, 0.7) }
									GradientStop { position: 1; color: Qt.rgba(1, 1, 1, 0) }
								}

								NumberAnimation on x {
									running: root.passwordActive
									loops: Animation.Infinite
									from: -sweep.width
									to: meter.width
									duration: 900
									easing.type: Easing.InOutSine
									onRunningChanged: if (!running) sweep.x = -sweep.width
								}
							}
						}

						// a soft tick at the fill edge on every keystroke
						Rectangle {
							x: fill.width - width / 2
							anchors.verticalCenter: parent.verticalCenter
							width: 11
							height: 11
							radius: 5.5
							color: fill.color
							visible: pill.count > 0 && !root.passwordActive
							scale: 1

							Behavior on x {
								SpatialAnim {
									duration: Motion.medium
								}
							}

							Connections {
								target: pill
								function onCountChanged() {
									if (pill.count > 0) bump.restart();
								}
							}

							SequentialAnimation on scale {
								id: bump

								running: false
								NumberAnimation { to: 1.45; duration: 70; easing.type: Easing.OutQuad }
								NumberAnimation { to: 1; duration: Motion.medium; easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.spatialFast }
							}
						}
					}

					TextInput {
						id: passwordInput

						anchors.fill: parent
						opacity: 0
						echoMode: TextInput.Password
						enabled: !passwordPam.active && root.authState !== "max"
						focus: root.locked
						cursorVisible: false

						onTextChanged: if (activeFocus) root.resetScreenSleepTimer()
						Keys.onReturnPressed: event => {
							event.accepted = true;
							root.submitPassword(text);
						}
						Keys.onEnterPressed: event => {
							event.accepted = true;
							root.submitPassword(text);
						}
						Keys.onEscapePressed: {
							text = "";
							root.authState = "";
							root.authMessage = "";
						}
						Keys.onPressed: root.resetScreenSleepTimer()

						Connections {
							target: root
							function onClearPasswordInput() {
								passwordInput.text = "";
							}
							function onFocusPasswordInput() {
								if (root.locked) passwordInput.forceActiveFocus();
							}
						}
					}
				}

				StyledText {
					anchors.horizontalCenter: parent.horizontalCenter
					height: 20
					text: root.statusText
					tone: root.failing ? Theme.danger : Qt.rgba(1, 1, 1, 0.75)
					surface: "transparent"
					font.pixelSize: Theme.size.body
					font.weight: Font.DemiBold
					opacity: text === "" ? 0 : 1

					Behavior on opacity {
						Anim {
							duration: Motion.short
						}
					}
				}
			}

			Row {
				anchors.horizontalCenter: parent.horizontalCenter
				anchors.bottom: parent.bottom
				anchors.bottomMargin: 36
				opacity: lockWindow.reveal * 0.8
				spacing: 18
				visible: Media.hasPlayer && Media.title !== ""

				Glyph {
					anchors.verticalCenter: parent.verticalCenter
					icon: Media.playing ? "music_note" : "pause"
					size: 16
					color: "white"
					surface: "transparent"
				}

				StyledText {
					anchors.verticalCenter: parent.verticalCenter
					width: Math.min(implicitWidth, 420)
					text: Media.barText || Media.title
					tone: "white"
					surface: "transparent"
					font.pixelSize: Theme.size.label
				}
			}
		}
	}

	PamContext {
		id: fingerprintPam

		config: "fprint"
		configDirectory: Quickshell.shellDir + "/core/pam"
		onActiveChanged: {
			root.fingerprintActive = active;
			if (active) root.fingerprintStartedAt = Date.now();
		}
		onCompleted: result => {
			if (!root.locked || !root.fingerprintAvailable || root.fingerprintSuspended) return;
			if (result === PamResult.Success) {
				root.authState = "";
				root.authMessage = "";
				root.unlock();
				return;
			}
			if (result === PamResult.MaxTries || result === PamResult.Failed) {
				root.fingerprintTries++;
				if (root.fingerprintTries < root.maxFingerprintTries) {
					root.authState = "fingerprint-failed";
					root.authMessage = "Fingerprint not recognized";
					authMessageReset.restart();
					fingerprintRetry.interval = 800;
					fingerprintRetry.restart();
				} else {
					root.authState = "fingerprint-max";
					root.authMessage = "Fingerprint disabled. Use password.";
					authMessageReset.restart();
				}
				root.shake();
				return;
			}
			// The Elan sensor gives up after ~10 s without a finger and reports
			// an error. That is not a failure: listen again right away, forever.
			if (Date.now() - root.fingerprintStartedAt > 5000) {
				root.fingerprintErrorTries = 0;
				fingerprintRetry.interval = 150;
				fingerprintRetry.restart();
				return;
			}
			// Real errors (reader busy, just resumed, fprintd restarting): back
			// off and keep trying instead of giving up for the rest of the lock.
			root.fingerprintErrorTries++;
			if (root.fingerprintErrorTries >= 3) {
				root.authState = "fingerprint-error";
				root.authMessage = "Fingerprint reader not responding";
				authMessageReset.restart();
			}
			fingerprintRetry.interval = root.fingerprintErrorTries < 3 ? 1000 : 5000;
			fingerprintRetry.restart();
		}
	}

	PamContext {
		id: passwordPam

		config: "passwd"
		configDirectory: Quickshell.shellDir + "/core/pam"
		onActiveChanged: root.passwordActive = active
		onMessageChanged: if (message !== "") root.authMessage = message
		onResponseRequiredChanged: {
			if (!responseRequired) return;
			respond(root.passwordSubmission);
			root.passwordSubmission = "";
		}
		onCompleted: result => {
			if (result === PamResult.Success) {
				root.authState = "";
				root.authMessage = "";
				root.unlock();
				return;
			}
			if (result === PamResult.MaxTries) {
				root.authState = "max";
				root.authMessage = passwordPam.message || "Too many attempts";
			} else if (result === PamResult.Error) {
				root.authState = "error";
				root.authMessage = passwordPam.message || "Authentication error";
			} else {
				root.authState = "failed";
				root.authMessage = "Incorrect password";
				Haptics.play("wrongPassword");
			}
			root.shake();
			root.clearPasswordInput();
			root.focusPasswordInput();
			authMessageReset.restart();
		}
	}

	Process {
		id: fingerprintAvailableCheck
		command: ["sh", "-lc", "fprintd-list \"$USER\""]
		onExited: exitCode => {
			root.fingerprintAvailable = exitCode === 0;
			if (root.fingerprintAvailable) root.startFingerprintAuth();
			else if (root.locked && root.enableFingerprint) fingerprintAvailableRetry.restart();
		}
	}

	Timer {
		id: fingerprintRetry
		interval: 800
		onTriggered: root.startFingerprintAuth()
	}

	// fprintd may not answer right after boot or resume; ask again
	Timer {
		id: fingerprintAvailableRetry
		interval: 3000
		onTriggered: if (root.locked && !root.fingerprintAvailable) root.startFingerprintCheck()
	}

	Timer {
		id: fingerprintWakeRetry
		interval: 350
		onTriggered: {
			root.fingerprintSuspended = false;
			if (root.fingerprintAvailable) root.startFingerprintAuth();
			else root.startFingerprintCheck();
		}
	}

	Timer {
		id: screenSleepTimer
		interval: root.screenSleepDelay
		onTriggered: root.dimAndPowerOffScreens()
	}

	Timer {
		id: screenPowerOffTimer
		interval: 1200
		onTriggered: root.powerOffScreens()
	}

	Timer {
		id: authMessageReset
		interval: 3600
		onTriggered: {
			if (root.authState !== "max") {
				root.authState = "";
				root.authMessage = "";
			}
		}
	}

	Timer {
		running: root.locked
		repeat: true
		interval: 1000
		onTriggered: root.lockNow = new Date()
	}
}
