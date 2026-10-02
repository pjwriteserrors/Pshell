import QtQuick
import Quickshell
import qs.core.services
import qs.style.bar

// What this style draws around the surfaces: one bar per screen.
Scope {
	Variants {
		model: Plugins.on("bar") ? Quickshell.screens : []

		Bar {}
	}
}
