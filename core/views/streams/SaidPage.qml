pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// Something somebody said, in everything that was seen. Also >said in the launcher.
ColumnLayout {
	id: root

	property var hits: []

	spacing: 14

	function search(text) {
		Streams.call("searchAll", { query: text }, data => root.hits = data ?? []);
	}

	Component.onCompleted: {
		field.text = Streams.saidWanted;
		field.input.forceActiveFocus();
		if (Streams.saidWanted) root.search(Streams.saidWanted);
		Streams.saidWanted = "";
	}

	Item {
		Layout.preferredHeight: 64
	}
	Text {
		Layout.leftMargin: 44
		text: "What was said"
		color: Theme.text
		font.family: Theme.fontFamily
		font.pixelSize: 34
		font.weight: Font.Black
	}
	Field {
		id: field

		Layout.fillWidth: true
		Layout.leftMargin: 44
		Layout.rightMargin: 44
		icon: "magnify"
		placeholder: "A name, a sentence, anything said in what you have seen"
		onEdited: text => debounce.restart()

		Timer {
			id: debounce

			interval: 220
			onTriggered: root.search(field.text)
		}
	}
	ListView {
		id: list

		Layout.fillWidth: true
		Layout.fillHeight: true
		Layout.leftMargin: 44
		Layout.rightMargin: 44
		clip: true
		spacing: 6
		boundsBehavior: Flickable.StopAtBounds
		model: root.hits
		ScrollBar.vertical: ThinScrollBar {}

		delegate: Clickable {
			id: hit

			required property var modelData

			width: list.width - 12
			implicitHeight: column.implicitHeight + 16
			radius: Theme.radius.small
			color: Theme.layer2
			onClicked: Streams.call("play", { video: hit.modelData.video, player: "app", at: hit.modelData.at })

			ColumnLayout {
				id: column

				anchors.left: parent.left
				anchors.right: parent.right
				anchors.top: parent.top
				anchors.margins: 8
				spacing: 2

				StyledText {
					Layout.fillWidth: true
					text: hit.modelData.text
					wrapMode: Text.Wrap
				}
				StyledText {
					Layout.fillWidth: true
					text: `${Streams.clock(hit.modelData.at)} · ${hit.modelData.title}`
					tone: Theme.textMuted
					font.pixelSize: Theme.size.small
					elide: Text.ElideRight
				}
			}
		}
	}
}
