pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets

// One folder as a list: the path on top takes a typed or pasted one, below
// it the folders to step into and the files. With `picking` a click on a
// file picks it.
ColumnLayout {
	id: root

	property string icon: "folder"
	property string path: ""
	property var entries: []
	property string error: ""
	property bool loading: false
	property bool showHidden: false
	property bool picking: false
	// paths of the picked files
	property var picked: []
	readonly property var rows: root.showHidden ? root.entries : root.entries.filter(entry => !String(entry.name).startsWith("."))

	signal opened(string path)
	signal toggled(string path)

	function focusPath() {
		field.focusInput();
		field.input.selectAll();
	}

	function join(name) {
		return root.path.endsWith("/") ? root.path + name : `${root.path}/${name}`;
	}

	function upPath() {
		return root.path.replace(/\/[^\/]+\/*$/, "") || "/";
	}

	function sizeText(bytes) {
		const units = ["B", "KB", "MB", "GB", "TB"];
		let value = Number(bytes) || 0;
		let unit = 0;
		while (value >= 1024 && unit < units.length - 1) {
			value /= 1024;
			unit += 1;
		}
		return `${unit === 0 || value >= 100 ? Math.round(value) : value.toFixed(1)} ${units[unit]}`;
	}

	// What an edit put in. More than one character at once came from the
	// clipboard.
	function inserted(before, after) {
		let start = 0;
		while (start < before.length && start < after.length && before[start] === after[start]) start += 1;
		let end = 0;
		while (end < before.length - start && end < after.length - start && before[before.length - 1 - end] === after[after.length - 1 - end]) end += 1;
		return after.slice(start, after.length - end);
	}

	spacing: 8

	// every listing puts the folder it shows back into the field
	function showPath() {
		field.text = root.path;
		field.before = root.path;
		// the next paste replaces it
		if (field.focused) field.input.selectAll();
	}

	onPathChanged: root.showPath()
	onEntriesChanged: root.showPath()

	RowLayout {
		Layout.fillWidth: true
		spacing: 6

		IconButton {
			icon: "arrow_up"
			variant: "tonal"
			enabled: root.path !== "" && root.path !== "/"
			onClicked: root.opened(root.upPath())
		}

		Field {
			id: field

			property string before: ""

			Layout.fillWidth: true
			icon: root.icon
			placeholder: "Path"
			clearable: false
			onEdited: text => {
				const put = root.inserted(field.before, text).trim();
				field.before = text;
				if (put.length < 2) return;
				// a whole path stands for itself, wherever in the field it went
				root.opened(/^(["']?(\/|~)|file:\/\/)/.test(put) ? put : text);
			}
			onAccepted: root.opened(field.text)

			Spinner {
				anchors.right: parent.right
				anchors.rightMargin: 12
				anchors.verticalCenter: parent.verticalCenter
				width: 14
				height: 14
				visible: root.loading
			}
		}
	}

	Rectangle {
		Layout.fillWidth: true
		Layout.fillHeight: true
		radius: Theme.radius.large
		color: Theme.layer1

		EmptyState {
			anchors.centerIn: parent
			width: parent.width
			visible: root.error !== "" || (root.rows.length === 0 && !root.loading && root.path !== "")
			icon: root.error !== "" ? "alert" : "folder_outline"
			title: root.error !== "" ? root.error : "Empty"
		}

		ListView {
			anchors.fill: parent
			anchors.margins: 4
			visible: root.error === ""
			clip: true
			spacing: 1
			model: root.rows
			boundsBehavior: Flickable.StopAtBounds
			ScrollBar.vertical: ThinScrollBar {}

			delegate: Clickable {
				id: row

				required property var modelData
				readonly property bool dir: !!row.modelData.dir
				readonly property string full: root.join(String(row.modelData.name))
				readonly property bool chosen: !row.dir && root.picked.includes(row.full)

				width: ListView.view.width
				implicitHeight: 32
				radius: Theme.radius.medium
				pressedScale: 0.98
				interactive: row.dir || root.picking
				opacity: row.interactive ? 1 : 0.5
				color: row.chosen ? Qt.alpha(Theme.primary, 0.14) : (row.hovered ? Theme.layer2 : "transparent")
				onClicked: row.dir ? root.opened(row.full) : root.toggled(row.full)

				RowLayout {
					anchors.fill: parent
					anchors.leftMargin: 10
					anchors.rightMargin: 12
					spacing: 10

					Glyph {
						icon: row.dir ? "folder" : (row.chosen ? "check_circle" : "file_outline")
						size: 16
						color: row.dir || row.chosen ? Theme.primary : Theme.textMuted
					}

					StyledText {
						Layout.fillWidth: true
						text: String(row.modelData.name)
						elide: Text.ElideMiddle
					}

					StyledText {
						visible: !row.dir && root.picking
						text: root.sizeText(row.modelData.size)
						tone: Theme.textSubtle
						font.pixelSize: Theme.size.small
						tabular: true
					}
				}
			}
		}
	}
}
