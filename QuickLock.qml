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

	property alias locked: sessionLock.locked

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


    WlSessionLock {
        id: sessionLock
        WlSessionLockSurface {
            id: lockWindow
            property real reveal: root.locked ? 1 : 0
            color: Atelier.ink

			Behavior on reveal {
				NumberAnimation {
					duration: Motion.large
					easing.type: ThemeEngine.standardEasing
				}
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

				width: Math.min(420, Math.max(260, lockWindow.width - 48))
				x: Math.max(32, Math.round(lockWindow.width * 0.1))
				y: Math.round((lockWindow.height - implicitHeight) * 0.6)
				spacing: 18
				opacity: lockWindow.reveal
				scale: 0.98 + 0.02 * lockWindow.reveal
				transformOrigin: Item.Center

				AtelierText {
					width: parent.width
					color: Atelier.paper
					text: Qt.formatDateTime(root.lockNow, "HH:mm")
					horizontalAlignment: Text.AlignLeft
					font.family: Atelier.display
					display: true
    font.pixelSize: 104
					font.weight: Font.Normal
				}

				AtelierText {
					width: parent.width
					color: Qt.alpha(Atelier.paper, 0.76)
					text: Qt.formatDateTime(root.lockNow, "dddd, dd. MMMM yyyy")
					horizontalAlignment: Text.AlignLeft
					font.pixelSize: 16
					font.weight: Font.Medium
				}

				ThemedRectangle {
					id: passwordBox

					property int inputLength: 0
					property real inputLevel: 0
					property real typePulse: 0
					property real typeSweep: 1

					function syncLength(length) {
						inputLength = length;
						inputLevel = Math.min(1, length / 8);
					}

					function tick(length) {
						syncLength(length);
						typePulseAnim.restart();
					}

					width: parent.width
					height: 56
					radius: ThemeEngine.radiusMedium
					color: Qt.tint(Atelier.ink, Qt.alpha(Atelier.paper, 0.1))
					border.width: 0
                    Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Atelier.accent }
					border.color: Qt.alpha(root.primary, 0.35)
					clip: true

					ParallelAnimation {
						id: typePulseAnim

						SequentialAnimation {
							NumberAnimation {
								target: passwordBox
								property: "typePulse"
								to: 1
								duration: ThemeEngine.duration(55)
								easing.type: ThemeEngine.standardEasing
							}

							NumberAnimation {
								target: passwordBox
								property: "typePulse"
								to: 0
								duration: ThemeEngine.duration(260)
								easing.type: ThemeEngine.standardEasing
							}
						}

						SequentialAnimation {
							PropertyAction {
								target: passwordBox
								property: "typeSweep"
								value: 0
							}

							NumberAnimation {
								target: passwordBox
								property: "typeSweep"
								to: 1
								duration: ThemeEngine.duration(320)
								easing.type: ThemeEngine.standardEasing
							}
						}
					}

					Row {
						anchors.fill: parent
						anchors.leftMargin: 16
						anchors.rightMargin: 16
						spacing: 12

						QQCImpl.IconImage {
							anchors.verticalCenter: parent.verticalCenter
							width: 18
							height: 18
							source: "/usr/share/icons/Adwaita/symbolic/status/system-lock-screen-symbolic.svg"
							sourceSize: Qt.size(width, height)
							color: Atelier.paper
							opacity: passwordPam.active ? 0.42 : (passwordBox.inputLength > 0 ? 0.92 : 0.78)
						}

						TextInput {
							id: passwordInput

							property int previousTextLength: 0

							width: parent.width - 30
							height: parent.height
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
							font.weight: Font.Medium
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

							AtelierText {
								anchors.centerIn: parent
								color: Qt.alpha(Atelier.paper, 0.64)
								text: "Password"
								font.pixelSize: 14
								font.weight: Font.Medium
								visible: passwordInput.text.length === 0 && !passwordPam.active
							}

							Item {
								id: inputTrace

								anchors.centerIn: parent
								width: Math.min(parent.width - 24, 236)
								height: 18
								visible: passwordInput.text.length > 0
								opacity: 0.68 + passwordBox.typePulse * 0.24
								clip: true

								ThemedRectangle {
									anchors.centerIn: parent
									width: parent.width
									height: 4
									radius: ThemeEngine.radiusMedium
									color: Qt.alpha(Atelier.paper, 0.18)
								}

								ThemedRectangle {
									anchors.verticalCenter: parent.verticalCenter
									anchors.left: parent.left
									width: parent.width * passwordBox.inputLevel
									height: 4
									radius: ThemeEngine.radiusMedium
									color: Qt.alpha(Atelier.paper, 0.72 + passwordBox.typePulse * 0.18)

									Behavior on width {
										NumberAnimation {
											duration: ThemeEngine.duration(150)
											easing.type: ThemeEngine.standardEasing
										}
									}
								}

								ThemedRectangle {
									width: Math.max(26, parent.width * 0.34)
									height: 10
									radius: ThemeEngine.radiusMedium
									x: (parent.width + width) * passwordBox.typeSweep - width
									y: Math.round((parent.height - height) / 2)
									color: Qt.alpha(Atelier.paper, 0.24)
									opacity: passwordBox.typePulse
								}

								Behavior on opacity {
									NumberAnimation {
										duration: ThemeEngine.duration(120)
										easing.type: ThemeEngine.standardEasing
									}
								}
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

				AtelierText {
					width: parent.width
					height: 22
					color: root.authState === "checking" ? Qt.alpha(Atelier.paper, 0.72) : root.danger
					text: root.statusText
					horizontalAlignment: Text.AlignLeft
					verticalAlignment: Text.AlignVCenter
					font.pixelSize: 13
					font.weight: Font.Medium
					opacity: text === "" ? 0 : 1

					Behavior on opacity {
						Anim {
							duration: Motion.fast
						}
					}

					Behavior on color {
						CAnim {}
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
