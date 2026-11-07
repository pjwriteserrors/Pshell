pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import qs.style.theme
import qs.style.widgets
import qs.core.services

// The folder's other PDFs (how far each was read), and the files attached
// to this one – opened at a click.
Item {
	id: root

	readonly property var attachments: Pdf.meta?.attachments ?? []

	function openAttachment(name) {
		Pdf.request("detach", { path: Pdf.sourcePath("a"), name: name, out: "", password: Pdf.password }, data => {
			if (!data?.path) return Pdf.say("That attachment could not be taken out", "alert_circle_outline");
			if (Pdf.isPdf(data.path)) Pdf.open(data.path);
			else Qt.openUrlExternally(Pdf.fileUrl(data.path));
		});
	}

	ListView {
		id: list

		anchors.fill: parent
		clip: true
		boundsBehavior: Flickable.StopAtBounds
		model: Pdf.list
		spacing: 2

		ScrollBar.vertical: ThinScrollBar {}

		header: Column {
			width: list.width
			visible: root.attachments.length > 0
			height: visible ? implicitHeight + 8 : 0
			spacing: 2

			StyledText {
				leftPadding: 12
				text: "Attached"
				tone: Theme.textSubtle
				font.pixelSize: Theme.size.small
				font.weight: Font.DemiBold
			}

			Repeater {
				model: root.attachments

				Clickable {
					id: attached

					required property var modelData

					x: 6
					width: list.width - 12
					height: 38
					radius: Theme.radius.small
					color: attached.hovered ? Theme.layer1 : "transparent"
					onClicked: root.openAttachment(attached.modelData.name)

					Row {
						anchors.fill: parent
						anchors.leftMargin: 10
						spacing: 8

						Glyph {
							anchors.verticalCenter: parent.verticalCenter
							icon: "paperclip"
							size: 16
							color: Theme.primary
						}
						StyledText {
							anchors.verticalCenter: parent.verticalCenter
							width: parent.width - 80
							text: attached.modelData.name
							elide: Text.ElideMiddle
						}
						StyledText {
							anchors.verticalCenter: parent.verticalCenter
							text: Pdf.formatBytes(attached.modelData.bytes)
							tone: Theme.textSubtle
							font.pixelSize: Theme.size.small
						}
					}
				}
			}

			StyledText {
				leftPadding: 12
				topPadding: 8
				text: "In the folder"
				tone: Theme.textSubtle
				font.pixelSize: Theme.size.small
				font.weight: Font.DemiBold
			}
		}

		delegate: Clickable {
			id: row

			required property string modelData
			readonly property bool here: row.modelData === Pdf.path
			readonly property real read: Pdf.progressOf(row.modelData)

			x: 6
			width: list.width - 12
			height: 42
			radius: Theme.radius.small
			color: row.here ? Theme.primarySoft : (row.hovered ? Theme.layer1 : "transparent")
			onClicked: if (!row.here) Pdf.open(row.modelData)

			Glyph {
				id: icon

				x: 10
				anchors.verticalCenter: parent.verticalCenter
				icon: "file_pdf_box"
				size: 18
				color: row.here ? Theme.primary : Theme.textMuted
			}
			StyledText {
				anchors.left: icon.right
				anchors.leftMargin: 8
				anchors.right: parent.right
				anchors.rightMargin: 10
				anchors.verticalCenter: parent.verticalCenter
				anchors.verticalCenterOffset: row.read > 0 ? -3 : 0
				text: Pdf.nameOf(row.modelData)
				elide: Text.ElideMiddle
				font.weight: row.here ? Font.DemiBold : Font.Normal
			}
			// how far it was read
			Rectangle {
				visible: row.read > 0
				anchors.left: icon.right
				anchors.leftMargin: 8
				anchors.bottom: parent.bottom
				anchors.bottomMargin: 8
				width: (row.width - 56) * row.read
				height: 3
				radius: 1.5
				color: Theme.primary
				opacity: 0.6
			}
		}
	}
}
