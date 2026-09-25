import QtQuick
import qs.style.theme

Text {
	id: root

	property bool tabular: false
	// the requested color; `color` is this lifted off surfaces it would vanish into
	property color tone: Theme.text
	// what the text is drawn on; "transparent" when unknown (e.g. an image)
	property color surface: Theme.surfaceBehind(root)

	color: Theme.readableOn(root.tone, root.surface)
	font.family: Theme.fontFamily
	font.pixelSize: Theme.size.body
	font.features: tabular ? { "tnum": 1 } : {}
	verticalAlignment: Text.AlignVCenter
	elide: Text.ElideRight
	maximumLineCount: wrapMode === Text.NoWrap ? 1 : 1000

	Behavior on color {
		ColorAnim {}
	}
}
