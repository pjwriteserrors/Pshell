pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.core.services

// A surface on each screen (or of each entry of `model`), built from its
// file while it is wanted, like View.
Scope {
	id: root

	required property string view
	property bool available: true
	property bool when: true
	property var model: Quickshell.screens

	onAvailableChanged: Views.wake()
	Component.onCompleted: Views.register(root)

	Variants {
		model: root.available && root.when ? root.model : []

		Loader {
			required property var modelData

			Component.onCompleted: setSource(Views.url(root.view), {
				modelData: modelData
			})
		}
	}
}
