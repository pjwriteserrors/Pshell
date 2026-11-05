import QtQuick
import qs.style.theme
import qs.core.services
import qs.core.views

// The task manager's window; closing it lets the daemon go back to looking
// every two seconds.
PopoutWindow {
	surface: TaskManager.surface
	title: TaskManager.system ? `Task manager · ${TaskManager.percent(TaskManager.cpu, 0)} CPU` : "Task manager"
	implicitWidth: 1240
	implicitHeight: 800
	minimumSize: Qt.size(900, 560)

	Component.onCompleted: {
		Sounds.play("open");
		view.takeFocus();
	}

	TaskManagerView {
		id: view

		anchors.fill: parent
		windowed: true
	}
}
