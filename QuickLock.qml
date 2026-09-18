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

			Column {
				id: lockContent

				width: Math.min(440, Math.max(280, lockWindow.width - 48))
				x: Math.round((lockWindow.width - width) / 2)
				y: Math.round((lockWindow.height - implicitHeight) / 2)
				spacing: Bio.s5
				opacity: lockWindow.reveal
				scale: 0.98 + 0.02 * lockWindow.reveal
				transformOrigin: Item.Center

				BioSigil {
					anchors.horizontalCenter: parent.horizontalCenter
					width: 92
					height: 92
					seed: 13
					lineColor: Qt.alpha(Bio.bone, 0.8)
					weight: Bio.rib
				}

				BioText {
					role: "specimen"
					width: parent.width
					text: Qt.formatDateTime(root.lockNow, "HH:mm")
					horizontalAlignment: Text.AlignHCenter
					font.pixelSize: 84
				}

				BioText {
					role: "label"
					tone: "muted"
					width: parent.width
					text: Qt.formatDateTime(root.lockNow, "dddd, dd MMMM yyyy")
					horizontalAlignment: Text.AlignHCenter
					font.pixelSize: 13
				}

				// The seal. Nothing here shows what was typed — a run of
				// vertebrae grows along the chamber instead, one per character,
				// and the ring on the left lights while PAM is thinking.
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
					height: 58

					SequentialAnimation {
						id: typePulseAnim

						NumberAnimation {
							target: passwordBox
							property: "typePulse"
							to: 1
							duration: 60
							easing.type: Easing.OutCubic
						}

						NumberAnimation {
							target: passwordBox
							property: "typePulse"
							to: 0
							duration: 280
							easing.type: Easing.OutCubic
						}
					}

					BioSurface {
						anchors.fill: parent
						variant: "plate"
						washTop: Bio.membrane
						washBottom: Bio.membraneDeep
						lineColor: root.authState === "failed" || root.authState === "max"
							? Qt.alpha(Bio.necrosis, 0.6)
							: Bio.boneDim
						liveColor: root.authState === "failed" || root.authState === "max"
							? Bio.necrosis
							: Bio.organ
						haloStrength: 0.20
						intensity: Math.max(passwordBox.typePulse,
							passwordPam.active ? 0.8 : (passwordBox.inputLength > 0 ? 0.45 : 0))
						padding: Bio.s4

						BioRing {
							id: sealRing
							anchors.left: parent.left
							anchors.verticalCenter: parent.verticalCenter
							width: 30
							height: 30
							seed: 2
							lineColor: Bio.boneFaint
							liveColor: passwordPam.active ? Bio.organ : Bio.bone
							intensity: passwordPam.active ? 1 : passwordBox.typePulse

							QQCImpl.IconImage {
								anchors.centerIn: parent
								width: 14
								height: 14
								source: "/usr/share/icons/Adwaita/symbolic/status/system-lock-screen-symbolic.svg"
								sourceSize: Qt.size(width, height)
								color: passwordPam.active ? Bio.organ : Bio.text
							}
						}

						BioText {
							anchors.left: sealRing.right
							anchors.leftMargin: Bio.s4
							anchors.verticalCenter: parent.verticalCenter
							role: "label"
							tone: "faint"
							text: passwordPam.active ? "Testing" : "Sealed"
							visible: passwordBox.inputLength === 0 || passwordPam.active
						}

						// One vertebra per character, growing away from the ring.
						Row {
							id: inputTrace
							anchors.left: sealRing.right
							anchors.leftMargin: Bio.s4
							anchors.right: parent.right
							anchors.verticalCenter: parent.verticalCenter
							spacing: Bio.s2
							visible: passwordBox.inputLength > 0 && !passwordPam.active

							Repeater {
								model: Math.min(passwordBox.inputLength, 16)

								delegate: Rectangle {
									required property int index

									anchors.verticalCenter: parent?.verticalCenter ?? undefined
									width: Bio.nodule * 2
									height: Bio.nodule * 2 * (index === passwordBox.inputLength - 1
										? 1 + passwordBox.typePulse * 0.5 : 1)
									radius: width / 2
									color: Bio.organ
									opacity: 0.55 + 0.45 * (index / Math.max(1, passwordBox.inputLength))
								}
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

				BioText {
					role: "label"
					width: parent.width
					height: 22
					tone: root.authState === "checking" ? "muted" : "alert"
					text: root.statusText
					horizontalAlignment: Text.AlignHCenter
					verticalAlignment: Text.AlignVCenter
					opacity: text === "" ? 0 : 1

					Behavior on opacity {
						NumberAnimation { duration: Bio.grow }
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
