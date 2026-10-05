pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.style.theme
import qs.core.services
import qs.style.widgets

// Where a message is written: the text, the files that go with it (picked,
// or dropped here) and the send button. Ctrl+Enter sends.
ColumnLayout {
	id: root

	property alias text: field.text
	property var files: []
	property string placeholder: "Message"
	property bool busy: false
	property real maxHeight: 170
	// a forward needs no words of its own
	property bool allowEmpty: false
	readonly property bool ready: !root.busy && (root.allowEmpty || root.text.trim() !== "" || root.files.length > 0)

	signal submit

	function clear() {
		field.text = "";
		root.files = [];
	}

	function focusInput() {
		field.focusInput();
	}

	function add(paths) {
		const next = root.files.slice();
		for (const entry of paths) {
			const path = decodeURIComponent(String(entry).replace(/^file:\/\//, ""));
			if (path !== "" && !next.includes(path)) next.push(path);
		}
		root.files = next;
	}

	spacing: 6

	Flow {
		Layout.fillWidth: true
		visible: root.files.length > 0
		spacing: 6

		Repeater {
			model: root.files

			delegate: Chip {
				required property string modelData

				icon: "paperclip"
				text: `${modelData.split("/").pop()}  ✕`
				onClicked: root.files = root.files.filter(path => path !== modelData)
			}
		}
	}

	RowLayout {
		Layout.fillWidth: true
		spacing: 6

		IconButton {
			Layout.alignment: Qt.AlignBottom
			implicitWidth: 40
			implicitHeight: 40
			icon: "paperclip"
			variant: "tonal"
			onClicked: if (!picker.running) picker.running = true
		}

		AreaField {
			id: field

			Layout.fillWidth: true
			Layout.preferredHeight: Math.max(40, Math.min(root.maxHeight, field.area.contentHeight + 28))
			placeholder: root.placeholder
			border.width: drop.containsDrag ? 2 : (field.focused ? 1.5 : 0)

			DropArea {
				id: drop

				anchors.fill: parent
				keys: ["text/uri-list"]
				onDropped: event => {
					root.add(event.urls);
					event.accept();
				}
			}
		}

		IconButton {
			Layout.alignment: Qt.AlignBottom
			implicitWidth: 40
			implicitHeight: 40
			icon: "send"
			variant: "filled"
			enabled: root.ready
			onClicked: root.submit()

			Spinner {
				anchors.centerIn: parent
				visible: root.busy
				width: 18
				height: 18
				color: Theme.onPrimary
			}
		}
	}

	Shortcut {
		sequences: ["Ctrl+Return", "Ctrl+Enter"]
		enabled: field.focused && root.ready
		onActivated: root.submit()
	}

	// the desktop's own file chooser
	Process {
		id: picker

		command: ["python3", `${Paths.scripts}/pick_files.py`]
		stdout: SplitParser {
			onRead: line => root.add([line])
		}
	}
}
