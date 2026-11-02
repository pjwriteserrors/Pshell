pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// What a pause is good for: where one is, how long is left and who was just
// talked about. Only what was seen, and no chapter names in a spoiler series.
Rectangle {
	id: root

	property string seriesId: ""
	property string video: ""
	property real position: 0
	property real duration: 0
	property real rate: 1
	property string chapter: ""
	property string title: ""
	property real ui: 1
	property bool wanted: false
	property var people: []
	readonly property real remaining: Math.max(0, root.duration - root.position) / Math.max(0.25, root.rate)

	width: 360 * root.ui
	height: column.implicitHeight + 28 * root.ui
	radius: 14 * root.ui
	color: Qt.rgba(0, 0, 0, 0.72)
	opacity: root.wanted ? 1 : 0
	visible: opacity > 0.01

	Behavior on opacity {
		Anim {}
	}

	onWantedChanged: {
		if (!root.wanted) return;
		root.people = [];
		if (root.seriesId) Streams.call("whoNow", { series: root.seriesId, video: root.video, at: root.position }, data => root.people = data?.people ?? []);
	}

	ColumnLayout {
		id: column

		anchors.left: parent.left
		anchors.right: parent.right
		anchors.top: parent.top
		anchors.margins: 14 * root.ui
		spacing: 4 * root.ui

		Text {
			Layout.fillWidth: true
			text: root.title
			color: "white"
			elide: Text.ElideRight
			font.family: Theme.fontFamily
			font.pixelSize: 16 * root.ui
			font.weight: Font.Bold
		}
		Text {
			Layout.fillWidth: true
			visible: root.chapter !== ""
			text: root.chapter
			color: Qt.rgba(1, 1, 1, 0.8)
			elide: Text.ElideRight
			font.family: Theme.fontFamily
			font.pixelSize: 14 * root.ui
		}
		Text {
			Layout.fillWidth: true
			visible: root.duration > 0
			text: `${Streams.span(root.remaining)} left · over at ${Qt.formatTime(new Date(Date.now() + root.remaining * 1000), "hh:mm")}`
			color: Qt.rgba(1, 1, 1, 0.66)
			font.family: Theme.fontFamily
			font.pixelSize: 13 * root.ui
		}
		Repeater {
			model: root.people.slice(0, 3)

			Text {
				required property var modelData

				Layout.fillWidth: true
				text: modelData.facts.length > 0 ? `${modelData.name}: ${modelData.facts[0].value}` : modelData.name
				color: Qt.rgba(1, 1, 1, 0.8)
				elide: Text.ElideRight
				font.family: Theme.fontFamily
				font.pixelSize: 13 * root.ui
			}
		}
	}
}
