import QtQuick

// Pshell login screen. Needs nothing but SDDM's Qt6 greeter: no SddmComponents,
// and QtMultimedia only for a video wallpaper (VideoBackground.qml, which falls
// back to the still frame when the module is missing).

Rectangle {
	id: root

	width: 1920
	height: 1080
	color: "#0d0d0f"

	property int sessionIndex: session.currentIndex
	property string passwordText: ""
	property string statusText: ""
	property color foreground: "#f4f0ea"
	property color background: "#0d0d0f"
	property color primary: "#d7c477"
	property color danger: "#d95c5c"
	// set by install-sddm-theme.sh only when /etc/pam.d/sddm has
	// pam_fprintd; without it the empty-password scan is just a failed login.
	// SDDM loads this file once per screen and every instance would start its
	// own scan, so only the primary screen listens.
	property bool fingerprintEnabled: String(config.fingerprint || "false").toLowerCase() === "true" && (typeof primaryScreen === "undefined" || primaryScreen)
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

	Connections {
		target: sddm

		function onLoginSucceeded() {
			// The greeter process can stay alive for the whole session; stop the
			// video pipeline so it does not keep decoding in the background.
			root.sessionStarted = true;
			root.authenticationRunning = false;
			root.fingerprintAttempt = false;
			root.statusText = "Login succeeded";
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
			root.statusText = "Login failed";
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
	// with autoPlay still decodes the file in a loop. A separate file so a
	// greeter without QtMultimedia still loads this one.
	Loader {
		id: wallpaperVideoLoader

		anchors.fill: parent
		active: root.backgroundType === "video" && !root.sessionStarted
		source: "VideoBackground.qml"
		onLoaded: item.source = root.backgroundVideoSource
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
			KeyNavigation.backtab: layoutBox.visible ? layoutBox : session
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

		Picker {
			id: session

			width: 220
			model: sessionModel
			textRole: "name"
			currentIndex: sessionModel.lastIndex
			KeyNavigation.tab: layoutBox.visible ? layoutBox : userEntry
			KeyNavigation.backtab: passwordInput
		}

		// keyboard is missing on some greeter backends and has no layouts on
		// Wayland; only worth showing with something to switch between
		Picker {
			id: layoutBox

			readonly property var layouts: typeof keyboard !== "undefined" && keyboard ? keyboard.layouts : []

			width: 90
			visible: layouts && layouts.length > 1
			model: layouts
			textRole: "shortName"
			currentIndex: visible ? keyboard.currentLayout : 0
			onPicked: index => keyboard.currentLayout = index
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

	// dropdown that opens upwards (it sits on the bottom edge); arrow keys
	// step through the entries while it has focus
	component Picker: Rectangle {
		id: picker

		property var model
		property string textRole: "name"
		property int currentIndex: 0
		property string currentText: ""
		property bool open: false
		readonly property int count: entries.count
		signal picked(int index)

		function pick(index) {
			if (count === 0)
				return;
			currentIndex = (index + count) % count;
			picked(currentIndex);
		}

		height: 30
		radius: 7
		activeFocusOnTab: true
		color: pickerMouse.containsMouse || open ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.16) : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
		border.width: 1
		border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, activeFocus ? 0.42 : 0.14)
		onActiveFocusChanged: if (!activeFocus) open = false

		Keys.onUpPressed: pick(currentIndex - 1)
		Keys.onDownPressed: pick(currentIndex + 1)
		Keys.onSpacePressed: open = !open
		Keys.onReturnPressed: open = !open
		Keys.onEnterPressed: open = !open
		Keys.onEscapePressed: open = false

		Text {
			anchors.fill: parent
			anchors.leftMargin: 12
			anchors.rightMargin: 12
			color: root.foreground
			text: picker.currentText
			elide: Text.ElideRight
			horizontalAlignment: Text.AlignHCenter
			verticalAlignment: Text.AlignVCenter
			font.pixelSize: 12
			font.weight: Font.Medium
		}

		MouseArea {
			id: pickerMouse

			anchors.fill: parent
			hoverEnabled: true
			onClicked: {
				picker.forceActiveFocus();
				picker.open = !picker.open;
			}
			onWheel: wheel => picker.pick(picker.currentIndex + (wheel.angleDelta.y > 0 ? -1 : 1))
		}

		Rectangle {
			anchors.bottom: parent.top
			anchors.bottomMargin: 6
			anchors.horizontalCenter: parent.horizontalCenter
			width: Math.max(parent.width, entryColumn.implicitWidth + 8)
			height: entryColumn.implicitHeight + 8
			radius: 7
			visible: picker.open
			color: Qt.tint(root.background, Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08))
			border.width: 1
			border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.14)

			Column {
				id: entryColumn

				x: 4
				y: 4
				width: parent.width - 8

				Repeater {
					id: entries

					model: picker.model

					delegate: Rectangle {
						id: entry

						required property int index
						required property var model
						// a QAbstractListModel (sessions) exposes roles, a list of
						// objects (keyboard layouts) the object as modelData
						readonly property string label: {
							const role = entry.model[picker.textRole];
							if (role !== undefined)
								return String(role);
							const data = entry.model.modelData;
							return data ? String(data[picker.textRole]) : "";
						}

						width: parent.width
						implicitWidth: entryText.implicitWidth + 24
						height: 28
						radius: 5
						color: entryMouse.containsMouse ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.14) : "transparent"

						Binding {
							target: picker
							property: "currentText"
							value: entry.label
							when: entry.index === picker.currentIndex
						}

						Text {
							id: entryText

							anchors.fill: parent
							anchors.leftMargin: 12
							anchors.rightMargin: 12
							color: entry.index === picker.currentIndex ? root.primary : root.foreground
							text: entry.label
							elide: Text.ElideRight
							verticalAlignment: Text.AlignVCenter
							font.pixelSize: 12
							font.weight: Font.Medium
						}

						MouseArea {
							id: entryMouse

							anchors.fill: parent
							hoverEnabled: true
							onClicked: {
								picker.pick(entry.index);
								picker.open = false;
							}
						}
					}
				}
			}
		}
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
