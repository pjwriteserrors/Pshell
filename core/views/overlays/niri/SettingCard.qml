import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets

// One setting, or a few that belong together: what it is, how it is set and
// – while it differs from niri's default – a way back. Cards rise in one by
// one when their page opens and glow when search jumps to them.
Rectangle {
	id: root

	property string title: ""
	property string subtitle: ""
	property string icon: ""
	// what search finds it by (NiriSettingsWindow's index)
	property string anchor: ""
	// set in the file: the reset pill shows
	property bool modified: false
	property bool padded: true
	default property alias content: body.data
	property alias header: headerRow
	property alias trailing: trailingSlot.data

	property real glow: 0
	property real enter: 1

	signal reset

	function flash() {
		glowAnim.restart();
	}

	function playEnter(delay) {
		root.enter = 0;
		enterAnim.delay = delay;
		enterAnim.restart();
	}

	Layout.fillWidth: true
	implicitHeight: column.implicitHeight + (root.padded ? 40 : 0)
	radius: Theme.radius.huge
	color: Theme.layer1
	border.width: 1.5
	border.color: Qt.alpha(Theme.primary, root.glow * 0.9)
	opacity: root.enter
	transform: Translate {
		y: (1 - root.enter) * 22
	}

	SequentialAnimation {
		id: enterAnim

		property int delay: 0

		PauseAnimation {
			duration: enterAnim.delay
		}
		NumberAnimation {
			target: root
			property: "enter"
			to: 1
			duration: Motion.long
			easing.type: Easing.BezierSpline
			easing.bezierCurve: Motion.decel
		}
	}

	SequentialAnimation {
		id: glowAnim

		NumberAnimation {
			target: root
			property: "glow"
			to: 1
			duration: Motion.medium
		}
		PauseAnimation {
			duration: 700
		}
		NumberAnimation {
			target: root
			property: "glow"
			to: 0
			duration: Motion.extraLong * 2
			easing.type: Easing.OutCubic
		}
	}

	Rectangle {
		anchors.fill: parent
		radius: parent.radius
		color: Theme.primary
		opacity: root.glow * 0.07
	}

	ColumnLayout {
		id: column

		anchors.left: parent.left
		anchors.right: parent.right
		anchors.top: parent.top
		anchors.margins: root.padded ? 20 : 0
		spacing: 16

		RowLayout {
			id: headerRow

			Layout.fillWidth: true
			visible: root.title !== ""
			spacing: 12

			Rectangle {
				visible: root.icon !== ""
				Layout.preferredWidth: 36
				Layout.preferredHeight: 36
				Layout.alignment: Qt.AlignTop
				radius: Theme.radius.medium
				color: Theme.primarySoft

				Glyph {
					anchors.centerIn: parent
					icon: root.icon
					size: 18
					color: Theme.primary
				}
			}

			ColumnLayout {
				Layout.fillWidth: true
				spacing: 2

				StyledText {
					Layout.fillWidth: true
					text: root.title
					font.pixelSize: Theme.size.title
					font.weight: Font.DemiBold
				}

				StyledText {
					Layout.fillWidth: true
					visible: root.subtitle !== ""
					text: root.subtitle
					tone: Theme.textMuted
					font.pixelSize: Theme.size.small
					wrapMode: Text.WordWrap
				}
			}

			Row {
				id: trailingSlot

				Layout.alignment: Qt.AlignTop
				spacing: 8
			}

			ResetPill {
				Layout.alignment: Qt.AlignTop
				shown: root.modified
				onClicked: root.reset()
			}
		}

		ColumnLayout {
			id: body

			Layout.fillWidth: true
			spacing: 14
		}
	}
}
