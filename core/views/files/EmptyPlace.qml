import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// What a place says when there is nothing to show: an empty folder, a
// search that found nothing, a folder that cannot be read.
ColumnLayout {
	id: root

	property var pane: null
	readonly property string kind: root.pane?.location.kind ?? "dir"
	readonly property bool failed: (root.pane?.error ?? "") !== ""
	readonly property bool filtered: (root.pane?.filter ?? "") !== ""

	spacing: 10

	Item {
		Layout.alignment: Qt.AlignHCenter
		implicitWidth: 92
		implicitHeight: 92

		Rectangle {
			anchors.fill: parent
			radius: width * 0.32
			color: Qt.tint(Theme.layer1, Qt.alpha(root.failed ? Theme.danger : Theme.primary, 0.12))

			// a slow float, so the place does not feel dead
			SequentialAnimation on y {
				loops: Animation.Infinite
				running: root.visible

				NumberAnimation {
					from: 0
					to: -6
					duration: 1800
					easing.type: Easing.InOutSine
				}
				NumberAnimation {
					from: -6
					to: 0
					duration: 1800
					easing.type: Easing.InOutSine
				}
			}

			Spinner {
				visible: root.pane?.searching ?? false
				anchors.centerIn: parent
				width: 34
				height: 34
			}

			Glyph {
				visible: !(root.pane?.searching ?? false)
				anchors.centerIn: parent
				size: 40
				color: root.failed ? Theme.danger : Qt.alpha(Theme.primary, 0.85)
				icon: {
					if (root.failed) return "folder_alert_outline";
					if (root.filtered || root.kind === "search") return "file_search_outline";
					switch (root.kind) {
					case "trash": return "trash_can_outline";
					case "recent": return "history";
					case "tag": return "tag_outline";
					case "collection": return "bookmark_box_multiple_outline";
					case "shelf": return "tray_arrow_down";
					default: return "folder_open_outline";
					}
				}
			}
		}
	}

	StyledText {
		Layout.alignment: Qt.AlignHCenter
		text: {
			if (root.failed) return root.pane.error;
			if (root.pane?.searching) return "Searching…";
			if (root.filtered) return `Nothing here matches “${root.pane.filter}”`;
			switch (root.kind) {
			case "search": return "Nothing found";
			case "trash": return "The trash is empty";
			case "recent": return "Nothing opened lately";
			case "tag": return "Nothing carries this tag yet";
			case "collection": return "This collection is empty";
			case "shelf": return "No files on this shelf";
			default: return "This folder is empty";
			}
		}
		font.pixelSize: Theme.size.title
		font.weight: Font.DemiBold
		tone: Theme.textMuted
	}

	StyledText {
		Layout.alignment: Qt.AlignHCenter
		Layout.maximumWidth: 320
		horizontalAlignment: Text.AlignHCenter
		wrapMode: Text.WordWrap
		visible: text !== ""
		text: {
			if (root.failed || root.pane?.searching) return "";
			switch (root.kind) {
			case "search": return root.pane?.location.contents ? "Contents are searched below the folder it started in." : "Try fewer words, or search the contents (Alt+C).";
			case "tag": return "Right-click a file and pick the tag, or drop files on the tag in the sidebar.";
			case "collection": return "Drop files on the collection in the sidebar. They stay where they are.";
			case "dir": return root.pane?.writable ? "Drop files here, paste with Ctrl+V, or make a folder with Ctrl+Shift+N." : "";
			default: return "";
			}
		}
		font.pixelSize: Theme.size.label
		tone: Theme.textSubtle
	}

	TextButton {
		Layout.alignment: Qt.AlignHCenter
		visible: root.failed
		text: "Try again"
		icon: "refresh"
		onClicked: root.pane.reload(true)
	}
}
