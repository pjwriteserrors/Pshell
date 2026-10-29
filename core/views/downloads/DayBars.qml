pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// What came in each day, as stacked bars: accelerated in the accent, normal
// below it, torrents on top. They grow one after the other when the page
// comes; the pointer on a day says its figures.
Item {
	id: root

	// [{ day, label, date, boost, normal, torrent, count }]
	property var days: []
	property bool play: true
	readonly property real highest: Math.max(1, ...root.days.map(day => day.boost + day.normal + day.torrent))
	property int hovered: -1

	implicitHeight: 150

	// the lines behind
	Repeater {
		model: 3

		delegate: Rectangle {
			required property int index
			x: 0
			y: bars.y + bars.height * (index / 3)
			width: root.width
			height: 1
			color: Theme.outline
		}
	}

	StyledText {
		anchors.right: parent.right
		y: bars.y - 2
		text: Format.bytes(root.highest)
		font.pixelSize: Theme.size.tiny
		tone: Theme.textFaint
		tabular: true
	}

	Row {
		id: bars

		y: 14
		width: parent.width
		height: parent.height - 34
		spacing: root.days.length > 20 ? 3 : 6

		Repeater {
			model: root.days

			delegate: Item {
				id: bar

				required property var modelData
				required property int index
				readonly property real sum: bar.modelData.boost + bar.modelData.normal + bar.modelData.torrent
				property real grow: 0

				width: (bars.width - bars.spacing * (root.days.length - 1)) / Math.max(1, root.days.length)
				height: bars.height

				// one after the other
				SequentialAnimation {
					id: rise

					PropertyAction { target: bar; property: "grow"; value: 0 }
					PauseAnimation { duration: 30 * bar.index }
					NumberAnimation { target: bar; property: "grow"; to: 1; duration: 700; easing.type: Easing.OutBack; easing.overshoot: 1.2 }
				}

				Connections {
					target: root
					function onPlayChanged() {
						if (root.play) rise.restart();
					}
				}
				Component.onCompleted: if (root.play) rise.restart()

				Rectangle {
					anchors.fill: parent
					radius: 4
					color: root.hovered === bar.index ? Theme.layer2 : "transparent"

					Behavior on color {
						ColorAnim {}
					}
				}

				Column {
					anchors.bottom: parent.bottom
					width: parent.width
					spacing: 0

					Rectangle {
						width: parent.width
						height: bar.grow * bars.height * bar.modelData.torrent / root.highest
						color: Theme.tertiary
						topLeftRadius: 4
						topRightRadius: 4
						visible: height > 0.5
					}

					Rectangle {
						width: parent.width
						height: bar.grow * bars.height * bar.modelData.normal / root.highest
						color: Qt.alpha(Theme.text, 0.32)
						topLeftRadius: bar.modelData.torrent > 0 ? 0 : 4
						topRightRadius: topLeftRadius
						visible: height > 0.5
					}

					Rectangle {
						width: parent.width
						height: bar.grow * bars.height * bar.modelData.boost / root.highest
						color: Theme.primary
						topLeftRadius: bar.modelData.torrent + bar.modelData.normal > 0 ? 0 : 4
						topRightRadius: topLeftRadius
						bottomLeftRadius: 2
						bottomRightRadius: 2
						visible: height > 0.5
					}
				}

				// nothing that day: a dot
				Rectangle {
					visible: bar.sum <= 0
					anchors.bottom: parent.bottom
					anchors.horizontalCenter: parent.horizontalCenter
					width: 4
					height: 4
					radius: 2
					color: Theme.textFaint
				}

				HoverHandler {
					onHoveredChanged: {
						if (hovered) root.hovered = bar.index;
						else if (root.hovered === bar.index) root.hovered = -1;
					}
				}
			}
		}
	}

	// the days' names under them, a few
	Row {
		anchors.bottom: parent.bottom
		width: parent.width
		spacing: bars.spacing

		Repeater {
			model: root.days

			delegate: StyledText {
				required property var modelData
				required property int index
				width: (bars.width - bars.spacing * (root.days.length - 1)) / Math.max(1, root.days.length)
				horizontalAlignment: Text.AlignHCenter
				text: root.days.length <= 14 || index % 5 === 0 || index === root.days.length - 1 ? (root.days.length <= 14 ? modelData.label : modelData.date) : ""
				font.pixelSize: Theme.size.tiny
				tone: index === root.days.length - 1 ? Theme.text : Theme.textSubtle
				elide: Text.ElideNone
			}
		}
	}

	// the day under the pointer
	Rectangle {
		id: tip

		readonly property var day: root.hovered >= 0 && root.hovered < root.days.length ? root.days[root.hovered] : null
		readonly property real anchorX: root.hovered >= 0 ? bars.x + (root.hovered + 0.5) * (bars.width + bars.spacing) / Math.max(1, root.days.length) : 0

		visible: opacity > 0.01
		opacity: tip.day ? 1 : 0
		x: Math.max(0, Math.min(root.width - width, tip.anchorX - width / 2))
		y: -8
		width: tipText.implicitWidth + 16
		height: tipText.implicitHeight + 10
		radius: Theme.radius.small
		color: Theme.layer3
		z: 5

		Behavior on opacity {
			Anim {
				duration: Motion.short
			}
		}
		Behavior on x {
			SpatialAnim {
				duration: Motion.medium
			}
		}

		StyledText {
			id: tipText

			anchors.centerIn: parent
			text: {
				const day = tip.day;
				if (!day) return "";
				const parts = [`${day.date}: ${Format.bytes(day.boost + day.normal + day.torrent)} in ${day.count}`];
				if (day.boost > 0) parts.push(`⚡ ${Format.bytes(day.boost)}`);
				if (day.normal > 0) parts.push(`normal ${Format.bytes(day.normal)}`);
				if (day.torrent > 0) parts.push(`torrent ${Format.bytes(day.torrent)}`);
				return parts.join("  ·  ");
			}
			font.pixelSize: Theme.size.tiny
			tabular: true
		}
	}
}
