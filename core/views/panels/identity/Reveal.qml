import QtQuick
import qs.style.theme
import qs.style.widgets

// A value that is on its way. While it is, a bar breathes in its place; when
// it arrives its letters settle from the left out of a jumble.
Item {
	id: root

	property string text: ""
	property bool pending: false
	property color tone: Theme.text
	property alias font: label.font
	// how long the bar is
	property real placeholder: 120

	readonly property bool waiting: root.pending && root.text === ""
	property string shown: ""
	property int settled: 0
	property bool ready: false

	implicitWidth: root.waiting ? root.placeholder : label.implicitWidth
	implicitHeight: label.implicitHeight

	Component.onCompleted: {
		root.shown = root.text;
		root.ready = true;
	}

	onTextChanged: {
		if (!root.ready) return;
		// only what was waited for arrives; anything else is simply there
		if (root.shown !== "" || root.text === "") {
			settle.stop();
			root.shown = root.text;
			return;
		}
		root.settled = 0;
		settle.restart();
	}

	function jumble() {
		const letters = "abcdefghijklmnopqrstuvwxyz0123456789";
		let out = root.text.slice(0, root.settled);
		for (let i = root.settled; i < root.text.length; i += 1) {
			const letter = root.text[i];
			out += /[\s@.,+-]/.test(letter) ? letter : letters[Math.floor(Math.random() * letters.length)];
		}
		return out;
	}

	Timer {
		id: settle

		interval: 28
		repeat: true
		onTriggered: {
			root.settled += Math.max(1, Math.ceil(root.text.length / 14));
			if (root.settled >= root.text.length) {
				root.shown = root.text;
				settle.stop();
			} else {
				root.shown = root.jumble();
			}
		}
	}

	Rectangle {
		anchors.verticalCenter: parent.verticalCenter
		width: Math.min(root.placeholder, root.width)
		height: Math.round(label.font.pixelSize * 0.72)
		radius: height / 2
		color: Theme.layer3
		visible: opacity > 0.01
		opacity: root.waiting ? 1 : 0

		Behavior on opacity {
			Anim {
				duration: Motion.short
			}
		}

		SequentialAnimation on scale {
			running: root.waiting
			loops: Animation.Infinite

			NumberAnimation {
				from: 1
				to: 0.94
				duration: 620
				easing.type: Easing.InOutSine
			}
			NumberAnimation {
				from: 0.94
				to: 1
				duration: 620
				easing.type: Easing.InOutSine
			}
		}
	}

	StyledText {
		id: label

		anchors.left: parent.left
		anchors.right: parent.right
		anchors.verticalCenter: parent.verticalCenter
		text: root.shown
		tone: root.tone
		opacity: root.waiting ? 0 : 1

		Behavior on opacity {
			Anim {
				duration: Motion.short
			}
		}
	}
}
