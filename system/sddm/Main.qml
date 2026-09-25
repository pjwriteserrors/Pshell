import QtQuick 2.15
import QtMultimedia
import SddmComponents 2.0

Rectangle {
	id: root

	width: 1920
	height: 1080
	color: "#0d0d0f"

	property int sessionIndex: session.index
	property string passwordText: ""
	property string statusText: ""
	property color foreground: "#f4f0ea"
	property color background: "#0d0d0f"
	property color primary: "#d7c477"
	property color danger: "#d95c5c"
	property bool fingerprintEnabled: String(config.fingerprint || "true").toLowerCase() !== "false"
	// only safe with the fingerprint-only PAM path from install-fingerprint-auth.sh;
	// with the stock stack every round would count as a failed login
	property bool fingerprintLoop: String(config.fingerprintLoop || "false").toLowerCase() === "true"
	property bool authenticationRunning: false
	property bool sessionStarted: false
	property bool fingerprintAttempt: false
	property int fingerprintStartAttempts: 0
	// password submitted while a fingerprint scan was still running
	property bool passwordPending: false
	property bool fingerprintRejected: false
	property int passwordProgressLength: 12
	property real passwordLevel: Math.min(1, passwordText.length / passwordProgressLength)
	readonly property string backgroundType: String(config.type || "image").toLowerCase()
	readonly property url backgroundImageSource: Qt.resolvedUrl(config.background || "backgrounds/wallpaper.png")
	readonly property url backgroundVideoSource: Qt.resolvedUrl(config.video || "backgrounds/wallpaper.mp4")

	function login(password, fingerprint) {
		if (userEntry.text === "")
			return;
		// SDDM cannot cancel a running PAM conversation: a typed password
		// waits until the fingerprint scan ends (touch or ~10 s sensor timeout)
		if (root.authenticationRunning) {
			if (!fingerprint && root.fingerprintAttempt && password !== "") {
				root.passwordPending = true;
				root.statusText = "Finishing fingerprint scan…";
			}
			return;
		}

		root.authenticationRunning = true;
		root.fingerprintAttempt = fingerprint;
		if (!fingerprint)
			root.statusText = "Checking...";
		else if (root.statusText === "")
			root.statusText = "Touch the sensor or type your password";
		sddm.login(userEntry.text, password, root.sessionIndex);
	}

	TextConstants {
		id: textConstants
	}

	Connections {
		target: sddm

		function onLoginSucceeded() {
			// The greeter process can stay alive for the whole session; stop the
			// video pipeline so it does not keep decoding in the background.
			root.sessionStarted = true;
			root.authenticationRunning = false;
			root.fingerprintAttempt = false;
			root.statusText = textConstants.loginSucceeded;
		}

		function onLoginFailed() {
			root.authenticationRunning = false;
			if (root.fingerprintAttempt) {
				// The sensor gives up after ~10 s without a finger; that is not
				// an error. Listen again unless the user switched to a password.
				root.fingerprintAttempt = false;
				if (root.passwordPending) {
					root.passwordPending = false;
					root.login(passwordInput.text, false);
					return;
				}
				root.statusText = root.fingerprintRejected ? "Fingerprint not recognized" : "";
				if (root.fingerprintRejected)
					statusClearTimer.restart();
				root.fingerprintRejected = false;
				fingerprintRestartTimer.restart();
				return;
			}
			root.passwordText = "";
			passwordInput.text = "";
			root.statusText = textConstants.loginFailed;
			passwordInput.forceActiveFocus();
			fingerprintRestartTimer.restart();
		}

		function onInformationMessage(message) {
			if (/match|recogni/i.test(message))
				root.fingerprintRejected = true;
			if (/place your finger|swipe/i.test(message))
				return;
			root.statusText = message;
		}
	}

	Image {
		id: wallpaper

		anchors.fill: parent
		source: root.backgroundImageSource
		fillMode: Image.PreserveAspectCrop
		asynchronous: false
		smooth: true
		mipmap: true
	}

	// Only instantiate the player when it is actually shown: a hidden Video
	// with autoPlay still decodes the file in a loop.
	Loader {
		id: wallpaperVideoLoader

		anchors.fill: parent
		active: root.backgroundType === "video" && !root.sessionStarted
		sourceComponent: Video {
			source: root.backgroundVideoSource
			fillMode: VideoOutput.PreserveAspectCrop
			autoPlay: true
			loops: MediaPlayer.Infinite
			muted: true
		}
	}

	Rectangle {
		anchors.fill: parent
		color: Qt.rgba(0, 0, 0, 0.28)
	}

	Column {
		id: loginContent

		width: Math.min(420, Math.max(280, root.width - 48))
		x: Math.round((root.width - width) / 2)
		y: Math.round((root.height - implicitHeight) / 2)
		spacing: 18

		Text {
			id: clockText

			width: parent.width
			color: root.foreground
			text: Qt.formatDateTime(clockTimer.now, "HH:mm")
			horizontalAlignment: Text.AlignHCenter
			font.family: "0xProto Nerd Font"
			font.pixelSize: 92
			font.weight: Font.DemiBold
		}

		Text {
			width: parent.width
			color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.76)
			text: Qt.formatDateTime(clockTimer.now, "dddd, dd. MMMM yyyy")
			horizontalAlignment: Text.AlignHCenter
			font.pixelSize: 16
			font.weight: Font.Medium
		}

		Rectangle {
			id: passwordBox

			width: parent.width
			height: 56
			radius: 7
			color: Qt.tint(root.background, Qt.rgba(root.primary.r, root.primary.g, root.primary.b, 0.10))
			border.width: 1
			border.color: Qt.rgba(root.primary.r, root.primary.g, root.primary.b, 0.35)
			clip: true

			Rectangle {
				anchors.centerIn: parent
				width: Math.min(parent.width - 56, 236)
				height: 4
				radius: 7
				color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.18)
				visible: passwordInput.text.length > 0
			}

			Rectangle {
				anchors.verticalCenter: parent.verticalCenter
				x: Math.round((parent.width - Math.min(parent.width - 56, 236)) / 2)
				width: Math.min(parent.width - 56, 236) * root.passwordLevel
				height: 4
				radius: 7
				color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.78)
				visible: passwordInput.text.length > 0

				Behavior on width {
					NumberAnimation {
						duration: 150
						easing.type: Easing.OutCubic
					}
				}
			}

			Text {
				anchors.centerIn: parent
				color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.64)
				text: "Password"
				font.pixelSize: 14
				font.weight: Font.Medium
				visible: passwordInput.text.length === 0
			}

			TextInput {
				id: passwordInput

				anchors.fill: parent
				color: "transparent"
				selectionColor: "transparent"
				selectedTextColor: "transparent"
				echoMode: TextInput.Password
				passwordMaskDelay: 0
				cursorVisible: false
				focus: true
				clip: true

				onTextChanged: root.passwordText = text

				Keys.onReturnPressed: {
					root.login(passwordInput.text, false);
				}

				Keys.onEnterPressed: {
					root.login(passwordInput.text, false);
				}

				Keys.onEscapePressed: {
					text = "";
					root.statusText = "";
				}
			}
		}

		Text {
			width: parent.width
			height: 22
			color: root.authenticationRunning ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.72) : root.danger
			text: root.statusText
			horizontalAlignment: Text.AlignHCenter
			verticalAlignment: Text.AlignVCenter
			font.pixelSize: 13
			font.weight: Font.Medium
			opacity: text === "" ? 0 : 1

			Behavior on opacity {
				NumberAnimation {
					duration: 120
					easing.type: Easing.OutCubic
				}
			}
		}
	}

	Column {
		anchors.left: parent.left
		anchors.leftMargin: 24
		anchors.bottom: parent.bottom
		anchors.bottomMargin: 22
		spacing: 8

		Text {
			color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.64)
			text: sddm.hostName
			font.pixelSize: 13
			font.weight: Font.Medium
		}

		TextInput {
			id: userEntry

			width: 180
			height: 30
			color: root.foreground
			text: userModel.lastUser
			selectByMouse: true
			font.pixelSize: 13
			KeyNavigation.tab: passwordInput
			KeyNavigation.backtab: layoutBox
		}
	}

	Row {
		anchors.right: parent.right
		anchors.rightMargin: 24
		anchors.bottom: parent.bottom
		anchors.bottomMargin: 22
		spacing: 10

		ActionButton {
			label: "Suspend"
			visible: sddm.canSuspend
			onTriggered: sddm.suspend()
		}

		ActionButton {
			label: "Reboot"
			onTriggered: sddm.reboot()
		}

		ActionButton {
			label: "Power Off"
			onTriggered: sddm.powerOff()
		}
	}

	Row {
		anchors.horizontalCenter: parent.horizontalCenter
		anchors.bottom: parent.bottom
		anchors.bottomMargin: 22
		spacing: 10

		ComboBox {
			id: session

			width: 220
			height: 30
			model: sessionModel
			index: sessionModel.lastIndex
			font.pixelSize: 13
			KeyNavigation.tab: layoutBox
			KeyNavigation.backtab: passwordInput
		}

		LayoutBox {
			id: layoutBox

			width: 90
			height: 30
			font.pixelSize: 13
			KeyNavigation.tab: userEntry
			KeyNavigation.backtab: session
		}
	}

	Timer {
		id: fingerprintStartTimer

		interval: 500
		running: root.fingerprintEnabled
		repeat: false
		onTriggered: {
			if (userEntry.text === "" && root.fingerprintStartAttempts < 10) {
				root.fingerprintStartAttempts++;
				restart();
				return;
			}
			root.login("", true);
		}
	}

	// keeps the sensor listening for the whole time the greeter is shown;
	// with the fingerprint-only PAM path these rounds never count as failed
	// logins (see install-fingerprint-auth.sh)
	Timer {
		id: fingerprintRestartTimer

		interval: 300
		repeat: false
		onTriggered: {
			if (!root.fingerprintEnabled || !root.fingerprintLoop || root.sessionStarted || root.authenticationRunning)
				return;
			if (passwordInput.text !== "") {
				restart();
				return;
			}
			root.login("", true);
		}
	}

	Timer {
		id: statusClearTimer

		interval: 2500
		onTriggered: {
			if (root.statusText === "Fingerprint not recognized")
				root.statusText = root.fingerprintAttempt ? "Touch the sensor or type your password" : "";
		}
	}

	Timer {
		id: clockTimer

		property var now: new Date()

		interval: 1000
		running: true
		repeat: true
		onTriggered: now = new Date()
	}

	Component.onCompleted: {
		if (userEntry.text === "")
			userEntry.forceActiveFocus();
		else
			passwordInput.forceActiveFocus();
	}

	component ActionButton: Rectangle {
		id: button

		property string label: ""
		signal triggered

		width: Math.max(86, buttonText.implicitWidth + 24)
		height: 30
		radius: 7
		color: buttonMouse.containsMouse ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.16) : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
		border.width: 1
		border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.14)

		Text {
			id: buttonText

			anchors.centerIn: parent
			color: root.foreground
			text: button.label
			font.pixelSize: 12
			font.weight: Font.Medium
		}

		MouseArea {
			id: buttonMouse

			anchors.fill: parent
			hoverEnabled: true
			onClicked: button.triggered()
		}

		Behavior on color {
			ColorAnimation {
				duration: 120
			}
		}
	}
}
