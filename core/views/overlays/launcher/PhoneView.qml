pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.style.theme
import qs.core.services
import qs.style.widgets

// Launcher >phone: KDE Connect. Typed text is sent as text; otherwise the
// clipboard, ring and "send file" (which switches to the file browser in
// picking mode).
ColumnLayout {
	id: root

	property string argument: ""
	property bool active: false
	property int currentIndex: 0
	readonly property string text: String(root.argument || "").trim()
	readonly property var actions: {
		const fixed = [
			{ id: "clipboard", icon: "content_paste", title: "Send clipboard" },
			{ id: "ring", icon: "phone_ring", title: "Ring" },
			{ id: "file", icon: "file_send", title: "Send file" }
		];
		if (root.text === "") return fixed;
		return [{ id: "text", icon: "send", title: root.text }].concat(fixed);
	}

	signal closeRequested
	signal pickFileRequested

	spacing: 12

	onActiveChanged: {
		if (!root.active) return;
		root.currentIndex = 0;
		KdeConnect.refresh();
	}
	onTextChanged: root.currentIndex = 0

	function move(delta) {
		root.currentIndex = Math.max(0, Math.min(root.actions.length - 1, root.currentIndex + delta));
	}

	function handleKey(event) {
		return false;
	}

	function cancel() {
		return false;
	}

	function activate(modifiers) {
		root.run(root.actions[root.currentIndex]);
	}

	function run(action) {
		if (!action) return;
		switch (action.id) {
		case "text":
			KdeConnect.sendText(root.text);
			root.closeRequested();
			break;
		case "clipboard":
			KdeConnect.sendClipboard();
			root.closeRequested();
			break;
		case "ring":
			KdeConnect.ring();
			root.closeRequested();
			break;
		case "file":
			root.pickFileRequested();
			break;
		}
	}

	RowLayout {
		Layout.fillWidth: true
		Layout.leftMargin: 6
		spacing: 12

		Rectangle {
			Layout.preferredWidth: 42
			Layout.preferredHeight: 42
			radius: 21
			color: KdeConnect.reachable ? Qt.alpha(Theme.success, 0.22) : Theme.layer2

			Glyph {
				anchors.centerIn: parent
				icon: KdeConnect.reachable ? "cellphone" : "cellphone_off"
				size: 20
				color: KdeConnect.reachable ? Theme.text : Theme.textMuted
			}
		}

		ColumnLayout {
			Layout.fillWidth: true
			spacing: 0

			StyledText {
				Layout.fillWidth: true
				text: KdeConnect.name
				font.pixelSize: Theme.size.title
				font.weight: Font.Bold
			}

			StyledText {
				Layout.fillWidth: true
				text: KdeConnect.summary
				tone: Theme.textMuted
				font.pixelSize: Theme.size.small
			}
		}

		Glyph {
			visible: KdeConnect.battery >= 0
			icon: KdeConnect.batteryIcon
			size: 18
			color: Theme.textMuted
		}
	}

	ListView {
		id: actionList

		Layout.fillWidth: true
		Layout.fillHeight: true
		clip: true
		spacing: 2
		model: root.actions
		currentIndex: root.currentIndex
		boundsBehavior: Flickable.StopAtBounds
		ScrollBar.vertical: ThinScrollBar {}

		delegate: ListItem {
			id: actionRow

			required property var modelData
			required property int index

			width: actionList.width
			icon: actionRow.modelData.icon
			title: actionRow.modelData.title
			selected: root.currentIndex === actionRow.index
			opacity: KdeConnect.reachable ? 1 : 0.5
			onEntered: root.currentIndex = actionRow.index
			onClicked: root.run(actionRow.modelData)
		}
	}
}
