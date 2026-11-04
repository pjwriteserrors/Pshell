import QtQuick
import qs.core.services

// A surface, built from its file while it is wanted (see Views): naming
// its type in Surfaces.qml would compile its whole tree at every start.
Loader {
	id: root

	// "panels/ControlCenter": core/views/panels/ControlCenter.qml, or
	// style/views/ControlCenter.qml when the style replaces it
	required property string view
	// its plugin is on: compiled ahead, and built while `when` holds
	property bool available: true
	property bool when: true

	active: root.available && root.when
	source: Views.url(root.view)

	onAvailableChanged: Views.wake()
	Component.onCompleted: Views.register(root)
}
