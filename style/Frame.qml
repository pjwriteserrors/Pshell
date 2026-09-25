import QtQuick
import Quickshell
import qs.style.bar

// What this style draws around the surfaces: one bar per screen.
Scope {
	Variants {
		model: Quickshell.screens

		Bar {}
	}
}
