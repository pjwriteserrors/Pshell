import QtQuick
import QtQuick.Layouts
import qs.style.theme

// Centered placeholder. Text wraps inside the available width instead of
// running past the edges of narrow containers.
ColumnLayout {
	id: root

	property string icon: "information"
	property string title: ""
	property string subtitle: ""
	property real maxTextWidth: Math.max(120, Math.min(300, (parent ? parent.width : 300) - 32))

	spacing: 6

	Glyph {
		Layout.alignment: Qt.AlignHCenter
		icon: root.icon
		size: 34
		color: Theme.textFaint
	}

	StyledText {
		Layout.alignment: Qt.AlignHCenter
		Layout.preferredWidth: Math.min(implicitWidth, root.maxTextWidth)
		text: root.title
		tone: Theme.textMuted
		font.pixelSize: Theme.size.body
		font.weight: Font.DemiBold
		horizontalAlignment: Text.AlignHCenter
	}

	StyledText {
		Layout.alignment: Qt.AlignHCenter
		Layout.preferredWidth: Math.min(implicitWidth, root.maxTextWidth)
		visible: root.subtitle !== ""
		text: root.subtitle
		tone: Theme.textSubtle
		font.pixelSize: Theme.size.small
		horizontalAlignment: Text.AlignHCenter
		wrapMode: Text.WordWrap
	}
}
