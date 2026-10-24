import QtQuick
import QtQuick.Layouts
import qs.style.theme
import qs.style.widgets
import qs.core.services

// When a scene counts as shown: how alike the game looks to its picture
// now (the fill) and the bar it has to cross (the handle, dragged).
ColumnLayout {
	id: root

	property var page: null
	property var scene: null
	readonly property real score: Number(root.page.scores[root.scene?.id ?? ""] ?? 0)
	readonly property real bar: track.dragging >= 0 ? track.dragging : Number(root.scene?.similar ?? 0.55)
	readonly property bool up: root.page.liveScenes.includes(root.scene?.id ?? "")

	spacing: 8

	RowLayout {
		Layout.fillWidth: true
		spacing: 6

		StyledText {
			text: "Recognised from"
			font.pixelSize: Theme.size.label
			font.weight: Font.Bold
			tone: Theme.textSubtle
		}

		StyledText {
			text: `${Math.round(root.bar * 100)} %`
			font.pixelSize: Theme.size.label
			font.weight: Font.Bold
			tabular: true
		}

		Item {
			Layout.fillWidth: true
		}

		Rectangle {
			visible: root.page.watching
			Layout.preferredHeight: 22
			Layout.preferredWidth: nowText.implicitWidth + 16
			radius: 11
			color: root.up ? Theme.primary : Theme.layer2

			Behavior on color {
				ColorAnim {}
			}

			StyledText {
				id: nowText

				anchors.centerIn: parent
				text: root.up ? `shown · ${Math.round(root.score * 100)} %` : `now ${Math.round(root.score * 100)} %`
				font.pixelSize: Theme.size.small
				font.weight: Font.DemiBold
				tone: root.up ? Theme.onPrimary : Theme.textMuted
				tabular: true
			}
		}
	}

	Item {
		id: track

		// the bar while the handle is dragged, -1 otherwise
		property real dragging: -1

		Layout.fillWidth: true
		Layout.preferredHeight: 30

		Rectangle {
			anchors.fill: parent
			radius: 15
			color: Theme.layer2
			clip: true

			// the likeness now
			Rectangle {
				width: parent.width * Math.max(0, Math.min(1, root.score))
				height: parent.height
				radius: 15
				color: root.up ? Theme.primary : Qt.alpha(Theme.text, 0.18)
				visible: root.page.watching

				Behavior on width {
					SpatialAnim {
						duration: Motion.long
					}
				}
				Behavior on color {
					ColorAnim {}
				}
			}

			// below the bar: not this scene
			Rectangle {
				width: parent.width * root.bar
				height: parent.height
				color: "transparent"
				border.width: 0

				Repeater {
					model: Math.floor(parent.width / 8)

					Rectangle {
						required property int index

						x: index * 8 + 3
						y: parent.height / 2 - 1
						width: 2
						height: 2
						radius: 1
						color: Theme.textFaint
					}
				}
			}
		}

		// the handle
		Rectangle {
			id: handle

			x: track.width * root.bar - width / 2
			y: -4
			width: handleArea.pressed ? 10 : 8
			height: parent.height + 8
			radius: width / 2
			color: Theme.text
			border.width: 2
			border.color: Theme.layer1

			Behavior on width {
				SpatialAnim {
					duration: Motion.short
				}
			}
			Behavior on x {
				enabled: !handleArea.pressed
				SpatialAnim {
					duration: Motion.medium
				}
			}
		}

		MouseArea {
			id: handleArea

			function at(x) {
				return Math.round(Math.max(0.2, Math.min(0.9, x / track.width)) * 100) / 100;
			}

			anchors.fill: parent
			anchors.topMargin: -6
			anchors.bottomMargin: -6
			preventStealing: true
			cursorShape: Qt.SizeHorCursor
			onPressed: mouse => track.dragging = handleArea.at(mouse.x)
			onPositionChanged: mouse => {
				if (pressed) track.dragging = handleArea.at(mouse.x);
			}
			onReleased: {
				if (root.scene && track.dragging >= 0) Mouse.hudChangeScene(root.scene.id, { similar: track.dragging });
				track.dragging = -1;
			}
		}
	}
}
