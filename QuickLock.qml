pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Controls.impl as QQCImpl
import QtMultimedia
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pam
import Quickshell.Wayland
import "components"
import "components/ArcInk.js" as Ink

Scope {
	id: root

	required property color foreground
	required property color background
	property color primary: foreground
	property color danger: "#d95c5c"

	property bool locked: false

	readonly property string wallpaperMediaType: String(mediaTypeFile.text()).trim()
	readonly property string wallpaperMediaPath: String(mediaSourceFile.text()).trim()
	readonly property string wallpaperMediaSource: root.wallpaperMediaPath === "" ? "" : root.fileUrl(root.wallpaperMediaPath)
	readonly property string wallpaperImageSource: root.wallpaperMediaSource === "" ? "" : `${root.wallpaperMediaSource}?v=${root.wallpaperFrameSerial}`
	readonly property string statusText: {
		if (passwordPam.active) return "Checking...";
		if (root.authState === "failed") return root.authMessage || "Incorrect password";
		if (root.authState === "error") return root.authMessage || "Authentication error";
		if (root.authState === "max") return root.authMessage || "Too many attempts";
		return "";
	}
	readonly property bool busy: root.locked || passwordPam.active

	property int wallpaperFrameSerial: 0
	property var lockNow: new Date()
	property string passwordSubmission: ""
	property string authState: ""
	property string authMessage: ""

	signal clearPasswordInput
	signal focusPasswordInput

	FileView {
		id: mediaTypeFile
		path: "/home/lu/.local/state/quickshell-theme/current/media-type"
		blockLoading: true
	}

	FileView {
		id: mediaSourceFile
		path: "/home/lu/.local/state/quickshell-theme/current/media-source"
		blockLoading: true
	}

	onLockedChanged: {
		if (locked) {
			focusDelay.restart();
		} else {
			focusDelay.stop();
			authMessageReset.stop();
			if (passwordPam.active) passwordPam.abort();
			root.passwordSubmission = "";
			root.authState = "";
			root.authMessage = "";
			root.clearPasswordInput();
		}
	}

	function fileUrl(path) {
		return Qt.resolvedUrl(path);
	}

	function resolveWallpaper() {
		root.wallpaperFrameSerial = Date.now();
	}

	function primeForLock() {
		authMessageReset.stop();
		root.lockNow = new Date();
		root.passwordSubmission = "";
		root.authState = "";
		root.authMessage = "";
		root.clearPasswordInput();
		root.resolveWallpaper();
	}

	function lock() {
		if (root.busy) {
			root.focusPasswordInput();
			return false;
		}

		root.primeForLock();
		root.locked = true;
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
		repeat: false
		onTriggered: root.focusPasswordInput()
	}

	Variants {
		model: Quickshell.screens

		PanelWindow {
			id: lockWindow

			required property var modelData

			screen: modelData

			anchors {
				left: true
				right: true
				top: true
				bottom: true
			}

			property real reveal: root.locked ? 1 : 0

			exclusiveZone: 0
			visible: root.locked
			color: root.background
			WlrLayershell.exclusionMode: ExclusionMode.Ignore
			WlrLayershell.layer: WlrLayer.Overlay
			WlrLayershell.keyboardFocus: root.locked ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

			Behavior on reveal {
				NumberAnimation {
					duration: Motion.large
					easing.type: ThemeEngine.standardEasing
				}
			}

			ShortcutInhibitor {
				window: lockWindow
				enabled: root.locked
			}

			onVisibleChanged: {
				if (visible) root.focusPasswordInput();
			}

			Image {
				anchors.fill: parent
				source: root.wallpaperMediaType === "image" ? root.wallpaperImageSource : ""
				visible: root.wallpaperMediaType === "image"
				fillMode: Image.PreserveAspectCrop
				asynchronous: false
				cache: false
				smooth: true
				mipmap: true
				opacity: lockWindow.reveal
			}

			VideoOutput {
				id: wallpaperVideo

				anchors.fill: parent
				visible: root.wallpaperMediaType === "video"
				fillMode: VideoOutput.PreserveAspectCrop
				opacity: lockWindow.reveal
			}

			MediaPlayer {
				id: wallpaperPlayer

				source: root.wallpaperMediaType === "video" ? root.wallpaperMediaSource : ""
				videoOutput: wallpaperVideo
				loops: MediaPlayer.Infinite

				onSourceChanged: {
					if (root.locked && root.wallpaperMediaType === "video")
						play();
					else
						stop();
				}

				onMediaStatusChanged: {
					if (root.locked && root.wallpaperMediaType === "video"
							&& (mediaStatus === MediaPlayer.LoadedMedia
								|| mediaStatus === MediaPlayer.BufferedMedia))
						play();
				}
			}

			Connections {
				target: root

				function onLockedChanged(): void {
					if (root.locked && root.wallpaperMediaType === "video")
						wallpaperPlayer.play();
					else
						wallpaperPlayer.stop();
				}
			}

			MouseArea {
				anchors.fill: parent
				cursorShape: Qt.BlankCursor
				onClicked: root.focusPasswordInput()
			}

			// The night that falls over the desktop when it is sealed. Thin
			// engraving over a bright wallpaper is where a style like this
			// fails, so the ward gets a ground to be cut into rather than a
			// higher line opacity.
			Rectangle {
				anchors.fill: parent
				color: Arc.depth
				opacity: 0.62 * lockWindow.reveal
			}

			// Sealed, the desktop is a ward.
			//
			// Not a clock in a corner with a password box under it: a circle is
			// inscribed in the middle of the screen, the hour stands inside it,
			// and what you type lights the runes around its rim one at a time,
			// clockwise, without ever showing a character. Locking draws the
			// circle rather than fading it in; a wrong word makes the whole ward
			// shudder and go out.
			Item {
				id: ward

				readonly property real span: Math.min(460, Math.min(lockWindow.width, lockWindow.height) * 0.52)
				readonly property int slots: 16

				width: ward.span
				height: ward.span
				anchors.centerIn: parent
				anchors.verticalCenterOffset: -Arc.s7
				opacity: lockWindow.reveal

				// The inscription: the circle is drawn, once, at the speed a
				// hand draws it.
				property real inscribe: 0

				NumberAnimation on inscribe {
					id: inscribeAnim
					running: root.locked
					from: 0
					to: 1
					duration: 1100
					easing.type: Easing.Bezier
					easing.bezierCurve: Arc.curveInk
				}

				// The shudder: a wrong word is answered by the ward itself, as
				// a damped oscillation rather than a canned shake.
				property real shudder: 0
				property real shudderVelocity: 0

				Connections {
					target: root
					function onAuthStateChanged() {
						if (root.authState === "failed" || root.authState === "max") {
							ward.shudderVelocity = 5.5;
							shudderClock.running = true;
						}
					}
				}

				Timer {
					id: shudderClock
					interval: 16
					repeat: true
					onTriggered: {
						ward.shudderVelocity += -ward.shudder * 0.55;
						ward.shudderVelocity *= 0.86;
						ward.shudder += ward.shudderVelocity;
						if (Math.abs(ward.shudder) < 0.06 && Math.abs(ward.shudderVelocity) < 0.06) {
							ward.shudder = 0;
							shudderClock.running = false;
						}
					}
				}

				transform: Translate {
					x: ward.shudder
				}

				// The dark the ward is inscribed on: a disc of night with a soft
				// edge, so the circle has something to be cut into wherever the
				// wallpaper happens to be bright.
				ArcHalo {
					anchors.centerIn: parent
					width: parent.width * 2.1
					height: parent.height * 2.1
					color: Arc.depth
					strength: 0.94 * ward.inscribe
					spread: 0.34
					falloff: 2.8
				}

				ArcHalo {
					anchors.centerIn: parent
					width: parent.width * 1.5
					height: parent.height * 1.5
					color: root.authState === "failed" || root.authState === "max" ? Arc.bane : Arc.aether
					strength: 0.22 * ward.inscribe
					spread: 0.4
					flicker: true
				}

				// The ward, cut once: two rings, a graduated limb and sixteen
				// empty rune slots waiting to be filled.
				Canvas {
					id: wardCanvas
					anchors.fill: parent
					renderStrategy: Canvas.Cooperative

					Connections {
						target: Arc
						function onGoldChanged() { wardCanvas.requestPaint(); }
					}

					onPaint: {
						const ctx = getContext("2d");
						ctx.reset();
						const cx = width / 2, cy = height / 2;
						const outer = Math.min(width, height) / 2 - 3;
						if (outer < 20) return;

						Ink.ring(ctx, cx, cy, outer, Arc.rule * 1.4, Qt.alpha(Arc.gold, 0.66), 1);
						Ink.ring(ctx, cx, cy, outer - 28, Arc.ruleThin, Qt.alpha(Arc.gold, 0.5), 1);
						Ink.ring(ctx, cx, cy, outer * 0.60, Arc.ruleThin, Qt.alpha(Arc.gold, 0.26), 1);
						Ink.graduations(ctx, cx, cy, outer - 4, 96, 4, 9, 8,
							Arc.ruleThin, Qt.alpha(Arc.gold, 0.45), 1);

						for (let index = 0; index < ward.slots; index++) {
							const angle = -Math.PI / 2 + Math.PI * 2 * index / ward.slots;
							Ink.rune(ctx, cx + Math.cos(angle) * (outer - 14),
								cy + Math.sin(angle) * (outer - 14), 16,
								index * 5 + 3, Arc.rule, Qt.alpha(Arc.gold, 0.45));
						}
					}
				}

				// The circle being drawn: the arc that sweeps round as the ward
				// is inscribed, and turns by itself while the word is tested.
				ArcDial {
					id: inscription
					anchors.fill: parent
					weight: Arc.ruleThin * 0.9
					lineColor: "transparent"
					liveColor: root.authState === "failed" || root.authState === "max" ? Arc.bane : Arc.aether
					beading: false
					progress: passwordPam.active ? 0.22 : ward.inscribe

					// While the word is being tested the arc turns on its own —
					// the one thing on a locked screen that moves.
					RotationAnimation on rotation {
						running: passwordPam.active
						loops: Animation.Infinite
						from: 0
						to: 360
						duration: 1600
					}
				}

				// What has been said: one rune lit per character, clockwise,
				// and nothing else about it shown anywhere.
				Canvas {
					id: spoken
					anchors.fill: parent
					renderStrategy: Canvas.Cooperative

					readonly property int said: Math.min(passwordBox.inputLength, ward.slots)
					readonly property real pulse: passwordBox.typePulse

					onSaidChanged: requestPaint()
					onPulseChanged: requestPaint()

					onPaint: {
						const ctx = getContext("2d");
						ctx.reset();
						const cx = width / 2, cy = height / 2;
						const outer = Math.min(width, height) / 2 - 3;
						if (outer < 20) return;
						for (let index = 0; index < spoken.said; index++) {
							const angle = -Math.PI / 2 + Math.PI * 2 * index / ward.slots;
							const newest = index === spoken.said - 1;
							const size = 15 * (newest ? 1 + spoken.pulse * 0.35 : 1);
							Ink.rune(ctx, cx + Math.cos(angle) * (outer - 13),
								cy + Math.sin(angle) * (outer - 13), size,
								index * 5 + 3, Arc.rule * (newest ? 1.35 : 1),
								newest ? Arc.aether : Qt.alpha(Arc.aether, 0.62));
						}
					}
				}

				// The hour, standing inside the ward.
				Column {
					anchors.centerIn: parent
					spacing: 0
					opacity: Math.max(0, (ward.inscribe - 0.45) / 0.55)

					ArcText {
						anchors.horizontalCenter: parent.horizontalCenter
						role: "display"
						font.pixelSize: 74
						font.letterSpacing: 1
						text: Qt.formatDateTime(root.lockNow, "HH:mm")
					}

					ArcText {
						anchors.horizontalCenter: parent.horizontalCenter
						role: "hand"
						tone: "aether"
						font.pixelSize: 17
						text: Arc.hourName(root.lockNow)
					}

					Item {
						width: 1
						height: Arc.s3
					}

					ArcText {
						anchors.horizontalCenter: parent.horizontalCenter
						role: "label"
						tone: "muted"
						font.pixelSize: 11
						text: Qt.formatDateTime(root.lockNow, "dddd, dd MMMM yyyy")
					}
				}
			}

			// The seal, under the ward: what state the word is in, and nothing
			// that could be read over a shoulder.
			Column {
				id: lockContent

				anchors.horizontalCenter: parent.horizontalCenter
				anchors.top: ward.bottom
				anchors.topMargin: Arc.s6
				width: Math.min(440, lockWindow.width - Arc.s8 * 2)
				spacing: Arc.s3
				opacity: Math.max(0, (ward.inscribe - 0.6) / 0.4) * lockWindow.reveal

				Item {
					id: passwordBox

					property int inputLength: 0
					property real inputLevel: 0
					property real typePulse: 0

					function syncLength(length) {
						inputLength = length;
						inputLevel = Math.min(1, length / 8);
					}

					function tick(length) {
						syncLength(length);
						typePulseAnim.restart();
					}

					width: parent.width
					height: 46

					SequentialAnimation {
						id: typePulseAnim

						NumberAnimation {
							target: passwordBox
							property: "typePulse"
							to: 1
							duration: 55
						}

						NumberAnimation {
							target: passwordBox
							property: "typePulse"
							to: 0
							duration: 280
							easing.type: Easing.Bezier
							easing.bezierCurve: Arc.curveKindle
						}
					}

					ArcLeaf {
						anchors.fill: parent
						variant: "plate"
						washTop: Arc.haze
						washBottom: Arc.hazeDeep
						lineColor: root.authState === "failed" || root.authState === "max"
							? Qt.alpha(Arc.bane, 0.6)
							: Arc.goldDim
						liveColor: root.authState === "failed" || root.authState === "max"
							? Arc.bane
							: Arc.aether
						haloStrength: 0.18
						intensity: Math.max(passwordBox.typePulse,
							passwordPam.active ? 0.8 : (passwordBox.inputLength > 0 ? 0.45 : 0))
						padding: Arc.s4

						Row {
							anchors.centerIn: parent
							spacing: Arc.s3

							ArcMark {
								anchors.verticalCenter: parent.verticalCenter
								width: 18
								height: 18
								glyph: "star"
								lineColor: passwordPam.active ? Arc.aether : Arc.goldDim
							}

							ArcText {
								anchors.verticalCenter: parent.verticalCenter
								role: "label"
								tone: passwordPam.active ? "aether" : "faint"
								text: passwordPam.active
									? "Testing the word"
									: passwordBox.inputLength > 0
										? "Speak on, then Return"
										: "Sealed"
							}
						}

						TextInput {
							id: passwordInput

							property int previousTextLength: 0

							anchors.fill: parent
							verticalAlignment: TextInput.AlignVCenter
							horizontalAlignment: TextInput.AlignHCenter
							color: "transparent"
							selectionColor: "transparent"
							selectedTextColor: "transparent"
							echoMode: TextInput.Password
							passwordMaskDelay: 0
							cursorVisible: false
							cursorDelegate: Item {
								visible: false
							}
							enabled: !passwordPam.active && root.authState !== "max"
							focus: root.locked
							font.pixelSize: 18
							clip: true

							onTextChanged: {
								if (activeFocus && text.length > previousTextLength) {
									passwordBox.tick(text.length);
								} else {
									passwordBox.syncLength(text.length);
								}
								previousTextLength = text.length;
							}

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

							Connections {
								function onClearPasswordInput(): void {
									passwordInput.text = "";
									passwordInput.previousTextLength = 0;
									passwordBox.syncLength(0);
								}

								function onFocusPasswordInput(): void {
									if (root.locked) passwordInput.forceActiveFocus();
								}

								target: root
							}

							MouseArea {
								anchors.fill: parent
								acceptedButtons: Qt.NoButton
								hoverEnabled: true
								cursorShape: Qt.BlankCursor
							}
						}
					}
				}

				ArcText {
					role: "label"
					width: parent.width
					height: 22
					tone: root.authState === "checking" ? "muted" : "alert"
					text: root.statusText
					horizontalAlignment: Text.AlignHCenter
					verticalAlignment: Text.AlignVCenter
					opacity: text === "" ? 0 : 1

					Behavior on opacity {
						NumberAnimation { duration: Arc.turn }
					}
				}
			}
		}
	}

	PamContext {
		id: passwordPam

		config: "passwd"
		configDirectory: Quickshell.shellDir + "/caelestia/assets/pam.d"

		onMessageChanged: {
			if (message !== "") root.authMessage = message;
		}

		onResponseRequiredChanged: {
			if (!responseRequired) return;
			respond(root.passwordSubmission);
			root.passwordSubmission = "";
			root.clearPasswordInput();
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
			}

			root.clearPasswordInput();
			root.focusPasswordInput();
			authMessageReset.restart();
		}
	}

	Timer {
		id: authMessageReset

		interval: 3600
		repeat: false
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
