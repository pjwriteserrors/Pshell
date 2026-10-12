pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// Bringing two folders in step: which way, whether what is only on the
// other side goes, and – before anything happens – what would be done.
DialogFrame {
	id: root

	property string leftPath: ""
	property string rightPath: ""
	property string direction: "right"
	property bool remove: false
	property var steps: []
	property int count: 0
	property bool loading: false
	property string error: ""

	readonly property string source: root.direction === "left" ? root.rightPath : root.leftPath
	readonly property string target: root.direction === "left" ? root.leftPath : root.rightPath

	function open(leftPath, rightPath) {
		root.leftPath = leftPath;
		root.rightPath = rightPath;
		root.direction = "right";
		root.remove = false;
		root.show();
		keys.forceActiveFocus();
		root.plan();
	}

	function plan() {
		root.loading = true;
		root.error = "";
		const asked = `${root.direction}|${root.remove}`;
		Files.syncPlan(root.source, root.target, root.direction === "both" ? "both" : "one", root.remove, (data, error) => {
			if (asked !== `${root.direction}|${root.remove}`) return;
			root.loading = false;
			root.error = error || "";
			root.steps = (data?.steps ?? []).map(step => Object.assign({ way: "there" }, step)).concat((data?.back ?? []).map(step => Object.assign({ way: "back" }, step)));
			root.count = data?.count ?? 0;
		});
	}

	onDirectionChanged: if (root.shown) root.plan()
	onRemoveChanged: if (root.shown) root.plan()

	function run() {
		if (root.count === 0) return;
		Files.sync(root.source, root.target, root.direction === "both" ? "both" : "one", root.remove);
		root.hide();
	}

	cardWidth: 560
	onDismissed: root.hide()

	Item {
		id: keys

		focus: root.shown
		Keys.onEscapePressed: root.hide()
		Keys.onReturnPressed: root.run()
		Keys.onEnterPressed: root.run()
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
				color: Qt.tint(Theme.layer2, Qt.alpha(Theme.tertiary, 0.2))

				Glyph {
					anchors.centerIn: parent
					icon: "folder_sync_outline"
					size: 20
					color: Theme.tertiary
				}
			}

			ColumnLayout {
				Layout.fillWidth: true
				spacing: 1

				StyledText {
					text: "Sync the two sides"
					font.pixelSize: Theme.size.title
					font.weight: Font.DemiBold
				}

				StyledText {
					Layout.fillWidth: true
					text: `${Files.pretty(root.leftPath)}  ·  ${Files.pretty(root.rightPath)}`
					tone: Theme.textSubtle
					font.pixelSize: Theme.size.small
					elide: Text.ElideMiddle
				}
			}
		}

		Segmented {
			Layout.fillWidth: true
			height: 34
			options: [
				{ value: "right", label: `${Files.nameOf(root.leftPath)} → ${Files.nameOf(root.rightPath)}` },
				{ value: "left", label: `${Files.nameOf(root.leftPath)} ← ${Files.nameOf(root.rightPath)}` },
				{ value: "both", label: "Both ways" }
			]
			current: root.direction
			onSelected: value => root.direction = value
		}

		RowLayout {
			Layout.fillWidth: true
			visible: root.direction !== "both"

			ColumnLayout {
				Layout.fillWidth: true
				spacing: 1

				StyledText {
					text: `Remove what is only in ${Files.nameOf(root.target)}`
				}

				StyledText {
					Layout.fillWidth: true
					text: "It is kept in .sync-removed there, not lost"
					tone: Theme.textSubtle
					font.pixelSize: Theme.size.small
				}
			}

			Toggle {
				checked: root.remove
				onToggled: on => root.remove = on
			}
		}

		StyledText {
			Layout.fillWidth: true
			text: root.loading ? "Working out what to do…" : (root.error || (root.count === 0 ? "Nothing to do – the sides are in step" : `${root.count} change${root.count === 1 ? "" : "s"}:`))
			tone: root.error ? Theme.danger : Theme.textMuted
			font.pixelSize: Theme.size.small
			wrapMode: Text.WordWrap
		}

		Rectangle {
			Layout.fillWidth: true
			Layout.preferredHeight: Math.min(260, planList.implicitHeight + 12)
			visible: root.steps.length > 0
			radius: Theme.radius.large
			color: Theme.layer2
			clip: true

			Flickable {
				anchors.fill: parent
				anchors.margins: 6
				contentHeight: planList.implicitHeight
				boundsBehavior: Flickable.StopAtBounds

				Column {
					id: planList

					width: parent.width

					Repeater {
						model: root.steps.slice(0, 300)

						delegate: RowLayout {
							required property var modelData

							width: planList.width
							height: 26
							spacing: 8

							Glyph {
								icon: modelData.action === "delete" ? "minus_circle_outline" : (modelData.action === "copy" ? "plus_circle_outline" : "sync")
								size: 15
								color: modelData.action === "delete" ? Theme.danger : (modelData.action === "copy" ? Theme.success : Theme.warning)
							}

							StyledText {
								Layout.fillWidth: true
								text: modelData.path
								font.family: Theme.monoFamily
								font.pixelSize: Theme.size.small
								elide: Text.ElideMiddle
							}

							StyledText {
								text: root.direction === "both" ? (modelData.way === "back" ? "←" : "→") : ""
								tone: Theme.textSubtle
							}
						}
					}
				}
			}
		}

		RowLayout {
			Layout.fillWidth: true
			spacing: 8

			Item {
				Layout.fillWidth: true
			}

			TextButton {
				text: "Cancel"
				variant: "ghost"
				onClicked: root.hide()
			}

			TextButton {
				text: "Sync"
				icon: "folder_sync_outline"
				variant: "filled"
				enabled: root.count > 0 && !root.loading
				opacity: enabled ? 1 : 0.5
				onClicked: root.run()
			}
		}
	}
}
