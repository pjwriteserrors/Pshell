import QtQuick
import QtQuick.Controls.impl as QQCImpl
import Quickshell

// A symbolic icon in an ink tone. Names resolve through the icon theme with
// an Adwaita fallback table, and absolute paths are used as they are.
Item {
	id: icon

	property string name: ""
	property var fallbacks: []
	property real size: 16
	property color color: Filament.ink
	readonly property string source: FIconTable.resolve(name, fallbacks)

	implicitWidth: size
	implicitHeight: size
	width: size
	height: size

	// Only instantiated with a real source: an IconImage asked for "" in a
	// long delegate list stalled the window's repaint.
	Loader {
		anchors.fill: parent
		active: icon.source !== ""
		sourceComponent: QQCImpl.IconImage {
			source: icon.source
			color: icon.color
			sourceSize: Qt.size(icon.size, icon.size)
		}
	}
}
