pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.impl as QQCImpl

// A button is a small chamber with a name engraved on it. Pressing it does not
// move it — it lights it, the way something reacts rather than something that
// is mechanically depressed.
Item {
	id: button

	property string text: ""
	property string iconSource: ""
	property string tone: "default"      // default | organ | alert
	property bool enabled: true
	property bool lit: false
	property real minimumWidth: 0

	readonly property color accentColor: tone === "alert" ? Bio.necrosis : Bio.organ
	readonly property real live: button.enabled ? Math.max(touch.live, lit ? 0.5 : 0) : 0

	signal clicked()

	implicitHeight: 32
	// Wide enough that the engraved label never runs into the corner bones.
	implicitWidth: Math.max(minimumWidth, row.implicitWidth + Bio.s8)
	opacity: enabled ? 1 : 0.45

	BioFrame {
		anchors.fill: parent
		variant: "plate"
		lineColor: button.tone === "alert" ? Qt.alpha(Bio.necrosis, 0.5) : Bio.boneDim
		liveColor: button.accentColor
		fillTop: button.tone === "alert" ? Qt.alpha(Bio.necrosis, 0.07) : Bio.tissue2
		fillBottom: Bio.tissue1
		intensity: button.live
	}

	Row {
		id: row
		anchors.centerIn: parent
		spacing: Bio.s2

		QQCImpl.IconImage {
			anchors.verticalCenter: parent.verticalCenter
			width: 14
			height: 14
			visible: button.iconSource !== ""
			source: button.iconSource
			sourceSize: Qt.size(width, height)
			color: label.color
		}

		BioText {
			id: label
			anchors.verticalCenter: parent.verticalCenter
			role: "label"
			text: button.text
			color: button.tone === "alert"
				? (button.live > 0.3 ? Bio.necrosis : Bio.textMuted)
				: (button.live > 0.3 ? Bio.organ : Bio.text)

			Behavior on color {
				ColorAnimation { duration: Bio.twitch }
			}
		}
	}

	BioTouch {
		id: touch
		enabled: button.enabled
		onClicked: button.clicked()
	}
}
