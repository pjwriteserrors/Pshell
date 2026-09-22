pragma ComponentBehavior: Bound

import QtQuick
import QtMultimedia
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pam
import Quickshell.Wayland
import "components"

// The lock screen is the same thread, drawn across the middle of the screen.
//
// The time sits above the wire, the date below it. The wire is the password
// field: every typed character hangs a spark on it, out from the centre.
// While PAM checks, the sparks run to the centre and merge into one
// breathing spark. A wrong password shakes the wire, flashes it to the
// alert colour and throws the sparks off. Too many tries and the wire goes
// cold. On unlock the sparks race off to the right, then the thread lifts
// to the top of the screen and becomes the bar's thread.
//
// Contract with shell.qml: `locked`, `lock()`, `unlock()`. `screens` is
// the Variants model (defaults to every screen). `locked` drops the moment
// the session is unlocked; the windows stay (`shown`) until the thread has
// finished lifting.
Scope {
	id: root

	property bool locked: false
	property bool shown: false
	property var screens: Quickshell.screens
	// A harness may turn the keyboard grab off; the shell never does.
	property bool grabKeyboard: true

	// ------------------------------------------------------- the old state
	readonly property string wallpaperMediaType: String(mediaTypeFile.text()).trim()
	readonly property string wallpaperMediaPath: String(mediaSourceFile.text()).trim()
	readonly property string wallpaperMediaSource: root.wallpaperMediaPath === "" ? "" : root.fileUrl(root.wallpaperMediaPath)
	readonly property string wallpaperImageSource: root.wallpaperMediaSource === "" ? "" : `${root.wallpaperMediaSource}?v=${root.wallpaperFrameSerial}`
	readonly property string statusText: {
		if (root.checking) return "Checking";
		if (root.authState === "failed") return root.authMessage || "Incorrect password";
		if (root.authState === "error") return root.authMessage || "Authentication error";
		if (root.authState === "max") return root.authMessage || "Too many attempts";
		return "";
	}
	readonly property bool busy: root.locked || passwordPam.active
	readonly property bool checking: passwordPam.active || root.authState === "checking"

	property int wallpaperFrameSerial: 0
	property var lockNow: new Date()
	property string passwordSubmission: ""
	// "", "checking", "failed", "error", "max"
	property string authState: ""
	property string authMessage: ""

	signal clearPasswordInput
	signal focusPasswordInput

	// ------------------------------------------------- what the thread does
	// `typed` follows the input; `shownTyped` is what the wire shows, held
	// still while the sparks are busy merging or scattering.
	property int typed: 0
	property int shownTyped: 0
	readonly property int sparkCap: 12
	readonly property int sparkSpacing: 30
	readonly property int visibleSparks: Math.min(sparkCap, shownTyped)
	readonly property real overflow: Math.max(0, Math.min(1, (shownTyped - sparkCap) / 10))
	readonly property int outerSlot: Math.ceil(Math.max(0, visibleSparks - 1) / 2)
	readonly property real spanTarget: visibleSparks === 0 ? 0 : outerSlot * sparkSpacing * 2 + 64 + overflow * 320
	property real span: spanTarget
	Behavior on span { NumberAnimation { duration: Filament.settle; easing.type: Easing.BezierSpline; easing.bezierCurve: Filament.easeSettle } }

	property real reveal: 0        // the wire grows from the centre, the clock surfaces
	property real merge: 0         // sparks run to the centre and become one
	property real scatter: 0       // sparks thrown off the wire
	property bool scattering: false
	property real shakeX: 0
	property real alertMix: 0
	property real coldness: root.authState === "max" ? 1 : 0
	Behavior on coldness { NumberAnimation { duration: 600; easing.type: Easing.InOutSine } }
	property real flight: 0        // sparks race off to the right
	property real lift: 0          // the wire lifts to the bar's line
	property real wash: 1          // the scrim over the wallpaper

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
			root.shown = true;
			revealAnim.restart();
			focusDelay.restart();
		} else {
			focusDelay.stop();
			authMessageReset.stop();
			if (passwordPam.active) passwordPam.abort();
			root.passwordSubmission = "";
			root.authState = "";
			root.authMessage = "";
			root.clearPasswordInput();
			if (root.shown) unlockSeq.restart();
		}
	}

	onTypedChanged: {
		if (root.checking) return;
		if (root.scattering) root.settleFailure();
		root.shownTyped = root.typed;
	}

	onAuthStateChanged: {
		if (!root.locked) return;
		switch (root.authState) {
		case "checking":
			unmergeAnim.stop();
			mergeAnim.restart();
			break;
		case "failed":
		case "error":
			mergeAnim.stop();
			failSeq.restart();
			shakeSeq.restart();
			alertSeq.restart();
			break;
		case "max":
			mergeAnim.stop();
			failSeq.stop();
			root.settleFailure();
			shakeSeq.restart();
			alertSeq.restart();
			break;
		default:
			if (!root.scattering && root.merge > 0) {
				mergeAnim.stop();
				unmergeAnim.restart();
			}
		}
	}

	function settleFailure() {
		failSeq.stop();
		root.scattering = false;
		root.scatter = 0;
		root.merge = 0;
		root.shownTyped = root.checking ? root.shownTyped : root.typed;
	}

	function fileUrl(path) {
		return Qt.resolvedUrl(path);
	}

	function resolveWallpaper() {
		root.wallpaperFrameSerial = Date.now();
	}

	function primeForLock() {
		authMessageReset.stop();
		unlockSeq.stop();
		failSeq.stop();
		shakeSeq.stop();
		alertSeq.stop();
		mergeAnim.stop();
		unmergeAnim.stop();
		root.flight = 0;
		root.lift = 0;
		root.wash = 1;
		root.merge = 0;
		root.scatter = 0;
		root.scattering = false;
		root.shakeX = 0;
		root.alertMix = 0;
		root.reveal = 0;
		root.shownTyped = 0;
		root.typed = 0;
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

	function finishUnlock() {
		root.shown = false;
		root.flight = 0;
		root.lift = 0;
		root.wash = 1;
		root.merge = 0;
		root.reveal = 0;
		root.shownTyped = 0;
		root.typed = 0;
	}

	function submitPassword(password) {
		if (!root.locked || passwordPam.active || root.authState === "max" || password.length === 0) return;
		root.passwordSubmission = password;
		root.authState = "checking";
		root.authMessage = "";
		passwordPam.start();
	}

	// ------------------------------------------------------------- motion
	NumberAnimation {
		id: revealAnim
		target: root; property: "reveal"; to: 1
		duration: Filament.unfold + 80
		easing.type: Easing.BezierSpline; easing.bezierCurve: Filament.easeSettle
	}

	NumberAnimation {
		id: mergeAnim
		target: root; property: "merge"; to: 1
		duration: 460
		easing.type: Easing.BezierSpline; easing.bezierCurve: Filament.easeTravel
	}

	NumberAnimation {
		id: unmergeAnim
		target: root; property: "merge"; to: 0
		duration: Filament.settle
		easing.type: Easing.BezierSpline; easing.bezierCurve: Filament.easeSettle
	}

	// The sparks are thrown off the wire and fade as they go.
	SequentialAnimation {
		id: failSeq
		ScriptAction { script: root.scattering = true }
		NumberAnimation { target: root; property: "scatter"; to: 1; duration: 720; easing.type: Easing.OutCubic }
		ScriptAction { script: root.settleFailure() }
	}

	// The wire gives sideways and swings back, settling in two swings.
	SequentialAnimation {
		id: shakeSeq
		PropertyAction { target: root; property: "shakeX"; value: 24 }
		SpringAnimation { target: root; property: "shakeX"; to: 0; spring: 4; damping: 0.3; epsilon: 0.2 }
	}

	// A flicker to the alert colour, held while the sparks scatter, then cooled.
	SequentialAnimation {
		id: alertSeq
		NumberAnimation { target: root; property: "alertMix"; to: 1; duration: 50 }
		NumberAnimation { target: root; property: "alertMix"; to: 0.3; duration: 70 }
		NumberAnimation { target: root; property: "alertMix"; to: 1; duration: 60 }
		PauseAnimation { duration: 520 }
		NumberAnimation { target: root; property: "alertMix"; to: 0; duration: 800; easing.type: Easing.BezierSpline; easing.bezierCurve: Filament.easeSettle }
	}

	// Unlock: the light leaves along the wire, then the wire rises to the bar
	// while the wash clears. Only then do the windows go.
	SequentialAnimation {
		id: unlockSeq
		NumberAnimation { target: root; property: "flight"; to: 1; duration: 400; easing.type: Easing.BezierSpline; easing.bezierCurve: Filament.easeTravel }
		ParallelAnimation {
			NumberAnimation { target: root; property: "lift"; to: 1; duration: 420; easing.type: Easing.BezierSpline; easing.bezierCurve: Filament.easeSettle }
			NumberAnimation { target: root; property: "wash"; to: 0; duration: 420; easing.type: Easing.InOutSine }
		}
		ScriptAction { script: root.finishUnlock() }
	}

	Timer {
		id: focusDelay
		interval: 60
		repeat: false
		onTriggered: root.focusPasswordInput()
	}

	// ------------------------------------------------------------ windows
	Variants {
		model: root.screens

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

			readonly property int mid: Math.round(height / 2)
			// The wire's centre line: mid-screen, lifting to the bar's line.
			readonly property int wireLine: Math.round(mid + (Filament.wireY - mid) * root.lift)
			readonly property int centreX: Math.round(width / 2)
			readonly property real grown: Math.min(1, root.reveal)
			readonly property real lightLeft: 1 - root.flight
			readonly property int clockSize: Math.round(Math.min(150, Math.max(96, height * 0.16)))

			exclusiveZone: 0
			visible: root.shown
			color: "transparent"
			WlrLayershell.exclusionMode: ExclusionMode.Ignore
			WlrLayershell.layer: WlrLayer.Overlay
			WlrLayershell.keyboardFocus: root.locked && root.grabKeyboard ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

			ShortcutInhibitor {
				window: lockWindow
				enabled: root.locked && root.grabKeyboard
			}

			onVisibleChanged: {
				if (visible) root.focusPasswordInput();
			}

			// -------------------------------------------------- wallpaper
			Rectangle {
				anchors.fill: parent
				color: Filament.bg
				opacity: 1 - root.lift
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
				opacity: 1 - root.lift
			}

			VideoOutput {
				id: wallpaperVideo

				anchors.fill: parent
				visible: root.wallpaperMediaType === "video"
				fillMode: VideoOutput.PreserveAspectCrop
				opacity: 1 - root.lift
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

			// The wash, and a soft dark band behind the clock and the wire so
			// they read over a bright wallpaper.
			Rectangle {
				anchors.fill: parent
				color: Filament.scrim
				opacity: root.wash
			}

			Rectangle {
				x: 0
				width: parent.width
				height: Math.round(lockWindow.clockSize * 3.2)
				y: lockWindow.wireLine - Math.round(height * 0.58)
				opacity: root.wash * (1 - root.lift)
				gradient: Gradient {
					GradientStop { position: 0.0; color: "transparent" }
					GradientStop { position: 0.5; color: Qt.alpha(Filament.bg, 0.62) }
					GradientStop { position: 1.0; color: "transparent" }
				}
			}

			MouseArea {
				anchors.fill: parent
				cursorShape: Qt.BlankCursor
				onClicked: root.focusPasswordInput()
			}

			// ------------------------------------------------------ clock
			Text {
				id: clock
				x: Math.round((lockWindow.width - width) / 2)
				y: lockWindow.wireLine - 26 - height + Math.round((1 - lockWindow.grown) * 22)
				text: Qt.formatDateTime(root.lockNow, "HH:mm")
				color: Filament.ink
				font.family: Filament.fontMono
				font.pixelSize: lockWindow.clockSize
				font.weight: Font.DemiBold
				renderType: Text.NativeRendering
				opacity: lockWindow.grown * lockWindow.lightLeft
			}

			FText {
				x: Math.round((lockWindow.width - width) / 2)
				y: lockWindow.wireLine + 22 - Math.round((1 - lockWindow.grown) * 14)
				text: Qt.formatDateTime(root.lockNow, "dddd, dd. MMMM yyyy")
				tone: "soft"
				font.pixelSize: 17
				font.weight: Font.Medium
				opacity: lockWindow.grown * lockWindow.lightLeft
			}

			FText {
				x: Math.round((lockWindow.width - width) / 2)
				y: lockWindow.wireLine + 54
				text: root.statusText
				tone: root.checking ? "mute" : "alert"
				caps: true
				font.pixelSize: Filament.textSm
				font.weight: Font.Medium
				opacity: text === "" ? 0 : lockWindow.lightLeft
				Behavior on opacity { NumberAnimation { duration: Filament.quick } }
			}

			// ------------------------------------------------ the thread
			Item {
				id: thread
				anchors.fill: parent
				transform: Translate { x: root.shakeX }

				readonly property real litPx: (root.span * (1 - root.merge) + root.merge * 64)
					* (1 - root.scatter) * lockWindow.lightLeft * (1 - root.coldness)
				readonly property real litHalf: wire.width > 0 ? Math.min(0.5, litPx / wire.width / 2) : 0

				Wire {
					id: wire
					x: Math.round(lockWindow.centreX * (1 - lockWindow.grown))
					y: lockWindow.wireLine - 1
					width: Math.round(lockWindow.width * lockWindow.grown)
					height: 2
					thickness: 2
					cold: Filament.mix(Filament.mix(Filament.wire, Filament.wireDim, root.coldness), Filament.alert, root.alertMix)
					hot: Filament.mix(Qt.lighter(Filament.charge, 1 + 0.35 * root.overflow), Filament.alert, root.alertMix)
					glow: root.coldness < 0.5
					animateLit: false
					litFrom: 0.5 - thread.litHalf
					lit: thread.litHalf * 2
					pulseWidth: 220
				}

				// The resting spark: the caret, where the first character lands.
				Spark {
					size: 5
					breathing: true
					intensity: 0.75
					x: lockWindow.centreX - Math.round(width / 2)
					y: lockWindow.wireLine - Math.round(height / 2)
					opacity: (root.visibleSparks === 0 && root.merge === 0 && !root.scattering && root.coldness < 0.5 ? 1 : 0)
						* lockWindow.grown * lockWindow.lightLeft
					Behavior on opacity { NumberAnimation { duration: Filament.quick } }
				}

				// One spark per character, from the centre outward.
				Repeater {
					model: root.sparkCap

					Spark {
						id: sp
						required property int index
						readonly property int slot: Math.ceil(index / 2) * (index % 2 === 1 ? 1 : -1)
						readonly property bool present: index < root.visibleSparks
						readonly property real j1: Math.sin((index + 1) * 12.9898)
						readonly property real j2: Math.cos((index + 1) * 78.233)
						property real appear: present ? 1 : 0
						Behavior on appear { SpringAnimation { spring: 4; damping: 0.3; epsilon: 0.01 } }

						size: 7
						color: Filament.mix(Filament.charge, Filament.alert, root.alertMix)
						x: Math.round(lockWindow.centreX
							+ slot * root.sparkSpacing * (1 - root.merge)
							+ root.scatter * j2 * 110
							+ root.flight * (lockWindow.width + 160 + j1 * 90)) - Math.round(width / 2)
						y: lockWindow.wireLine - Math.round(root.scatter * (22 + Math.abs(j1) * 70) * (index % 3 === 0 ? -0.8 : 1)) - Math.round(height / 2)
						opacity: Math.min(1, appear) * (root.scattering ? Math.max(0, 1 - root.scatter * 1.15) : 1 - root.merge) * (1 - root.coldness)
						scale: 0.3 + 0.7 * appear
					}
				}

				// The one the sparks become while the password is checked.
				Spark {
					size: 9
					breathing: true
					color: Filament.mix(Filament.charge, Filament.alert, root.alertMix)
					x: lockWindow.centreX + Math.round(root.flight * (lockWindow.width + 160)) - Math.round(width / 2)
					y: lockWindow.wireLine - Math.round(height / 2)
					opacity: root.merge * (1 - root.scatter)
				}
			}

			// ------------------------------------------------- the input
			// Invisible: the wire above is what the typing looks like.
			TextInput {
				id: passwordInput

				property int previousTextLength: 0

				x: 0
				y: lockWindow.wireLine - 10
				width: parent.width
				height: 20
				color: "transparent"
				selectionColor: "transparent"
				selectedTextColor: "transparent"
				echoMode: TextInput.Password
				passwordMaskDelay: 0
				cursorVisible: false
				cursorDelegate: Item { visible: false }
				enabled: !passwordPam.active && root.authState !== "max"
				focus: root.locked
				inputMethodHints: Qt.ImhSensitiveData | Qt.ImhNoPredictiveText | Qt.ImhNoAutoUppercase
				font.pixelSize: 14
				clip: true

				onTextChanged: {
					root.typed = text.length;
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
					target: root

					function onClearPasswordInput(): void {
						passwordInput.text = "";
						passwordInput.previousTextLength = 0;
					}

					function onFocusPasswordInput(): void {
						if (root.locked) passwordInput.forceActiveFocus();
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

	// ---------------------------------------------------------------- PAM
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
				root.unlock();
				root.authState = "";
				root.authMessage = "";
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
