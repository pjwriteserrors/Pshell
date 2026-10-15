import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets

// One way to use a control (a click, a swipe, holding …) and what it does.
// Lights up when the real mouse does it; `approach` (0…1) fills it while a
// swipe heads its way.
Clickable {
	id: root

	property string trigger: ""
	property string triggerLabel: ""
	property string triggerIcon: ""
	property var info: ({ label: "", icon: "", plain: true })
	// set for the app picked, or only inherited from everywhere
	property bool own: false
	property bool inherited: false
	property real approach: 0
	property bool compact: false
	property bool armed: false

	property real glow: 0

	function flash() {
		flashAnim.restart();
	}

	implicitHeight: root.compact ? 58 : 76
	radius: Theme.radius.large
	color: root.armed ? Theme.primaryContainer : (root.own ? Theme.layer2 : Qt.alpha(Theme.layer2, 0.55))
	border.width: 1.5
	border.color: Qt.alpha(Theme.primary, Math.max(root.glow, root.approach * 0.8, root.armed ? 0.7 : 0))
	pressedScale: 0.96

	SequentialAnimation {
		id: flashAnim

		NumberAnimation {
			target: root
			property: "glow"
			to: 1
			duration: Motion.micro
		}
		NumberAnimation {
			target: root
			property: "glow"
			to: 0
			duration: Motion.extraLong * 2
			easing.type: Easing.OutCubic
		}
	}

	// the swipe coming this way
	Rectangle {
		anchors.fill: parent
		radius: parent.radius
		color: Theme.primary
		opacity: Math.max(root.approach * 0.16, root.glow * 0.22)
	}

	RowLayout {
		anchors.fill: parent
		anchors.leftMargin: 12
		anchors.rightMargin: 12
		spacing: 10

		Rectangle {
			Layout.preferredWidth: root.compact ? 30 : 36
			Layout.preferredHeight: root.compact ? 30 : 36
			radius: Theme.radius.medium
			color: root.own ? Theme.primarySoft : Theme.layer3
			scale: 1 + root.glow * 0.18

			Glyph {
				anchors.centerIn: parent
				icon: root.info.icon || root.triggerIcon
				size: root.compact ? 15 : 18
				color: root.own ? Theme.primary : Theme.textMuted
			}
		}

		ColumnLayout {
			Layout.fillWidth: true
			spacing: 1

			RowLayout {
				Layout.fillWidth: true
				spacing: 4

				Glyph {
					visible: root.triggerIcon !== "" && (root.info.icon || "") !== ""
					icon: root.triggerIcon
					size: 11
					color: Theme.textSubtle
				}

				StyledText {
					Layout.fillWidth: true
					text: root.triggerLabel
					tone: Theme.textSubtle
					font.pixelSize: Theme.size.tiny
					font.weight: Font.DemiBold
					font.capitalization: Font.AllUppercase
					font.letterSpacing: 0.4
					elide: Text.ElideRight
				}
			}

			StyledText {
				Layout.fillWidth: true
				text: root.info.label
				tone: root.own ? Theme.text : (root.inherited ? Theme.textMuted : Theme.textSubtle)
				font.weight: root.own ? Font.DemiBold : Font.Medium
				font.italic: !root.own && !root.inherited && root.info.plain === true
				elide: Text.ElideRight
			}

			StyledText {
				Layout.fillWidth: true
				visible: root.inherited && !root.compact
				text: "from Everywhere"
				tone: Theme.textFaint
				font.pixelSize: Theme.size.tiny
			}
		}
	}
}
