import QtQuick
import Quickshell
// the module scanner follows imports from the entry file, so name every
// module shell.qml uses
import qs.core
import qs.style

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
