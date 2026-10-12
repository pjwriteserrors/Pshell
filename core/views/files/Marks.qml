pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.style.widgets
import qs.core.services

// Small signs on a file: changed in git, how it compares with the other
// side of a split, a note stuck to it.
Row {
	id: root

	property var pane: null
	property string path: ""
	property string name: ""
	property bool compact: false

	readonly property string git: FileLibrary.setting("gitBadges") === false ? "" : String(root.pane?.git?.files?.[root.name] ?? "")
	readonly property string compared: String(root.pane?.compareStates?.[root.name] ?? "")
	readonly property string note: {
		FileLibrary.notes;
		return FileLibrary.noteOf(root.path);
	}

	spacing: 3
	visible: root.git !== "" || (root.compared !== "" && root.compared !== "same") || root.note !== ""

	Rectangle {
		visible: root.git !== ""
		anchors.verticalCenter: parent.verticalCenter
		width: 16
		height: 16
		radius: 8
		color: ({ M: Theme.warning, A: Theme.success, "?": Theme.success, D: Theme.danger, U: Theme.tertiary, R: Theme.primary })[root.git] ?? Theme.textMuted
		border.width: 1.5
		border.color: Theme.base

		Text {
			anchors.centerIn: parent
			text: root.git === "?" ? "+" : root.git
			color: Theme.base
			font.family: Theme.fontFamily
			font.pixelSize: 9
			font.weight: Font.Black
		}
	}

	Rectangle {
		visible: root.compared !== "" && root.compared !== "same"
		anchors.verticalCenter: parent.verticalCenter
		width: compareText.implicitWidth + 10
		height: 16
		radius: 8
		color: root.compared === "only" ? Theme.tertiary : (root.compared === "newer" ? Theme.success : (root.compared === "older" ? Theme.warning : Theme.danger))
		border.width: 1.5
		border.color: Theme.base

		Text {
			id: compareText

			anchors.centerIn: parent
			text: ({ only: root.compact ? "only" : "only here", newer: "newer", older: "older", differs: "differs", changed: "changed" })[root.compared] ?? root.compared
			color: Theme.base
			font.family: Theme.fontFamily
			font.pixelSize: 9
			font.weight: Font.Bold
		}
	}

	Rectangle {
		visible: root.note !== ""
		anchors.verticalCenter: parent.verticalCenter
		width: 16
		height: 16
		radius: 5
		color: Theme.warning
		border.width: 1.5
		border.color: Theme.base

		Glyph {
			anchors.centerIn: parent
			icon: "note_text_outline"
			size: 10
			color: Theme.base
			animated: false
		}
	}
}
