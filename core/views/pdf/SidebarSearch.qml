pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import qs.style.theme
import qs.style.widgets
import qs.core.services

// What a search found, with the words around each, by page; a click shows it.
Item {
	id: root

	property var reader: null
	readonly property var hits: root.reader ? root.reader.hits.slice(0, 600) : []

	Field {
		id: field

		anchors.left: parent.left
		anchors.right: parent.right
		anchors.margins: 8
		height: 34
		icon: "magnify"
		placeholder: "Search the file"
		text: Pdf.searchText
		onEdited: text => typing.restart()
		onAccepted: Pdf.searchStep(1)
	}

	Timer {
		id: typing

		interval: 260
		onTriggered: {
			Pdf.searchCurrent = -1;
			Pdf.searchText = field.text.trim();
		}
	}

	ListView {
		id: list

		anchors.left: parent.left
		anchors.right: parent.right
		anchors.top: field.bottom
		anchors.bottom: parent.bottom
		anchors.topMargin: 6
		model: root.hits
		spacing: 2
		clip: true
		boundsBehavior: Flickable.StopAtBounds
		currentIndex: Pdf.searchCurrent
		highlightFollowsCurrentItem: false
		onCurrentIndexChanged: if (list.currentIndex >= 0) list.positionViewAtIndex(list.currentIndex, ListView.Contain)

		ScrollBar.vertical: ThinScrollBar {}

		section.property: "index"
		section.delegate: StyledText {
			required property string section

			leftPadding: 12
			topPadding: 6
			text: `Page ${Number(section) + 1}`
			tone: Theme.textSubtle
			font.pixelSize: Theme.size.small
			font.weight: Font.DemiBold
		}

		delegate: Clickable {
			id: row

			required property var modelData
			required property int index

			x: 6
			width: list.width - 12
			height: words.implicitHeight + 12
			radius: Theme.radius.small
			color: row.index === Pdf.searchCurrent ? Theme.primarySoft : (row.hovered ? Theme.layer1 : "transparent")
			onClicked: {
				Pdf.searchCurrent = row.index;
				root.reader?.showHit();
			}

			StyledText {
				id: words

				anchors.left: parent.left
				anchors.right: parent.right
				anchors.margins: 8
				anchors.verticalCenter: parent.verticalCenter
				textFormat: Text.StyledText
				wrapMode: Text.WordWrap
				maximumLineCount: 2
				elide: Text.ElideRight
				font.pixelSize: Theme.size.small
				text: `${root.plain(row.modelData.before)}<b><font color="${Theme.primary}">${root.plain(Pdf.searchText)}</font></b>${root.plain(row.modelData.after)}`
			}
		}
	}

	function plain(text) {
		return String(text || "").replace(/[\r\n]+/g, " ").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
	}

	StyledText {
		anchors.centerIn: list
		visible: Pdf.searchText !== "" && root.hits.length === 0
		text: "Not in the text (a scan needs its words read first)"
		width: 200
		wrapMode: Text.WordWrap
		horizontalAlignment: Text.AlignHCenter
		tone: Theme.textSubtle
	}
}
