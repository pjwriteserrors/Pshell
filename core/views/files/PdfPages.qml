pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Pdf
import qs.style.widgets
import qs.core.services

// A PDF's pages one under the other, for the quick look. A file of its own,
// loaded by URL: QtQuick.Pdf comes with qt6-webengine, and without it only
// this preview is missing instead of the whole shell failing to load.
Item {
	id: root

	property string path: ""

	PdfDocument {
		id: pdf

		source: root.path !== "" ? Files.uri(root.path) : ""
	}

	ListView {
		id: pageList

		anchors.fill: parent
		model: pdf.status === PdfDocument.Ready ? pdf.pageCount : 0
		spacing: 14
		clip: true
		cacheBuffer: 1200
		boundsBehavior: Flickable.StopAtBounds

		ScrollBar.vertical: ThinScrollBar {}

		delegate: Item {
			id: pageItem

			required property int index
			readonly property size pageSize: pdf.pagePointSize(pageItem.index)

			width: pageList.width
			height: pageList.width * 0.8 * (pageItem.pageSize.height / Math.max(1, pageItem.pageSize.width))

			Rectangle {
				anchors.horizontalCenter: parent.horizontalCenter
				width: parent.width * 0.8
				height: parent.height
				color: "white"
				radius: 3

				PdfPageImage {
					anchors.fill: parent
					document: pdf
					currentFrame: pageItem.index
					asynchronous: true
					sourceSize.width: width * 1.5
				}
			}
		}
	}
}
