pragma ComponentBehavior: Bound

import QtQuick
import qs.style.theme
import qs.style.widgets
import qs.core.services
import "../video"

// Comparing: another version of this file chosen – one beside it, one read
// lately, an earlier save, or any – and both laid side by side over the
// window, the differences outlined (Compare.qml).
PaneFrame {
	id: root

	property Item dock: null
	readonly property var near: Pdf.list.filter(p => p !== Pdf.path).slice(0, 12)
	readonly property var lately: Pdf.recent.filter(p => p !== Pdf.path && !root.near.includes(p)).slice(0, 8)

	title: "Compare"
	subtitle: "With another version – the pages side by side"
	onClose: Pdf.tool = ""

	Component.onCompleted: Pdf.loadVersions()

	function row(path, detail) {
		return { path: path, detail: detail };
	}

	TextButton {
		width: parent.width
		text: "Choose the other file…"
		icon: "file_find_outline"
		variant: "filled"
		onActivated: Files.pick({ title: "Compare with", filters: ["*.pdf"], folder: Pdf.folderOf(Pdf.path) }, paths => {
			if (paths?.length) Pdf.compareWith = paths[0];
		})
	}

	Repeater {
		model: [
			{ label: "Earlier saves of it", rows: Pdf.versionList.map(v => root.row(v.path, String(v.stamp).replace("T", " ").slice(0, 16))) },
			{ label: "Beside it", rows: root.near.map(p => root.row(p, "")) },
			{ label: "Read lately", rows: root.lately.map(p => root.row(p, Pdf.folderOf(p))) }
		].filter(g => g.rows.length > 0)

		delegate: Column {
			id: group

			required property var modelData

			width: parent.width
			spacing: 2

			SectionLabel {
				text: group.modelData.label
				bottomPadding: 4
			}

			Repeater {
				model: group.modelData.rows

				delegate: Clickable {
					id: pick

					required property var modelData

					width: group.width
					height: pick.modelData.detail ? 44 : 34
					radius: Theme.radius.small
					color: pick.hovered ? Theme.layer2 : "transparent"
					onClicked: Pdf.compareWith = pick.modelData.path

					Glyph {
						id: pdfIcon

						x: 8
						anchors.verticalCenter: parent.verticalCenter
						icon: "file_pdf_box"
						size: 18
					}

					Column {
						anchors.left: pdfIcon.right
						anchors.leftMargin: 10
						anchors.right: parent.right
						anchors.rightMargin: 8
						anchors.verticalCenter: parent.verticalCenter

						StyledText {
							width: parent.width
							text: Pdf.nameOf(pick.modelData.path)
							elide: Text.ElideMiddle
						}

						StyledText {
							width: parent.width
							visible: pick.modelData.detail !== ""
							text: pick.modelData.detail
							elide: Text.ElideMiddle
							font.pixelSize: Theme.size.tiny
							tone: Theme.textSubtle
						}
					}
				}
			}
		}
	}
}
