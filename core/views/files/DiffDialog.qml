pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// What changed in a file (or a folder) since the last commit: the lines
// that went red, the ones that came green, and the last commits of it.
DialogFrame {
	id: root

	property string path: ""
	property var lines: []
	property var commits: []
	property bool loading: false
	property string error: ""
	signal commitAsked(string path)

	function open(path) {
		root.path = path;
		root.lines = [];
		root.commits = [];
		root.error = "";
		root.loading = true;
		root.show();
		keys.forceActiveFocus();
		Files.request("gitdiff", { path: path }, (data, error) => {
			root.loading = false;
			if (error) {
				root.error = error;
				return;
			}
			root.lines = String(data.diff || "").split("\n").slice(0, 4000);
			root.commits = data.commits ?? [];
		});
	}

	function toneOf(line) {
		if (line.startsWith("+++") || line.startsWith("---")) return "head";
		if (line.startsWith("@@")) return "hunk";
		if (line.startsWith("+")) return "add";
		if (line.startsWith("-")) return "remove";
		if (line.startsWith("diff ") || line.startsWith("index ") || line.startsWith("new file")) return "head";
		return "";
	}

	cardWidth: 860
	onDismissed: root.hide()

	Item {
		id: keys

		focus: root.shown
		Keys.onEscapePressed: root.hide()
	}

	ColumnLayout {
		width: parent.width
		spacing: 12

		RowLayout {
			spacing: 12

			Rectangle {
				width: 40
				height: 40
				radius: 13
				color: Qt.tint(Theme.layer2, Qt.alpha(Theme.warning, 0.2))

				Glyph {
					anchors.centerIn: parent
					icon: "file_compare"
					size: 20
					color: Theme.warning
				}
			}

			ColumnLayout {
				Layout.fillWidth: true
				spacing: 1

				StyledText {
					text: `Changes in ${Files.nameOf(root.path)}`
					font.pixelSize: Theme.size.title
					font.weight: Font.DemiBold
				}

				StyledText {
					Layout.fillWidth: true
					text: {
						const added = root.lines.filter(line => line.startsWith("+") && !line.startsWith("+++")).length;
						const removed = root.lines.filter(line => line.startsWith("-") && !line.startsWith("---")).length;
						return root.loading ? "Reading…" : (root.error || `${added} lines added · ${removed} removed since the last commit`);
					}
					tone: Theme.textSubtle
					font.pixelSize: Theme.size.small
					elide: Text.ElideRight
				}
			}

			TextButton {
				text: "Commit…"
				icon: "source_commit"
				variant: "tonal"
				height: 32
				enabled: root.lines.length > 1
				onClicked: {
					root.hide();
					root.commitAsked(root.path);
				}
			}
		}

		Rectangle {
			Layout.fillWidth: true
			Layout.preferredHeight: Math.max(200, root.height - 300)
			radius: Theme.radius.large
			color: Theme.layer2
			clip: true

			ListView {
				id: diffList

				anchors.fill: parent
				anchors.margins: 8
				model: root.lines
				boundsBehavior: Flickable.StopAtBounds
				reuseItems: true

				ScrollBar.vertical: ThinScrollBar {}

				delegate: Rectangle {
					id: line

					required property string modelData
					readonly property string tone: root.toneOf(line.modelData)

					width: diffList.width
					height: lineText.implicitHeight + 2
					color: line.tone === "add" ? Qt.alpha(Theme.success, 0.14) : (line.tone === "remove" ? Qt.alpha(Theme.danger, 0.14) : (line.tone === "hunk" ? Qt.alpha(Theme.primary, 0.1) : "transparent"))

					Text {
						id: lineText

						x: 6
						width: parent.width - 12
						text: line.modelData === "" ? " " : line.modelData
						color: line.tone === "add" ? Theme.success : (line.tone === "remove" ? Theme.danger : (line.tone === "hunk" ? Theme.primary : (line.tone === "head" ? Theme.textMuted : Theme.text)))
						font.family: Theme.monoFamily
						font.pixelSize: Theme.size.small
						font.weight: line.tone === "head" ? Font.DemiBold : Font.Normal
						wrapMode: Text.WrapAnywhere
					}
				}
			}

			EmptyState {
				anchors.centerIn: parent
				visible: !root.loading && root.lines.length <= 1 && root.error === ""
				icon: "check_circle_outline"
				title: "Nothing changed"
				subtitle: "It is the same as in the last commit"
			}

			Spinner {
				anchors.centerIn: parent
				visible: root.loading
				width: 22
				height: 22
			}
		}

		Flow {
			Layout.fillWidth: true
			spacing: 6
			visible: root.commits.length > 0

			StyledText {
				text: "Last commits:"
				tone: Theme.textSubtle
				font.pixelSize: Theme.size.small
				height: 26
				verticalAlignment: Text.AlignVCenter
			}

			Repeater {
				model: root.commits.slice(0, 5)

				delegate: Chip {
					required property var modelData

					height: 26
					icon: "source_commit"
					text: `${modelData.subject} · ${modelData.when}`
				}
			}
		}
	}
}
