import QtQuick
import QtQuick.Controls
import QtMultimedia
import SddmComponents

Item {
	id: root

	width: 1920
	height: 1080
	focus: true

	property color foreground: config.foreground
	property color background: config.background
	property color primary: config.primary
	property color danger: config.danger
	property string mediaType: config.mediaType
	property date now: new Date()
	property bool authenticating: false
	property string authState: ""
	property string authMessage: ""
	property bool capsLockOn: false
	property int userIndex: userModel.lastIndex >= 0 ? userModel.lastIndex : 0
	property int sessionIndex: sessionModel.lastIndex >= 0 ? sessionModel.lastIndex : 0

	readonly property int userCount: userModel.count
	readonly property int sessionCount: sessionModel.rowCount()
	readonly property string userName: userCount > 0
		? String(userModel.data(userModel.index(userIndex, 0), 257) || "")
		: userInput.text
	readonly property string userLabel: userCount > 0
		? String(userModel.data(userModel.index(userIndex, 0), 258)
			 || userModel.data(userModel.index(userIndex, 0), 257) || "")
		: "Username"
	readonly property bool userNeedsPassword: userCount === 0
		|| Boolean(userModel.data(userModel.index(userIndex, 0), 261))
	readonly property string sessionLabel: sessionCount > 0
		? String(sessionModel.data(sessionModel.index(sessionIndex, 0), 260) || "Session")
		: "Session"
	readonly property string statusText: {
		if (authenticating) return "Checking...";
		if (capsLockOn) return "Caps Lock is on";
		if (authState === "failed") return authMessage || "Incorrect password";
		if (authState === "error") return authMessage || "Authentication error";
		return "";
	}

	function alpha(colorValue, opacityValue) {
		return Qt.rgba(colorValue.r, colorValue.g, colorValue.b, opacityValue);
	}

	function clearAuthentication() {
		authReset.stop();
		authState = "";
		authMessage = "";
	}

	function login() {
		if (authenticating || userName.length === 0)
			return;
		if (passwordInput.text.length === 0 && userNeedsPassword)
			return;

		authReset.stop();
		authenticating = true;
		authState = "checking";
		authMessage = "";
		sddm.login(userName, passwordInput.text, sessionIndex);
	}

	function cycleUser(delta) {
		if (userCount < 2)
			return;
		userIndex = (userIndex + userCount + delta) % userCount;
		sddm.currentUser = userName;
		passwordInput.text = "";
		clearAuthentication();
		passwordInput.forceActiveFocus();
	}

	function cycleSession(delta) {
		if (sessionCount < 2)
			return;
		sessionIndex = (sessionIndex + sessionCount + delta) % sessionCount;
		passwordInput.forceActiveFocus();
	}

	FontLoader {
		id: protoFont
		source: "assets/0xProtoNerdFont-Regular.ttf"
	}

	Image {
		id: imageBackground

		anchors.fill: parent
		source: "backgrounds/wallpaper.png"
		visible: root.mediaType === "image"
		fillMode: Image.PreserveAspectCrop
		asynchronous: false
		cache: false
		smooth: true
		mipmap: true
	}

	VideoOutput {
		id: videoBackground

		anchors.fill: parent
		visible: root.mediaType === "video"
		fillMode: VideoOutput.PreserveAspectCrop
	}

	MediaPlayer {
		id: backgroundPlayer

		source: root.mediaType === "video" ? "backgrounds/wallpaper.mp4" : ""
		videoOutput: videoBackground
		loops: MediaPlayer.Infinite

		Component.onCompleted: {
			if (root.mediaType === "video")
				play();
		}

		onMediaStatusChanged: {
			if (root.mediaType === "video"
					&& (mediaStatus === MediaPlayer.LoadedMedia
					|| mediaStatus === MediaPlayer.BufferedMedia)
			)
				play();
		}
	}

	MouseArea {
		anchors.fill: parent
		cursorShape: Qt.BlankCursor
		onClicked: passwordInput.forceActiveFocus()
	}

	Column {
		id: lockContent

		width: Math.min(420, Math.max(260, root.width - 48))
		x: Math.round((root.width - width) / 2)
		y: Math.round((root.height - implicitHeight) / 2)
		spacing: 18

		Text {
			width: parent.width
			color: root.foreground
			text: Qt.formatDateTime(root.now, "HH:mm")
			horizontalAlignment: Text.AlignHCenter
			font.family: protoFont.status === FontLoader.Ready ? protoFont.name : "monospace"
			font.pixelSize: 92
			font.weight: Font.DemiBold
		}

		Text {
			width: parent.width
			color: root.alpha(root.foreground, 0.76)
			text: Qt.formatDateTime(root.now, "dddd, dd. MMMM yyyy")
			horizontalAlignment: Text.AlignHCenter
			font.pixelSize: 16
			font.weight: Font.Medium
		}

		TextField {
			id: userInput

			width: parent.width
			height: 44
			visible: root.userCount === 0
			placeholderText: "Username"
			color: root.foreground
			placeholderTextColor: root.alpha(root.foreground, 0.64)
			horizontalAlignment: TextInput.AlignHCenter
			font.pixelSize: 14
			background: Rectangle {
				radius: 7
				color: Qt.tint(root.background, root.alpha(root.primary, 0.1))
				border.width: 1
				border.color: root.alpha(root.primary, 0.35)
			}
			Keys.onReturnPressed: passwordInput.forceActiveFocus()
			Keys.onEnterPressed: passwordInput.forceActiveFocus()
		}

		Rectangle {
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
			radius: 7
			color: Qt.tint(root.background, root.alpha(root.primary, 0.1))
			border.width: 1
			border.color: root.alpha(root.primary, 0.35)
			clip: true

			ParallelAnimation {
				id: typePulseAnim

				SequentialAnimation {
					NumberAnimation {
						target: passwordBox
						property: "typePulse"
						to: 1
						duration: 55
						easing.type: Easing.OutCubic
					}
					NumberAnimation {
						target: passwordBox
						property: "typePulse"
						to: 0
						duration: 260
						easing.type: Easing.OutCubic
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
						duration: 320
						easing.type: Easing.OutCubic
					}
				}
			}

			Row {
				anchors.fill: parent
				anchors.leftMargin: 16
				anchors.rightMargin: 16
				spacing: 12

				Text {
					anchors.verticalCenter: parent.verticalCenter
					width: 18
					color: root.foreground
					text: "\uf023"
					horizontalAlignment: Text.AlignHCenter
					font.family: protoFont.status === FontLoader.Ready ? protoFont.name : "monospace"
					font.pixelSize: 17
					opacity: root.authenticating ? 0.42 : (passwordBox.inputLength > 0 ? 0.92 : 0.78)
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
					enabled: !root.authenticating
					focus: true
					font.pixelSize: 18
					font.weight: Font.Medium
					clip: true

					onTextChanged: {
						if (activeFocus && text.length > previousTextLength)
							passwordBox.tick(text.length);
						else
							passwordBox.syncLength(text.length);
						previousTextLength = text.length;
					}

					Keys.onReturnPressed: function(event) {
						event.accepted = true;
						root.login();
					}
					Keys.onEnterPressed: function(event) {
						event.accepted = true;
						root.login();
					}
					Keys.onEscapePressed: function(event) {
						event.accepted = true;
						text = "";
						root.clearAuthentication();
					}
					Keys.onPressed: function(event) {
						if (event.key === Qt.Key_CapsLock)
							root.capsLockOn = !root.capsLockOn;
					}

					Text {
						anchors.centerIn: parent
						color: root.alpha(root.foreground, 0.64)
						text: "Password"
						font.pixelSize: 14
						font.weight: Font.Medium
						visible: passwordInput.text.length === 0 && !root.authenticating
					}

					Item {
						anchors.centerIn: parent
						width: Math.min(parent.width - 24, 236)
						height: 18
						visible: passwordInput.text.length > 0
						opacity: 0.68 + passwordBox.typePulse * 0.24
						clip: true

						Rectangle {
							anchors.centerIn: parent
							width: parent.width
							height: 4
							radius: 7
							color: root.alpha(root.foreground, 0.18)
						}

						Rectangle {
							anchors.verticalCenter: parent.verticalCenter
							anchors.left: parent.left
							width: parent.width * passwordBox.inputLevel
							height: 4
							radius: 7
							color: root.alpha(root.foreground, 0.72 + passwordBox.typePulse * 0.18)

							Behavior on width {
								NumberAnimation {
									duration: 150
									easing.type: Easing.OutCubic
								}
							}
						}

						Rectangle {
							width: Math.max(26, parent.width * 0.34)
							height: 10
							radius: 7
							x: (parent.width + width) * passwordBox.typeSweep - width
							y: Math.round((parent.height - height) / 2)
							color: root.alpha(root.foreground, 0.24)
							opacity: passwordBox.typePulse
						}
					}
				}
			}
		}

		Text {
			width: parent.width
			height: 22
			color: root.authState === "checking" || root.capsLockOn
				? root.alpha(root.foreground, 0.72) : root.danger
			text: root.statusText
			horizontalAlignment: Text.AlignHCenter
			verticalAlignment: Text.AlignVCenter
			font.pixelSize: 13
			font.weight: Font.Medium
			opacity: text === "" ? 0 : 1

			Behavior on opacity {
				NumberAnimation { duration: 120 }
			}
		}
	}

	Row {
		anchors.left: parent.left
		anchors.bottom: parent.bottom
		anchors.margins: 18
		spacing: 8
		opacity: 0.72

		FooterButton {
			label: root.userLabel
			enabled: root.userCount > 1
			onClicked: root.cycleUser(1)
		}

		FooterButton {
			label: root.sessionLabel
			enabled: root.sessionCount > 1
			onClicked: root.cycleSession(1)
		}
	}

	Row {
		anchors.right: parent.right
		anchors.bottom: parent.bottom
		anchors.margins: 18
		spacing: 8
		opacity: 0.72

		FooterButton {
			label: "↻"
			enabled: sddm.canReboot
			onClicked: sddm.reboot()
		}

		FooterButton {
			label: "⏻"
			enabled: sddm.canPowerOff
			onClicked: sddm.powerOff()
		}
	}

	component FooterButton: Rectangle {
		id: footerButton

		property alias label: footerLabel.text
		signal clicked

		width: Math.max(38, footerLabel.implicitWidth + 20)
		height: 34
		radius: 7
		color: footerMouse.containsMouse ? root.alpha(root.background, 0.34) : root.alpha(root.background, 0.16)
		border.width: 1
		border.color: root.alpha(root.primary, footerMouse.containsMouse ? 0.5 : 0.3)
		opacity: enabled ? 1 : 0.58

		Text {
			id: footerLabel
			anchors.centerIn: parent
			color: root.foreground
			font.family: protoFont.status === FontLoader.Ready ? protoFont.name : "sans-serif"
			font.pixelSize: 12
			font.weight: Font.Medium
			elide: Text.ElideRight
		}

		MouseArea {
			id: footerMouse
			anchors.fill: parent
			hoverEnabled: true
			cursorShape: parent.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
			enabled: parent.enabled
			onClicked: footerButton.clicked()
		}
	}

	Connections {
		target: sddm

		function onLoginSucceeded() {
			root.authenticating = true;
		}

		function onLoginFailed() {
			root.authenticating = false;
			root.authState = "failed";
			root.authMessage = "Incorrect password";
			passwordInput.text = "";
			passwordInput.forceActiveFocus();
			authReset.restart();
		}

		function onInformationMessage(message) {
			if (message === "")
				return;
			root.authMessage = message;
		}

		function onErrorMessage(message) {
			root.authenticating = false;
			root.authState = "error";
			root.authMessage = message;
			passwordInput.text = "";
			passwordInput.forceActiveFocus();
			authReset.restart();
		}
	}

	Timer {
		interval: 1000
		running: true
		repeat: true
		onTriggered: root.now = new Date()
	}

	Timer {
		id: authReset
		interval: 3600
		repeat: false
		onTriggered: root.clearAuthentication()
	}

	Timer {
		interval: 60
		running: true
		repeat: false
		onTriggered: {
			if (root.userCount > 0)
				sddm.currentUser = root.userName;
			passwordInput.forceActiveFocus();
		}
	}
}
