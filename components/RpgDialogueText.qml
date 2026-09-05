import QtQuick

// Stable-height typewriter text for RPG dialogue surfaces. The invisible
// sizing copy lays out the complete message, while the visible copy reveals
// it one character at a time without moving the surrounding card.
Item {
	id: root

	property string dialogueText: ""
	property color textColor: "white"
	property real fontPixelSize: 12
	property int fontWeight: Font.Normal
	property real letterSpacing: 0
	property int maximumLineCount: 0
	property int letterDelay: 22
	property int startDelay: 150
	property bool animate: true
	property int revealCount: 0

	readonly property bool complete: revealCount >= dialogueText.length
	readonly property string visibleText: dialogueText.slice(0, Math.max(0, revealCount))

	implicitHeight: Math.max(fullText.implicitHeight, fontPixelSize * 1.25)
		+ (dialogueText !== "" ? 8 : 0)
	clip: true

	function restart() {
		delayTimer.stop();
		revealAnimation.stop();
		revealCount = animate ? 0 : dialogueText.length;
		if (animate && dialogueText.length > 0) delayTimer.restart();
	}

	function revealAll() {
		delayTimer.stop();
		revealAnimation.stop();
		revealCount = dialogueText.length;
	}

	onDialogueTextChanged: restart()
	onAnimateChanged: restart()
	Component.onCompleted: restart()

	Text {
		id: fullText
		width: root.width
		visible: false
		text: root.dialogueText
		font.pixelSize: root.fontPixelSize
		font.weight: root.fontWeight
		font.letterSpacing: root.letterSpacing
		textFormat: Text.PlainText
		wrapMode: Text.WordWrap
		maximumLineCount: root.maximumLineCount > 0 ? root.maximumLineCount : 2147483647
		elide: root.maximumLineCount > 0 ? Text.ElideRight : Text.ElideNone
	}

	Text {
		anchors.left: parent.left
		anchors.right: parent.right
		anchors.top: parent.top
		color: root.textColor
		text: root.visibleText
		font.pixelSize: root.fontPixelSize
		font.weight: root.fontWeight
		font.letterSpacing: root.letterSpacing
		textFormat: Text.PlainText
		wrapMode: Text.WordWrap
		maximumLineCount: root.maximumLineCount > 0 ? root.maximumLineCount : 2147483647
		elide: root.maximumLineCount > 0 ? Text.ElideRight : Text.ElideNone
	}

	Item {
		id: continueMark
		visible: root.complete && root.dialogueText !== ""
		width: 8
		height: 8
		anchors.right: parent.right
		anchors.bottom: parent.bottom
		opacity: 0.45
		transform: Translate { id: continueBounce }

		Rectangle {
			width: 6
			height: 6
			anchors.centerIn: parent
			rotation: 45
			color: "transparent"
			border.width: 1
			border.color: root.textColor
		}

		SequentialAnimation {
			running: continueMark.visible
			loops: Animation.Infinite
			NumberAnimation { target: continueBounce; property: "y"; from: 0; to: 3; duration: 430; easing.type: Easing.InOutSine }
			NumberAnimation { target: continueBounce; property: "y"; from: 3; to: 0; duration: 430; easing.type: Easing.InOutSine }
		}
	}

	MouseArea {
		anchors.fill: parent
		enabled: !root.complete
		cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
		onClicked: root.revealAll()
	}

	Timer {
		id: delayTimer
		interval: Math.max(0, root.startDelay)
		repeat: false
		onTriggered: revealAnimation.restart()
	}

	NumberAnimation {
		id: revealAnimation
		target: root
		property: "revealCount"
		from: 0
		to: root.dialogueText.length
		duration: Math.max(1, root.dialogueText.length * root.letterDelay)
		easing.type: Easing.Linear
	}
}
