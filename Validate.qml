import QtQuick
import Quickshell
// the module scanner follows imports from the entry file, so name every
// module shell.qml uses
import qs.style.theme
import qs.style.bar
import qs.core.services
import qs.core.views.panels
import qs.core.views.overlays
import qs.core.views.rpg

// Compiles shell.qml and everything it pulls in without opening a window.
// Run: quickshell -p ./Validate.qml
Scope {
	Timer {
		running: true
		interval: 20

		onTriggered: {
			const component = Qt.createComponent("shell.qml", Component.PreferSynchronous);
			if (component.status === Component.Ready)
				console.log("VALIDATE: ok");
			else
				console.error(`VALIDATE: failed\n${component.errorString()}`);
			Qt.quit();
		}
	}
}
