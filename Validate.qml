import QtQuick
import Quickshell

Scope {
    Timer {
      running: true
      interval: 20
      onTriggered: {
        const component = Qt.createComponent("shell.qml", Component.PreferSynchronous);
        if (component.status === Component.Error) {
            console.error(component.errorString());
            Qt.quit();
        } else if (component.status === Component.Ready) {
            console.log("STYLE: complete shell and dependencies compiled successfully");
            Qt.quit();
        } else {
            console.error("Shell did not compile synchronously");
            Qt.quit();
        }
      }
    }
}
