pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "components"

// Bar island that mirrors what you type (US layout) into a LandLynes display,
// capturing up to `maxWords` words before resetting for the next batch.
// Backed by scripts/keycatcher.py (evdev). Capture is fully stopped while
// `paused` is true (e.g. lock screen) so keystrokes are never even read.
ThemedRectangle {
	id: root

	required property color foreground
	required property color surface
	property int maxWords: 3
	property bool paused: false

	readonly property string fontFamily: landFont.status === FontLoader.Ready ? landFont.name : "sans-serif"

	FontLoader {
		id: landFont
		source: "file:///home/lu/.local/share/fonts/LandLynes004-SVG.ttf"
	}

	// live buffer being displayed
	property string current: ""
	property bool pendingReset: false

	readonly property real horizontalPadding: 12
	readonly property int minWidth: 46
	readonly property int maxWidth: 300

	radius: ThemeEngine.radiusMedium
	color: "transparent"

	clip: !ThemeEngine.shadowEnabled
	implicitWidth: Math.min(maxWidth, Math.max(minWidth, Math.round(textMetrics.width) + horizontalPadding * 2 + 10))

	Behavior on implicitWidth {
		Anim {
			duration: Motion.fast
		}
	}

	function reset() {
		root.current = "";
		root.pendingReset = false;
	}

	function feed(line) {
		if (!line)
			return;
		let obj;
		try {
			obj = JSON.parse(line);
		} catch (e) {
			return;
		}

		idleTimer.restart();

		if (obj.clr) {
			root.reset();
			return;
		}

		if (obj.bs) {
			if (root.current.length > 0)
				root.current = root.current.slice(0, -1);
			root.pendingReset = false;
			return;
		}

		if (obj.c === undefined)
			return;

		const ch = obj.c;
		if (ch === " ") {
			if (root.current.length === 0)
				return;
			if (root.current.charAt(root.current.length - 1) === " ")
				return;
			root.current += " ";
			const words = root.current.trim().split(/\s+/);
			if (words.length >= root.maxWords)
				root.pendingReset = true;
			return;
		}

		// printable character
		if (root.pendingReset) {
			root.current = ch;
			root.pendingReset = false;
		} else {
			root.current += ch;
		}
	}

	onPausedChanged: {
		if (paused)
			root.reset();
	}

	Process {
		id: catcher
		running: !root.paused
		command: ["python3", `${Quickshell.shellDir}/scripts/keycatcher.py`]

		stdout: SplitParser {
			onRead: data => root.feed(data)
		}

		onExited: (code, status) => {
			// python or a device hiccup died; relaunch shortly unless paused
			if (!root.paused)
				relaunchTimer.restart();
		}
	}

	Timer {
		id: relaunchTimer
		interval: 1500
		repeat: false
		onTriggered: {
			if (!root.paused)
				catcher.running = true;
		}
	}

	// clear the line after a stretch of no typing
	Timer {
		id: idleTimer
		interval: 6000
		repeat: false
		onTriggered: root.reset()
	}

	TextMetrics {
		id: textMetrics
		font.family: root.fontFamily
		font.pixelSize: 22
		text: root.current
	}

	// text pinned to the right edge so the newest words stay visible when the
	// buffer is wider than the pill (older text clips off the left)
	Item {
		anchors.fill: parent
		anchors.leftMargin: root.horizontalPadding
		anchors.rightMargin: root.horizontalPadding

		Row {
			anchors.right: parent.right
			anchors.verticalCenter: parent.verticalCenter
			spacing: 3

			AtelierText {
				id: label
				anchors.verticalCenter: parent.verticalCenter
				color: root.foreground
				font.family: root.fontFamily
				display: true
				font.pixelSize: 22
				text: root.current
				textFormat: Text.PlainText
			}

			// blinking caret — shows the widget is live even when empty
			ThemedRectangle {
				anchors.verticalCenter: parent.verticalCenter
				width: 2
				height: 18
				radius: 1
				color: Qt.alpha(root.foreground, 0.75)
				opacity: caretBlink.on ? 0.9 : 0.15

				Behavior on opacity {
					Anim {
						duration: Motion.fast
					}
				}
			}
		}
	}

	QtObject {
		id: caretBlink
		property bool on: true
	}

	Timer {
		running: !root.paused
		repeat: true
		interval: 600
		onTriggered: caretBlink.on = !caretBlink.on
	}
}
