pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// What changed between two PDFs, page by page: lines only in the second
// one in green, lines that are gone in red.
DialogFrame {
	id: root

	property var result: ({})
	readonly property var changes: root.result.changes ?? []

	function open(result) {
		root.result = result;
		root.show();
		keys.forceActiveFocus();
	}

	cardWidth: 680
	onDismissed: root.hide()

	Item {
		id: keys

		focus: root.shown
		Keys.onEscapePressed: root.hide()
		Keys.onReturnPressed: root.hide()
	}

	ColumnLayout {
		width: parent.width
		spacing: 14

		ColumnLayout {
			spacing: 1

			StyledText {
				text: root.changes.length === 0 ? "The text is the same" : `${root.changes.length} page${root.changes.length === 1 ? "" : "s"} differ`
				font.pixelSize: Theme.size.title
				font.weight: Font.DemiBold
			}

			StyledText {
				Layout.fillWidth: true
				text: `${root.result.a ?? ""}  →  ${root.result.b ?? ""}`
				tone: Theme.textSubtle
				font.pixelSize: Theme.size.small
				elide: Text.ElideMiddle
			}
		}

		Rectangle {
			Layout.fillWidth: true
			Layout.preferredHeight: Math.min(480, Math.max(60, changeList.implicitHeight + 20))
			radius: Theme.radius.large
			color: Theme.layer2

			Flickable {
				anchors.fill: parent
				anchors.margins: 10
				contentHeight: changeList.implicitHeight
				clip: true
				boundsBehavior: Flickable.StopAtBounds

				ScrollBar.vertical: ThinScrollBar {}

				Column {
					id: changeList

					width: parent.width
					spacing: 12

					StyledText {
						visible: root.changes.length === 0
						text: "Pictures and layout are not compared, only the words."
						tone: Theme.textMuted
					}

					Repeater {
						model: root.changes

						delegate: Column {
							id: pageChanges

							required property var modelData

							width: changeList.width
							spacing: 2

							StyledText {
								text: `Page ${pageChanges.modelData.page}`
								font.weight: Font.DemiBold
								font.pixelSize: Theme.size.small
								tone: Theme.textMuted
							}

							Repeater {
								model: pageChanges.modelData.lines

								delegate: Rectangle {
									required property var modelData

									width: pageChanges.width
									height: line.implicitHeight + 6
									radius: 4
									color: Qt.alpha(modelData.kind === "added" ? Theme.success : Theme.danger, 0.12)

									Text {
										id: line

										x: 8
										y: 3
										width: parent.width - 16
										text: `${parent.modelData.kind === "added" ? "+" : "−"}  ${parent.modelData.text}`
										color: parent.modelData.kind === "added" ? Theme.success : Theme.danger
										font.family: Theme.monoFamily
										font.pixelSize: Theme.size.small
										wrapMode: Text.Wrap
									}
								}
							}
						}
					}
				}
			}
		}

		RowLayout {
			Layout.alignment: Qt.AlignRight

			TextButton {
				text: "Done"
				variant: "filled"
				onClicked: root.hide()
			}
		}
	}
}
